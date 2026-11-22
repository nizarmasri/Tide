import Foundation

/// Extra canned data for the render matrix (DESIGN.md §12). Dates are relative to the real
/// clock so "Today at …" renders naturally.
public extension PreviewFixtures {
    private static let gbx: Int64 = 1_000_000_000

    /// Moves completion dates to "today" so rows read "Today at 07:42".
    static func todayDates(_ s: EngineSnapshot, now: Date = Date()) -> EngineSnapshot {
        var s = s
        for i in s.tasks.indices where s.tasks[i].phase.isFinished {
            let at = now.addingTimeInterval(-Double(7_200 + i * 1_800))
            s.tasks[i].completedAt = at
            if case .completed = s.tasks[i].phase { s.tasks[i].phase = .completed(at: at) }
        }
        return s
    }

    static var mixedToday: EngineSnapshot { todayDates(mixed) }

    private static func t(_ id: String, _ name: String, _ phase: TaskPhase, done: Double, total: Int64,
                          speed: Int64 = 0, kind: TaskKind = .torrent, seeds: Int = 0, peers: Int = 0) -> DownloadTask {
        DownloadTask(id: TaskID(id), name: name, kind: kind, phase: phase,
                     completedBytes: Int64(Double(total) * done), totalBytes: total, downloadSpeed: speed,
                     uploadSpeed: phase == .seeding(ratio: 0.4, target: 1.0) ? 1_200_000 : 0,
                     seeders: seeds, peers: peers, directory: movies, volumeName: "Media", volumeIsExternal: true,
                     addedAt: Date().addingTimeInterval(-3_600), completedAt: phase.isFinished ? Date().addingTimeInterval(-9_000) : nil,
                     magnetLink: kind == .http ? nil : "magnet:?xt=urn:btih:0", trackerCount: 12)
    }

