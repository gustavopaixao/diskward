import Foundation

public struct CleanOutcome: Sendable, Identifiable {
    public var id: String { item.id }
    public let item: CleanupItem
    public let error: String?
    /// Combined stdout/stderr for command actions (shown in the report like a terminal log).
    public var output: String? = nil
    public var succeeded: Bool { error == nil }
}

public struct CleanReport: Sendable {
    public var outcomes: [CleanOutcome] = []
    public var freeBefore: Int64?
    public var freeAfter: Int64?
    public var emptiedTrash = false
    public var trashEmptyError: String?

    public var succeeded: [CleanOutcome] { outcomes.filter(\.succeeded) }
    public var failed: [CleanOutcome] { outcomes.filter { !$0.succeeded } }
    public var cleanedSize: Int64 { succeeded.reduce(0) { $0 + $1.item.size } }

    /// Real change in free space, as reported by the volume.
    public var freedOnDisk: Int64? {
        guard let before = freeBefore, let after = freeAfter else { return nil }
        return after - before
    }
}

/// Executes cleanup actions. Every file path goes through `SafetyGuard` first.
public struct Cleaner: Sendable {
    public let safety: SafetyGuard
    public let log: CleanupLog
    public let home: URL
    /// Moves one item to the Trash. Injectable so tests don't touch the real Trash.
    let moveToTrash: @Sendable (URL) throws -> Void

    public init(
        safety: SafetyGuard = SafetyGuard(),
        log: CleanupLog = CleanupLog(),
        home: URL = Paths.home,
        moveToTrash: @escaping @Sendable (URL) throws -> Void = { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) }
    ) {
        self.safety = safety
        self.log = log
        self.home = home
        self.moveToTrash = moveToTrash
    }

    public func clean(_ items: [CleanupItem], emptyTrashAfter: Bool) async -> CleanReport {
        var report = CleanReport()
        report.freeBefore = DiskInfo.current(for: home)?.available

        for item in Cleaner.executionOrder(items) {
            if Task.isCancelled { break }
            let (error, output) = await perform(item)
            report.outcomes.append(CleanOutcome(item: item, error: error, output: output))
            log.record(item: item, error: error)
        }

        if emptyTrashAfter {
            let trash = home.appendingPathComponent(".Trash")
            do {
                try emptyTrash(trash)
                report.emptiedTrash = true
                log.record(message: "Emptied Trash after cleanup")
            } catch {
                report.trashEmptyError = error.localizedDescription
                log.record(message: "Empty Trash failed: \(error.localizedDescription)")
            }
        }

        report.freeAfter = DiskInfo.current(for: home)?.available
        return report
    }

    /// Stable sort by `groupOrder`, so e.g. Docker containers go before the images they use.
    static func executionOrder(_ items: [CleanupItem]) -> [CleanupItem] {
        items.enumerated()
            .sorted { ($0.element.groupOrder, $0.offset) < ($1.element.groupOrder, $1.offset) }
            .map(\.element)
    }

    /// Returns an error message (nil on success) and, for commands, their output.
    private func perform(_ item: CleanupItem) async -> (String?, String?) {
        do {
            switch item.action {
            case .trash(let urls):
                // Validate everything before touching anything.
                for url in urls { try safety.validate(url) }
                var failures: [String] = []
                for url in urls where FS.exists(url) {
                    do {
                        try moveToTrash(url)
                    } catch {
                        failures.append("\(url.lastPathComponent): \(error.localizedDescription)")
                    }
                }
                return (failures.isEmpty ? nil : failures.joined(separator: "\n"), nil)

            case .command(let command):
                let output = try await ShellRunner.run(command.executable, command.arguments, timeout: 900)
                let log = "$ \(command.display)\n" + [output.stdoutString, output.stderr]
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
                    .joined(separator: "\n")
                guard output.succeeded else {
                    let message = output.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                    return (message.isEmpty ? "Command failed with status \(output.status)" : message, log)
                }
                return (nil, log)

            case .emptyTrash(let trash):
                try emptyTrash(trash)
                return (nil, nil)

            case .manual(let instructions):
                return ("Storage Helper doesn't clean this automatically. \(instructions)", nil)
            }
        } catch {
            return (error.localizedDescription, nil)
        }
    }

    private func emptyTrash(_ trash: URL) throws {
        let names = try FileManager.default.contentsOfDirectory(atPath: trash.path)
        var failures: [String] = []
        for name in names where name != ".DS_Store" && name != ".localized" {
            let url = trash.appendingPathComponent(name)
            do {
                try safety.validateTrashContent(url, trash: trash)
                try FileManager.default.removeItem(at: url)
            } catch {
                failures.append("\(name): \(error.localizedDescription)")
            }
        }
        if !failures.isEmpty {
            throw ProviderError("Could not delete \(failures.count) item(s) from the Trash:\n" + failures.prefix(5).joined(separator: "\n"))
        }
    }
}

/// Append-only audit log at ~/Library/Logs/StorageHelper/cleanup.log.
public struct CleanupLog: Sendable {
    public let fileURL: URL

    public init(directory: URL = Paths.home.appendingPathComponent("Library/Logs/StorageHelper")) {
        self.fileURL = directory.appendingPathComponent("cleanup.log")
    }

    public func record(item: CleanupItem, error: String?) {
        let status = error.map { "FAILED (\($0.replacingOccurrences(of: "\n", with: " | ")))" } ?? "OK"
        let target: String
        switch item.action {
        case .trash(let urls): target = urls.map(\.path).joined(separator: ", ")
        case .command(let cmd): target = cmd.display
        case .emptyTrash(let url): target = url.path
        case .manual: target = item.url?.path ?? item.title
        }
        record(message: "[\(item.providerID)] \(item.title) | \(ByteFormat.string(item.size)) | \(item.action.summary) | \(target) | \(status)")
    }

    public func record(message: String) {
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(message)\n"
        let fm = FileManager.default
        try? fm.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let handle = try? FileHandle(forWritingTo: fileURL) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: Data(line.utf8))
        } else {
            try? Data(line.utf8).write(to: fileURL)
        }
    }
}
