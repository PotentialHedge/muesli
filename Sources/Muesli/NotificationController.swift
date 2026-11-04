import Foundation
import MuesliCore
import UserNotifications

/// The "Zoom is using your microphone. Record?" prompt.
@MainActor
final class NotificationController: NSObject, UNUserNotificationCenterDelegate {
    enum Action {
        case record(appID: String)
        case alwaysRecord(appID: String)
    }

    var onAction: ((Action) -> Void)?

    nonisolated private static let category = "meeting-detected"
    nonisolated private static let recordAction = "record"
    nonisolated private static let alwaysRecordAction = "always-record"
    nonisolated private static let promptID = "meeting-prompt"
    nonisolated private static let appIDKey = "appID"

    /// UNUserNotificationCenter crashes outside an app bundle (e.g. `swift run`).
    private var center: UNUserNotificationCenter? {
        Bundle.main.bundleIdentifier == nil ? nil : .current()
    }

    func setUp() {
        guard let center else { return }
        center.delegate = self
        center.setNotificationCategories([
            UNNotificationCategory(
                identifier: Self.category,
                actions: [
                    UNNotificationAction(identifier: Self.recordAction, title: "Record"),
                    UNNotificationAction(identifier: Self.alwaysRecordAction, title: "Always Record This App"),
                ],
                intentIdentifiers: []
            ),
        ])
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func promptToRecord(_ app: MeetingApp) {
        guard let center else { return }
        let content = UNMutableNotificationContent()
        content.title = "\(app.name) is using your microphone"
        content.body = "Record this meeting?"
        content.categoryIdentifier = Self.category
        content.userInfo = [Self.appIDKey: app.id]
        center.add(UNNotificationRequest(identifier: Self.promptID, content: content, trigger: nil))
    }

    func removePrompt() {
        center?.removeDeliveredNotifications(withIdentifiers: [Self.promptID])
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let actionID = response.actionIdentifier
        guard let appID = response.notification.request.content.userInfo[Self.appIDKey] as? String else { return }
        await MainActor.run {
            switch actionID {
            case Self.recordAction: onAction?(.record(appID: appID))
            case Self.alwaysRecordAction: onAction?(.alwaysRecord(appID: appID))
            default: break  // clicking the banner itself just dismisses it
            }
        }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}
