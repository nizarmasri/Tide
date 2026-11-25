import Foundation

// UI-facing value types. The SwiftUI layer only sees these; the FFI adapter (TideEngine target)
// maps the Rust core's records onto them. Keep them plain, Equatable and Sendable.

public struct TaskID: Hashable, Codable, Sendable, CustomStringConvertible {
    public let raw: String
    public init(_ raw: String) { self.raw = raw }
    public var description: String { raw }
}

public enum TaskKind: String, Codable, Sendable {
    case torrent   // from a .torrent file (metadata known)
    case magnet    // from a magnet link (metadata may still be pending)
    case http      // HTTP(S)/FTP/SFTP
}

public enum AutoPauseReason: String, Codable, Sendable {
    case battery
    case expensiveNetwork
}

public enum ProblemKind: String, Codable, Sendable {
    case diskFull, cantWrite, fileExists, notFound, needsLogin, fat32, badTorrent, unknown
}

public enum FixAction: String, Codable, Sendable {
    case retry, chooseFolder, resolve, copyLink, chooseAnotherFile, restartEngine
}

public struct TaskProblem: Equatable, Codable, Sendable {
    public var kind: ProblemKind
    /// Plain status line, ≤ 45 characters, sentence case, no final period.
    public var status: String
    /// Full-sentence explanation for the inspector (optional).
    public var explanation: String?
    public var fix: FixAction
    /// aria2's own message and code, only ever shown under Details.
    public var rawMessage: String?
    public var code: Int?

    public init(kind: ProblemKind, status: String, explanation: String? = nil, fix: FixAction,
                rawMessage: String? = nil, code: Int? = nil) {
        self.kind = kind; self.status = status; self.explanation = explanation; self.fix = fix
        self.rawMessage = rawMessage; self.code = code
    }
}

/// The 14 presentation states from DESIGN.md §7. The core decides the phase; TideKit maps it to
/// symbol/colour/text.
public enum TaskPhase: Equatable, Codable, Sendable {
    case downloading
    case stalled                       // 0 B/s for > 2 min
    case resuming                      // first ≤ 10 s after a resume/import: "Continuing from 34%"
    case fetchingMetadata(peers: Int)
    case queued(position: Int)         // 1-based position in line
    case paused
    case autoPaused(AutoPauseReason)
    case scheduled(startsAt: Date)
    case checking(progress: Double, secondsLeft: Int?)
    case waitingForDrive(volumeName: String)
    case waitingForNetwork
    case error(TaskProblem)
    case completed(at: Date)
    case seeding(ratio: Double, target: Double?)

    public var isActive: Bool {
        switch self {
        case .downloading, .stalled, .resuming, .fetchingMetadata, .checking: return true
        default: return false
        }
    }
    public var isFinished: Bool {
        switch self {
        case .completed, .seeding: return true
        default: return false
        }
    }
    public var isPausable: Bool {
        switch self {
        case .downloading, .stalled, .resuming, .fetchingMetadata, .queued, .scheduled, .waitingForDrive,
             .waitingForNetwork, .autoPaused:
            return true
        default: return false
        }
    }
}

public struct DownloadTask: Identifiable, Equatable, Sendable {
    public var id: TaskID
    public var name: String
    public var kind: TaskKind
    public var phase: TaskPhase
    /// Bytes done / bytes selected (not the whole torrent).
    public var completedBytes: Int64
    public var totalBytes: Int64
    public var downloadSpeed: Int64
    public var uploadSpeed: Int64
    public var seeders: Int
    public var peers: Int
    /// Folder the download lives in (aria2 `dir`).
    public var directory: URL
    /// Volume display name of `directory` ("Media", "Macintosh HD").
    public var volumeName: String
    public var volumeIsExternal: Bool
    /// The main file (largest selected) — used for the file-type icon, Open, Quick Look, Reveal.
    public var primaryFile: URL?
    public var addedAt: Date
    public var completedAt: Date?
    public var speedLimit: Int64?          // bytes/s, nil = unlimited
    public var startAt: Date?
    public var infoHash: String?
    public var magnetLink: String?
    public var sourceURL: String?
    public var gid: String?                // Details only
    public var pieceLength: Int64?
    public var pieceCount: Int?
    public var piecesDone: Int?
    public var trackerCount: Int
    public var createdBy: String?
    public var comment: String?
    /// True for a few seconds after import, for the one-time accent highlight.
    public var justImported: Bool

