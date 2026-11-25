import XCTest
@testable import FocusAssistant

/// Checks the rules as written, using synthetic samples. These tests say nothing about
/// how well the rules or their thresholds match what a real person does.
final class ActivityEstimatorTests: XCTestCase {
    private func sample(_ time: Double, pitch: Double? = 5, yaw: Double? = 0, eyes: Double? = nil,
                        face: Bool = true, person: Bool = true,
                        keyboardIdle: Double = 60, pointerIdle: Double = 60) -> SignalSnapshot {
        var vision = VisionSignals()
        if face {
            vision.faceCount = 1
            vision.head = HeadPose(pitch: pitch, yaw: yaw, roll: 0)
            vision.eyeOpenness = eyes
        }
        vision.personCoverage = person ? 0.3 : 0
        return SignalSnapshot(time: time, vision: vision, input: InputIdle(keyboard: keyboardIdle, pointer: pointerIdle))
    }

    /// Six straight-ahead samples at 0, 0.5 … 2.5 s, which is the default calibration length.
    private func calibrated(pitch: Double = 5, yaw: Double = 0, eyes: Double? = nil) -> ActivityEstimator {
        var estimator = ActivityEstimator()
        for step in 0..<6 { _ = estimator.update(sample(Double(step) * 0.5, pitch: pitch, yaw: yaw, eyes: eyes)) }
        return estimator
    }

    /// Feeds one sample every half second from `start` up to and including `end`.
    private func feed(_ estimator: inout ActivityEstimator, from start: Double, through end: Double,
                      _ make: (Double) -> SignalSnapshot) -> [ActivityEstimate] {
        stride(from: start, through: end, by: 0.5).map { estimator.update(make($0)) }
    }

    // MARK: Straight-ahead

    func testLearnsStraightAheadFromFirstFaceSamplesThenReportsFacing() {
        var estimator = ActivityEstimator()
        for step in 0..<5 {
            let estimate = estimator.update(sample(Double(step) * 0.5, pitch: 8, yaw: -2, eyes: 0.3))
            XCTAssertEqual(estimate.posture, .calibrating)
            XCTAssertNil(estimator.baseline)
            XCTAssertFalse(estimate.possiblePhoneUse)
        }
        _ = estimator.update(sample(2.5, pitch: 8, yaw: -2, eyes: 0.3))
        XCTAssertEqual(estimator.baseline, ActivityEstimator.Baseline(pitch: 8, yaw: -2, eyeOpenness: 0.3))

        let settled = estimator.update(sample(3.0, pitch: 8, yaw: -2, eyes: 0.3))
        XCTAssertEqual(settled.posture, .facing)
        XCTAssertEqual(settled.tilt ?? .nan, 0, accuracy: 0.0001)
        XCTAssertEqual(settled.eyeRatio ?? .nan, 1, accuracy: 0.0001)
        XCTAssertFalse(settled.inputActive)
    }

    func testCalibrationWaitsForAFace() {
        var estimator = ActivityEstimator()
        for step in 0..<10 { _ = estimator.update(sample(Double(step) * 0.5, face: false)) }
        XCTAssertNil(estimator.baseline)
    }

    func testRecalibrateLearnsANewStraightAhead() {
        var estimator = calibrated(pitch: 5)
        estimator.recalibrate()
        XCTAssertNil(estimator.baseline)

        let estimates = feed(&estimator, from: 3.0, through: 6.0) { self.sample($0, pitch: 25) }
        XCTAssertEqual(estimator.baseline?.pitch, 25)
        XCTAssertEqual(estimates.last?.posture, .facing, "the new position is now straight-ahead")
    }

    // MARK: Posture

    func testOnlyDownwardTiltCountsAsDown() {
        // Pitch rises when the head goes down (confirmed in the 26 Nov 2026 guided check).
        // Upward tilt while facing the screen again must not count as away.
        for (pitch, expected) in [(13.0, Posture.down), (-5.0, .facing), (12.0, .facing), (-2.0, .facing)] {
            var estimator = calibrated(pitch: 5)
            let estimates = feed(&estimator, from: 3.0, through: 4.0) { self.sample($0, pitch: pitch) }
            XCTAssertEqual(estimates.last?.posture, expected, "pitch \(pitch)")
            XCTAssertEqual(estimates.last?.tilt ?? .nan, pitch - 5, accuracy: 0.0001)
        }
    }

