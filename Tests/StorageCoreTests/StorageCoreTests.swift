import Foundation
import Testing
@testable import StorageCore

/// Creates a throwaway fake home folder for each test.
final class TempHome {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("StorageCoreTests-\(UUID().uuidString)")
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: url) }

    @discardableResult
    func file(_ relative: String, bytes: Int = 10_000) throws -> URL {
        let target = url.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 0x41, count: bytes).write(to: target)
        return target
    }

    @discardableResult
    func dir(_ relative: String) throws -> URL {
        let target = url.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        return target
    }
}

func fixture(_ name: String) throws -> Data {
    let url = try #require(Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures"))
    return try Data(contentsOf: url)
}

@Suite struct SizeCalculatorTests {
    @Test func measuresNestedFiles() throws {
        let home = try TempHome()
        try home.file("a/one.bin", bytes: 100_000)
        try home.file("a/b/two.bin", bytes: 200_000)
        let result = SizeCalculator.measure(home.url.appendingPathComponent("a"))
        #expect(result.size >= 300_000)
        #expect(result.size < 400_000)
        #expect(result.unreadable == 0)
        #expect(result.lastModified != nil)
    }

    @Test func doesNotFollowSymlinks() throws {
        let home = try TempHome()
        try home.file("big/blob.bin", bytes: 1_000_000)
        try home.dir("small")
        try FileManager.default.createSymbolicLink(
            at: home.url.appendingPathComponent("small/link"),
            withDestinationURL: home.url.appendingPathComponent("big"))
        let result = SizeCalculator.measure(home.url.appendingPathComponent("small"))
        #expect(result.size < 100_000)
    }

    @Test func countsHardLinksOnce() throws {
        let home = try TempHome()
        let original = try home.file("h/original.bin", bytes: 1_000_000)
        try FileManager.default.linkItem(at: original, to: home.url.appendingPathComponent("h/copy.bin"))
        let result = SizeCalculator.measure(home.url.appendingPathComponent("h"))
        #expect(result.size < 1_500_000)
    }

    @Test func directoryScannerMeasuresChildren() async throws {
        let home = try TempHome()
        try home.file("root/x/file", bytes: 500_000)
        try home.file("root/y/file", bytes: 50_000)
        let children = await DirectoryScanner.children(of: home.url.appendingPathComponent("root"))
        #expect(children.count == 2)
        let x = try #require(children.first { $0.name == "x" })
        #expect(x.isDirectory)
        #expect(x.size >= 500_000)
    }
}

@Suite struct SafetyGuardTests {
    @Test func allowsCacheChildren() throws {
        let home = try TempHome()
        let guardian = SafetyGuard(home: home.url)
        try guardian.validate(home.url.appendingPathComponent("Library/Caches/com.example.app"))
        try guardian.validate(home.url.appendingPathComponent("Library/Developer/Xcode/DerivedData/App-abc"))
        try guardian.validate(home.url.appendingPathComponent("lab/project/node_modules"))
    }

    @Test(arguments: [
        "/", "/System", "/usr/lib", "/Applications/Safari.app", "/Library/Caches/x",
    ])
    func rejectsSystemPaths(_ path: String) throws {
        let home = try TempHome()
        #expect(throws: SafetyViolation.self) { try SafetyGuard(home: home.url).validate(URL(fileURLWithPath: path)) }
    }

    @Test(arguments: [
        "", "Library", "Library/Caches", "Documents", "Downloads", "Desktop", ".ssh/id_ed25519",
        "Library/Keychains/login.keychain-db", ".Trash/something", "Library/Mobile Documents/x",
    ])
    func rejectsProtectedHomePaths(_ relative: String) throws {
        let home = try TempHome()
        let url = relative.isEmpty ? home.url : home.url.appendingPathComponent(relative)
        #expect(throws: SafetyViolation.self) { try SafetyGuard(home: home.url).validate(url) }
    }

    @Test func rejectsDotDotEscapes() throws {
        let home = try TempHome()
        let url = URL(fileURLWithPath: home.url.path + "/Library/Caches/../../../../etc")
        #expect(throws: SafetyViolation.self) { try SafetyGuard(home: home.url).validate(url) }
    }

