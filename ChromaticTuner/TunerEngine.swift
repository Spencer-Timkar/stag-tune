import AVFoundation
import Foundation
import UIKit

private final class AnalysisGate: @unchecked Sendable {
    private let lock = NSLock()
    private var busy = false

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !busy else { return false }
        busy = true
        return true
    }

    func release() {
        lock.lock()
        busy = false
        lock.unlock()
    }
}

private struct AudioAnalysisFrame: Sendable {
    let samples: [Float]
    let advanceSamples: Int
}

private final class PitchAnalysisPipeline: @unchecked Sendable {
    private let lock = NSLock()
    private let detector = PitchDetector(silenceThreshold: 0.00075)
    private var refiner = PhasePitchRefiner()

    func analyze(frame: AudioAnalysisFrame, sampleRate: Double) -> PitchObservation? {
        lock.lock()
        defer { lock.unlock() }
        guard let observation = detector.detect(samples: frame.samples, sampleRate: sampleRate) else {
            refiner.reset()
            return nil
        }
        return refiner.refine(
            observation: observation,
            samples: frame.samples,
            sampleRate: sampleRate,
            advanceSamples: frame.advanceSamples
        )
    }

    func reset() {
        lock.lock()
        refiner.reset()
        lock.unlock()
    }
}

private final class OverlappingAudioWindow: @unchecked Sendable {
    private let lock = NSLock()
    private let windowSize: Int
    private let hopSize: Int
    private var ring: [Float]
    private var writeIndex = 0
    private var sampleCount = 0
    private var samplesSinceAnalysis = 0

    init(windowSize: Int = 3_072, hopSize: Int = 1_024) {
        self.windowSize = windowSize
        self.hopSize = hopSize
        ring = [Float](repeating: 0, count: windowSize)
    }

    func append(_ data: UnsafePointer<Float>, count: Int, gate: AnalysisGate) -> AudioAnalysisFrame? {
        lock.lock()
        defer { lock.unlock() }

        for index in 0..<count {
            ring[writeIndex] = data[index]
            writeIndex = (writeIndex + 1) % windowSize
        }
        sampleCount = min(windowSize, sampleCount + count)
        samplesSinceAnalysis += count

        guard sampleCount == windowSize,
              samplesSinceAnalysis >= hopSize,
              gate.claim() else { return nil }

        let advanceSamples = samplesSinceAnalysis
        samplesSinceAnalysis = 0
        var window = [Float](repeating: 0, count: windowSize)
        for index in 0..<windowSize {
            window[index] = ring[(writeIndex + index) % windowSize]
        }
        return AudioAnalysisFrame(samples: window, advanceSamples: advanceSamples)
    }

    func reset() {
        lock.lock()
        ring.withUnsafeMutableBufferPointer { $0.initialize(repeating: 0) }
        writeIndex = 0
        sampleCount = 0
        samplesSinceAnalysis = 0
        lock.unlock()
    }
}

private struct TunerSnapshot {
    var frequency: Double? = nil
    var cents: Double? = nil
    var midiNote: Int? = nil
    var confidence = 0.0
    var status = "Play a note"
    var microphoneDenied = false
    var isTuned = false
}

@MainActor
final class TunerEngine: ObservableObject {
    @Published private var snapshot = TunerSnapshot()

    var frequency: Double? { snapshot.frequency }
    var cents: Double? { snapshot.cents }
    var midiNote: Int? { snapshot.midiNote }
    var confidence: Double { snapshot.confidence }
    var status: String { snapshot.status }
    var microphoneDenied: Bool { snapshot.microphoneDenied }
    @Published private(set) var microphonePermissionResolved = false
    var isTuned: Bool { snapshot.isTuned }

    var configuration = TunerConfiguration()

