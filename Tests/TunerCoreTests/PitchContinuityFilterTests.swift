import XCTest
@testable import TunerCore

final class PitchContinuityFilterTests: XCTestCase {
    func testAcquiresWithBatchedMicrophoneCallbacks() {
        for interval in [0.10, 0.128, 0.186, 0.256] {
            var filter = PitchContinuityFilter()
            XCTAssertFalse(filter.accept(midiNote: 64, trackedNote: nil, confidence: 0.9, time: 0))
            XCTAssertFalse(filter.accept(midiNote: 64, trackedNote: nil, confidence: 0.9, time: interval))
            XCTAssertTrue(filter.accept(midiNote: 64, trackedNote: nil, confidence: 0.9, time: 2 * interval), "Callback interval: \(interval)")
        }
    }

    func testAcquisitionNeedsConsecutiveEvidence() {
        var filter = PitchContinuityFilter()
        XCTAssertFalse(filter.accept(midiNote: 64, trackedNote: nil, confidence: 0.9, time: 0))
        XCTAssertFalse(filter.accept(midiNote: 64, trackedNote: nil, confidence: 0.9, time: 0.025))
        XCTAssertTrue(filter.accept(midiNote: 64, trackedNote: nil, confidence: 0.9, time: 0.05))
    }

    func testBriefSubharmonicDoesNotReplaceBString() {
        var filter = PitchContinuityFilter()
        for frame in 0..<6 {
            XCTAssertFalse(filter.accept(midiNote: 40, trackedNote: 59, confidence: 0.8, time: Double(frame) * 0.022))
        }
        XCTAssertTrue(filter.accept(midiNote: 59.1, trackedNote: 59, confidence: 0.8, time: 0.15))
    }

    func testRealStringChangeIsAcceptedWithinTwoTenthsOfASecond() {
        var filter = PitchContinuityFilter()
        var accepted = false
        for frame in 0...9 {
            accepted = filter.accept(midiNote: 64, trackedNote: 40, confidence: 0.9, time: Double(frame) * 0.022)
        }
        XCTAssertTrue(accepted)
    }

    func testDropoutsAndRejectedFramesBreakConfirmation() {
        var filter = PitchContinuityFilter()
        for frame in 0..<20 {
            let note: Double? = frame.isMultiple(of: 3) ? nil : 40
            XCTAssertFalse(filter.accept(midiNote: note, trackedNote: 59, confidence: 0.9, time: Double(frame) * 0.022))
        }
        filter.reset()
        XCTAssertFalse(filter.accept(midiNote: 40, trackedNote: 59, confidence: 0.9, time: 1))
        XCTAssertFalse(filter.accept(midiNote: 40, trackedNote: 59, confidence: 0.9, time: 1.6))
        XCTAssertFalse(filter.accept(midiNote: 40, trackedNote: 59, confidence: 0.9, time: 1.62))
    }

    func testContinuousTuningMovementHasNoConfirmationDelay() {
        var filter = PitchContinuityFilter()
        for frame in 0..<20 {
            let tracked = 63.8 + Double(frame) * 0.03
            XCTAssertTrue(filter.accept(midiNote: tracked + 0.03, trackedNote: tracked, confidence: 0.8, time: Double(frame) * 0.022))
        }
    }
}
