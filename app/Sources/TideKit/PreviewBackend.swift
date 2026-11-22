import Foundation

/// Canned-data backend for previews, the render matrix and tests. It never touches the network
/// or disk. Actions mutate the in-memory snapshot so interactive previews behave plausibly.
public final class PreviewBackend: EngineBackend, @unchecked Sendable {
    private let lock = NSLock()
    private var snap: EngineSnapshot
    private var onSnapshot: (@Sendable (EngineSnapshot) -> Void)?

    public init(_ snapshot: EngineSnapshot = PreviewFixtures.mixed) { self.snap = snapshot }

    private func publish(_ mutate: (inout EngineSnapshot) -> Void) {
        lock.lock(); mutate(&snap); let s = snap; let cb = onSnapshot; lock.unlock()
        cb?(s)
    }

    public func start(settings: TideSettings, onSnapshot: @escaping @Sendable (EngineSnapshot) -> Void,
                      onEvent: @escaping @Sendable (EngineEvent) -> Void) {
        lock.lock(); self.onSnapshot = onSnapshot; let s = snap; lock.unlock()
        onSnapshot(s)
    }
    public func shutdown() {}
    public func setUIVisible(_ visible: Bool) {}

    public func inspect(_ input: AddInput, destination: URL) async -> AddPreview {
        switch input {
        case .torrentFile: return PreviewFixtures.torrentPreview
        case .link(let s) where s.hasPrefix("magnet:"): return PreviewFixtures.magnetPreview
        case .link: return PreviewFixtures.urlPreview
        }
    }
    public func add(_ preview: AddPreview, options: AddOptions) async throws -> TaskID { TaskID(UUID().uuidString) }

    private func setPhase(_ ids: [TaskID], _ phase: TaskPhase) {
        publish { s in for i in s.tasks.indices where ids.contains(s.tasks[i].id) { s.tasks[i].phase = phase } }
    }
    public func pause(_ ids: [TaskID]) { setPhase(ids, .paused) }
    public func resume(_ ids: [TaskID]) { setPhase(ids, .downloading) }
    public func pauseAll() { publish { s in for i in s.tasks.indices where s.tasks[i].phase.isPausable { s.tasks[i].phase = .paused } } }
    public func resumeAll() { publish { s in for i in s.tasks.indices where s.tasks[i].phase == .paused { s.tasks[i].phase = .downloading } } }
    public func startNow(_ ids: [TaskID]) { setPhase(ids, .downloading) }
    public func startAt(_ ids: [TaskID], date: Date?) { if let date { setPhase(ids, .scheduled(startsAt: date)) } }
    public func remove(_ ids: [TaskID], trashFiles: Bool) async throws { publish { s in s.tasks.removeAll { ids.contains($0.id) } } }
    public func clearCompleted() { publish { s in s.tasks.removeAll { $0.phase.isFinished } } }
    public func setSelectedFiles(_ id: TaskID, indexes: [Int]) async throws {}
    public func setSpeedLimit(_ ids: [TaskID], bytesPerSecond: Int64?) {
        publish { s in for i in s.tasks.indices where ids.contains(s.tasks[i].id) { s.tasks[i].speedLimit = bytesPerSecond } }
    }
    public func setSeedPolicy(_ ids: [TaskID], policy: SeedPolicy?) {}
    public func move(_ id: TaskID, to position: QueueMove) {}
    public func verify(_ id: TaskID) { setPhase([id], .checking(progress: 0, secondsLeft: nil)) }
    public func retry(_ id: TaskID) { setPhase([id], .downloading) }

    public func files(_ id: TaskID) async -> [TaskFile] { PreviewFixtures.movieFiles }
    public func peers(_ id: TaskID) async -> [Peer] { PreviewFixtures.peers }
    public func pieces(_ id: TaskID) async -> PieceMap? { PreviewFixtures.pieceMap(count: 17361, done: 0.342) }

    public func scanForImports(at url: URL) async -> [ImportCandidate] { [PreviewFixtures.movieImport] }
    public func importDownloads(_ candidates: [ImportCandidate], selectedFiles: [String: [Int]]) async throws -> [TaskID] {
        candidates.map { TaskID($0.id) }
    }

