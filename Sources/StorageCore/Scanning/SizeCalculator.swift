import Darwin
import Foundation

public struct SizeResult: Sendable, Equatable {
    /// Allocated bytes on disk.
    public var size: Int64
    /// Most recent modification date found in the tree.
    public var lastModified: Date?
    /// Entries that could not be read (permissions, races).
    public var unreadable: Int

    public init(size: Int64 = 0, lastModified: Date? = nil, unreadable: Int = 0) {
        self.size = size
        self.lastModified = lastModified
        self.unreadable = unreadable
    }
}

/// Measures real disk usage of a file or folder using fts(3), which is much faster than
/// FileManager enumeration and gives us `st_blocks` (allocated size) and inode info.
///
/// - Symlinks are never followed (the link itself is counted).
/// - Hard-linked files are counted once per measurement.
/// - APFS clones are counted at full size (APFS does not expose shared extents cheaply),
///   so totals can be a little higher than what deleting actually frees.
public enum SizeCalculator {
    private struct InodeKey: Hashable {
        let dev: Int32
        let ino: UInt64
    }

    /// - Parameter sameDevice: Do not cross into other mounted volumes (used for whole-disk scans).
    public static func measure(_ url: URL, sameDevice: Bool = false) -> SizeResult {
        var result = SizeResult()
        var latest = 0
        var seen = Set<InodeKey>()

        guard let cPath = strdup(url.path) else { return SizeResult(unreadable: 1) }
        defer { free(cPath) }

        var options = FTS_PHYSICAL | FTS_NOCHDIR
        if sameDevice { options |= FTS_XDEV }

        let paths: [UnsafeMutablePointer<CChar>?] = [cPath, nil]
        guard let fts = fts_open(paths, options, nil) else { return SizeResult(unreadable: 1) }
        defer { fts_close(fts) }

        var counter = 0
        while let entry = fts_read(fts) {
            counter += 1
            if counter & 0x3FF == 0, Task.isCancelled { break }

            let info = Int32(entry.pointee.fts_info)
            switch info {
            case FTS_DP:
                continue // post-order visit of a directory, already counted
            case FTS_DNR, FTS_ERR, FTS_NS:
                result.unreadable += 1
                continue
            default:
                break
            }
            guard let stat = entry.pointee.fts_statp?.pointee else { continue }

            if info != FTS_D, stat.st_nlink > 1 {
                let key = InodeKey(dev: stat.st_dev, ino: stat.st_ino)
                if !seen.insert(key).inserted { continue }
            }
            result.size += Int64(stat.st_blocks) * 512
            latest = max(latest, stat.st_mtimespec.tv_sec)
        }

        if latest > 0 { result.lastModified = Date(timeIntervalSince1970: TimeInterval(latest)) }
        return result
    }
}

/// Lists a folder's direct children and measures each one concurrently.
public enum DirectoryScanner {
    public struct Child: Sendable, Identifiable, Hashable {
        public var id: URL { url }
        public let url: URL
        public let isDirectory: Bool
        public let size: Int64
        public let lastModified: Date?
        public let unreadable: Int
        public var name: String { url.lastPathComponent }
    }

    public static func children(
        of directory: URL,
        sameDevice: Bool = false,
        filter: @escaping @Sendable (URL) -> Bool = { _ in true }
    ) async -> [Child] {
        let urls = FS.children(directory).filter(filter)
        return await urls.concurrentMap { url in
            let measured = SizeCalculator.measure(url, sameDevice: sameDevice)
            return Child(
                url: url,
                isDirectory: FS.isDirectory(url),
                size: measured.size,
                lastModified: measured.lastModified,
                unreadable: measured.unreadable
            )
        }
    }
}

/// Small file-system helpers. Never follow symlinks when deciding "is this a directory".
public enum FS {
    public static func exists(_ url: URL) -> Bool {
        var st = stat()
        return lstat(url.path, &st) == 0
    }

    public static func isDirectory(_ url: URL) -> Bool {
        var st = stat()
        guard lstat(url.path, &st) == 0 else { return false }
        return (st.st_mode & S_IFMT) == S_IFDIR
    }

    public static func children(_ directory: URL) -> [URL] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names
            .filter { $0 != ".DS_Store" && $0 != ".localized" }
            .map { directory.appendingPathComponent($0) }
    }

    public static func canList(_ directory: URL) -> Bool {
        (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) != nil
    }
}

extension Array where Element: Sendable {
    /// Order-preserving async map with bounded concurrency.
    public func concurrentMap<T: Sendable>(
        limit: Int = 8,
        _ transform: @escaping @Sendable (Element) async -> T
    ) async -> [T] {
        guard !isEmpty else { return [] }
        return await withTaskGroup(of: (Int, T).self) { group in
            var results = [T?](repeating: nil, count: count)
            var next = 0
            func enqueue() {
                let index = next
                let element = self[index]
                group.addTask { (index, await transform(element)) }
                next += 1
            }
            for _ in 0..<Swift.min(limit, count) { enqueue() }
            for await (index, value) in group {
                results[index] = value
                if next < count, !Task.isCancelled { enqueue() }
            }
            return results.compactMap { $0 }
        }
    }
}
