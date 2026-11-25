import CoreGraphics
import CoreVideo

/// A detector result, not evidence that the person is using the phone.
struct PhoneDetection: Sendable, Equatable {
    /// Normalized original-image coordinates with a lower-left origin (Vision convention).
    let boundingBox: CGRect
    /// Uncalibrated model output; not a probability of distraction.
    let confidence: Float
    let label: String
}

struct DetectionResult: Sendable, Equatable {
    /// An empty array means the detector successfully found no phone in this frame.
    /// A model/runtime failure must throw instead of returning an empty array.
    let phones: [PhoneDetection]
    let inferenceMilliseconds: Double
}

/// Called synchronously on the capture/inference queue, with at most one call in flight.
/// The pixel buffer is borrowed for this call only: implementations must not retain it,
/// schedule asynchronous work with it, or send it across actor/queue boundaries.
protocol PhoneDetector {
    func detect(in pixelBuffer: CVPixelBuffer) throws -> DetectionResult
}
