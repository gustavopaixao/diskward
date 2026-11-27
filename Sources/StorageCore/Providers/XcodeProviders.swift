import Foundation

private let xcodeBundleID = "com.apple.dt.Xcode"
private let simulatorBundleID = "com.apple.iphonesimulator"

public struct DerivedDataProvider: CleanupProvider {
    public let id = "derived-data"
    public let title = "DerivedData"
    public let icon = "hammer"
    public let category = CleanupCategory.xcode
    public let note: String? = "Build products and indexes. Xcode rebuilds them on the next build."
    public let relatedApps = [xcodeBundleID]
    let home: URL

    public init(home: URL = Paths.home) { self.home = home }

    var directory: URL { home.appendingPathComponent("Library/Developer/Xcode/DerivedData") }

    public func availability() async -> ProviderAvailability {
        FS.exists(directory) ? .available : .notInstalled
    }

    public func scan() async throws -> [CleanupItem] {
        await ProviderSupport.childItems(
            of: directory, providerID: id, home: home,
            title: DerivedDataProvider.projectName
        )
    }

    /// "MyApp-abcdefghijklmnopqrstuvwxyzab" → "MyApp"
    static func projectName(_ url: URL) -> String {
        let name = url.lastPathComponent
        if name == "ModuleCache.noindex" { return "Module Cache" }
        if let dash = name.lastIndex(of: "-") {
            let suffix = name[name.index(after: dash)...]
            if suffix.count == 28, suffix.allSatisfy({ $0.isLetter && $0.isLowercase }) {
                return String(name[..<dash])
            }
        }
        return name
    }
}

public struct ArchivesProvider: CleanupProvider {
    public let id = "archives"
    public let title = "Archives"
    public let icon = "archivebox.fill"
    public let category = CleanupCategory.xcode
    public let note: String? = "Archives keep the dSYMs you need to symbolicate crash reports for shipped builds. Keep the ones for live releases."
    let home: URL

    public init(home: URL = Paths.home) { self.home = home }

    var directory: URL { home.appendingPathComponent("Library/Developer/Xcode/Archives") }

    public func availability() async -> ProviderAvailability {
        FS.exists(directory) ? .available : .notInstalled
    }

    public func scan() async throws -> [CleanupItem] {
        let archives = FS.children(directory)
            .flatMap { FS.children($0) }
            .filter { $0.pathExtension == "xcarchive" }
        let home = self.home
        let id = self.id
        let items = await archives.concurrentMap { url -> CleanupItem? in
            guard var item = ProviderSupport.pathItem(
                url, providerID: id, title: url.deletingPathExtension().lastPathComponent,
                home: home, safety: .caution
            ) else { return nil }
            item.detail = url.deletingLastPathComponent().lastPathComponent // date folder
            return item
        }
        return items.compactMap { $0 }.sorted { $0.size > $1.size }
    }
}

public struct DeviceSupportProvider: CleanupProvider {
    public let id = "device-support"
    public let title = "Device Support"
    public let icon = "iphone"
    public let category = CleanupCategory.xcode
    public let note: String? = "Debug symbols copied from devices you've connected. Xcode copies them again when a device is plugged in."
    let home: URL

    public init(home: URL = Paths.home) { self.home = home }

    var base: URL { home.appendingPathComponent("Library/Developer/Xcode") }

    var folders: [URL] {
        FS.children(base).filter { $0.lastPathComponent.hasSuffix("DeviceSupport") }
    }

    public func availability() async -> ProviderAvailability {
        folders.isEmpty ? .notInstalled : .available
    }

    public func scan() async throws -> [CleanupItem] {
        var all: [CleanupItem] = []
        for folder in folders {
            let platform = folder.lastPathComponent.replacingOccurrences(of: " DeviceSupport", with: "")
            all += await ProviderSupport.childItems(
                of: folder, providerID: id, home: home,
                title: { "\(platform) \($0.lastPathComponent)" }
            )
        }
        return all.sorted { $0.size > $1.size }
    }
}

// MARK: - Simulators (via simctl)

struct SimctlDeviceList: Decodable {
    struct Device: Decodable {
        let udid: String
        let name: String
        let state: String?
        let isAvailable: Bool?
        let availabilityError: String?
        let dataPath: String?
        let dataPathSize: Int64?
        let lastBootedAt: String?
    }
    let devices: [String: [Device]]
}

public struct SimulatorsProvider: CleanupProvider {
    public let id = "simulators"
    public let title = "Simulators"
    public let icon = "ipad.and.iphone"
    public let category = CleanupCategory.xcode
    public let note: String? = "Deleting a simulator removes its apps and data. Unavailable simulators (no matching runtime) are pre-selected."
    public let relatedApps = [simulatorBundleID]
    let home: URL

    public init(home: URL = Paths.home) { self.home = home }

    public func availability() async -> ProviderAvailability {
        let devices = home.appendingPathComponent("Library/Developer/CoreSimulator/Devices")
        guard FS.exists(devices), ShellRunner.which("xcrun") != nil else { return .notInstalled }
        return .available
    }