    @Test func rejectsSymlinkedParentEscapingHome() throws {
        let home = try TempHome()
        let outside = try TempHome()
        try outside.dir("victim")
        try FileManager.default.createSymbolicLink(
            at: home.url.appendingPathComponent("sneaky"), withDestinationURL: outside.url)
        let url = home.url.appendingPathComponent("sneaky/victim")
        #expect(throws: SafetyViolation.self) { try SafetyGuard(home: home.url).validate(url) }
    }

    @Test func symlinkItselfIsAllowedButOnlyTheLink() throws {
        let home = try TempHome()
        let outside = try TempHome()
        try home.dir("Library/Caches")
        try FileManager.default.createSymbolicLink(
            at: home.url.appendingPathComponent("Library/Caches/link"), withDestinationURL: outside.url)
        // The link lives in an allowed folder, so trashing the link is fine (target untouched).
        try SafetyGuard(home: home.url).validate(home.url.appendingPathComponent("Library/Caches/link"))
    }
}

@Suite struct ProviderTests {
    @Test func userCachesListsChildrenAndExcludesSpecificOnes() async throws {
        let home = try TempHome()
        try home.file("Library/Caches/com.example.app/data", bytes: 2_000_000)
        try home.file("Library/Caches/com.apple.Safari/data", bytes: 2_000_000)
        try home.file("Library/Caches/Homebrew/bottle", bytes: 2_000_000)
        try home.file("Library/Caches/tiny/data", bytes: 10)
        let items = try await UserCachesProvider(home: home.url).scan()
        #expect(Set(items.map(\.title)) == ["com.example.app", "com.apple.Safari"])
        #expect(items.first { $0.title == "com.apple.Safari" }?.safety == .caution)
        #expect(items.first { $0.title == "com.example.app" }?.safety == .safe)
    }

    @Test func derivedDataProjectName() {
        #expect(DerivedDataProvider.projectName(URL(fileURLWithPath: "/x/MyApp-abcdefghijklmnopqrstuvwxyzab")) == "MyApp")
        #expect(DerivedDataProvider.projectName(URL(fileURLWithPath: "/x/My-App-abcdefghijklmnopqrstuvwxyzab")) == "My-App")
        #expect(DerivedDataProvider.projectName(URL(fileURLWithPath: "/x/ModuleCache.noindex")) == "Module Cache")
        #expect(DerivedDataProvider.projectName(URL(fileURLWithPath: "/x/Plain")) == "Plain")
    }

    @Test func simulatorDevicesParse() throws {
        let list = try JSONDecoder().decode(SimctlDeviceList.self, from: fixture("simctl-devices.json"))
        let home = URL(fileURLWithPath: "/nonexistent-home")
        let items = list.devices.flatMap { runtime, devices in
            devices.map { SimulatorsProvider.item(for: $0, runtime: runtime, providerID: "sim", home: home) }
        }
        let unavailable = try #require(items.first { $0.detail == "AAAA" })
        #expect(unavailable.title == "iPhone 15 · iOS 17.2")
        #expect(unavailable.size == 2_147_483_648)
        #expect(unavailable.safety == .safe)
        #expect(unavailable.action == .command(ShellCommand("xcrun", ["simctl", "delete", "AAAA"])))
        let booted = try #require(items.first { $0.detail == "BBBB" })
        #expect(booted.safety == .caution)
        #expect(booted.note == "Currently booted")
    }

    @Test func simulatorRuntimesParseAndSkipUndeletable() throws {
        let items = try SimulatorRuntimesProvider.parse(fixture("simctl-runtimes.json"), providerID: "rt")
        #expect(items.count == 1)
        #expect(items[0].title == "iOS 17.2")
        #expect(items[0].size == 7_516_192_768)
        #expect(items[0].lastModified != nil)
    }