    public init(id: TaskID, name: String, kind: TaskKind, phase: TaskPhase, completedBytes: Int64,
                totalBytes: Int64, downloadSpeed: Int64 = 0, uploadSpeed: Int64 = 0, seeders: Int = 0,
                peers: Int = 0, directory: URL, volumeName: String, volumeIsExternal: Bool = false,
                primaryFile: URL? = nil, addedAt: Date = Date(), completedAt: Date? = nil,
                speedLimit: Int64? = nil, startAt: Date? = nil, infoHash: String? = nil,
                magnetLink: String? = nil, sourceURL: String? = nil, gid: String? = nil,
                pieceLength: Int64? = nil, pieceCount: Int? = nil, piecesDone: Int? = nil,
                trackerCount: Int = 0, createdBy: String? = nil, comment: String? = nil,
                justImported: Bool = false) {
        self.id = id; self.name = name; self.kind = kind; self.phase = phase
        self.completedBytes = completedBytes; self.totalBytes = totalBytes
        self.downloadSpeed = downloadSpeed; self.uploadSpeed = uploadSpeed
        self.seeders = seeders; self.peers = peers; self.directory = directory
        self.volumeName = volumeName; self.volumeIsExternal = volumeIsExternal
        self.primaryFile = primaryFile; self.addedAt = addedAt; self.completedAt = completedAt
        self.speedLimit = speedLimit; self.startAt = startAt; self.infoHash = infoHash
        self.magnetLink = magnetLink; self.sourceURL = sourceURL; self.gid = gid
        self.pieceLength = pieceLength; self.pieceCount = pieceCount; self.piecesDone = piecesDone
        self.trackerCount = trackerCount; self.createdBy = createdBy; self.comment = comment
        self.justImported = justImported
    }

    public var fraction: Double {
        totalBytes > 0 ? min(1, max(0, Double(completedBytes) / Double(totalBytes))) : 0
    }
}

public enum FileTag: String, Codable, Sendable {
    case video, sample, image, text, other
}

public struct TaskFile: Identifiable, Equatable, Sendable {
    public var id: Int { index }
    /// aria2 1-based file index.
    public var index: Int
    /// Path relative to the torrent root, "/"-separated (folders are derived from it).
    public var path: String
    public var length: Int64
    public var completedLength: Int64
    public var selected: Bool
    public var tag: FileTag

    public init(index: Int, path: String, length: Int64, completedLength: Int64 = 0, selected: Bool,
                tag: FileTag) {
        self.index = index; self.path = path; self.length = length
        self.completedLength = completedLength; self.selected = selected; self.tag = tag
    }
    public var name: String { (path as NSString).lastPathComponent }
}

public struct Peer: Identifiable, Equatable, Sendable {
    public var id: String { address }
    public var address: String          // "1.2.3.4:51413"
    public var client: String           // "qBittorrent 4.6" or ""
    public var progress: Double         // 0…1
    public var downloadSpeed: Int64     // from that peer to us
    public var uploadSpeed: Int64
    public var isSeeder: Bool
    public init(address: String, client: String, progress: Double, downloadSpeed: Int64,
                uploadSpeed: Int64, isSeeder: Bool) {
        self.address = address; self.client = client; self.progress = progress
        self.downloadSpeed = downloadSpeed; self.uploadSpeed = uploadSpeed; self.isSeeder = isSeeder
    }
}

/// Which pieces are done. `bits` is the aria2 bitfield (MSB first).
public struct PieceMap: Equatable, Sendable {
    public var count: Int
    public var bits: [UInt8]
    public init(count: Int, bits: [UInt8]) { self.count = count; self.bits = bits }
    public func has(_ i: Int) -> Bool {
        guard i >= 0, i < count, i / 8 < bits.count else { return false }
        return bits[i / 8] & (0x80 >> UInt8(i % 8)) != 0
    }
    public var doneCount: Int { bits.reduce(0) { $0 + $1.nonzeroBitCount } }
    /// Fraction done in each of `buckets` equal slices — for drawing at pixel width.
    public func buckets(_ buckets: Int) -> [Double] {
        guard count > 0, buckets > 0 else { return [] }
        return (0..<buckets).map { b in
            let lo = b * count / buckets, hi = max(lo + 1, (b + 1) * count / buckets)
            var n = 0
            for i in lo..<min(hi, count) where has(i) { n += 1 }
            return Double(n) / Double(hi - lo)
        }
    }
}

public enum EngineState: Equatable, Sendable {
    case starting
    case running(version: String)
    case stopped(reason: String)
}

public enum ScheduleStatus: Equatable, Sendable {
    case anyTime
    case insideWindow(endsAt: Date)
    case outsideWindow(startsAt: Date)
}

