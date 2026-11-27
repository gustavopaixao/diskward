import Foundation

// MARK: - Shared: "keep the newest version, older ones are safe to delete"

enum Versioned {
    struct Entry: Sendable {
        let url: URL
        let key: String
        let version: String
    }

    /// One item per entry. Within each key, the newest version is `.caution` (probably in use)
    /// and older versions are `.safe`.
    static func items(
        _ entries: [Entry], providerID: String, home: URL,
        title: @escaping @Sendable (Entry) -> String,
        newestNote: String = "Newest version (probably in use)"
    ) async -> [CleanupItem] {
        let newest: [String: String] = Dictionary(grouping: entries, by: \.key).mapValues { group in
            group.map(\.version).max { $0.compare($1, options: .numeric) == .orderedAscending } ?? ""
        }
        let items = await entries.concurrentMap { entry -> CleanupItem? in
            let measured = SizeCalculator.measure(entry.url)
            guard measured.size > 0 else { return nil }
            let isNewest = newest[entry.key] == entry.version
            return CleanupItem(
                id: "\(providerID):\(entry.url.path)",
                providerID: providerID,
                title: title(entry),
                detail: Paths.display(entry.url, home: home),
                url: entry.url,
                size: measured.size,
                lastModified: measured.lastModified,
                safety: isNewest ? .caution : .safe,
                action: .trash([entry.url]),
                note: isNewest ? newestNote : "Older version"
            )
        }
        return items.compactMap { $0 }
    }

    /// "chromium-1140" → ("chromium", "1140"); "ms.python-2024.1.0-darwin-arm64" → ("ms.python", "2024.1.0-darwin-arm64").
    static func splitNameVersion(_ name: String) -> (key: String, version: String)? {
        guard let range = name.range(of: #"-v?\d+(\.\d+)*([-.+].*)?$"#, options: .regularExpression) else { return nil }
        let key = String(name[..<range.lowerBound])
        var version = String(name[range]).dropFirst()
        if version.hasPrefix("v") { version = version.dropFirst() }
        return key.isEmpty ? nil : (key, String(version))
    }
}

// MARK: - Android

public struct AndroidProvider: CleanupProvider {
    public let id = "android"
    public let title = "Android"
    public let icon = "apps.iphone"
    public let category = CleanupCategory.devTools
    public let note: String? = "Emulators (AVDs) and SDK system images. Emulators lose their data; system images can be downloaded again in Android Studio › SDK Manager."
    let home: URL
    let sdk: URL

    public init(home: URL = Paths.home, environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.home = home
        let sdkPath = environment["ANDROID_HOME"] ?? environment["ANDROID_SDK_ROOT"]
        self.sdk = sdkPath.map { URL(fileURLWithPath: $0) } ?? home.appendingPathComponent("Library/Android/sdk")
    }

    var avdDir: URL { home.appendingPathComponent(".android/avd") }

    public func availability() async -> ProviderAvailability {
        FS.exists(avdDir) || FS.exists(sdk) ? .available : .notInstalled
    }

    public func scan() async throws -> [CleanupItem] {
        let home = self.home
        let id = self.id

        // Emulators: "<name>.avd" folder + "<name>.ini" file.
        let avds = FS.children(avdDir).filter { $0.pathExtension == "avd" }
        var items = await avds.concurrentMap { avd -> CleanupItem? in
            let measured = SizeCalculator.measure(avd)
            guard measured.size > 0 else { return nil }
            let name = avd.deletingPathExtension().lastPathComponent
            let ini = avd.deletingPathExtension().appendingPathExtension("ini")
            return CleanupItem(
                id: "\(id):\(avd.path)", providerID: id,
                title: "Emulator: \(name.replacingOccurrences(of: "_", with: " "))",
                detail: Paths.display(avd, home: home), url: avd, size: measured.size,
                lastModified: measured.lastModified, safety: .caution,
                action: .trash(FS.exists(ini) ? [avd, ini] : [avd]),
                tab: "Emulators", groupOrder: 0)
        }.compactMap { $0 }

        // System images: system-images/<api>/<tag>/<abi>
        let images = FS.children(sdk.appendingPathComponent("system-images"))
            .flatMap { api in FS.children(api).flatMap { tag in FS.children(tag).map { (api, tag, $0) } } }
            .filter { FS.isDirectory($0.2) }
        items += await images.concurrentMap { api, tag, abi -> CleanupItem? in
            let measured = SizeCalculator.measure(abi)
            guard measured.size > 0 else { return nil }
            return CleanupItem(
                id: "\(id):\(abi.path)", providerID: id,
                title: "\(api.lastPathComponent) · \(tag.lastPathComponent) · \(abi.lastPathComponent)",
                detail: Paths.display(abi, home: home), url: abi, size: measured.size,
                lastModified: measured.lastModified, safety: .caution, action: .trash([abi]),
                tab: "System Images", groupOrder: 1)
        }.compactMap { $0 }

        if let cache = ProviderSupport.pathItem(home.appendingPathComponent(".android/cache"),
                                                providerID: id, title: "Android tools cache", home: home) {
            var cache = cache
            cache.tab = "Caches"
            cache.groupOrder = 2
            items.append(cache)
        }
        return items.sorted { ($0.groupOrder, -$0.size) < ($1.groupOrder, -$1.size) }
    }
}

// MARK: - Playwright

public struct PlaywrightProvider: CleanupProvider {
    public let id = "playwright"
    public let title = "Playwright Browsers"
    public let icon = "theatermasks"
    public let category = CleanupCategory.devTools
    public let note: String? = "Each Playwright version downloads its own browsers. Older versions are pre-selected; `npx playwright install` gets any of them back."
    let home: URL

