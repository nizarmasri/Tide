import Foundation

/// Semantic colours from DESIGN.md §9. The UI maps these to SwiftUI styles; `.accent` must map to
/// the tint (system accent, recolours under Graphite).
public enum StateTint: String, Sendable, Equatable {
    case accent, secondary, gray, orange, red, green, teal, indigo
}

/// The single trailing verb a row offers (DESIGN.md §7, "Row action").
public enum RowAction: Equatable, Sendable {
    case pause, resume, startNow, resumeAnyway, showInFinder, stopSharing
    case fix(FixAction)
    case none

    public var label: String {
        switch self {
        case .pause: return "Pause"
        case .resume: return "Resume"
        case .startNow: return "Start Now"
        case .resumeAnyway: return "Resume Anyway"
        case .showInFinder: return "Show in Finder"
        case .stopSharing: return "Stop Sharing"
        case .fix(let f): return f.label
        case .none: return ""
        }
    }

    public var symbol: String {
        switch self {
        case .pause: return "pause.fill"
        case .resume, .resumeAnyway, .startNow: return "play.fill"
        case .showInFinder: return "magnifyingglass"
        case .stopSharing: return "stop.fill"
        case .fix(let f): return f.symbol
        case .none: return ""
        }
    }
}

public extension FixAction {
    var label: String {
        switch self {
        case .retry: return "Retry"
        case .chooseFolder: return "Choose Folder…"
        case .resolve: return "Resolve…"
        case .copyLink: return "Copy Link"
        case .chooseAnotherFile: return "Choose Another File…"
        case .restartEngine: return "Restart Engine"
        }
    }
    var symbol: String {
        switch self {
        case .retry: return "arrow.clockwise"
        case .chooseFolder: return "folder"
        case .resolve: return "arrow.triangle.branch"
        case .copyLink: return "link"
        case .chooseAnotherFile: return "doc"
        case .restartEngine: return "arrow.clockwise"
        }
    }
}

/// Everything a row needs to draw a task, derived purely from the task (+ ETA + clock).
public struct TaskPresentation: Equatable, Sendable {
    public var symbol: String
    public var symbolTint: StateTint
    public var stateName: String
    /// nil = no bar (completed).
    public var barTint: StateTint?
    public var barValue: Double
    /// Popover/compact status line (≤ 45 chars, no final period). May contain ↓/↑, which the UI
    /// renders as SF Symbols.
    public var status: String
    /// Window row status line (sizes spelled out).
    public var detailStatus: String
    /// "18 seeds · 42 peers" for active torrents, else nil.
    public var peersLine: String?
    public var action: RowAction
    public var isError: Bool
    /// Non-downloading rows lead their status line with an 11pt state symbol.
    public var showsInlineSymbol: Bool {
        !(symbol == "arrow.down.circle.fill")
    }
    /// Spoken value for VoiceOver.
    public var accessibilityValue: String