    @Test func dockerSizes() {
        #expect(DockerProvider.parseSize("1.5GB") == 1_500_000_000)
        #expect(DockerProvider.parseSize("120MB (98%)") == 120_000_000)
        #expect(DockerProvider.parseSize("12.3kB") == 12_300)
        #expect(DockerProvider.parseSize("0B") == 0)
        #expect(DockerProvider.parseSize("garbage") == 0)
    }

    @Test func dockerContainersGroupedByState() throws {
        let containers = DockerProvider.decodeLines(DockerContainerRow.self, from: try fixture("docker-ps.jsonl"))
        let items = DockerProvider.containerItems(containers, providerID: "docker")
        let running = try #require(items.first { $0.title == "db" })
        #expect(running.tab == "Containers" && running.usage?.label == "Running")
        #expect(running.safety == .caution)
        #expect(running.command == ShellCommand("docker", ["rm", "-f", "c1c1c1c1c1c1"]))
        let stopped = try #require(items.first { $0.title == "old-api" })
        #expect(stopped.tab == "Containers" && stopped.usage?.inUse == false)
        #expect(stopped.safety == .safe)
        #expect(stopped.size == 120_000_000)
    }

    @Test func dockerImagesMergeTagsAndDetectUsage() throws {
        let containers = DockerProvider.decodeLines(DockerContainerRow.self, from: try fixture("docker-ps.jsonl"))
        let images = DockerProvider.imageItems(from: try fixture("docker-images.jsonl"), containers: containers, providerID: "docker")
        // postgres:16 and postgres:latest are the same image: one row, not two.
        #expect(images.count == 3)
        #expect(Set(images.map(\.id)).count == images.count)

        let postgres = try #require(images.first { $0.detail.contains("aaa111") })
        #expect(postgres.title == "postgres:16, postgres:latest")
        #expect(postgres.tab == "Images" && postgres.usage == .used)
        #expect(postgres.note?.contains("db") == true)
        #expect(postgres.command == ShellCommand("docker", ["image", "rm", "postgres:16", "postgres:latest"]))

        // node:20 is used by a stopped container: still "in use" (docker refuses to remove it).
        let node = try #require(images.first { $0.title == "node:20" })
        #expect(node.usage == .used)

        let dangling = try #require(images.first { $0.title.hasPrefix("<untagged>") })
        #expect(dangling.usage == .unused)
        #expect(dangling.safety == .safe)
        #expect(dangling.command == ShellCommand("docker", ["image", "rm", "bbb222"]))
    }

