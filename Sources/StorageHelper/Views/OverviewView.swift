import StorageCore
import SwiftUI

struct OverviewView: View {
    @Environment(AppModel.self) private var model
    @Binding var route: Route?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if !model.hasFullDiskAccess { FullDiskAccessBanner() }

                HStack(spacing: 16) {
                    StatCard(title: "Free space", value: model.disk.map { ByteFormat.string($0.available) } ?? "—",
                             caption: model.disk.map { "of \(ByteFormat.string($0.total))" } ?? "")
                    StatCard(title: "Reclaimable found", value: ByteFormat.string(model.totalReclaimable),
                             caption: model.isScanning ? "Scanning…" : model.lastScan.map { "Scanned \($0.relative)" } ?? "")
                    StatCard(title: "Selected", value: ByteFormat.string(model.selectedSize),
                             caption: "\(model.selection.count) items · safe items are pre-selected")
                }

                let maxTotal = model.visibleStates.map(\.total).max() ?? 0
                ForEach(CleanupCategory.allCases) { category in
                    let states = model.states(in: category)
                    if !states.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(category.title).font(.title3.bold())
                            VStack(spacing: 0) {
                                ForEach(states) { state in
                                    Button { route = .provider(state.id) } label: {
                                        OverviewRow(state: state, maxTotal: maxTotal)
                                    }
                                    .buttonStyle(.plain)
                                    if state.id != states.last?.id { Divider() }
                                }
                            }
                            .background(RoundedRectangle(cornerRadius: 10).fill(.background.secondary))
                        }
                    }
                }
            }
            .padding(24)
        }
        .navigationTitle("Overview")
    }
}

struct StatCard: View {
    let title: String
    let value: String
    let caption: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.system(size: 26, weight: .semibold, design: .rounded)).monospacedDigit()
            Text(caption).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(.background.secondary))
    }
}

struct OverviewRow: View {
    @Environment(AppModel.self) private var model
    let state: ProviderState
    let maxTotal: Int64

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: state.provider.icon)
                .frame(width: 22)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(state.provider.title).font(.body.weight(.medium))
                    Spacer()
                    statusText
                }
                if state.status == .done, state.total > 0 {
                    SizeBar(value: state.total, maxValue: maxTotal)
                }
            }
            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
    }

    @ViewBuilder private var statusText: some View {
        switch state.status {
        case .idle, .scanning:
            HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Scanning…").foregroundStyle(.secondary) }
        case .done:
            let selected = state.items.filter { model.selection.contains($0.id) }.reduce(Int64(0)) { $0 + $1.size }
            HStack(spacing: 8) {
                if selected > 0 {
                    Text("\(ByteFormat.string(selected)) selected").font(.caption).foregroundStyle(.secondary)
                }
                Text(state.total > 0 ? ByteFormat.string(state.total) : "Nothing to clean")
                    .monospacedDigit()
                    .foregroundStyle(state.total > 0 ? .primary : .secondary)
            }
        case .unavailable(let reason), .failed(let reason):
            Text(reason).font(.caption).foregroundStyle(.orange).lineLimit(1)
        case .hidden:
            EmptyView()
        }
    }
}
