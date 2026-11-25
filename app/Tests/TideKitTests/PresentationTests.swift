import XCTest
@testable import TideKit

final class FormatTests: XCTestCase {
    private func dec(_ s: String) -> String { s.replacingOccurrences(of: ",", with: ".") } // locale-agnostic

    func testBytesThreeSignificantDigits() {
        XCTAssertEqual(dec(TideFormat.bytes(68_200_000_000)), "68.2 GB")
        XCTAssertEqual(TideFormat.bytes(412_000_000_000), "412 GB")
        XCTAssertEqual(dec(TideFormat.bytes(1_210_000_000_000)), "1.21 TB")
        XCTAssertEqual(dec(TideFormat.bytes(6_100_000_000)), "6.1 GB")
        XCTAssertEqual(TideFormat.bytes(38), "38 bytes")
        XCTAssertEqual(TideFormat.bytes(999_600), "1 MB")
    }

    func testSpeed() {
        XCTAssertEqual(dec(TideFormat.speed(24_600_000)), "24.6 MB/s")
        XCTAssertEqual(TideFormat.speed(512_000), "512 KB/s")
        XCTAssertEqual(TideFormat.speed(0), "0 KB/s")
    }

    func testProgressPairsShareUnitAndDecimals() {
        XCTAssertEqual(dec(TideFormat.progress(23_200_000_000, of: 68_200_000_000)), "23.2 of 68.2 GB")
        XCTAssertEqual(dec(TideFormat.progress(9_430_000_000, of: 41_000_000_000)), "9.4 of 41.0 GB")
        XCTAssertEqual(dec(TideFormat.progress(1_220_000_000, of: 6_100_000_000)), "1.2 of 6.1 GB")
        XCTAssertEqual(dec(TideFormat.progress(4_500_000_000, of: 9_000_000_000)), "4.5 of 9.0 GB")
        XCTAssertEqual(dec(TideFormat.progress(512_000_000, of: 68_200_000_000)), "0.5 of 68.2 GB")
        XCTAssertEqual(TideFormat.progress(45_600_000_000, of: 412_000_000_000), "45 of 412 GB")
        XCTAssertEqual(TideFormat.progress(0, of: 61_000_000_000), "61 GB")
        // The done side never rounds up to the total.
        XCTAssertEqual(dec(TideFormat.progress(68_190_000_000, of: 68_200_000_000)), "68.1 of 68.2 GB")
    }

    /// 0.8% of 8 GB used to read "0.0 of 8.0 GB", as if nothing had arrived.
    func testProgressNeverReadsZeroWhileDataExists() {
        XCTAssertEqual(dec(TideFormat.progress(64_100_000, of: 8_000_000_000)), "64.1 MB of 8.0 GB")
        XCTAssertEqual(dec(TideFormat.progress(99_000_000, of: 8_000_000_000)), "99 MB of 8.0 GB")
        XCTAssertEqual(dec(TideFormat.progress(100_000_000, of: 8_000_000_000)), "0.1 of 8.0 GB")
        XCTAssertEqual(dec(TideFormat.progress(1_500, of: 8_000_000_000)), "1.5 KB of 8.0 GB")
        // No decimals at 100 or above: anything under 1 GB gets its own unit.
        XCTAssertEqual(TideFormat.progress(400_000_000, of: 412_000_000_000), "400 MB of 412 GB")
        XCTAssertEqual(TideFormat.progress(1_000_000_000, of: 412_000_000_000), "1 of 412 GB")
    }

    func testBreakableInsertsZeroWidthSpaces() {
        let b = TideFormat.breakable("A.B-C_D")
        XCTAssertEqual(b, "A.\u{200B}B-\u{200B}C_\u{200B}D")
        XCTAssertEqual(b.replacingOccurrences(of: "\u{200B}", with: ""), "A.B-C_D")
    }

    func testPercentNeverRoundsUpTo100() {
        XCTAssertEqual(TideFormat.percent(0.342), "34%")
        XCTAssertEqual(TideFormat.percent(0.9999), "99%")
        XCTAssertEqual(dec(TideFormat.precisePercent(0.3429)), "34.2%")
    }

