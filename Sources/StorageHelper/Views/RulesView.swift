import StorageCore
import SwiftUI

/// Saved cleanup rules: turn them on, adjust the number, and apply them all at once.
struct RulesView: View {
    @Environment(AppModel.self) private var model
    @State private var confirmItems: [CleanupItem]?

    var body: some View {
        @Bindable var model = model
        let matches = model.ruleMatches
        let total = matches.reduce(0) { $0 + $1.size }

        VStack(spacing: 0) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Your cleanup rules").font(.title2.bold())
                    Text("Rules pick items from the latest scan. You always review the list before anything is deleted.")
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer()
                if model.isScanning { ProgressView().controlSize(.small) }
                Button {
                    confirmItems = matches
                } label: {
                    Label("Apply Rules · \(matches.count) items · \(ByteFormat.string(total))", systemImage: "checklist")
                }
                .buttonStyle(.borderedProminent)
                .disabled(matches.isEmpty || model.isScanning || model.isCleaning)
            }
            .padding()
            Divider()

            List {
                ForEach($model.rules) { $rule in
                    RuleRow(rule: $rule, matches: RuleEngine.matches(rule, in: model.allItems))
                }
            }
            .listStyle(.inset(alternatesRowBackgrounds: true))

            HStack {
                Text("Matches update after each scan.").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Restore Defaults") { model.rules = RuleEngine.defaultRules() }
            }
            .padding(10)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .navigationTitle("Cleanup Rules")
        .sheet(item: Binding(
            get: { confirmItems.map(ItemsWrapper.init) },
            set: { if $0 == nil { confirmItems = nil } }
        )) { wrapper in
            CleanConfirmSheet(items: wrapper.items)
        }
    }
}

struct RuleRow: View {
    @Binding var rule: CleanupRule
    let matches: [CleanupItem]

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Toggle("", isOn: $rule.enabled).labelsHidden().toggleStyle(.switch).controlSize(.small)
            VStack(alignment: .leading, spacing: 3) {
                Text(rule.title).fontWeight(.medium)
                Text(rule.kind.explanation).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer()
            if let unit = rule.kind.valueUnit {
                Stepper(value: $rule.value, in: rule.kind.valueRange, step: unit == "days" ? 7 : 1) {
                    Text("\(rule.value) \(unit)").monospacedDigit().foregroundStyle(.secondary)
                }
                .fixedSize()
            }
            VStack(alignment: .trailing, spacing: 2) {
                Text(ByteFormat.string(matches.reduce(0) { $0 + $1.size })).monospacedDigit()
                Text("\(matches.count) item\(matches.count == 1 ? "" : "s")").font(.caption).foregroundStyle(.secondary)
            }
            .frame(width: 90, alignment: .trailing)
            .opacity(rule.enabled ? 1 : 0.4)
        }
        .padding(.vertical, 4)
    }
}
