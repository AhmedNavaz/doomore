import Foundation

/// Temporal state of the Milestone 1 behavioral engine (spec §5.2).
enum BehaviorState: String, Sendable, Equatable {
    case disabled
    case unavailable
    case paused
    case observing
    case candidate
    case sustainedPhoneUse
    case cooldown

    var displayName: String {
        switch self {
        case .disabled: return "Disabled"
        case .unavailable: return "Unavailable"
        case .paused: return "Paused"
        case .observing: return "Observing"
        case .candidate: return "Possible phone use (grace)"
        case .sustainedPhoneUse: return "Sustained phone use"
        case .cooldown: return "Cooldown"
        }
    }
}

/// Interpretable reason codes explaining the current behavioral state (spec §5.2).
/// Never fabricates a behavioral probability score.
enum BehaviorReason: String, Sendable, Equatable, Hashable {
    case monitoringDisabled
    case cameraUnavailable
    case sessionInactive
    case userPaused
    case breakActive
    case meetingAppActive
    case outsideWorkContext
    case calibrating
    case noPersonInView
    case multiplePeopleInView
    case evidenceStale
    case lowQualityOrUnknown
    case inputActive
    case idleOnlyWithoutAwayPosture
    case awayFromScreen
    case idleCorroborated
    case sustainedGraceElapsed
    case repeatedShortPickups
    case episodeAcknowledged
    case cooldownActive
    /// No keyboard or mouse for a while, with the person at the desk and head, eyes or face
    /// position showing signs of looking elsewhere for much of that time.
    case idleAtDeskWithCues
    /// This Mac is playing video, so sitting still without input is expected.
    case macPlayingVideo

    var label: String {
        switch self {
        case .monitoringDisabled: return "monitoring off"
        case .cameraUnavailable: return "camera unavailable"
        case .sessionInactive: return "session inactive"
        case .userPaused: return "paused by user"
        case .breakActive: return "on break"
        case .meetingAppActive: return "meeting app active"
        case .outsideWorkContext: return "outside work apps"
        case .calibrating: return "calibrating straight-ahead"
        case .noPersonInView: return "no person in view"
        case .multiplePeopleInView: return "multiple people in frame"
        case .evidenceStale: return "evidence stale"
        case .lowQualityOrUnknown: return "evidence unknown"
        case .inputActive: return "keyboard or pointer active"
        case .idleOnlyWithoutAwayPosture: return "idle while facing screen"
        case .awayFromScreen: return "head or eyes away"
        case .idleCorroborated: return "input idle corroborated"
        case .sustainedGraceElapsed: return "grace elapsed"
        case .repeatedShortPickups: return "repeated short pickups"
        case .episodeAcknowledged: return "acknowledged"
        case .cooldownActive: return "reminder cooldown"
        case .idleAtDeskWithCues: return "no input, looking elsewhere"
        case .macPlayingVideo: return "video playing on this Mac"
        }
    }
}

/// Quality/visibility classification of a single perception sample.
/// Model failure, occlusion, or multiple people are never treated as positive evidence.
enum EvidenceQuality: String, Sendable, Equatable {
    case valid
    case calibrating
    case noPerson
    case multiplePeople
    case unknown
}

/// One perception observation fed into `BehaviorEngine`.
struct BehaviorEvidence: Sendable, Equatable {
    var time: Double
    var quality: EvidenceQuality
    var posture: Posture
    var awayFromScreen: Bool
    var inputIdleSeconds: Double
    var possiblePhoneUse: Bool
    var handCount: Int
    var faceCount: Int
    /// Weaker sign of looking elsewhere while still reading as facing (see `ActivityEstimate.softCue`).
    var softCue: Bool
    /// This Mac is playing video (see `MacMediaState.videoPlaying`); unknown counts as not playing.
    var macVideoPlaying: Bool

    init(
        time: Double,
        quality: EvidenceQuality = .valid,
        posture: Posture = .facing,
        awayFromScreen: Bool = false,
        inputIdleSeconds: Double = 0,
        possiblePhoneUse: Bool = false,
        handCount: Int = 0,
        faceCount: Int = 1,
        softCue: Bool = false,
        macVideoPlaying: Bool = false
    ) {
        self.time = time
        self.quality = quality
        self.posture = posture
        self.awayFromScreen = quality == .valid && awayFromScreen
        self.inputIdleSeconds = inputIdleSeconds
        self.possiblePhoneUse = quality == .valid && possiblePhoneUse
        self.handCount = handCount
        self.faceCount = faceCount
        self.softCue = quality == .valid && softCue
        self.macVideoPlaying = macVideoPlaying
    }

