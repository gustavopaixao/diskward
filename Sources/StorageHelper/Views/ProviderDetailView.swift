import AppKit
import StorageCore
import SwiftUI

struct ProviderDetailView: View {
    @Environment(AppModel.self) private var model
    let providerID: String
    @State private var sortOrder = [KeyPathComparator(\CleanupItem.size, order: .reverse)]
    @State private var confirmItems: [CleanupItem]?
    /// Selected tab (for providers whose items have tabs, e.g. Docker).
    @State private var selectedTab: String?
    /// Inside a tab: show in-use items instead of unused ones.
    @State private var showInUse = false

    var body: some View {
        if let state = model.state(for: providerID) {
            VStack(alignment: .leading, spacing: 0) {
                header(state)
                Divider()
                content(state)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .navigationTitle(state.provider.title)
            .sheet(item: Binding(
                get: { confirmItems.map(ItemsWrapper.init) },
                set: { if $0 == nil { confirmItems = nil } }
            )) { wrapper in
                CleanConfirmSheet(items: wrapper.items)
            }
        } else {
            EmptyStateView(icon: "questionmark.folder", title: "Not found")
        }
    }

    @ViewBuilder private func header(_ state: ProviderState) -> some View {
        let selected = state.items.filter { model.selection.contains($0.id) }
        VStack(alignment: .leading, spacing: 8) {
            if let note = state.provider.note {
                // No .fixedSize here: at narrow widths it made the window's minimum height
                // ~1900pt, which pushed the whole window content up under the toolbar.
                Label(note, systemImage: "info.circle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .help(note)
            }
            let visible = visibleItems(state)
            HStack {
                Text("\(visible.count) items · \(ByteFormat.string(visible.reduce(0) { $0 + $1.size }))")
                    .font(.headline.monospacedDigit())
                Spacer()
                if !visible.isEmpty {
                    Button("Select All") { model.setSelected(true, items: visible) }
                    Button("Select None") { model.setSelected(false, items: visible) }
                }
                Button { model.rescan(providerID: providerID) } label: { Image(systemName: "arrow.clockwise") }
                    .help("Rescan \(state.provider.title)")
                if !state.items.isEmpty {
                    Button("Clean \(ByteFormat.string(selected.reduce(0) { $0 + $1.size }))") {
                        confirmItems = selected
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(selected.isEmpty || model.isCleaning)
                }
            }
            .disabled(state.status == .scanning)
        }
        .padding()
    }

    @ViewBuilder private func content(_ state: ProviderState) -> some View {
        switch state.status {
        case .idle, .scanning:
            ProgressView("Scanning \(state.provider.title)…").frame(maxWidth: .infinity, maxHeight: .infinity)
        case .unavailable(let reason):
            EmptyStateView(icon: "exclamationmark.triangle", title: "Can't scan right now", message: reason, tint: DS.review) {
                Button("Try Again") { model.rescan(providerID: providerID) }
            }
        case .failed(let error):
            EmptyStateView(icon: "xmark.octagon", title: "Scan failed", message: error, tint: DS.critical) {
                Button("Try Again") { model.rescan(providerID: providerID) }
            }
        case .hidden:
            EmptyStateView(icon: "nosign", title: "Not installed",
                           message: "\(state.provider.title) wasn't found on this Mac.")
        case .done where state.items.isEmpty:
            EmptyStateView(icon: "checkmark.circle", title: "Nothing to clean",
                           message: "\(state.provider.title) isn't using any space worth cleaning.",
                           tint: DS.reclaimable)
        case .done:
            VStack(spacing: 0) {
                filterBar(state)
                if visibleItems(state).isEmpty {
                    EmptyStateView(icon: "checkmark.circle", title: "Nothing here",
                                   message: "No items in this view. Try the other tab or switch.",
                                   tint: DS.reclaimable)
                } else {
                    itemTable(state)
                }
            }
        }
    }

    // MARK: Tabs and in-use switch

    /// Tab names in display order (empty for providers without tabs).
    private func tabs(_ state: ProviderState) -> [String] {
        var seen = Set<String>()
        return state.items
            .sorted { $0.groupOrder < $1.groupOrder }
            .compactMap(\.tab)
            .filter { seen.insert($0).inserted }
    }

    private func currentTab(_ state: ProviderState) -> String? {
        let all = tabs(state)
        if let selectedTab, all.contains(selectedTab) { return selectedTab }
        return all.first
    }

    private func itemsInCurrentTab(_ state: ProviderState) -> [CleanupItem] {
        guard let tab = currentTab(state) else { return state.items }
        return state.items.filter { $0.tab == tab }
    }

    /// Items shown in the table: current tab, then the in-use switch.
    private func visibleItems(_ state: ProviderState) -> [CleanupItem] {
        let inTab = itemsInCurrentTab(state)
        guard inTab.contains(where: { $0.usage != nil }) else { return inTab }
        return inTab.filter { ($0.usage?.inUse ?? false) == showInUse }
    }

    @ViewBuilder private func filterBar(_ state: ProviderState) -> some View {
        let allTabs = tabs(state)
        let inTab = itemsInCurrentTab(state)
        let usages = inTab.compactMap(\.usage)
        if !allTabs.isEmpty {
            HStack(spacing: 16) {
                Picker("Show", selection: Binding(
                    get: { currentTab(state) ?? "" },
                    set: { selectedTab = $0; showInUse = false }
                )) {
                    ForEach(allTabs, id: \.self) { tab in
                        let items = state.items.filter { $0.tab == tab }
                        Text("\(tab)  \(ByteFormat.string(items.reduce(0) { $0 + $1.size }))").tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()

                if !usages.isEmpty {
                    let unusedLabel = usages.first { !$0.inUse }?.label ?? Usage.unused.label
                    let usedLabel = usages.first { $0.inUse }?.label ?? Usage.used.label
                    let unusedCount = usages.filter { !$0.inUse }.count
                    Picker("Usage", selection: $showInUse) {
                        Text("\(unusedLabel) (\(unusedCount))").tag(false)
                        Text("\(usedLabel) (\(usages.count - unusedCount))").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                }
                Spacer()
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
            Divider()
        }
    }

    private func itemTable(_ state: ProviderState) -> some View {
        let items = visibleItems(state).sorted(using: sortOrder)
        let maxSize = items.map(\.size).max() ?? 0
        return Table(items, sortOrder: $sortOrder) {
            TableColumn("") { item in
                Toggle("", isOn: Binding(
                    get: { model.selection.contains(item.id) },
                    set: { model.setSelected($0, items: [item]) }
                ))
                .labelsHidden()
                .disabled(!item.action.isActionable)
            }
            .width(24)

            TableColumn("Name", value: \.title) { item in
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(item.title).fontWeight(.medium).lineLimit(1)
                        SafetyBadge(safety: item.safety)
                    }
                    Text(item.note ?? item.detail)
                        .font(item.note == nil && (item.detail.hasPrefix("~") || item.detail.hasPrefix("/")) ? .technical : .caption)
                        .foregroundStyle(item.note == nil ? Color.secondary : DS.review)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .help(item.detail)
            }

            TableColumn("Size", value: \.size) { item in
                VStack(alignment: .trailing, spacing: 3) {
                    Text(ByteFormat.string(item.size)).monospacedDigit()
                    SizeBar(value: item.size, maxValue: maxSize).frame(width: 80)
                }
                .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(min: 90, ideal: 110, max: 140)

            TableColumn("Modified") { item in
                Text(item.lastModified?.relative ?? "—").foregroundStyle(.secondary)
            }
            .width(min: 90, ideal: 120, max: 160)

            TableColumn("Action") { item in
                ActionCell(item: item) { confirmItems = [item] }
            }
            .width(min: 220, ideal: 300)
        }
        .contextMenu(forSelectionType: CleanupItem.ID.self) { ids in
            let selected = state.items.filter { ids.contains($0.id) }
            if let url = selected.first?.url {
                Button("Reveal in Finder") { Reveal.inFinder(url) }
                Button("Copy Path") { Pasteboard.copy(url.path) }
                Divider()
            }
            let commands = selected.compactMap(\.command)
            if !commands.isEmpty {
                Button("Copy Command\(commands.count > 1 ? "s" : "")") {
                    Pasteboard.copy(commands.map(\.shellLine).joined(separator: "\n"))
                }
                Button("Open in Terminal") { TerminalLauncher.run(commands) }
                Divider()
            }
            if !selected.isEmpty {
                Button(commands.count == selected.count ? "Run Now…" : "Clean \(selected.count == 1 ? selected[0].title : "\(selected.count) items")…") {
                    confirmItems = selected
                }
            }
        }
    }
}

/// Shows what Clean will do. For commands: the command itself, with Run / Copy / Terminal buttons.
struct ActionCell: View {
    let item: CleanupItem
    let run: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            if let command = item.command {
                Text("$ \(command.display)")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help("Runs when you clean this item: \(command.shellLine)")
                Spacer(minLength: 4)
                Button(action: run) { Image(systemName: "play.fill") }
                    .help("Run now (asks for confirmation)")
                Button { Pasteboard.copy(command.shellLine) } label: { Image(systemName: "doc.on.doc") }
                    .help("Copy command")
                Button { TerminalLauncher.run([command]) } label: { Image(systemName: "terminal") }
                    .help("Open in Terminal")
            } else if case .manual(let instructions) = item.action {
                Image(systemName: "hand.point.right").foregroundStyle(.secondary)
                Text(instructions)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .help(instructions)
                Spacer(minLength: 4)
                if let url = item.url {
                    Button { Reveal.inFinder(url) } label: { Image(systemName: "folder") }
                        .help("Reveal in Finder")
                }
            } else {
                Text(item.action.summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .buttonStyle(.borderless)
    }
}

struct ItemsWrapper: Identifiable {
    let id = UUID()
    let items: [CleanupItem]
}
