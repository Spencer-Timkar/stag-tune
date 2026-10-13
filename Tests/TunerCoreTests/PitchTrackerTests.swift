import XCTest
@testable import TunerCore

final class PitchTrackerTests: XCTestCase {
    private let note = PitchObservation(frequency: 329.6276, confidence: 0.9, amplitude: 0.004)

    func testIdleTimerDoesNotEraseFirstNoteAtPhoneCallbackRates() throws {
        for interval in [0.021333, 0.10, 0.128, 0.186, 0.256] {
            var tracker = PitchTracker()
            var nextTick = 0.0
            var reading: PitchObservation?
            for frame in 0..<8 {
                let time = 2 + Double(frame) * interval
                while nextTick <= time {
                    XCTAssertFalse(tracker.expire(at: nextTick))
                    nextTick += 0.1
                }
                reading = tracker.consume(note, windowRMS: 0.004, time: time)
            }
            XCTAssertEqual(try XCTUnwrap(reading).frequency, note.frequency, accuracy: 0.01)
        }
    }

    func testReleaseHappensOnceAndDoesNotPreventReacquisition() throws {
        var tracker = PitchTracker()
        for time in [0.0, 0.186, 0.372] {
            _ = tracker.consume(note, windowRMS: 0.004, time: time)
        }
        XCTAssertNotNil(tracker.smoothedMIDINote)
        XCTAssertFalse(tracker.expire(at: 1.5))
        XCTAssertTrue(tracker.expire(at: 1.7))
        XCTAssertNil(tracker.smoothedMIDINote)
        XCTAssertFalse(tracker.expire(at: 1.8))
        XCTAssertNil(tracker.consume(note, windowRMS: 0.004, time: 2))
        XCTAssertFalse(tracker.expire(at: 2.1))
        XCTAssertNil(tracker.consume(note, windowRMS: 0.004, time: 2.186))
        XCTAssertFalse(tracker.expire(at: 2.2))
        XCTAssertNotNil(tracker.consume(note, windowRMS: 0.004, time: 2.372))
    }

    func testSilenceDoesNotCreateAReading() {
        var tracker = PitchTracker()
        for frame in 0..<100 {
            let time = Double(frame) * 0.186
            XCTAssertNil(tracker.consume(nil, windowRMS: 0.0001, time: time))
            XCTAssertFalse(tracker.expire(at: time))
        }
        XCTAssertNil(tracker.smoothedMIDINote)
    }

    func testResetAllowsAnotherNoteAndReferencePitch() throws {
        var tracker = PitchTracker()
        for time in [0.0, 0.186, 0.372] {
            _ = tracker.consume(note, windowRMS: 0.004, time: time)
        }
        tracker.reset()
        XCTAssertNil(tracker.smoothedMIDINote)
        let other = PitchObservation(frequency: 442, confidence: 0.9, amplitude: 0.004)
        for time in [1.0, 1.186, 1.372] {
            _ = tracker.consume(other, windowRMS: 0.004, time: time, referencePitch: 442)
        }
        XCTAssertEqual(try XCTUnwrap(tracker.smoothedMIDINote), 69, accuracy: 0.001)
    }

    func testReferencePitchChangeKeepsTheHeldNote() throws {
        var tracker = PitchTracker()
        for time in [0.0, 0.186, 0.372] {
            _ = tracker.consume(note, windowRMS: 0.004, time: time)
        }
        XCTAssertEqual(try XCTUnwrap(tracker.smoothedMIDINote), 64, accuracy: 0.001)

        let remapped = 69 + 12 * log2(note.frequency / 442)
        tracker.retune(referencePitch: 442)
        XCTAssertEqual(try XCTUnwrap(tracker.smoothedMIDINote), remapped, accuracy: 0.001)

        // The same note must keep displaying: a reference change may not cost a
        // fresh acquisition, which the confirmation delay would otherwise impose.
        let afterRetune = try XCTUnwrap(
            tracker.consume(note, windowRMS: 0.004, time: 0.558, referencePitch: 442)
        )
        XCTAssertEqual(afterRetune.frequency, note.frequency, accuracy: 0.5)
        XCTAssertEqual(try XCTUnwrap(tracker.smoothedMIDINote), remapped, accuracy: 0.05)
    }

    func testRetuneBeforeAnyReadingIsHarmless() {
        var tracker = PitchTracker()
        tracker.retune(referencePitch: 442)
        XCTAssertNil(tracker.smoothedMIDINote)
        tracker.retune(referencePitch: .nan)
        XCTAssertNil(tracker.smoothedMIDINote)
    }

    func testInvalidObservationDoesNotReachDisplay() {
        var tracker = PitchTracker()
        for frequency in [Double.nan, .infinity, 0, -1] {
            let invalid = PitchObservation(frequency: frequency, confidence: 1, amplitude: 0.004)
            XCTAssertNil(tracker.consume(invalid, windowRMS: 0.004, time: 0))
        }
    }

    func testRecordedAudioThroughTrackerAndIdleTimerAtBatchedCadence() throws {
        guard let path = ProcessInfo.processInfo.environment["TUNER_RECORDING_PCM"] else {
            throw XCTSkip("Set TUNER_RECORDING_PCM for the live-pipeline replay")
        }
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let samples = data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        let rate = 48_000.0
        for hop in [1_024, 4_800, 8_192] {
            let detector = PitchDetector(silenceThreshold: 0.00075)
            var refiner = PhasePitchRefiner()
            var tracker = PitchTracker()
            var nextTick = 0.0
            var matching = [0, 0, 0]
            var totals = [0, 0, 0]
            for start in stride(from: 0, through: samples.count - 3_072, by: hop) {
                let time = Double(start + 3_072) / rate
                while nextTick <= time {
                    tracker.expire(at: nextTick)
                    nextTick += 0.1
                }
                let frame = Array(samples[start..<start + 3_072])
                let rms = sqrt(frame.reduce(0.0) { $0 + Double($1 * $1) } / Double(frame.count))
                let observation = detector.detect(samples: frame, sampleRate: rate).map {
                    refiner.refine(observation: $0, samples: frame, sampleRate: rate, advanceSamples: hop)
                }
                if observation == nil { refiner.reset() }
                _ = tracker.consume(observation, windowRMS: rms, time: time)
                for (index, interval) in [(12.5, 14.0, 55.0), (15.3, 17.0, 59.0), (18.3, 21.0, 64.0)].enumerated() {
                    if time >= interval.0, time < interval.1 {
                        totals[index] += 1
                        if let midi = tracker.smoothedMIDINote, abs(midi - interval.2) < 0.5 {
                            matching[index] += 1
                        }
                    }
                }
            }
            for index in 0..<3 {
                XCTAssertGreaterThan(Double(matching[index]) / Double(totals[index]), 0.7, "hop=\(hop), section=\(index), matching=\(matching[index])/\(totals[index])")
            }
        }
    }
}