    public init(home: URL = Paths.home) { self.home = home }

    var directory: URL { home.appendingPathComponent("Library/Caches/ms-playwright") }

    public func availability() async -> ProviderAvailability {
        FS.exists(directory) ? .available : .notInstalled
    }

    public func scan() async throws -> [CleanupItem] {
        let entries = FS.children(directory)
            .filter { !$0.lastPathComponent.hasPrefix(".") && FS.isDirectory($0) }
            .compactMap { url -> Versioned.Entry? in
                guard let (key, version) = Versioned.splitNameVersion(url.lastPathComponent) else { return nil }
                return Versioned.Entry(url: url, key: key, version: version)
            }
        return await Versioned.items(entries, providerID: id, home: home,
                                     title: { "\($0.key) build \($0.version)" })
            .sorted { $0.size > $1.size }
    }
}

// MARK: - AI models

/// One line of `ollama list`: NAME ID SIZE MODIFIED.
struct OllamaModel: Equatable {
    let name: String
    let size: Int64
    let modified: String
}

public struct AIModelsProvider: CleanupProvider {
    public let id = "ai-models"
    public let title = "AI Models"
    public let icon = "brain"
    public let category = CleanupCategory.devTools
    public let note: String? = "Local models from Ollama, Hugging Face and LM Studio. They're often several GB each and can be downloaded again."
    let home: URL

    public init(home: URL = Paths.home) { self.home = home }

    var ollamaDir: URL { home.appendingPathComponent(".ollama/models") }
    var huggingFaceHub: URL { home.appendingPathComponent(".cache/huggingface/hub") }
    var lmStudioDirs: [URL] {
        [home.appendingPathComponent(".lmstudio/models"), home.appendingPathComponent(".cache/lm-studio/models")]
    }

    public func availability() async -> ProviderAvailability {
        ([ollamaDir, huggingFaceHub] + lmStudioDirs).contains(where: FS.exists) ? .available : .notInstalled
    }

    public func scan() async throws -> [CleanupItem] {
        var items: [CleanupItem] = []
        let home = self.home
        let id = self.id

        // Ollama: per model via the CLI when the server is running, else the whole folder.
        if FS.exists(ollamaDir) {
            if let output = try? await ShellRunner.run("ollama", ["list"], timeout: 15), output.succeeded {
                items += AIModelsProvider.parseOllama(output.stdoutString).map { model in
                    CleanupItem(
                        id: "\(id):ollama:\(model.name)", providerID: id, title: model.name,
                        detail: "Ollama · modified \(model.modified)", url: ollamaDir, size: model.size,
                        safety: .caution, action: .command(ShellCommand("ollama", ["rm", model.name])), tab: "Ollama")
                }
            } else if var whole = ProviderSupport.pathItem(ollamaDir, providerID: id, title: "All Ollama models",
                                                           home: home, safety: .caution,
                                                           note: "Start Ollama to see models one by one") {
                whole.tab = "Ollama"
                items.append(whole)
            }
        }

        // Hugging Face: hub/models--org--name, hub/datasets--org--name
        let hubEntries = FS.children(huggingFaceHub).filter {
            $0.lastPathComponent.hasPrefix("models--") || $0.lastPathComponent.hasPrefix("datasets--")
        }
        items += await hubEntries.concurrentMap { url -> CleanupItem? in
            guard var item = ProviderSupport.pathItem(url, providerID: id, title: AIModelsProvider.huggingFaceName(url.lastPathComponent),
                                                      home: home, safety: .caution) else { return nil }
            item.tab = "Hugging Face"
            return item
        }.compactMap { $0 }

        // LM Studio: models/<publisher>/<model>
        let lmModels = lmStudioDirs.flatMap { FS.children($0) }.flatMap { publisher in
            FS.children(publisher).filter(FS.isDirectory).map { (publisher, $0) }
        }
        items += await lmModels.concurrentMap { publisher, model -> CleanupItem? in
            guard var item = ProviderSupport.pathItem(model, providerID: id,
                                                      title: "\(publisher.lastPathComponent)/\(model.lastPathComponent)",
                                                      home: home, safety: .caution) else { return nil }
            item.tab = "LM Studio"
            return item
        }.compactMap { $0 }

        return items.sorted { $0.size > $1.size }
    }

