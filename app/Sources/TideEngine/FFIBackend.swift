import Foundation
import TideFFI
import TideKit

/// EngineBackend over the Rust core. Every core call is synchronous and may touch disk or aria2,
/// so they run off the main thread; snapshots and events arrive on the core's engine thread.
public final class FFIBackend: EngineBackend, VolumeEjectHandling, @unchecked Sendable {
    private let engine: TideEngine
    private let queue = DispatchQueue(label: "tide.engine.calls", qos: .userInitiated)
    private var listener: Listener?
    private var lastEnvironment = SystemEnvironment()

    public init() {
        try? FileManager.default.createDirectory(at: TidePaths.supportDirectory, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: TidePaths.logDirectory, withIntermediateDirectories: true)
        engine = TideEngine(config: CoreConfig(
            aria2Path: FFIBackend.aria2Path(),
            supportDir: TidePaths.supportDirectory.path,
            logDir: TidePaths.logDirectory.path,
            appPid: UInt32(ProcessInfo.processInfo.processIdentifier)
        ))
    }

    /// Bundled Contents/Helpers/aria2c, else Homebrew's (development builds).
    public static func aria2Path() -> String {
        if let helpers = Bundle.main.executableURL?.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Helpers/aria2c"), FileManager.default.isExecutableFile(atPath: helpers.path) {
            return helpers.path
        }
        return defaultAria2Path()
    }

    private func async(_ work: @escaping @Sendable () -> Void) { queue.async(execute: work) }

    private func call<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { cont in queue.async { cont.resume(returning: work()) } }
    }

    private func callThrowing<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { cont in
            queue.async {
                do { cont.resume(returning: try work()) } catch let CoreError.Failed(message) {
                    cont.resume(throwing: TideError.engine(message))
                } catch { cont.resume(throwing: error) }
            }
        }
    }

    // MARK: Lifecycle

    public func start(settings: TideSettings, onSnapshot: @escaping @Sendable (EngineSnapshot) -> Void,
                      onEvent: @escaping @Sendable (EngineEvent) -> Void) {
        let l = Listener(onSnapshot: { onSnapshot(Map.snapshot($0)) }, onEvent: { onEvent(Map.event($0)) })
        listener = l
        let engine = self.engine
        let core = Map.settings(settings)
        let env = Map.environment(SystemEnvironment())
        async {
            engine.updateEnvironment(environment: env)
            engine.start(settings: core, listener: l)
        }
    }

    public func shutdown() {
        // Synchronous: aria2 must write its progress files before the app exits.
        engine.shutdown()
    }

    public func setUIVisible(_ visible: Bool) {
        let engine = self.engine
        async { engine.setUiVisible(visible: visible) }
    }

    // MARK: Adding

    public func inspect(_ input: AddInput, destination: URL) async -> AddPreview {
        let engine = self.engine
        let source = Map.source(input)
        let core = await call { engine.inspect(source: source, destination: destination.path) }
        return Map.preview(core, input: input)
    }

    public func add(_ preview: AddPreview, options: AddOptions) async throws -> TaskID {
        let engine = self.engine
        let req = CoreAddRequest(
            source: Map.source(preview.input),
            directory: options.directory.path,
            selectedFiles: options.selectedFiles.map { $0.map { UInt32($0) } },
            start: Map.start(options.start)
        )
        let id = try await callThrowing { try engine.add(request: req) }
        return TaskID(id)
    }

    // MARK: Task actions

    private func ids(_ ids: [TaskID]) -> [String] { ids.map(\.raw) }

    public func pause(_ ids: [TaskID]) { let e = engine, i = self.ids(ids); async { e.pause(ids: i) } }
    public func resume(_ ids: [TaskID]) { let e = engine, i = self.ids(ids); async { e.resume(ids: i) } }
    public func pauseAll() { let e = engine; async { e.pauseAll() } }
    public func resumeAll() { let e = engine; async { e.resumeAll() } }
    public func startNow(_ ids: [TaskID]) { let e = engine, i = self.ids(ids); async { e.startNow(ids: i) } }
    public func startAt(_ ids: [TaskID], date: Date?) {
        let e = engine, i = self.ids(ids), t = date.map { Int64($0.timeIntervalSince1970) }
        async { e.startAt(ids: i, time: t) }
    }

    public func remove(_ ids: [TaskID], trashFiles: Bool) async throws {
        let e = engine, i = self.ids(ids)
        let paths = await call { e.remove(ids: i, trashFiles: trashFiles) }
        for p in paths {
            try? FileManager.default.trashItem(at: URL(fileURLWithPath: p), resultingItemURL: nil)
        }
    }

    public func clearCompleted() { let e = engine; async { e.clearCompleted() } }

    public func setSelectedFiles(_ id: TaskID, indexes: [Int]) async throws {
        let e = engine, raw = id.raw, idx = indexes.map { UInt32($0) }
        try await callThrowing { try e.setSelectedFiles(id: raw, indexes: idx) }
    }

    public func setSpeedLimit(_ ids: [TaskID], bytesPerSecond: Int64?) {
        let e = engine, i = self.ids(ids)
        async { e.setSpeedLimit(ids: i, bytesPerSecond: bytesPerSecond) }
    }

    public func setSeedPolicy(_ ids: [TaskID], policy: SeedPolicy?) {
        let e = engine, i = self.ids(ids), p = policy.map(Map.seed)
        async { e.setSeedPolicy(ids: i, policy: p) }
    }

    public func move(_ id: TaskID, to position: QueueMove) {
        let e = engine, raw = id.raw
        let m: CoreMove
        switch position {
        case .top: m = .top
        case .bottom: m = .bottom
        case .up: m = .up
        case .down: m = .down
        case .index(let i): m = .index(index: UInt32(max(0, i)))
        }
        async { e.moveTask(id: raw, to: m) }
    }

    public func verify(_ id: TaskID) { let e = engine, raw = id.raw; async { e.verify(id: raw) } }
    public func retry(_ id: TaskID) { let e = engine, raw = id.raw; async { e.retry(id: raw) } }

    public func files(_ id: TaskID) async -> [TaskFile] {
        let e = engine, raw = id.raw
        return await call { e.files(id: raw) }.map(Map.file)
    }

    public func peers(_ id: TaskID) async -> [Peer] {
        let e = engine, raw = id.raw
        return await call { e.peers(id: raw) }.map {
            Peer(address: $0.address, client: $0.client, progress: $0.progress, downloadSpeed: $0.downloadSpeed,
                 uploadSpeed: $0.uploadSpeed, isSeeder: $0.isSeeder)
        }
    }

    public func pieces(_ id: TaskID) async -> PieceMap? {
        let e = engine, raw = id.raw
        return await call { e.pieces(id: raw) }.map(Map.pieces)
    }

    // MARK: Import

    public func scanForImports(at url: URL) async -> [ImportCandidate] {
        let e = engine
        return await call { e.scanImports(path: url.path) }.map(Map.importCandidate)
    }

    public func importDownloads(_ candidates: [ImportCandidate], selectedFiles: [String: [Int]]) async throws -> [TaskID] {
        let e = engine
        let reqs = candidates.map {
            CoreImportRequest(id: $0.id, directory: $0.directory.path,
                              selectedFiles: selectedFiles[$0.id].map { $0.map { UInt32($0) } })
        }
        return try await callThrowing { try e.importDownloads(items: reqs) }.map(TaskID.init)
    }

    // MARK: Global

    public func setSlowMode(_ on: Bool) { let e = engine; async { e.setSlowMode(on: on) } }

    public func updateSettings(_ settings: TideSettings) {
        let e = engine, s = Map.settings(settings)
        async { e.updateSettings(settings: s) }
    }

    public func updateEnvironment(_ env: SystemEnvironment) {
        lastEnvironment = env
        let e = engine, c = Map.environment(env)
        async { e.updateEnvironment(environment: c) }
    }

    public func restartEngine() { let e = engine; async { e.restartEngine() } }
    public func engineLogURL() -> URL? { URL(fileURLWithPath: engine.logPath()) }

    /// Synchronous on purpose: the drive is about to eject, aria2 must let go of its files first.
    public func volumeWillUnmount(_ mountPath: String) {
        engine.volumeWillUnmount(mountPath: mountPath)
    }

    /// `Tide --cli verify-sample`.
    public static func verifySample(torrent: String, directory: String, sample: Int) -> String {
        TideFFI.verifySample(torrentPath: torrent, directory: directory, sample: UInt32(sample))
    }

    public static var coreVersionString: String { coreVersion() }
}

