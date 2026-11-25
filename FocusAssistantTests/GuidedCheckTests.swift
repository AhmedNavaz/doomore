import XCTest
@testable import FocusAssistant

/// Phase timing and the per-phase log lines. Nothing here speaks, opens a camera or writes a log.
final class GuidedCheckTests: XCTestCase {
    func testPhasesRunScreenThenMoveThenPhoneThenScreen() {
        XCTAssertEqual(GuidedCheck.phases.map(\.name), ["screen", "move", "phone", "screen-again"])
        XCTAssertEqual(GuidedCheck.phases.map(\.kind), [.screen, .setup, .phone, .screen])
        XCTAssertEqual(GuidedCheck.totalSeconds, 62)
    }

    func testPhaseIndexFollowsElapsedTime() {
        let cases: [(Double, Int?)] = [(0, 0), (11.99, 0), (12, 1), (26.9, 1), (27, 2), (46.9, 2),
                                       (47, 3), (61.9, 3), (62, nil), (-0.1, nil), (.nan, nil), (.infinity, nil)]
        for (elapsed, expected) in cases {
            XCTAssertEqual(GuidedCheck.phaseIndex(at: elapsed), expected, "elapsed \(elapsed)")
        }
    }

    func testTheFirstFiveSecondsOfEachPhaseAreNotScored() {
        let cases: [(Double, Bool)] = [(0, false), (4.9, false), (5, true), (11.9, true),
                                       (12, false), (16.9, false), (17, true), (26.9, true),
                                       (27, false), (31.9, false), (32, true), (46.9, true),
                                       (47, false), (51.9, false), (52, true), (61.9, true),
                                       (62, false), (-1, false), (.nan, false)]
        for (elapsed, expected) in cases {
            XCTAssertEqual(GuidedCheck.isScored(at: elapsed), expected, "elapsed \(elapsed)")
        }
    }

    func testSummaryReportsEachPhaseAndTheResult() {
        func snapshot(face: Bool) -> SignalSnapshot {
            var vision = VisionSignals()
            vision.faceCount = face ? 1 : 0
            return SignalSnapshot(time: 0, vision: vision, input: InputIdle(keyboard: 60, pointer: 60))
        }
        let facing = ActivityEstimate(posture: .facing, inputActive: false, secondsInState: 1, possiblePhoneUse: false,
                                      tilt: 2, yawOff: 1, eyeRatio: 1.0)
        let away = ActivityEstimate(posture: .down, inputActive: false, secondsInState: 6, possiblePhoneUse: true,
                                    tilt: -12, yawOff: 3, eyeRatio: 0.7)
        let hidden = ActivityEstimate(posture: .hidden, inputActive: false, secondsInState: 1, possiblePhoneUse: false,
                                      tilt: nil, yawOff: nil, eyeRatio: nil)
        var summary = GuidedSummary()
        summary.add(phase: "screen", scored: true, snapshot: snapshot(face: true), estimate: facing)
        summary.add(phase: "screen", scored: false, snapshot: snapshot(face: true), estimate: away)
        summary.add(phase: "phone", scored: true, snapshot: snapshot(face: true), estimate: away)
        summary.add(phase: "phone", scored: true, snapshot: snapshot(face: false), estimate: hidden)
        // The move phase is logged but never counts toward either score.
        summary.add(phase: "move", scored: true, snapshot: snapshot(face: true), estimate: away)

        XCTAssertEqual(summary.lines(), [
            "GUIDED phase=screen samples=2 face=2 away=0.50 phone_guess=0.50 idle=1.00"
                + " scored=1 away_scored=0.00 phone_guess_scored=0.00"
                + " tilt_min_mean_max=-12.0/-5.0/+2.0 turn_mean_max=2.0/3.0 eyes_min_mean_max=0.70/0.85/1.00",
            "GUIDED phase=move samples=1 face=1 away=1.00 phone_guess=1.00 idle=1.00"
                + " scored=1 away_scored=1.00 phone_guess_scored=1.00"
                + " tilt_min_mean_max=-12.0/-12.0/-12.0 turn_mean_max=3.0/3.0 eyes_min_mean_max=0.70/0.70/0.70",
            "GUIDED phase=phone samples=2 face=1 away=1.00 phone_guess=0.50 idle=1.00"
                + " scored=2 away_scored=1.00 phone_guess_scored=0.50"
                + " tilt_min_mean_max=-12.0/-12.0/-12.0 turn_mean_max=3.0/3.0 eyes_min_mean_max=0.70/0.70/0.70",
            "GUIDED phase=screen-again samples=0",
            "GUIDED result settle_seconds=5 phone_guess_while_on_phone=0.50 phone_guess_while_facing_screen=0.00"
        ])
    }

    func testSummaryWithoutSamplesSaysSo() {
        XCTAssertEqual(GuidedSummary().lines().last,
                       "GUIDED result settle_seconds=5 phone_guess_while_on_phone=n/a phone_guess_while_facing_screen=n/a")
    }
}
