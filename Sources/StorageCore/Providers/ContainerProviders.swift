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

    enum CodingKeys: String, CodingKey {
        case id = "ID", repository = "Repository", tag = "Tag", size = "Size", createdSince = "CreatedSince"
    }
}

/// One line of `docker ps -a --size --format json`.
struct DockerContainerRow: Decodable {
    let id: String
    let image: String
    let names: String
    let state: String?
    let status: String?
    let size: String?
    let runningFor: String?

    enum CodingKeys: String, CodingKey {
        case id = "ID", image = "Image", names = "Names", state = "State", status = "Status",
             size = "Size", runningFor = "RunningFor"
    }

    var isRunning: Bool {
        if let state { return state == "running" || state == "restarting" || state == "paused" }
        return status?.hasPrefix("Up") ?? false
    }
}

struct DockerVolumeRow: Equatable {
    let name: String
    let links: Int
    let size: Int64
}

public struct DockerProvider: CleanupProvider {
    public let id = "docker"
    public let title = "Docker"
    public let icon = "shippingbox.fill"
    public let category = CleanupCategory.containers
    public let note: String? = "Docker Desktop keeps everything in one disk image (Docker.raw). After cleaning, that file may take a while to shrink, so the change in free space can lag. Image sizes include layers shared with other images."
    public let relatedApps: [String] = []

    /// Tabs in display order. The same order is used when running commands,
    /// so containers are removed before the images and volumes they use.
    enum Tab: Int {
        case containers, images, volumes, buildCache

        var title: String {
            switch self {
            case .containers: "Containers"
            case .images: "Images"
            case .volumes: "Volumes"
            case .buildCache: "Build Cache"
            }
        }
    }

    public init() {}

    public func availability() async -> ProviderAvailability {
        guard ShellRunner.which("docker") != nil else { return .notInstalled }
        guard let info = try? await ShellRunner.run("docker", ["info", "--format", "{{.ServerVersion}}"], timeout: 10),
              info.succeeded
        else { return .unavailable("Docker is installed but not running. Start Docker Desktop to scan it.") }
        return .available
    }

    public func scan() async throws -> [CleanupItem] {
        async let containersOut = ShellRunner.run("docker", ["ps", "-a", "--size", "--format", "json"], timeout: 120)
        async let imagesOut = ShellRunner.run("docker", ["image", "ls", "--format", "json"], timeout: 60)
        async let verboseDFOut = ShellRunner.run("docker", ["system", "df", "-v"], timeout: 180)
        async let dfOut = ShellRunner.run("docker", ["system", "df", "--format", "json"], timeout: 60)

        let containersResult = try await containersOut
        guard containersResult.succeeded else {
            throw ProviderError("docker ps failed: \(containersResult.stderr.prefix(300))")
        }
        let containers = DockerProvider.decodeLines(DockerContainerRow.self, from: containersResult.stdout)

        var items = DockerProvider.containerItems(containers, providerID: id)
        let verbose = (try? await verboseDFOut).flatMap { $0.succeeded ? $0.stdoutString : nil } ?? ""
        if let images = try? await imagesOut, images.succeeded {
            items += DockerProvider.imageItems(
                from: images.stdout, containers: containers,
                uniqueSizes: DockerProvider.parseImageUniqueSizes(verboseDF: verbose), providerID: id)
        }
        items += DockerProvider.volumeItems(DockerProvider.parseVolumes(verboseDF: verbose), providerID: id)
        if let df = try? await dfOut, df.succeeded {
            items += DockerProvider.buildCacheItems(fromDF: df.stdout, providerID: id)
        }
        return items.sorted { ($0.groupOrder, -$0.size) < ($1.groupOrder, -$1.size) }
    }

    // MARK: Parsing (static so they can be tested with fixtures)

    static func decodeLines<T: Decodable>(_ type: T.Type, from data: Data) -> [T] {
        let decoder = JSONDecoder()
        return String(decoding: data, as: UTF8.self)
            .split(separator: "\n")
            .compactMap { try? decoder.decode(T.self, from: Data($0.utf8)) }
    }

    static func containerItems(_ containers: [DockerContainerRow], providerID: String) -> [CleanupItem] {
        containers.map { container in
            let running = container.isRunning
            return CleanupItem(
                id: "\(providerID):container:\(container.id)",
                providerID: providerID,
                title: container.names,
                detail: "\(container.image) · \(container.status ?? container.state ?? "")",
                size: parseSize(container.size ?? "0B"),
                safety: running ? .caution : .safe,
                action: .command(ShellCommand("docker", running ? ["rm", "-f", container.id] : ["rm", container.id])),
                note: running ? "Running: it will be stopped and removed" : nil,
                tab: Tab.containers.title,
                usage: running ? Usage(inUse: true, label: "Running") : Usage(inUse: false, label: "Stopped"),
                groupOrder: Tab.containers.rawValue
            )
        }
    }