    /// Maps Milestone 0 signal output into Milestone 1 behavioral evidence.
    init(snapshot: SignalSnapshot, estimate: ActivityEstimate, media: MacMediaState = .unknown) {
        let quality: EvidenceQuality
        if !snapshot.time.isFinite {
            quality = .unknown
        } else if snapshot.vision.faceCount > 1 {
            // Multiple people in frame → suppress ambiguous association (spec §6.2, §7.1).
            quality = .multiplePeople
        } else if estimate.posture == .calibrating {
            quality = .calibrating
        } else if estimate.posture == .nobody {
            quality = .noPerson
        } else {
            quality = .valid
        }

        self.init(
            time: snapshot.time,
            quality: quality,
            posture: estimate.posture,
            awayFromScreen: estimate.posture.isAway,
            inputIdleSeconds: snapshot.input.any,
            possiblePhoneUse: estimate.possiblePhoneUse,
            handCount: snapshot.vision.handCount,
            faceCount: snapshot.vision.faceCount,
            softCue: estimate.softCue,
            macVideoPlaying: media.videoPlaying == true
        )
    }

    /// Any sign, strong or soft, that the person is looking somewhere other than the screen.
    var anyAwayCue: Bool { awayFromScreen || softCue }
}

/// Why an intervention reminder was emitted.
enum InterventionKind: String, Sendable, Equatable {
    /// A single corroborated away + idle episode passed the grace period.
    case sustainedEpisode
    /// Repeated short phone-away pickups exceeded the rolling-window threshold (spec §13.2).
    case repeatedShortPickups
    /// A long stretch without keyboard or mouse while sitting at the desk, looking elsewhere for
    /// much of it. Catches a phone held high enough that the head barely tilts.
    case idleAtDesk

    var headline: String {
        switch self {
        case .sustainedEpisode:
            return "You've been away from your screen for a while. Still working?"
        case .repeatedShortPickups:
            return "You've stepped away from your screen several times recently. Still working?"
        case .idleAtDesk:
            return "You haven't touched your Mac for a couple of minutes. Still working?"
        }
    }
}

/// Neutral user feedback actions on a reminder (spec §5.3, §13.2).
enum InterventionAction: Sendable, Equatable {
    case backToWork
    case takingABreak(duration: Double)
    case notADistraction
}

/// One emitted intervention event. Milestone 1 displays it in the diagnostics view;
/// Milestone 2 delivers it via `UNUserNotificationCenter`.
struct InterventionEvent: Sendable, Equatable {
    var episodeID: UUID
    var kind: InterventionKind
    var timestamp: Double
    var evidenceDuration: Double
    var recentPickupCount: Int
    var reasons: [BehaviorReason]
}

/// Immutable UI/diagnostic output produced by `BehaviorEngine` on every step or tick.
/// Holds no images, landmarks, app names, or identity data.
struct BehaviorSnapshot: Sendable, Equatable {
    var state: BehaviorState
    var stateSince: Double
    var evidenceDuration: Double
    var graceProgress: Double
    var recentPickupCount: Int
    var episodeID: UUID?
    var reasons: [BehaviorReason]
    var lastUpdate: Double
    var pendingIntervention: InterventionEvent?
    var cooldownRemaining: Double
    var breakRemaining: Double
    /// Seconds of the current stretch without keyboard or mouse while at the desk (0 when none).
    var idleStretchSeconds: Double = 0
    /// Share of that stretch with any sign of looking elsewhere, 0 to 1.
    var idleStretchCueShare: Double = 0

    static func initial(at now: Double = 0) -> BehaviorSnapshot {
        BehaviorSnapshot(
            state: .disabled,
            stateSince: now,
            evidenceDuration: 0,
            graceProgress: 0,
            recentPickupCount: 0,
            episodeID: nil,
            reasons: [.monitoringDisabled],
            lastUpdate: now,
            pendingIntervention: nil,
            cooldownRemaining: 0,
            breakRemaining: 0
        )
    }
}
