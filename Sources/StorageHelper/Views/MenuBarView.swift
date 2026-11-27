import StorageCore
import SwiftUI

/// Menu bar label: free space at a glance, with a warning icon when low.
struct MenuBarLabel: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @AppStorage(AppSettings.lowSpaceThresholdGBKey) private var thresholdGB = 30

    var body: some View {
        let free = model.disk?.available ?? 0
        let low = free < Int64(thresholdGB) * 1_000_000_000
        // Template glyph + text: macOS tints both for light/dark menu bars and the highlight state.
        HStack(spacing: 4) {
            Brand.menuBarImage
            Text((low ? "⚠︎ " : "") + (model.disk.map { ByteFormat.string($0.available) } ?? ""))
        }
        .accessibilityLabel(low ? "\(Brand.name): low disk space" : Brand.name)
        .onAppear { MainWindow.open = { openWindow(id: "main") } }
    }
}

struct MenuBarView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            BrandHeader(iconSize: 28, showTagline: false)
            DiskGauge(disk: model.disk)

            if let growth = model.growth() {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Since \(growth.from.date.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption.bold())
                    Text("Free space \(SignedBytes.string(growth.freeDelta))").font(.callout)
                    ForEach(growth.grown.prefix(3)) { entry in
                        HStack {
                            Image(systemName: "arrow.up.right").foregroundStyle(DS.review).font(.caption)
                            Text(entry.title).lineLimit(1)
                            Spacer()
                            Text(SignedBytes.string(entry.delta)).monospacedDigit()
                        }
                        .font(.caption)
                    }
                }
            }

            HStack {
                Text("Reclaimable").foregroundStyle(.secondary)
                Spacer()
                if model.isScanning {
                    ProgressView().controlSize(.small)
                } else {
                    Text(ByteFormat.string(model.totalReclaimable)).monospacedDigit()
                }
            }
            .font(.callout)

            Divider()

            Button { open(route: .overview) } label: { Label("Open Diskward", systemImage: "macwindow") }
            Button { open(route: .changes) } label: { Label("What Changed", systemImage: "chart.line.uptrend.xyaxis") }
            let matches = model.ruleMatches
            Button { open(route: .rules) } label: {
                Label("Apply My Rules (\(ByteFormat.string(matches.reduce(0) { $0 + $1.size })))", systemImage: "checklist")
            }
            .disabled(matches.isEmpty || model.isScanning)
            Button { model.scanAll() } label: { Label("Scan Now", systemImage: "arrow.clockwise") }
                .disabled(model.isScanning)
            Divider()
            HStack {
                AppearancePicker(showsLabels: false)
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
            }
            HStack {
                SettingsLink { Text("Settings…") }
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
            }
        }
        .buttonStyle(.borderless)
        .padding(14)
        .frame(width: 280)
        .onAppear { model.refreshDisk() }
    }

    private func open(route: Route) {
        MainWindow.open = { openWindow(id: "main") }
        MainWindow.show(route: route)
    }
}
