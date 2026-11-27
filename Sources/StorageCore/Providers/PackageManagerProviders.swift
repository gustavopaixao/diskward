import Foundation

public struct HomebrewProvider: CleanupProvider {
    public let id = "homebrew"
    public let title = "Homebrew"
    public let icon = "mug"
    public let category = CleanupCategory.packageManagers
    public let note: String? = "Runs `brew cleanup --prune=all`, which removes downloaded bottles and old versions of installed packages."

    public init() {}

    public func availability() async -> ProviderAvailability {
        ShellRunner.which("brew") == nil ? .notInstalled : .available
    }

    public func scan() async throws -> [CleanupItem] {
        let output = try await ShellRunner.run("brew", ["--cache"], timeout: 30)
        let path = output.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard output.succeeded, !path.isEmpty else { throw ProviderError("brew --cache failed") }
        let cache = URL(fileURLWithPath: path)
        let measured = SizeCalculator.measure(cache)
        guard measured.size > 0 else { return [] }
        return [CleanupItem(
            id: "\(id):cache",
            providerID: id,
            title: "Homebrew download cache",
            detail: Paths.display(cache),
            url: cache,
            size: measured.size,
            lastModified: measured.lastModified,
            safety: .safe,
            action: .command(ShellCommand("brew", ["cleanup", "--prune=all", "-s"]))
        )]
    }
}

/// Finds `node_modules` folders in your project directories.
public struct NodeModulesProvider: CleanupProvider {
    public let id = "node-modules"
    public let title = "node_modules"
    public let icon = "folder.badge.minus"
    public let category = CleanupCategory.projects
    public let note: String?
    let home: URL
    let roots: [URL]
    let maxDepth: Int
    let staleDays: Double

    public static let defaultRootNames = [
        "lab", "Developer", "Projects", "projects", "code", "Code", "src", "dev", "workspace", "repos", "git",
        "Documents/GitHub", "Documents/Projects",
    ]

    public init(home: URL = Paths.home, roots: [URL]? = nil, maxDepth: Int = 6, staleDays: Double = 30) {
        self.home = home
        self.roots = roots ?? NodeModulesProvider.defaultRootNames.map { home.appendingPathComponent($0) }
        self.maxDepth = maxDepth
        self.staleDays = staleDays
        self.note = "Run `npm install` to get them back. Projects untouched for \(Int(staleDays))+ days are pre-selected."
    }

    var existingRoots: [URL] {
        // De-duplicate case-insensitive duplicates (APFS is usually case-insensitive).
        var seen = Set<String>()
        return roots.filter { FS.isDirectory($0) && seen.insert($0.resolvingSymlinksInPath().path.lowercased()).inserted }
    }

    public func availability() async -> ProviderAvailability {
        existingRoots.isEmpty ? .notInstalled : .available
    }

    public func scan() async throws -> [CleanupItem] {
        let found = existingRoots.flatMap { find(in: $0) }
        let cutoff = ProviderSupport.daysAgo(staleDays)
        let home = self.home
        let id = self.id
        let items = await found.concurrentMap { url -> CleanupItem? in
            let measured = SizeCalculator.measure(url)
            guard measured.size > 0 else { return nil }
            let project = url.deletingLastPathComponent()
            let stale = measured.lastModified.map { $0 < cutoff } ?? false
            return CleanupItem(
                id: "\(id):\(url.path)",
                providerID: id,
                title: project.lastPathComponent,
                detail: Paths.display(project, home: home),
                url: url,
                size: measured.size,
                lastModified: measured.lastModified,
                safety: stale ? .safe : .caution,
                action: .trash([url])
            )
        }
        return items.compactMap { $0 }.sorted { $0.size > $1.size }
    }

    /// Breadth-first walk that stops at each `node_modules` (no nested ones) and skips hidden folders.
    func find(in root: URL) -> [URL] {
        var result: [URL] = []
        var queue: [(URL, Int)] = [(root, 0)]
        while !queue.isEmpty {
            let (dir, depth) = queue.removeFirst()
            for child in FS.children(dir) where FS.isDirectory(child) {
                let name = child.lastPathComponent
                if name == "node_modules" {
                    result.append(child)
                } else if !name.hasPrefix("."), depth + 1 < maxDepth, name != "Library", !name.hasSuffix(".app") {
                    queue.append((child, depth + 1))
                }
            }
        }
        return result
    }
}