    func testDurations() {
        XCTAssertEqual(TideFormat.duration(30), "Less than a minute")
        XCTAssertEqual(TideFormat.duration(5 * 60), "5 min")
        XCTAssertEqual(TideFormat.duration(72 * 60), "1 hr 12 min")
        XCTAssertEqual(TideFormat.duration(2 * 3600), "2 hr")
        XCTAssertEqual(TideFormat.duration(28 * 3600), "1 day 4 hr")
        XCTAssertEqual(TideFormat.duration(3 * 86_400), "3 days")
        XCTAssertEqual(TideFormat.shortTimeLeft(38), "38 sec left")
    }

    func testShortName() {
        let s = TideFormat.shortName("The.Movie.2024.2160p.UHD.BluRay.REMUX.HDR.HEVC.Atmos.mkv", max: 24)
        XCTAssertEqual(s.count, 24)
        XCTAssertTrue(s.contains("…"))
        XCTAssertTrue(s.hasSuffix(".mkv"))
    }
}

final class StatePresentationTests: XCTestCase {
    private let dir = URL(fileURLWithPath: "/Volumes/Media/Movies")

    private func task(_ phase: TaskPhase, speed: Int64 = 0) -> DownloadTask {
        DownloadTask(id: TaskID("t"), name: "A.mkv", kind: .torrent, phase: phase, completedBytes: 34,
                     totalBytes: 100, downloadSpeed: speed, seeders: 3, peers: 9, directory: dir,
                     volumeName: "Media", volumeIsExternal: true)
    }

    func testEveryStateHasDistinctSymbolOrTint() {
        let phases: [TaskPhase] = [
            .downloading, .fetchingMetadata(peers: 1), .queued(position: 2), .paused, .autoPaused(.battery),
            .autoPaused(.expensiveNetwork), .scheduled(startsAt: Date()), .checking(progress: 0.4, secondsLeft: 5),
            .waitingForDrive(volumeName: "Media"), .waitingForNetwork,
            .error(TaskProblem(kind: .diskFull, status: "Not enough space on Media", fix: .retry)),
            .completed(at: Date()), .seeding(ratio: 0.4, target: 1),
        ]
        let keys = phases.map { p -> String in let x = task(p).presentation(); return "\(x.symbol)|\(x.symbolTint)" }
        XCTAssertEqual(Set(keys).count, keys.count, "states must be distinguishable: \(keys)")
    }

    func testDownloadingStatus() {
        let p = task(.downloading, speed: 1).presentation(eta: 4_320)
        XCTAssertTrue(p.status.hasPrefix("34% · "))
        XCTAssertTrue(p.status.hasSuffix("1 hr 12 min left"))
        XCTAssertEqual(p.action, .pause)
        XCTAssertEqual(p.peersLine, "3 seeds · 9 peers")
    }

    func testNoETAWhenNotMoving() {
        let p = task(.downloading, speed: 0).presentation(eta: 100)
        XCTAssertEqual(p.status, "Looking for peers · 34%")
    }

    func testStateComesFirst() {
        let t = DownloadTask(id: TaskID("p"), name: "u.iso", kind: .http, phase: .paused, completedBytes: 1_220_000_000,
                             totalBytes: 6_100_000_000, directory: dir, volumeName: "Mac")
        XCTAssertEqual(t.presentation().status.replacingOccurrences(of: ",", with: "."), "Paused · 1.2 of 6.1 GB")
        XCTAssertFalse(task(.downloading, speed: 1).presentation().showsInlineSymbol)
        XCTAssertTrue(task(.queued(position: 2)).presentation().showsInlineSymbol)
    }

    func testWaitingForDriveNamesVolumeAndKeepsProgress() {
        let p = task(.waitingForDrive(volumeName: "Media")).presentation()
        XCTAssertTrue(p.status.hasPrefix("Waiting for Media · "))
        XCTAssertTrue(p.showsInlineSymbol)
        XCTAssertEqual(p.barValue, 0.34, accuracy: 0.001)
        XCTAssertEqual(p.action, .none)
    }

    func testErrorUsesPlainReasonAndOneFix() {
        let prob = TaskProblem(kind: .diskFull, status: "Not enough space on Media", fix: .retry)
        let p = task(.error(prob)).presentation()
        XCTAssertTrue(p.isError)
        XCTAssertEqual(p.status, "Not enough space on Media")
        XCTAssertLessThanOrEqual(p.status.count, 45)
        XCTAssertEqual(p.action, .fix(.retry))
    }