    func testTiltIsRelativeToTheLearnedPositionNotToZero() {
        // A camera that looks up at the face reports a steady offset; only the change counts.
        var estimator = calibrated(pitch: 20)
        let slightly = feed(&estimator, from: 3.0, through: 4.0) { self.sample($0, pitch: 26) }
        XCTAssertEqual(slightly.last?.posture, .facing)

        let clearly = feed(&estimator, from: 4.5, through: 5.5) { self.sample($0, pitch: 30) }
        XCTAssertEqual(clearly.last?.posture, .down)
    }

    func testEyesLoweredWithoutHeadMovementCountsAsDown() {
        var estimator = calibrated(eyes: 0.32)
        let lowered = feed(&estimator, from: 3.0, through: 4.0) { self.sample($0, eyes: 0.22) }
        XCTAssertEqual(lowered.last?.posture, .down)
        XCTAssertEqual(lowered.last?.eyeRatio ?? .nan, 0.22 / 0.32, accuracy: 0.0001)

        let open = feed(&estimator, from: 4.5, through: 5.5) { self.sample($0, eyes: 0.27) }
        XCTAssertEqual(open.last?.posture, .facing, "84% as open is not lowered")
    }

    func testMissingAnglesAndEyesNeverReportAway() {
        var estimator = calibrated()
        let estimates = feed(&estimator, from: 3.0, through: 10.0) { self.sample($0, pitch: nil, yaw: nil, eyes: nil) }
        XCTAssertEqual(estimates.last?.posture, .facing)
        XCTAssertNil(estimates.last?.tilt)
        XCTAssertNil(estimates.last?.eyeRatio)
        XCTAssertFalse(estimates.contains { $0.possiblePhoneUse })
    }

    func testTurnedIsMeasuredFromTheLearnedYawInEitherDirection() {
        for (yaw, expected) in [(45.0, Posture.turned), (-15.0, .turned), (28.0, .facing)] {
            var estimator = calibrated(yaw: 10)
            let estimates = feed(&estimator, from: 3.0, through: 4.0) { self.sample($0, pitch: 5, yaw: yaw) }
            XCTAssertEqual(estimates.last?.posture, expected, "yaw \(yaw)")
        }
    }

    func testSmallPersonCoverageWithoutAFaceCountsAsNobody() {
        var estimator = calibrated()
        var vision = VisionSignals()
        vision.personCoverage = 0.04 // Below the 0.05 rule.
        let estimates = feed(&estimator, from: 3.0, through: 12.0) {
            SignalSnapshot(time: $0, vision: vision, input: InputIdle(keyboard: 60, pointer: 60))
        }
        XCTAssertEqual(estimates.last?.posture, .nobody)
        XCTAssertFalse(estimates.contains { $0.possiblePhoneUse })
    }

    func testOneOddSampleDoesNotRestartTheTimer() {
        var estimator = calibrated()
        let estimates = feed(&estimator, from: 3.0, through: 8.0) { time in
            time == 6.0 ? self.sample(time, pitch: 5) : self.sample(time, pitch: 25)
        }
        XCTAssertEqual(estimates[6].posture, .down, "a single straight-ahead sample is ignored")
        XCTAssertEqual(estimates[10].secondsInState, 5.0, accuracy: 0.0001)
    }

    func testTwoSamplesOfANewStateDoReplaceTheOldOne() {
        var estimator = calibrated()
        _ = feed(&estimator, from: 3.0, through: 9.0) { self.sample($0, pitch: 25) }
        let back = feed(&estimator, from: 9.5, through: 10.0) { self.sample($0, pitch: 5) }

        XCTAssertEqual(back[1].posture, .facing)
        XCTAssertEqual(back[1].secondsInState, 0.5, accuracy: 0.0001)
    }

    // MARK: Possible phone use

    func testPhoneGuessWaitsForFiveSecondsWithoutKeyboardOrMouse() {
        var estimator = calibrated()
        // Typing stops at 3.0 s, the moment the head goes down.
        let estimates = feed(&estimator, from: 3.0, through: 9.0) { self.sample($0, pitch: 25, keyboardIdle: $0 - 3.0) }
        XCTAssertFalse(estimates[9].possiblePhoneUse, "4.5 s idle must not be flagged")
        XCTAssertTrue(estimates[10].possiblePhoneUse, "5.0 s idle with the head away is flagged")
        XCTAssertEqual(estimates[10].key, "down-idle")
    }

