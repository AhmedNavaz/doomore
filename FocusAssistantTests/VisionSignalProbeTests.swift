import CoreVideo
import XCTest
@testable import FocusAssistant

/// Runs the real system models on a blank synthetic frame, inside the sandboxed test host.
/// This shows that every request executes and that an empty picture reports "nothing found".
/// It is not evidence about faces, hands or phones in real camera frames.
final class VisionSignalProbeTests: XCTestCase {
    func testBlankFrameRunsEveryRequestAndFindsNobody() throws {
        let probe = try VisionSignalProbe()
        let signals = try probe.analyze(try makeGrayBuffer(width: 1280, height: 720))

        XCTAssertEqual(signals.faceCount, 0)
        XCTAssertNil(signals.head)
        XCTAssertNil(signals.eyeOpenness)
        XCTAssertNil(signals.pupilOffset)
        XCTAssertNil(signals.faceWidth)
        XCTAssertNil(signals.faceCenterY)
        XCTAssertLessThan(signals.personCoverage, 0.05, "a blank frame must stay below the person-in-view rule")
        XCTAssertEqual(signals.handCount, 0)
        let classifier = try XCTUnwrap(signals.classifier)
        XCTAssertGreaterThan(classifier.labelCount, 0)
        XCTAssertNotNil(classifier.phoneConfidence, "the installed classifier should report the exact phone label")
    }

    func testProbeCanBeReusedForSeveralFrames() throws {
        let probe = try VisionSignalProbe()
        let buffer = try makeGrayBuffer(width: 640, height: 480)
        XCTAssertEqual(try probe.analyze(buffer), try probe.analyze(buffer))
    }

    func testEyeOpennessIsHeightOverWidthOfTheOutline() {
        let outline = [CGPoint(x: 10, y: 5), CGPoint(x: 30, y: 8), CGPoint(x: 50, y: 5), CGPoint(x: 30, y: 2)]
        XCTAssertEqual(VisionSignalProbe.openness(of: outline) ?? .nan, 6.0 / 40.0, accuracy: 0.0001)
        XCTAssertNil(VisionSignalProbe.openness(of: Array(outline.prefix(2))), "too few points")
        XCTAssertNil(VisionSignalProbe.openness(of: [CGPoint(x: 1, y: 0), CGPoint(x: 1, y: 4), CGPoint(x: 1.5, y: 2)]),
                     "an outline without width")
    }

    func testPupilVerticalOffsetMeasuresSignedPerpendicularOffsetInvariantToRoll() {
        let levelEye = [CGPoint(x: 10, y: 20), CGPoint(x: 30, y: 26), CGPoint(x: 50, y: 20), CGPoint(x: 30, y: 14)]
        XCTAssertEqual(VisionSignalProbe.pupilVerticalOffset(eye: levelEye, pupil: [CGPoint(x: 30, y: 24)]) ?? .nan,
                       0.1, accuracy: 0.0001, "4 px above a 40 px eye line is +0.10")
        XCTAssertEqual(VisionSignalProbe.pupilVerticalOffset(eye: levelEye, pupil: [CGPoint(x: 30, y: 16)]) ?? .nan,
                       -0.1, accuracy: 0.0001, "4 px below a 40 px eye line is -0.10")

        // Rotate eye and pupil by 30° counterclockwise around (10, 20): signed offset must stay -0.10.
        let angle = Double.pi / 6
        func rotate(_ p: CGPoint) -> CGPoint {
            let dx = Double(p.x - 10), dy = Double(p.y - 20)
            return CGPoint(x: 10 + dx * cos(angle) - dy * sin(angle),
                           y: 20 + dx * sin(angle) + dy * cos(angle))
        }
        let rolledEye = levelEye.map(rotate)
        let rolledPupil = [rotate(CGPoint(x: 30, y: 16))]
        XCTAssertEqual(VisionSignalProbe.pupilVerticalOffset(eye: rolledEye, pupil: rolledPupil) ?? .nan,
                       -0.1, accuracy: 0.0001)

        XCTAssertNil(VisionSignalProbe.pupilVerticalOffset(eye: levelEye, pupil: []))
        XCTAssertNil(VisionSignalProbe.pupilVerticalOffset(eye: Array(levelEye.prefix(2)), pupil: [CGPoint(x: 30, y: 20)]))
    }

    /// The idle counters must be readable under App Sandbox without any permission.
    /// The values are printed so they can be compared with the same call outside the sandbox.
    func testIdleCountersAreReadableInsideTheSandbox() {
        let idle = InputIdle.current()
        print("IDLE-IN-SANDBOX keyboard=\(idle.keyboard) pointer=\(idle.pointer)")
        XCTAssertTrue(idle.any.isFinite)
        XCTAssertGreaterThanOrEqual(idle.any, 0)
    }

    private func makeGrayBuffer(width: Int, height: Int) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        let attributes = [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary] as CFDictionary
        let status = CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, attributes, &buffer)
        XCTAssertEqual(status, kCVReturnSuccess)
        let created = try XCTUnwrap(buffer)
        CVPixelBufferLockBaseAddress(created, [])
        defer { CVPixelBufferUnlockBaseAddress(created, []) }
        memset(CVPixelBufferGetBaseAddress(created), 128, CVPixelBufferGetDataSize(created))
        return created
    }
}
