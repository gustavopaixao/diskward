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
                             caption: model.isScanning ? "Scanning…" : model.lastScan.map { "Scanned \($0.relative)" } ?? "",
                             valueColor: DS.reclaimable)
                    StatCard(title: "Selected", value: ByteFormat.string(model.selectedSize),
                             caption: "\(model.selection.count) items · safe items are pre-selected")
                }

                let top = Array(model.allItems.sorted { $0.size > $1.size }.prefix(5))
                if !top.isEmpty {
                    TopPlacesRow(items: top, diskUsed: model.disk?.used ?? 0) { item in
                        route = .provider(item.providerID)
                    }
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
    var valueColor: Color = .primary

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.system(size: 26, weight: .semibold, design: .rounded)).monospacedDigit()
                .foregroundStyle(valueColor)
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
            Text(reason).font(.caption).foregroundStyle(DS.review).lineLimit(1)
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
                    segment(DS.reclaimable, width: geo.size.width * Double(min(reclaimable, disk.used)) / total)
                    segment(DS.otherUsed, width: geo.size.width * Double(other) / total)
                    segment(Color.secondary.opacity(0.2), width: geo.size.width * Double(disk.available) / total)
                }
            }
            .frame(height: 14)

            HStack(spacing: 18) {
                legend(DS.reclaimable, "Reclaimable", reclaimable)
                legend(DS.otherUsed, "Other used space", other)
                legend(Color.secondary.opacity(0.2), "Free", disk.available)
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

/// The five largest items found by the scan, as a row of cards.
struct TopPlacesRow: View {
    @Environment(AppModel.self) private var model
    let items: [CleanupItem]
    let diskUsed: Int64
    let open: (CleanupItem) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Biggest space users").font(.title3.bold())
                if model.isScanning { ProgressView().controlSize(.small) }
                Spacer()
                Text("Top \(items.count) items found by the scan").font(.caption).foregroundStyle(.secondary)
            }
            // Equal-width cards that fill the row and resize with the window. When five
            // don't fit at a readable size, fall back to 3 and then 2 columns.
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 12) { cards(minWidth: 130) }
                    .fixedSize(horizontal: false, vertical: true) // same height for every card
                columns(3)
                columns(2)
            }
        }
    }
}

extension TopPlacesRow {
    @ViewBuilder func cards(minWidth: CGFloat) -> some View {
        ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
            Button { open(item) } label: {
                TopPlaceCard(rank: index + 1, item: item,
                             source: model.state(for: item.providerID)?.provider,
                             maxSize: items.first?.size ?? 1, diskUsed: diskUsed)
                    .frame(minWidth: minWidth, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            .buttonStyle(.plain)
            .help("\(item.title)\n\(item.detail)\nClick to open \(model.state(for: item.providerID)?.provider.title ?? "its source")")
        }
    }

    func columns(_ count: Int) -> some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: count), spacing: 12) {
            cards(minWidth: 0)
        }
    }
}

struct TopPlaceCard: View {
    let rank: Int
    let item: CleanupItem
    let source: (any CleanupProvider)?
    let maxSize: Int64
    let diskUsed: Int64

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text("\(rank)")
                    .font(.caption.bold())
                    .frame(width: 18, height: 18)
                    .background(Circle().fill(DS.tint.opacity(0.15)))
                Image(systemName: source?.icon ?? "folder").foregroundStyle(.secondary)
                Text(source?.title ?? "")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Text(item.title)
                .fontWeight(.medium)
                .lineLimit(1)
                .truncationMode(.middle)
            Text(ByteFormat.string(item.size))
                .font(.system(size: 20, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            SizeBar(value: item.size, maxValue: maxSize)
            if diskUsed > 0 {
                Text("\(String(format: "%.1f", Double(item.size) / Double(diskUsed) * 100))% of used space")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(.background.secondary))
        .contentShape(Rectangle())
    }
}
