import AppKit
import StorageCore
import SwiftUI

struct ProviderDetailView: View {
    @Environment(AppModel.self) private var model
    let providerID: String
    @State private var sortOrder = [KeyPathComparator(\CleanupItem.size, order: .reverse)]
    @State private var confirmItems: [CleanupItem]?

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
            ContentUnavailableView("Not found", systemImage: "questionmark.folder")
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
            HStack {
                Text("\(state.items.count) items · \(ByteFormat.string(state.total))")
                    .font(.headline.monospacedDigit())
                Spacer()
                Button("Select All") { model.setSelected(true, items: state.items) }
                Button("Select None") { model.setSelected(false, items: state.items) }
                Button { model.rescan(providerID: providerID) } label: { Image(systemName: "arrow.clockwise") }
                    .help("Rescan \(state.provider.title)")
                Button("Clean \(ByteFormat.string(selected.reduce(0) { $0 + $1.size }))") {
                    confirmItems = selected
                }
                .buttonStyle(.borderedProminent)
                .disabled(selected.isEmpty || model.isCleaning)
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
            ContentUnavailableView(reason, systemImage: "exclamationmark.triangle")
        case .failed(let error):
            ContentUnavailableView {
                Label("Scan failed", systemImage: "exclamationmark.triangle")
            } description: {
                Text(error)
            } actions: {
                Button("Try Again") { model.rescan(providerID: providerID) }
            }
        case .hidden:
            ContentUnavailableView("Not installed", systemImage: "nosign")
        case .done where state.items.isEmpty:
            ContentUnavailableView("Nothing to clean", systemImage: "checkmark.circle")
        case .done:
            itemTable(state)
        }
    }

    private func itemTable(_ state: ProviderState) -> some View {
        let items = state.items.sorted(using: sortOrder)
        let maxSize = state.items.map(\.size).max() ?? 0
        return Table(items, sortOrder: $sortOrder) {
            TableColumn("") { item in
                Toggle("", isOn: Binding(
                    get: { model.selection.contains(item.id) },
                    set: { model.setSelected($0, items: [item]) }
                ))
                .labelsHidden()
            }
            .width(24)

            TableColumn("Name", value: \.title) { item in
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(item.title).fontWeight(.medium).lineLimit(1)
                        SafetyBadge(safety: item.safety)
                    }
                    Text(item.note ?? item.detail)
                        .font(.caption)
                        .foregroundStyle(item.note == nil ? Color.secondary : Color.orange)
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
                Text(item.action.summary)
                    .font(.caption)
                    .foregroundStyle(item.action.isPermanent ? .red : .secondary)
                    .lineLimit(1)
                    .help(item.action.summary)
            }
            .width(min: 100, ideal: 160)
        }
        .contextMenu(forSelectionType: CleanupItem.ID.self) { ids in
            let selected = items.filter { ids.contains($0.id) }
            if let url = selected.first?.url {
                Button("Reveal in Finder") { Reveal.inFinder(url) }
                Button("Copy Path") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(url.path, forType: .string)
                }
                Divider()
            }
            if !selected.isEmpty {
                Button("Clean \(selected.count == 1 ? selected[0].title : "\(selected.count) items")…") {
                    confirmItems = selected
                }
            }
        }
    }
}

struct ItemsWrapper: Identifiable {
    let id = UUID()
    let items: [CleanupItem]
}