private final class Listener: EngineListener, @unchecked Sendable {
    let snapshot: (CoreSnapshot) -> Void
    let event: (CoreEvent) -> Void
    init(onSnapshot: @escaping (CoreSnapshot) -> Void, onEvent: @escaping (CoreEvent) -> Void) {
        snapshot = onSnapshot
        event = onEvent
    }
    func onSnapshot(snapshot s: CoreSnapshot) { snapshot(s) }
    func onEvent(event e: CoreEvent) { event(e) }
}

// MARK: - Mapping

enum Map {
    static func date(_ t: Int64) -> Date { Date(timeIntervalSince1970: TimeInterval(t)) }

    static func kind(_ k: CoreKind) -> TaskKind {
        switch k {
        case .torrent: return .torrent
        case .magnet: return .magnet
        case .http: return .http
        }
    }

    static func problem(_ p: CoreProblem) -> TaskProblem {
        let kind: ProblemKind
        switch p.kind {
        case .diskFull: kind = .diskFull
        case .cantWrite: kind = .cantWrite
        case .fileExists: kind = .fileExists
        case .notFound: kind = .notFound
        case .needsLogin: kind = .needsLogin
        case .fat32: kind = .fat32
        case .badTorrent: kind = .badTorrent
        case .unknown: kind = .unknown
        }
        let fix: FixAction
        switch p.fix {
        case .retry: fix = .retry
        case .chooseFolder: fix = .chooseFolder
        case .resolve: fix = .resolve
        case .copyLink: fix = .copyLink
        case .chooseAnotherFile: fix = .chooseAnotherFile
        }
        return TaskProblem(kind: kind, status: p.status, explanation: p.explanation, fix: fix,
                           rawMessage: p.rawMessage, code: p.code.map { Int($0) })
    }

