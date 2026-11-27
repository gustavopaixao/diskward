import AppKit
import StorageCore
import UserNotifications

extension Notification.Name {
    /// Ask the main window to show a route (posted when a notification is clicked).
    static let showRoute = Notification.Name("StorageHelper.showRoute")
}

/// Sends the "low disk space" notification.
@MainActor
enum LowSpaceNotifier {
    /// Notifications need a real .app bundle; `swift run` has none and UNUserNotificationCenter would crash.
    static var isSupported: Bool { Bundle.main.bundleIdentifier != nil && Bundle.main.bundleURL.pathExtension == "app" }

    static func requestPermission() {
        guard isSupported else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    static func checkAndNotify(disk: DiskInfo, growth: Growth?) {
        let defaults = UserDefaults.standard
        guard defaults.bool(forKey: AppSettings.lowSpaceAlertsKey), isSupported else { return }

        let threshold = Int64(defaults.integer(forKey: AppSettings.lowSpaceThresholdGBKey)) * 1_000_000_000
        let lastDate = defaults.object(forKey: AppSettings.lastAlertDateKey) as? Date
        let lastFree = defaults.object(forKey: AppSettings.lastAlertFreeKey) as? Int64
        let policy = LowSpacePolicy(threshold: threshold)
        guard policy.shouldAlert(free: disk.available, lastAlert: lastDate, lastAlertFree: lastFree) else { return }

        defaults.set(Date(), forKey: AppSettings.lastAlertDateKey)
        defaults.set(disk.available, forKey: AppSettings.lastAlertFreeKey)

        let content = UNMutableNotificationContent()
        content.title = "Low disk space: \(ByteFormat.string(disk.available)) free"
        if let top = growth?.grown.prefix(2), !top.isEmpty {
            content.body = "Grew recently: " + top.map { "\($0.title) \(SignedBytes.string($0.delta))" }.joined(separator: ", ")
                + ". Click to review."
        } else {
            content.body = "Click to see what you can clean."
        }
        content.sound = .default
        Task {
            let center = UNUserNotificationCenter.current()
            guard (try? await center.requestAuthorization(options: [.alert, .sound])) == true else { return }
            let request = UNNotificationRequest(identifier: "low-space", content: content, trigger: nil)
            try? await center.add(request)
        }
    }
}

/// Lets non-view code (notification clicks) open the main window.
@MainActor
enum MainWindow {
    static var open: (() -> Void)?

    static func show(route: Route? = nil) {
        NSApp.activate(ignoringOtherApps: true)
        let hasWindow = NSApp.windows.contains { $0.isVisible && $0.canBecomeMain }
        if !hasWindow { open?() }
        if let route {
            // Give a newly opened window a moment to subscribe.
            DispatchQueue.main.asyncAfter(deadline: .now() + (hasWindow ? 0 : 0.4)) {
                NotificationCenter.default.post(name: .showRoute, object: route)
            }
        }
    }
}
