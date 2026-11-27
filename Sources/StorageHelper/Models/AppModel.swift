import AppKit
import Observation
import StorageCore

struct ProviderState: Identifiable {
    enum Status: Equatable {
        case idle
        case scanning
        case done
        case failed(String)
        case unavailable(String)
        case hidden
    }

    let provider: any CleanupProvider
    var status: Status = .idle
    var items: [CleanupItem] = []

    var id: String { provider.id }
    var total: Int64 { items.reduce(0) { $0 + $1.size } }
    var isVisible: Bool { status != .hidden }
}

@MainActor
@Observable
final class AppModel {
    var states: [ProviderState]
    var selection: Set<CleanupItem.ID> = []
    var disk: DiskInfo? = DiskInfo.current()
    var hasFullDiskAccess = Permissions.hasFullDiskAccess()
    var lastScan: Date?
    var isCleaning = false
    var lastReport: CleanReport?

    /// Past full scans, oldest first (for "What Changed").
    var history: [ScanSnapshot] = []

    /// Cleanup rules, saved whenever they change.
    var rules: [CleanupRule] = AppSettings.rules {
        didSet { AppSettings.rules = rules }
    }

    /// Items the enabled rules select from the current scan results.
    var ruleMatches: [CleanupItem] { RuleEngine.apply(rules, to: allItems) }

    private var scanTask: Task<Void, Never>?
    private let cleaner = Cleaner()
    private let scanHistory = ScanHistory()

    var isScanning: Bool { states.contains { $0.status == .scanning } }

    init() {
        states = ProviderRegistry.all(nodeModulesRoots: AppSettings.nodeModulesRoots).map { ProviderState(provider: $0) }
        history = scanHistory.load()
        AppSettings.register()
        startMonitoring()
    }

    // MARK: Background monitoring (menu bar)

    private var monitorTask: Task<Void, Never>?

    /// Every 10 minutes: refresh free space, warn if low, and run a daily scan so
    /// "What Changed" has history even if you don't open the window.
    private func startMonitoring() {
        monitorTask?.cancel()
        monitorTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.monitorTick()
                try? await Task.sleep(for: .seconds(600))
            }
        }
    }

    func monitorTick() async {
        refreshDisk()
        if let disk { LowSpaceNotifier.checkAndNotify(disk: disk, growth: growth(age: 86_400) ?? growth()) }

        let defaults = UserDefaults.standard
        let lastFullScan = history.last?.date ?? .distantPast
        // lastScan != nil: the launch scan already ran, so this is a long-running session.
        if defaults.bool(forKey: AppSettings.dailyScanKey), !isScanning, lastScan != nil,
           Date().timeIntervalSince(lastFullScan) > 86_400 {
            scanAll()
        }
    }

    /// Starts the first scan once per launch (not every time the window reopens).
    func scanIfNeeded() {
        if lastScan == nil, !isScanning { scanAll() }
    }

    /// Growth between the latest scan and the one closest to `age` before it.
    func growth(age: TimeInterval = 0) -> Growth? {
        guard let latest = history.last,
              let base = ScanHistory.baseline(in: history, for: latest, age: age)
        else { return nil }
        return ScanHistory.growth(from: base, to: latest)
    }

    /// Saves a snapshot of a completed full scan.
    private func recordSnapshot() {
        refreshDisk()
        guard let disk else { return }
        let done = states.filter { $0.status == .done }
            .map { (id: $0.id, title: $0.provider.title, items: $0.items) }
        guard !done.isEmpty else { return }
        let history = scanHistory
        let snapshot = ScanSnapshot(date: Date(), disk: disk, providers: done)
        Task.detached(priority: .utility) {
            let updated = history.append(snapshot)
            await MainActor.run { self.history = updated }
        }
    }

    // MARK: Derived values

    var visibleStates: [ProviderState] { states.filter(\.isVisible) }

    func states(in category: CleanupCategory) -> [ProviderState] {
        visibleStates.filter { $0.provider.category == category }
    }

    var allItems: [CleanupItem] { states.flatMap(\.items) }
    var totalReclaimable: Int64 { allItems.reduce(0) { $0 + $1.size } }
    var selectedItems: [CleanupItem] { allItems.filter { selection.contains($0.id) } }
    var selectedSize: Int64 { selectedItems.reduce(0) { $0 + $1.size } }

    /// Used space that no scanned item accounts for (apps, documents, system files…).
    var unexplainedUsed: Int64? {
        guard let disk else { return nil }
        return max(0, disk.used - totalReclaimable)
    }

    func state(for id: String) -> ProviderState? { states.first { $0.id == id } }

    // MARK: Scanning

    func scanAll() {
        scanTask?.cancel()
        refreshDisk()
        hasFullDiskAccess = Permissions.hasFullDiskAccess()
        let providers = states.map(\.provider)
        scanTask = Task {
            await withTaskGroup(of: Void.self) { group in
                for provider in providers {
                    group.addTask { await self.scan(provider) }
                }
            }
            guard !Task.isCancelled else { return }
            lastScan = Date()
            recordSnapshot()
        }
    }

    func rescan(providerID: String) {
        guard let provider = state(for: providerID)?.provider else { return }
        Task { await scan(provider) }
    }

    func cancelScan() {
        scanTask?.cancel()
        for index in states.indices where states[index].status == .scanning {
            states[index].status = .failed("Cancelled")
        }
    }

    private func scan(_ provider: any CleanupProvider) async {
        update(provider.id) { $0.status = .scanning }
        // Run off the main actor: providers do blocking file-system work.
        let result: Result<[CleanupItem], Error>? = await Task.detached(priority: .userInitiated) {
            switch await provider.availability() {
            case .notInstalled: return nil
            case .unavailable(let reason): return .failure(ProviderError(reason))
            case .available:
                do { return .success(try await provider.scan()) } catch { return .failure(error) }
            }
        }.value

        if Task.isCancelled { return }
        update(provider.id) { state in
            let oldIDs = Set(state.items.map(\.id))
            switch result {
            case nil:
                state.status = .hidden
                state.items = []
            case .success(let items):
                state.status = .done
                // Tables need unique IDs; duplicates would render twice and be counted twice.
                var seen = Set<CleanupItem.ID>()
                state.items = items.filter { seen.insert($0.id).inserted }
            case .failure(let error as ProviderError):
                state.status = .unavailable(error.message)
                state.items = []
            case .failure(let error):
                state.status = .failed(error.localizedDescription)
                state.items = []
            }
            // Reset selection for this provider: pre-select only safe items.
            selection.subtract(oldIDs)
            selection.formUnion(state.items.filter { $0.safety.isPreselected && $0.action.isActionable }.map(\.id))
        }
    }

    private func update(_ id: String, _ change: (inout ProviderState) -> Void) {
        guard let index = states.firstIndex(where: { $0.id == id }) else { return }
        change(&states[index])
    }

    func refreshDisk() { disk = DiskInfo.current() }

    // MARK: Selection

    func setSelected(_ selected: Bool, items: [CleanupItem]) {
        let ids = items.filter(\.action.isActionable).map(\.id)
        if selected { selection.formUnion(ids) } else { selection.subtract(ids) }
    }

    // MARK: Cleaning

    /// Names of running apps that relate to the given items (warn before cleaning).
    func runningRelatedApps(for items: [CleanupItem]) -> [String] {
        let providerIDs = Set(items.map(\.providerID))
        let bundleIDs = Set(states.filter { providerIDs.contains($0.id) }.flatMap { $0.provider.relatedApps })
        return NSWorkspace.shared.runningApplications
            .filter { app in app.bundleIdentifier.map(bundleIDs.contains) ?? false }
            .compactMap(\.localizedName)
    }

    func clean(_ items: [CleanupItem], emptyTrashAfter: Bool) async {
        isCleaning = true
        defer { isCleaning = false }
        let cleaner = self.cleaner
        let report = await Task.detached(priority: .userInitiated) {
            await cleaner.clean(items, emptyTrashAfter: emptyTrashAfter)
        }.value

        let cleanedIDs = Set(report.succeeded.map(\.item.id))
        for index in states.indices {
            states[index].items.removeAll { cleanedIDs.contains($0.id) }
        }
        selection.subtract(cleanedIDs)
        lastReport = report
        refreshDisk()

        // Re-scan touched providers so numbers stay honest (e.g. partial failures, Trash growing).
        let touched = Set(items.map(\.providerID)).union(emptyTrashAfter ? ["trash"] : [])
        for id in touched { rescan(providerID: id) }
        if !touched.contains("trash") { rescan(providerID: "trash") }
    }
}

