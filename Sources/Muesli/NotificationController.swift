import Foundation
import MuesliCore
import UserNotifications

/// The "Zoom is using your microphone. Record?" prompt. Shortly after another meeting ended, it
/// also offers to continue that one instead.
@MainActor
final class NotificationController: NSObject, UNUserNotificationCenterDelegate {
    enum Action {
        case record(appID: String)
        case alwaysRecord(appID: String)
        case continueMeeting(appID: String)
    }

    var onAction: ((Action) -> Void)?

    nonisolated private static let category = "meeting-detected"
    nonisolated private static let continuableCategory = "meeting-detected-continuable"
    nonisolated private static let continueAction = "continue"
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
        let alwaysRecord = UNNotificationAction(identifier: Self.alwaysRecordAction, title: "Always Record This App")
        center.setNotificationCategories([
            UNNotificationCategory(
                identifier: Self.category,
                actions: [UNNotificationAction(identifier: Self.recordAction, title: "Record"), alwaysRecord],
                intentIdentifiers: []
            ),
            UNNotificationCategory(
                identifier: Self.continuableCategory,
                actions: [
                    UNNotificationAction(identifier: Self.continueAction, title: "Continue Previous Meeting"),
                    UNNotificationAction(identifier: Self.recordAction, title: "Record New Meeting"),
                    alwaysRecord,
                ],
                intentIdentifiers: []
            ),
        ])
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    /// - Parameter previous: a recently ended meeting that this one could continue, if any.
    func promptToRecord(_ app: MeetingApp, previous: String? = nil) {
        guard let center else { return }
        let content = UNMutableNotificationContent()
        content.title = "\(app.name) is using your microphone"
        if let previous {
            content.body = "Record this meeting, or continue “\(previous)”?"
            content.categoryIdentifier = Self.continuableCategory
        } else {
            content.body = "Record this meeting?"
            content.categoryIdentifier = Self.category
        }
        content.userInfo = [Self.appIDKey: app.id]
        // Asking is only useful while the meeting is on, so try to get past a Focus. Without the
        // time-sensitive entitlement this needs Muesli allowed in the Focus's settings.
        content.interruptionLevel = .timeSensitive
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
            case Self.continueAction: onAction?(.continueMeeting(appID: appID))
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