    func testPhoneGuessNeedsHalfOfTheRecentWindowAway() {
        var estimator = calibrated()
        // Input has been idle all along, so only the window decides. Six facing samples came first.
        let estimates = feed(&estimator, from: 3.0, through: 8.0) { self.sample($0, pitch: 25) }
        XCTAssertFalse(estimates[4].possiblePhoneUse, "5 of 11 samples away")
        XCTAssertEqual(estimates[4].awayShare, 5.0 / 11.0, accuracy: 0.0001)
        XCTAssertTrue(estimates[5].possiblePhoneUse, "6 of 12 samples away")
    }

    func testHeadBobbingBetweenPhoneAndScreenIsStillFlagged() {
        var estimator = calibrated()
        // 1.5 s away, 0.5 s back at the screen, repeated: the held state flips but the window does not.
        let estimates = feed(&estimator, from: 3.0, through: 15.0) { time in
            (time - 3.0).truncatingRemainder(dividingBy: 2) < 1.5 ? self.sample(time, pitch: 25) : self.sample(time, pitch: 5)
        }
        XCTAssertTrue(estimates.suffix(8).allSatisfy(\.possiblePhoneUse))
    }

    func testPhoneGuessFadesAfterLookingBackAtTheScreen() {
        var estimator = calibrated()
        let away = feed(&estimator, from: 3.0, through: 9.0) { self.sample($0, pitch: 25) }
        XCTAssertTrue(away.last?.possiblePhoneUse == true)

        let back = feed(&estimator, from: 9.5, through: 14.0) { self.sample($0, pitch: 5) }
        XCTAssertTrue(back[0].possiblePhoneUse, "one glance back does not clear it")
        XCTAssertFalse(back.last?.possiblePhoneUse ?? true, "cleared once most of the window faces the screen")
    }

    func testPhoneGuessClearsAfterFacingTheScreenForReturnSeconds() {
        // The window is still mostly away; only the time since the head came back decides.
        var estimator = calibrated()
        _ = feed(&estimator, from: 3.0, through: 12.0) { self.sample($0, pitch: 25) }
        let back = feed(&estimator, from: 12.5, through: 14.0) { self.sample($0, pitch: 5) }
        XCTAssertTrue(back[1].possiblePhoneUse, "1.0 s back: still flagged")
        XCTAssertFalse(back[2].possiblePhoneUse, "1.5 s back: cleared")
        XCTAssertGreaterThanOrEqual(back[2].awayShare, 0.5)
    }

    func testLookingDownWhileUsingKeyboardIsNeverFlagged() {
        var estimator = calibrated()
        let estimates = feed(&estimator, from: 3.0, through: 23.0) { self.sample($0, pitch: 30, keyboardIdle: 0.4) }
        XCTAssertEqual(estimates[1].posture, .down)
        XCTAssertEqual(estimates.last?.inputActive, true)
        XCTAssertFalse(estimates.contains { $0.possiblePhoneUse })
    }

    func testStraightAheadIsRelearnedWhileTyping() {
        // The person shifts a little in the chair and types facing the screen from the new position.
        var estimator = calibrated(yaw: 0)
        _ = feed(&estimator, from: 3.0, through: 8.0) { self.sample($0, yaw: 8, keyboardIdle: 0.4) }
        XCTAssertEqual(estimator.baseline?.yaw, 8)

        // Facing the screen from the new position without input is not "turned".
        let idle = feed(&estimator, from: 8.5, through: 20.0) { self.sample($0, yaw: 8, keyboardIdle: $0 - 8.0) }
        XCTAssertFalse(idle.contains { $0.possiblePhoneUse })
        XCTAssertEqual(estimator.baseline?.yaw, 8, "idle samples do not move straight-ahead")
    }

    func testLargeTurnWhileTouchingTheKeyboardIsNotLearnedAsStraightAhead() {
        // 26 Nov 2026: the reference was dragged toward a phone position (+8.6° while the head was near +20°).
        var estimator = calibrated(yaw: 0)
        _ = feed(&estimator, from: 3.0, through: 12.0) { self.sample($0, yaw: 22, keyboardIdle: 0.4) }
        XCTAssertEqual(estimator.baseline?.yaw, 0)
    }

