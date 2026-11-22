import Foundation

/// Popover header, window subtitle and other aggregate text (DESIGN.md §4, §5).
public struct SnapshotSummary: Equatable, Sendable {
    public var headline: String
    public var subline: String
    /// True when the go/stop toggle should read "Pause All".
    public var showsPauseAll: Bool
    /// Label for the go button when nothing is moving: "Resume All" or "Start Now".
    public var goLabel: String
    public var isEmpty: Bool

    public init(_ snap: EngineSnapshot, etas: [TaskID: Int] = [:], now: Date = Date(), calendar: Calendar = .current) {
        let incomplete = snap.inProgress
        let moving = incomplete.filter { $0.phase.isActive }
        let downloading = incomplete.filter {
            switch $0.phase { case .downloading, .stalled, .resuming, .fetchingMetadata: return true; default: return false }
        }
        let errors = incomplete.filter { if case .error = $0.phase { return true }; return false }
        let paused = incomplete.filter {
            switch $0.phase { case .paused, .autoPaused: return true; default: return false }
        }
        let waitingDrive = incomplete.compactMap { t -> String? in
            if case .waitingForDrive(let v) = t.phase { return v }; return nil
        }
        let scheduledTasks = incomplete.filter { if case .scheduled = $0.phase { return true }; return false }

        isEmpty = snap.tasks.isEmpty
        showsPauseAll = !moving.isEmpty
        if case .outsideWindow = snap.schedule { goLabel = "Start Now" } else { goLabel = "Resume All" }

        // Line 1
        if isEmpty {
            headline = "Downloads"
        } else if !moving.isEmpty {
            if snap.downloadSpeed > 0 {
                headline = TideFormat.speed(snap.downloadSpeed)
            } else if moving.contains(where: { if case .checking = $0.phase { return true }; return false }) {
                headline = "Checking Data"
            } else {
                headline = "Looking for Peers"
            }
        } else if case .outsideWindow(let start) = snap.schedule, !incomplete.isEmpty {
            headline = TideFormat.startsAt(start, now: now, calendar: calendar)
        } else if !waitingDrive.isEmpty, waitingDrive.count == incomplete.count {
            headline = "Waiting for \(waitingDrive[0])"
        } else if !errors.isEmpty, errors.count == incomplete.count {
            headline = errors.count == 1 ? "1 Problem" : "\(errors.count) Problems"
        } else if !paused.isEmpty {
            headline = "Paused"
        } else if let first = scheduledTasks.first, case .scheduled(let at) = first.phase {
            headline = TideFormat.startsAt(at, now: now, calendar: calendar)
        } else if incomplete.isEmpty {
            headline = "All Done"
        } else if !waitingDrive.isEmpty {
            headline = "Waiting for \(waitingDrive[0])"
        } else {
            headline = "Waiting"
        }

        // Line 2
        var parts: [String] = []
        if isEmpty {
            parts.append("Drop a torrent, magnet link or URL here")
        } else if !downloading.isEmpty {
            parts.append("\(downloading.count) downloading")
            let remaining = downloading.compactMap { etas[$0.id] ?? $0.rawETA }.max()
            if let r = remaining, snap.downloadSpeed > 0 { parts.append("done in \(TideFormat.duration(r))") }
        } else if !moving.isEmpty {
            parts.append("\(moving.count) checking")
        } else if incomplete.isEmpty {
            let today = snap.finished.filter { calendar.isDate($0.completedAt ?? .distantPast, inSameDayAs: now) }
            parts.append(today.isEmpty ? "Nothing in progress" : "\(today.count) finished today")
        } else {
            if !paused.isEmpty { parts.append("\(paused.count) paused") }
            if !waitingDrive.isEmpty { parts.append("\(waitingDrive.count) waiting for \(waitingDrive[0])") }
            if !errors.isEmpty { parts.append("\(errors.count) stopped") }
            let queued = incomplete.count - paused.count - waitingDrive.count - errors.count
            if queued > 0 {
                if case .outsideWindow(let start) = snap.schedule {
                    let secs = Int(start.timeIntervalSince(now))
                    parts.append(secs > 60 ? "Next window opens in \(TideFormat.duration(secs))" : "\(queued) waiting")
                } else {
                    parts.append("\(queued) waiting")
                }
            }
        }
        if snap.slowMode { parts.append("Slow Mode") }
        subline = parts.joined(separator: " · ")
    }
}

public enum WindowSubtitle {
    /// "2 downloading · 24.6 MB/s · ↑ 1.2 MB/s · Slow Mode"
    public static func text(_ snap: EngineSnapshot) -> String {
        let incomplete = snap.inProgress
        let downloading = incomplete.filter { $0.phase.isActive }.count
        var parts: [String] = []
        if downloading > 0 {
            parts.append("\(downloading) downloading")
            parts.append(TideFormat.speed(snap.downloadSpeed))
        } else if incomplete.isEmpty {
            parts.append(snap.tasks.isEmpty ? "No downloads" : "All done")
        } else {
            parts.append("\(incomplete.count) waiting")
        }
        if snap.uploadSpeed > 0 { parts.append("↑ \(TideFormat.speed(snap.uploadSpeed))") }
        if snap.slowMode { parts.append("Slow Mode") }
        return parts.joined(separator: " · ")
    }
}

