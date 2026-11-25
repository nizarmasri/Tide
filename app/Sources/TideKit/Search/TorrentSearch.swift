import Foundation
import Observation

/// Runs a search across the enabled sources and holds the merged results. One lives per Search
/// window; nothing here runs until the user presses Return.
@MainActor
@Observable
public final class TorrentSearch {
    public enum Phase: Equatable, Sendable { case idle, searching, done }

    public private(set) var phase: Phase = .idle
    /// The query the current results are for.
    public private(set) var query = ""
    public private(set) var results: [SearchResult] = []
    /// The sources this search used, and the ones that gave nothing back.
    public private(set) var searched: [SearchSourceID] = []
    public private(set) var failures: [SearchSourceID: SearchFailure] = [:]

    @ObservationIgnored private let transport: HTTPTransport
    @ObservationIgnored private let deadline: Duration
    @ObservationIgnored private let now: @Sendable () -> Date
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var cache: [String: CacheEntry] = [:]
    @ObservationIgnored private var limitedUntil: [SearchSourceID: Date] = [:]

    private struct CacheEntry {
        var at: Date
        var hits: [SearchHit]
        var failures: [SearchSourceID: SearchFailure]
    }
    nonisolated static let cacheLife: TimeInterval = 15 * 60
    nonisolated static let cacheSize = 10

    /// `deadline` caps each source, retry included.
    public init(transport: @escaping HTTPTransport = SearchHTTP.live, deadline: Duration = .seconds(6),
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.transport = transport
        self.deadline = deadline
        self.now = now
    }

    public func search(_ text: String, sources: [SearchSourceID], showAdult: Bool) {
        task?.cancel()
        let q = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { clear(); return }
        let sources = SearchSourceID.allCases.filter(sources.contains)
        query = q
        searched = sources

        let key = "\(showAdult ? 1 : 0)|\(sources.map(\.rawValue).joined(separator: ","))|\(q.lowercased())"
        let start = now()
        if let c = cache[key], start.timeIntervalSince(c.at) < Self.cacheLife {
            publish(hits: c.hits, failures: c.failures, showAdult: showAdult)
            return
        }

        var skipped: [SearchSourceID: SearchFailure] = [:]
        var asked: [SearchSourceID] = []
        for s in sources {
            if let until = limitedUntil[s], until > start { skipped[s] = .rateLimited } else { asked.append(s) }
        }
        phase = .searching

        let transport = self.transport, deadline = self.deadline
        task = Task { [weak self] in
            let outcomes = await withTaskGroup(of: (SearchSourceID, SourceOutcome).self) { group in
                for s in asked {
                    group.addTask {
                        (s, await TorrentSearch.fetch(TorrentIndexes.index(s), query: q, adult: showAdult,
                                                      transport: transport, deadline: deadline))
                    }
                }
                var all: [(SearchSourceID, SourceOutcome)] = []
                for await o in group { all.append(o) }
                return all
            }
            guard !Task.isCancelled, let self else { return }
            self.finish(outcomes, skipped: skipped, key: key, at: start, showAdult: showAdult)
        }
    }

    /// Stops a search in progress.
    public func cancel() {
        task?.cancel()
        task = nil
        if phase == .searching { phase = results.isEmpty && failures.isEmpty ? .idle : .done }
    }

    public func clear() {
        task?.cancel()
        task = nil
        phase = .idle
        query = ""
        results = []
        searched = []
        failures = [:]
    }

    /// Waits for the current search (tests).
    public func wait() async { await task?.value }

    private func finish(_ outcomes: [(SearchSourceID, SourceOutcome)], skipped: [SearchSourceID: SearchFailure],
                        key: String, at: Date, showAdult: Bool) {
        var failures = skipped
        var hits: [SearchHit] = []
        for (s, o) in outcomes.sorted(by: { $0.0.priority < $1.0.priority }) {
            hits += o.hits
            if let f = o.failure { failures[s] = f }
            if let until = o.limitedUntil { limitedUntil[s] = until }
        }
        // Only complete answers are cached: pressing Return again must re-ask a source that failed.
        // (A rate-limited source is skipped until its reset either way.)
        if failures.values.allSatisfy({ $0 == .rateLimited }) {
            cache[key] = CacheEntry(at: at, hits: hits, failures: failures)
            if cache.count > Self.cacheSize, let oldest = cache.min(by: { $0.value.at < $1.value.at })?.key {
                cache[oldest] = nil
            }
        }
        publish(hits: hits, failures: failures, showAdult: showAdult)
    }

