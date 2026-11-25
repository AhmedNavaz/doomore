import CoreGraphics
import Foundation

/// Head angles from Vision's face request, in degrees. Uncalibrated model outputs.
struct HeadPose: Sendable, Equatable {
    /// The SDK header `VNObservation.h` says positive means nodding down. The labelled guided
    /// check of 26 Nov 2026 agrees: looking down at a phone raised pitch by 9–15° above
    /// straight-ahead. An earlier unlabelled reading suggesting the opposite was wrong.
    /// The estimator still treats a change in either direction as "head tilted".
    var pitch: Double?
    /// Positive means counterclockwise (same header). Which side that is on screen is unverified.
    var yaw: Double?
    var roll: Double?

    init(pitch: Double?, yaw: Double?, roll: Double?) {
        self.pitch = pitch
        self.yaw = yaw
        self.roll = roll
    }

    /// Vision reports radians; non-finite values are treated as not computed.
    init(radiansPitch: Double?, yaw: Double?, roll: Double?) {
        func degrees(_ radians: Double?) -> Double? {
            guard let radians, radians.isFinite else { return nil }
            return radians * 180 / .pi
        }
        self.init(pitch: degrees(radiansPitch), yaw: degrees(yaw), roll: degrees(roll))
    }
}

/// What one analysed camera frame showed. Counts, angles and label names only; no pixels.
struct VisionSignals: Sendable, Equatable {
    var faceCount = 0
    /// Pose of the largest face; nil when no face was found.
    var head: HeadPose?
    /// Height divided by width of the eye outlines of the largest face, averaged over both eyes.
    /// Eyelids lower when the eyes look down, even if the head barely moves: 0.19–0.25 looking at
    /// a phone against 0.31–0.33 looking at the screen in two screenshots (25 Nov 2026). Nil
    /// without a face or eye landmarks.
    var eyeOpenness: Double?
    /// Fraction of the picture (0 to 1) that the person-segmentation model marks as a person.
    /// It separates "left the desk" from "face hidden". The upper-body detector tried first
    /// found nobody in 23 of 23 live samples while a face was found in 22 (25 Nov 2026).
    var personCoverage = 0.0
    var handCount = 0
    /// Whole-image labels. Shown as a raw signal; not used by the activity estimate.
    var classifier: ClassifierReading?
}

/// Seconds since the last keyboard or pointer event in this login session.
/// Only elapsed time is read: no keys, clicks, positions or app names.
struct InputIdle: Sendable, Equatable {
    var keyboard: Double
    var pointer: Double
    var any: Double { min(keyboard, pointer) }
}

extension InputIdle {
    /// Reads the system's idle counters. Needs no permission and returns no event content.
    static func current() -> InputIdle {
        func idle(_ type: CGEventType) -> Double {
            let seconds = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: type)
            return seconds.isFinite && seconds >= 0 ? seconds : .infinity
        }
        let pointerTypes: [CGEventType] = [.mouseMoved, .leftMouseDown, .rightMouseDown, .otherMouseDown,
                                           .leftMouseDragged, .scrollWheel]
        return InputIdle(keyboard: idle(.keyDown), pointer: pointerTypes.map(idle).min() ?? .infinity)
    }
}

/// One window of the system sound classifier. Label names and scores only; no audio.
struct SoundReading: Sendable, Equatable {
    /// Highest-scoring labels, descending. Uncalibrated.
    var top: [Classification]
    /// `ProcessInfo.systemUptime` when the window was reported.
    var time: Double
}

enum SoundStatus: Sendable, Equatable {
    case off
    case denied
    case starting
    case listening
    case failed(String)

    var text: String {
        switch self {
        case .off: return "Microphone off"
        case .denied: return "Microphone permission denied — enable it in System Settings → Privacy & Security → Microphone"
        case .starting: return "Starting microphone…"
        case .listening: return "Listening"
        case let .failed(reason): return "Sound unavailable: \(reason)"
        }
    }

    /// Short form for the shared text log.
    var key: String {
        switch self {
        case .off: return "off"
        case .denied: return "denied"
        case .starting: return "starting"
        case .listening: return "listening"
        case .failed: return "failed"
        }
    }
}

/// Everything the activity estimate reads for one sample.
struct SignalSnapshot: Sendable, Equatable {
    /// `ProcessInfo.systemUptime` of the analysed frame.
    var time: Double
    var vision: VisionSignals
    var input: InputIdle
}
