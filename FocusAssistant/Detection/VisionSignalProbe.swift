import CoreVideo
import Foundation
import Vision

/// Runs Apple's built-in Vision requests on one borrowed frame: face with head angles and
/// eye outlines, how much of the picture is a person, hands, and the whole-image classifier. All are operating-system
/// models; nothing is downloaded or bundled. None of them locates a phone, and the
/// classifier's `phone` score is a whole-image label, deliberately NOT a PhoneDetector.
final class VisionSignalProbe {
    /// A hand counts when at least this many joints are found above `handJointConfidence`.
    /// Starting values; not checked against real scenes.
    static let minimumHandJoints = 5
    static let handJointConfidence: Float = 0.3

    private let faces = VNDetectFaceRectanglesRequest()
    private let landmarks = VNDetectFaceLandmarksRequest()
    private let person = VNGeneratePersonSegmentationRequest()
    private let hands = VNDetectHumanHandPoseRequest()
    private let classify = VNClassifyImageRequest()

    init() throws {
        faces.revision = VNDetectFaceRectanglesRequestRevision3 // macOS 12+: reports roll, yaw and pitch.
        landmarks.revision = VNDetectFaceLandmarksRequestRevision3
        person.qualityLevel = .fast // macOS 12+. A coarse mask is enough to measure coverage.
        person.outputPixelFormat = kCVPixelFormatType_OneComponent8
        hands.maximumHandCount = 2
        classify.revision = VNClassifyImageRequestRevision2 // macOS 14+.
        _ = try classify.supportedIdentifiers() // Fail at Start, not mid-capture, if the classifier is missing.
    }

    /// Loads the models by analysing one blank frame and discarding the result. The first
    /// analysis in a process took about six seconds in the unit-test host (25 Nov 2026);
    /// later ones took milliseconds. Called before the camera starts, so that wait never
    /// happens inside a frame callback.
    func warmUp() throws {
        var created: CVPixelBuffer?
        guard CVPixelBufferCreate(kCFAllocatorDefault, 640, 360, kCVPixelFormatType_32BGRA, nil, &created) == kCVReturnSuccess,
              let buffer = created else { return }
        CVPixelBufferLockBaseAddress(buffer, [])
        memset(CVPixelBufferGetBaseAddress(buffer), 128, CVPixelBufferGetDataSize(buffer))
        CVPixelBufferUnlockBaseAddress(buffer, [])
        _ = try analyze(buffer)
    }

    /// Any request failure throws: a failed analysis must not look like "nothing found".
    func analyze(_ buffer: CVPixelBuffer) throws -> VisionSignals {
        let handler = VNImageRequestHandler(cvPixelBuffer: buffer, orientation: .up)
        try handler.perform([faces, person, hands, classify])

        var signals = VisionSignals()
        let found = faces.results ?? []
        signals.faceCount = found.count
        if let largest = found.max(by: { Self.area($0.boundingBox) < Self.area($1.boundingBox) }) {
            signals.head = HeadPose(radiansPitch: largest.pitch?.doubleValue,
                                    yaw: largest.yaw?.doubleValue,
                                    roll: largest.roll?.doubleValue)
            // Landmarks for the largest face only, reusing its box instead of searching again.
            landmarks.inputFaceObservations = [largest]
            try handler.perform([landmarks])
            let size = CGSize(width: CVPixelBufferGetWidth(buffer), height: CVPixelBufferGetHeight(buffer))
            if let marks = landmarks.results?.first?.landmarks {
                let eyes = [marks.leftEye, marks.rightEye].compactMap { region in
                    region.flatMap { Self.openness(of: $0.pointsInImage(imageSize: size)) }
                }
                signals.eyeOpenness = eyes.isEmpty ? nil : eyes.reduce(0, +) / Double(eyes.count)
            }
            landmarks.inputFaceObservations = nil
        }
        if let mask = person.results?.first?.pixelBuffer {
            signals.personCoverage = Self.coverage(of: mask)
        }
        signals.handCount = (hands.results ?? []).filter { observation in
            let points = (try? observation.recognizedPoints(.all)) ?? [:]
            return points.values.filter { $0.confidence > Self.handJointConfidence }.count >= Self.minimumHandJoints
        }.count
        // Every label is read so the exact `phone` score is available even far outside the top labels.
        signals.classifier = ClassifierReading.summarize((classify.results ?? []).map {
            Classification(label: $0.identifier, confidence: $0.confidence)
        })
        return signals
    }

    private static func area(_ box: CGRect) -> CGFloat { box.width * box.height }

    /// Height over width of an eye outline in image pixels; nil for a degenerate outline.
    static func openness(of points: [CGPoint]) -> Double? {
        guard points.count >= 3 else { return nil }
        let xs = points.map(\.x), ys = points.map(\.y)
        guard let minX = xs.min(), let maxX = xs.max(), let minY = ys.min(), let maxY = ys.max(),
              maxX - minX > 1 else { return nil }
        let ratio = Double((maxY - minY) / (maxX - minX))
        return ratio.isFinite ? ratio : nil
    }

    /// Share of mask pixels above the midpoint, sampled every fourth row and column.
    /// The mask is read inside this call and not kept.
    private static func coverage(of mask: CVPixelBuffer) -> Double {
        CVPixelBufferLockBaseAddress(mask, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(mask, .readOnly) }
        let width = CVPixelBufferGetWidth(mask), height = CVPixelBufferGetHeight(mask)
        guard let base = CVPixelBufferGetBaseAddress(mask), width > 0, height > 0 else { return 0 }
        let pixels = base.assumingMemoryBound(to: UInt8.self)
        let rowBytes = CVPixelBufferGetBytesPerRow(mask)
        var inside = 0, total = 0
        for y in stride(from: 0, to: height, by: 4) {
            let row = pixels + y * rowBytes
            for x in stride(from: 0, to: width, by: 4) {
                total += 1
                if row[x] > 127 { inside += 1 }
            }
        }
        return total > 0 ? Double(inside) / Double(total) : 0
    }
}