    static func parseOllama(_ text: String) -> [OllamaModel] {
        // Names and IDs never contain spaces: NAME ID <number> <unit> <modified…>
        text.split(separator: "\n").dropFirst().compactMap { line in
            let parts = line.split(whereSeparator: \.isWhitespace).map(String.init)
            guard parts.count >= 5 else { return nil }
            return OllamaModel(name: parts[0], size: parseHumanSize("\(parts[2]) \(parts[3])"),
                               modified: parts[4...].joined(separator: " "))
        }
    }

    /// "4.7 GB", "274 MB" (decimal units, as Ollama prints them).
    static func parseHumanSize(_ text: String) -> Int64 {
        let parts = text.split(separator: " ")
        guard parts.count == 2, let number = Double(parts[0]) else { return 0 }
        let multiplier: Double = switch parts[1].uppercased() {
        case "TB": 1e12
        case "GB": 1e9
        case "MB": 1e6
        case "KB": 1e3
        default: 1
        }
        return Int64(number * multiplier)
    }

    /// "models--meta-llama--Llama-3-8B" → "meta-llama/Llama-3-8B"; datasets get a suffix.
    static func huggingFaceName(_ folder: String) -> String {
        let isDataset = folder.hasPrefix("datasets--")
        let name = folder
            .replacingOccurrences(of: isDataset ? "datasets--" : "models--", with: "")
            .replacingOccurrences(of: "--", with: "/")
        return isDataset ? "\(name) (dataset)" : name
    }
}

// MARK: - Editors

public struct EditorsProvider: CleanupProvider {
    public let id = "editors"
    public let title = "Editors & IDEs"
    public let icon = "chevron.left.forwardslash.chevron.right"
    public let category = CleanupCategory.devTools
    public let note: String? = "Caches from VS Code, Cursor, Windsurf and JetBrains IDEs, plus extension versions and IDE versions you've upgraded from. Quit the editor before cleaning its caches."
    public let relatedApps = [
        "com.microsoft.VSCode", "com.todesktop.230313mzl4w4u92", "com.exafunction.windsurf",
    ]
    let home: URL

    public init(home: URL = Paths.home) { self.home = home }

    /// (Application Support folder, extensions folder, display name)
    static let codeEditors = [
        ("Code", ".vscode/extensions", "VS Code"),
        ("Code - Insiders", ".vscode-insiders/extensions", "VS Code Insiders"),
        ("Cursor", ".cursor/extensions", "Cursor"),
        ("Windsurf", ".windsurf/extensions", "Windsurf"),
    ]
    static let cacheFolders = ["Cache", "CachedData", "CachedExtensionVSIXs", "Code Cache", "GPUCache", "logs"]

    var jetBrainsCaches: URL { home.appendingPathComponent("Library/Caches/JetBrains") }

    public func availability() async -> ProviderAvailability {
        let any = FS.exists(jetBrainsCaches) || EditorsProvider.codeEditors.contains {
            FS.exists(home.appendingPathComponent("Library/Application Support/\($0.0)"))
                || FS.exists(home.appendingPathComponent($0.1))
        }
        return any ? .available : .notInstalled
    }

