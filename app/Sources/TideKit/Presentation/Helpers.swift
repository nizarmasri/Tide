import Foundation
import Observation

// MARK: - ETA smoothing

/// ETA from a 10 s exponential moving average of speed, published at most every 2 s
/// (DESIGN.md §9). Fed every snapshot by the app delegate.
@MainActor
@Observable
public final class EtaEstimator {
    public private(set) var etas: [TaskID: Int] = [:]
    @ObservationIgnored private var ema: [TaskID: Double] = [:]
    @ObservationIgnored private var lastSample: Date?
    @ObservationIgnored private var lastPublish: Date = .distantPast

    public init() {}

    public func ingest(_ snap: EngineSnapshot, now: Date = Date()) {
        let dt = lastSample.map { max(0.1, now.timeIntervalSince($0)) } ?? 10
        lastSample = now
        let alpha = 1 - exp(-dt / 10)
        var next: [TaskID: Double] = [:]
        for t in snap.tasks where t.phase.isActive {
            let s = Double(t.downloadSpeed)
            if let old = ema[t.id] { next[t.id] = old + alpha * (s - old) } else { next[t.id] = s }
        }
        ema = next
        guard now.timeIntervalSince(lastPublish) >= 2 || etas.isEmpty else { return }
        lastPublish = now
        var out: [TaskID: Int] = [:]
        for t in snap.tasks {
            guard let s = ema[t.id], s >= 1, t.totalBytes > t.completedBytes else { continue }
            out[t.id] = Int(Double(t.totalBytes - t.completedBytes) / s)
        }
        if out != etas { etas = out }
    }

    public func eta(_ task: DownloadTask) -> Int? {
        guard task.downloadSpeed > 0 else { return nil }
        return etas[task.id] ?? task.rawETA
    }
}

// MARK: - Input parsing (drops, paste, open)

public enum InputParser {
    static let linkPrefixes = ["magnet:", "http://", "https://", "ftp://", "sftp://"]

    public static func isLink(_ s: String) -> Bool {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return linkPrefixes.contains { t.hasPrefix($0) } && t.count > 10
    }

    /// One link per line; ignores anything that isn't a magnet or URL.
    public static func links(in text: String) -> [AddInput] {
        text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter(isLink)
            .map { AddInput.link($0) }
    }

    public static func input(for url: URL) -> AddInput? {
        if url.isFileURL {
            return url.pathExtension.lowercased() == "torrent" ? .torrentFile(url) : nil
        }
        let s = url.absoluteString
        return isLink(s) ? .link(s) : nil
    }

    public static func inputs(urls: [URL], strings: [String]) -> [AddInput] {
        var out: [AddInput] = urls.compactMap(input(for:))
        for s in strings { out += links(in: s) }
        var seen = Set<AddInput>()
        return out.filter { seen.insert($0).inserted }
    }
}

// MARK: - File tree

/// Folder/file tree built from torrent file paths, for the Add window and the Files inspector.
public struct FileNode: Identifiable, Equatable, Sendable {
    public var id: String          // full relative path
    public var name: String
    public var file: TaskFile?     // nil for folders
    public var children: [FileNode]

    public var isFolder: Bool { file == nil }

    public var totalBytes: Int64 {
        file?.length ?? children.reduce(0) { $0 + $1.totalBytes }
    }
    public var completedBytes: Int64 {
        file?.completedLength ?? children.reduce(0) { $0 + $1.completedBytes }
    }
    public var leafIndexes: [Int] {
        file.map { [$0.index] } ?? children.flatMap(\.leafIndexes)
    }

    public enum Check: Equatable, Sendable { case on, off, mixed }

    public func check(selected: Set<Int>) -> Check {
        let leaves = leafIndexes
        let n = leaves.filter(selected.contains).count
        if n == 0 { return .off }
        return n == leaves.count ? .on : .mixed
    }

