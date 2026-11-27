import Foundation

// Space that is easy to miss: it doesn't show up in Finder's normal views.

/// Local Time Machine snapshots. They hold deleted/changed files until macOS thins them.
public struct TimeMachineSnapshotsProvider: CleanupProvider {
    public let id = "tm-snapshots"
    public let title = "Local Snapshots"
    public let icon = "clock.arrow.circlepath"
    public let category = CleanupCategory.system
    public let note: String? = "Time Machine keeps local snapshots on your disk until it needs the space. They often show up as \"System Data\". macOS doesn't report the size of each snapshot; the purgeable total is shown on the Overview."

    public init() {}

    public func availability() async -> ProviderAvailability {
        ShellRunner.which("tmutil") == nil ? .notInstalled : .available
    }

    public func scan() async throws -> [CleanupItem] {
        let output = try await ShellRunner.run("tmutil", ["listlocalsnapshots", "/"], timeout: 30)
        guard output.succeeded else { throw ProviderError("tmutil failed: \(output.stderr.prefix(200))") }
        return TimeMachineSnapshotsProvider.parse(output.stdoutString, providerID: id)
    }

    /// Lines look like `com.apple.TimeMachine.2025-01-10-101010.local`.
    static func parse(_ text: String, providerID: String) -> [CleanupItem] {
        let prefix = "com.apple.TimeMachine."
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"

        return text.split(separator: "\n").compactMap { line -> CleanupItem? in
            let name = line.trimmingCharacters(in: .whitespaces)
            guard name.hasPrefix(prefix) else { return nil }
            let stamp = name.dropFirst(prefix.count).replacingOccurrences(of: ".local", with: "")
            let date = formatter.date(from: stamp)
            return CleanupItem(
                id: "\(providerID):\(name)",
                providerID: providerID,
                title: date.map { "Snapshot \($0.formatted(date: .abbreviated, time: .shortened))" } ?? name,
                detail: name,
                size: 0,
                lastModified: date,
                safety: .caution,
                action: .command(ShellCommand("tmutil", ["deletelocalsnapshots", stamp])),
                note: "Size unknown. Deleting it can free a lot if you've deleted big files recently."
            )
        }
        .sorted { ($0.lastModified ?? .distantPast) < ($1.lastModified ?? .distantPast) }
    }
}

/// iPhone / iPad backups made by Finder.
public struct DeviceBackupsProvider: CleanupProvider {
    public let id = "device-backups"
    public let title = "iPhone & iPad Backups"
    public let icon = "iphone.gen3"
    public let category = CleanupCategory.system
    public let note: String? = "Local backups made by Finder. Delete the ones for devices you no longer have, or that are also backed up to iCloud."
    let home: URL

    public init(home: URL = Paths.home) { self.home = home }

    var directory: URL { home.appendingPathComponent("Library/Application Support/MobileSync/Backup") }

    public func availability() async -> ProviderAvailability {
        guard FS.exists(directory) else { return .notInstalled }
        return FS.canList(directory) ? .available : .unavailable("Grant Full Disk Access to see device backups.")
    }

    public func scan() async throws -> [CleanupItem] {
        let id = self.id
        let home = self.home
        let backups = FS.children(directory).filter { FS.isDirectory($0) }
        let items = await backups.concurrentMap { url -> CleanupItem? in
            let measured = SizeCalculator.measure(url)
            guard measured.size > 0 else { return nil }
            let info = DeviceBackupsProvider.info(at: url)
            return CleanupItem(
                id: "\(id):\(url.path)",
                providerID: id,
                title: info.name ?? "Backup \(url.lastPathComponent.prefix(8))",
                detail: [info.product, Paths.display(url, home: home)].compactMap { $0 }.joined(separator: " · "),
                url: url,
                size: measured.size,
                lastModified: info.date ?? measured.lastModified,
                safety: .review,
                action: .trash([url])
            )
        }
        return items.compactMap { $0 }.sorted { $0.size > $1.size }
    }

    static func info(at backup: URL) -> (name: String?, product: String?, date: Date?) {
        guard let data = try? Data(contentsOf: backup.appendingPathComponent("Info.plist")),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { return (nil, nil, nil) }
        let product = [plist["Product Name"] ?? plist["Product Type"], plist["Product Version"].map { "iOS \($0)" }]
            .compactMap { $0 as? String }
            .joined(separator: " ")
        return (plist["Device Name"] as? String, product.isEmpty ? nil : product, plist["Last Backup Date"] as? Date)
    }
}

/// Mail and Messages store attachments locally. Deleting them on disk would corrupt the apps'
/// databases, so these are shown with instructions instead.
public struct MailMessagesProvider: CleanupProvider {
    public let id = "mail-messages"
    public let title = "Mail & Messages"
    public let icon = "envelope"
    public let category = CleanupCategory.system
    public let note: String? = "Shown for information. Storage Developer Helper won't delete these files directly, because that would break Mail and Messages. Follow the steps in the Action column instead."
    let home: URL

    public init(home: URL = Paths.home) { self.home = home }

    struct Entry {
        let path: String
        let title: String
        let instructions: String
    }

    let entries = [
        Entry(path: "Library/Messages/Attachments", title: "Messages attachments",
              instructions: "Messages › Settings › General › Keep messages: 1 Year, or delete large conversations"),
        Entry(path: "Library/Mail", title: "Mail data and attachments",
              instructions: "Delete large emails in Mail, or remove unused accounts in System Settings › Internet Accounts"),
        Entry(path: "Library/Containers/com.apple.mail/Data/Library/Mail Downloads", title: "Mail downloads",
              instructions: "Open the folder in Finder and delete what you don't need"),
    ]

    public func availability() async -> ProviderAvailability {
        let existing = entries.map { home.appendingPathComponent($0.path) }.filter(FS.exists)
        guard !existing.isEmpty else { return .notInstalled }
        // These folders are protected by macOS; without Full Disk Access they read as empty.
        return existing.contains(where: FS.canList) ? .available : .unavailable("Grant Full Disk Access to measure Mail and Messages.")
    }

    public func scan() async throws -> [CleanupItem] {
        let home = self.home
        let id = self.id
        let items = await entries.concurrentMap { entry -> CleanupItem? in
            let url = home.appendingPathComponent(entry.path)
            guard FS.exists(url) else { return nil }
            let measured = SizeCalculator.measure(url)
            guard measured.size > 1_000_000 else { return nil }
            return CleanupItem(
                id: "\(id):\(entry.path)", providerID: id, title: entry.title,
                detail: Paths.display(url, home: home), url: url, size: measured.size,
                lastModified: measured.lastModified, safety: .review,
                action: .manual(entry.instructions),
                note: measured.unreadable > 0 ? "Partly unreadable: grant Full Disk Access for the full size" : nil
            )
        }
        return items.compactMap { $0 }.sorted { $0.size > $1.size }
    }
}