    public func setSlowMode(_ on: Bool) { publish { $0.slowMode = on } }
    public func updateSettings(_ settings: TideSettings) {}
    public func updateEnvironment(_ env: SystemEnvironment) {}
    public func restartEngine() { publish { $0.engine = .running(version: "1.37.0") } }
    public func engineLogURL() -> URL? { nil }
}

/// Canned data for previews and screenshots.
public enum PreviewFixtures {
    public static let movies = URL(fileURLWithPath: "/Volumes/Media/Movies", isDirectory: true)
    public static let movieName = "Tears.of.Steel.2012.4K.HDR.mkv"
    static let gb: Int64 = 1_000_000_000
    static let now = Date(timeIntervalSince1970: 1_795_420_800) // fixed for stable renders

    public static let movie = DownloadTask(
        id: TaskID("movie"), name: movieName, kind: .torrent, phase: .downloading,
        completedBytes: 24_900_000_000, totalBytes: 72_814_480_399, downloadSpeed: 24_600_000,
        uploadSpeed: 0, seeders: 18, peers: 42, directory: movies, volumeName: "Media",
        volumeIsExternal: true,
        primaryFile: movies.appendingPathComponent("Tears.of.Steel.2012.4K.HDR/\(movieName)"),
        addedAt: now.addingTimeInterval(-86_400), infoHash: "209c8226b299b308beaf2b9cd3fb49212dbd13ec",
        magnetLink: "magnet:?xt=urn:btih:209C8226B299B308BEAF2B9CD3FB49212DBD13EC", gid: "2089b05ecca3d829",
        pieceLength: 4_194_304, pieceCount: 17361, piecesDone: 5941, trackerCount: 38)

    public static let show = DownloadTask(
        id: TaskID("show"), name: "Pioneer.One.S01.1080p.WEB", kind: .magnet,
        phase: .waitingForDrive(volumeName: "Media"), completedBytes: 9_300_000_000, totalBytes: 41_200_000_000,
        directory: movies, volumeName: "Media", volumeIsExternal: true, addedAt: now.addingTimeInterval(-3_600),
        trackerCount: 12)

    public static let ubuntu = DownloadTask(
        id: TaskID("ubuntu"), name: "ubuntu-26.04-desktop-arm64.iso", kind: .http,
        phase: .paused, completedBytes: 1_200_000_000, totalBytes: 6_100_000_000,
        directory: URL(fileURLWithPath: NSHomeDirectory() + "/Downloads"), volumeName: "Macintosh HD",
        addedAt: now.addingTimeInterval(-7_200), sourceURL: "https://cdimage.ubuntu.com/ubuntu-26.04-desktop-arm64.iso")

    public static let failed = DownloadTask(
        id: TaskID("failed"), name: "Cosmos.Laundromat.2015.4K.mkv", kind: .torrent,
        phase: .error(TaskProblem(kind: .diskFull, status: "Not enough space on Media",
                                  explanation: "Media needs 44.9 GB more. Free up space, then try again.",
                                  fix: .retry, rawMessage: "No space left on device", code: 9)),
        completedBytes: 31_000_000_000, totalBytes: 75_900_000_000, directory: movies, volumeName: "Media",
        volumeIsExternal: true, trackerCount: 20)

    public static let done = DownloadTask(
        id: TaskID("sintel"), name: "Sintel.2010.4K.mkv",
        kind: .torrent, phase: .completed(at: now.addingTimeInterval(-5_000)), completedBytes: 68_200_000_000,
        totalBytes: 68_200_000_000, directory: movies, volumeName: "Media", volumeIsExternal: true,
        addedAt: now.addingTimeInterval(-200_000), completedAt: now.addingTimeInterval(-5_000), trackerCount: 30)

    public static let mixed = EngineSnapshot(
        tasks: [movie, show, ubuntu, failed, done], downloadSpeed: 24_600_000, uploadSpeed: 0, slowMode: false,
        engine: .running(version: "1.37.0"), schedule: .anyTime,
        defaultVolume: VolumeStatus(name: "Media", isExternal: true, isConnected: true, freeBytes: 412 * gb))

    public static let empty = EngineSnapshot(
        engine: .running(version: "1.37.0"),
        defaultVolume: VolumeStatus(name: "Media", isExternal: true, isConnected: true, freeBytes: 412 * gb))