    public init(task: DownloadTask, eta: Int?, now: Date = Date(), calendar: Calendar = .current) {
        let pct = TideFormat.percent(task.fraction)
        let speed = TideFormat.speed(task.downloadSpeed)
        let sizes = TideFormat.progress(task.completedBytes, of: task.totalBytes)
        let etaText = (task.downloadSpeed > 0 ? eta : nil).map { TideFormat.timeLeft($0) }
        let spokenPct = "\(Int((task.fraction * 100).rounded(.down))) percent"
        isError = false
        peersLine = nil

        switch task.phase {
        case .downloading:
            symbol = "arrow.down.circle.fill"; symbolTint = .accent; stateName = "Downloading"
            barTint = .accent; barValue = task.fraction
            if task.downloadSpeed > 0 {
                status = [pct, speed, etaText].compactMap { $0 }.joined(separator: " · ")
                detailStatus = [sizes, speed, etaText].compactMap { $0 }.joined(separator: " · ")
            } else {
                status = "Looking for peers · \(pct)"
                detailStatus = "Looking for peers · \(sizes)"
            }
            action = .pause
            var spoken = "Downloading, \(spokenPct)"
            if task.downloadSpeed > 0 { spoken += ", \(TideFormat.spokenSpeed(task.downloadSpeed))" }
            if let e = eta, task.downloadSpeed > 0 { spoken += ", about \(TideFormat.spokenDuration(e)) left" }
            accessibilityValue = spoken
        case .stalled:
            symbol = "arrow.down.circle.fill"; symbolTint = .accent; stateName = "Looking for Peers"
            barTint = .accent; barValue = task.fraction
            status = "Looking for peers · \(pct)"
            detailStatus = "Looking for peers · \(sizes)"
            action = .pause
            accessibilityValue = "Looking for peers, \(spokenPct)"
        case .resuming:
            symbol = "arrow.down.circle.fill"; symbolTint = .accent; stateName = "Continuing"
            barTint = .accent; barValue = task.fraction
            status = "Continuing from \(pct)"
            detailStatus = "Continuing from \(pct) · \(sizes)"
            action = .pause
            accessibilityValue = "Continuing from \(spokenPct)"
        case .fetchingMetadata(let peers):
            symbol = "arrow.down.circle.dotted"; symbolTint = .accent; stateName = "Getting File List"
            barTint = .accent; barValue = 0
            status = "Getting file list · \(peers) \(peers == 1 ? "peer" : "peers")"
            detailStatus = status
            action = .pause
            accessibilityValue = "Getting file list from \(peers) peers"
        case .queued(let position):
            symbol = "hourglass"; symbolTint = .secondary; stateName = "Queued"
            barTint = .gray; barValue = task.fraction
            status = "Queued · \(TideFormat.ordinal(position)) in line"
            detailStatus = "Queued · \(TideFormat.ordinal(position)) in line · \(sizes)"
            action = .startNow
            accessibilityValue = "Queued, \(TideFormat.ordinal(position)) in line, \(spokenPct)"
        case .paused:
            symbol = "pause.circle.fill"; symbolTint = .secondary; stateName = "Paused"
            barTint = .gray; barValue = task.fraction
            status = "Paused · \(sizes)"
            detailStatus = status
            action = .resume
            accessibilityValue = "Paused, \(spokenPct) of \(TideFormat.spokenBytes(task.totalBytes))"
        case .autoPaused(let reason):
            symbol = reason == .battery ? "battery.50percent" : "personalhotspot"
            symbolTint = .orange; stateName = "Paused Automatically"
            barTint = .gray; barValue = task.fraction
            let reasonText = reason == .battery ? "Paused on battery power" : "Paused on hotspot"
            status = "\(reasonText) · \(sizes)"
            detailStatus = status
            action = .resumeAnyway
            accessibilityValue = "\(reasonText), \(spokenPct)"
        case .scheduled(let date):
            symbol = "clock"; symbolTint = .secondary; stateName = "Scheduled"
            barTint = .gray; barValue = task.fraction
            let starts = TideFormat.startsAt(date, now: now, calendar: calendar)
            status = task.totalBytes > 0 ? "\(starts) · \(sizes)" : starts
            detailStatus = status
            action = .startNow
            accessibilityValue = starts
        case .checking(let progress, let secondsLeft):
            symbol = "doc.text.magnifyingglass"; symbolTint = .teal; stateName = "Checking Data"
            barTint = .teal; barValue = max(0, min(1, progress))
            var s = "Checking data · \(TideFormat.percent(progress))"
            if let l = secondsLeft { s += " · \(TideFormat.shortTimeLeft(l))" }
            status = s; detailStatus = s
            action = .none
            accessibilityValue = "Checking data, \(Int((progress * 100).rounded(.down))) percent"
        case .waitingForDrive(let volume):
            symbol = "externaldrive"; symbolTint = .orange; stateName = "Waiting for \(volume)"
            barTint = .gray; barValue = task.fraction
            status = "Waiting for \(volume) · \(sizes)"
            detailStatus = status
            action = .none
            accessibilityValue = "Waiting for \(volume), \(spokenPct)"
        case .waitingForNetwork:
            symbol = "wifi.slash"; symbolTint = .orange; stateName = "Waiting for Network"
            barTint = .gray; barValue = task.fraction
            status = "Waiting for network · \(sizes)"
            detailStatus = status
            action = .none
            accessibilityValue = "Waiting for network, \(spokenPct)"
        case .error(let problem):
            symbol = "exclamationmark.triangle.fill"; symbolTint = .red; stateName = "Stopped"
            barTint = .red; barValue = task.fraction
            status = problem.status
            detailStatus = problem.status
            action = .fix(problem.fix)
            isError = true
            accessibilityValue = "Stopped. \(problem.status)"
        case .completed(let at):
            symbol = "checkmark.circle.fill"; symbolTint = .green; stateName = "Downloaded"
            barTint = nil; barValue = 1
            status = "\(TideFormat.bytes(task.totalBytes)) · \(TideFormat.dayAndTime(task.completedAt ?? at, now: now, calendar: calendar))"
            detailStatus = status
            action = .showInFinder
            accessibilityValue = "Downloaded, \(TideFormat.spokenBytes(task.totalBytes))"
        case .seeding(let ratio, let target):
            symbol = "arrow.up.circle.fill"; symbolTint = .green; stateName = "Sharing"
            barTint = .green
            let r = String(format: "%.1f", ratio)
            if let t = target, t > 0 {
                barValue = min(1, ratio / t)
                status = "Seeding · ↑ \(TideFormat.speed(task.uploadSpeed)) · ratio \(r) of \(String(format: "%.1f", t))"
            } else {
                barValue = 1
                status = "Seeding · ↑ \(TideFormat.speed(task.uploadSpeed)) · ratio \(r)"
            }
            detailStatus = status
            action = .stopSharing
            accessibilityValue = "Sharing, uploading at \(TideFormat.spokenSpeed(task.uploadSpeed)), ratio \(r)"
        }

        if task.kind != .http, task.phase.isActive, task.peers + task.seeders > 0 {
            peersLine = "\(task.seeders) \(task.seeders == 1 ? "seed" : "seeds") · \(task.peers) \(task.peers == 1 ? "peer" : "peers")"
        }
    }
}

public extension DownloadTask {
    /// Remaining bytes ÷ speed (unsmoothed), nil when not moving.
    var rawETA: Int? {
        guard downloadSpeed > 0, totalBytes > completedBytes else { return nil }
        return Int((totalBytes - completedBytes) / downloadSpeed)
    }

    func presentation(eta: Int? = nil, now: Date = Date()) -> TaskPresentation {
        TaskPresentation(task: self, eta: eta ?? rawETA, now: now)
    }
}

public extension TaskPhase {
    /// One or two words for the 72pt compact-row column.
    var shortName: String {
        switch self {
        case .downloading: return "Starting"
        case .stalled: return "No peers"
        case .resuming: return "Resuming"
        case .fetchingMetadata: return "File list"
        case .queued(let n): return "Queued \(n)"
        case .paused: return "Paused"
        case .autoPaused(.battery): return "On battery"
        case .autoPaused(.expensiveNetwork): return "Hotspot"
        case .scheduled(let d): return TideFormat.time(d)
        case .checking: return "Checking"
        case .waitingForDrive: return "No drive"
        case .waitingForNetwork: return "Offline"
        case .error: return "Stopped"
        case .completed: return "Done"
        case .seeding: return "Sharing"
        }
    }
}
