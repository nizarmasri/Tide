import Foundation

/// What the UI can ask of the engine. The real implementation (TideEngine target) wraps the Rust
/// core over UniFFI; `PreviewBackend` serves canned data for previews and tests.
///
/// Implementations push state through `onSnapshot` (called on any thread; AppModel hops to main).
public protocol EngineBackend: AnyObject, Sendable {
    func start(settings: TideSettings, onSnapshot: @escaping @Sendable (EngineSnapshot) -> Void,
               onEvent: @escaping @Sendable (EngineEvent) -> Void)
    func shutdown()
    /// UI visibility drives the polling rate (1 Hz visible, slow when hidden).
    func setUIVisible(_ visible: Bool)

    func inspect(_ input: AddInput, destination: URL) async -> AddPreview
    func add(_ preview: AddPreview, options: AddOptions) async throws -> TaskID
    func pause(_ ids: [TaskID])
    func resume(_ ids: [TaskID])
    func pauseAll()
    func resumeAll()
    func startNow(_ ids: [TaskID])
    func startAt(_ ids: [TaskID], date: Date?)
    func remove(_ ids: [TaskID], trashFiles: Bool) async throws
    func clearCompleted()
    func setSelectedFiles(_ id: TaskID, indexes: [Int]) async throws
    func setSpeedLimit(_ ids: [TaskID], bytesPerSecond: Int64?)
    func setSeedPolicy(_ ids: [TaskID], policy: SeedPolicy?)
    func move(_ id: TaskID, to position: QueueMove)
    func verify(_ id: TaskID)
    func retry(_ id: TaskID)

    func files(_ id: TaskID) async -> [TaskFile]
    func peers(_ id: TaskID) async -> [Peer]
    func pieces(_ id: TaskID) async -> PieceMap?

    func scanForImports(at url: URL) async -> [ImportCandidate]
    func importDownloads(_ candidates: [ImportCandidate], selectedFiles: [String: [Int]]) async throws -> [TaskID]

    func setSlowMode(_ on: Bool)
    func updateSettings(_ settings: TideSettings)
    /// Facts the Swift side observes, fed to the core's policy engine.
    func updateEnvironment(_ env: SystemEnvironment)
    func restartEngine()
    func engineLogURL() -> URL?
}

public enum QueueMove: Equatable, Sendable {
    case top, bottom, up, down
    case index(Int)
}

public enum EngineEvent: Equatable, Sendable {
    case completed(TaskID, name: String, directory: URL, volumeName: String)
    case stopped(TaskID, name: String, reason: String)
    case waitingForDrive(volumeName: String)
    case engineStopped(reason: String)
    case addedFromWatchFolder(name: String)
}

/// System facts observed by TideKit watchers.
public struct SystemEnvironment: Equatable, Sendable {
    public var onBattery = false
    public var networkAvailable = true
    public var networkExpensive = false
    /// Mounted volumes: mount path → volume UUID (nil when unknown).
    public var mountedVolumes: [String: String] = [:]
    public init() {}
}

public enum TideError: LocalizedError, Equatable {
    case engine(String)
    case notFound
    public var errorDescription: String? {
        switch self {
        case .engine(let m): return m
        case .notFound: return "That download isn't in Tide anymore."
        }
    }
}
