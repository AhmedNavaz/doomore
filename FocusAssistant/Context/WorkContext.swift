import Foundation

/// How the app decides whether the user is currently in a work context.
enum WorkContextMode: String, Sendable, Equatable, CaseIterable, Identifiable {
    /// Explicit override: every non-meeting app counts as work while enabled.
    case manualWork
    /// Automatic mode: active only when the frontmost app is in `workBundleIDs`.
    case selectedApps
    /// Work context is turned off; monitoring stays paused with no reminders.
    case inactive

    var id: String { rawValue }

    var label: String {
        switch self {
        case .manualWork: return "Manual work mode"
        case .selectedApps: return "Selected work apps"
        case .inactive: return "Off (no reminders)"
        }
    }
}

/// Configurable app lists and mode for work-context gating.
/// Thresholds and bundle sets stay configurable in code for Milestone 1.
struct WorkContextConfig: Sendable, Equatable {
    var mode: WorkContextMode
    var workBundleIDs: Set<String>
    var meetingBundleIDs: Set<String>

    /// Dedicated coding and writing apps. Arbitrary browsers and terminals are
    /// deliberately excluded by default (spec §5.2).
    static let defaultWorkBundleIDs: Set<String> = [
        "com.apple.dt.Xcode",
        "com.microsoft.VSCode",
        "com.todesktop.230313mzl4w4u92", // Cursor
        "dev.zed.Zed",
        "com.apple.Notes",
        "com.apple.iWork.Pages",
    ]

    /// Video-call apps that always suppress distraction reminders.
    static let defaultMeetingBundleIDs: Set<String> = [
        "us.zoom.xos",
        "com.apple.FaceTime",
        "com.microsoft.teams",
        "com.microsoft.teams2",
        "Cisco-Systems.Spark",
    ]

    init(
        mode: WorkContextMode = .selectedApps,
        workBundleIDs: Set<String> = WorkContextConfig.defaultWorkBundleIDs,
        meetingBundleIDs: Set<String> = WorkContextConfig.defaultMeetingBundleIDs
    ) {
        self.mode = mode
        self.workBundleIDs = workBundleIDs
        self.meetingBundleIDs = meetingBundleIDs
    }
}

/// Pure snapshot of system, camera, and foreground-app context at one instant.
/// Contains only the frontmost bundle identifier — never window titles, tabs, or content.
struct WorkContextSnapshot: Sendable, Equatable {
    var monitoringEnabled: Bool
    var cameraAvailable: Bool
    var cameraUnavailableReason: String?
    var sessionActive: Bool
    var userPaused: Bool
    var breakUntil: Double?
    var frontmostBundleID: String?
    var config: WorkContextConfig

    init(
        monitoringEnabled: Bool = false,
        cameraAvailable: Bool = false,
        cameraUnavailableReason: String? = nil,
        sessionActive: Bool = true,
        userPaused: Bool = false,
        breakUntil: Double? = nil,
        frontmostBundleID: String? = nil,
        config: WorkContextConfig = WorkContextConfig()
    ) {
        self.monitoringEnabled = monitoringEnabled
        self.cameraAvailable = cameraAvailable
        self.cameraUnavailableReason = cameraUnavailableReason
        self.sessionActive = sessionActive
        self.userPaused = userPaused
        self.breakUntil = breakUntil
        self.frontmostBundleID = frontmostBundleID
        self.config = config
    }

    var isMeetingActive: Bool {
        guard let bundleID = frontmostBundleID else { return false }
        return config.meetingBundleIDs.contains(bundleID)
    }

    var isWorkAppActive: Bool {
        guard !isMeetingActive else { return false }
        switch config.mode {
        case .manualWork:
            return true
        case .selectedApps:
            guard let bundleID = frontmostBundleID else { return false }
            return config.workBundleIDs.contains(bundleID)
        case .inactive:
            return false
        }
    }

    func isBreakActive(at now: Double) -> Bool {
        guard let breakUntil, breakUntil.isFinite, now.isFinite else { return false }
        return now < breakUntil
    }
}