    static func phase(_ p: CorePhase) -> TaskPhase {
        switch p {
        case .downloading: return .downloading
        case .stalled: return .stalled
        case .resuming: return .resuming
        case .fetchingMetadata(let peers): return .fetchingMetadata(peers: Int(peers))
        case .queued(let pos): return .queued(position: Int(pos))
        case .paused: return .paused
        case .autoPaused(let r): return .autoPaused(r == .battery ? .battery : .expensiveNetwork)
        case .scheduled(let t): return .scheduled(startsAt: date(t))
        case .checking(let progress, let left): return .checking(progress: progress, secondsLeft: left.map { Int($0) })
        case .waitingForDrive(let v): return .waitingForDrive(volumeName: v)
        case .waitingForNetwork: return .waitingForNetwork
        case .error(let p): return .error(problem(p))
        case .completed(let at): return .completed(at: date(at))
        case .seeding(let ratio, let target): return .seeding(ratio: ratio, target: target)
        }
    }

    static func task(_ t: CoreTask) -> DownloadTask {
        DownloadTask(
            id: TaskID(t.id), name: t.name, kind: kind(t.kind), phase: phase(t.phase),
            completedBytes: t.completedBytes, totalBytes: t.totalBytes, downloadSpeed: t.downloadSpeed,
            uploadSpeed: t.uploadSpeed, seeders: Int(t.seeders), peers: Int(t.peers),
            directory: URL(fileURLWithPath: t.directory, isDirectory: true), volumeName: t.volumeName,
            volumeIsExternal: t.volumeIsExternal, primaryFile: t.primaryFile.map { URL(fileURLWithPath: $0) },
            addedAt: date(t.addedAt), completedAt: t.completedAt.map(date), speedLimit: t.speedLimit,
            startAt: t.startAt.map(date), infoHash: t.infoHash, magnetLink: t.magnetLink, sourceURL: t.sourceUrl,
            gid: t.gid, pieceLength: t.pieceLength, pieceCount: t.pieceCount.map { Int($0) },
            piecesDone: t.piecesDone.map { Int($0) }, trackerCount: Int(t.trackerCount), createdBy: t.createdBy,
            comment: t.comment, justImported: t.justImported)
    }

