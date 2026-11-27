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
    /// Comma-separated IDs of collapsed categories, remembered between launches.
    @AppStorage("collapsedSidebarSections") private var collapsedRaw = ""

    private var collapsed: Set<String> {
        Set(collapsedRaw.split(separator: ",").map(String.init))
    }

    private func setCollapsed(_ ids: Set<String>) {
        collapsedRaw = ids.sorted().joined(separator: ",")
    }

    private func isExpanded(_ category: CleanupCategory) -> Binding<Bool> {
        Binding(
            get: { !collapsed.contains(category.id) },
            set: { expanded in
                var ids = collapsed
                if expanded { ids.remove(category.id) } else { ids.insert(category.id) }
                setCollapsed(ids)
            }
        )
    }

    var body: some View {
        List(selection: $route) {
            Section {
                Label("Overview", systemImage: "chart.pie").tag(Route.overview)
                Label("What Changed", systemImage: "chart.line.uptrend.xyaxis").tag(Route.changes)
                Label("Cleanup Rules", systemImage: "checklist").tag(Route.rules)
                Label("Disk Explorer", systemImage: "folder.badge.gearshape").tag(Route.explorer)
            }
            .collapsible(false)
            ForEach(CleanupCategory.allCases) { category in
                let states = model.states(in: category)
                if !states.isEmpty {
                    let expanded = isExpanded(category)
                    // The category title is a regular (non-selectable) row, not a Section header:
                    // macOS adds its own hover chevron on the right to any sidebar section header.
                    Section {
                        SidebarSectionHeader(title: category.title, states: states, isExpanded: expanded)
                            .padding(.top, 4)
                            .contextMenu {
                                Button("Collapse All") { setCollapsed(Set(CleanupCategory.allCases.map(\.id))) }
                                Button("Expand All") { setCollapsed([]) }
                                Divider()
                                Button("Collapse Others") {
                                    setCollapsed(Set(CleanupCategory.allCases.map(\.id)).subtracting([category.id]))
                                }
                            }
                        if expanded.wrappedValue {
                            ForEach(states) { state in
                                SidebarRow(state: state).tag(Route.provider(state.id))
                            }
                        }
                    }
                    .collapsible(false)
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .top) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Image(nsImage: Brand.appIcon)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: 26, height: 26)
                        .accessibilityHidden(true)
                    Text(Brand.name).font(.headline)
                    Spacer()
                }
                .help(Brand.tagline)
                DiskGauge(disk: model.disk)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .safeAreaInset(edge: .bottom) {
            HStack(spacing: 12) {
                Button { setCollapsed(Set(CleanupCategory.allCases.map(\.id))) } label: {
                    Image(systemName: "rectangle.compress.vertical")
                }
                .help("Collapse all sections")
                Button { setCollapsed([]) } label: {
                    Image(systemName: "rectangle.expand.vertical")
                }
                .help("Expand all sections")
                Spacer()
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
        }
        // Opening a source from elsewhere (Overview, What Changed) expands its section so it's visible.
        .onChange(of: route) { _, newRoute in
            guard case .provider(let id) = newRoute,
                  let category = model.state(for: id)?.provider.category,
                  collapsed.contains(category.id)
            else { return }
            var ids = collapsed
            ids.remove(category.id)
            setCollapsed(ids)
        }
    }
}

/// Section title with an always-visible chevron, plus its total so collapsed
/// sections still show how big they are. Clicking anywhere on it toggles the section.
struct SidebarSectionHeader: View {
    let title: String
    let states: [ProviderState]
    @Binding var isExpanded: Bool

    var body: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.15)) { isExpanded.toggle() }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.primary.opacity(0.75))
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .frame(width: 12)
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.primary.opacity(0.75))
                Spacer()
                if states.contains(where: { $0.status == .scanning || $0.status == .idle }) {
                    ProgressView().controlSize(.mini)
                } else {
                    let total = states.reduce(Int64(0)) { $0 + $1.total }
                    if total > 0 {
                        Text(ByteFormat.string(total))
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(isExpanded ? "Collapse \(title)" : "Expand \(title)")
        .accessibilityLabel("\(title), \(isExpanded ? "expanded" : "collapsed")")
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
                Image(systemName: "exclamationmark.triangle").foregroundStyle(DS.review)
            case .hidden:
                EmptyView()
            }
        }
    }
}
