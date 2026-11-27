import Foundation

public struct DiskInfo: Sendable, Equatable {
    public let total: Int64
    /// Matches the "available" number Finder shows (includes purgeable space).
    public let available: Int64
    public var used: Int64 { total - available }
    public var usedFraction: Double { total > 0 ? Double(used) / Double(total) : 0 }

    public static func current(for url: URL = Paths.home) -> DiskInfo? {
        let keys: Set<URLResourceKey> = [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey]
        guard let values = try? url.resourceValues(forKeys: keys),
              let total = values.volumeTotalCapacity,
              let available = values.volumeAvailableCapacityForImportantUsage
        else { return nil }
        return DiskInfo(total: Int64(total), available: available)
    }
}

public enum Permissions {
    /// Full Disk Access can't be queried directly; the standard trick is to try to read a TCC-protected file.
    public static func hasFullDiskAccess(home: URL = Paths.home) -> Bool {
        let probes = [
            "Library/Application Support/com.apple.TCC/TCC.db",
            "Library/Safari/Bookmarks.plist",
        ]
        for probe in probes {
            let path = home.appendingPathComponent(probe).path
            guard FileManager.default.fileExists(atPath: path) else { continue }
            if let handle = FileHandle(forReadingAtPath: path) {
                try? handle.close()
                return true
            }
            return false
        }
        // No probe file exists: fall back to the Trash, which is also protected.
        return FS.canList(home.appendingPathComponent(".Trash"))
    }

    public static let fullDiskAccessSettingsURL =
        URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!
}
