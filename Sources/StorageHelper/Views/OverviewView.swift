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
                             caption: model.disk.map { disk in
                                 disk.purgeable > 0
                                     ? "incl. \(ByteFormat.string(disk.purgeable)) purgeable · of \(ByteFormat.string(disk.total))"
                                     : "of \(ByteFormat.string(disk.total))"
                             } ?? "")
                    StatCard(title: "Reclaimable found", value: ByteFormat.string(model.totalReclaimable),
                             caption: model.isScanning ? "Scanning…" : model.lastScan.map { "Scanned \($0.relative)" } ?? "")
                    StatCard(title: "Selected", value: ByteFormat.string(model.selectedSize),
                             caption: "\(model.selection.count) items · safe items are pre-selected")
                }

                if let growth = model.growth(), !growth.grown.isEmpty || growth.freeDelta != 0 {
                    GrowthSummary(growth: growth) { route = .changes }
                }

                if let disk = model.disk, let other = model.unexplainedUsed, !model.isScanning {
                    UsageBreakdown(disk: disk, reclaimable: model.totalReclaimable, other: other) {
                        route = .explorer
                    }
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

/// One bar: reclaimable (found by the scan) · other used space · free.
struct UsageBreakdown: View {
    let disk: DiskInfo
    let reclaimable: Int64
    let other: Int64
    let explore: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Where your disk space is").font(.title3.bold())
            GeometryReader { geo in
                let total = max(Double(disk.total), 1)
                HStack(spacing: 2) {
                    segment(.orange, width: geo.size.width * Double(min(reclaimable, disk.used)) / total)
                    segment(.gray, width: geo.size.width * Double(other) / total)
                    segment(.green.opacity(0.5), width: geo.size.width * Double(disk.available) / total)
                }
            }
            .frame(height: 14)

            HStack(spacing: 18) {
                legend(.orange, "Reclaimable", reclaimable)
                legend(.gray, "Other used space", other)
                legend(.green.opacity(0.5), "Free", disk.available)
                Spacer()
                Button("Find it in Disk Explorer", action: explore)
            }
            .font(.caption)

            Text("\"Other used space\" is everything this scan doesn't list: apps, documents, photos and macOS itself. Use the Disk Explorer to see which folders hold it.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .padding()
        .background(RoundedRectangle(cornerRadius: 10).fill(.background.secondary))
    }

    private func segment(_ color: Color, width: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: 3).fill(color).frame(width: max(0, width))
    }

    private func legend(_ color: Color, _ title: String, _ value: Int64) -> some View {
        HStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 10, height: 10)
            Text("\(title) \(ByteFormat.string(value))").monospacedDigit()
        }
    }
}
