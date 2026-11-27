import Foundation
import Observation
import StorageCore

/// "What's using my disk?" Drill-down of folder sizes, cached per folder for the session.
@MainActor
@Observable
final class ExplorerModel {
    var root: URL = Paths.home
    var path: [URL] = [Paths.home]
    var isLoading = false
    private(set) var cache: [URL: [DirectoryScanner.Child]] = [:]
    private var loadTask: Task<Void, Never>?

    var current: URL { path.last ?? root }
    var children: [DirectoryScanner.Child] { cache[current] ?? [] }
    var currentTotal: Int64 { children.reduce(0) { $0 + $1.size } }

    func setRoot(_ url: URL) {
        root = url
        path = [url]
        load(url)
    }

    func open(_ url: URL) {
        path.append(url)
        load(url)
    }

    func goTo(index: Int) {
        guard path.indices.contains(index) else { return }
        path = Array(path.prefix(index + 1))
        load(current)
    }

    func refresh() {
        cache[current] = nil
        load(current, force: true)
    }

    func load(_ url: URL, force: Bool = false) {
        if !force, cache[url] != nil { return }
        loadTask?.cancel()
        isLoading = true
        // Don't cross into other volumes when scanning "/" (Time Machine, external disks, etc).
        let sameDevice = url.path == "/"
        loadTask = Task {
            let children = await Task.detached(priority: .userInitiated) {
                await DirectoryScanner.children(of: url, sameDevice: sameDevice)
                    .sorted { $0.size > $1.size }
            }.value
            guard !Task.isCancelled else { return }
            cache[url] = children
            isLoading = false
        }
    }

    /// Called after something in the current folder was trashed.
    func remove(_ child: DirectoryScanner.Child) {
        cache[current]?.removeAll { $0.url == child.url }
        // Parent totals are stale now.
        for url in path.dropLast() { cache[url] = nil }
    }
}
