import Foundation

public struct UserCachesProvider: CleanupProvider {
    public let id = "caches"
    public let title = "App Caches"
    public let icon = "archivebox"
    public let category = CleanupCategory.system
    public let note: String? = "Apps rebuild their caches when needed. Quit apps first for best results. Apple caches (com.apple.*) are not pre-selected."
    let home: URL

    /// Shown by more specific providers instead, so they aren't counted twice.
    static let excluded: Set<String> = [
        "Homebrew", "pip", "pypoetry", "CocoaPods", "Yarn", "pnpm", "org.swift.swiftpm",
        "org.carthage.CarthageKit", "go-build", "StorageHelper", "ms-playwright", "JetBrains",
    ]

    public init(home: URL = Paths.home) { self.home = home }

    var directory: URL { home.appendingPathComponent("Library/Caches") }

    public func availability() async -> ProviderAvailability {
        FS.exists(directory) ? .available : .notInstalled
    }

    public func scan() async throws -> [CleanupItem] {
        await ProviderSupport.childItems(
            of: directory, providerID: id, minSize: 1_000_000, home: home,
            filter: { !UserCachesProvider.excluded.contains($0.lastPathComponent) },
            safety: { $0.name.hasPrefix("com.apple.") ? .caution : .safe }
        )
    }
}

public struct LogsProvider: CleanupProvider {
    public let id = "logs"
    public let title = "Logs"
    public let icon = "doc.text"
    public let category = CleanupCategory.system
    let home: URL

    public init(home: URL = Paths.home) { self.home = home }

    var directory: URL { home.appendingPathComponent("Library/Logs") }

    public func availability() async -> ProviderAvailability {
        FS.exists(directory) ? .available : .notInstalled
    }

    public func scan() async throws -> [CleanupItem] {
        await ProviderSupport.childItems(
            of: directory, providerID: id, minSize: 500_000, home: home,
            filter: { $0.lastPathComponent != "StorageHelper" }
        )
    }
}

public struct TrashProvider: CleanupProvider {
    public let id = "trash"
    public let title = "Trash"
    public let icon = "trash"
    public let category = CleanupCategory.system
    public let note: String? = "Emptying the Trash is permanent."
    let home: URL

    public init(home: URL = Paths.home) { self.home = home }

    var directory: URL { home.appendingPathComponent(".Trash") }

    public func availability() async -> ProviderAvailability {
        guard FS.exists(directory) else { return .notInstalled }
        return FS.canList(directory) ? .available : .unavailable("Grant Full Disk Access to see the Trash.")
    }

    public func scan() async throws -> [CleanupItem] {
        let measured = SizeCalculator.measure(directory)
        let count = FS.children(directory).count
        guard measured.size > 0, count > 0 else { return [] }
        return [CleanupItem(
            id: "\(id):\(directory.path)",
            providerID: id,
            title: "Trash (\(count) item\(count == 1 ? "" : "s"))",
            detail: "~/.Trash",
            url: directory,
            size: measured.size,
            lastModified: measured.lastModified,
            safety: .caution,
            action: .emptyTrash(directory)
        )]
    }
}

public struct DownloadsProvider: CleanupProvider {
    public let id = "downloads"
    public let title = "Downloads"
    public let icon = "arrow.down.circle"
    public let category = CleanupCategory.system
    public let note: String? = "Files over 100 MB, or over 1 MB and untouched for 90+ days. Nothing here is pre-selected: check each one."
    let home: URL
    let largeThreshold: Int64
    let oldThresholdDays: Double

    public init(home: URL = Paths.home, largeThreshold: Int64 = 100_000_000, oldThresholdDays: Double = 90) {
        self.home = home
        self.largeThreshold = largeThreshold
        self.oldThresholdDays = oldThresholdDays
    }

    var directory: URL { home.appendingPathComponent("Downloads") }

    public func availability() async -> ProviderAvailability {
        guard FS.exists(directory) else { return .notInstalled }
        return FS.canList(directory) ? .available : .unavailable("Allow access to the Downloads folder (or grant Full Disk Access).")
    }

    public func scan() async throws -> [CleanupItem] {
        let cutoff = ProviderSupport.daysAgo(oldThresholdDays)
        let large = largeThreshold
        return await ProviderSupport.childItems(
            of: directory, providerID: id, home: home,
            safety: { _ in .review },
            note: { child in
                if let date = child.lastModified, date < cutoff { return "Not modified in \(Int(Date().timeIntervalSince(date) / 86_400)) days" }
                return child.size >= large ? "Large file" : nil
            }
        ).filter { item in
            item.size >= large || (item.size >= 1_000_000 && (item.lastModified.map { $0 < cutoff } ?? false))
        }
    }
}
