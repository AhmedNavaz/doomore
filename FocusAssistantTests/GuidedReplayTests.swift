import XCTest
@testable import FocusAssistant

/// Replays the readings logged during the first guided phone check (26 Nov 2026, one person,
/// FaceTime HD Camera, phone held below the camera). Numbers only: no picture or sound was kept.
/// The phase labels are what the app asked for, not what the person was doing at each moment:
/// the head went down about 4 s after the phone cue and came back about 5 s after the screen cue.
/// These tests stop a rule change from silently undoing what worked on real data. They are not
/// an accuracy measurement; one run by one person cannot give one.
final class GuidedReplayTests: XCTestCase {
    /// (seconds since Start, phase, pitch°, yaw°, eye openness, person coverage, keyboard idle s, pointer idle s)
    static let run: [(Double, String, Double, Double, Double, Double, Double, Double)] = [
        (0.6, "screen", 0.9, 5.0, 0.251, 0.22, 18.6, 0.5),
        (1.1, "screen", 0.2, 2.2, 0.249, 0.23, 19.1, 1.0),
        (1.6, "screen", -2.1, -3.6, 0.251, 0.22, 19.6, 1.6),
        (2.1, "screen", -0.8, 2.0, 0.316, 0.22, 20.2, 2.1),
        (2.6, "screen", -1.0, 2.8, 0.272, 0.22, 20.7, 2.6),
        (3.2, "screen", 4.0, 0.3, 0.287, 0.23, 21.2, 3.1),
        (3.7, "screen", 1.1, 0.1, 0.282, 0.23, 21.7, 3.6),
        (4.2, "screen", 1.1, 0.0, 0.290, 0.23, 22.2, 4.1),
        (4.7, "screen", 3.0, -0.8, 0.291, 0.23, 22.7, 4.7),
        (5.2, "screen", -0.7, 1.0, 0.258, 0.23, 23.3, 5.2),
        (5.7, "screen", 1.8, -0.8, 0.260, 0.23, 23.8, 5.7),
        (6.3, "screen", 3.2, -1.1, 0.293, 0.23, 24.3, 6.2),
        (6.8, "screen", -0.1, -0.7, 0.248, 0.23, 24.9, 6.8),
        (7.3, "screen", 0.7, -0.3, 0.268, 0.23, 25.4, 7.3),
        (7.8, "screen", 0.9, -1.8, 0.283, 0.23, 25.9, 7.8),
        (8.4, "screen", 0.6, -2.1, 0.271, 0.23, 26.4, 8.3),
        (8.9, "screen", 2.3, -2.0, 0.291, 0.23, 26.9, 8.9),
        (9.4, "screen", 2.1, -2.5, 0.283, 0.23, 27.4, 9.4),
        (9.9, "screen", 1.8, -3.0, 0.287, 0.23, 28.0, 9.9),
        (10.4, "phone", 0.4, -1.8, 0.288, 0.23, 28.5, 10.4),
        (10.9, "phone", -1.3, -0.7, 0.285, 0.23, 29.0, 10.9),
        (11.4, "phone", -1.0, -1.5, 0.270, 0.22, 29.5, 11.4),
        (12.0, "phone", 1.3, 0.1, 0.225, 0.22, 30.0, 11.9),
        (12.5, "phone", 6.2, -6.7, 0.275, 0.22, 30.5, 12.4),
        (13.0, "phone", 3.3, -5.9, 0.299, 0.21, 31.0, 12.9),
        (13.5, "phone", 7.1, 5.3, 0.281, 0.21, 31.5, 13.4),
        (14.0, "phone", 7.4, 3.0, 0.183, 0.22, 32.1, 14.0),
        (14.5, "phone", 11.5, 3.7, 0.148, 0.22, 32.6, 14.5),
        (15.0, "phone", 9.7, 6.1, 0.168, 0.22, 33.1, 15.0),
        (15.5, "phone", 11.3, 6.4, 0.264, 0.22, 33.6, 15.5),
        (16.1, "phone", 11.0, 6.9, 0.205, 0.22, 34.1, 16.0),
        (16.6, "phone", 11.2, 6.8, 0.203, 0.22, 34.6, 16.5),
        (17.1, "phone", 12.0, 7.5, 0.194, 0.22, 35.1, 17.0),
        (17.6, "phone", 14.1, 8.3, 0.193, 0.22, 35.7, 17.6),
        (18.1, "phone", 14.6, 5.4, 0.179, 0.22, 36.2, 18.1),
        (18.6, "phone", 12.2, 5.8, 0.169, 0.22, 36.7, 18.6),
        (19.2, "phone", 13.5, 7.6, 0.198, 0.22, 37.2, 19.1),
        (19.7, "phone", 12.3, 7.1, 0.216, 0.22, 37.7, 19.6),
        (20.2, "phone", 10.9, 6.9, 0.169, 0.22, 38.2, 20.1),
        (20.7, "phone", 13.2, 6.0, 0.213, 0.22, 38.7, 20.6),
        (21.2, "phone", 12.4, 6.0, 0.231, 0.22, 39.3, 21.2),
        (21.7, "phone", 12.7, 7.9, 0.241, 0.22, 39.8, 21.7),
        (22.2, "phone", 12.0, 6.8, 0.202, 0.22, 40.3, 22.2),
        (22.7, "phone", 12.9, 6.9, 0.204, 0.22, 40.8, 22.7),
        (23.2, "phone", 12.3, 8.2, 0.231, 0.22, 41.3, 23.2),
        (23.7, "phone", 14.9, 6.7, 0.206, 0.22, 41.8, 23.7),
        (24.2, "phone", 12.7, 6.8, 0.217, 0.22, 42.3, 24.2),
        (24.7, "phone", 13.2, 7.8, 0.183, 0.22, 42.8, 24.7),
        (25.3, "screen-again", 13.4, 6.9, 0.136, 0.22, 43.3, 25.2),
        (25.8, "screen-again", 10.4, 4.0, 0.139, 0.22, 43.8, 25.7),
        (26.3, "screen-again", 11.0, 3.4, 0.106, 0.22, 44.3, 26.3),
        (26.8, "screen-again", 10.5, 3.6, 0.130, 0.22, 44.9, 26.8),
        (27.4, "screen-again", 10.4, 2.9, 0.119, 0.22, 45.4, 27.3),
        (27.9, "screen-again", 10.7, 5.0, 0.119, 0.22, 45.9, 27.8),
        (28.4, "screen-again", 13.1, 5.7, 0.121, 0.22, 46.4, 28.4),
        (28.9, "screen-again", 13.2, 6.1, 0.131, 0.22, 46.9, 28.9),
        (29.4, "screen-again", 8.5, 2.6, 0.215, 0.22, 47.5, 29.4),
        (29.9, "screen-again", 2.9, -2.2, 0.306, 0.21, 48.0, 29.9),
        (30.5, "screen-again", 0.6, -0.8, 0.237, 0.22, 48.5, 30.4),
        (31.0, "screen-again", 0.1, 3.1, 0.277, 0.22, 49.0, 31.0),
        (31.5, "screen-again", 3.3, 5.9, 0.297, 0.22, 49.5, 31.5),
        (32.0, "screen-again", 3.9, 5.3, 0.309, 0.22, 50.1, 32.0),
        (32.6, "screen-again", 4.5, 3.5, 0.306, 0.22, 50.6, 32.5),
        (33.1, "screen-again", 4.2, 2.3, 0.292, 0.22, 51.1, 33.0),
        (33.6, "screen-again", 0.2, 1.3, 0.251, 0.22, 51.6, 33.6),
        (34.1, "screen-again", 1.5, 0.4, 0.257, 0.22, 52.1, 34.1),
        (34.6, "screen-again", 5.6, 0.4, 0.292, 0.22, 52.6, 34.6),
    ]

