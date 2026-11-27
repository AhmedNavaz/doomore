import Foundation

/// How readily reminders fire. Scales the engine's timing rules; the underlying signals,
/// the work-app gating and the "never remind on unknown evidence" rules do not change.
enum Sensitivity: String, Sendable, Equatable, CaseIterable, Identifiable {
    case relaxed
    case balanced
    case sensitive

    var id: String { rawValue }

    var label: String {
        switch self {
        case .relaxed: return "Relaxed"
        case .balanced: return "Balanced"
        case .sensitive: return "Sensitive"
        }
    }

    var detail: String {
        switch self {
        case .relaxed: return "Waits about 40 s of looking away and 75 s of idle with some looking away. Fewer reminders."
        case .balanced: return "Waits about 25 s of looking away and 45 s of no input with some looking away. Reminds again after 2 minutes."
        case .sensitive: return "Waits about 15 s of looking away, or 60 s at the desk with no input whatever you look at. Reminds again after 90 s. More false alarms."
        }
    }

    /// Engine rules for this setting. `.balanced` is exactly the default rules.
    var rules: BehaviorEngine.Rules {
        var rules = BehaviorEngine.Rules()
        switch self {
        case .balanced:
            break
        case .relaxed:
            rules.idleCorroborationSeconds = 8
            rules.episodeGraceSeconds = 40
            rules.cooldownSeconds = 240
            rules.pickupThresholdCount = 5
            rules.idleStretchCueSeconds = 75
            rules.idleStretchLongSeconds = 240
            rules.idleStretchLongCueShare = 0.35
        case .sensitive:
            rules.idleCorroborationSeconds = 5
            rules.episodeGraceSeconds = 15
            rules.cooldownSeconds = 90
            rules.pickupThresholdCount = 3
            rules.idleStretchCueSeconds = 30
            rules.idleStretchLongSeconds = 90
            rules.idleStretchLongCueShare = 0.2
            rules.idleStretchPlainSeconds = 60
        }
        return rules
    }
}