    @Test func dockerVolumesFromVerboseDF() throws {
        let text = String(decoding: try fixture("docker-df-verbose.txt"), as: UTF8.self)
        let volumes = DockerProvider.parseVolumes(verboseDF: text)
        #expect(volumes == [
            DockerVolumeRow(name: "pgdata", links: 1, size: 512_000_000),
            DockerVolumeRow(name: "old_cache", links: 0, size: 1_500_000_000),
        ])
        let items = DockerProvider.volumeItems(volumes, providerID: "docker")
        #expect(items.first { $0.title == "pgdata" }?.usage == .used)
        #expect(items.first { $0.title == "old_cache" }?.usage == .unused)
    }

    @Test func dockerBuildCacheOnlyFromDF() throws {
        let items = DockerProvider.buildCacheItems(fromDF: try fixture("docker-df.jsonl"), providerID: "docker")
        #expect(items.isEmpty) // fixture has 0B build cache
    }

    @Test func cleanerRunsContainersBeforeImages() {
        let image = CleanupItem(id: "i", providerID: "docker", title: "img", size: 1,
                                action: .command(ShellCommand("docker", ["image", "rm", "x"])), groupOrder: 2)
        let container = CleanupItem(id: "c", providerID: "docker", title: "ctr", size: 1,
                                    action: .command(ShellCommand("docker", ["rm", "y"])), groupOrder: 0)
        let file = CleanupItem(id: "f", providerID: "caches", title: "f", size: 1, action: .trash([]))
        #expect(Cleaner.executionOrder([image, file, container]).map(\.id) == ["f", "c", "i"])
    }

    @Test func shellLineQuoting() {
        #expect(ShellCommand("docker", ["image", "rm", "postgres:16"]).shellLine == "docker image rm postgres:16")
        #expect(ShellCommand("/usr/bin/xcrun", ["simctl", "delete", "a b"]).shellLine == "xcrun simctl delete 'a b'")
        #expect(ShellCommand("echo", ["it's"]).shellLine == "echo 'it'\\''s'")
    }

    @Test func jenkinsKeepsNewestBuilds() async throws {
        let home = try TempHome()
        for build in 1...6 { try home.file(".jenkins/jobs/api/builds/\(build)/log", bytes: 50_000) }
        try home.file(".jenkins/jobs/folder/jobs/web/builds/1/log", bytes: 50_000)
        try home.file(".jenkins/workspace/api/src", bytes: 80_000)
        let provider = JenkinsProvider(home: home.url, environment: [:], keepLatestBuilds: 3)
        #expect(await provider.availability() == .available)
        let items = try await provider.scan()
        let api = try #require(items.first { $0.title.hasPrefix("api:") })
        guard case .trash(let urls) = api.action else { Issue.record("expected trash"); return }
        #expect(Set(urls.map(\.lastPathComponent)) == ["1", "2", "3"])
        #expect(items.contains { $0.title == "Workspace: api" })
        #expect(!items.contains { $0.title.hasPrefix("folder/web") }) // only 1 build, nothing to clean
    }

    @Test func jenkinsHiddenWhenMissing() async throws {
        let home = try TempHome()
        let provider = JenkinsProvider(home: home.url, environment: [:])
        // /Users/Shared/Jenkins may exist on some machines; only assert when it does not.
        if !FS.exists(URL(fileURLWithPath: "/Users/Shared/Jenkins/Home/jobs")) {
            #expect(await provider.availability() == .notInstalled)
        }
    }

    @Test func nodeModulesFinderSkipsNested() async throws {
        let home = try TempHome()
        try home.file("lab/app/node_modules/react/index.js", bytes: 100_000)
        try home.file("lab/app/node_modules/react/node_modules/x/index.js", bytes: 100_000)
        try home.file("lab/group/other/node_modules/y/index.js", bytes: 100_000)
        try home.file("lab/.hidden/node_modules/z/index.js", bytes: 100_000)
        let provider = NodeModulesProvider(home: home.url, roots: [home.url.appendingPathComponent("lab")])
        let items = try await provider.scan()
        #expect(Set(items.map(\.title)) == ["app", "other"])
        #expect(items.allSatisfy { $0.safety == .caution }) // freshly modified
    }

    @Test func downloadsOnlyLargeOrOld() async throws {
        let home = try TempHome()
        try home.file("Downloads/big.dmg", bytes: 2_000_000)
        try home.file("Downloads/small.pdf", bytes: 1_000)
        let old = try home.file("Downloads/old.zip", bytes: 1_100_000)
        let oldTiny = try home.file("Downloads/old-tiny.txt", bytes: 1_000)
        for url in [old, oldTiny] {
            try FileManager.default.setAttributes(
                [.modificationDate: Date().addingTimeInterval(-200 * 86_400)], ofItemAtPath: url.path)
        }
        let items = try await DownloadsProvider(home: home.url, largeThreshold: 1_500_000).scan()
        #expect(Set(items.map(\.title)) == ["big.dmg", "old.zip"])
        #expect(items.allSatisfy { $0.safety == .review })
    }
}

@Suite struct CleanerTests {
    @Test func trashesAllowedItemAndRefusesProtected() async throws {
        let home = try TempHome()
        let target = try home.file("Library/Caches/com.example.app/data", bytes: 1_000)
        let cacheDir = target.deletingLastPathComponent()
        let logDir = home.url.appendingPathComponent("Library/Logs/StorageHelper")
        let cleaner = Cleaner(safety: SafetyGuard(home: home.url), log: CleanupLog(directory: logDir), home: home.url,
                              moveToTrash: { try FileManager.default.removeItem(at: $0) })

        let good = CleanupItem(id: "1", providerID: "test", title: "ok", size: 1_000, action: .trash([cacheDir]))
        let bad = CleanupItem(id: "2", providerID: "test", title: "bad", size: 1, action: .trash([home.url.appendingPathComponent("Documents")]))
        let report = await cleaner.clean([good, bad], emptyTrashAfter: false)

        #expect(report.succeeded.map(\.item.id) == ["1"])
        #expect(report.failed.map(\.item.id) == ["2"])
        #expect(!FS.exists(cacheDir))
        let log = try String(contentsOf: logDir.appendingPathComponent("cleanup.log"), encoding: .utf8)
        #expect(log.contains("FAILED"))
        #expect(log.contains("| OK"))
    }