public struct VolumeStatus: Equatable, Sendable {
    public var name: String
    public var isExternal: Bool
    public var isConnected: Bool
    public var freeBytes: Int64?
    public init(name: String, isExternal: Bool, isConnected: Bool, freeBytes: Int64?) {
        self.name = name; self.isExternal = isExternal; self.isConnected = isConnected; self.freeBytes = freeBytes
    }
}

public struct EngineSnapshot: Equatable, Sendable {
    public var tasks: [DownloadTask]          // queue order for incomplete; completed after
    public var downloadSpeed: Int64
    public var uploadSpeed: Int64
    public var slowMode: Bool
    public var engine: EngineState
    public var schedule: ScheduleStatus
    public var defaultVolume: VolumeStatus?
    public var autoPause: AutoPauseReason?

    public init(tasks: [DownloadTask] = [], downloadSpeed: Int64 = 0, uploadSpeed: Int64 = 0,
                slowMode: Bool = false, engine: EngineState = .starting, schedule: ScheduleStatus = .anyTime,
                defaultVolume: VolumeStatus? = nil, autoPause: AutoPauseReason? = nil) {
        self.tasks = tasks; self.downloadSpeed = downloadSpeed; self.uploadSpeed = uploadSpeed
        self.slowMode = slowMode; self.engine = engine; self.schedule = schedule
        self.defaultVolume = defaultVolume; self.autoPause = autoPause
    }

    public var inProgress: [DownloadTask] { tasks.filter { !$0.phase.isFinished } }
    public var finished: [DownloadTask] {
        tasks.filter { $0.phase.isFinished }.sorted { ($0.completedAt ?? .distantPast) > ($1.completedAt ?? .distantPast) }
    }
}

// MARK: - Adding

public enum AddInput: Hashable, Codable, Sendable {
    case torrentFile(URL)
    case link(String)     // magnet: or http(s)/ftp/sftp
}

public enum InputProblem: Equatable, Sendable {
    case unreadableTorrent
    case invalidLink
}

public struct SmartSummary: Equatable, Sendable {
    public var skippedCount: Int
    public var skippedBytes: Int64
    /// "sample, 2 images, 1 text file"
    public var skippedDescription: String
    public init(skippedCount: Int, skippedBytes: Int64, skippedDescription: String) {
        self.skippedCount = skippedCount; self.skippedBytes = skippedBytes; self.skippedDescription = skippedDescription
    }
}

public struct ExistingProgress: Equatable, Sendable {
    public var completedBytes: Int64
    public var fraction: Double
    public init(completedBytes: Int64, fraction: Double) { self.completedBytes = completedBytes; self.fraction = fraction }
}

public struct AddPreview: Identifiable, Equatable, Sendable {
    public var id: UUID
    public var input: AddInput
    public var kind: TaskKind
    public var name: String
    public var totalBytes: Int64?          // nil = unknown (URL without size, magnet before metadata)
    public var files: [TaskFile]           // empty for URLs and pending magnets
    public var smart: SmartSummary?
    public var metadataPending: Bool       // magnet still fetching the file list
    public var metadataPeers: Int
    public var duplicateOf: TaskID?
    public var existing: ExistingProgress? // data + .aria2 found at the chosen destination
    public var problem: InputProblem?
    /// Lowercase hex info hash, for torrents and magnets.
    public var infoHash: String?

    public init(id: UUID = UUID(), input: AddInput, kind: TaskKind, name: String, totalBytes: Int64?,
                files: [TaskFile] = [], smart: SmartSummary? = nil, metadataPending: Bool = false,
                metadataPeers: Int = 0, duplicateOf: TaskID? = nil, existing: ExistingProgress? = nil,
                problem: InputProblem? = nil, infoHash: String? = nil) {
        self.id = id; self.input = input; self.kind = kind; self.name = name; self.totalBytes = totalBytes
        self.files = files; self.smart = smart; self.metadataPending = metadataPending
        self.metadataPeers = metadataPeers; self.duplicateOf = duplicateOf; self.existing = existing
        self.problem = problem; self.infoHash = infoHash
    }

    public var selectedBytes: Int64 {
        files.isEmpty ? (totalBytes ?? 0) : files.filter(\.selected).reduce(0) { $0 + $1.length }
    }
}

public enum StartMode: Equatable, Sendable {
    case now
    case at(Date)
    case paused
}

public struct AddOptions: Equatable, Sendable {
    public var directory: URL
    /// nil = smart default; otherwise the explicit 1-based indexes.
    public var selectedFiles: [Int]?
    public var start: StartMode
    public init(directory: URL, selectedFiles: [Int]? = nil, start: StartMode = .now) {
        self.directory = directory; self.selectedFiles = selectedFiles; self.start = start
    }
}