    /// `docker image ls` prints one line per *tag*, so an image tagged twice appears twice.
    /// Lines are merged by image ID: one row per image, listing all of its tags.
    /// - Parameter uniqueSizes: image ID → bytes only this image uses (what removing it frees).
    ///   Without it, the full image size is used, which counts shared layers more than once.
    static func imageItems(
        from data: Data, containers: [DockerContainerRow],
        uniqueSizes: [String: Int64] = [:], providerID: String
    ) -> [CleanupItem] {
        var order: [String] = []
        var byID: [String: [DockerImageRow]] = [:]
        for row in decodeLines(DockerImageRow.self, from: data) {
            if byID[row.id] == nil { order.append(row.id) }
            byID[row.id, default: []].append(row)
        }

        return order.compactMap { imageID -> CleanupItem? in
            guard let rows = byID[imageID], let first = rows.first else { return nil }
            let tags = rows.filter { $0.repository != "<none>" }.map { "\($0.repository):\($0.tag)" }
            let dangling = tags.isEmpty
            let users = containers.filter { container in rows.contains { uses(container.image, image: $0) } }
            let inUse = !users.isEmpty

            let note: String?
            if inUse {
                let names = users.prefix(3).map(\.names).joined(separator: ", ")
                note = "Used by \(names)\(users.count > 3 ? " +\(users.count - 3)" : ""). Remove those containers first."
            } else if dangling {
                note = "Dangling (untagged) image"
            } else if tags.count > 1 {
                note = "\(tags.count) tags point to this image"
            } else {
                note = nil
            }

            // Removing every tag removes the image. Untagged images are removed by ID.
            let arguments = ["image", "rm"] + (dangling ? [imageID] : tags)
            return CleanupItem(
                id: "\(providerID):image:\(imageID)",
                providerID: providerID,
                title: dangling ? "<untagged> \(imageID)" : tags.joined(separator: ", "),
                detail: "Image \(imageID) · \(first.size) total" + (first.createdSince.map { " · created \($0)" } ?? ""),
                size: uniqueSizes[imageID] ?? parseSize(first.size),
                safety: dangling && !inUse ? .safe : .caution,
                action: .command(ShellCommand("docker", arguments)),
                note: note,
                tab: Tab.images.title,
                usage: inUse ? .used : .unused,
                groupOrder: Tab.images.rawValue
            )
        }
    }

    /// A container's `Image` can be "name:tag", "name" (meaning :latest) or an image ID prefix.
    static func uses(_ containerImage: String, image: DockerImageRow) -> Bool {
        if image.repository != "<none>" {
            if containerImage == "\(image.repository):\(image.tag)" { return true }
            if image.tag == "latest", containerImage == image.repository { return true }
        }
        let shortID = image.id.replacingOccurrences(of: "sha256:", with: "")
        let reference = containerImage.replacingOccurrences(of: "sha256:", with: "")
        return reference.count >= 12 && (shortID.hasPrefix(reference) || reference.hasPrefix(shortID))
    }

    static func volumeItems(_ volumes: [DockerVolumeRow], providerID: String) -> [CleanupItem] {
        volumes.map { volume in
            let inUse = volume.links > 0
            return CleanupItem(
                id: "\(providerID):volume:\(volume.name)",
                providerID: providerID,
                title: volume.name,
                detail: inUse ? "Used by \(volume.links) container\(volume.links == 1 ? "" : "s")" : "Not used by any container",
                size: volume.size,
                safety: .caution,
                action: .command(ShellCommand("docker", ["volume", "rm", volume.name])),
                note: inUse ? "In use: remove the container first" : "May hold data (databases, uploads)",
                tab: Tab.volumes.title,
                usage: inUse ? .used : .unused,
                groupOrder: Tab.volumes.rawValue
            )
        }
    }

    /// Reads UNIQUE SIZE per image ID from the "Images space usage" table of `docker system df -v`.
    /// Columns: REPOSITORY TAG IMAGE ID CREATED(several words) SIZE SHARED UNIQUE CONTAINERS,
    /// so the ID is the 3rd token and sizes are counted from the end.
    static func parseImageUniqueSizes(verboseDF text: String) -> [String: Int64] {
        var sizes: [String: Int64] = [:]
        var inSection = false
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("Images space usage") { inSection = true; continue }
            guard inSection else { continue }
            if trimmed.hasPrefix("REPOSITORY") || (trimmed.isEmpty && sizes.isEmpty) { continue }
            if trimmed.isEmpty || trimmed.hasSuffix("space usage:") { break }
            let parts = trimmed.split(whereSeparator: \.isWhitespace).map(String.init)
            guard parts.count >= 8 else { continue }
            sizes[parts[2]] = parseSize(parts[parts.count - 2])
        }
        return sizes
    }

    /// Reads the "Local Volumes space usage" table from `docker system df -v`.
    /// (The verbose JSON output differs between Docker versions; this table has been stable for years.)
    static func parseVolumes(verboseDF text: String) -> [DockerVolumeRow] {
        var rows: [DockerVolumeRow] = []
        var inSection = false
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("Local Volumes space usage") { inSection = true; continue }
            guard inSection else { continue }
            if trimmed.hasPrefix("VOLUME NAME") || (trimmed.isEmpty && rows.isEmpty) { continue }
            if trimmed.isEmpty || trimmed.hasSuffix("space usage:") { break }
            let parts = trimmed.split(whereSeparator: \.isWhitespace)
            guard parts.count >= 3, let links = Int(parts[1]) else { continue }
            rows.append(DockerVolumeRow(name: String(parts[0]), links: links, size: parseSize(String(parts[2]))))
        }
        return rows
    }

    static func buildCacheItems(fromDF data: Data, providerID: String) -> [CleanupItem] {
        decodeLines(DockerDFRow.self, from: data).compactMap { row in
            guard row.type == "Build Cache" else { return nil }
            let reclaimable = parseSize(row.reclaimable ?? "0B")
            guard reclaimable > 0 else { return nil }
            return CleanupItem(
                id: "\(providerID):build-cache", providerID: providerID,
                title: "Build cache", detail: "\(row.totalCount ?? "?") entries",
                size: reclaimable, safety: .safe,
                action: .command(ShellCommand("docker", ["builder", "prune", "-a", "-f"])),
                tab: Tab.buildCache.title, groupOrder: Tab.buildCache.rawValue)
        }
    }

    /// Parses Docker's sizes like "1.2GB", "512MB", "12.3kB", "0B", "1.2GB (50%)",
    /// "0B (virtual 1.2GB)". Docker uses SI units.
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