    func testSecondsJustAfterTypingDoNotTeachStraightAhead() {
        // Typing stops at 3.0 s and the head turns at once; input still reads "active" until 6.0 s.
        var estimator = calibrated(yaw: 0)
        let estimates = feed(&estimator, from: 3.0, through: 12.0) { self.sample($0, yaw: 30, keyboardIdle: $0 - 3.0) }
        XCTAssertEqual(estimator.baseline?.yaw, 0)
        XCTAssertEqual(estimates.last?.posture, .turned)
        XCTAssertTrue(estimates.last?.possiblePhoneUse == true)
    }

    func testRelearningCanBeTurnedOff() {
        var estimator = ActivityEstimator(rules: { var r = ActivityEstimator.Rules(); r.relearnSeconds = 0; return r }())
        _ = feed(&estimator, from: 0.0, through: 2.5) { self.sample($0, yaw: 0) }
        _ = feed(&estimator, from: 3.0, through: 8.0) { self.sample($0, yaw: 22, keyboardIdle: 0.4) }
        XCTAssertEqual(estimator.baseline?.yaw, 0)
    }

    func testPointerUseAloneCountsAsInput() {
        var estimator = calibrated()
        let estimates = feed(&estimator, from: 3.0, through: 12.0) { self.sample($0, pitch: 30, pointerIdle: 1) }
        XCTAssertFalse(estimates.contains { $0.possiblePhoneUse })
    }

    func testHiddenFaceWithPersonInViewCountsAsAway() {
        var estimator = calibrated()
        let estimates = feed(&estimator, from: 3.0, through: 8.0) { self.sample($0, face: false, person: true) }
        XCTAssertEqual(estimates[10].posture, .hidden)
        XCTAssertTrue(estimates[10].possiblePhoneUse)
        XCTAssertNil(estimates[10].tilt)
    }

    func testTurnedWithIdleInputCountsAsAway() {
        // Measured on 25 Nov 2026: a phone held off to one side turned the head 33–44°.
        var estimator = calibrated()
        let estimates = feed(&estimator, from: 3.0, through: 10.0) { self.sample($0, yaw: 40) }
        XCTAssertEqual(estimates.last?.posture, .turned)
        XCTAssertTrue(estimates.last?.possiblePhoneUse == true)
    }

    func testNobodyInViewIsNeverFlagged() {
        var estimator = calibrated()
        let estimates = feed(&estimator, from: 3.0, through: 20.0) { self.sample($0, face: false, person: false) }
        XCTAssertEqual(estimates.last?.posture, .nobody)
        XCTAssertFalse(estimates.contains { $0.possiblePhoneUse })
    }

    func testLeavingRightAfterLookingAwayIsNotFlagged() {
        var estimator = calibrated()
        _ = feed(&estimator, from: 3.0, through: 9.0) { self.sample($0, pitch: 25) }
        let gone = estimator.update(sample(9.5, face: false, person: false))
        XCTAssertFalse(gone.possiblePhoneUse, "the window is still mostly away, but nobody is there now")
    }

    func testRecalibrateForgetsTheRecentWindow() {
        var estimator = calibrated()
        _ = feed(&estimator, from: 3.0, through: 9.0) { self.sample($0, pitch: 25) }
        estimator.recalibrate()
        let estimate = estimator.update(sample(9.5, face: false, person: true))
        XCTAssertFalse(estimate.possiblePhoneUse, "a fresh window spans less than half of eight seconds")
    }

    // MARK: Helpers

    func testMedianIgnoresNonFiniteValues() {
        XCTAssertEqual(ActivityEstimator.median([3, .nan, 1, .infinity, 2]), 2)
        XCTAssertEqual(ActivityEstimator.median([4, 1, 3, 2]), 2.5)
        XCTAssertNil(ActivityEstimator.median([]))
        XCTAssertNil(ActivityEstimator.median([.nan]))
    }

    func testHeadPoseConvertsRadiansAndDropsNonFiniteAngles() {
        let pose = HeadPose(radiansPitch: .pi / 6, yaw: -.pi / 2, roll: .nan)
        XCTAssertEqual(pose.pitch ?? .nan, 30, accuracy: 0.0001)
        XCTAssertEqual(pose.yaw ?? .nan, -90, accuracy: 0.0001)
        XCTAssertNil(pose.roll)
        XCTAssertNil(HeadPose(radiansPitch: nil, yaw: nil, roll: nil).pitch)
    }
}
