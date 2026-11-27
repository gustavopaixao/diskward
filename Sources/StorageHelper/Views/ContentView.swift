import AppKit
import StorageCore
import SwiftUI

enum Route: Hashable {
    case overview
    case changes
    case rules
    case explorer
    case provider(String)
}

struct ContentView: View {
    @Environment(AppModel.self) private var model
    @State private var route: Route? = .overview
    @Environment(\.openWindow) private var openWindow
    @State private var showingConfirm = false
    @State private var showingFullDiskAccess = AppSettings.shouldPromptForFullDiskAccess

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            SidebarView(route: $route)
                .navigationSplitViewColumnWidth(min: 230, ideal: 260)
        } detail: {
            switch route ?? .overview {
            case .overview: OverviewView(route: $route)
            case .changes: ChangesView(route: $route)
            case .rules: RulesView()
            case .explorer: DiskExplorerView()
            case .provider(let id): ProviderDetailView(providerID: id)
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                if model.isScanning {
                    Button { model.cancelScan() } label: { Label("Stop", systemImage: "stop.circle") }
                        .help("Stop scanning")
                } else {
                    Button { model.scanAll() } label: { Label("Scan", systemImage: "arrow.clockwise") }
                        .help("Scan again (⌘R)")
                }
                Button {
                    showingConfirm = true
                } label: {
                    Label("Clean \(ByteFormat.string(model.selectedSize))", systemImage: "sparkles")
                        .labelStyle(.titleAndIcon)
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.selection.isEmpty || model.isCleaning)
                .help("Review and clean the selected items")
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .showRoute)) { note in
            if let target = note.object as? Route { route = target }
        }
        .onAppear { MainWindow.open = { openWindow(id: "main") } }
        .sheet(isPresented: $showingFullDiskAccess) {
            FullDiskAccessSheet()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            // Access granted while the app was in the background (e.g. via the Overview banner):
            // pick it up and rescan.
            if !model.hasFullDiskAccess, Permissions.hasFullDiskAccess() {
                model.hasFullDiskAccess = true
                model.scanAll()
            }
        }
        .sheet(isPresented: $showingConfirm) {
            CleanConfirmSheet(items: model.selectedItems)
        }
        .sheet(item: Binding(
            get: { model.lastReport.map(ReportWrapper.init) },
            set: { if $0 == nil { model.lastReport = nil } }
        )) { wrapper in
            CleanReportSheet(report: wrapper.report)
        }
    }
}

struct ReportWrapper: Identifiable {
    let id = UUID()
    let report: CleanReport
}

struct SidebarView: View {
    @Environment(AppModel.self) private var model
    @Binding var route: Route?

    var body: some View {
        List(selection: $route) {
            Section {
                Label("Overview", systemImage: "chart.pie").tag(Route.overview)
                Label("What Changed", systemImage: "chart.line.uptrend.xyaxis").tag(Route.changes)
                Label("Cleanup Rules", systemImage: "checklist").tag(Route.rules)
                Label("Disk Explorer", systemImage: "folder.badge.gearshape").tag(Route.explorer)
            }
            ForEach(CleanupCategory.allCases) { category in
                let states = model.states(in: category)
                if !states.isEmpty {
                    Section(category.title) {
                        ForEach(states) { state in
                            SidebarRow(state: state).tag(Route.provider(state.id))
                        }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .top) {
            DiskGauge(disk: model.disk)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
        }
    }
}

struct SidebarRow: View {
    let state: ProviderState

    var body: some View {
        HStack {
            Label(state.provider.title, systemImage: state.provider.icon)
            Spacer()
            switch state.status {
            case .scanning, .idle:
                ProgressView().controlSize(.small)
            case .done:
                Text(state.total > 0 ? ByteFormat.string(state.total) : "—")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            case .failed, .unavailable:
                Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
            case .hidden:
                EmptyView()
            }
        }
    }
}
