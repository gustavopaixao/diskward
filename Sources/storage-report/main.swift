import Foundation
import StorageCore

// Read-only: scans every provider and prints what could be reclaimed. Never deletes anything.
let limit = Int(CommandLine.arguments.dropFirst().first { Int($0) != nil } ?? "") ?? 5

if let disk = DiskInfo.current() {
    print("Disk: \(ByteFormat.string(disk.available)) free of \(ByteFormat.string(disk.total))")
}
print("Full Disk Access: \(Permissions.hasFullDiskAccess() ? "yes" : "NO (some numbers will be too low)")\n")

let providers = ProviderRegistry.all()
let results = await providers.concurrentMap(limit: 6) { provider -> (any CleanupProvider, String?, [CleanupItem]) in
    switch await provider.availability() {
    case .notInstalled: return (provider, "not installed", [])
    case .unavailable(let reason): return (provider, reason, [])
    case .available:
        do { return (provider, nil, try await provider.scan()) } catch { return (provider, "error: \(error.localizedDescription)", []) }
    }
}

var grandTotal: Int64 = 0
for category in CleanupCategory.allCases {
    let rows = results.filter { $0.0.category == category }
    guard !rows.isEmpty else { continue }
    print("== \(category.title) ==")
    for (provider, status, items) in rows {
        let total = items.reduce(0) { $0 + $1.size }
        grandTotal += total
        let pad = provider.title.padding(toLength: 32, withPad: " ", startingAt: 0)
        print("  \(pad) \(status ?? ByteFormat.string(total))")
        for item in items.prefix(limit) {
            let flag = item.safety == .safe ? " " : (item.safety == .caution ? "!" : "?")
            print("    \(flag) \(ByteFormat.string(item.size).padding(toLength: 10, withPad: " ", startingAt: 0)) \(item.title)")
        }
        if items.count > limit { print("      … and \(items.count - limit) more") }
    }
    print("")
}
print("Total reclaimable: \(ByteFormat.string(grandTotal))   (! = caution, ? = review)")