    /// Builds the tree. A single top-level folder shared by every file (the torrent's name) is
    /// dropped, because the window already shows that name.
    public static func tree(_ files: [TaskFile]) -> [FileNode] {
        var comps = files.map { $0.path.split(separator: "/").map(String.init) }
        if files.count > 0, let first = comps.first?.first,
           comps.allSatisfy({ $0.count > 1 && $0.first == first }) {
            comps = comps.map { Array($0.dropFirst()) }
        }
        final class Box { var name: String; var path: String; var file: TaskFile?; var kids: [String: Box] = [:]; var order: [String] = []
            init(_ n: String, _ p: String) { name = n; path = p } }
        let root = Box("", "")
        for (f, parts) in zip(files, comps) {
            var node = root
            for (i, part) in parts.enumerated() {
                let path = node.path.isEmpty ? part : node.path + "/" + part
                if node.kids[part] == nil { node.kids[part] = Box(part, path); node.order.append(part) }
                node = node.kids[part]!
                if i == parts.count - 1 { node.file = f }
            }
        }
        func build(_ b: Box) -> [FileNode] {
            b.order.compactMap { b.kids[$0] }.map { k in
                FileNode(id: k.path, name: k.name, file: k.file, children: build(k))
            }.sorted { a, b in
                if a.isFolder != b.isFolder { return a.isFolder }
                return a.totalBytes > b.totalBytes
            }
        }
        return build(root)
    }
}

public extension FileTag {
    /// Capsule tag shown on junk rows; nil for videos and other files.
    var junkLabel: String? {
        switch self {
        case .sample: return "Sample"
        case .image: return "Image"
        case .text: return "Text"
        case .video, .other: return nil
        }
    }
}

public extension Array where Element == TaskFile {
    /// Indexes selected by "Videos Only".
    var videoIndexes: [Int] { filter { $0.tag == .video }.map(\.index) }
}

// MARK: - Schedule wording

public enum ScheduleText {
    static func clock(_ minute: Int, calendar: Calendar = .current) -> String {
        var c = DateComponents()
        c.hour = (minute / 60) % 24; c.minute = minute % 60
        let d = calendar.date(from: c) ?? Date()
        return TideFormat.time(d, calendar: calendar)
    }

    static func days(_ set: Set<Int>, calendar: Calendar = .current) -> String {
        if set.count == 7 { return "every day" }
        if set == Set(2...6) { return "on weekdays" }
        if set == [1, 7] { return "on weekends" }
        if set.isEmpty { return "on no days" }
        let symbols = calendar.shortWeekdaySymbols
        return "on " + set.sorted().map { symbols[$0 - 1] }.joined(separator: ", ")
    }

    /// "Downloads run 01:00–08:00 every day. Next window opens in 3 hr 12 min."
    public static func summary(enabled: Bool, window: TimeWindow, status: ScheduleStatus, now: Date = Date()) -> String {
        guard enabled else { return "Downloads run any time." }
        var s = "Downloads run \(clock(window.startMinute))–\(clock(window.endMinute)) \(days(window.weekdays))."
        switch status {
        case .outsideWindow(let start):
            let secs = Int(start.timeIntervalSince(now))
            if secs > 0 { s += " Next window opens in \(TideFormat.duration(secs))." }
        case .insideWindow(let end):
            let secs = Int(end.timeIntervalSince(now))
            if secs > 0 { s += " This window closes in \(TideFormat.duration(secs))." }
        case .anyTime: break
        }
        return s
    }

    /// Where `now` sits relative to the window: inside (closes at…) or outside (opens at…),
    /// honouring weekdays (a window belongs to the day it starts on) and midnight crossings.
    public static func status(_ w: TimeWindow, now: Date, calendar: Calendar = .current) -> ScheduleStatus {
        guard !w.weekdays.isEmpty else { return .anyTime }
        let duration = w.startMinute == w.endMinute ? 1440 : (w.endMinute - w.startMinute + 1440) % 1440
        let today = calendar.startOfDay(for: now)
        func start(_ dayOffset: Int) -> Date? {
            guard let day = calendar.date(byAdding: .day, value: dayOffset, to: today),
                  w.weekdays.contains(calendar.component(.weekday, from: day)) else { return nil }
            return calendar.date(byAdding: .minute, value: w.startMinute, to: day)
        }
        for offset in [-1, 0] {
            if let s = start(offset) {
                let e = s.addingTimeInterval(Double(duration) * 60)
                if s <= now && now < e { return .insideWindow(endsAt: e) }
            }
        }
        for offset in 0...7 {
            if let s = start(offset), s > now { return .outsideWindow(startsAt: s) }
        }
        return .anyTime
    }

    /// Whether `minute` (0…1439) falls inside the window on any day.
    public static func contains(_ w: TimeWindow, minute: Int) -> Bool {
        if w.startMinute == w.endMinute { return true }
        if w.startMinute < w.endMinute { return minute >= w.startMinute && minute < w.endMinute }
        return minute >= w.startMinute || minute < w.endMinute
    }
}
