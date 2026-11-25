import Foundation

// MARK: - HTTP

public struct HTTPResponse: Sendable {
    public var status: Int
    /// Header names lowercased.
    public var headers: [String: String]
    public var body: Data

    public init(status: Int, headers: [String: String] = [:], body: Data) {
        self.status = status; self.body = body
        self.headers = Dictionary(headers.map { ($0.key.lowercased(), $0.value) }, uniquingKeysWith: { a, _ in a })
    }
}

/// Sends one request. The live one is URLSession; tests pass canned responses.
public typealias HTTPTransport = @Sendable (URLRequest) async throws -> HTTPResponse

public enum SearchHTTP {
    /// Ephemeral: no disk cache, no cookies. Created on first search, never at launch.
    private static let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.urlCache = nil
        c.httpCookieStorage = nil
        c.httpShouldSetCookies = false
        c.timeoutIntervalForRequest = 15
        c.timeoutIntervalForResource = 30
        c.waitsForConnectivity = false
        return URLSession(configuration: c)
    }()

    static let userAgent: String = {
        let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1"
        return "Tide/\(v)"
    }()

    public static let live: HTTPTransport = { request in
        let (data, response) = try await session.data(for: request)
        let http = response as? HTTPURLResponse
        var headers: [String: String] = [:]
        for (k, v) in http?.allHeaderFields ?? [:] {
            if let k = k as? String, let v = v as? String { headers[k] = v }
        }
        return HTTPResponse(status: http?.statusCode ?? 0, headers: headers, body: data)
    }

    static func get(_ url: URL, accept: String = "application/json") -> URLRequest {
        var r = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
        r.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        r.setValue(accept, forHTTPHeaderField: "Accept")
        return r
    }
}

// MARK: - Sources

/// One search source: how to ask it, and how to read its answer.
protocol TorrentIndex: Sendable {
    var source: SearchSourceID { get }
    func request(for query: String, adult: Bool) -> URLRequest
    func parse(_ body: Data) throws -> [SearchHit]
}

enum TorrentIndexes {
    static func index(_ id: SearchSourceID) -> any TorrentIndex {
        switch id {
        case .knaben: return KnabenIndex()
        case .piratebay: return PirateBayIndex()
        case .bitsearch: return BitsearchIndex()
        case .torrentscsv: return TorrentsCSVIndex()
        }
    }
}

/// Every host Tide talks to for search. These domains move now and then; this is the one place
/// to update them.
enum SearchHosts {
    static let knaben = "https://api.knaben.org"
    static let bitsearch = "https://bitsearch.eu"
    static let apibay = "https://apibay.org"
    static let torrentsCSV = "https://torrents-csv.com"
    static let nyaa = "https://nyaa.si"
    static let torrentCache = "https://itorrents.net"

    static func url(_ base: String, _ path: String, _ query: [(String, String?)]) -> URL {
        var c = URLComponents(string: base + path)!
        c.percentEncodedQuery = query.map { k, v in
            v.map { "\(k)=\(InfoHash.escape($0))" } ?? k
        }.joined(separator: "&")
        return c.url!
    }
}

/// Public trackers that answered live, for sources that give no trackers of their own.
enum DefaultTrackers {
    static let list = [
        "udp://tracker.opentrackr.org:1337/announce",
        "udp://open.stealth.si:80/announce",
        "udp://tracker.torrent.eu.org:451/announce",
        "udp://open.demonii.com:1337/announce",
    ]
}

// MARK: Knaben (meta-indexer: The Pirate Bay, YTS, Nyaa, Tokyo Toshokan, …)

struct KnabenIndex: TorrentIndex {
    let source = SearchSourceID.knaben

    func request(for query: String, adult: Bool) -> URLRequest {
        var q: [(String, String?)] = [("q", query), ("o", "seeders"), ("d", "desc"), ("s", "150")]
        if adult { q.append(("xxx", nil)) }
        return SearchHTTP.get(SearchHosts.url(SearchHosts.knaben, "/v2/search", q))
    }

    private struct Response: Decodable { var hits: [Hit]? }
    private struct Hit: Decodable {
        var title: String?
        var hash: String?
        var bytes: Int64?
        var seeders: Int?
        var peers: Int?
        var liveSeeders: Int?
        var livePeers: Int?
        var date: String?
        var categoryId: [Int]?
        var details: String?
        var magnetUrl: String?
        var tracker: String?
        var trackerId: String?
    }