    public func scan() async throws -> [CleanupItem] {
        let output = try await ShellRunner.run("xcrun", ["simctl", "list", "devices", "-j"], timeout: 60)
        guard output.succeeded else { throw ProviderError("simctl failed: \(output.stderr.prefix(300))") }
        let list = try JSONDecoder().decode(SimctlDeviceList.self, from: output.stdout)
        let home = self.home
        let id = self.id

        let entries = list.devices.flatMap { runtime, devices in devices.map { (runtime, $0) } }
        let items = await entries.concurrentMap { runtime, device in
            SimulatorsProvider.item(for: device, runtime: runtime, providerID: id, home: home)
        }
        return items.sorted { $0.size > $1.size }
    }

    static func item(for device: SimctlDeviceList.Device, runtime: String, providerID: String, home: URL) -> CleanupItem {
        let deviceDir = home.appendingPathComponent("Library/Developer/CoreSimulator/Devices/\(device.udid)")
        let size = device.dataPathSize ?? SizeCalculator.measure(deviceDir).size
        let available = device.isAvailable ?? true
        let booted = device.state == "Booted"
        var note: String?
        if !available { note = device.availabilityError ?? "Unavailable: runtime missing" }
        if booted { note = "Currently booted" }

        return CleanupItem(
            id: "\(providerID):\(device.udid)",
            providerID: providerID,
            title: "\(device.name) · \(runtimeDisplayName(runtime))",
            detail: device.udid,
            url: FS.exists(deviceDir) ? deviceDir : nil,
            size: size,
            lastModified: device.lastBootedAt.flatMap(parseDate),
            safety: (!available && !booted) ? .safe : .caution,
            action: .command(ShellCommand("xcrun", ["simctl", "delete", device.udid])),
            note: note
        )
    }

    /// "com.apple.CoreSimulator.SimRuntime.iOS-17-2" → "iOS 17.2"
    static func runtimeDisplayName(_ identifier: String) -> String {
        guard let last = identifier.split(separator: ".").last else { return identifier }
        var parts = last.split(separator: "-").map(String.init)
        guard parts.count >= 2 else { return String(last) }
        let platform = parts.removeFirst()
        return "\(platform) \(parts.joined(separator: "."))"
    }
}

// MARK: - Simulator runtimes

struct SimctlRuntime: Decodable {
    let identifier: String
    let version: String?
    let build: String?
    let platformIdentifier: String?
    let runtimeIdentifier: String?
    let sizeBytes: Int64?
    let deletable: Bool?
    let state: String?
    let lastUsedAt: String?
}

public struct SimulatorRuntimesProvider: CleanupProvider {
    public let id = "sim-runtimes"
    public let title = "Simulator Runtimes"
    public let icon = "cpu"
    public let category = CleanupCategory.xcode
    public let note: String? = "Each runtime is several GB. Delete the iOS/watchOS versions you no longer test on. They can be downloaded again from Xcode > Settings > Components."
    public let relatedApps = [xcodeBundleID, simulatorBundleID]

    public init() {}

    public func availability() async -> ProviderAvailability {
        ShellRunner.which("xcrun") != nil && FS.exists(URL(fileURLWithPath: "/Library/Developer/CoreSimulator"))
            ? .available : .notInstalled
    }

    public func scan() async throws -> [CleanupItem] {
        let output = try await ShellRunner.run("xcrun", ["simctl", "runtime", "list", "-j"], timeout: 60)
        guard output.succeeded else { throw ProviderError("simctl runtime list failed: \(output.stderr.prefix(300))") }
        return try SimulatorRuntimesProvider.parse(output.stdout, providerID: id)
    }

    static func parse(_ data: Data, providerID: String) throws -> [CleanupItem] {
        let runtimes = try JSONDecoder().decode([String: SimctlRuntime].self, from: data)
        return runtimes.values
            .filter { $0.deletable ?? true }
            .map { runtime in
                let platform = runtime.runtimeIdentifier.map(SimulatorsProvider.runtimeDisplayName)
                    ?? runtime.platformIdentifier ?? "Runtime"
                return CleanupItem(
                    id: "\(providerID):\(runtime.identifier)",
                    providerID: providerID,
                    title: platform,
                    detail: [runtime.version, runtime.build.map { "(\($0))" }, runtime.state]
                        .compactMap { $0 }.joined(separator: " "),
                    size: runtime.sizeBytes ?? 0,
                    lastModified: runtime.lastUsedAt.flatMap(parseDate),
                    safety: .caution,
                    action: .command(ShellCommand("xcrun", ["simctl", "runtime", "delete", runtime.identifier]))
                )
            }
            .sorted { $0.size > $1.size }
    }
}

func parseDate(_ string: String) -> Date? {
    let formatter = ISO8601DateFormatter()
    if let date = formatter.date(from: string) { return date }
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.date(from: string)
}
