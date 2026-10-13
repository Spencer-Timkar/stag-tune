import Foundation

public struct PitchObservation: Sendable, Equatable {
    public let frequency: Double
    public let confidence: Double
    public let amplitude: Double

    public init(frequency: Double, confidence: Double, amplitude: Double) {
        self.frequency = frequency
        self.confidence = confidence
        self.amplitude = amplitude
    }
}

/// Refines consecutive pitch observations from the phase advance of the actual
/// fundamental. YIN provides fast, robust note acquisition; phase tracking then
/// removes the sharp bias that stiff guitar-string overtones can introduce.
public struct PhasePitchRefiner: Sendable {
    private var previousPhase: Double?
    private var previousReferenceFrequency: Double?

    public init() {}

    public mutating func reset() {
        previousPhase = nil
        previousReferenceFrequency = nil
    }

    public mutating func refine(
        observation: PitchObservation,
        samples: [Float],
        sampleRate: Double,
        advanceSamples: Int
    ) -> PitchObservation {
        guard samples.count >= 1_024, sampleRate > 0, advanceSamples > 0 else {
            reset()
            return observation
        }

        let midi = (69 + 12 * log2(observation.frequency / 440)).rounded()
        let referenceFrequency = 440 * pow(2, (midi - 69) / 12)
        let phase = fundamentalPhase(
            samples: samples,
            sampleRate: sampleRate,
            referenceFrequency: referenceFrequency
        )

        defer {
            previousPhase = phase
            previousReferenceFrequency = referenceFrequency
        }

        guard let previousPhase,
              let previousReferenceFrequency,
              abs(previousReferenceFrequency - referenceFrequency) < 0.01 else {
            return observation
        }

        let twoPi = 2 * Double.pi
        let wrappedAdvance = phase - previousPhase
        let expectedAdvance = twoPi * observation.frequency * Double(advanceSamples) / sampleRate
        let cycleCount = ((expectedAdvance - wrappedAdvance) / twoPi).rounded()
        let unwrappedAdvance = wrappedAdvance + cycleCount * twoPi
        let phaseFrequency = unwrappedAdvance * sampleRate / (twoPi * Double(advanceSamples))

        // Phase is only a refinement. If the fundamental coefficient is briefly
        // contaminated by an attack or room noise, retain the robust YIN result.
        guard phaseFrequency.isFinite,
              abs(phaseFrequency - observation.frequency) <= max(2.5, observation.frequency * 0.025) else {
            return observation
        }

        return PitchObservation(
            frequency: phaseFrequency,
            confidence: observation.confidence,
            amplitude: observation.amplitude
        )
    }

    private func fundamentalPhase(
        samples: [Float],
        sampleRate: Double,
        referenceFrequency: Double
    ) -> Double {
        let count = samples.count
        let step = 2 * Double.pi * referenceFrequency / sampleRate
        let stepCosine = cos(step)
        let stepSine = sin(step)
        var oscillatorCosine = 1.0
        var oscillatorSine = 0.0
        var real = 0.0
        var imaginary = 0.0

        for index in 0..<count {
            let window = 0.5 - 0.5 * cos(2 * Double.pi * Double(index) / Double(count - 1))
            let sample = Double(samples[index]) * window
            real += sample * oscillatorCosine
            imaginary -= sample * oscillatorSine

            let nextCosine = oscillatorCosine * stepCosine - oscillatorSine * stepSine
            oscillatorSine = oscillatorSine * stepCosine + oscillatorCosine * stepSine
            oscillatorCosine = nextCosine
        }
        return atan2(imaginary, real)
    }
}

/// A YIN-style detector tuned for monophonic musical notes.
public struct PitchDetector: Sendable {
    public var minimumFrequency: Double
    public var maximumFrequency: Double
    public var silenceThreshold: Double
    public var yinThreshold: Double

    public init(
        minimumFrequency: Double = 45,
        maximumFrequency: Double = 2_000,
        silenceThreshold: Double = 0.006,
        yinThreshold: Double = 0.16
    ) {
        self.minimumFrequency = minimumFrequency
        self.maximumFrequency = maximumFrequency
        self.silenceThreshold = silenceThreshold
        self.yinThreshold = yinThreshold
    }