    func parse(_ body: Data) throws -> [SearchHit] {
        try JSONDecoder().decode(Response.self, from: body).hits?.compactMap { h in
            guard let hash = h.hash.flatMap(InfoHash.normalize), let title = h.title, !title.isEmpty else { return nil }
            let details = h.details.flatMap(URL.init(string:))
            var origin = SourceHit(source: .knaben, label: Self.label(h.tracker), page: details)
            switch h.trackerId {
            case "thepiratebay":
                origin.pirateBayID = details.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }?
                    .queryItems?.first { $0.name == "id" }?.value
            case "nyaasi":
                // nyaa.si/view/<id> (or a mirror) → nyaa.si/download/<id>.torrent
                if let id = details?.lastPathComponent, details?.pathComponents.contains("view") == true,
                   id.allSatisfy(\.isNumber) {
                    origin.torrentURL = URL(string: "\(SearchHosts.nyaa)/download/\(id).torrent")
                }
            default: break
            }
            return SearchHit(
                infoHash: hash, name: title, size: max(0, h.bytes ?? 0),
                seeders: h.liveSeeders ?? h.seeders ?? 0,  // live counts are fresher than the index's
                leechers: h.livePeers ?? h.peers ?? 0,
                added: h.date.flatMap(SearchDates.parse), category: Self.category(h.categoryId ?? []),
                trackers: h.magnetUrl.map(InfoHash.trackers(inMagnet:)) ?? [], origin: origin)
        } ?? []
    }

    static func label(_ tracker: String?) -> String {
        guard let tracker, !tracker.isEmpty else { return "Knaben" }
        return tracker == "Nyaa.si" ? "Nyaa" : tracker
    }

    /// Knaben ids: 1M audio, 2M TV, 3M movies, 4M PC (4001000 games), 5M XXX, 6M anime,
    /// 7M console, 8M mobile, 9M books.
    static func category(_ ids: [Int]) -> SearchCategory {
        if ids.contains(4_001_000) { return .games }
        guard let top = ids.map({ $0 / 1_000_000 }).first(where: { $0 > 0 }) else { return .other }
        switch top {
        case 1: return .music
        case 2: return .tv
        case 3: return .movies
        case 4, 8: return .apps
        case 5: return .adult
        case 6: return .anime
        case 7: return .games
        case 9: return .books
        default: return .other
        }
    }
}

// MARK: The Pirate Bay (apibay)

struct PirateBayIndex: TorrentIndex {
    let source = SearchSourceID.piratebay

    func request(for query: String, adult: Bool) -> URLRequest {
        SearchHTTP.get(SearchHosts.url(SearchHosts.apibay, "/q.php", [("q", query), ("cat", "0")]))
    }

    private struct Row: Decodable {
        var id: LossyString?
        var name: String?
        var info_hash: String?
        var leechers: LossyInt?
        var seeders: LossyInt?
        var size: LossyInt?
        var username: String?
        var added: LossyInt?
        var category: LossyInt?
    }

    func parse(_ body: Data) throws -> [SearchHit] {
        // An uncached query sometimes comes back empty instead of "[]".
        guard !body.allSatisfy({ $0 == 0x20 || $0 == 0x0a || $0 == 0x0d }) else { return [] }
        return try JSONDecoder().decode([Row].self, from: body).compactMap { r in
            // "No results returned" is a row with id 0 and an all-zero hash.
            guard let id = r.id?.value, id != "0", let hash = r.info_hash.flatMap(InfoHash.normalize),
                  let name = r.name, !name.isEmpty else { return nil }
            let added = (r.added?.value).flatMap { $0 > 0 ? Date(timeIntervalSince1970: TimeInterval($0)) : nil }
            return SearchHit(
                infoHash: hash, name: name, size: max(0, r.size?.value ?? 0), seeders: Int(r.seeders?.value ?? 0),
                leechers: Int(r.leechers?.value ?? 0), added: added, category: Self.category(Int(r.category?.value ?? 0)),
                uploader: r.username.flatMap { $0.isEmpty ? nil : $0 },
                origin: SourceHit(source: .piratebay, pirateBayID: id))
        }
    }

    /// 1xx audio, 2xx video, 3xx applications, 4xx games, 5xx porn, 6xx other.
    static func category(_ c: Int) -> SearchCategory {
        switch c {
        case 102, 601, 602: return .books
        case 100...199: return .music
        case 203: return .music
        case 205, 208, 212: return .tv
        case 200...299: return [201, 202, 207, 209, 211].contains(c) ? .movies : .other
        case 300...399: return .apps
        case 400...499: return .games
        case 500...599: return .adult
        default: return .other
        }
    }

    /// `f.php?id=` → the torrent's files with sizes.
    static func filesRequest(id: String) -> URLRequest {
        SearchHTTP.get(SearchHosts.url(SearchHosts.apibay, "/f.php", [("id", id)]))
    }

    private struct FileRow: Decodable {
        var name: [String]?
        var size: [Int64]?
    }

    static func parseFiles(_ body: Data) throws -> [TaskFile] {
        try JSONDecoder().decode([FileRow].self, from: body).enumerated().compactMap { i, f in
            guard let path = f.name?.first, !path.isEmpty else { return nil }
            return TaskFile(index: i + 1, path: path, length: f.size?.first ?? 0, selected: true, tag: .other)
        }
    }
}

// MARK: Bitsearch (DHT index; 200 free requests a day per IP)

struct BitsearchIndex: TorrentIndex {
    let source = SearchSourceID.bitsearch

