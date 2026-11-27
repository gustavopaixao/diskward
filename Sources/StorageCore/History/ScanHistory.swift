import Foundation

/// What one full scan found, kept so later scans can show what grew.
public struct ScanSnapshot: Codable, Sendable, Identifiable, Equatable {
    public var id: Date { date }
    public let date: Date
    public let free: Int64
    public let used: Int64
    /// Provider ID → total bytes. Only providers that scanned successfully.
    public let providerTotals: [String: Int64]
    public let providerTitles: [String: String]
    /// Item ID → bytes, for the largest items only (keeps the file small).
    public let itemSizes: [String: Int64]
    public let itemTitles: [String: String]
    public let itemProviders: [String: String]

    public static let maxItems = 1500

    public init(date: Date, disk: DiskInfo, providers: [(id: String, title: String, items: [CleanupItem])]) {
        self.date = date
        self.free = disk.available
        self.used = disk.used
        var totals: [String: Int64] = [:]
        var titles: [String: String] = [:]
        for provider in providers {
            totals[provider.id] = provider.items.reduce(0) { $0 + $1.size }
            titles[provider.id] = provider.title
        }
        self.providerTotals = totals
        self.providerTitles = titles

        let largest = providers.flatMap(\.items).sorted { $0.size > $1.size }.prefix(Self.maxItems)
        var sizes: [String: Int64] = [:]
        var itemTitles: [String: String] = [:]
        var itemProviders: [String: String] = [:]
        for item in largest {
            sizes[item.id] = item.size
            itemTitles[item.id] = item.title
            itemProviders[item.id] = item.providerID
        }
        self.itemSizes = sizes
        self.itemTitles = itemTitles
        self.itemProviders = itemProviders
    }
}

public struct Growth: Sendable {
    public struct Entry: Sendable, Identifiable {
        public let id: String
        public let title: String
        public let providerID: String
        public let before: Int64
        public let after: Int64
        public var delta: Int64 { after - before }
    }

    public let from: ScanSnapshot
    public let to: ScanSnapshot
    /// Positive = less free space now.
    public var freeDelta: Int64 { to.free - from.free }
    /// Sorted by delta, biggest growth first. Unchanged providers are left out.
    public let providers: [Entry]
    /// Items that grew or appeared, biggest growth first.
    public let items: [Entry]

    public var grown: [Entry] { providers.filter { $0.delta > 0 } }
    public var shrunk: [Entry] { providers.filter { $0.delta < 0 } }
}

/// Stores scan snapshots in ~/Library/Application Support/StorageHelper/history.json.
public struct ScanHistory: Sendable {
    public let fileURL: URL
    /// Snapshots closer together than this replace each other, so repeated rescans don't add noise.
    public let minimumSpacing: TimeInterval
    public let keep: Int

    public init(
        directory: URL = Paths.home.appendingPathComponent("Library/Application Support/StorageHelper"),
        minimumSpacing: TimeInterval = 15 * 60,
        keep: Int = 180
    ) {
        self.fileURL = directory.appendingPathComponent("history.json")
        self.minimumSpacing = minimumSpacing
        self.keep = keep
    }

    public func load() -> [ScanSnapshot] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return ((try? decoder.decode([ScanSnapshot].self, from: data)) ?? []).sorted { $0.date < $1.date }
    }

    /// Appends a snapshot (or replaces the latest one if it's very recent) and returns the new history.
    @discardableResult
    public func append(_ snapshot: ScanSnapshot) -> [ScanSnapshot] {
        var history = load()
        if let last = history.last, snapshot.date.timeIntervalSince(last.date) < minimumSpacing {
            history.removeLast()
        }
        history.append(snapshot)
        history = Array(history.suffix(keep))
        save(history)
        return history
    }

    func save(_ history: [ScanSnapshot]) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(history) else { return }
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: fileURL, options: .atomic)
    }

    /// The newest snapshot at least `age` older than `latest` (or the one just before it when `age` is 0).
    public static func baseline(in history: [ScanSnapshot], for latest: ScanSnapshot, age: TimeInterval) -> ScanSnapshot? {
        history
            .filter { $0.date < latest.date && latest.date.timeIntervalSince($0.date) >= age }
            .max { $0.date < $1.date }
    }

    /// Compares two snapshots. Only providers present in both are compared, so a provider that
    /// failed or was unavailable in one scan doesn't show up as a huge change.
    public static func growth(from old: ScanSnapshot, to new: ScanSnapshot) -> Growth {
        let providers = Set(old.providerTotals.keys).intersection(new.providerTotals.keys)
            .compactMap { id -> Growth.Entry? in
                let before = old.providerTotals[id] ?? 0
                let after = new.providerTotals[id] ?? 0
                guard before != after else { return nil }
                return Growth.Entry(id: id, title: new.providerTitles[id] ?? id, providerID: id, before: before, after: after)
            }
            .sorted { $0.delta > $1.delta }

        let comparable = Set(old.providerTotals.keys).intersection(new.providerTotals.keys)
        let items = new.itemSizes.compactMap { id, after -> Growth.Entry? in
            guard let provider = new.itemProviders[id], comparable.contains(provider) else { return nil }
            let before = old.itemSizes[id] ?? 0
            guard after - before > 0 else { return nil }
            return Growth.Entry(id: id, title: new.itemTitles[id] ?? id, providerID: provider, before: before, after: after)
        }
        .sorted { $0.delta > $1.delta }

        return Growth(from: old, to: new, providers: providers, items: Array(items.prefix(25)))
    }
}

public enum SignedBytes {
    /// "+1.2 GB" / "−300 MB" / "±0"
    public static func string(_ value: Int64) -> String {
        if value == 0 { return "±0" }
        return (value > 0 ? "+" : "−") + ByteFormat.string(abs(value))
    }
}
