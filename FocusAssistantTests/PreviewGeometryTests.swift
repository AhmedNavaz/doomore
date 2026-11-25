import XCTest
@testable import FocusAssistant

final class PreviewGeometryTests: XCTestCase {
    func testVisionLowerLeftConvertsToTopLeft() throws {
        let actual = try XCTUnwrap(PreviewGeometry.rect(
            for: CGRect(x: 0.1, y: 0.2, width: 0.3, height: 0.4),
            imageSize: CGSize(width: 640, height: 480),
            viewSize: CGSize(width: 800, height: 600),
            mirrored: false
        ))
        assertRect(actual, equals: CGRect(x: 80, y: 240, width: 240, height: 240))
    }

    func testLandscapeImageLeavesTopAndBottomBars() throws {
        let actual = try XCTUnwrap(PreviewGeometry.rect(
            for: CGRect(x: 0, y: 0, width: 1, height: 1),
            imageSize: CGSize(width: 640, height: 480),
            viewSize: CGSize(width: 800, height: 800),
            mirrored: false
        ))
        assertRect(actual, equals: CGRect(x: 0, y: 100, width: 800, height: 600))
    }

    func testPortraitImageLeavesLeftAndRightBars() throws {
        let actual = try XCTUnwrap(PreviewGeometry.rect(
            for: CGRect(x: 0, y: 0, width: 1, height: 1),
            imageSize: CGSize(width: 480, height: 640),
            viewSize: CGSize(width: 800, height: 600),
            mirrored: false
        ))
        assertRect(actual, equals: CGRect(x: 175, y: 0, width: 450, height: 600))
    }

    func testMirrorsBoxWithinFittedImage() throws {
        let actual = try XCTUnwrap(PreviewGeometry.rect(
            for: CGRect(x: 0.1, y: 0.2, width: 0.2, height: 0.3),
            imageSize: CGSize(width: 480, height: 640),
            viewSize: CGSize(width: 800, height: 600),
            mirrored: true
        ))
        assertRect(actual, equals: CGRect(x: 490, y: 300, width: 90, height: 180))
    }

    func testMirroringPreservesSizeAndVerticalPlacement() throws {
        let box = CGRect(x: 0.07, y: 0.31, width: 0.23, height: 0.19)
        let normal = try XCTUnwrap(PreviewGeometry.rect(
            for: box, imageSize: CGSize(width: 1280, height: 720),
            viewSize: CGSize(width: 900, height: 800), mirrored: false
        ))
        let mirrored = try XCTUnwrap(PreviewGeometry.rect(
            for: box, imageSize: CGSize(width: 1280, height: 720),
            viewSize: CGSize(width: 900, height: 800), mirrored: true
        ))
        XCTAssertEqual(mirrored.width, normal.width, accuracy: 0.000001)
        XCTAssertEqual(mirrored.height, normal.height, accuracy: 0.000001)
        XCTAssertEqual(mirrored.minY, normal.minY, accuracy: 0.000001)
        XCTAssertEqual(mirrored.minX, 900 - normal.maxX, accuracy: 0.000001)
    }

    func testClipsAtImageEdgesBeforeMirroring() throws {
        let actual = try XCTUnwrap(PreviewGeometry.rect(
            for: CGRect(x: -0.1, y: 0.8, width: 0.3, height: 0.4),
            imageSize: CGSize(width: 100, height: 100),
            viewSize: CGSize(width: 200, height: 200), mirrored: true
        ))
        assertRect(actual, equals: CGRect(x: 160, y: 0, width: 40, height: 40))
    }

    func testBoxCoveringWholeImageClipsToContent() throws {
        let actual = try XCTUnwrap(PreviewGeometry.rect(
            for: CGRect(x: -1, y: -1, width: 3, height: 3),
            imageSize: CGSize(width: 640, height: 480),
            viewSize: CGSize(width: 800, height: 800), mirrored: false
        ))
        assertRect(actual, equals: CGRect(x: 0, y: 100, width: 800, height: 600))
    }

    func testWhollyOutsideAndEdgeOnlyBoxesAreRejected() {
        for box in [
            CGRect(x: 1.1, y: 0.1, width: 0.2, height: 0.2),
            CGRect(x: -0.4, y: 0.1, width: 0.2, height: 0.2),
            CGRect(x: 1, y: 0.1, width: 0.2, height: 0.2),
            CGRect(x: 0.1, y: 1, width: 0.2, height: 0.2)
        ] {
            XCTAssertNil(map(box), "Unexpected visible box for \(box)")
        }
    }

    func testInvalidBoxNumbersAndDimensionsAreRejected() {
        for box in [
            CGRect(x: CGFloat.nan, y: 0, width: 0.2, height: 0.2),
            CGRect(x: 0, y: CGFloat.infinity, width: 0.2, height: 0.2),
            CGRect(x: 0, y: 0, width: CGFloat.infinity, height: 0.2),
            CGRect(x: 0, y: 0, width: 0.2, height: CGFloat.nan),
            CGRect(x: 0, y: 0, width: 0, height: 0.2),
            CGRect(x: 0, y: 0, width: 0.2, height: -0.1),
            CGRect.null
        ] {
            XCTAssertNil(map(box), "Unexpected visible box for \(box)")
        }
    }

    func testInvalidImageOrViewSizesAreRejected() {
        let box = CGRect(x: 0, y: 0, width: 1, height: 1)
        let validSize = CGSize(width: 640, height: 480)
        for size in [
            CGSize.zero,
            CGSize(width: -1, height: 480),
            CGSize(width: 640, height: 0),
            CGSize(width: CGFloat.infinity, height: 480),
            CGSize(width: 640, height: CGFloat.nan)
        ] {
            XCTAssertNil(PreviewGeometry.rect(
                for: box, imageSize: size, viewSize: validSize, mirrored: false
            ))
            XCTAssertNil(PreviewGeometry.rect(
                for: box, imageSize: validSize, viewSize: size, mirrored: true
            ))
        }
    }

    private func map(_ box: CGRect) -> CGRect? {
        PreviewGeometry.rect(
            for: box, imageSize: CGSize(width: 640, height: 480),
            viewSize: CGSize(width: 800, height: 600), mirrored: false
        )
    }

    private func assertRect(
        _ actual: CGRect,
        equals expected: CGRect,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(actual.minX, expected.minX, accuracy: 0.000001, file: file, line: line)
        XCTAssertEqual(actual.minY, expected.minY, accuracy: 0.000001, file: file, line: line)
        XCTAssertEqual(actual.width, expected.width, accuracy: 0.000001, file: file, line: line)
        XCTAssertEqual(actual.height, expected.height, accuracy: 0.000001, file: file, line: line)
    }
}