    @Test func emptyTrashOnlyDeletesInsideTrash() async throws {
        let home = try TempHome()
        try home.file(".Trash/old.bin", bytes: 1_000)
        try home.file(".Trash/folder/inner.bin", bytes: 1_000)
        let keep = try home.file("keep.txt", bytes: 10)
        let trash = home.url.appendingPathComponent(".Trash")
        let cleaner = Cleaner(safety: SafetyGuard(home: home.url),
                              log: CleanupLog(directory: home.url.appendingPathComponent("logs")), home: home.url)
        let item = CleanupItem(id: "t", providerID: "trash", title: "Trash", size: 2_000, action: .emptyTrash(trash))
        let report = await cleaner.clean([item], emptyTrashAfter: false)
        #expect(report.failed.isEmpty)
        #expect(FS.children(trash).isEmpty)
        #expect(FS.exists(trash))
        #expect(FS.exists(keep))
    }
}

@Suite struct HiddenSpaceTests {
    @Test func parsesLocalSnapshots() {
        let text = """
        Snapshots for disk /:
        com.apple.TimeMachine.2025-01-10-101010.local
        com.apple.TimeMachine.2025-01-09-090000.local
        """
        let items = TimeMachineSnapshotsProvider.parse(text, providerID: "tm")
        #expect(items.count == 2)
        #expect(items[0].detail == "com.apple.TimeMachine.2025-01-09-090000.local") // oldest first
        #expect(items[0].command == ShellCommand("tmutil", ["deletelocalsnapshots", "2025-01-09-090000"]))
        #expect(items[0].lastModified != nil)
    }

    @Test func readsDeviceBackupInfo() async throws {
        let home = try TempHome()
        let backup = try home.dir("Library/Application Support/MobileSync/Backup/00008110-ABC")
        try home.file("Library/Application Support/MobileSync/Backup/00008110-ABC/blob", bytes: 500_000)
        let plist: [String: Any] = ["Device Name": "Gustavo's iPhone", "Product Name": "iPhone 15", "Product Version": "18.1",
                                    "Last Backup Date": Date(timeIntervalSince1970: 1_700_000_000)]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            .write(to: backup.appendingPathComponent("Info.plist"))

        let items = try await DeviceBackupsProvider(home: home.url).scan()
        let item = try #require(items.first)
        #expect(item.title == "Gustavo's iPhone")
        #expect(item.detail.hasPrefix("iPhone 15 iOS 18.1"))
        #expect(item.safety == .review)
        #expect(item.lastModified == Date(timeIntervalSince1970: 1_700_000_000))
        try SafetyGuard(home: home.url).validate(backup) // backups are deletable
    }

    @Test func manualItemsAreNeverCleaned() async throws {
        let home = try TempHome()
        let attachments = try home.file("Library/Messages/Attachments/a/photo.heic", bytes: 2_000_000)
        let items = try await MailMessagesProvider(home: home.url).scan()
        let item = try #require(items.first)
        #expect(!item.action.isActionable)

        let cleaner = Cleaner(safety: SafetyGuard(home: home.url),
                              log: CleanupLog(directory: home.url.appendingPathComponent("logs")), home: home.url,
                              moveToTrash: { try FileManager.default.removeItem(at: $0) })
        let report = await cleaner.clean([item], emptyTrashAfter: false)
        #expect(report.failed.count == 1)
        #expect(FS.exists(attachments))
    }
}