    func testCompletedHasNoBar() {
        let p = task(.completed(at: Date())).presentation()
        XCTAssertNil(p.barTint)
        XCTAssertEqual(p.action, .showInFinder)
    }

    func testStatusLinesStayShort() {
        for t in PreviewFixtures.allStates.tasks {
            XCTAssertLessThanOrEqual(t.presentation(eta: 4_320).status.count, 45, t.name)
        }
    }
}

final class GlyphTests: XCTestCase {
    func testPriority() {
        var s = PreviewFixtures.mixed
        XCTAssertEqual(MenuBarGlyph(s, showSpeed: false, justCompleted: false).center, .arrow)
        XCTAssertTrue(MenuBarGlyph(s, showSpeed: false, justCompleted: false).attention) // error + moving

        s.tasks = s.tasks.map { var t = $0; if t.phase.isActive { t.phase = .paused }; return t }
        XCTAssertEqual(MenuBarGlyph(s, showSpeed: false, justCompleted: false).center, .exclamation)

        s.tasks.removeAll { if case .error = $0.phase { return true }; return false }
        XCTAssertEqual(MenuBarGlyph(s, showSpeed: false, justCompleted: false).center, .dots)

        s.tasks.removeAll { if case .waitingForDrive = $0.phase { return true }; return false }
        XCTAssertEqual(MenuBarGlyph(s, showSpeed: false, justCompleted: false).center, .pause)

        s.tasks.removeAll { !$0.phase.isFinished }
        XCTAssertEqual(MenuBarGlyph(s, showSpeed: false, justCompleted: true).center, .check)
        let idle = MenuBarGlyph(s, showSpeed: false, justCompleted: false)
        XCTAssertEqual(idle.center, .idle)
        XCTAssertNil(idle.progress)
    }

    func testProgressQuantisedTo2Percent() {
        let g = MenuBarGlyph(PreviewFixtures.mixed, showSpeed: true, justCompleted: false)
        let p = try! XCTUnwrap(g.progress)
        XCTAssertEqual((p * 50).rounded(), p * 50, accuracy: 1e-9)
        XCTAssertNotNil(g.speedText)
    }

    func testSpeedTextOffByDefault() {
        XCTAssertNil(MenuBarGlyph(PreviewFixtures.mixed, showSpeed: false, justCompleted: false).speedText)
    }
}

final class SummaryTests: XCTestCase {
    func testHeadlineStates() {
        XCTAssertEqual(SnapshotSummary(PreviewFixtures.empty).headline, "Downloads")
        XCTAssertTrue(SnapshotSummary(PreviewFixtures.mixed).showsPauseAll)
        XCTAssertEqual(SnapshotSummary(PreviewFixtures.onBattery).headline, "Paused")
        let outside = SnapshotSummary(PreviewFixtures.outsideHours)
        XCTAssertTrue(outside.headline.hasPrefix("Starts"))
        XCTAssertEqual(outside.goLabel, "Start Now")
        XCTAssertTrue(SnapshotSummary(PreviewFixtures.slowMode).subline.hasSuffix("Slow Mode"))
    }

    func testBannerPriority() {
        XCTAssertEqual(PopoverBanner.pick(PreviewFixtures.engineStopped, clipboardHasLink: true), .engineStopped)
        XCTAssertEqual(PopoverBanner.pick(PreviewFixtures.onBattery, clipboardHasLink: true), .autoPaused(.battery))
        XCTAssertEqual(PopoverBanner.pick(PreviewFixtures.mixed, clipboardHasLink: true), .clipboardLink)
        XCTAssertNil(PopoverBanner.pick(PreviewFixtures.mixed, clipboardHasLink: false))
    }
}

final class InputParserTests: XCTestCase {
    func testLinksPerLine() {
        let text = "magnet:?xt=urn:btih:ABC123456\n  https://example.com/a.iso \nnot a link\nftp://host/file"
        XCTAssertEqual(InputParser.links(in: text).count, 3)
    }

    func testTorrentFilesAndDedup() {
        let f = URL(fileURLWithPath: "/tmp/x.torrent")
        let inputs = InputParser.inputs(urls: [f, f, URL(fileURLWithPath: "/tmp/readme.txt")], strings: [])
        XCTAssertEqual(inputs, [.torrentFile(f)])
    }
}

