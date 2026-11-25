import Foundation
import CoreGraphics

/// The window always runs `signals`. `captureOnly` is reachable only through the self-test
/// argument `--capture-only`, as the camera-without-analysis baseline for measurements.
enum CaptureMode: String, CaseIterable, Identifiable {
    case captureOnly = "Capture only"
    case signals = "All signals"
    var id: String { rawValue }
}

struct CameraChoice: Identifiable, Equatable {
    let id: String
    let name: String
    let builtIn: Bool
}

struct Classification: Sendable, Equatable {
    let label: String
    let confidence: Float
}

struct CaptureMetrics: Sendable {
    /// False in capture-only runs, where analysis counters do not apply.
    var inferenceConfigured = false
    var deliveredFrames = 0
    var droppedFrames = 0
    var skippedFrames = 0
    var inferenceCount = 0
    var captureFPS = 0.0
    var inferenceFPS = 0.0
    var lastLatencyMS = 0.0
    var meanLatencyMS = 0.0
    var p95LatencyMS = 0.0
    var imageSize = CGSize.zero
    /// Latest analysed frame; nil in capture-only runs and before the first sample.
    var signals: VisionSignals?
    /// Keyboard and pointer idle time read at the moment of that frame.
    var input: InputIdle?
    var phones: [PhoneDetection] = []
    /// `ProcessInfo.systemUptime` of the latest analysed frame; it changes once per sample.
    var sampleTime = 0.0
}

enum CaptureEvent {
    case started(String, previewAttached: Bool)
    case metrics(CaptureMetrics)
    case stopped(String)
    case failed(String)
}
