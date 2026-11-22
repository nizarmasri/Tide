import Foundation
import Observation

/// The single source of truth the SwiftUI layer observes. It forwards actions to the backend and
/// receives snapshots from it. Views never talk to the backend directly.
@MainActor
@Observable
public final class AppModel {
    public private(set) var snapshot: EngineSnapshot
    public var settings: TideSettings {
        didSet {
            guard settings != oldValue else { return }
            settingsStore.save(settings)
            backend.updateSettings(settings)
        }
    }
    public let backend: EngineBackend

    /// Pending Add windows: request id → the inputs it was opened for.
    public var addRequests: [UUID: [AddInput]] = [:]

    // Hooks the app layer installs (window opening, notifications).
    @ObservationIgnored public var openAddWindow: ((UUID) -> Void)?
    @ObservationIgnored public var showTaskInWindow: ((TaskID) -> Void)?
    @ObservationIgnored public var onEvent: ((EngineEvent) -> Void)?

    @ObservationIgnored private let settingsStore: SettingsStore
    @ObservationIgnored private var started = false
    @ObservationIgnored private var visibleSurfaces = Set<String>()

    public init(backend: EngineBackend, settingsStore: SettingsStore, initial: EngineSnapshot = EngineSnapshot()) {
        self.backend = backend
        self.settingsStore = settingsStore
        self.settings = settingsStore.load()
        self.snapshot = initial
    }

    public func start() {
        guard !started else { return }
        started = true
        backend.start(settings: settings, onSnapshot: { [weak self] snap in
            Task { @MainActor in self?.apply(snap) }
        }, onEvent: { [weak self] event in
            Task { @MainActor in self?.onEvent?(event) }
        })
    }

    public func shutdown() { backend.shutdown() }

    /// Test/preview hook: replace the snapshot directly.
    public func apply(_ snap: EngineSnapshot) {
        if snap != snapshot { snapshot = snap }
    }

    public func task(_ id: TaskID) -> DownloadTask? { snapshot.tasks.first { $0.id == id } }

    // MARK: Visibility (drives polling rate)

    public func surfaceAppeared(_ name: String) {
        let wasEmpty = visibleSurfaces.isEmpty
        visibleSurfaces.insert(name)
        if wasEmpty { backend.setUIVisible(true) }
    }

    public func surfaceDisappeared(_ name: String) {
        visibleSurfaces.remove(name)
        if visibleSurfaces.isEmpty { backend.setUIVisible(false) }
    }

    // MARK: Adding

    public func requestAdd(_ inputs: [AddInput]) {
        let id = UUID()
        addRequests[id] = inputs
        openAddWindow?(id)
    }

    public func finishAddRequest(_ id: UUID) { addRequests[id] = nil }

    public func inspect(_ input: AddInput, destination: URL? = nil) async -> AddPreview {
        await backend.inspect(input, destination: destination ?? settings.defaultDirectory)
    }

    @discardableResult
    public func add(_ preview: AddPreview, options: AddOptions) async throws -> TaskID {
        rememberDirectory(options.directory)
        return try await backend.add(preview, options: options)
    }

    public func rememberDirectory(_ url: URL) {
        var recents = settings.recentDirectories.filter { $0.standardizedFileURL != url.standardizedFileURL }
        recents.insert(url, at: 0)
        settings.recentDirectories = Array(recents.prefix(5))
    }

    // MARK: Task actions

    public func pause(_ ids: [TaskID]) { backend.pause(ids) }
    public func resume(_ ids: [TaskID]) { backend.resume(ids) }
    public func pauseAll() { backend.pauseAll() }
    public func resumeAll() { backend.resumeAll() }
    public func startNow(_ ids: [TaskID]) { backend.startNow(ids) }
    public func startAt(_ ids: [TaskID], date: Date?) { backend.startAt(ids, date: date) }
    public func remove(_ ids: [TaskID], trashFiles: Bool) async throws { try await backend.remove(ids, trashFiles: trashFiles) }
    public func clearCompleted() { backend.clearCompleted() }
    public func setSelectedFiles(_ id: TaskID, indexes: [Int]) async throws { try await backend.setSelectedFiles(id, indexes: indexes) }
    public func setSpeedLimit(_ ids: [TaskID], bytesPerSecond: Int64?) { backend.setSpeedLimit(ids, bytesPerSecond: bytesPerSecond) }
    public func setSeedPolicy(_ ids: [TaskID], policy: SeedPolicy?) { backend.setSeedPolicy(ids, policy: policy) }
    public func move(_ id: TaskID, to position: QueueMove) { backend.move(id, to: position) }
    public func verify(_ id: TaskID) { backend.verify(id) }
    public func retry(_ id: TaskID) { backend.retry(id) }

    public func files(_ id: TaskID) async -> [TaskFile] { await backend.files(id) }
    public func peers(_ id: TaskID) async -> [Peer] { await backend.peers(id) }
    public func pieces(_ id: TaskID) async -> PieceMap? { await backend.pieces(id) }

    // MARK: Import

    public func scanForImports(at url: URL) async -> [ImportCandidate] { await backend.scanForImports(at: url) }

    @discardableResult
    public func importDownloads(_ candidates: [ImportCandidate], selectedFiles: [String: [Int]] = [:]) async throws -> [TaskID] {
        if let dir = candidates.first?.directory { rememberDirectory(dir) }
        return try await backend.importDownloads(candidates, selectedFiles: selectedFiles)
    }

    // MARK: Global

    public var slowMode: Bool { snapshot.slowMode }
    public func setSlowMode(_ on: Bool) { backend.setSlowMode(on) }
    public func toggleSlowMode() { backend.setSlowMode(!snapshot.slowMode) }
    public func updateEnvironment(_ env: SystemEnvironment) { backend.updateEnvironment(env) }
    public func restartEngine() { backend.restartEngine() }
    public var engineLogURL: URL? { backend.engineLogURL() }

    /// True when anything is moving data — the popover/toolbar go/stop toggle shows Pause All.
    public var anythingMoving: Bool { snapshot.tasks.contains { $0.phase.isActive } }
}

/// JSON settings file in Application Support (or in memory for previews/tests).
public final class SettingsStore: @unchecked Sendable {
    private let url: URL?
    private var memory: TideSettings

    public init(url: URL?) {
        self.url = url
        self.memory = TideSettings()
    }

    public static func appDefault() -> SettingsStore {
        SettingsStore(url: TidePaths.supportDirectory.appendingPathComponent("settings.json"))
    }

    public static func inMemory(_ settings: TideSettings = TideSettings()) -> SettingsStore {
        let s = SettingsStore(url: nil)
        s.memory = settings
        return s
    }

    public func load() -> TideSettings {
        guard let url, let data = try? Data(contentsOf: url),
              let s = try? JSONDecoder().decode(TideSettings.self, from: data) else { return memory }
        memory = s
        return s
    }

    public func save(_ settings: TideSettings) {
        memory = settings
        guard let url else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? enc.encode(settings) { try? data.write(to: url, options: .atomic) }
    }
}

public enum TidePaths {
    public static var supportDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Tide", isDirectory: true)
    }
    public static var logDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Tide", isDirectory: true)
    }
}
