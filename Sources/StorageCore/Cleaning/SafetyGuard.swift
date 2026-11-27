import Foundation

public struct SafetyViolation: LocalizedError, Sendable, Equatable {
    public let path: String
    public let reason: String
    public var errorDescription: String? { "Refused to delete \(path): \(reason)" }
}

/// Last line of defence: every path is checked here right before it is trashed.
///
/// A path is allowed only if it is strictly inside one of `allowedRoots` (by default the home
/// folder) and is not one of the protected folders or inside a protected subtree.
/// Symlinks in the parent path are resolved first, so a link can't smuggle us outside the home folder.
public struct SafetyGuard: Sendable {
    public let home: String
    public let allowedRoots: [String]

    /// Exact paths (relative to home) that must never be deleted as a whole.
    static let protectedExact = [
        "", "Library", "Library/Application Support", "Library/Preferences", "Library/Containers",
        "Library/Group Containers", "Library/Caches", "Library/Logs", "Library/Developer",
        "Library/Developer/Xcode", "Library/Developer/CoreSimulator",
        "Desktop", "Documents", "Downloads", "Movies", "Music", "Pictures", "Public", "Applications",
        ".Trash", ".config", ".local", ".cache", ".docker", ".npm", ".gradle", ".m2", ".jenkins",
    ]

    /// Subtrees (relative to home) where nothing may be deleted.
    static let protectedSubtrees = [
        ".ssh", ".gnupg", ".aws", ".kube", ".Trash",
        "Library/Keychains", "Library/Mobile Documents", "Library/Mail", "Library/Messages",
        "Library/Photos", "Library/CloudStorage", "Library/Accounts", "Library/Cookies",
        "Pictures/Photos Library.photoslibrary",
    ]

    public init(home: URL = Paths.home, extraRoots: [URL] = []) {
        let resolvedHome = SafetyGuard.resolve(home)
        self.home = resolvedHome
        self.allowedRoots = [resolvedHome] + extraRoots.map(SafetyGuard.resolve)
    }

    /// Resolves symlinks in the *parent* path but keeps the last component, so trashing a
    /// symlink removes the link itself, never its target.
    static func resolve(_ url: URL) -> String {
        let standardized = url.standardizedFileURL
        let name = standardized.lastPathComponent
        let parent = standardized.deletingLastPathComponent().resolvingSymlinksInPath()
        if standardized.path == "/" { return "/" }
        return parent.appendingPathComponent(name).path
    }

    public func validate(_ url: URL) throws {
        let path = SafetyGuard.resolve(url)
        func fail(_ reason: String) -> SafetyViolation { SafetyViolation(path: path, reason: reason) }

        guard path.hasPrefix("/"), !path.contains("/../") else { throw fail("not an absolute, normalized path") }

        let inAllowedRoot = allowedRoots.contains { root in path.hasPrefix(root + "/") }
        guard inAllowedRoot else { throw fail("outside the allowed folders") }

        if path.hasPrefix(home + "/") || path == home {
            let relative = path == home ? "" : String(path.dropFirst(home.count + 1))
            if SafetyGuard.protectedExact.contains(relative) {
                throw fail("this folder is protected")
            }
            for subtree in SafetyGuard.protectedSubtrees
            where relative == subtree || relative.hasPrefix(subtree + "/") {
                throw fail("inside protected folder ~/\(subtree)")
            }
        }
    }

    /// Validates that `url` is a direct or nested child of the given Trash folder.
    public func validateTrashContent(_ url: URL, trash: URL) throws {
        let path = SafetyGuard.resolve(url)
        let trashPath = trash.resolvingSymlinksInPath().path
        guard path.hasPrefix(trashPath + "/") else {
            throw SafetyViolation(path: path, reason: "not inside the Trash")
        }
    }
}
