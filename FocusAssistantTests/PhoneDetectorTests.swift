import CoreVideo
import XCTest
@testable import FocusAssistant

/// Contract tests only. These fakes do not prove any real model or camera functionality.
final class PhoneDetectorTests: XCTestCase {
    func testFakeReturnsKnownBoxForBorrowedSyntheticFrame() throws {
        let expected = DetectionResult(phones: [PhoneDetection(
            boundingBox: CGRect(x: 0.25, y: 0.1, width: 0.2, height: 0.6),
            confidence: 0.72, label: "synthetic test phone"
        )], inferenceMilliseconds: 4)
        let detector = FakePhoneDetector(result: .success(expected))
        let buffer = try makeSyntheticBuffer()

        XCTAssertEqual(try detector.detect(in: buffer), expected)
        XCTAssertEqual(detector.receivedDimensions, CGSize(width: 8, height: 6))
        XCTAssertEqual(detector.callCount, 1)
    }

    func testSuccessfulEmptyResultIsDistinctFromFailure() throws {
        let detector = FakePhoneDetector(result: .success(DetectionResult(
            phones: [], inferenceMilliseconds: 2
        )))
        let result = try detector.detect(in: makeSyntheticBuffer())
        XCTAssertTrue(result.phones.isEmpty)
        XCTAssertEqual(detector.callCount, 1)
    }

    func testDetectorFailurePropagatesInsteadOfBecomingNegativeEvidence() throws {
        let detector = FakePhoneDetector(result: .failure(.unavailable))
        let buffer = try makeSyntheticBuffer()
        XCTAssertThrowsError(try detector.detect(in: buffer)) { error in
            XCTAssertEqual(error as? FakeFailure, .unavailable)
        }
        XCTAssertEqual(detector.callCount, 1)
    }

    private func makeSyntheticBuffer() throws -> CVPixelBuffer {
        var pixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault, 8, 6, kCVPixelFormatType_32BGRA, nil, &pixelBuffer
        )
        XCTAssertEqual(status, kCVReturnSuccess)
        let buffer = try XCTUnwrap(pixelBuffer)
        let lockStatus = CVPixelBufferLockBaseAddress(buffer, [])
        XCTAssertEqual(lockStatus, kCVReturnSuccess)
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let address = try XCTUnwrap(CVPixelBufferGetBaseAddress(buffer))
        address.initializeMemory(
            as: UInt8.self, repeating: 0,
            count: CVPixelBufferGetBytesPerRow(buffer) * CVPixelBufferGetHeight(buffer)
        )
        return buffer
    }
}

private enum FakeFailure: Error, Equatable {
    case unavailable
}

private final class FakePhoneDetector: PhoneDetector {
    let result: Result<DetectionResult, FakeFailure>
    private(set) var callCount = 0
    private(set) var receivedDimensions: CGSize?

    init(result: Result<DetectionResult, FakeFailure>) {
        self.result = result
    }

    func detect(in pixelBuffer: CVPixelBuffer) throws -> DetectionResult {
        callCount += 1
        receivedDimensions = CGSize(
            width: CVPixelBufferGetWidth(pixelBuffer), height: CVPixelBufferGetHeight(pixelBuffer)
        )
        return try result.get()
    }
}