    public static let movieFiles: [TaskFile] = [
        TaskFile(index: 1, path: "Tears.of.Steel.2012.4K.HDR/\(movieName)",
                 length: 72_814_480_399, completedLength: 24_900_000_000, selected: true, tag: .video),
        TaskFile(index: 2, path: "Tears.of.Steel.2012.4K.HDR/Downloaded from example.org.txt",
                 length: 38, selected: false, tag: .text),
        TaskFile(index: 3, path: "Tears.of.Steel.2012.4K.HDR/release.txt",
                 length: 64, selected: false, tag: .text),
        TaskFile(index: 4, path: "Tears.of.Steel.2012.4K.HDR/info.txt",
                 length: 418, selected: false, tag: .text),
        TaskFile(index: 5, path: "Tears.of.Steel.2012.4K.HDR/poster.png",
                 length: 143_111, selected: false, tag: .image),
    ]

    public static let movieSmart = SmartSummary(skippedCount: 4, skippedBytes: 143_631, skippedDescription: "1 image, 3 text files")

    public static let torrentPreview = AddPreview(
        input: .torrentFile(movies.appendingPathComponent("209c8226b299b308beaf2b9cd3fb49212dbd13ec.torrent")),
        kind: .torrent, name: "Tears.of.Steel.2012.4K.HDR",
        totalBytes: 72_814_624_030, files: movieFiles.map { var f = $0; f.completedLength = 0; return f },
        smart: movieSmart)

    public static let magnetPreview = AddPreview(
        input: .link("magnet:?xt=urn:btih:209C8226B299B308BEAF2B9CD3FB49212DBD13EC"), kind: .magnet,
        name: "Tears of Steel 2012 4K HDR", totalBytes: nil, metadataPending: true, metadataPeers: 6)

    public static let urlPreview = AddPreview(
        input: .link("https://cdimage.ubuntu.com/ubuntu-26.04-desktop-arm64.iso"), kind: .http,
        name: "ubuntu-26.04-desktop-arm64.iso", totalBytes: 6_100_000_000)

    public static let peers: [Peer] = [
        Peer(address: "185.21.216.140:51413", client: "qBittorrent 5.1.2", progress: 1, downloadSpeed: 6_200_000, uploadSpeed: 0, isSeeder: true),
        Peer(address: "91.121.44.12:6881", client: "Transmission 4.0.6", progress: 1, downloadSpeed: 4_900_000, uploadSpeed: 0, isSeeder: true),
        Peer(address: "[2a01:4f8::1]:50413", client: "libtorrent 2.0", progress: 0.71, downloadSpeed: 2_100_000, uploadSpeed: 12_000, isSeeder: false),
        Peer(address: "78.46.12.9:42000", client: "", progress: 0.12, downloadSpeed: 0, uploadSpeed: 4_000, isSeeder: false),
    ]

    public static func pieceMap(count: Int, done: Double) -> PieceMap {
        var bits = [UInt8](repeating: 0, count: (count + 7) / 8)
        var rng = SplitMix(seed: 7)
        for i in 0..<count where Double(rng.next() % 10_000) / 10_000 < done {
            bits[i / 8] |= 0x80 >> UInt8(i % 8)
        }
        return PieceMap(count: count, bits: bits)
    }

    public static let movieImport = ImportCandidate(
        id: "209c8226b299b308beaf2b9cd3fb49212dbd13ec",
        name: "Tears.of.Steel.2012.4K.HDR",
        directory: movies, volumeName: "Media", totalBytes: 72_814_624_030, completedBytes: 24_918_237_184,
        torrentFile: movies.appendingPathComponent("209c8226b299b308beaf2b9cd3fb49212dbd13ec.torrent"),
        progressFile: movies.appendingPathComponent("Tears.of.Steel.2012.4K.HDR.aria2"),
        progressSavedAt: now.addingTimeInterval(-43_200),
        dataFile: movie.primaryFile, pieces: pieceMap(count: 17361, done: 0.342), files: movieFiles,
        smart: movieSmart, needsCheck: false, estimatedCheckSeconds: nil)
}

/// Deterministic RNG so preview renders are stable.
struct SplitMix {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}
