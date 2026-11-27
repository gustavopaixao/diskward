import Foundation

/// What a rule selects. New kinds can be added freely; stored rules with unknown kinds are dropped.
public enum RuleKind: String, Codable, CaseIterable, Sendable {
    case derivedDataOlderThan
    case stoppedDockerContainers
    case danglingDockerImages
    case dockerBuildCache
    case unavailableSimulators
    case keepLatestArchives
    case cachesOlderThan
    case logsOlderThan
    case nodeModulesOlderThan
    case packageManagerCaches

    /// Whether the rule has a number to adjust, and what it means.
    public var valueUnit: String? {
        switch self {
        case .derivedDataOlderThan, .cachesOlderThan, .logsOlderThan, .nodeModulesOlderThan: "days"
        case .keepLatestArchives: "archives per app"
        default: nil
        }
    }

    public var valueRange: ClosedRange<Int> {
        self == .keepLatestArchives ? 1...50 : 1...365
    }

    public var defaultValue: Int {
        switch self {
        case .derivedDataOlderThan: 14
        case .keepLatestArchives: 3
        case .cachesOlderThan, .logsOlderThan, .nodeModulesOlderThan: 30
        default: 0
        }
    }

    public var enabledByDefault: Bool {
        switch self {
        case .derivedDataOlderThan, .stoppedDockerContainers, .danglingDockerImages, .unavailableSimulators, .logsOlderThan:
            true
        default:
            false
        }
    }

    public func title(value: Int) -> String {
        switch self {
        case .derivedDataOlderThan: "DerivedData not built in \(value) days"
        case .stoppedDockerContainers: "Stopped Docker containers"
        case .danglingDockerImages: "Untagged (dangling) Docker images"
        case .dockerBuildCache: "Docker build cache"
        case .unavailableSimulators: "Simulators whose runtime is gone"
        case .keepLatestArchives: "Keep only the newest \(value) archives per app"
        case .cachesOlderThan: "App caches untouched for \(value) days"
        case .logsOlderThan: "Logs older than \(value) days"
        case .nodeModulesOlderThan: "node_modules in projects untouched for \(value) days"
        case .packageManagerCaches: "Package manager download caches"
        }
    }

    public var explanation: String {
        switch self {
        case .derivedDataOlderThan: "Xcode rebuilds it on the next build."
        case .stoppedDockerContainers: "Containers that aren't running. Their volumes are kept."
        case .danglingDockerImages: "Leftover layers from rebuilt images, not used by any container."
        case .dockerBuildCache: "Makes the next docker build slower."
        case .unavailableSimulators: "Can't be booted anymore because their iOS version was removed."
        case .keepLatestArchives: "Older archives lose the dSYMs for crash reports of those builds."
        case .cachesOlderThan: "Skips Apple caches (com.apple.*)."
        case .logsOlderThan: "Old app logs."
        case .nodeModulesOlderThan: "Run npm install to get them back."
        case .packageManagerCaches: "npm, Yarn, pnpm, pip, Gradle, CocoaPods, Go, Homebrew… Re-downloaded when needed. Skips the Maven repository and Go modules."
        }
    }
}

public struct CleanupRule: Codable, Identifiable, Hashable, Sendable {
    public var id: String { kind.rawValue }
    public let kind: RuleKind
    public var enabled: Bool
    public var value: Int

    public init(kind: RuleKind, enabled: Bool? = nil, value: Int? = nil) {
        self.kind = kind
        self.enabled = enabled ?? kind.enabledByDefault
        self.value = value ?? kind.defaultValue
    }

    public var title: String { kind.title(value: value) }
}

public enum RuleEngine {
    public static func defaultRules() -> [CleanupRule] {
        RuleKind.allCases.map { CleanupRule(kind: $0) }
    }

    /// Stored rules merged with defaults, so newly added rule kinds appear.
    public static func merged(_ stored: [CleanupRule]) -> [CleanupRule] {
        RuleKind.allCases.map { kind in stored.first { $0.kind == kind } ?? CleanupRule(kind: kind) }
    }

    static let packageManagerProviders: Set<String> = ["homebrew", "js", "python", "jvm", "apple-pm", "go"]

    /// Items the rule selects. Manual items are never selected.
    public static func matches(_ rule: CleanupRule, in items: [CleanupItem], now: Date = Date()) -> [CleanupItem] {
        let cutoff = now.addingTimeInterval(-Double(rule.value) * 86_400)
        func olderThanCutoff(_ item: CleanupItem) -> Bool { (item.lastModified ?? now) < cutoff }
        let candidates = items.filter(\.action.isActionable)

        switch rule.kind {
        case .derivedDataOlderThan:
            return candidates.filter { $0.providerID == "derived-data" && olderThanCutoff($0) }
        case .stoppedDockerContainers:
            return candidates.filter { $0.providerID == "docker" && $0.tab == "Containers" && $0.usage?.inUse == false }
        case .danglingDockerImages:
            return candidates.filter {
                $0.providerID == "docker" && $0.tab == "Images" && $0.usage?.inUse == false && $0.title.hasPrefix("<untagged>")
            }
        case .dockerBuildCache:
            return candidates.filter { $0.providerID == "docker" && $0.tab == "Build Cache" }
        case .unavailableSimulators:
            return candidates.filter {
                $0.providerID == "simulators" && $0.meta["available"] == "false" && $0.meta["booted"] != "true"
            }
        case .keepLatestArchives:
            let archives = candidates.filter { $0.providerID == "archives" }
            return Dictionary(grouping: archives) { $0.meta["app"] ?? $0.title }
                .values
                .flatMap { group in
                    group.sorted { ($0.lastModified ?? .distantPast) > ($1.lastModified ?? .distantPast) }
                        .dropFirst(rule.value)
                }
        case .cachesOlderThan:
            return candidates.filter { $0.providerID == "caches" && $0.safety == .safe && olderThanCutoff($0) }
        case .logsOlderThan:
            return candidates.filter { $0.providerID == "logs" && olderThanCutoff($0) }
        case .nodeModulesOlderThan:
            return candidates.filter { $0.providerID == "node-modules" && olderThanCutoff($0) }
        case .packageManagerCaches:
            return candidates.filter { packageManagerProviders.contains($0.providerID) && $0.safety == .safe }
        }
    }

    /// Everything the enabled rules select, without duplicates.
    public static func apply(_ rules: [CleanupRule], to items: [CleanupItem], now: Date = Date()) -> [CleanupItem] {
        var seen = Set<String>()
        return rules.filter(\.enabled)
            .flatMap { matches($0, in: items, now: now) }
            .filter { seen.insert($0.id).inserted }
    }
}
