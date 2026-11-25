import XCTest
@testable import FocusAssistant

final class CaptureFormatTests: XCTestCase {
    private func c(_ w: Int, _ h: Int, fps: Double = 30, yuv: Bool = true) -> CaptureFormatChoice.Candidate {
        .init(width: w, height: h, maxFrameRate: fps, isVideoRange420: yuv)
    }

    /// Same dimensions and order as the built-in camera's list read on 25 Nov 2026.
    func testPicksNative720FromObservedBuiltInList() {
        let list = [c(1920, 1080), c(1280, 720), c(1080, 1920), c(1760, 1328), c(640, 480), c(1328, 1760), c(1552, 1552)]
        XCTAssertEqual(CaptureFormatChoice.select(from: list), 1)
    }

    func testNoExact720ReturnsNilRatherThanNearbySize() {
        XCTAssertNil(CaptureFormatChoice.select(from: [c(1920, 1080), c(640, 480), c(720, 1280), c(1280, 960)]))
        XCTAssertNil(CaptureFormatChoice.select(from: []))
    }

    func testPrefers420vThenHigherFrameRateThenFirstListed() {
        XCTAssertEqual(CaptureFormatChoice.select(from: [c(1280, 720, fps: 60, yuv: false), c(1280, 720, fps: 30)]), 1)
        XCTAssertEqual(CaptureFormatChoice.select(from: [c(1280, 720, fps: 15), c(1280, 720, fps: 30)]), 1)
        XCTAssertEqual(CaptureFormatChoice.select(from: [c(640, 480), c(1280, 720), c(1280, 720)]), 1)
    }
}
