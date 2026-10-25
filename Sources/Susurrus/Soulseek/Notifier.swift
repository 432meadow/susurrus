import Foundation
@preconcurrency import UserNotifications

/// Posts user notifications (finished downloads, wishlist finds). Needs the app bundle: run
/// straight from `swift run` there's no bundle identifier and notifications are skipped.
@MainActor
enum Notifier {
    private static let presenter = Presenter()
    private static var isSetUp = false

    static func post(title: String, body: String) {
        guard Bundle.main.bundleIdentifier != nil else { return }
        let center = UNUserNotificationCenter.current()
        if !isSetUp {
            isSetUp = true
            center.delegate = presenter
        }
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
        }
    }

    /// Shows banners even while susurrus is the active app.
    private final class Presenter: NSObject, UNUserNotificationCenterDelegate {
        func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                    withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
            completionHandler([.banner, .sound])
        }
    }
}
