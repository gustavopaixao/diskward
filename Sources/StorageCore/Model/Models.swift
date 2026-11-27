import Foundation

/// Sidebar grouping for providers.
public enum CleanupCategory: String, CaseIterable, Sendable, Identifiable, Codable {
    case system, xcode, containers, packageManagers, projects

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .system: "System"
        case .xcode: "Xcode"
        case .containers: "Containers & CI"
        case .packageManagers: "Package Managers"
        case .projects: "Projects"
        }
    }
}

/// How confident we are that deleting an item is harmless.
/// Only `.safe` items are pre-selected after a scan.
public enum SafetyLevel: String, Sendable, Hashable, Codable, Comparable {
    /// Regenerated automatically (caches, build products).
    case safe
    /// Regenerable but costly, or holds history (archives, Maven repo, Docker volumes).
    case caution
    /// Personal files: you must look at each one (Downloads).
    case review

    public var isPreselected: Bool { self == .safe }

    private var rank: Int {
        switch self {
        case .safe: 0
        case .caution: 1
        case .review: 2
        }
    }

    public static func < (lhs: SafetyLevel, rhs: SafetyLevel) -> Bool { lhs.rank < rhs.rank }
}

/// An external command used to clean things that are not plain files (Docker, simulators, Homebrew).
public struct ShellCommand: Sendable, Hashable, Codable {
    public let executable: String
    public let arguments: [String]

    public init(_ executable: String, _ arguments: [String]) {
        self.executable = executable
        self.arguments = arguments
    }

    /// Human-readable form shown in the confirmation sheet.
    public var display: String {
        ([(executable as NSString).lastPathComponent] + arguments).joined(separator: " ")
    }
}

public enum CleanupAction: Sendable, Hashable {
    /// Move these paths to the Trash (recoverable).
    case trash([URL])
    /// Run a tool-specific command.
    case command(ShellCommand)
    /// Permanently delete the contents of this Trash folder.
    case emptyTrash(URL)
    /// Shown for information only: the app can't (or shouldn't) delete it. The text says how to do it by hand.
    case manual(String)

    public var summary: String {
        switch self {
        case .trash(let urls): urls.count == 1 ? "Move to Trash" : "Move \(urls.count) items to Trash"
        case .command(let cmd): "Run: \(cmd.display)"
        case .emptyTrash: "Permanently delete Trash contents"
        case .manual(let instructions): instructions
        }
    }

    public var isPermanent: Bool {
        switch self {
        case .trash, .manual: false
        case .command, .emptyTrash: true
        }
    }

    /// False for `.manual` items: they can't be selected or cleaned by the app.
    public var isActionable: Bool {
        if case .manual = self { return false }
        return true
    }
}

public struct CleanupItem: Identifiable, Sendable, Hashable {
    public let id: String
    public let providerID: String
    public var title: String
    public var detail: String
    /// Location used for "Reveal in Finder", if any.
    public var url: URL?
    /// Bytes on disk (allocated size).
    public var size: Int64
    public var lastModified: Date?
    public var safety: SafetyLevel
    public var action: CleanupAction
    public var note: String?
    /// Optional tab this item is shown under (e.g. "Containers", "Images").
    public var tab: String?
    /// Optional in-use state, shown as a switch inside the tab (e.g. Stopped / Running).
    public var usage: Usage?
    /// Order of tabs, and the order actions run in (lower first),
    /// e.g. containers are removed before the images they use.
    public var groupOrder: Int
    /// Extra facts for cleanup rules (e.g. "app" for archives, "available" for simulators).
    public var meta: [String: String]

    public init(
        id: String,
        providerID: String,
        title: String,
        detail: String = "",
        url: URL? = nil,
        size: Int64,
        lastModified: Date? = nil,
        safety: SafetyLevel = .safe,
        action: CleanupAction,
        note: String? = nil,
        tab: String? = nil,
        usage: Usage? = nil,
        groupOrder: Int = 0,
        meta: [String: String] = [:]
    ) {
        self.id = id
        self.providerID = providerID
        self.title = title
        self.detail = detail
        self.url = url
        self.size = size
        self.lastModified = lastModified
        self.safety = safety
        self.action = action
        self.note = note
        self.tab = tab
        self.usage = usage
        self.groupOrder = groupOrder
        self.meta = meta
    }
}

public struct Usage: Sendable, Hashable {
    public let inUse: Bool
    /// Label for this state, e.g. "Running" / "Stopped" or "In use" / "Unused".
    public let label: String

    public init(inUse: Bool, label: String) {
        self.inUse = inUse
        self.label = label
    }

    public static let used = Usage(inUse: true, label: "In use")
    public static let unused = Usage(inUse: false, label: "Unused")
}

public enum ProviderAvailability: Sendable, Equatable {
    case available
    /// Tool or folder does not exist on this Mac: the provider is hidden.
    case notInstalled
    /// Installed but cannot be scanned right now (e.g. Docker not running).
    case unavailable(String)
}

/// A source of reclaimable space. Implementations should be cheap to create.
public protocol CleanupProvider: Sendable {
    var id: String { get }
    var title: String { get }
    /// SF Symbol name.
    var icon: String { get }
    var category: CleanupCategory { get }
    /// Optional explanation shown above the item list.
    var note: String? { get }
    /// Bundle IDs of apps that should be quit before cleaning (warning only).
    var relatedApps: [String] { get }

    func availability() async -> ProviderAvailability
    func scan() async throws -> [CleanupItem]
}

extension CleanupProvider {
    public var note: String? { nil }
    public var relatedApps: [String] { [] }
}

public struct ProviderError: LocalizedError, Sendable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

public enum ByteFormat {
    public static func string(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

public enum Paths {
    public static var home: URL { FileManager.default.homeDirectoryForCurrentUser }

    /// "~/Library/Caches" style display path.
    public static func display(_ url: URL, home: URL = Paths.home) -> String {
        let path = url.path
        let homePath = home.path
        if path == homePath { return "~" }
        if path.hasPrefix(homePath + "/") { return "~" + path.dropFirst(homePath.count) }
        return path
    }
}

extension ShellCommand {
    /// Copy-pasteable shell form, with arguments quoted when needed.
    public var shellLine: String {
        ([(executable as NSString).lastPathComponent] + arguments).map(ShellCommand.quote).joined(separator: " ")
    }

    static func quote(_ argument: String) -> String {
        let safe = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_@%+=:,./-")
        if !argument.isEmpty, argument.unicodeScalars.allSatisfy(safe.contains) { return argument }
        return "'" + argument.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

extension CleanupItem {
    /// The command this item runs when cleaned, if it is a command action.
    public var command: ShellCommand? {
        if case .command(let command) = action { return command }
        return nil
    }
}