    private func publish(hits: [SearchHit], failures: [SearchSourceID: SearchFailure], showAdult: Bool) {
        results = SearchMerger.merge(hits, showAdult: showAdult)
        self.failures = failures
        phase = .done
    }

    // MARK: One source

    struct SourceOutcome: Sendable {
        var hits: [SearchHit] = []
        var failure: SearchFailure?
        /// Set when the source says its allowance is used up.
        var limitedUntil: Date?
    }

    nonisolated static func fetch(_ index: any TorrentIndex, query: String, adult: Bool,
                                  transport: @escaping HTTPTransport, deadline: Duration) async -> SourceOutcome {
        do {
            return try await withDeadline(deadline) {
                var retried = false
                while true {
                    let resp = try await transport(index.request(for: query, adult: adult))
                    let reset = resp.headers["x-ratelimit-reset"].flatMap(SearchDates.parse)
                    switch resp.status {
                    case 200..<300:
                        guard let hits = try? index.parse(resp.body) else { return SourceOutcome(failure: .unavailable) }
                        let exhausted = resp.headers["x-ratelimit-remaining"] == "0"
                        return SourceOutcome(hits: hits, limitedUntil: exhausted ? reset : nil)
                    case 429:
                        return SourceOutcome(failure: .rateLimited, limitedUntil: reset ?? Date().addingTimeInterval(3600))
                    case 500...599 where !retried:
                        retried = true
                        try await Task.sleep(for: .milliseconds(500))
                    default:
                        return SourceOutcome(failure: .unavailable)
                    }
                }
            }
        } catch let e as URLError where [.notConnectedToInternet, .networkConnectionLost, .dataNotAllowed].contains(e.code) {
            return SourceOutcome(failure: .offline)
        } catch {
            return SourceOutcome(failure: .unavailable)
        }
    }
}

// MARK: - Status text

extension TorrentSearch {
    /// Every source failed (or none was asked).
    public var allFailed: Bool { phase == .done && failures.count >= searched.count }
    public var isOffline: Bool { allFailed && !failures.isEmpty && failures.values.allSatisfy { $0 == .offline } }

    /// "214 results from 4 sources".
    public var summary: String {
        let answered = max(0, searched.count - failures.count)
        let n = results.count
        return "\(TideFormat.count(n)) \(n == 1 ? "result" : "results") from \(answered) \(answered == 1 ? "source" : "sources")"
    }

    /// "Bitsearch didn't respond", "Bitsearch's daily limit is reached".
    public var failureNote: String? {
        let down = searched.filter { failures[$0] == .unavailable || failures[$0] == .offline }.map(\.name)
        let limited = searched.filter { failures[$0] == .rateLimited }.map(\.name)
        var parts: [String] = []
        if !down.isEmpty { parts.append("\(Self.list(down)) didn't respond") }
        if limited.count == 1 { parts.append("\(limited[0])'s daily limit is reached") }
        if limited.count > 1 { parts.append("\(Self.list(limited)) reached their daily limits") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private static func list(_ names: [String]) -> String {
        names.count <= 1 ? names.joined() : names.dropLast().joined(separator: ", ") + " and " + names.last!
    }
}

// MARK: - Deadline

struct DeadlineExceeded: Error {}

/// Runs `op`, giving up (and cancelling it) after `duration`.
func withDeadline<T: Sendable>(_ duration: Duration, _ op: @escaping @Sendable () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask(operation: op)
        group.addTask {
            try await Task.sleep(for: duration)
            throw DeadlineExceeded()
        }
        defer { group.cancelAll() }
        guard let first = try await group.next() else { throw DeadlineExceeded() }
        return first
    }
}

// MARK: - Previews

extension TorrentSearch {
    /// A search in a given state with canned results, for previews and the render matrix.
    public static func preview(query: String, results: [SearchResult], phase: Phase = .done,
                               searched: [SearchSourceID] = SearchSourceID.allCases,
                               failures: [SearchSourceID: SearchFailure] = [:]) -> TorrentSearch {
        let s = TorrentSearch(transport: { _ in throw URLError(.notConnectedToInternet) })
        s.query = query
        s.results = results
        s.phase = phase
        s.searched = searched
        s.failures = failures
        return s
    }
}
