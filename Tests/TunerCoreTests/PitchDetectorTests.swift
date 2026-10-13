import XCTest
@testable import TunerCore

final class PitchDetectorTests: XCTestCase {
    private let sampleRate = 48_000.0

    func testDetectsConcertA() throws {
        let observation = try XCTUnwrap(PitchDetector().detect(
            samples: sine(frequency: 440, count: 4_096),
            sampleRate: sampleRate
        ))
        XCTAssertEqual(observation.frequency, 440, accuracy: 0.7)
        XCTAssertGreaterThan(observation.confidence, 0.9)
    }

    func testDetectsLowGuitarE() throws {
        let observation = try XCTUnwrap(PitchDetector().detect(
            samples: sine(frequency: 82.4069, count: 8_192),
            sampleRate: sampleRate
        ))
        XCTAssertEqual(observation.frequency, 82.4069, accuracy: 0.25)
    }

    func testDetectsLowGuitarEWithAppWindow() throws {
        let detector = PitchDetector(silenceThreshold: 0.01, yinThreshold: 0.14)
        let observation = try XCTUnwrap(detector.detect(
            samples: sine(frequency: 82.4069, count: 3_072),
            sampleRate: sampleRate
        ))
        XCTAssertEqual(observation.frequency, 82.4069, accuracy: 0.35)
        XCTAssertGreaterThan(observation.confidence, 0.7)
    }

    func testDetectsVeryQuietUnpluggedElectricGuitarSignal() throws {
        let detector = PitchDetector(silenceThreshold: 0.0025)
        let observation = try XCTUnwrap(detector.detect(
            samples: sine(frequency: 82.4069, count: 3_072, amplitude: 0.004),
            sampleRate: sampleRate
        ))
        XCTAssertEqual(observation.frequency, 82.4069, accuracy: 0.35)
        XCTAssertGreaterThan(observation.confidence, 0.7)
    }

    func testDetectsUnpluggedElectricGuitarDecay() throws {
        let detector = PitchDetector(silenceThreshold: 0.00096)
        let observation = try XCTUnwrap(detector.detect(
            samples: sine(frequency: 82.4069, count: 3_072, amplitude: 0.0016),
            sampleRate: sampleRate
        ))
        XCTAssertEqual(observation.frequency, 82.4069, accuracy: 0.35)
        XCTAssertGreaterThan(observation.confidence, 0.62)
    }

    func testDoesNotMistakeQuietBStringForLowE() throws {
        let frequency = 246.9417
        let samples: [Float] = (0..<3_072).map { index in
            let time = Double(index) / sampleRate
            let phase = 2 * Double.pi * frequency * time
            let cycle = Int(floor(frequency * time)) % 3
            let envelope = [1.0, 0.76, 0.54][cycle]
            // A weak fundamental with prominent upper harmonics approximates the
            // microphone signal from an unplugged electric-guitar string. Its
            // three-cycle envelope recreates the B-to-low-E subharmonic trap.
            return Float(envelope * (
                0.0014 * sin(phase)
                + 0.0022 * sin(2.01 * phase)
                + 0.0018 * sin(3.02 * phase)
            ))
        }
        let observation = try XCTUnwrap(PitchDetector(silenceThreshold: 0.0012).detect(
            samples: samples,
            sampleRate: sampleRate
        ))
        XCTAssertEqual(observation.frequency, frequency, accuracy: 2.0)
    }

    func testPhaseRefinementFollowsFundamentalInsteadOfSharpPartials() throws {
        let fundamental = 81.6
        let totalCount = 4_096
        let stiffness = 0.001
        let amplitudes = [0.05, 0.24, 0.20, 0.16, 0.12]
        let signal: [Float] = (0..<totalCount).map { index in
            let time = Double(index) / sampleRate
            return Float(amplitudes.enumerated().reduce(0.0) { sum, item in
                let harmonic = Double(item.offset + 1)
                let partial = harmonic * fundamental * sqrt(1 + stiffness * harmonic * harmonic)
                return sum + item.element * sin(2 * .pi * partial * time)
            })
        }

        let detector = PitchDetector(silenceThreshold: 0.0012)
        var refiner = PhasePitchRefiner()
        let firstRaw = try XCTUnwrap(detector.detect(
            samples: Array(signal[0..<3_072]), sampleRate: sampleRate
        ))
        _ = refiner.refine(
            observation: firstRaw,
            samples: Array(signal[0..<3_072]),
            sampleRate: sampleRate,
            advanceSamples: 3_072
        )
        let secondSamples = Array(signal[1_024..<4_096])
        let secondRaw = try XCTUnwrap(detector.detect(samples: secondSamples, sampleRate: sampleRate))
        let refined = refiner.refine(
            observation: secondRaw,
            samples: secondSamples,
            sampleRate: sampleRate,
            advanceSamples: 1_024
        )

        XCTAssertGreaterThan(secondRaw.frequency, fundamental + 0.25)
        XCTAssertEqual(refined.frequency, fundamental, accuracy: 0.25)
    }

