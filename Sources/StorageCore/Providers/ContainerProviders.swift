import Foundation

// MARK: - Docker

/// One line of `docker system df --format json`.
struct DockerDFRow: Decodable {
    let type: String
    let totalCount: String?
    let active: String?
    let size: String?
    let reclaimable: String?

    enum CodingKeys: String, CodingKey {
        case type = "Type", totalCount = "TotalCount", active = "Active", size = "Size", reclaimable = "Reclaimable"
    }
}

/// One line of `docker image ls --format json`.
struct DockerImageRow: Decodable {
    let id: String
    let repository: String
    let tag: String
    let size: String
    let createdSince: String?
    let createdAt: String?

    enum CodingKeys: String, CodingKey {
        case id = "ID", repository = "Repository", tag = "Tag", size = "Size",
             createdSince = "CreatedSince", createdAt = "CreatedAt"
    }
}

public struct DockerProvider: CleanupProvider {
    public let id = "docker"
    public let title = "Docker"
    public let icon = "shippingbox.fill"
    public let category = CleanupCategory.containers
    public let note: String? = "Docker Desktop keeps everything in one disk image (Docker.raw). After pruning, that file may take a while to shrink, so the change in free space can lag."
    public let relatedApps: [String] = []

    public init() {}

    public func availability() async -> ProviderAvailability {
        guard ShellRunner.which("docker") != nil else { return .notInstalled }
        guard let info = try? await ShellRunner.run("docker", ["info", "--format", "{{.ServerVersion}}"], timeout: 10),
              info.succeeded
        else { return .unavailable("Docker is installed but not running. Start Docker Desktop to scan it.") }
        return .available
    }

    public func scan() async throws -> [CleanupItem] {
        async let dfOutput = ShellRunner.run("docker", ["system", "df", "--format", "json"], timeout: 60)
        async let imagesOutput = ShellRunner.run("docker", ["image", "ls", "--format", "json"], timeout: 60)
        async let usedOutput = ShellRunner.run("docker", ["ps", "-a", "--format", "{{.Image}}"], timeout: 60)

        let df = try await dfOutput
        guard df.succeeded else { throw ProviderError("docker system df failed: \(df.stderr.prefix(300))") }
        var items = DockerProvider.summaryItems(fromDF: df.stdout, providerID: id)

        let images = try await imagesOutput
        let used = (try? await usedOutput)?.stdoutString ?? ""
        let usedImages = Set(used.split(separator: "\n").map(String.init))
        if images.succeeded {
            items += DockerProvider.imageItems(from: images.stdout, usedBy: usedImages, providerID: id)
        }
        return items.sorted { $0.size > $1.size }
    }

    static func decodeLines<T: Decodable>(_ type: T.Type, from data: Data) -> [T] {
        let decoder = JSONDecoder()
        return String(decoding: data, as: UTF8.self)
            .split(separator: "\n")
            .compactMap { try? decoder.decode(T.self, from: Data($0.utf8)) }
    }

    /// Aggregate items: stopped containers, unused volumes, build cache.
    static func summaryItems(fromDF data: Data, providerID: String) -> [CleanupItem] {
        let docker = "docker"
        return decodeLines(DockerDFRow.self, from: data).compactMap { row in
            let reclaimable = parseSize(row.reclaimable ?? "0B")
            guard reclaimable > 0 else { return nil }
            let counts = "\(row.totalCount ?? "?") total, \(row.active ?? "?") in use"
            switch row.type {
            case "Containers":
                return CleanupItem(
                    id: "\(providerID):containers", providerID: providerID,
                    title: "Stopped containers", detail: counts, size: reclaimable,
                    safety: .safe, action: .command(ShellCommand(docker, ["container", "prune", "-f"])))
            case "Local Volumes":
                return CleanupItem(
                    id: "\(providerID):volumes", providerID: providerID,
                    title: "Unused volumes", detail: counts, size: reclaimable,
                    safety: .caution, action: .command(ShellCommand(docker, ["volume", "prune", "-a", "-f"])),
                    note: "Volumes can hold databases and other data. Only unused volumes are removed.")
            case "Build Cache":
                return CleanupItem(
                    id: "\(providerID):build-cache", providerID: providerID,
                    title: "Build cache", detail: counts, size: reclaimable,
                    safety: .safe, action: .command(ShellCommand(docker, ["builder", "prune", "-a", "-f"])))
            default:
                return nil // images are listed one by one
            }
        }
    }

    static func imageItems(from data: Data, usedBy usedImages: Set<String>, providerID: String) -> [CleanupItem] {
        decodeLines(DockerImageRow.self, from: data).map { image in
            let name = image.repository == "<none>" ? "<untagged>" : "\(image.repository):\(image.tag)"
            let dangling = image.repository == "<none>"
            let inUse = usedImages.contains(name) || usedImages.contains(image.repository)
                || usedImages.contains { $0.hasPrefix(image.id) }
            return CleanupItem(
                id: "\(providerID):image:\(image.id)",
                providerID: providerID,
                title: name,
                detail: "Image \(image.id)" + (image.createdSince.map { " · created \($0)" } ?? ""),
                size: parseSize(image.size),
                safety: dangling && !inUse ? .safe : .caution,
                action: .command(ShellCommand("docker", ["image", "rm", image.id])),
                note: inUse ? "Used by a container (remove the container first)" : (dangling ? "Dangling image" : nil)
            )
        }
    }

