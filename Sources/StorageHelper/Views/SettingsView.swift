import AppKit
import StorageCore
import SwiftUI

import ServiceManagement

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettingsView().tabItem { Label("General", systemImage: "gearshape") }
            ProjectFoldersSettingsView().tabItem { Label("Projects", systemImage: "folder") }
        }
        .frame(width: 500)
    }
}

struct GeneralSettingsView: View {
    @AppStorage(AppSettings.showMenuBarKey) private var showMenuBar = true
    @AppStorage(AppSettings.lowSpaceAlertsKey) private var alerts = true
    @AppStorage(AppSettings.lowSpaceThresholdGBKey) private var thresholdGB = 30
    @AppStorage(AppSettings.dailyScanKey) private var dailyScan = true
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?

    var body: some View {
        Form {
            Section("Menu bar") {
                Toggle("Show free space in the menu bar", isOn: $showMenuBar)
                Text("When it's on, closing the window keeps Diskward running in the menu bar.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Open at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, enabled in setLaunchAtLogin(enabled) }
                if let loginError {
                    Text(loginError).font(.caption).foregroundStyle(DS.critical)
                }
            }
            Section("Alerts") {
                Toggle("Notify me when free space is low", isOn: $alerts)
                    .onChange(of: alerts) { _, on in if on { LowSpaceNotifier.requestPermission() } }
                Stepper(value: $thresholdGB, in: 5...500, step: 5) {
                    Text("Warn below \(thresholdGB) GB free")
                }
                .disabled(!alerts)
                Toggle("Scan once a day while running (keeps \"What Changed\" up to date)", isOn: $dailyScan)
                if !LowSpaceNotifier.isSupported {
                    Text("Notifications only work in the built app (scripts/build-app.sh), not with `swift run`.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            loginError = nil
        } catch {
            loginError = "Couldn't change this: \(error.localizedDescription). Move the app to /Applications and try again."
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }
}

struct ProjectFoldersSettingsView: View {
    @State private var roots: [URL] = AppSettings.nodeModulesRoots
        ?? NodeModulesProvider.defaultRootNames.map { Paths.home.appendingPathComponent($0) }
            .filter { FS.isDirectory($0) }
    @State private var selected: URL?

    var body: some View {
        Form {
            Section {
                List(roots, id: \.self, selection: $selected) { url in
                    Text(Paths.display(url)).font(.system(.body, design: .monospaced))
                }
                .frame(minHeight: 160)
                HStack {
                    Button("Add Folder…") { addFolder() }
                    Button("Remove") {
                        roots.removeAll { $0 == selected }
                        save()
                    }
                    .disabled(selected == nil)
                    Spacer()
                    Button("Reset to Defaults") {
                        AppSettings.nodeModulesRoots = nil
                        roots = NodeModulesProvider.defaultRootNames.map { Paths.home.appendingPathComponent($0) }
                            .filter { FS.isDirectory($0) }
                    }
                }
            } header: {
                Text("Project folders searched for node_modules")
            } footer: {
                Text("Changes take effect the next time you open the app.").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding()
    }

    private func addFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        if panel.runModal() == .OK {
            roots += panel.urls.filter { !roots.contains($0) }
            save()
        }
    }

    private func save() { AppSettings.nodeModulesRoots = roots }
}
