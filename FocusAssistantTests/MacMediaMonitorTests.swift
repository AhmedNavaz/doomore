import XCTest
@testable import FocusAssistant

final class MacMediaMonitorTests: XCTestCase {
    func testGenericElectronKeepAwakeIsNotVideo() {
        // Seen live: Codeshi held this for 20 minutes and every phone-step frame read mac_video=on.
        XCTAssertFalse(MacMediaMonitor.isVideoAssertion(type: "NoDisplaySleepAssertion", name: "Electron"))
    }

    func testBrowserAndPlayerVideoNamesCount() {
        XCTAssertTrue(MacMediaMonitor.isVideoAssertion(type: "NoDisplaySleepAssertion", name: "Playing video"))
        XCTAssertTrue(MacMediaMonitor.isVideoAssertion(type: "NoDisplaySleepAssertion", name: "Video Wake Lock"))
        XCTAssertTrue(MacMediaMonitor.isVideoAssertion(type: "PreventUserIdleDisplaySleep", name: "IINA is playing"))
        XCTAssertTrue(MacMediaMonitor.isVideoAssertion(type: "PreventUserIdleDisplaySleep", name: "WebKit Media Playback"))
    }

    func testNonDisplayAssertionsNeverCount() {
        XCTAssertFalse(MacMediaMonitor.isVideoAssertion(type: "PreventUserIdleSystemSleep", name: "Playing video"))
        XCTAssertFalse(MacMediaMonitor.isVideoAssertion(type: "UserIsActive", name: "media key"))
    }

    func testMissingFieldsDoNotCount() {
        XCTAssertFalse(MacMediaMonitor.isVideoAssertion(type: nil, name: "Playing video"))
        XCTAssertFalse(MacMediaMonitor.isVideoAssertion(type: "NoDisplaySleepAssertion", name: nil))
    }
}
