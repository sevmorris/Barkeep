import Foundation
import UserNotifications

enum NotificationService {
    static func showCompletionNotification(operation: String) async {
        let center = UNUserNotificationCenter.current()

        do {
            let settings = await center.notificationSettings()
            switch settings.authorizationStatus {
            case .notDetermined:
                let granted = try await center.requestAuthorization(options: [.alert, .sound])
                guard granted else { return }
            case .authorized, .provisional:
                break
            default:
                return
            }

            let content = UNMutableNotificationContent()
            content.title = "Barkeep"
            content.body = operation
            content.sound = .default

            let request = UNNotificationRequest(
                identifier: UUID().uuidString,
                content: content,
                trigger: nil
            )

            try await center.add(request)
        } catch {
            // Notification delivery is best-effort; failures are silent
        }
    }
}