    public func detect(samples input: [Float], sampleRate: Double) -> PitchObservation? {
        guard input.count >= 1_024, sampleRate > 0 else { return nil }

        // A box-filtered 4:1 decimation keeps the musical range while reducing the
        // quadratic YIN workload by roughly 16x. This matters in unoptimized debug
        // builds and prevents microphone buffers from queuing behind analysis.
        let factor = 4
        let reducedCount = input.count / factor
        var samples = [Float]()
        samples.reserveCapacity(reducedCount)
        for index in 0..<reducedCount {
            let start = index * factor
            let average = (input[start] + input[start + 1] + input[start + 2] + input[start + 3]) / Float(factor)
            samples.append(average)
        }
        let effectiveSampleRate = sampleRate / Double(factor)
        let mean = samples.reduce(0.0) { $0 + Double($1) } / Double(samples.count)
        samples = samples.map { Float(Double($0) - mean) }
        // Pre-emphasis reduces fan/handling rumble relative to string partials.
        // Keep RMS on the unweighted signal so quiet-note sensitivity is unchanged.
        // A gentle low-pass limits the extra weight given to pick transients and
        // sharp upper partials. Both coefficients follow the actual sample rate.
        let rms = sqrt(samples.reduce(0.0) { $0 + Double($1 * $1) } / Double(samples.count))
        let original = samples
        let emphasis = Float(exp(-2 * Double.pi * 80 / effectiveSampleRate))
        let lowPass = Float(exp(-2 * Double.pi * 1_200 / effectiveSampleRate))
        var filtered = (1 - emphasis) * original[0]
        samples[0] = filtered
        for index in 1..<samples.count {
            let emphasized = original[index] - emphasis * original[index - 1]
            filtered = lowPass * filtered + (1 - lowPass) * emphasized
            samples[index] = filtered
        }
        guard rms >= silenceThreshold else { return nil }

        let minimumLag = max(2, Int(effectiveSampleRate / maximumFrequency))
        let maximumLag = min(samples.count / 2, Int(effectiveSampleRate / minimumFrequency))
        guard maximumLag > minimumLag else { return nil }

        var difference = [Double](repeating: 0, count: maximumLag + 1)
        // Every lag contributes to cumulative normalization. Use equal-sized
        // comparisons so longer periods do not win merely by comparing less audio.
        for lag in 1...maximumLag {
            var sum = 0.0
            let limit = samples.count - maximumLag
            for index in 0..<limit {
                let delta = Double(samples[index] - samples[index + lag])
                sum += delta * delta
            }
            difference[lag] = sum
        }

        var normalized = [Double](repeating: 1, count: maximumLag + 1)
        var runningSum = 0.0
        if maximumLag >= 1 {
            for lag in 1...maximumLag {
                runningSum += difference[lag]
                normalized[lag] = runningSum == 0 ? 1 : difference[lag] * Double(lag) / runningSum
            }
        }

        var candidate: Int?
        if minimumLag <= maximumLag {
            for lag in minimumLag...maximumLag where normalized[lag] < yinThreshold {
                var valley = lag
                while valley + 1 <= maximumLag && normalized[valley + 1] < normalized[valley] {
                    valley += 1
                }
                candidate = valley
                break
            }
        }

        if candidate == nil {
            candidate = (minimumLag...maximumLag).min { normalized[$0] < normalized[$1] }
        }
        guard let initialLag = candidate, normalized[initialLag] < 0.45 else { return nil }

        // A quiet guitar fundamental can miss the first YIN threshold while a
        // longer repeated period crosses it. The B string is especially prone to
        // being reported as low E because three B periods are almost exactly one
        // E2 period. Check short-period divisors before accepting that kind of
        // subharmonic, but require a clearly periodic divisor so real bass notes
        // are not promoted to one of their upper harmonics.
        var lag = initialLag
        for divisor in stride(from: 4, through: 2, by: -1) {
            let approximate = initialLag / divisor
            guard approximate >= minimumLag else { continue }
            let lower = max(minimumLag, approximate - 2)
            let upper = min(maximumLag, approximate + 2)
            guard lower <= upper,
                  let divisorLag = (lower...upper).min(by: { normalized[$0] < normalized[$1] }) else { continue }
            let divisorScore = normalized[divisorLag]
            if divisorScore < 0.28,
               divisorScore <= normalized[initialLag] + 0.14 {
                lag = divisorLag
                break
            }
        }

        let refinedLag: Double
        if lag > minimumLag && lag < maximumLag {
            let left = normalized[lag - 1]
            let center = normalized[lag]
            let right = normalized[lag + 1]
            let denominator = left - (2 * center) + right
            refinedLag = abs(denominator) > 0.000_001
                ? Double(lag) + 0.5 * (left - right) / denominator
                : Double(lag)
        } else {
            refinedLag = Double(lag)
        }

        let frequency = effectiveSampleRate / refinedLag
        guard frequency >= minimumFrequency, frequency <= maximumFrequency else { return nil }
        return PitchObservation(
            frequency: frequency,
            confidence: max(0, min(1, 1 - normalized[lag])),
            amplitude: rms
        )
    }
}

/// Confirms acquisition and note changes over elapsed observation time. Missing or
/// rejected frames break confirmation, so scattered false notes cannot add up
/// to a switch. Small tuning movements pass through without a confirmation delay.
public struct PitchContinuityFilter: Sendable {
    private var candidate: Double?
    private var candidateSince = 0.0
    private var lastTime: Double?
    private var count = 0

    public init() {}

    public mutating func reset() {
        candidate = nil
        lastTime = nil
        count = 0
    }

