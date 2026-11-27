import Foundation
import UserNotifications

/// Pure mapping between reminder events and macOS notification content and actions
/// (spec §1.2, §5.3, §13.2). No images, app names or private content are ever included.
enum ReminderNotification {
    static let categoryID = "focus.reminder"
    static let backToWorkID = "focus.backToWork"
    static let breakID = "focus.break"
    static let quickReplyID = "focus.notADistraction"

    struct Content: Equatable {
        var identifier: String
        var title: String
        var body: String
    }

    static func content(for event: InterventionEvent) -> Content {
        Content(identifier: event.episodeID.uuidString, title: "FocusAssistant", body: event.kind.headline)
    }

    /// Maps a notification response to an engine action. Opening or dismissing the
    /// notification is not feedback, so it returns nil.
    static func action(forResponse identifier: String, breakSeconds: Double) -> InterventionAction? {
        switch identifier {
        case backToWorkID: return .backToWork
        case breakID: return .takingABreak(duration: breakSeconds)
        case quickReplyID: return .notADistraction
        default: return nil
        }
    }

    static func breakTitle(seconds: Double) -> String {
        "Taking a break (\(max(1, Int((seconds / 60).rounded()))) min)"
    }
}

/// What the person allowed in System Settings → Notifications for this app.
enum NotificationPermission: Equatable {
    case unknown
    case notAsked
    case allowed
    case denied
}

/// Delivers reminders through `UNUserNotificationCenter`. Permission is requested only when the
/// person starts monitoring, never at launch, and a refusal is shown in the menu, not re-prompted.
@MainActor
final class ReminderNotifier: NSObject, UNUserNotificationCenterDelegate {
    private(set) var permission: NotificationPermission = .unknown
    var onPermissionChange: ((NotificationPermission) -> Void)?
    /// Called on the main actor with the engine action chosen in a notification.
    var onAction: ((InterventionAction) -> Void)?
    private let breakSeconds: Double
    private var center: UNUserNotificationCenter { .current() }

    init(breakSeconds: Double) {
        self.breakSeconds = breakSeconds
        super.init()
        center.delegate = self
        let actions = [
            UNNotificationAction(identifier: ReminderNotification.backToWorkID, title: "Back to work"),
            UNNotificationAction(identifier: ReminderNotification.breakID,
                                 title: ReminderNotification.breakTitle(seconds: breakSeconds)),
            UNNotificationAction(identifier: ReminderNotification.quickReplyID, title: "Quick reply / Not a distraction"),
        ]
        center.setNotificationCategories([
            UNNotificationCategory(identifier: ReminderNotification.categoryID, actions: actions,
                                   intentIdentifiers: [], options: []),
        ])
        refreshPermission()
    }

    func refreshPermission() {
        center.getNotificationSettings { [weak self] settings in
            let value: NotificationPermission
            switch settings.authorizationStatus {
            case .notDetermined: value = .notAsked
            case .denied: value = .denied
            case .authorized, .provisional: value = .allowed
            @unknown default: value = .unknown
            }
            DispatchQueue.main.async { self?.setPermission(value) }
        }
    }

    /// Asks once, only if macOS has never asked. Called from an explicit Start monitoring.
    func requestPermissionIfNeeded() {
        guard permission == .notAsked || permission == .unknown else { return }
        center.requestAuthorization(options: [.alert, .sound]) { [weak self] _, _ in
            DispatchQueue.main.async { self?.refreshPermission() }
        }
    }

    func deliver(_ event: InterventionEvent) {
        let value = ReminderNotification.content(for: event)
        let content = UNMutableNotificationContent()
        content.title = value.title
        content.body = value.body
        content.categoryIdentifier = ReminderNotification.categoryID
        // A sound matters: the person is probably looking at their phone, not this screen.
        content.sound = .default
        center.add(UNNotificationRequest(identifier: value.identifier, content: content, trigger: nil))
    }

    /// Removes reminders that no longer apply, for example after an answer in the window.
    func clearDelivered() {
        center.removeAllDeliveredNotifications()
    }

    private func setPermission(_ value: NotificationPermission) {
        guard value != permission else { return }
        permission = value
        onPermissionChange?(value)
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound, .list])
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        let identifier = response.actionIdentifier
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self,
                      let action = ReminderNotification.action(forResponse: identifier, breakSeconds: self.breakSeconds)
                else { return }
                self.onAction?(action)
            }
        }
        completionHandler()
    }
}