// MARK: - Importing

public struct ImportCandidate: Identifiable, Equatable, Sendable {
    public var id: String                  // info hash or progress-file path
    public var name: String
    public var directory: URL
    public var volumeName: String
    public var totalBytes: Int64
    public var completedBytes: Int64
    public var torrentFile: URL?
    public var progressFile: URL?
    public var progressSavedAt: Date?
    public var dataFile: URL?
    public var pieces: PieceMap?
    public var files: [TaskFile]
    public var smart: SmartSummary?
    /// No progress file: Tide checks the data on disk first.
    public var needsCheck: Bool
    public var estimatedCheckSeconds: Int?
    public var alreadyInLibrary: Bool

    public init(id: String, name: String, directory: URL, volumeName: String, totalBytes: Int64,
                completedBytes: Int64, torrentFile: URL?, progressFile: URL?, progressSavedAt: Date?,
                dataFile: URL?, pieces: PieceMap?, files: [TaskFile], smart: SmartSummary?,
                needsCheck: Bool, estimatedCheckSeconds: Int?, alreadyInLibrary: Bool = false) {
        self.id = id; self.name = name; self.directory = directory; self.volumeName = volumeName
        self.totalBytes = totalBytes; self.completedBytes = completedBytes; self.torrentFile = torrentFile
        self.progressFile = progressFile; self.progressSavedAt = progressSavedAt; self.dataFile = dataFile
        self.pieces = pieces; self.files = files; self.smart = smart; self.needsCheck = needsCheck
        self.estimatedCheckSeconds = estimatedCheckSeconds; self.alreadyInLibrary = alreadyInLibrary
    }

    public var fraction: Double { totalBytes > 0 ? Double(completedBytes) / Double(totalBytes) : 0 }
}

// MARK: - Settings

public struct TimeWindow: Equatable, Codable, Sendable {
    /// Minutes after midnight, 0…1439. `end < start` means the window crosses midnight.
    public var startMinute: Int
    public var endMinute: Int
    /// 1 = Sunday … 7 = Saturday (Calendar weekday numbering).
    public var weekdays: Set<Int>
    public init(startMinute: Int, endMinute: Int, weekdays: Set<Int> = Set(1...7)) {
        self.startMinute = startMinute; self.endMinute = endMinute; self.weekdays = weekdays
    }
}

public enum SeedPolicy: Equatable, Codable, Sendable {
    case stop
    case ratio(Double)
    case minutes(Int)
}

public enum ClearCompletedPolicy: String, Codable, Sendable, CaseIterable {
    case never, afterDay, afterWeek
}

public struct TideSettings: Equatable, Codable, Sendable {
    // General
    public var openAtLogin = true
    public var showSpeedInMenuBar = false
    public var preventSleep = true
    public var askBeforeQuit = true
    public var notifyCompleted = true
    public var notifyProblems = true
    public var notifyWaitingForDrive = true
    public var soundOnCompletion = true
    // Downloads
    public var defaultDirectory: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")
    public var recentDirectories: [URL] = []
    public var onlyMainVideo = true
    public var skipExtras = true
    public var watchFolderEnabled = false
    public var watchFolder: URL? = nil
    public var trashAddedTorrents = true
    public var clearCompleted: ClearCompletedPolicy = .never
    // Schedule
    public var downloadHoursEnabled = false
    public var downloadHours = TimeWindow(startMinute: 60, endMinute: 480)
    public var keepAwakeForSchedule = true
    public var slowModeDownLimit: Int64 = 2_000_000
    public var slowModeUpLimit: Int64 = 500_000
    public var slowModeScheduled = false
    public var slowModeHours = TimeWindow(startMinute: 18 * 60, endMinute: 23 * 60)
    public var pauseOnBattery = false
    public var pauseOnExpensiveNetwork = false
    // Network
    public var downLimit: Int64? = nil
    public var upLimit: Int64? = nil
    public var maxConcurrent = 3
    public var connectionsPerServer = 16
    // BitTorrent
    public var afterDownload: SeedPolicy = .stop
    public var maxPeers = 55
    public var listenPort = 51413
    public var dht = true
    public var pex = true
    public var lpd = true
    public var preferEncryption = false
    public var extraTrackers = ""
    // Search. Optional so settings saved before these existed still decode; nil means the default.
    public var searchDisabledSources: [String]? = nil
    public var searchShowAdult: Bool? = nil
    // Engine
    public var advancedOptions = ""
    // First run
    public var welcomeDone = false

    public init() {}
}
