import AppKit
import SwiftUI

@main
struct StorageHelperApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppModel()
    @State private var explorer = ExplorerModel()

    var body: some Scene {
        WindowGroup("Storage Helper") {
            ContentView()
                .environment(model)
                .environment(explorer)
                .frame(minWidth: 900, minHeight: 560)
                .task { model.scanAll() }
        }
        .commands {
            CommandGroup(after: .newItem) {
                Button("Scan Again") { model.scanAll() }
                    .keyboardShortcut("r", modifiers: .command)
            }
        }

        Settings {
            SettingsView()
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Needed when launched via `swift run` (no .app bundle): show in Dock and take focus.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
