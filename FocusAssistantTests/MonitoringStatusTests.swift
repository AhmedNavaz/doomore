import XCTest
@testable import FocusAssistant

final class MonitoringStatusTests: XCTestCase {
    private func status(_ configure: (inout MonitoringStatus.Inputs) -> Void) -> MonitoringStatus {
        var inputs = MonitoringStatus.Inputs()
        configure(&inputs)
        return MonitoringStatus.make(inputs)
    }

    private func running(_ state: BehaviorState, _ reasons: [BehaviorReason] = []) -> MonitoringStatus {
        status {
            $0.wantsMonitoring = true
            $0.cameraRequested = true
            $0.cameraCapturing = true
            $0.behavior = state
            $0.reasons = reasons
        }
    }

    func testOffByDefault() {
        XCTAssertEqual(status { _ in }.kind, .off)
    }

    func testProblemShownAfterMonitoringEndedOnItsOwn() {
        let value = status { $0.problem = "Camera permission denied" }
        XCTAssertEqual(value.kind, .unavailable)
        XCTAssertEqual(value.line, "Camera permission denied")
    }

    func testBreakOutranksEverythingAndRoundsMinutesUp() {
        let value = status {
            $0.wantsMonitoring = true
            $0.userPaused = true
            $0.breakSecondsLeft = 61
        }
        XCTAssertEqual(value.kind, .paused)
        XCTAssertEqual(value.line, "On break · 2 min left · camera off")
    }

    func testPauseAndLockArePausedNotUnavailable() {
        XCTAssertEqual(status { $0.wantsMonitoring = true; $0.userPaused = true }.kind, .paused)
        XCTAssertEqual(status { $0.wantsMonitoring = true; $0.sessionActive = false }.kind, .paused)
    }

    func testStartingUntilFramesArrive() {
        XCTAssertEqual(status { $0.wantsMonitoring = true; $0.cameraRequested = true }.kind, .starting)
    }

    func testRunningStatesShowMonitoringWithoutClaimingPhoneUse() {
        for state in [BehaviorState.observing, .candidate, .sustainedPhoneUse, .cooldown] {
            let value = running(state)
            XCTAssertEqual(value.kind, .monitoring, "\(state)")
            XCTAssertFalse(value.line.lowercased().contains("phone"), "\(state)")
        }
    }

    func testEngineGatesExplainWhyNoReminders() {
        XCTAssertEqual(running(.paused, [.meetingAppActive]).line, "Meeting app in front · no reminders")
        XCTAssertEqual(running(.paused, [.outsideWorkContext]).line, "Not in a work app · no reminders")
        XCTAssertEqual(running(.unavailable, [.cameraUnavailable]).kind, .unavailable)
    }

    func testEverySymbolIsDistinct() {
        let kinds: [MonitoringStatus.Kind] = [.off, .starting, .monitoring, .paused, .unavailable]
        let symbols = Set(kinds.map { MonitoringStatus(kind: $0, line: "").symbol })
        XCTAssertEqual(symbols.count, kinds.count)
    }
}

final class ReminderNotificationTests: XCTestCase {
    func testContentIsNeutralAndKeyedByEpisode() {
        let id = UUID()
        let event = InterventionEvent(episodeID: id, kind: .sustainedEpisode, timestamp: 10,
                                      evidenceDuration: 50, recentPickupCount: 0, reasons: [.sustainedGraceElapsed])
        let content = ReminderNotification.content(for: event)
        XCTAssertEqual(content.identifier, id.uuidString)
        XCTAssertEqual(content.body, InterventionKind.sustainedEpisode.headline)
        XCTAssertTrue(content.body.hasSuffix("Still working?"))
    }

    func testResponsesMapToEngineActions() {
        XCTAssertEqual(ReminderNotification.action(forResponse: ReminderNotification.backToWorkID, breakSeconds: 300), .backToWork)
        XCTAssertEqual(ReminderNotification.action(forResponse: ReminderNotification.breakID, breakSeconds: 300),
                       .takingABreak(duration: 300))
        XCTAssertEqual(ReminderNotification.action(forResponse: ReminderNotification.quickReplyID, breakSeconds: 300), .notADistraction)
    }

    func testOpeningOrDismissingIsNotFeedback() {
        XCTAssertNil(ReminderNotification.action(forResponse: "com.apple.UNNotificationDefaultActionIdentifier", breakSeconds: 300))
        XCTAssertNil(ReminderNotification.action(forResponse: "com.apple.UNNotificationDismissActionIdentifier", breakSeconds: 300))
    }

    func testBreakTitle() {
        XCTAssertEqual(ReminderNotification.breakTitle(seconds: 300), "Taking a break (5 min)")
    }
}

final class MonitoringStatusRemindersOffTests: XCTestCase {
    func testWorkContextOffSaysRemindersAreOff() {
        let status = MonitoringStatus.make(.init(wantsMonitoring: true, cameraRequested: true, cameraCapturing: true,
                                                 behavior: .paused, reasons: [.outsideWorkContext], remindersOff: true))
        XCTAssertEqual(status.line, "Reminders are off (work context set to Off)")
    }
}
