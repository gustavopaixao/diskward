import Foundation

/// Shared building blocks so each provider stays small.
enum ProviderSupport {
    /// One item per child of `directory`, measured concurrently, sorted by size.
    static func childItems(
        of directory: URL,
        providerID: String,
        minSize: Int64 = 0,
        home: URL,
        filter: @escaping @Sendable (URL) -> Bool = { _ in true },
        title: @Sendable (URL) -> String = { $0.lastPathComponent },
        safety: @Sendable (DirectoryScanner.Child) -> SafetyLevel = { _ in .safe },
        note: @Sendable (DirectoryScanner.Child) -> String? = { _ in nil }
    ) async -> [CleanupItem] {
        let children = await DirectoryScanner.children(of: directory, filter: filter)
        return children
            .filter { $0.size >= minSize && $0.size > 0 }
            .map { child in
                CleanupItem(
                    id: "\(providerID):\(child.url.path)",
                    providerID: providerID,
                    title: title(child.url),
                    detail: Paths.display(child.url, home: home),
                    url: child.url,
                    size: child.size,
                    lastModified: child.lastModified,
                    safety: safety(child),
                    action: .trash([child.url]),
                    note: note(child)
                )
            }
            .sorted { $0.size > $1.size }
    }

    /// A single item for a whole folder, or nil if it doesn't exist / is empty.
    static func pathItem(
        _ url: URL,
        providerID: String,
        title: String,
        home: URL,
        safety: SafetyLevel = .safe,
        note: String? = nil
    ) -> CleanupItem? {
        guard FS.exists(url) else { return nil }
        let measured = SizeCalculator.measure(url)
        guard measured.size > 0 else { return nil }
        return CleanupItem(
            id: "\(providerID):\(url.path)",
            providerID: providerID,
            title: title,
            detail: Paths.display(url, home: home),
            url: url,
            size: measured.size,
            lastModified: measured.lastModified,
            safety: safety,
            action: .trash([url]),
            note: note
        )
    }

    static func daysAgo(_ days: Double) -> Date { Date().addingTimeInterval(-days * 86_400) }
}

// MARK: - Known paths (package manager caches etc.)

public struct KnownPath: Sendable {
    public let relativePath: String
    public let title: String
    public let safety: SafetyLevel
    public let note: String?
    /// Use the tool's own cleanup command instead of trashing the folder (when the tool is installed).
    public let command: ShellCommand?

    public init(_ relativePath: String, _ title: String, safety: SafetyLevel = .safe, note: String? = nil, command: ShellCommand? = nil) {
        self.relativePath = relativePath
        self.title = title
        self.safety = safety
        self.note = note
        self.command = command
    }
}

/// A provider made of a fixed list of well-known cache folders.
public struct KnownPathsProvider: CleanupProvider {
    public let id: String
    public let title: String
    public let icon: String
    public let category: CleanupCategory
    public let note: String?
    public let paths: [KnownPath]
    let home: URL

    public init(id: String, title: String, icon: String, category: CleanupCategory,
                note: String? = nil, paths: [KnownPath], home: URL = Paths.home) {
        self.id = id
        self.title = title
        self.icon = icon
        self.category = category
        self.note = note
        self.paths = paths
        self.home = home
    }

    public func availability() async -> ProviderAvailability {
        paths.contains { FS.exists(home.appendingPathComponent($0.relativePath)) } ? .available : .notInstalled
    }

    public func scan() async throws -> [CleanupItem] {
        let home = self.home
        let id = self.id
        let items = await paths.concurrentMap { known -> CleanupItem? in
            guard var item = ProviderSupport.pathItem(
                home.appendingPathComponent(known.relativePath),
                providerID: id, title: known.title, home: home,
                safety: known.safety, note: known.note
            ) else { return nil }
            if let command = known.command, ShellRunner.which(command.executable) != nil {
                item.action = .command(command)
            }
            return item
        }
        return items.compactMap { $0 }.sorted { $0.size > $1.size }
    }
}

extension KnownPathsProvider {
    public static func javaScript(home: URL = Paths.home) -> KnownPathsProvider {
        KnownPathsProvider(
            id: "js", title: "npm / Yarn / pnpm / Bun", icon: "shippingbox", category: .packageManagers,
            note: "Download caches. Packages are re-downloaded on the next install.",
            paths: [
                KnownPath(".npm/_cacache", "npm cache"),
                KnownPath("Library/Caches/Yarn", "Yarn cache"),
                KnownPath("Library/pnpm/store", "pnpm store",
                          note: "Removes packages no project uses. Projects hard-link into the store, so less space may be freed than shown.",
                          command: ShellCommand("pnpm", ["store", "prune"])),
                KnownPath("Library/Caches/pnpm", "pnpm metadata cache"),
                KnownPath(".bun/install/cache", "Bun cache"),
            ], home: home)
    }

    public static func python(home: URL = Paths.home) -> KnownPathsProvider {
        KnownPathsProvider(
            id: "python", title: "pip / uv / Poetry", icon: "chevron.left.forwardslash.chevron.right",
            category: .packageManagers, note: "Wheel and download caches.",
            paths: [
                KnownPath("Library/Caches/pip", "pip cache"),
                KnownPath(".cache/pip", "pip cache (XDG)"),
                KnownPath(".cache/uv", "uv cache"),
                KnownPath("Library/Caches/pypoetry", "Poetry cache"),
            ], home: home)
    }

    public static func jvm(home: URL = Paths.home) -> KnownPathsProvider {
        KnownPathsProvider(
            id: "jvm", title: "Gradle / Maven", icon: "cup.and.saucer", category: .packageManagers,
            note: "Gradle caches are rebuilt automatically. The Maven repository is re-downloaded on the next build (can be slow).",
            paths: [
                KnownPath(".gradle/caches", "Gradle caches"),
                KnownPath(".gradle/wrapper/dists", "Gradle wrapper distributions"),
                KnownPath(".m2/repository", "Maven local repository", safety: .caution),
            ], home: home)
    }

    public static func apple(home: URL = Paths.home) -> KnownPathsProvider {
        KnownPathsProvider(
            id: "apple-pm", title: "CocoaPods / SwiftPM / Carthage", icon: "swift", category: .packageManagers,
            paths: [
                KnownPath("Library/Caches/CocoaPods", "CocoaPods cache"),
                KnownPath("Library/Caches/org.swift.swiftpm", "Swift Package Manager cache"),
                KnownPath("Library/Caches/org.carthage.CarthageKit", "Carthage cache"),
            ], home: home)
    }

    public static func go(home: URL = Paths.home) -> KnownPathsProvider {
        KnownPathsProvider(
            id: "go", title: "Go", icon: "hare", category: .packageManagers,
            paths: [
                KnownPath("Library/Caches/go-build", "Go build cache"),
                KnownPath("go/pkg/mod", "Go module cache", safety: .caution),
            ], home: home)
    }
}
