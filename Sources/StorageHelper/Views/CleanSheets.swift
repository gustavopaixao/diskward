import StorageCore
import SwiftUI

struct CleanConfirmSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let items: [CleanupItem]
    @State private var emptyTrashAfter = false

    private var total: Int64 { items.reduce(0) { $0 + $1.size } }
    private var hasTrashMoves: Bool { items.contains { if case .trash = $0.action { true } else { false } } }
    private var permanentCount: Int { items.filter(\.action.isPermanent).count }
    private var riskyCount: Int { items.filter { $0.safety != .safe }.count }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Clean \(items.count) item\(items.count == 1 ? "" : "s") · \(ByteFormat.string(total))")
                .font(.title2.bold())

            let running = model.runningRelatedApps(for: items)
            if !running.isEmpty {
                Label("Quit \(running.joined(separator: ", ")) first for best results.", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }
            if riskyCount > 0 {
                Label("\(riskyCount) selected item\(riskyCount == 1 ? " is" : "s are") marked Caution or Review.", systemImage: "hand.raised.fill")
                    .foregroundStyle(.orange)
            }
            if permanentCount > 0 {
                Label("\(permanentCount) item\(permanentCount == 1 ? "" : "s") will be removed permanently (Docker, simulators, Homebrew, emptying the Trash).", systemImage: "xmark.octagon.fill")
                    .foregroundStyle(.red)
            }

            List {
                ForEach(items.sorted { $0.size > $1.size }) { item in
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text(item.title).lineLimit(1)
                                SafetyBadge(safety: item.safety)
                            }
                            Text(actionDetail(item))
                                .font(.caption.monospaced())
                                .foregroundStyle(item.action.isPermanent ? .red : .secondary)
                                .lineLimit(2)
                                .truncationMode(.middle)
                        }
                        Spacer()
                        Text(ByteFormat.string(item.size)).monospacedDigit()
                    }
                }
            }
            .frame(minHeight: 220)

            if hasTrashMoves {
                Toggle(isOn: $emptyTrashAfter) {
                    VStack(alignment: .leading) {
                        Text("Empty the Trash afterwards to free space now")
                        Text("Items moved to the Trash still take up space until it is emptied. This also deletes anything else already in the Trash.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(role: .destructive) {
                    let items = self.items
                    let emptyTrash = emptyTrashAfter
                    dismiss()
                    Task { await model.clean(items, emptyTrashAfter: emptyTrash) }
                } label: {
                    Text("Clean \(ByteFormat.string(total))")
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
            }
        }
        .padding(20)
        .frame(width: 620, height: 520)
    }

    private func actionDetail(_ item: CleanupItem) -> String {
        switch item.action {
        case .trash(let urls):
            urls.count == 1 ? "→ Trash: \(Paths.display(urls[0]))" : "→ Trash: \(urls.count) items in \(item.detail)"
        case .command(let command):
            "$ \(command.shellLine)"
        case .emptyTrash:
            "Permanently delete everything in the Trash"
        }
    }
}

struct CleanReportSheet: View {
    @Environment(\.dismiss) private var dismiss
    let report: CleanReport
    @State private var showOutput = true

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(report.failed.isEmpty ? "Cleanup finished" : "Cleanup finished with problems",
                  systemImage: report.failed.isEmpty ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .font(.title2.bold())
                .foregroundStyle(report.failed.isEmpty ? .green : .orange)

            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                GridRow {
                    Text("Cleaned").foregroundStyle(.secondary)
                    Text("\(report.succeeded.count) items · \(ByteFormat.string(report.cleanedSize))")
                }
                if let before = report.freeBefore, let after = report.freeAfter {
                    GridRow {
                        Text("Free space").foregroundStyle(.secondary)
                        Text("\(ByteFormat.string(before)) → \(ByteFormat.string(after))  (\(signed(after - before)))")
                            .monospacedDigit()
                    }
                }
                if report.emptiedTrash {
                    GridRow { Text("Trash").foregroundStyle(.secondary); Text("Emptied") }
                }
            }

            if let delta = report.freedOnDisk, delta < report.cleanedSize / 2, !report.emptiedTrash {
                Text("Free space barely changed because files moved to the Trash still use space. Empty the Trash to reclaim it. Docker frees space inside its own disk image, which macOS sees later.")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let trashError = report.trashEmptyError {
                Text(trashError).font(.callout).foregroundStyle(.red)
            }

            if !report.failed.isEmpty {
                Text("Failed").font(.headline)
                List(report.failed) { outcome in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(outcome.item.title)
                        Text(outcome.error ?? "").font(.caption).foregroundStyle(.red).lineLimit(3)
                    }
                }
                .frame(minHeight: 140)
            }

            let logs = report.outcomes.compactMap(\.output)
            if !logs.isEmpty {
                DisclosureGroup("Command output (\(logs.count))", isExpanded: $showOutput) {
                    ScrollView {
                        Text(logs.joined(separator: "\n\n"))
                            .font(.caption.monospaced())
                            .foregroundStyle(.green)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(10)
                    }
                    .frame(height: 180)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.black.opacity(0.85)))
                }
            }

            HStack {
                Text("Details are logged in ~/Library/Logs/StorageHelper/cleanup.log")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 560)
    }

    private func signed(_ value: Int64) -> String {
        (value >= 0 ? "+" : "−") + ByteFormat.string(abs(value))
    }
}