    /// Parses Docker's sizes like "1.2GB", "512MB", "12.3kB", "0B", "1.2GB (50%)". Docker uses SI units.
    static func parseSize(_ text: String) -> Int64 {
        let token = text.split(separator: " ").first.map(String.init) ?? text
        let units: [(String, Double)] = [("TB", 1e12), ("GB", 1e9), ("MB", 1e6), ("kB", 1e3), ("KB", 1e3), ("B", 1)]
        for (suffix, multiplier) in units where token.hasSuffix(suffix) {
            let number = Double(token.dropLast(suffix.count)) ?? 0
            return Int64(number * multiplier)
        }
        return 0
    }
}

// MARK: - Jenkins

public struct JenkinsProvider: CleanupProvider {
    public let id = "jenkins"
    public let title = "Jenkins"
    public let icon = "gearshape.2"
    public let category = CleanupCategory.containers
    public let note: String?
    let home: URL
    let candidates: [URL]
    let keepLatestBuilds: Int

    public init(home: URL = Paths.home, environment: [String: String] = ProcessInfo.processInfo.environment, keepLatestBuilds: Int = 3) {
        self.home = home
        self.keepLatestBuilds = keepLatestBuilds
        var candidates: [URL] = []
        if let env = environment["JENKINS_HOME"] { candidates.append(URL(fileURLWithPath: env)) }
        candidates.append(home.appendingPathComponent(".jenkins"))
        candidates.append(URL(fileURLWithPath: "/Users/Shared/Jenkins/Home"))
        self.candidates = candidates
        self.note = "Workspaces are checked out again on the next build. For each job, old builds are listed and the newest \(keepLatestBuilds) are kept. Stop Jenkins before cleaning."
    }

    var jenkinsHome: URL? {
        candidates.first { FS.exists($0.appendingPathComponent("jobs")) }
    }

    public func availability() async -> ProviderAvailability {
        jenkinsHome == nil ? .notInstalled : .available
    }

    public func scan() async throws -> [CleanupItem] {
        guard let jenkins = jenkinsHome else { return [] }
        var items: [CleanupItem] = []

        // Workspaces
        items += await ProviderSupport.childItems(
            of: jenkins.appendingPathComponent("workspace"), providerID: id, home: home,
            filter: { FS.isDirectory($0) }, // skip Jenkins' own index files like workspaces.txt
            title: { "Workspace: \($0.lastPathComponent)" },
            safety: { _ in .caution }
        )

        // Old builds per job (supports folder plugin: jobs/<folder>/jobs/<job>)
        for job in JenkinsProvider.jobs(in: jenkins.appendingPathComponent("jobs")) {
            if let item = oldBuildsItem(for: job.url, name: job.name) { items.append(item) }
        }
        return items.sorted { $0.size > $1.size }
    }

    static func jobs(in jobsDir: URL, prefix: String = "", depth: Int = 0) -> [(name: String, url: URL)] {
        guard depth < 4 else { return [] }
        var result: [(String, URL)] = []
        for job in FS.children(jobsDir) where FS.isDirectory(job) {
            let name = prefix + job.lastPathComponent
            if FS.exists(job.appendingPathComponent("builds")) { result.append((name, job)) }
            let nested = job.appendingPathComponent("jobs")
            if FS.exists(nested) { result += jobs(in: nested, prefix: name + "/", depth: depth + 1) }
        }
        return result
    }

    func oldBuildsItem(for job: URL, name: String) -> CleanupItem? {
        let builds = FS.children(job.appendingPathComponent("builds"))
            .filter { Int($0.lastPathComponent) != nil && FS.isDirectory($0) }
            .sorted { Int($0.lastPathComponent)! > Int($1.lastPathComponent)! }
        let old = Array(builds.dropFirst(keepLatestBuilds))
        guard !old.isEmpty else { return nil }
        let measured = old.map { SizeCalculator.measure($0) }
        let size = measured.reduce(0) { $0 + $1.size }
        guard size > 0 else { return nil }
        return CleanupItem(
            id: "\(id):builds:\(job.path)",
            providerID: id,
            title: "\(name): \(old.count) old build\(old.count == 1 ? "" : "s")",
            detail: "Builds #\(old.last!.lastPathComponent)–#\(old.first!.lastPathComponent), keeping the newest \(keepLatestBuilds)",
            url: job.appendingPathComponent("builds"),
            size: size,
            lastModified: measured.compactMap(\.lastModified).max(),
            safety: .caution,
            action: .trash(old)
        )
    }
}