    /// One task per state, for the state table review.
    static var allStates: EngineSnapshot {
        let now = Date()
        let tasks: [DownloadTask] = [
            t("s1", "Tears.of.Steel.2012.4K.HDR.mkv", .downloading, done: 0.34, total: 72 * gbx, speed: 24_600_000, seeds: 18, peers: 42),
            t("s2", "Spring.2019.4K.HDR.mkv", .stalled, done: 0.61, total: 58 * gbx),
            t("s3", "Elephants.Dream.2006.4K.mkv", .resuming, done: 0.34, total: 64 * gbx),
            t("s4", "Caminandes 3 Llamigos 2016 4K", .fetchingMetadata(peers: 6), done: 0, total: 0, kind: .magnet),
            t("s5", "Agent.327.2017.4K.mkv", .queued(position: 2), done: 0, total: 61 * gbx),
            t("s6", "ubuntu-26.04-desktop-arm64.iso", .paused, done: 0.2, total: 6_100_000_000, kind: .http),
            t("s7", "Sprite.Fright.2021.4K.mkv", .autoPaused(.battery), done: 0.12, total: 22 * gbx),
            t("s8", "Charge.2022.4K.mkv", .scheduled(startsAt: Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.date(bySettingHour: 1, minute: 0, second: 0, of: now)!)!), done: 0, total: 14 * gbx),
            t("s9", "Night.of.the.Living.Dead.1968.1080p.mkv", .checking(progress: 0.41, secondsLeft: 38), done: 0.41, total: 18 * gbx),
            t("s10", "Pioneer.One.S01.1080p", .waitingForDrive(volumeName: "Media"), done: 0.23, total: 41 * gbx),
            t("s11", "Metropolis.1927.1080p.mkv", .waitingForNetwork, done: 0.5, total: 9 * gbx),
            t("s12", "Cosmos.Laundromat.2015.4K.mkv",
              .error(TaskProblem(kind: .diskFull, status: "Not enough space on Media",
                                 explanation: "Media needs 44.9 GB more. Free up space, then try again.", fix: .retry)),
              done: 0.41, total: 76 * gbx),
            t("s13", "Sintel.2010.4K.mkv", .completed(at: now.addingTimeInterval(-9_000)), done: 1, total: 68_200_000_000),
            t("s14", "Big.Buck.Bunny.2008.2160p.60fps.mkv", .seeding(ratio: 0.4, target: 1.0), done: 1, total: 11 * gbx),
        ]
        return EngineSnapshot(tasks: tasks, downloadSpeed: 24_600_000, uploadSpeed: 1_200_000,
                              engine: .running(version: "1.37.0"), schedule: .anyTime,
                              defaultVolume: VolumeStatus(name: "Media", isExternal: true, isConnected: true, freeBytes: 412 * gbx))
    }

    /// Eight active rows (the popover scrolls after six).
    static var manyRows: EngineSnapshot {
        var s = allStates
        s.tasks = Array(s.tasks.prefix(9))
        return s
    }

    static var engineStopped: EngineSnapshot {
        var s = mixedToday
        s.engine = .stopped(reason: "The engine quit unexpectedly")
        s.tasks = s.tasks.map { var t = $0; if t.phase.isActive { t.phase = .paused; t.downloadSpeed = 0 }; return t }
        s.downloadSpeed = 0
        return s
    }

    static var onBattery: EngineSnapshot {
        var s = mixedToday
        s.autoPause = .battery
        s.tasks = s.tasks.map { var t = $0; if t.phase.isActive { t.phase = .autoPaused(.battery); t.downloadSpeed = 0 }; return t }
        s.downloadSpeed = 0
        return s
    }

    static var outsideHours: EngineSnapshot {
        let start = Calendar.current.date(bySettingHour: 1, minute: 0, second: 0, of: Date().addingTimeInterval(86_400))!
        var s = mixedToday
        s.schedule = .outsideWindow(startsAt: start)
        s.tasks = s.tasks.map { var t = $0; if !t.phase.isFinished, case .error = t.phase {} else if !t.phase.isFinished { t.phase = .scheduled(startsAt: start); t.downloadSpeed = 0 }; return t }
        s.downloadSpeed = 0
        return s
    }

    static var slowMode: EngineSnapshot {
        var s = mixedToday
        s.slowMode = true
        s.downloadSpeed = 2_000_000
        s.tasks = s.tasks.map { var t = $0; if t.phase == .downloading { t.downloadSpeed = 2_000_000 }; return t }
        return s
    }

    // MARK: Add previews

    static var duplicatePreview: AddPreview {
        var p = torrentPreview
        p.duplicateOf = movie.id
        return p
    }

    static var existingPreview: AddPreview {
        var p = torrentPreview
        p.existing = ExistingProgress(completedBytes: 24_918_237_184, fraction: 0.342)
        return p
    }

    static var unreadablePreview: AddPreview {
        AddPreview(input: .torrentFile(URL(fileURLWithPath: "/Users/me/Downloads/broken.torrent")), kind: .torrent,
                   name: "broken.torrent", totalBytes: nil, problem: .unreadableTorrent)
    }

    static var multiPreviews: [AddPreview] {
        let a = torrentPreview
        var b = magnetPreview
        b.metadataPending = false
        b.name = "Pioneer.One.S01.1080p.WEB"
        b.totalBytes = 41_200_000_000
        b.files = (1...10).map { i in
            TaskFile(index: i, path: "Pioneer.One.S01/Pioneer.One.S01E\(String(format: "%02d", i)).2160p.mkv",
                     length: 4_100_000_000, selected: true, tag: .video)
        } + [TaskFile(index: 11, path: "Pioneer.One.S01/Sample/sample.mkv", length: 80_000_000, selected: false, tag: .sample),
             TaskFile(index: 12, path: "Pioneer.One.S01/poster.jpg", length: 400_000, selected: false, tag: .image)]
        b.smart = SmartSummary(skippedCount: 2, skippedBytes: 80_400_000, skippedDescription: "sample, 1 image")
        let c = urlPreview
        return [a, b, c]
    }

    // MARK: Import variants

    /// The sample import, saved "2 days ago" relative to now.
    static var movieImportRecent: ImportCandidate {
        var c = movieImport
        c.progressSavedAt = Date().addingTimeInterval(-2 * 86_400 - 3_600)
        return c
    }

    static var importMissingProgress: ImportCandidate {
        var c = movieImportRecent
        c.progressFile = nil
        c.progressSavedAt = nil
        c.pieces = nil
        c.needsCheck = true
        c.estimatedCheckSeconds = 40
        c.completedBytes = 0
        return c
    }

    static var importSeveral: [ImportCandidate] {
        var b = movieImport
        b.id = "other"
        b.name = "Spring.2019.4K.HDR"
        b.totalBytes = 58_000_000_000
        b.completedBytes = 35_400_000_000
        var c = movieImport
        c.id = "third"
        c.name = "Agent.327.2017.4K"
        c.totalBytes = 61_000_000_000
        c.completedBytes = 3_100_000_000
        return [movieImportRecent, b, c]
    }
}
