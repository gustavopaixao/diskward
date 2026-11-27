import Charts
import StorageCore
import SwiftUI

enum CompareWindow: String, CaseIterable, Identifiable {
    case previous, day, week, month
    var id: String { rawValue }

    var title: String {
        switch self {
        case .previous: "Previous scan"
        case .day: "1 day ago"
        case .week: "1 week ago"
        case .month: "1 month ago"
        }
    }

    var age: TimeInterval {
        switch self {
        case .previous: 0
        case .day: 86_400
        case .week: 7 * 86_400
        case .month: 30 * 86_400
        }
    }
}

/// "What grew?" Compares the latest scan with an earlier one and charts free space over time.
struct ChangesView: View {
    @Environment(AppModel.self) private var model
    @Binding var route: Route?
    @State private var window: CompareWindow = .previous

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if model.history.count < 2 {
                    ContentUnavailableView(
                        "Not enough history yet",
                        systemImage: "chart.line.uptrend.xyaxis",
                        description: Text("Each full scan is saved. Scan again later (scans less than 15 minutes apart replace each other) to see what grew.")
                    )
                    .frame(maxWidth: .infinity, minHeight: 300)
                } else {
                    Picker("Compare with", selection: $window) {
                        ForEach(CompareWindow.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .fixedSize()

                    if let growth = model.growth(age: window.age) {
                        headline(growth)
                        FreeSpaceChart(history: model.history, from: growth.from.date)
                        providerChanges(growth)
                        itemChanges(growth)
                    } else {
                        Text("No scan that old yet. The oldest saved scan is from \(model.history.first!.date.formatted(date: .abbreviated, time: .shortened)).")
                            .foregroundStyle(.secondary)
                        FreeSpaceChart(history: model.history, from: nil)
                    }
                }
            }
            .padding(24)
        }
        .navigationTitle("What Changed")
    }

    private func headline(_ growth: Growth) -> some View {
        HStack(spacing: 16) {
            StatCard(title: "Free space change",
                     value: SignedBytes.string(growth.freeDelta),
                     caption: "since \(growth.from.date.formatted(date: .abbreviated, time: .shortened))")
            StatCard(title: "Grew",
                     value: ByteFormat.string(growth.grown.reduce(0) { $0 + $1.delta }),
                     caption: "\(growth.grown.count) sources got bigger")
            StatCard(title: "Shrank",
                     value: ByteFormat.string(-growth.shrunk.reduce(0) { $0 + $1.delta }),
                     caption: "\(growth.shrunk.count) sources got smaller")
        }
    }

    @ViewBuilder private func providerChanges(_ growth: Growth) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("By source").font(.title3.bold())
            if growth.providers.isEmpty {
                Text("No changes in the scanned sources.").foregroundStyle(.secondary)
            } else {
                let maxDelta = growth.providers.map { abs($0.delta) }.max() ?? 1
                VStack(spacing: 0) {
                    ForEach(growth.providers) { entry in
                        Button { route = .provider(entry.providerID) } label: {
                            DeltaRow(title: entry.title, subtitle: "\(ByteFormat.string(entry.before)) → \(ByteFormat.string(entry.after))",
                                     delta: entry.delta, maxDelta: maxDelta)
                        }
                        .buttonStyle(.plain)
                        if entry.id != growth.providers.last?.id { Divider() }
                    }
                }
                .background(RoundedRectangle(cornerRadius: 10).fill(.background.secondary))
            }
        }
    }

    @ViewBuilder private func itemChanges(_ growth: Growth) -> some View {
        if !growth.items.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("Biggest growing items").font(.title3.bold())
                let maxDelta = growth.items.map(\.delta).max() ?? 1
                VStack(spacing: 0) {
                    ForEach(growth.items) { entry in
                        Button { route = .provider(entry.providerID) } label: {
                            DeltaRow(title: entry.title,
                                     subtitle: (model.state(for: entry.providerID)?.provider.title ?? entry.providerID)
                                         + (entry.before == 0 ? " · new" : " · \(ByteFormat.string(entry.before)) → \(ByteFormat.string(entry.after))"),
                                     delta: entry.delta, maxDelta: maxDelta)
                        }
                        .buttonStyle(.plain)
                        if entry.id != growth.items.last?.id { Divider() }
                    }
                }
                .background(RoundedRectangle(cornerRadius: 10).fill(.background.secondary))
            }
        }
    }
}