    public mutating func accept(
        midiNote: Double?, trackedNote: Double?, confidence: Double, time: Double
    ) -> Bool {
        guard let midiNote, midiNote.isFinite, time.isFinite, confidence >= 0.55 else {
            reset()
            return false
        }
        let distance = trackedNote.map { abs(midiNote - $0) }
        if let distance, distance <= 0.75 {
            reset()
            return true
        }
        guard confidence >= 0.60 else { reset(); return false }
        // A tap's requested buffer size is only a hint. Batched device delivery
        // and debug builds can exceed 100 ms without a missing observation.
        if let candidate, let lastTime,
           time >= lastTime, time - lastTime <= 0.5,
           abs(midiNote - candidate) <= 0.35 {
            count += 1
        } else {
            candidate = midiNote
            candidateSince = time
            count = 1
        }
        lastTime = time
        let duration = distance.map { $0 > 7.5 ? 0.18 : 0.10 } ?? 0.04
        guard count >= 3, time - candidateSince >= duration else { return false }
        reset()
        return true
    }
}


/// Shared live/replay tracking, including the idle timer. An empty display has
/// nothing to expire: timer ticks must never erase a pending first note.
public struct PitchTracker: Sendable {
    public private(set) var smoothedMIDINote: Double?
    /// The frequency the smoothed note represents. Kept so a change of reference
    /// pitch can re-express a held reading instead of dropping it.
    private var smoothedFrequency: Double?
    private var recentRawNotes: [Double] = []
    private var continuityFilter = PitchContinuityFilter()
    private var learnedNoiseFloor: Double?
    private var lastObservation: Double?

    public init() {}

    public mutating func reset() {
        self = PitchTracker()
    }

    /// Re-expresses a held reading under a new reference pitch. Changing the
    /// reference does not change the note being played, so the reading must
    /// survive it: only the MIDI number the frequency maps to moves. Raw
    /// observations and any pending confirmation are dropped because they are
    /// expressed against the old reference.
    public mutating func retune(referencePitch: Double) {
        guard let smoothedFrequency, referencePitch.isFinite, referencePitch > 0 else { return }
        smoothedMIDINote = 69 + 12 * log2(smoothedFrequency / referencePitch)
        recentRawNotes.removeAll(keepingCapacity: true)
        continuityFilter.reset()
    }

    @discardableResult
    public mutating func expire(at time: Double) -> Bool {
        guard let lastObservation, time.isFinite,
              time - lastObservation > 1.25 else { return false }
        smoothedMIDINote = nil
        smoothedFrequency = nil
        recentRawNotes.removeAll(keepingCapacity: true)
        continuityFilter.reset()
        self.lastObservation = nil
        return true
    }

    public mutating func consume(
        _ observation: PitchObservation?, windowRMS: Double,
        time: Double, referencePitch: Double = 440
    ) -> PitchObservation? {
        let acquisitionConfidence = 0.60
        let releaseConfidence = 0.55
        let releaseDuration = 1.25
        guard time.isFinite, referencePitch.isFinite, referencePitch > 0,
              windowRMS.isFinite, windowRMS >= 0 else { return nil }
        _ = expire(at: time)
        let rawMIDINote = observation.flatMap { value -> Double? in
            guard value.frequency.isFinite, value.frequency > 0,
                  value.confidence.isFinite, value.amplitude.isFinite else { return nil }
            return 69 + 12 * log2(value.frequency / referencePitch)
        }
        let isContinuingTrackedNote: Bool
        if let trackedNote = smoothedMIDINote,
           let rawMIDINote,
           lastObservation.map({ time - $0 <= releaseDuration }) == true {
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

        guard let observation, let rawMIDINote else {
            continuityFilter.reset()
            return nil
        }
        if isContinuingTrackedNote {
            let releaseThreshold = max(0.00075, (learnedNoiseFloor ?? 0) * 0.84)
            guard observation.confidence >= releaseConfidence,
                  observation.confidence >= 0.58 || observation.amplitude >= releaseThreshold else {
                continuityFilter.reset()
                return nil
            }
        } else {
            let acquisitionThreshold = max(0.00095, learnedNoiseFloor ?? 0)
            guard observation.confidence >= acquisitionConfidence,
                  observation.confidence >= 0.66 || observation.amplitude >= acquisitionThreshold else {
                continuityFilter.reset()
                return nil
            }
        }
        guard continuityFilter.accept(
            midiNote: rawMIDINote,
            trackedNote: smoothedMIDINote,
            confidence: observation.confidence,
            time: time
        ) else { return nil }
        if let previous = smoothedMIDINote, abs(rawMIDINote - previous) > 0.75 {
            recentRawNotes.removeAll(keepingCapacity: true)
        }
        recentRawNotes.append(rawMIDINote)
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
        guard let smoothedMIDINote else { return nil }

        lastObservation = time
        let frequency = referencePitch * pow(2, (smoothedMIDINote - 69) / 12)
        smoothedFrequency = frequency
        return PitchObservation(
            frequency: frequency,
            confidence: observation.confidence,
            amplitude: observation.amplitude
        )
    }
}
