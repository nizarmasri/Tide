import Foundation
import Observation

/// Loads the file list of the selected search result, and only that one.
///
/// Two lookups run side by side once the selection has rested:
/// - a quick list from the index (The Pirate Bay's `f.php`, else Bitsearch's detail), and
/// - the real .torrent (a direct link from the source, else a public cache by info hash).
///
/// The .torrent is only used once the core has read it and its info hash matches the result's.
/// It then gives the full file tree and smart selection, and Download hands it to the Add window
/// so the download starts without waiting for metadata.
@MainActor
@Observable
public final class TorrentDetails {
    public enum Files: Equatable, Sendable {
        case loading
        /// From the index: names, and usually sizes.
        case listed([TaskFile])
        /// From the verified .torrent: the same preview the Add window shows.
        case full(AddPreview)
        case unavailable
    }

    /// By info hash. Kept while the window is open.
    public private(set) var files: [String: Files] = [:]

    @ObservationIgnored private let transport: HTTPTransport
    @ObservationIgnored private let directory: URL
    @ObservationIgnored private let settle: Duration
    @ObservationIgnored private let inspect: @MainActor (AddInput) async -> AddPreview
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var selectedID: String?

    nonisolated public static let defaultDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent("Tide-Search", isDirectory: true)

    nonisolated static let torrentDeadline: Duration = .seconds(15)
    nonisolated static let listDeadline: Duration = .seconds(6)
    nonisolated static let maxTorrentBytes = 8_000_000

    public init(transport: @escaping HTTPTransport = SearchHTTP.live, directory: URL = TorrentDetails.defaultDirectory,
                settle: Duration = .milliseconds(400), inspect: @escaping @MainActor (AddInput) async -> AddPreview) {
        self.transport = transport
        self.directory = directory
        self.settle = settle
        self.inspect = inspect
    }

    /// Loads `result`'s files after the selection rests; a new selection cancels the last load.
    /// `sources` are the ones the user turned on: their hosts are the only indexes asked.
    public func select(_ result: SearchResult?, sources: Set<SearchSourceID>) {
        guard result?.id != selectedID else { return }
        selectedID = result?.id
        task?.cancel()
        task = nil
        guard let result, files[result.id] == nil else { return }
        let settle = self.settle
        task = Task { [weak self] in
            try? await Task.sleep(for: settle)
            guard !Task.isCancelled else { return }
            await self?.load(result, sources: sources)
        }
    }

    /// Waits for the current load (tests).
    public func wait() async { await task?.value }

    /// What Download should add: the verified .torrent when there is one, else the magnet.
    public func addInput(for result: SearchResult) -> AddInput {
        if case .full(let p)? = files[result.id], case .torrentFile(let url) = p.input,
           FileManager.default.fileExists(atPath: url.path) {
            return .torrentFile(url)
        }
        return .link(result.magnet)
    }

    /// Deletes downloaded .torrent files, except those an open Add window still needs.
    nonisolated public static func removeTemporaryFiles(in directory: URL = defaultDirectory, keeping keep: Set<URL>) {
        guard let items = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        else { return }
        let kept = Set(keep.map(\.standardizedFileURL))
        for f in items where !kept.contains(f.standardizedFileURL) {
            try? FileManager.default.removeItem(at: f)
        }
    }

    // MARK: Loading

    private enum Outcome: Sendable {
        case listed([TaskFile]?)
        case torrent(URL?)
    }

    private func load(_ r: SearchResult, sources: Set<SearchSourceID>) async {
        files[r.id] = .loading
        let transport = self.transport, directory = self.directory
        await withTaskGroup(of: Outcome.self) { group in
            group.addTask { .listed(await TorrentDetails.listFiles(r, sources: sources, transport: transport)) }
            group.addTask { .torrent(await TorrentDetails.fetchTorrent(r, into: directory, transport: transport)) }
            for await outcome in group {
                guard !Task.isCancelled else { break }
                switch outcome {
                case .listed(let list?) where !list.isEmpty:
                    if case .loading? = files[r.id] { files[r.id] = .listed(list) }
                case .torrent(let url?):
                    let p = await inspect(.torrentFile(url))
                    if p.problem == nil, p.infoHash == r.infoHash, !p.files.isEmpty {
                        files[r.id] = .full(p)
                    } else {
                        try? FileManager.default.removeItem(at: url)
                    }
                default:
                    break
                }
            }
        }
        if Task.isCancelled {
            // Interrupted: forget partial work so coming back loads it properly.
            if case .full? = files[r.id] {} else { files[r.id] = nil }
        } else if case .loading? = files[r.id] {
            files[r.id] = .unavailable
        }
    }

    nonisolated static func listFiles(_ r: SearchResult, sources: Set<SearchSourceID>,
                                      transport: @escaping HTTPTransport) async -> [TaskFile]? {
        if sources.contains(.piratebay), let id = r.pirateBayID,
           let resp = try? await withDeadline(listDeadline, { try await transport(PirateBayIndex.filesRequest(id: id)) }),
           resp.status == 200, let list = try? PirateBayIndex.parseFiles(resp.body), !list.isEmpty {
            return list
        }
        guard !Task.isCancelled, sources.contains(.bitsearch) else { return nil }
        let hash = r.infoHash
        if let resp = try? await withDeadline(listDeadline, { try await transport(BitsearchIndex.detailRequest(hash: hash)) }),
           resp.status == 200, let list = try? BitsearchIndex.parseFiles(resp.body), !list.isEmpty {
            return list
        }
        return nil
    }

    nonisolated static func fetchTorrent(_ r: SearchResult, into directory: URL,
                                         transport: @escaping HTTPTransport) async -> URL? {
        let cache = URL(string: "\(SearchHosts.torrentCache)/torrent/\(r.infoHash.uppercased()).torrent")!
        for url in r.torrentURLs + [cache] {
            guard !Task.isCancelled else { return nil }
            let request = SearchHTTP.get(url, accept: "application/x-bittorrent")
            guard let resp = try? await withDeadline(torrentDeadline, { try await transport(request) }),
                  resp.status == 200, looksLikeTorrent(resp.body) else { continue }
            let file = directory.appendingPathComponent("\(r.infoHash).torrent")
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try resp.body.write(to: file, options: .atomic)
                return file
            } catch {
                return nil
            }
        }
        return nil
    }

    /// A bencoded dictionary with an info dictionary; a cache miss is an HTML page.
    nonisolated static func looksLikeTorrent(_ d: Data) -> Bool {
        d.count > 40 && d.count <= maxTorrentBytes && d.first == UInt8(ascii: "d")
            && d.range(of: Data("4:info".utf8)) != nil
    }
}

// MARK: - Previews

extension TorrentDetails {
    /// Canned files for previews and the render matrix.
    public func preload(_ files: Files, for id: String) { self.files[id] = files }
}