/// One change: arrow + sign carry the direction, so it never relies on color alone.
struct DeltaRow: View {
    let title: String
    let subtitle: String
    let delta: Int64
    let maxDelta: Int64

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: delta > 0 ? "arrow.up.right" : "arrow.down.right")
                .foregroundStyle(delta > 0 ? DS.review : DS.reclaimable)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(title).lineLimit(1)
                    Spacer()
                    Text(SignedBytes.string(delta)).monospacedDigit().fontWeight(.medium)
                }
                HStack {
                    Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    Spacer()
                    SizeBar(value: abs(delta), maxValue: maxDelta, color: delta > 0 ? DS.review : DS.reclaimable)
                        .frame(width: 120)
                }
            }
            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .contentShape(Rectangle())
    }
}

/// Free space over time: a single series, so no legend; hover shows the exact value.
struct FreeSpaceChart: View {
    let history: [ScanSnapshot]
    /// Start of the comparison window, marked on the chart.
    let from: Date?
    @State private var hovered: Date?

    private var hoveredSnapshot: ScanSnapshot? {
        guard let hovered else { return nil }
        return history.min { abs($0.date.timeIntervalSince(hovered)) < abs($1.date.timeIntervalSince(hovered)) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Free space over time").font(.title3.bold())
            Chart {
                ForEach(history) { snapshot in
                    LineMark(x: .value("Date", snapshot.date), y: .value("Free", Double(snapshot.free) / 1e9))
                        .lineStyle(StrokeStyle(lineWidth: 2))
                        .interpolationMethod(.monotone)
                        .foregroundStyle(DS.tint)
                    PointMark(x: .value("Date", snapshot.date), y: .value("Free", Double(snapshot.free) / 1e9))
                        .symbolSize(30)
                        .foregroundStyle(DS.tint)
                }
                if let from {
                    RuleMark(x: .value("Compared from", from))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                        .foregroundStyle(.secondary)
                }
                if let snapshot = hoveredSnapshot {
                    RuleMark(x: .value("Selected", snapshot.date))
                        .foregroundStyle(.secondary.opacity(0.5))
                        .annotation(position: .top, overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(snapshot.date.formatted(date: .abbreviated, time: .shortened)).font(.caption2).foregroundStyle(.secondary)
                                Text("\(ByteFormat.string(snapshot.free)) free").font(.caption.bold()).monospacedDigit()
                            }
                            .padding(6)
                            .background(RoundedRectangle(cornerRadius: 6).fill(.background).shadow(radius: 2))
                        }
                }
            }
            .chartXSelection(value: $hovered)
            .chartYAxisLabel("GB free")
            .chartYAxis {
                AxisMarks { _ in
                    AxisGridLine().foregroundStyle(.secondary.opacity(0.2))
                    AxisValueLabel()
                }
            }
            .frame(height: 200)
        }
        .padding()
        .background(RoundedRectangle(cornerRadius: 10).fill(.background.secondary))
    }
}

/// Compact "since last scan" card on the Overview.
struct GrowthSummary: View {
    let growth: Growth
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "chart.line.uptrend.xyaxis").font(.title2).foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Since \(growth.from.date.formatted(date: .abbreviated, time: .shortened)): free space \(SignedBytes.string(growth.freeDelta))")
                        .font(.headline)
                    let top = growth.grown.prefix(3).map { "\($0.title) \(SignedBytes.string($0.delta))" }
                    Text(top.isEmpty ? "Nothing in the scanned sources grew." : "Grew: " + top.joined(separator: " · "))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                Image(systemName: "chevron.right").foregroundStyle(.tertiary)
            }
            .padding()
            .background(RoundedRectangle(cornerRadius: 10).fill(.background.secondary))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