    func request(for query: String, adult: Bool) -> URLRequest {
        SearchHTTP.get(SearchHosts.url(SearchHosts.bitsearch, "/api/v1/search",
                                       [("q", query), ("sort", "seeders"), ("order", "desc"), ("limit", "100")]))
    }

    private struct Response: Decodable { var results: [Row]? }
    private struct Row: Decodable {
        var id: String?
        var infohash: String?
        var title: String?
        var size: Int64?
        var category: Int?
        var seeders: Int?
        var leechers: Int?
        var createdAt: String?
    }

    func parse(_ body: Data) throws -> [SearchHit] {
        try JSONDecoder().decode(Response.self, from: body).results?.compactMap { r in
            guard let hash = r.infohash.flatMap(InfoHash.normalize), let title = r.title, !title.isEmpty else { return nil }
            let page = r.id.flatMap { URL(string: "\(SearchHosts.bitsearch)/torrent/\($0)") }
            return SearchHit(
                infoHash: hash, name: title, size: max(0, r.size ?? 0), seeders: r.seeders ?? 0,
                leechers: r.leechers ?? 0, added: r.createdAt.flatMap(SearchDates.parse),
                category: Self.category(r.category ?? 0), origin: SourceHit(source: .bitsearch, page: page))
        } ?? []
    }

    /// 1 other, 2 movies, 3 TV, 4 anime, 5 software, 6 games, 7 music, 8 audiobooks, 9 ebooks, 10 XXX.
    static func category(_ c: Int) -> SearchCategory {
        switch c {
        case 2: return .movies
        case 3: return .tv
        case 4: return .anime
        case 5: return .apps
        case 6: return .games
        case 7: return .music
        case 8, 9: return .books
        case 10: return .adult
        default: return .other
        }
    }

    /// Detail by info hash: file paths (no sizes in practice) and trackers.
    static func detailRequest(hash: String) -> URLRequest {
        SearchHTTP.get(URL(string: "\(SearchHosts.bitsearch)/api/v1/torrent/\(hash)")!)
    }

    private struct Detail: Decodable {
        struct T: Decodable { var files: [F]? }
        struct F: Decodable { var path: String?; var size: Int64? }
        var torrent: T?
    }

    static func parseFiles(_ body: Data) throws -> [TaskFile] {
        (try JSONDecoder().decode(Detail.self, from: body).torrent?.files ?? []).enumerated().compactMap { i, f in
            guard let path = f.path, !path.isEmpty else { return nil }
            return TaskFile(index: i + 1, path: path, length: f.size ?? 0, selected: true, tag: .other)
        }
    }
}

// MARK: Torrents-CSV (open index of public torrents)

struct TorrentsCSVIndex: TorrentIndex {
    let source = SearchSourceID.torrentscsv

    func request(for query: String, adult: Bool) -> URLRequest {
        SearchHTTP.get(SearchHosts.url(SearchHosts.torrentsCSV, "/service/search", [("q", query)]))
    }

    private struct Response: Decodable { var torrents: [Row]? }
    private struct Row: Decodable {
        var infohash: String?
        var name: String?
        var size_bytes: Int64?
        var created_unix: Int64?
        var seeders: Int?
        var leechers: Int?
    }

    func parse(_ body: Data) throws -> [SearchHit] {
        try JSONDecoder().decode(Response.self, from: body).torrents?.compactMap { r in
            guard let hash = r.infohash.flatMap(InfoHash.normalize), let name = r.name, !name.isEmpty else { return nil }
            let added = r.created_unix.flatMap { $0 > 0 ? Date(timeIntervalSince1970: TimeInterval($0)) : nil }
            return SearchHit(infoHash: hash, name: name, size: max(0, r.size_bytes ?? 0), seeders: r.seeders ?? 0,
                             leechers: r.leechers ?? 0, added: added, origin: SourceHit(source: .torrentscsv))
        } ?? []
    }
}

// MARK: - Decoding helpers

/// apibay sends numbers as strings.
struct LossyInt: Decodable {
    var value: Int64
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let n = try? c.decode(Int64.self) { value = n }
        else if let s = try? c.decode(String.self), let n = Int64(s) { value = n }
        else { value = 0 }
    }
}

struct LossyString: Decodable {
    var value: String
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let s = try? c.decode(String.self) { value = s }
        else if let n = try? c.decode(Int64.self) { value = String(n) }
        else { value = "" }
    }
}

enum SearchDates {
    // ISO8601DateFormatter is thread-safe for parsing.
    nonisolated(unsafe) private static let plain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime]; return f
    }()
    nonisolated(unsafe) private static let fractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f
    }()
    nonisolated(unsafe) private static let noZone: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withFullDate, .withTime, .withColonSeparatorInTime, .withDashSeparatorInDate]
        f.timeZone = TimeZone(secondsFromGMT: 0)
        return f
    }()

    /// "2026-04-25T15:35:00+00:00", "2026-11-12T09:46:57.223Z", "2015-11-08T00:00:00" (UTC).
    static func parse(_ s: String) -> Date? {
        plain.date(from: s) ?? fractional.date(from: s) ?? noZone.date(from: s)
    }
}