    /// Phase starts in that run, from the first and last sample of each phase. It used 10 s, 15 s and 10 s phases.
    static let phaseStart = ["screen": 0.3, "phone": 10.3, "screen-again": 25.3]

    private func replay() -> [(time: Double, phase: String, estimate: ActivityEstimate)] {
        var estimator = ActivityEstimator()
        return Self.run.map { row in
            var vision = VisionSignals()
            vision.faceCount = 1
            vision.head = HeadPose(pitch: row.2, yaw: row.3, roll: 0)
            vision.eyeOpenness = row.4
            vision.personCoverage = row.5
            let snapshot = SignalSnapshot(time: row.0, vision: vision, input: InputIdle(keyboard: row.6, pointer: row.7))
            return (row.0, row.1, estimator.update(snapshot))
        }
    }

    func testFacingTheScreenWithoutTypingIsNeverFlagged() {
        let screen = replay().filter { $0.phase == "screen" }
        XCTAssertEqual(screen.count, 19)
        XCTAssertFalse(screen.contains { $0.estimate.possiblePhoneUse })
        XCTAssertFalse(screen.contains { $0.estimate.posture.isAway })
    }

    func testHeadDownAtThePhoneIsSeenWithinASample() {
        // Pitch first reached +11.8° above straight-ahead at 14.5 s.
        let firstAway = replay().first { $0.estimate.posture.isAway }
        XCTAssertEqual(firstAway?.time ?? 0, 14.5, accuracy: 0.6)
    }

    func testMostOfThePhonePhaseIsFlaggedOnceSettled() {
        let settled = replay().filter { $0.phase == "phone" && $0.time - Self.phaseStart["phone"]! >= GuidedCheck.settleSeconds }
        let share = Double(settled.filter { $0.estimate.possiblePhoneUse }.count) / Double(settled.count)
        XCTAssertGreaterThanOrEqual(share, 0.75, "the guess needs about 3.5 s of the 8 s window to switch on")
    }

    func testTheGuessClearsSoonAfterTheHeadComesBackUp() {
        let samples = replay()
        // The last sample with the head down was at 29.4 s; at 29.9 s it faced the screen again.
        let afterReturn = samples.filter { $0.time >= 29.4 + ActivityEstimator.Rules().returnSeconds }
        XCTAssertFalse(afterReturn.isEmpty)
        XCTAssertFalse(afterReturn.contains { $0.estimate.possiblePhoneUse },
                       "before 26 Nov the guess lingered until 34.1 s")
    }
}
