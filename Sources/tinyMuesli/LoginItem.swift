import ServiceManagement

/// Opening tinyMuesli at login, so it's there to notice meetings.
@MainActor
enum LoginItem {
    static var isEnabled: Bool {
        // Waiting for approval in System Settings → Login Items still counts: it's what the user chose.
        [.enabled, .requiresApproval].contains(SMAppService.mainApp.status)
    }

    /// Returns an error message if macOS refused.
    @discardableResult
    static func set(_ enabled: Bool) -> String? {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            return nil
        } catch {
            return "Couldn't \(enabled ? "add tinyMuesli to" : "remove tinyMuesli from") your login items: \(error.localizedDescription)"
        }
    }
}