    static func snapshot(_ s: CoreSnapshot) -> EngineSnapshot {
        let engine: EngineState
        switch s.engine {
        case .starting: engine = .starting
        case .running(let v): engine = .running(version: v)
        case .stopped(let r): engine = .stopped(reason: r)
        }
        let schedule: ScheduleStatus
        switch s.schedule {
        case .anyTime: schedule = .anyTime
        case .inside(let end): schedule = .insideWindow(endsAt: date(end))
        case .outside(let start): schedule = .outsideWindow(startsAt: date(start))
        }
        return EngineSnapshot(
            tasks: s.tasks.map(task), downloadSpeed: s.downloadSpeed, uploadSpeed: s.uploadSpeed,
            slowMode: s.slowMode, engine: engine, schedule: schedule,
            defaultVolume: s.defaultVolume.map {
                VolumeStatus(name: $0.name, isExternal: $0.isExternal, isConnected: $0.isConnected, freeBytes: $0.freeBytes)
            },
            autoPause: s.autoPause.map { $0 == .battery ? .battery : .expensiveNetwork })
    }

    static func event(_ e: CoreEvent) -> EngineEvent {
        switch e {
        case .completed(let id, let name, let dir, let vol):
            return .completed(TaskID(id), name: name, directory: URL(fileURLWithPath: dir, isDirectory: true), volumeName: vol)
        case .stopped(let id, let name, let reason): return .stopped(TaskID(id), name: name, reason: reason)
        case .waitingForDrive(let v): return .waitingForDrive(volumeName: v)
        case .engineStopped(let r): return .engineStopped(reason: r)
        }
    }

    static func tag(_ t: CoreFileTag) -> FileTag {
        switch t {
        case .video: return .video
        case .sample: return .sample
        case .image: return .image
        case .text: return .text
        case .other: return .other
        }
    }

    static func file(_ f: CoreFile) -> TaskFile {
        TaskFile(index: Int(f.index), path: f.path, length: f.length, completedLength: f.completedLength,
                 selected: f.selected, tag: tag(f.tag))
    }

    static func pieces(_ p: CorePieces) -> PieceMap { PieceMap(count: Int(p.count), bits: [UInt8](p.bits)) }

    static func smart(_ s: CoreSmart) -> SmartSummary {
        SmartSummary(skippedCount: Int(s.skippedCount), skippedBytes: s.skippedBytes, skippedDescription: s.skippedDescription)
    }

    static func source(_ i: AddInput) -> CoreSource {
        switch i {
        case .torrentFile(let url): return .torrentFile(path: url.path)
        case .link(let s): return .link(link: s)
        }
    }

    static func start(_ s: StartMode) -> CoreStart {
        switch s {
        case .now: return .now
        case .at(let d): return .at(time: Int64(d.timeIntervalSince1970))
        case .paused: return .paused
        }
    }

