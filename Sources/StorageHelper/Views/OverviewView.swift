import StorageCore
import SwiftUI

struct OverviewView: View {
    @Environment(AppModel.self) private var model
    @Binding var route: Route?
    @State private var confirmItems: [CleanupItem]?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if !model.hasFullDiskAccess { FullDiskAccessBanner() }

                OverviewHero()

                if let disk = model.disk, let other = model.unexplainedUsed {
                    UsageBreakdown(disk: disk, reclaimable: model.totalReclaimable, other: other,
                                   isScanning: model.isScanning) {
                        route = .explorer
                    }
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

                QuickWinsCard(
                    review: { confirmItems = $0 },
                    editRules: { route = .rules }
                )

                CategorySummary { route = .provider($0) }
            }
            .padding(24)
        }
        .navigationTitle("Overview")
        .sheet(item: Binding(
            get: { confirmItems.map(ItemsWrapper.init) },
            set: { if $0 == nil { confirmItems = nil } }
        )) { wrapper in
            CleanConfirmSheet(items: wrapper.items)
        }
    }
}

/// Brand hero: icon, tagline and the three headline numbers, on the brand surface.
struct OverviewHero: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(alignment: .center, spacing: 20) {
            HStack(spacing: 14) {
                Image(nsImage: Brand.appIcon)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 56, height: 56)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(Brand.tagline).font(.title3.weight(.semibold))
                    Text(statusLine).font(.callout).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            .layoutPriority(1)

            Spacer(minLength: 12)

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 28) { stats }
                HStack(spacing: 16) { stats }
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: 12).fill(DS.brandSurface))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary.opacity(0.08)))
    }

    private var statusLine: String {
        if model.isScanning { return "Scanning your Mac…" }
        if let date = model.lastScan { return "Scanned \(date.relative)" }
        return "Ready to scan"
    }

    @ViewBuilder private var stats: some View {
        HeroStat(title: "Free",
                 value: model.disk.map { ByteFormat.string($0.available) } ?? "—",
                 caption: model.disk.map { disk in
                     disk.purgeable > 0 ? "\(ByteFormat.string(disk.purgeable)) purgeable" : "of \(ByteFormat.string(disk.total))"
                 } ?? "",
                 color: model.disk.map { $0.available < 20_000_000_000 ? DS.critical : .primary } ?? .primary)
        HeroStat(title: "Reclaimable", value: ByteFormat.string(model.totalReclaimable),
                 caption: "found by the scan", color: DS.reclaimable)
        HeroStat(title: "Selected", value: ByteFormat.string(model.selectedSize),
                 caption: "\(model.selection.count) items", color: .primary)
    }
}

struct HeroStat: View {
    let title: String
    let value: String
    let caption: String
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 24, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(color)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(caption).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
        }
        .fixedSize(horizontal: true, vertical: false)
        .accessibilityElement(children: .combine)
    }
}

/// What the enabled cleanup rules would clean right now, with one button to review it.
struct QuickWinsCard: View {
    @Environment(AppModel.self) private var model
    let review: ([CleanupItem]) -> Void
    let editRules: () -> Void

    var body: some View {
        let matches = model.ruleMatches
        let total = matches.reduce(Int64(0)) { $0 + $1.size }
        let perRule = model.rules.filter(\.enabled)
            .map { ($0, RuleEngine.matches($0, in: model.allItems)) }
            .filter { !$0.1.isEmpty }
            .sorted { $0.1.reduce(0) { $0 + $1.size } > $1.1.reduce(0) { $0 + $1.size } }

        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Quick wins").font(.title3.bold())
                Spacer()
                Button("Edit Rules…", action: editRules).buttonStyle(.link)
            }
            HStack(alignment: .center, spacing: 14) {
                Image(systemName: "checklist")
                    .font(.title2)
                    .foregroundStyle(DS.tint)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 4) {
                    if matches.isEmpty {
                        Text(model.isScanning ? "Checking your rules…" : "Nothing matches your rules right now.")
                            .font(.headline)
                        Text("Turn on more rules to find easy space to free.").font(.callout).foregroundStyle(.secondary)
                    } else {
                        HStack(spacing: 4) {
                            Text("Your rules can free")
                            Text(ByteFormat.string(total)).foregroundStyle(DS.reclaimableText).monospacedDigit()
                            Text("· \(matches.count) items").foregroundStyle(.secondary)
                        }
                        .font(.headline)
                        Text(perRule.prefix(3).map { "\($0.0.title) \(ByteFormat.string($0.1.reduce(0) { $0 + $1.size }))" }
                            .joined(separator: " · "))
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer()
                Button("Review & Clean") { review(matches) }
                    .buttonStyle(.borderedProminent)
                    .disabled(matches.isEmpty || model.isScanning || model.isCleaning)
            }
            .padding(14)
            .background(RoundedRectangle(cornerRadius: 10).fill(.background.secondary))
        }
    }
}