    func testRejectsSilence() {
        XCTAssertNil(PitchDetector().detect(samples: [Float](repeating: 0, count: 4_096), sampleRate: sampleRate))
    }

    func testRejectsBroadbandRoomNoise() {
        var state: UInt64 = 0xC0FFEE
        let noise: [Float] = (0..<3_072).map { _ in
            state = state &* 6_364_136_223_846_793_005 &+ 1
            let unit = Double(state >> 11) / Double(UInt64.max >> 11)
            return Float((unit * 2 - 1) * 0.03)
        }
        let detector = PitchDetector(silenceThreshold: 0.01, yinThreshold: 0.14)
        XCTAssertNil(detector.detect(samples: noise, sampleRate: sampleRate))
    }

    func testPreservesChromaticRangeAfterRumbleWeighting() throws {
        for rate in [44_100.0, 48_000.0] {
            for frequency in [46.25, 55, 110, 440, 880, 1760, 1975.5] {
                let samples = (0..<3_072).map { Float(0.05 * sin(2 * Double.pi * frequency * Double($0) / rate)) }
                let result = try XCTUnwrap(PitchDetector().detect(samples: samples, sampleRate: rate))
                XCTAssertLessThan(abs(1200 * log2(result.frequency / frequency)), 25, "Frequency \(frequency) at \(rate)")
            }
        }
    }

    func testUpperStringsThroughFanRumbleAtCommonSampleRates() throws {
        for rate in [44_100.0, 48_000.0] {
            for frequency in [196.0, 246.9417, 329.6276] {
                var state: UInt64 = 12345
                for offset in stride(from: 0, to: 12_288, by: 1_024) {
                    let signal: [Float] = (0..<3_072).map { index in
                        state = state &* 6_364_136_223_846_793_005 &+ 1
                        let noise = Double(state >> 11) / Double(UInt64.max >> 11) * 2 - 1
                        let time = Double(index + offset) / rate
                        let phase = 2 * Double.pi * frequency * time
                        let guitar = 0.006 * sin(phase) + 0.009 * sin(2 * phase) + 0.004 * sin(3 * phase)
                        let rumble = 0.008 * sin(2 * Double.pi * 78 * time)
                        return Float(guitar + rumble + 0.002 * noise)
                    }
                    let result = try XCTUnwrap(PitchDetector(silenceThreshold: 0.00075).detect(samples: signal, sampleRate: rate))
                    XCTAssertLessThan(abs(1200 * log2(result.frequency / frequency)), 15)
                }
            }
        }
    }

    /// Opt-in replay: decode the supplied recording to mono 48 kHz Float32 PCM
    /// and set TUNER_RECORDING_PCM to its path. Personal audio stays outside Git.
    func testProvidedRecordingUpperStrings() throws {
        guard let path = ProcessInfo.processInfo.environment["TUNER_RECORDING_PCM"] else {
            throw XCTSkip("Set TUNER_RECORDING_PCM to run the real-recording regression")
        }
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let samples = data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        let detector = PitchDetector(silenceThreshold: 0.00075)
        for (start, end, expected) in [(12.2, 14.0, 55.0), (15.0, 17.0, 59.0), (18.0, 21.0, 64.0)] {
            var matching = 0
            var total = 0
            let first = Int(start * sampleRate)
            let last = Int(end * sampleRate)
            XCTAssertGreaterThanOrEqual(samples.count, last + 3_072)
            guard samples.count >= last + 3_072 else { return }
            for offset in stride(from: first, through: last, by: 1_024) {
                total += 1
                if let result = detector.detect(samples: Array(samples[offset..<offset + 3_072]), sampleRate: sampleRate) {
                    let midi = 69 + 12 * log2(result.frequency / 440)
                    if abs(midi - expected) < 0.5 { matching += 1 }
                }
            }
            XCTAssertGreaterThan(Double(matching) / Double(total), 0.80, "MIDI \(expected): \(matching)/\(total)")
        }
    }

    private func sine(frequency: Double, count: Int, amplitude: Double = 0.5) -> [Float] {
        (0..<count).map { index in
            Float(amplitude * sin(2 * .pi * frequency * Double(index) / sampleRate))
        }
    }
}