    public func scan() async throws -> [CleanupItem] {
        var items: [CleanupItem] = []
        let home = self.home
        let id = self.id

        for (supportName, extensionsPath, display) in EditorsProvider.codeEditors {
            // Caches
            let support = home.appendingPathComponent("Library/Application Support/\(supportName)")
            for folder in EditorsProvider.cacheFolders {
                if var item = ProviderSupport.pathItem(support.appendingPathComponent(folder), providerID: id,
                                                       title: "\(display): \(folder)", home: home) {
                    item.tab = display
                    items.append(item)
                }
            }
            // Old extension versions
            let entries = FS.children(home.appendingPathComponent(extensionsPath))
                .filter { FS.isDirectory($0) }
                .compactMap { url -> Versioned.Entry? in
                    guard let (key, version) = Versioned.splitNameVersion(url.lastPathComponent) else { return nil }
                    return Versioned.Entry(url: url, key: key, version: version)
                }
            let keysWithSeveral = Set(Dictionary(grouping: entries, by: \.key).filter { $0.value.count > 1 }.keys)
            let extensionItems = await Versioned.items(
                entries.filter { keysWithSeveral.contains($0.key) }, providerID: id, home: home,
                title: { "\(display) extension \($0.key) \($0.version)" },
                newestNote: "Current version (kept)")
            // Only list older versions: the current one is in use.
            items += extensionItems.filter { $0.safety == .safe }.map { item in
                var item = item
                item.tab = display
                return item
            }
        }

        // JetBrains caches per product version, e.g. "IntelliJIdea2024.1"
        let jetBrains = FS.children(jetBrainsCaches).filter(FS.isDirectory).compactMap { url -> Versioned.Entry? in
            let name = url.lastPathComponent
            guard let range = name.range(of: #"\d{4}\.\d+$"#, options: .regularExpression) else { return nil }
            return Versioned.Entry(url: url, key: String(name[..<range.lowerBound]), version: String(name[range]))
        }
        items += await Versioned.items(jetBrains, providerID: id, home: home,
                                       title: { "JetBrains \($0.key) \($0.version) caches" })
            .map { item in
                var item = item
                item.tab = "JetBrains"
                return item
            }

        return items.sorted { $0.size > $1.size }
    }
}

// MARK: - Xcode extras

public struct XcodeExtrasProvider: CleanupProvider {
    public let id = "xcode-extras"
    public let title = "Xcode Extras"
    public let icon = "wrench.and.screwdriver"
    public let category = CleanupCategory.xcode
    public let note: String? = "SwiftUI preview data, simulator caches, and extra Xcode installs. Remove old Xcode versions yourself from Applications (they're outside your home folder)."
    public let relatedApps = ["com.apple.dt.Xcode"]
    let home: URL
    let applications: URL

    public init(home: URL = Paths.home, applications: URL = URL(fileURLWithPath: "/Applications")) {
        self.home = home
        self.applications = applications
    }

    var xcodeInstalls: [URL] {
        FS.children(applications).filter { $0.lastPathComponent.hasPrefix("Xcode") && $0.pathExtension == "app" }
    }

    public func availability() async -> ProviderAvailability {
        FS.exists(home.appendingPathComponent("Library/Developer")) || !xcodeInstalls.isEmpty ? .available : .notInstalled
    }

    public func scan() async throws -> [CleanupItem] {
        var items: [CleanupItem] = []
        let paths = [
            ("Library/Developer/Xcode/UserData/Previews", "SwiftUI Previews"),
            ("Library/Developer/CoreSimulator/Caches", "Simulator caches"),
            ("Library/Developer/XCPGDevices", "Playground simulators"),
        ]
        for (path, title) in paths {
            if let item = ProviderSupport.pathItem(home.appendingPathComponent(path), providerID: id, title: title, home: home) {
                items.append(item)
            }
        }

        // Other Xcode installs (not the active one). Manual: outside the home folder.
        let active = (try? await ShellRunner.run("xcode-select", ["-p"], timeout: 10))?.stdoutString
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let others = xcodeInstalls.filter { !active.hasPrefix($0.path + "/") }
        let id = self.id
        items += await others.concurrentMap { app -> CleanupItem? in
            let measured = SizeCalculator.measure(app)
            guard measured.size > 0 else { return nil }
            let version = (NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist"))?["CFBundleShortVersionString"] as? String)
            return CleanupItem(
                id: "\(id):\(app.path)", providerID: id,
                title: app.deletingPathExtension().lastPathComponent + (version.map { " (\($0))" } ?? ""),
                detail: app.path, url: app, size: measured.size, lastModified: measured.lastModified,
                safety: .review,
                action: .manual("Not the active Xcode. Drag it to the Trash in Finder if you don't need it"))
        }.compactMap { $0 }

        return items.sorted { $0.size > $1.size }
    }
}
