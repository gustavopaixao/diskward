import AppKit
import StorageCore
import SwiftUI

struct SettingsView: View {
    @State private var roots: [URL] = AppSettings.nodeModulesRoots
        ?? NodeModulesProvider.defaultRootNames.map { Paths.home.appendingPathComponent($0) }
            .filter { FS.isDirectory($0) }
    @State private var selected: URL?

    var body: some View {
        Form {
            Section {
                List(roots, id: \.self, selection: $selected) { url in
                    Text(Paths.display(url))
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
        .frame(width: 480)
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
