import AppKit

/// Tracks the frontmost macOS application bundle identifier via `NSWorkspace`.
/// Reads only the application bundle ID and display name — never window titles,
/// document contents, browser URLs, or keystrokes, and requires no extra permissions.
@MainActor
final class ForegroundAppMonitor {
    struct AppIdentity: Sendable, Equatable {
        var bundleID: String?
        var localizedName: String?
    }

    private(set) var current: AppIdentity
    private let onChange: (AppIdentity) -> Void
    private var observer: NSObjectProtocol?

    init(onChange: @escaping (AppIdentity) -> Void) {
        self.onChange = onChange
        self.current = Self.readFrontmost()
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            let identity = AppIdentity(
                bundleID: app?.bundleIdentifier,
                localizedName: app?.localizedName
            )
            MainActor.assumeIsolated {
                guard let self, self.current != identity else { return }
                self.current = identity
                self.onChange(identity)
            }
        }
    }

    deinit {
        if let observer {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
    }

    func refresh() {
        let latest = Self.readFrontmost()
        guard latest != current else { return }
        current = latest
        onChange(latest)
    }

    private static func readFrontmost() -> AppIdentity {
        let app = NSWorkspace.shared.frontmostApplication
        return AppIdentity(bundleID: app?.bundleIdentifier, localizedName: app?.localizedName)
    }
}
