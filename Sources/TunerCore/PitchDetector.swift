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
        let rms = sqrt(samples.reduce(0.0) { $0 + Double($1 * $1) } / Double(samples.count))
        guard rms >= silenceThreshold else { return nil }

        let minimumLag = max(2, Int(effectiveSampleRate / maximumFrequency))
        let maximumLag = min(samples.count / 2, Int(effectiveSampleRate / minimumFrequency))
        guard maximumLag > minimumLag else { return nil }

        var difference = [Double](repeating: 0, count: maximumLag + 1)
        for lag in minimumLag...maximumLag {
            var sum = 0.0
            let limit = samples.count - lag
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
