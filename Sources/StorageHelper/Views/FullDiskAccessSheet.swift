import AppKit
import Combine
import StorageCore
import SwiftUI

/// Shown at launch when Full Disk Access is missing.
///
/// macOS has no API to request Full Disk Access with a system prompt: the user must enable it
/// in System Settings. This sheet walks through that and polls until access is granted, then
/// closes itself and rescans.
struct FullDiskAccessSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @AppStorage(AppSettings.skipFullDiskAccessPromptKey) private var dontAskAgain = false
    @State private var openedSettings = false

    private let poll = Timer.publish(every: 1.5, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            BrandHeader()
            Divider()
            HStack(spacing: 14) {
                Image(systemName: "lock.shield.fill")
                    .font(.system(size: 40))
                    .foregroundStyle(DS.review)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Allow Full Disk Access").font(.title2.bold())
                    Text("Diskward needs it to measure the Trash, app caches and other protected folders. Without it, the numbers will be too low.")
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                }
            }

            VStack(alignment: .leading, spacing: 10) {
                step(1, "Open Privacy & Security › Full Disk Access.") {
                    Button("Open System Settings") {
                        NSWorkspace.shared.open(Permissions.fullDiskAccessSettingsURL)
                        openedSettings = true
                    }
                    .buttonStyle(.borderedProminent)
                }
                step(2, "Turn on Diskward. If it isn't listed, click + and choose the app, or drag it into the list.") {
                    Button("Show App in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
                    }
                }
                step(3, "Come back here. This window closes by itself once access is granted. If it doesn't, quit and reopen the app.") {
                    Button("Quit & Reopen") { Relauncher.relaunch() }
                }
            }
            .padding(14)
            .background(RoundedRectangle(cornerRadius: 10).fill(.background.secondary))

            if openedSettings {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Waiting for access…").foregroundStyle(.secondary)
                }
            }

            HStack {
                Toggle("Don't ask again at startup", isOn: $dontAskAgain)
                Spacer()
                Button("Not Now") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(22)
        .frame(width: 560)
        .onReceive(poll) { _ in checkAccess() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            checkAccess()
        }
    }

    private func checkAccess() {
        guard Permissions.hasFullDiskAccess() else { return }
        model.hasFullDiskAccess = true
        dismiss()
        model.scanAll()
    }

    private func step<Accessory: View>(_ number: Int, _ text: String, @ViewBuilder accessory: () -> Accessory) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Text("\(number)")
                .font(.headline)
                .frame(width: 26, height: 26)
                .background(Circle().fill(DS.tint.opacity(0.15)))
            Text(text).lineLimit(3)
            Spacer(minLength: 8)
            accessory()
        }
    }
}

@MainActor
enum Relauncher {
    /// Starts a new copy of the app once this one has exited, then quits.
    static func relaunch() {
        let path = Bundle.main.bundleURL.path
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        // Wait for this process to exit, then reopen the bundle.
        task.arguments = ["-c", "while kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null; do sleep 0.2; done; /usr/bin/open \"$0\"", path]
        try? task.run()
        NSApp.terminate(nil)
    }
}
