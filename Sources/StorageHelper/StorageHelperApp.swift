import AppKit
import SwiftUI
import UserNotifications

@main
struct StorageHelperApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppModel()
    @State private var explorer = ExplorerModel()
    @AppStorage(AppSettings.showMenuBarKey) private var showMenuBar = true
    /// Observed so the View › Appearance checkmark updates when the mode changes anywhere.
    @AppStorage(AppearanceMode.key) private var appearanceRaw = AppearanceMode.system.rawValue

    var body: some Scene {
        WindowGroup(Brand.name, id: "main") {
            ContentView()
                .environment(model)
                .environment(explorer)
                .frame(minWidth: 900, minHeight: 560)
                .tint(DS.tint)
                .task { model.scanIfNeeded() }
        }
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About \(Brand.name)") { AboutPanel.show() }
            }
            CommandGroup(after: .sidebar) {
                Divider()
                Menu("Appearance") {
                    ForEach(Array(AppearanceMode.allCases.enumerated()), id: \.element) { index, mode in
                        Button {
                            AppearanceMode.set(mode)
                        } label: {
                            // Checkmark on the active mode, like other macOS menus.
                            if appearanceRaw == mode.rawValue { Label(mode.title, systemImage: "checkmark") } else { Text(mode.title) }
                        }
                        .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: [.command, .option])
                    }
                }
            }
            CommandGroup(after: .newItem) {
                Button("Scan Again") { model.scanAll() }
                    .keyboardShortcut("r", modifiers: .command)
            }
        }

        MenuBarExtra(isInserted: $showMenuBar) {
            MenuBarView().environment(model).tint(DS.tint)
        } label: {
            MenuBarLabel().environment(model)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView().tint(DS.tint)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Needed when launched via `swift run` (no .app bundle): show in Dock and take focus.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        MainActor.assumeIsolated {
            AppearanceMode.current.apply()
            if LowSpaceNotifier.isSupported { UNUserNotificationCenter.current().delegate = self }
        }
    }

    /// With the menu bar item on, closing the window keeps the app running in the menu bar.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        !UserDefaults.standard.bool(forKey: AppSettings.showMenuBarKey)
    }

    // Clicking the low-space notification opens "What Changed".
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse
    ) async {
        await MainActor.run { MainWindow.show(route: .changes) }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}