// MARK: - Menu bar glyph

public enum GlyphCenter: String, Sendable, CaseIterable {
    case arrow, exclamation, dots, clock, pause, check, idle
}

/// What the 18×18 template status item shows (DESIGN.md §3).
public struct MenuBarGlyph: Equatable, Sendable {
    public var center: GlyphCenter
    /// Ring arc 0…1, nil = full ring (idle).
    public var progress: Double?
    public var attention: Bool
    /// Speed text shown left of the glyph, nil = hidden.
    public var speedText: String?

    public init(center: GlyphCenter, progress: Double?, attention: Bool, speedText: String?) {
        self.center = center; self.progress = progress; self.attention = attention; self.speedText = speedText
    }

    /// Derives the glyph. `justCompleted` is true for 4 s after a completion.
    public init(_ snap: EngineSnapshot, showSpeed: Bool, justCompleted: Bool) {
        let incomplete = snap.inProgress
        let anyMoving = incomplete.contains { $0.phase.isActive }
        let anyError = incomplete.contains { if case .error = $0.phase { return true }; return false }
        let anyWaiting = incomplete.contains {
            switch $0.phase { case .waitingForDrive, .waitingForNetwork: return true; default: return false }
        }
        let anyScheduled = incomplete.contains { if case .scheduled = $0.phase { return true }; return false }
            || { if case .outsideWindow = snap.schedule { return !incomplete.isEmpty }; return false }()
        let anyPaused = incomplete.contains {
            switch $0.phase { case .paused, .autoPaused: return true; default: return false }
        }

        if anyMoving { center = .arrow }
        else if anyError { center = .exclamation }
        else if anyWaiting { center = .dots }
        else if anyScheduled { center = .clock }
        else if anyPaused { center = .pause }
        else if justCompleted { center = .check }
        else { center = .idle }

        if incomplete.isEmpty {
            progress = nil
        } else {
            let total = incomplete.reduce(Int64(0)) { $0 + $1.totalBytes }
            let done = incomplete.reduce(Int64(0)) { $0 + min($1.completedBytes, $1.totalBytes) }
            let p = total > 0 ? Double(done) / Double(total) : 0
            // Quantise to 2% so the item only redraws on visible change.
            progress = (p * 50).rounded(.down) / 50
        }
        attention = anyError && center != .exclamation
        speedText = (showSpeed && anyMoving && snap.downloadSpeed > 0) ? TideFormat.speed(snap.downloadSpeed) : nil
    }

    /// VoiceOver value for the status item: "2 downloading, 34 percent".
    public static func accessibilityValue(_ snap: EngineSnapshot) -> String {
        let incomplete = snap.inProgress
        let moving = incomplete.filter { $0.phase.isActive }.count
        if incomplete.isEmpty { return snap.tasks.isEmpty ? "No downloads" : "All downloads finished" }
        let total = incomplete.reduce(Int64(0)) { $0 + $1.totalBytes }
        let done = incomplete.reduce(Int64(0)) { $0 + $1.completedBytes }
        let pct = total > 0 ? Int(Double(done) / Double(total) * 100) : 0
        return moving > 0 ? "\(moving) downloading, \(pct) percent" : "\(incomplete.count) waiting, \(pct) percent"
    }
}

// MARK: - Popover banner

public enum PopoverBanner: Equatable, Sendable {
    case engineStopped
    case autoPaused(AutoPauseReason)
    case clipboardLink

    /// Highest-priority banner, or nil.
    public static func pick(_ snap: EngineSnapshot, clipboardHasLink: Bool) -> PopoverBanner? {
        if case .stopped = snap.engine { return .engineStopped }
        if let r = snap.autoPause { return .autoPaused(r) }
        if clipboardHasLink { return .clipboardLink }
        return nil
    }

    public var text: String {
        switch self {
        case .engineStopped: return "Download engine stopped"
        case .autoPaused(.battery): return "Paused on battery power"
        case .autoPaused(.expensiveNetwork): return "Paused on hotspot"
        case .clipboardLink: return "Link on clipboard"
        }
    }
    public var actionTitle: String {
        switch self {
        case .engineStopped: return "Restart"
        case .autoPaused: return "Resume Anyway"
        case .clipboardLink: return "Add"
        }
    }
    public var symbol: String {
        switch self {
        case .engineStopped: return "exclamationmark.triangle.fill"
        case .autoPaused(.battery): return "battery.50percent"
        case .autoPaused(.expensiveNetwork): return "personalhotspot"
        case .clipboardLink: return "doc.on.clipboard"
        }
    }
    public var tint: StateTint {
        switch self {
        case .engineStopped: return .red
        case .autoPaused: return .orange
        case .clipboardLink: return .accent
        }
    }
}
