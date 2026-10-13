import AVFoundation
import Foundation
import Observation
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
    #if DEBUG
    private var diagnosticFrameCount = 0
    private let diagnosticsEnabled = ProcessInfo.processInfo.environment["TUNER_DIAGNOSTICS"] == "1"
    #endif

    func analyze(frame: AudioAnalysisFrame, sampleRate: Double) -> PitchObservation? {
        lock.lock()
        defer { lock.unlock() }
        #if DEBUG
        if diagnosticsEnabled, diagnosticFrameCount < 12 {
            print("Tuner input: rate=\(sampleRate) advance=\(frame.advanceSamples) window=\(frame.samples.count)")
            diagnosticFrameCount += 1
        }
        #endif
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

/// The displayed reading. Each property is observed on its own, so a new pitch
/// only invalidates the views that read it — the pitch wheel, the meter, and the
/// readouts — instead of the entire screen at the hop rate.
@Observable
@MainActor
final class TunerEngine {
    private(set) var frequency: Double?
    private(set) var cents: Double?
    private(set) var midiNote: Int?
    private(set) var confidence = 0.0
    private(set) var status = "Play a note"
    private(set) var isTuned = false
    private(set) var microphoneDenied = false
    private(set) var microphonePermissionResolved = false

    @ObservationIgnored var configuration = TunerConfiguration()

    @ObservationIgnored private let audioEngine = AVAudioEngine()
    // Shared with the audio tap and the detection queue, so they are nonisolated
    // and kept out of observation: the registrar must not be touched off the
    // main actor.
    @ObservationIgnored private nonisolated let detectorQueue = DispatchQueue(
        label: "tuner.pitch-detection", qos: .userInitiated
    )
    @ObservationIgnored private nonisolated let analysisGate = AnalysisGate()
    @ObservationIgnored private nonisolated let audioWindow = OverlappingAudioWindow()
    @ObservationIgnored private nonisolated let pitchPipeline = PitchAnalysisPipeline()
    @ObservationIgnored private var tracker = PitchTracker()
    @ObservationIgnored private var analysisGeneration = 0
    #if DEBUG
    @ObservationIgnored private var lastDiagnosticTime = 0.0
    @ObservationIgnored private let diagnosticsEnabled = ProcessInfo.processInfo.environment["TUNER_DIAGNOSTICS"] == "1"
    #endif
    @ObservationIgnored private var hapticSent = false
    @ObservationIgnored private var hapticTask: Task<Void, Never>?
    @ObservationIgnored private let lockHaptic = UIImpactFeedbackGenerator(style: .medium)
    @ObservationIgnored private var fadeTimer: Timer?
    @ObservationIgnored private var notificationTokens: [NSObjectProtocol] = []
    @ObservationIgnored private var isStarting = false
    @ObservationIgnored private var shouldBeRunning = false
    @ObservationIgnored private var inputTapInstalled = false
    @ObservationIgnored private var activeInputNode: AVAudioInputNode?

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
        #if targetEnvironment(simulator)
        shouldBeRunning = false
        // CoreSimulator's inputNode can abort with an audio RPC deadlock even
        // when AVAudioSession reports an input. Do not initialize simulator I/O.
        clearReading(status: "Use iPhone for microphone")
        microphonePermissionResolved = true
        return
        #else
        guard !isStarting, !audioEngine.isRunning else { return }
        switch AVAudioApplication.shared.recordPermission {
        case .granted:
            microphonePermissionResolved = true
            configureAndStartAudio()
            return
        case .denied:
            clearReading(status: "Microphone is off", denied: true)
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
                else { self.clearReading(status: "Microphone is off", denied: true) }
                self.microphonePermissionResolved = true
            }
        }
        #endif
    }

    func stop() {
        shouldBeRunning = false
        analysisGeneration += 1
        fadeTimer?.invalidate()
        hapticTask?.cancel()
        removeInputTapIfNeeded()
        audioEngine.stop()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    /// Applies new settings. Options that only change what is drawn take effect on
    /// the next frame, and the reading is left alone, so a note being held is not
    /// interrupted by touching a display preference. Only the reference pitch
    /// moves the mapping from frequency to note, so only it needs the current
    /// reading re-expressed — and even then the note itself is unchanged.
    func update(configuration: TunerConfiguration) {
        guard configuration != self.configuration else { return }
        let referencePitchChanged = configuration.referencePitch != self.configuration.referencePitch
        self.configuration = configuration
        guard referencePitchChanged else { return }
        tracker.retune(referencePitch: configuration.referencePitch)
        // The phase refiner's history is expressed against the old reference.
        pitchPipeline.reset()
        hapticTask?.cancel()
        hapticSent = false
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

            // Validate the device route before constructing its input node.
            guard session.availableInputs?.isEmpty == false else {
                status = "No microphone available"
                try? session.setActive(false, options: .notifyOthersOnDeactivation)
                return
            }

            removeInputTapIfNeeded()
            let input = audioEngine.inputNode
            activeInputNode = input
            let format = input.outputFormat(forBus: 0)
            guard format.sampleRate > 0, format.channelCount > 0 else {
                status = "No microphone available"
                try? session.setActive(false, options: .notifyOthersOnDeactivation)
                return
            }
            audioWindow.reset()
            pitchPipeline.reset()
            clearReading()
            analysisGeneration += 1
            let generation = analysisGeneration
            input.installTap(onBus: 0, bufferSize: 1_024, format: format) { [weak self] buffer, _ in
                guard let self,
                      let data = buffer.floatChannelData?[0],
                      let frame = self.audioWindow.append(
                        data,
                        count: Int(buffer.frameLength),
                        gate: self.analysisGate
                      ) else { return }
                let observationTime = ProcessInfo.processInfo.systemUptime
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
                        guard let self, self.shouldBeRunning,
                              self.analysisGeneration == generation else { return }
                        self.consume(result, windowRMS: windowRMS, observationTime: observationTime)
                    }
                }
            }
            inputTapInstalled = true
            audioEngine.prepare()
            try audioEngine.start()
            startFadeTimer()
        } catch {
            removeInputTapIfNeeded()
            audioEngine.stop()
            status = "Audio unavailable"
        }
    }

    private func removeInputTapIfNeeded() {
        guard inputTapInstalled else { return }
        activeInputNode?.removeTap(onBus: 0)
        inputTapInstalled = false
        activeInputNode = nil
    }

    
    private func consume(_ observation: PitchObservation?, windowRMS: Double, observationTime: Double) {
        #if DEBUG
        defer {
            if diagnosticsEnabled, observationTime - lastDiagnosticTime >= 0.5 {
                print("Tuner tracking: rms=\(windowRMS) rawHz=\(observation?.frequency ?? 0) confidence=\(observation?.confidence ?? 0) displayedHz=\(frequency ?? 0)")
                lastDiagnosticTime = observationTime
            }
        }
        #endif
        guard let observation = tracker.consume(
            observation, windowRMS: windowRMS, time: observationTime,
            referencePitch: configuration.referencePitch
        ), let smoothedMIDINote = tracker.smoothedMIDINote else { return }

        let nearestNote = Int(smoothedMIDINote.rounded())
        let deviation = (smoothedMIDINote - Double(nearestNote)) * 100
        let absoluteDeviation = abs(deviation)
        let exitMargin = max(2.0, configuration.tolerance * 0.2)
        let tuned = isTuned
            ? absoluteDeviation <= configuration.tolerance + exitMargin
            : absoluteDeviation <= configuration.tolerance
        frequency = configuration.referencePitch * pow(2, (smoothedMIDINote - 69) / 12)
        cents = deviation
        midiNote = nearestNote
        confidence = observation.confidence
        status = tuned ? "In tune" : (deviation > 0 ? "Sharp" : "Flat")
        isTuned = tuned

        updateHaptics(cents: deviation)
    }

    private func updateHaptics(cents: Double) {
        if configuration.hapticsEnabled,
           abs(cents) > configuration.tolerance,
           abs(cents) <= configuration.tolerance + 15 {
            lockHaptic.prepare()
        }

        guard isTuned else {
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
                  self.isTuned else { return }
            self.lockHaptic.impactOccurred(intensity: 0.82)
        }
    }

    private func startFadeTimer() {
        fadeTimer?.invalidate()
        fadeTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if self.tracker.expire(at: ProcessInfo.processInfo.systemUptime) {
                    self.clearReading()
                }
            }
        }
    }

    /// Clears the reading and publishes a fresh status. Only the audio path calls
    /// this, so a settings change never costs the user the reading they are on.
    private func clearReading(status newStatus: String? = nil, denied: Bool = false) {
        frequency = nil
        cents = nil
        midiNote = nil
        confidence = 0
        isTuned = false
        microphoneDenied = denied
        status = newStatus ?? (denied ? "Microphone is off" : "Play a note")
        tracker.reset()
        hapticTask?.cancel()
        hapticSent = false
    }

    private func handleInterruption(_ notification: Notification) {
        guard let rawType = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: rawType) else { return }
        if type == .began {
            status = "Listening paused"
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