    static func preview(_ p: CorePreview, input: AddInput) -> AddPreview {
        AddPreview(
            input: input, kind: kind(p.kind), name: p.name, totalBytes: p.totalBytes, files: p.files.map(file),
            smart: p.smart.map(smart), metadataPending: p.metadataPending, metadataPeers: Int(p.metadataPeers),
            duplicateOf: p.duplicateOf.map(TaskID.init),
            existing: p.existingCompleted.map { ExistingProgress(completedBytes: $0, fraction: p.existingFraction ?? 0) },
            problem: p.problem.map { $0 == .unreadableTorrent ? .unreadableTorrent : .invalidLink })
    }

    static func importCandidate(_ c: CoreImport) -> ImportCandidate {
        ImportCandidate(
            id: c.id, name: c.name, directory: URL(fileURLWithPath: c.directory, isDirectory: true),
            volumeName: c.volumeName, totalBytes: c.totalBytes, completedBytes: c.completedBytes,
            torrentFile: c.torrentFile.map { URL(fileURLWithPath: $0) },
            progressFile: c.progressFile.map { URL(fileURLWithPath: $0) },
            progressSavedAt: c.progressSavedAt.map(date), dataFile: c.dataFile.map { URL(fileURLWithPath: $0) },
            pieces: c.pieces.map(pieces), files: c.files.map(file), smart: c.smart.map(smart),
            needsCheck: c.needsCheck, estimatedCheckSeconds: c.estimatedCheckSeconds.map { Int($0) },
            alreadyInLibrary: c.alreadyInLibrary)
    }

    static func window(_ w: TimeWindow) -> CoreWindow {
        CoreWindow(startMinute: UInt32(max(0, w.startMinute)), endMinute: UInt32(max(0, w.endMinute)),
                   weekdays: w.weekdays.sorted().map { UInt32($0) })
    }

    static func seed(_ p: SeedPolicy) -> CoreSeed {
        switch p {
        case .stop: return .stop
        case .ratio(let r): return .ratio(ratio: r)
        case .minutes(let m): return .minutes(minutes: UInt32(max(0, m)))
        }
    }

    static func settings(_ s: TideSettings) -> CoreSettings {
        CoreSettings(
            defaultDirectory: s.defaultDirectory.path, onlyMainVideo: s.onlyMainVideo, skipExtras: s.skipExtras,
            downloadHoursEnabled: s.downloadHoursEnabled, downloadHours: window(s.downloadHours),
            slowDownLimit: s.slowModeDownLimit, slowUpLimit: s.slowModeUpLimit,
            slowModeScheduled: s.slowModeScheduled, slowModeHours: window(s.slowModeHours),
            pauseOnBattery: s.pauseOnBattery, pauseOnExpensiveNetwork: s.pauseOnExpensiveNetwork,
            downLimit: s.downLimit, upLimit: s.upLimit, maxConcurrent: UInt32(max(1, s.maxConcurrent)),
            connectionsPerServer: UInt32(min(16, max(1, s.connectionsPerServer))), afterDownload: seed(s.afterDownload),
            maxPeers: UInt32(max(1, s.maxPeers)), listenPort: UInt16(clamping: s.listenPort), dht: s.dht, pex: s.pex,
            lpd: s.lpd, preferEncryption: s.preferEncryption, extraTrackers: s.extraTrackers,
            advancedOptions: s.advancedOptions)
    }

    static func environment(_ e: SystemEnvironment) -> CoreEnvironment {
        let boot = (try? URL(fileURLWithPath: "/").resourceValues(forKeys: [.volumeNameKey]).volumeName) ?? "Macintosh HD"
        return CoreEnvironment(
            onBattery: e.onBattery, networkAvailable: e.networkAvailable, networkExpensive: e.networkExpensive,
            bootVolumeName: boot, utcOffsetSeconds: Int64(TimeZone.current.secondsFromGMT()))
    }
}
