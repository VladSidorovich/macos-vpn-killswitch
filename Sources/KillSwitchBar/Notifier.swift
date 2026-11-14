import Foundation
import UserNotifications
import KillSwitchClient

/// Posts macOS notifications. Only works from a real .app bundle; a bare `swift run` binary stays silent.
final class Notifier {
    private let enabled: Bool

    init() {
        enabled = Bundle.main.bundleIdentifier != nil && Bundle.main.bundlePath.hasSuffix(".app")
        if enabled {
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        }
    }

    func post(_ n: AppNotification) {
        guard enabled else { return }
        let c = UNMutableNotificationContent()
        c.title = n.title
        c.body = n.body
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: c, trigger: nil))
    }
}