/// One compact row per category instead of every source (the sidebar lists those).
struct CategorySummary: View {
    @Environment(AppModel.self) private var model
    /// Opens the largest source of the clicked category.
    let open: (String) -> Void

    static func icon(_ category: CleanupCategory) -> String {
        switch category {
        case .system: "desktopcomputer"
        case .xcode: "hammer"
        case .containers: "shippingbox"
        case .packageManagers: "cube.box"
        case .devTools: "wrench.and.screwdriver"
        case .projects: "folder"
        }
    }

    var body: some View {
        let rows = CleanupCategory.allCases.compactMap { category -> (CleanupCategory, [ProviderState])? in
            let states = model.states(in: category)
            return states.isEmpty ? nil : (category, states)
        }
        let maxTotal = rows.map { $0.1.reduce(Int64(0)) { $0 + $1.total } }.max() ?? 0

        VStack(alignment: .leading, spacing: 8) {
            Text("By category").font(.title3.bold())
            VStack(spacing: 0) {
                ForEach(rows, id: \.0) { category, states in
                    let total = states.reduce(Int64(0)) { $0 + $1.total }
                    let scanning = states.contains { $0.status == .scanning || $0.status == .idle }
                    let largest = states.max { $0.total < $1.total }
                    Button { if let largest { open(largest.id) } } label: {
                        HStack(spacing: 12) {
                            Image(systemName: Self.icon(category)).foregroundStyle(.secondary).frame(width: 22)
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text(category.title).font(.body.weight(.medium))
                                    Text("\(states.count) sources").font(.caption).foregroundStyle(.secondary)
                                    Spacer()
                                    if scanning { ProgressView().controlSize(.small) }
                                    Text(ByteFormat.string(total))
                                        .monospacedDigit()
                                        .foregroundStyle(total > 0 ? .primary : .secondary)
                                }
                                SizeBar(value: total, maxValue: maxTotal)
                            }
                            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(largest.map { "Open \($0.provider.title), the largest source in \(category.title)" } ?? "")
                    if category != rows.last?.0 { Divider() }
                }
            }
            .background(RoundedRectangle(cornerRadius: 10).fill(.background.secondary))
        }
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

/// One bar: other used space · reclaimable (found by the scan) · free.
struct UsageBreakdown: View {
    let disk: DiskInfo
    let reclaimable: Int64
    let other: Int64
    var isScanning = false
    let explore: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Where your disk space is").font(.title3.bold())
                if isScanning {
                    ProgressView().controlSize(.small)
                    Text("updating…").font(.caption).foregroundStyle(.secondary)
                }
            }
            GeometryReader { geo in
                let total = max(Double(disk.total), 1)
                HStack(spacing: 2) {
                    segment(DS.otherUsed, width: geo.size.width * Double(other) / total)
                    segment(DS.reclaimable, width: geo.size.width * Double(min(reclaimable, disk.used)) / total)
                    segment(Color.secondary.opacity(0.2), width: geo.size.width * Double(disk.available) / total)
                }
            }
            .frame(height: 14)

            HStack(spacing: 18) {
                legend(DS.otherUsed, "Other space", other)
                legend(DS.reclaimable, "Reclaimable", reclaimable)
                legend(Color.secondary.opacity(0.2), "Free", disk.available)
                Spacer()
                Button("Find it in Disk Explorer", action: explore)
            }
            .font(.caption)

            Text("\"Other space\" is everything this scan doesn't list: apps, documents, photos and macOS itself. Use the Disk Explorer to see which folders hold it.")
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
