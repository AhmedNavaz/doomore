import Foundation

/// What the menu bar shows (spec §1.2: monitoring, paused, unavailable or inactive).
/// Pure so every combination is unit-tested; holds no app names or readings.
struct MonitoringStatus: Equatable {
    enum Kind: Equatable {
        case off
        case starting
        case monitoring
        case paused
        case unavailable
    }

    var kind: Kind
    var line: String

    var symbol: String {
        switch kind {
        case .off: return "eye.slash"
        case .starting: return "eye"
        case .monitoring: return "eye.fill"
        case .paused: return "pause.circle"
        case .unavailable: return "exclamationmark.triangle"
        }
    }

    struct Inputs: Equatable {
        /// The person asked for monitoring and has not stopped it.
        var wantsMonitoring = false
        var userPaused = false
        var breakSecondsLeft = 0.0
        var cameraRequested = false
        var cameraCapturing = false
        var sessionActive = true
        var behavior: BehaviorState = .disabled
        var reasons: [BehaviorReason] = []
        /// Why monitoring could not run, for example a refused camera permission.
        var problem: String?
        /// Work context is set to Off, so the engine never reminds.
        var remindersOff = false
    }

    static func make(_ inputs: Inputs) -> MonitoringStatus {
        guard inputs.wantsMonitoring else {
            if let problem = inputs.problem { return MonitoringStatus(kind: .unavailable, line: problem) }
            return MonitoringStatus(kind: .off, line: "Monitoring off")
        }
        if inputs.breakSecondsLeft > 0 {
            let minutes = max(1, Int((inputs.breakSecondsLeft / 60).rounded(.up)))
            return MonitoringStatus(kind: .paused, line: "On break · \(minutes) min left · camera off")
        }
        if inputs.userPaused {
            return MonitoringStatus(kind: .paused, line: "Paused · camera off")
        }
        if !inputs.sessionActive {
            return MonitoringStatus(kind: .paused, line: "Mac locked or asleep · resumes when you return")
        }
        if let problem = inputs.problem {
            return MonitoringStatus(kind: .unavailable, line: problem)
        }
        if !inputs.cameraCapturing {
            return MonitoringStatus(kind: .starting, line: inputs.cameraRequested ? "Starting camera…" : "Waiting to start")
        }
        switch inputs.behavior {
        case .paused:
            if inputs.reasons.contains(.meetingAppActive) {
                return MonitoringStatus(kind: .paused, line: "Meeting app in front · no reminders")
            }
            if inputs.remindersOff {
                return MonitoringStatus(kind: .paused, line: "Reminders are off (work context set to Off)")
            }
            if inputs.reasons.contains(.outsideWorkContext) {
                return MonitoringStatus(kind: .paused, line: "Not in a work app · no reminders")
            }
            return MonitoringStatus(kind: .paused, line: "Paused")
        case .unavailable:
            return MonitoringStatus(kind: .unavailable, line: "Camera unavailable")
        case .disabled:
            return MonitoringStatus(kind: .starting, line: "Starting…")
        case .observing, .candidate, .sustainedPhoneUse, .cooldown:
            if inputs.reasons.contains(.calibrating) {
                return MonitoringStatus(kind: .monitoring, line: "Monitoring · learning straight-ahead, look at the screen")
            }
            if inputs.reasons.contains(.noPersonInView) {
                return MonitoringStatus(kind: .monitoring, line: "Monitoring · nobody in view")
            }
            return MonitoringStatus(kind: .monitoring, line: "Monitoring")
        }
    }
}
