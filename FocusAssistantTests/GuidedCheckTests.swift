import XCTest
@testable import FocusAssistant

/// Phase timing and the per-phase log lines. Nothing here speaks, opens a camera or writes a log.
final class GuidedCheckTests: XCTestCase {
    func testPhasesRunScreenThenMoveThenPhoneThenScreen() {
        XCTAssertEqual(GuidedCheck.phases.map(\.name), ["screen", "move", "phone", "screen-again"])
        XCTAssertEqual(GuidedCheck.phases.map(\.kind), [.screen, .setup, .phone, .screen])
        XCTAssertEqual(GuidedCheck.totalSeconds, 62)
    }

    func testBehaviorSuitePhasesCoverIdleTypingQuickReplyAndSustainedPhone() {
        XCTAssertEqual(
            GuidedCheck.phases(for: .behaviorEngine).map(\.name),
            ["screen-idle", "keyboard", "quick-reply", "return-screen", "sustained-phone", "recover"]
        )
        XCTAssertEqual(GuidedCheck.totalSeconds(for: .behaviorEngine), 198)
        XCTAssertEqual(GuidedCheck.phaseIndex(at: 0, suite: .behaviorEngine), 0)
        XCTAssertEqual(GuidedCheck.phaseIndex(at: 30, suite: .behaviorEngine), 2)
        XCTAssertEqual(GuidedCheck.phaseIndex(at: 150, suite: .behaviorEngine), 4)
        XCTAssertEqual(GuidedCheck.phaseIndex(at: 197.9, suite: .behaviorEngine), 5)
        XCTAssertNil(GuidedCheck.phaseIndex(at: 198, suite: .behaviorEngine))
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

    func testBehaviorGuidedSummaryPassesWhenAllExpectationsMet() {
        var summary = BehaviorGuidedSummary()
        let snapshot = SignalSnapshot(time: 10, vision: VisionSignals(), input: InputIdle(keyboard: 20, pointer: 20))
        let facing = ActivityEstimate(posture: .facing, inputActive: false, secondsInState: 5, possiblePhoneUse: false,
                                      tilt: 0, yawOff: 0, eyeRatio: 1)
        let away = ActivityEstimate(posture: .down, inputActive: false, secondsInState: 20, possiblePhoneUse: true,
                                    tilt: 12, yawOff: 2, eyeRatio: 0.7)

        func makeBehavior(state: BehaviorState, duration: Double = 0, pickups: Int = 0,
                          reminder: InterventionEvent? = nil) -> BehaviorSnapshot {
            BehaviorSnapshot(state: state, stateSince: 0, evidenceDuration: duration,
                             graceProgress: min(1, duration / 45.0), recentPickupCount: pickups,
                             episodeID: nil, reasons: [], lastUpdate: 0,
                             pendingIntervention: reminder, cooldownRemaining: 0, breakRemaining: 0)
        }

        summary.add(phase: "screen-idle", phaseElapsed: 10, snapshot: snapshot, estimate: facing,
                    behavior: makeBehavior(state: .observing))
        summary.add(phase: "keyboard", phaseElapsed: 10, snapshot: snapshot, estimate: facing,
                    behavior: makeBehavior(state: .observing))
        summary.add(phase: "quick-reply", phaseElapsed: 28, snapshot: snapshot, estimate: away,
                    behavior: makeBehavior(state: .candidate, duration: 18))
        summary.add(phase: "return-screen", phaseElapsed: 8, snapshot: snapshot, estimate: facing,
                    behavior: makeBehavior(state: .observing, pickups: 1))
        let event = InterventionEvent(episodeID: UUID(), kind: .sustainedEpisode, timestamp: 120,
                                      evidenceDuration: 45.5, recentPickupCount: 2,
                                      reasons: [.awayFromScreen, .idleCorroborated, .sustainedGraceElapsed])
        summary.add(phase: "sustained-phone", phaseElapsed: 49, snapshot: snapshot, estimate: away,
                    behavior: makeBehavior(state: .sustainedPhoneUse, duration: 45.5, pickups: 1, reminder: event))
        summary.add(phase: "recover", phaseElapsed: 5, snapshot: snapshot, estimate: facing,
                    behavior: makeBehavior(state: .cooldown, pickups: 1))

        let report = summary.report()
        XCTAssertTrue(report.allPassed)
        XCTAssertEqual(report.items.map(\.status), [.pass, .pass, .pass, .pass])
        XCTAssertEqual(summary.lines().last,
                       "GUIDED_BEHAVIOR result=pass idle_screen=pass keyboard=pass quick_reply=pass sustained=pass")
    }

    func testBehaviorGuidedSummaryFlagsEarlyOrMissingReminders() {
        var summary = BehaviorGuidedSummary()
        let snapshot = SignalSnapshot(time: 10, vision: VisionSignals(), input: InputIdle(keyboard: 20, pointer: 20))
        let away = ActivityEstimate(posture: .down, inputActive: false, secondsInState: 20, possiblePhoneUse: true,
                                    tilt: 12, yawOff: 2, eyeRatio: 0.7)
        let candidate = BehaviorSnapshot(state: .candidate, stateSince: 0, evidenceDuration: 5,
                                         graceProgress: 0.1, recentPickupCount: 0, episodeID: nil,
                                         reasons: [], lastUpdate: 0, pendingIntervention: nil,
                                         cooldownRemaining: 0, breakRemaining: 0)
        summary.add(phase: "screen-idle", phaseElapsed: 12, snapshot: snapshot, estimate: away, behavior: candidate)
        // Typing has begun in the keyboard step, so a later candidate is a real false trigger.
        let typing = SignalSnapshot(time: 9, vision: VisionSignals(), input: InputIdle(keyboard: 0.5, pointer: 20))
        summary.add(phase: "keyboard", phaseElapsed: 7, snapshot: typing, estimate: away, behavior: candidate)
        summary.add(phase: "keyboard", phaseElapsed: 8, snapshot: snapshot, estimate: away, behavior: candidate)
        summary.add(phase: "quick-reply", phaseElapsed: 20, snapshot: snapshot, estimate: away, behavior: candidate)
        summary.add(phase: "sustained-phone", phaseElapsed: 50, snapshot: snapshot, estimate: away, behavior: candidate)

        let report = summary.report()
        XCTAssertFalse(report.allPassed)
        XCTAssertEqual(report.items.map(\.status), [.fail, .fail, .info, .fail])
        XCTAssertTrue(summary.lines()[1].contains(" away_after_input=2 "))
    }

    func testKeyboardCandidateBeforeFirstInputIsInfoNotFail() {
        // 27 Nov 2026: the step opened while the person was still idle from step 1, a glance at the
        // keyboard read as eyes lowered for about 5 s, and the first mouse move cleared it.
        var summary = BehaviorGuidedSummary()
        let facing = ActivityEstimate(posture: .facing, inputActive: true, secondsInState: 2, possiblePhoneUse: false,
                                      tilt: 0, yawOff: 0, eyeRatio: 1)
        func behavior(_ state: BehaviorState) -> BehaviorSnapshot {
            BehaviorSnapshot(state: state, stateSince: 0, evidenceDuration: 2, graceProgress: 0.05,
                             recentPickupCount: 0, episodeID: nil, reasons: [], lastUpdate: 0,
                             pendingIntervention: nil, cooldownRemaining: 0, breakRemaining: 0)
        }
        let idle = SignalSnapshot(time: 20, vision: VisionSignals(), input: InputIdle(keyboard: 69, pointer: 19))
        let moving = SignalSnapshot(time: 21, vision: VisionSignals(), input: InputIdle(keyboard: 70, pointer: 0))
        summary.add(phase: "keyboard", phaseElapsed: 3.5, snapshot: idle, estimate: facing, behavior: behavior(.candidate))
        summary.add(phase: "keyboard", phaseElapsed: 4.5, snapshot: moving, estimate: facing, behavior: behavior(.observing))

        let keyboard = summary.report().items[1]
        XCTAssertEqual(keyboard.id, "keyboard")
        XCTAssertEqual(keyboard.status, .info)
    }
}