final class FileTreeTests: XCTestCase {
    func testDropsSharedRootAndSortsBySize() {
        let tree = FileNode.tree(PreviewFixtures.movieFiles)
        XCTAssertEqual(tree.count, 5)
        XCTAssertEqual(tree.first?.file?.index, 1)
        XCTAssertFalse(tree.contains { $0.isFolder })
    }

    func testTriState() {
        let files = [
            TaskFile(index: 1, path: "S/E1.mkv", length: 10, selected: true, tag: .video),
            TaskFile(index: 2, path: "S/Extras/a.jpg", length: 1, selected: false, tag: .image),
            TaskFile(index: 3, path: "S/Extras/b.txt", length: 1, selected: false, tag: .text),
            TaskFile(index: 4, path: "T/c.mkv", length: 5, selected: true, tag: .video),
        ]
        let tree = FileNode.tree(files)
        let s = tree.first { $0.name == "S" }!
        XCTAssertEqual(s.check(selected: [1]), .mixed)
        XCTAssertEqual(s.check(selected: [1, 2, 3]), .on)
        XCTAssertEqual(s.check(selected: [4]), .off)
        XCTAssertEqual(files.videoIndexes, [1, 4])
    }
}

final class ScheduleTextTests: XCTestCase {
    func testContainsAcrossMidnight() {
        let w = TimeWindow(startMinute: 22 * 60, endMinute: 6 * 60)
        XCTAssertTrue(ScheduleText.contains(w, minute: 23 * 60))
        XCTAssertTrue(ScheduleText.contains(w, minute: 60))
        XCTAssertFalse(ScheduleText.contains(w, minute: 12 * 60))
    }

    func testStatusInsideAndOutside() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let w = TimeWindow(startMinute: 60, endMinute: 480)
        let noon = cal.date(from: DateComponents(year: 2026, month: 11, day: 22, hour: 12))!
        guard case .outsideWindow(let opens) = ScheduleText.status(w, now: noon, calendar: cal) else { return XCTFail() }
        XCTAssertEqual(opens.timeIntervalSince(noon), 13 * 3600)
        let two = cal.date(from: DateComponents(year: 2026, month: 11, day: 22, hour: 2))!
        guard case .insideWindow(let closes) = ScheduleText.status(w, now: two, calendar: cal) else { return XCTFail() }
        XCTAssertEqual(closes.timeIntervalSince(two), 6 * 3600)
        // Crossing midnight: 22:00–06:00 started yesterday is still open at 03:00.
        let night = TimeWindow(startMinute: 22 * 60, endMinute: 6 * 60)
        let three = cal.date(from: DateComponents(year: 2026, month: 11, day: 22, hour: 3))!
        guard case .insideWindow = ScheduleText.status(night, now: three, calendar: cal) else { return XCTFail() }
        let s = ScheduleText.summary(enabled: true, window: w, status: ScheduleText.status(w, now: noon, calendar: cal), now: noon)
        XCTAssertTrue(s.hasSuffix("Next window opens in 13 hr."), s)
    }

    func testSummary() {
        XCTAssertEqual(ScheduleText.summary(enabled: false, window: TimeWindow(startMinute: 0, endMinute: 60), status: .anyTime),
                       "Downloads run any time.")
        let s = ScheduleText.summary(enabled: true, window: TimeWindow(startMinute: 60, endMinute: 480), status: .anyTime)
        XCTAssertTrue(s.hasPrefix("Downloads run "))
        XCTAssertTrue(s.hasSuffix("every day."))
    }
}

@MainActor
final class EtaEstimatorTests: XCTestCase {
    func testSmoothsAndThrottles() {
        let e = EtaEstimator()
        var snap = PreviewFixtures.mixed
        let t0 = Date()
        e.ingest(snap, now: t0)
        let first = e.etas[PreviewFixtures.movie.id]
        XCTAssertNotNil(first)
        // A speed spike one second later is smoothed and not yet published (≤ every 2 s).
        snap.tasks[0].downloadSpeed *= 10
        e.ingest(snap, now: t0.addingTimeInterval(1))
        XCTAssertEqual(e.etas[PreviewFixtures.movie.id], first)
        e.ingest(snap, now: t0.addingTimeInterval(3))
        let later = try! XCTUnwrap(e.etas[PreviewFixtures.movie.id])
        XCTAssertLessThan(later, first!)
        XCTAssertGreaterThan(later, first! / 10)
    }
}
