import XCTest
@testable import FocusAssistant

final class RunTokenTests: XCTestCase {
    func testInitiallyRejectsCallbacks() {
        let token = RunToken()
        XCTAssertNil(token.current)
        XCTAssertFalse(token.accepts(UUID()))
    }

    func testCancelWhileRequestingRejectsDelayedPermissionResponse() {
        var token = RunToken()
        let permissionRequest = token.begin()
        XCTAssertTrue(token.accepts(permissionRequest))

        token.cancel()

        XCTAssertNil(token.current)
        XCTAssertFalse(token.accepts(permissionRequest))
    }

    func testRapidRestartRejectsPriorGeneration() {
        var token = RunToken()
        let firstRun = token.begin()
        let secondRun = token.begin()

        XCTAssertNotEqual(firstRun, secondRun)
        XCTAssertFalse(token.accepts(firstRun))
        XCTAssertTrue(token.accepts(secondRun))
        XCTAssertEqual(token.current, secondRun)
    }

    func testRepeatedCancelIsHarmlessAndNextRunCanStart() {
        var token = RunToken()
        let firstRun = token.begin()
        token.cancel()
        token.cancel()
        XCTAssertNil(token.current)

        let nextRun = token.begin()
        XCTAssertFalse(token.accepts(firstRun))
        XCTAssertTrue(token.accepts(nextRun))
    }
}

final class InferenceScheduleTests: XCTestCase {
    func testFirstFiniteNonnegativeTimestampIsAccepted() {
        var schedule = InferenceSchedule()
        XCTAssertFalse(schedule.shouldProcess(at: -.infinity))
        XCTAssertFalse(schedule.shouldProcess(at: .infinity))
        XCTAssertFalse(schedule.shouldProcess(at: .nan))
        XCTAssertFalse(schedule.shouldProcess(at: -1))
        XCTAssertTrue(schedule.shouldProcess(at: 0))
    }

    func testDefaultIntervalAdmitsOnlyAfterOneSecond() {
        var schedule = InferenceSchedule()
        XCTAssertTrue(schedule.shouldProcess(at: 10))
        XCTAssertFalse(schedule.shouldProcess(at: 10.25))
        XCTAssertFalse(schedule.shouldProcess(at: 10.99))
        XCTAssertTrue(schedule.shouldProcess(at: 11))
    }

    func testCustomInterval() {
        var schedule = InferenceSchedule(minimumInterval: 0.25)
        XCTAssertTrue(schedule.shouldProcess(at: 2))
        XCTAssertFalse(schedule.shouldProcess(at: 2.125))
        XCTAssertTrue(schedule.shouldProcess(at: 2.25))
    }

    func testIrregularCadenceDoesNotQueueCatchUp() {
        var schedule = InferenceSchedule()
        XCTAssertTrue(schedule.shouldProcess(at: 10))
        XCTAssertTrue(schedule.shouldProcess(at: 100))
        XCTAssertFalse(schedule.shouldProcess(at: 100))
        XCTAssertFalse(schedule.shouldProcess(at: 100.1))
        XCTAssertFalse(schedule.shouldProcess(at: 100.9))
        XCTAssertTrue(schedule.shouldProcess(at: 101))
    }

    func testOutOfOrderAndRepeatedTimesDoNotMoveScheduleBackwards() {
        var schedule = InferenceSchedule()
        XCTAssertTrue(schedule.shouldProcess(at: 10))
        XCTAssertFalse(schedule.shouldProcess(at: 10.75))
        XCTAssertFalse(schedule.shouldProcess(at: 10.5))
        XCTAssertFalse(schedule.shouldProcess(at: 10.75))
        XCTAssertFalse(schedule.shouldProcess(at: 8))
        XCTAssertFalse(schedule.shouldProcess(at: .nan))
        XCTAssertFalse(schedule.shouldProcess(at: .infinity))
        XCTAssertTrue(schedule.shouldProcess(at: 11))
    }

    func testResetAcceptsNewTimelineWithoutInheritedDelay() {
        var schedule = InferenceSchedule()
        XCTAssertTrue(schedule.shouldProcess(at: 100))
        schedule.reset()
        XCTAssertTrue(schedule.shouldProcess(at: 0))
        XCTAssertFalse(schedule.shouldProcess(at: 0))
        XCTAssertFalse(schedule.shouldProcess(at: 0.5))
        XCTAssertTrue(schedule.shouldProcess(at: 1))
    }
}