    private let audioEngine = AVAudioEngine()
    private let detectorQueue = DispatchQueue(label: "tuner.pitch-detection", qos: .userInitiated)
    private let analysisGate = AnalysisGate()
    private let audioWindow = OverlappingAudioWindow()
    private let pitchPipeline = PitchAnalysisPipeline()
    private var smoothedMIDINote: Double?
    private var recentRawNotes: [Double] = []
    private var pendingJumpMIDINote: Double?
    private var pendingJumpCount = 0
    private var learnedNoiseFloor: Double?
    private var lastObservation = Date.distantPast
    private var hapticSent = false
    private var hapticTask: Task<Void, Never>?
    private let lockHaptic = UIImpactFeedbackGenerator(style: .medium)
    private var fadeTimer: Timer?
    private var notificationTokens: [NSObjectProtocol] = []
    private var isStarting = false
    private var shouldBeRunning = false
    private var inputTapInstalled = false
    private var activeInputNode: AVAudioInputNode?

    init() {
        let center = NotificationCenter.default
        notificationTokens.append(center.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            Task { @MainActor [weak self] in self?.handleInterruption(notification) }
        })
        notificationTokens.append(center.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            Task { @MainActor [weak self] in self?.handleRouteChange(notification) }
        })
    }

    deinit {
        notificationTokens.forEach { NotificationCenter.default.removeObserver($0) }
    }

    func start() {
        shouldBeRunning = true
        guard !isStarting, !audioEngine.isRunning else { return }
        switch AVAudioApplication.shared.recordPermission {
        case .granted:
            microphonePermissionResolved = true
            configureAndStartAudio()
            return
        case .denied:
            snapshot = TunerSnapshot(status: "Microphone is off", microphoneDenied: true)
            microphonePermissionResolved = true
            return
        case .undetermined:
            microphonePermissionResolved = false
        @unknown default:
            return
        }
        isStarting = true
        AVAudioApplication.requestRecordPermission { [weak self] granted in
            Task { @MainActor in
                guard let self else { return }
                defer { self.isStarting = false }
                guard self.shouldBeRunning else { return }
                if granted { self.configureAndStartAudio() }
                else {
                    self.snapshot = TunerSnapshot(
                        status: "Microphone is off",
                        microphoneDenied: true
                    )
                }
                self.microphonePermissionResolved = true
            }
        }
    }

    func stop() {
        shouldBeRunning = false
        fadeTimer?.invalidate()
        hapticTask?.cancel()
        removeInputTapIfNeeded()
        audioEngine.stop()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    func update(configuration: TunerConfiguration) {
        self.configuration = configuration
        smoothedMIDINote = nil
        learnedNoiseFloor = nil
        audioWindow.reset()
        pitchPipeline.reset()
        clearReading()
    }

    private func configureAndStartAudio() {
        guard shouldBeRunning, !audioEngine.isRunning else { return }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .measurement)
            try session.setPreferredSampleRate(48_000)
            try session.setPreferredIOBufferDuration(0.02)
            try session.setActive(true)
            if let builtInMicrophone = session.availableInputs?.first(where: { $0.portType == .builtInMic }) {
                try? session.setPreferredInput(builtInMicrophone)
            }

            // AVAudioEngine's inputNode accessor can abort the process when the
            // Simulator or a temporarily changing route has no input device.
            // Check the session first so that state becomes a recoverable UI
            // message instead of a SIGABRT.
            guard session.availableInputs?.isEmpty == false else {
                var next = snapshot
                next.status = "No microphone available"
                snapshot = next
                try? session.setActive(false, options: .notifyOthersOnDeactivation)
                return
            }

            let input = audioEngine.inputNode
            activeInputNode = input
            let format = input.outputFormat(forBus: 0)
            guard format.sampleRate > 0, format.channelCount > 0 else {
                var next = snapshot
                next.status = "No microphone available"
                snapshot = next
                try? session.setActive(false, options: .notifyOthersOnDeactivation)
                return
            }
            removeInputTapIfNeeded()
            audioWindow.reset()
            pitchPipeline.reset()
            learnedNoiseFloor = nil
            input.installTap(onBus: 0, bufferSize: 1_024, format: format) { [weak self] buffer, _ in
                guard let self,
                      let data = buffer.floatChannelData?[0],
                      let frame = self.audioWindow.append(
                        data,
                        count: Int(buffer.frameLength),
                        gate: self.analysisGate
                      ) else { return }
                let rate = format.sampleRate
                self.detectorQueue.async { [weak self] in
                    guard let self else { return }
                    let result = self.pitchPipeline.analyze(frame: frame, sampleRate: rate)
                    let windowRMS = sqrt(
                        frame.samples.reduce(0.0) { $0 + Double($1 * $1) }
                            / Double(frame.samples.count)
                    )
                    self.analysisGate.release()
                    Task { @MainActor [weak self] in
                        self?.consume(result, windowRMS: windowRMS)
                    }
                }
            }
            inputTapInstalled = true
            audioEngine.prepare()
            try audioEngine.start()
            snapshot = TunerSnapshot()
            startFadeTimer()
        } catch {
            removeInputTapIfNeeded()
            audioEngine.stop()
            var next = snapshot
            next.status = "Audio unavailable"
            snapshot = next
        }
    }

    private func removeInputTapIfNeeded() {
        guard inputTapInstalled else { return }
        activeInputNode?.removeTap(onBus: 0)
        inputTapInstalled = false
    }

    
    private func consume(_ observation: PitchObservation?, windowRMS: Double) {
        let acquisitionConfidence = 0.43
        let releaseConfidence = 0.28
        let releaseDuration = 1.25
        let now = Date()
        let rawMIDINote = observation.map {
            69 + 12 * log2($0.frequency / configuration.referencePitch)
        }
        let isContinuingTrackedNote: Bool
        if let trackedNote = smoothedMIDINote,
           let rawMIDINote,
           now.timeIntervalSince(lastObservation) <= releaseDuration {
            isContinuingTrackedNote = abs(rawMIDINote - trackedNote) <= 1.25
        } else {
            isContinuingTrackedNote = false
        }

        // Learn the room level only from frames that do not resemble a stable
        // musical pitch. Strong, highly periodic notes can always pass the gate,
        // which keeps quiet instruments responsive.
        if !isContinuingTrackedNote,
           observation == nil || (observation?.confidence ?? 0) <= acquisitionConfidence {
            if let learnedNoiseFloor {
                self.learnedNoiseFloor = learnedNoiseFloor * 0.94 + windowRMS * 0.06
            } else {
                learnedNoiseFloor = windowRMS
            }
        }

        guard let observation, let rawMIDINote else { return }
        if isContinuingTrackedNote {
            let releaseThreshold = max(0.00075, (learnedNoiseFloor ?? 0) * 0.84)
            guard observation.confidence >= releaseConfidence,
                  observation.confidence >= 0.58 || observation.amplitude >= releaseThreshold else { return }
        } else {
            let acquisitionThreshold = max(0.00095, learnedNoiseFloor ?? 0)
            guard observation.confidence >= acquisitionConfidence,
                  observation.confidence >= 0.66 || observation.amplitude >= acquisitionThreshold else { return }
        }
        guard let confirmedMIDINote = confirmedJump(rawMIDINote) else { return }

        recentRawNotes.append(confirmedMIDINote)
        if recentRawNotes.count > 5 { recentRawNotes.removeFirst() }
        let filterDepth = observation.confidence >= 0.78 ? 3 : 5
        let filterWindow = recentRawNotes.suffix(filterDepth).sorted()
        let filteredMIDINote = filterWindow[filterWindow.count / 2]

        // Median filtering rejects single-frame harmonic errors; adaptive smoothing
        // settles quiet jitter without making genuine movement feel sluggish.
        if let previous = smoothedMIDINote, abs(filteredMIDINote - previous) < 1.25 {
            let distance = abs(filteredMIDINote - previous)
            let response: Double
            if distance > 0.12 {
                response = observation.confidence >= 0.78 ? 0.46 : 0.34
            } else {
                response = observation.confidence >= 0.78 ? 0.22 : 0.16
            }
            smoothedMIDINote = previous + response * (filteredMIDINote - previous)
        } else {
            smoothedMIDINote = filteredMIDINote
        }
        guard let smoothedMIDINote else { return }

        let nearestNote = Int(smoothedMIDINote.rounded())
        let deviation = (smoothedMIDINote - Double(nearestNote)) * 100
        let absoluteDeviation = abs(deviation)
        let exitMargin = max(2.0, configuration.tolerance * 0.2)
        let tuned = snapshot.isTuned
            ? absoluteDeviation <= configuration.tolerance + exitMargin
            : absoluteDeviation <= configuration.tolerance
        snapshot = TunerSnapshot(
            frequency: observation.frequency,
            cents: deviation,
            midiNote: nearestNote,
            confidence: observation.confidence,
            status: tuned ? "In tune" : (deviation > 0 ? "Sharp" : "Flat"),
            isTuned: tuned
        )
        lastObservation = now

        updateHaptics(cents: deviation)
    }

    private func confirmedJump(_ rawMIDINote: Double) -> Double? {
        guard let trackedNote = smoothedMIDINote else {
            pendingJumpMIDINote = nil
            pendingJumpCount = 0
            return rawMIDINote
        }

        guard abs(rawMIDINote - trackedNote) > 2.5 else {
            pendingJumpMIDINote = nil
            pendingJumpCount = 0
            return rawMIDINote
        }

        if let pendingJumpMIDINote,
           abs(rawMIDINote - pendingJumpMIDINote) <= 0.35 {
            pendingJumpCount += 1
            self.pendingJumpMIDINote = rawMIDINote
        } else {
            pendingJumpMIDINote = rawMIDINote
            pendingJumpCount = 1
        }

        guard pendingJumpCount >= 2 else { return nil }
        self.pendingJumpMIDINote = nil
        pendingJumpCount = 0
        recentRawNotes.removeAll(keepingCapacity: true)
        return rawMIDINote
    }

    private func updateHaptics(cents: Double) {
        if configuration.hapticsEnabled,
           abs(cents) > configuration.tolerance,
           abs(cents) <= configuration.tolerance + 15 {
            lockHaptic.prepare()
        }

        guard snapshot.isTuned else {
            hapticTask?.cancel()
            hapticSent = false
            return
        }

        guard configuration.hapticsEnabled, !hapticSent else { return }
        hapticSent = true
        lockHaptic.prepare()
        hapticTask?.cancel()
        hapticTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(90))
            guard let self,
                  !Task.isCancelled,
                  self.snapshot.isTuned else { return }
            self.lockHaptic.impactOccurred(intensity: 0.82)
        }
    }

    private func startFadeTimer() {
        fadeTimer?.invalidate()
        fadeTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let now = Date()
                if now.timeIntervalSince(self.lastObservation) > 1.25 { self.clearReading() }
            }
        }
    }

    private func clearReading() {
        snapshot = TunerSnapshot(
            status: microphoneDenied ? "Microphone is off" : "Play a note",
            microphoneDenied: microphoneDenied
        )
        smoothedMIDINote = nil
        recentRawNotes.removeAll(keepingCapacity: true)
        pendingJumpMIDINote = nil
        pendingJumpCount = 0
        hapticTask?.cancel()
        hapticSent = false
    }

    private func handleInterruption(_ notification: Notification) {
        guard let rawType = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: rawType) else { return }
        if type == .began {
            var next = snapshot
            next.status = "Listening paused"
            snapshot = next
        } else {
            restartForRouteChange()
        }
    }

    private func restartForRouteChange() {
        guard shouldBeRunning, !microphoneDenied, !isStarting else { return }
        isStarting = true
        defer { isStarting = false }
        removeInputTapIfNeeded()
        audioEngine.stop()
        configureAndStartAudio()
    }

    private func handleRouteChange(_ notification: Notification) {
        guard let rawReason = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
              let reason = AVAudioSession.RouteChangeReason(rawValue: rawReason),
              reason == .newDeviceAvailable || reason == .oldDeviceUnavailable else { return }
        restartForRouteChange()
    }
}
