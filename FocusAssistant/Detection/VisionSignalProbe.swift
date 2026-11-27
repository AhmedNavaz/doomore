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
            signals.faceWidth = Double(largest.boundingBox.width)
            signals.faceCenterY = Double(largest.boundingBox.midY)
            if let light = Self.luma(of: buffer, face: largest.boundingBox) {
                signals.faceLuma = light.face
                signals.frameLuma = light.frame
            }
            // Landmarks for the largest face only, reusing its box instead of searching again.
            landmarks.inputFaceObservations = [largest]
            try handler.perform([landmarks])
            let size = CGSize(width: CVPixelBufferGetWidth(buffer), height: CVPixelBufferGetHeight(buffer))
            if let marks = landmarks.results?.first?.landmarks {
                let eyes = [marks.leftEye, marks.rightEye].compactMap { region in
                    region.flatMap { Self.openness(of: $0.pointsInImage(imageSize: size)) }
                }
                signals.eyeOpenness = eyes.isEmpty ? nil : eyes.reduce(0, +) / Double(eyes.count)

                let gazePairs: [(VNFaceLandmarkRegion2D?, VNFaceLandmarkRegion2D?)] = [
                    (marks.leftEye, marks.leftPupil),
                    (marks.rightEye, marks.rightPupil)
                ]
                let pupils = gazePairs.compactMap { eye, pupil -> Double? in
                    guard let eye, let pupil else { return nil }
                    return Self.pupilVerticalOffset(eye: eye.pointsInImage(imageSize: size),
                                                    pupil: pupil.pointsInImage(imageSize: size))
                }
                signals.pupilOffset = pupils.isEmpty ? nil : pupils.reduce(0, +) / Double(pupils.count)
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

    /// Signed perpendicular offset of the pupil from the line connecting the eye's left and right
    /// corners, divided by the corner-to-corner distance. Positive means above the corner line
    /// (Vision's y axis increases upward); negative means below (looking down). Roll- and scale-invariant.
    static func pupilVerticalOffset(eye: [CGPoint], pupil: [CGPoint]) -> Double? {
        guard eye.count >= 3, !pupil.isEmpty else { return nil }
        guard let left = eye.min(by: { $0.x < $1.x }),
              let right = eye.max(by: { $0.x < $1.x }) else { return nil }
        let dx = Double(right.x - left.x)
        let dy = Double(right.y - left.y)
        let lengthSquared = dx * dx + dy * dy
        guard lengthSquared > 1 else { return nil }
        let px = pupil.reduce(0.0) { $0 + Double($1.x) } / Double(pupil.count)
        let py = pupil.reduce(0.0) { $0 + Double($1.y) } / Double(pupil.count)
        let cross = dx * (py - Double(left.y)) - dy * (px - Double(left.x))
        let offset = cross / lengthSquared
        return offset.isFinite ? offset : nil
    }

    /// Mean brightness (Rec. 601 luma, 0 to 1) inside `face` (Vision's normalized box, origin bottom
    /// left) and over the whole frame, sampled every eighth row and column of a 32BGRA buffer.
    /// Nil for any other pixel format. Pixels are read inside this call and not kept.
    static func luma(of buffer: CVPixelBuffer, face: CGRect) -> (face: Double, frame: Double)? {
        guard CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_32BGRA else { return nil }
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
        guard let base = CVPixelBufferGetBaseAddress(buffer), width > 0, height > 0 else { return nil }
        let pixels = base.assumingMemoryBound(to: UInt8.self)
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        let box = face.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        guard !box.isNull, box.width > 0, box.height > 0 else { return nil }
        // Rows in memory run top to bottom; Vision's y runs bottom to top.
        let x0 = Int(box.minX * CGFloat(width)), x1 = Int(box.maxX * CGFloat(width))
        let y0 = Int((1 - box.maxY) * CGFloat(height)), y1 = Int((1 - box.minY) * CGFloat(height))
        var faceSum = 0.0, faceCount = 0, frameSum = 0.0, frameCount = 0
        for y in stride(from: 0, to: height, by: 8) {
            let row = pixels + y * rowBytes
            let inFaceRow = y >= y0 && y < y1
            for x in stride(from: 0, to: width, by: 8) {
                let p = row + x * 4
                let value = (0.114 * Double(p[0]) + 0.587 * Double(p[1]) + 0.299 * Double(p[2])) / 255
                frameSum += value
                frameCount += 1
                if inFaceRow && x >= x0 && x < x1 {
                    faceSum += value
                    faceCount += 1
                }
            }
        }
        guard faceCount > 0, frameCount > 0 else { return nil }
        return (faceSum / Double(faceCount), frameSum / Double(frameCount))
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
