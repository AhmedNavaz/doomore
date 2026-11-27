import XCTest
@testable import FocusAssistant

final class SettingsTests: XCTestCase {
    func testBalancedIsDefaultRules() {
        XCTAssertEqual(Sensitivity.balanced.rules, BehaviorEngine.Rules())
    }

    func testSensitivityOrdersGraceAndPickups() {
        let relaxed = Sensitivity.relaxed.rules, sensitive = Sensitivity.sensitive.rules
        XCTAssertGreaterThan(relaxed.episodeGraceSeconds, sensitive.episodeGraceSeconds)
        XCTAssertGreaterThan(relaxed.pickupThresholdCount, sensitive.pickupThresholdCount)
        XCTAssertGreaterThan(relaxed.idleStretchCueSeconds, sensitive.idleStretchCueSeconds)
        XCTAssertGreaterThan(sensitive.pickupThresholdCount, 0)
    }

    func testWorkAppListNormalizesAddsAndRemoves() {
        XCTAssertEqual(WorkAppList.normalized(["b", " a ", "b", ""]), ["a", "b"])
        XCTAssertEqual(WorkAppList.adding("c", to: ["b", "a"]), ["a", "b", "c"])
        XCTAssertEqual(WorkAppList.adding("a", to: ["a"]), ["a"])
        XCTAssertEqual(WorkAppList.removing("a", from: ["a", "b"]), ["b"])
    }
}
