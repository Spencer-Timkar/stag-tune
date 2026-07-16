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

    private func sine(frequency: Double, count: Int, amplitude: Double = 0.5) -> [Float] {
        (0..<count).map { index in
            Float(amplitude * sin(2 * .pi * frequency * Double(index) / sampleRate))
        }
    }
}