enum AppSettings {
    static let rulesKey = "cleanupRules"

    static var rules: [CleanupRule] {
        get {
            let stored = UserDefaults.standard.data(forKey: rulesKey)
                .flatMap { try? JSONDecoder().decode([CleanupRule].self, from: $0) } ?? []
            return RuleEngine.merged(stored)
        }
        set {
            UserDefaults.standard.set(try? JSONEncoder().encode(newValue), forKey: rulesKey)
        }
    }

    static let showMenuBarKey = "showMenuBar"
    static let lowSpaceAlertsKey = "lowSpaceAlerts"
    static let lowSpaceThresholdGBKey = "lowSpaceThresholdGB"
    static let dailyScanKey = "dailyBackgroundScan"
    static let lastAlertDateKey = "lastLowSpaceAlertDate"
    static let lastAlertFreeKey = "lastLowSpaceAlertFree"

    static func register() {
        UserDefaults.standard.register(defaults: [
            showMenuBarKey: true,
            lowSpaceAlertsKey: true,
            lowSpaceThresholdGBKey: 30,
            dailyScanKey: true,
        ])
    }

    static let nodeModulesRootsKey = "nodeModulesRoots"
    static let skipFullDiskAccessPromptKey = "skipFullDiskAccessPrompt"

    /// Ask at startup unless access is already granted or the user chose "Don't ask again".
    @MainActor static var shouldPromptForFullDiskAccess: Bool {
        !UserDefaults.standard.bool(forKey: skipFullDiskAccessPromptKey) && !Permissions.hasFullDiskAccess()
    }

    /// nil = use the defaults from NodeModulesProvider.
    static var nodeModulesRoots: [URL]? {
        get {
            UserDefaults.standard.stringArray(forKey: nodeModulesRootsKey)?.map { URL(fileURLWithPath: $0) }
        }
        set {
            UserDefaults.standard.set(newValue?.map(\.path), forKey: nodeModulesRootsKey)
        }
    }
}
