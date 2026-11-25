import XCTest
@testable import TideKit

// Fixtures are trimmed copies of what each source returned on 2026-11-25.

private let knabenJSON = #"""
{"max_score":null,"total":{"relation":"eq","value":3},"hits":[
 {"bytes":6517612871,"cachedOrigin":"The Pirate Bay (proxy)","category":"PC / Unix","categoryId":[4000000,4004000],
  "date":"2026-04-25T15:35:00+00:00","details":"https://knaben.xyz/thepiratebay/description.php?id=82917197",
  "hash":"DAFC8C076CA2F3ED376EEAE7C76A0D6BE2415C45","livePeers":108,"liveSeeders":147,
  "magnetUrl":"magnet:?xt=urn:btih:DAFC8C076CA2F3ED376EEAE7C76A0D6BE2415C45&dn=ubuntu-26.04-desktop-amd64.iso&tr=udp%3A%2F%2Ftracker.opentrackr.org%3A1337&tr=udp%3A%2F%2Fopen.stealth.si%3A80%2Fannounce",
  "peers":99,"seeders":132,"title":"ubuntu-26.04-desktop-amd64.iso","tracker":"The Pirate Bay","trackerId":"thepiratebay"},
 {"bytes":1503238553,"categoryId":[9000000,6006001,6006000,6000000],"date":"2015-11-08T00:00:00",
  "details":"https://nyaa.iss.ink/view/1993131","hash":"611e5b6bcfa317ea580a40da2e7befda5caf3a9f",
  "magnetUrl":null,"peers":10,"seeders":234,"title":"[AnoZu] One Piece S23E06 1080p","tracker":"Nyaa.si","trackerId":"nyaasi"},
 {"bytes":76902560,"categoryId":[1001000,1000000],"details":"https://1337x.to/torrent/3168985/x/","hash":null,
  "magnetUrl":null,"peers":0,"seeders":4,"title":"No hash here","tracker":"1337x","trackerId":"1337x"}
]}
"""#

private let apibayJSON = #"""
[{"id":"59191690","name":"Ubuntu 22.04 LTS","info_hash":"2C6B6858D61DA9543D4231A71DB4B1C9264B0685","leechers":"11",
  "seeders":"34","size":"3654957056","num_files":"1","username":"rjaa","added":"1652877231","status":"vip","category":"303","imdb":""},
 {"id":"81462446","name":"Ubuntu Linux Bible","info_hash":"232CD67EB3FFBD7C37BF9EC3EE887417E5AE1EE6","leechers":"3",
  "seeders":"35","size":"8554738","num_files":"1","username":"","added":"1765526528","status":"vip","category":"601","imdb":""},
 {"id":"1","name":"Adult thing","info_hash":"1111111111111111111111111111111111111111","leechers":"1",
  "seeders":"500","size":"1000","num_files":"1","username":"x","added":"0","status":"member","category":"501","imdb":""}]
"""#

private let apibayNoResults = #"""
[{"id":"0","name":"No results returned","info_hash":"0000000000000000000000000000000000000000","leechers":"0","seeders":"0","num_files":"0","size":"0","username":"","added":"0","status":"member","category":"0","imdb":"","total_found":"1"}]
"""#

private let bitsearchJSON = #"""
{"success":true,"query":"ubuntu","results":[
 {"id":"63f864e1ae697358dc80e874","infohash":"A7838B75C42B612DA3B6CC99BEED4ECB2D04CFF2","title":"ubuntu-22.04.2-desktop-amd64.iso",
  "size":4927586304,"category":5,"subCategory":4,"genres":[],"seeders":177,"leechers":331,"downloads":0,"verified":false,
  "createdAt":"2023-02-24T10:00:00.000Z","updatedAt":"2026-11-12T09:03:50.401Z"},
 {"id":"5cb8afc48700981f3e5b00c4","infohash":"2C6B6858D61DA9543D4231A71DB4B1C9264B0685","title":"Ubuntu 22.04 LTS",
  "size":3654957056,"category":1,"subCategory":7,"genres":[],"seeders":40,"leechers":2,"downloads":0,"verified":false,
  "createdAt":null,"updatedAt":"2026-11-12T09:46:57.223Z"}],
 "pagination":{"page":1,"perPage":20,"total":4285,"totalPages":215,"hasNext":true,"hasPrev":false},"took":2}
"""#

private let torrentsCSVJSON = #"""
{"torrents":[{"infohash":"232cd67eb3ffbd7c37bf9ec3ee887417e5ae1ee6","name":"Clinton D., Negus C. Ubuntu Linux Bible 11ed 2025",
 "size_bytes":8554738,"created_unix":1784214068,"seeders":27,"leechers":0,"completed":345,"scraped_date":1792966620,"id":81285}],
 "next":771058}
"""#

private let apibayFilesJSON = #"""
[{"name":["Course/01 - Intro.mp4"],"size":[160755461]},{"name":["TutsNode.com.txt"],"size":[63]}]
"""#

private let bitsearchDetailJSON = #"""
{"success":true,"torrent":{"id":"63f864e1ae697358dc80e874","infohash":"A7838B75C42B612DA3B6CC99BEED4ECB2D04CFF2",
 "title":"ubuntu-22.04.2-desktop-amd64.iso","files":[{"path":"ubuntu-22.04.2-desktop-amd64.iso"}],
 "trackers":["udp://tracker.opentrackr.org:1337/announce"],"magnetUri":"magnet:?xt=urn:btih:A7838B75C42B612DA3B6CC99BEED4ECB2D04CFF2"}}
"""#

private func data(_ s: String) -> Data { Data(s.utf8) }

// MARK: - Hashes and magnets

final class InfoHashTests: XCTestCase {
    func testNormalizesHexAndBase32() {
        XCTAssertEqual(InfoHash.normalize("DD8255ECDC7CA55FB0BBF81323D87062DB1F6D1C"), "dd8255ecdc7ca55fb0bbf81323d87062db1f6d1c")
        XCTAssertEqual(InfoHash.normalize("WOEM2DRYZ2BTWFHPUKQXOOS7SGUN3B75"), "b388cd0e38ce833b14efa2a1773a5f91a8dd87fd")
        XCTAssertEqual(InfoHash.normalize("woem2dryz2btwfhpukqxoos7sgun3b75"), "b388cd0e38ce833b14efa2a1773a5f91a8dd87fd")
    }

    func testRejectsGarbageAndZeroHash() {
        XCTAssertNil(InfoHash.normalize("0000000000000000000000000000000000000000"))
        XCTAssertNil(InfoHash.normalize("not a hash"))
        XCTAssertNil(InfoHash.normalize("DD8255ECDC7CA55FB0BBF81323D87062DB1F6D1"))   // 39 characters
        XCTAssertNil(InfoHash.normalize("WOEM2DRYZ2BTWFHPUKQXOOS7SGUN3B71"))           // 1 isn't base32
    }

    func testMagnetRoundTrip() {
        let m = InfoHash.magnet(hash: "dd8255ecdc7ca55fb0bbf81323d87062db1f6d1c", name: "Big Buck Bunny & Friends",
                                trackers: ["udp://tracker.opentrackr.org:1337/announce"])
        XCTAssertEqual(m, "magnet:?xt=urn:btih:dd8255ecdc7ca55fb0bbf81323d87062db1f6d1c&dn=Big%20Buck%20Bunny%20%26%20Friends"
                       + "&tr=udp%3A%2F%2Ftracker.opentrackr.org%3A1337%2Fannounce")
        XCTAssertEqual(InfoHash.trackers(inMagnet: m), ["udp://tracker.opentrackr.org:1337/announce"])
    }
}

// MARK: - Source parsing

final class SourceParsingTests: XCTestCase {
    func testKnaben() throws {
        let hits = try KnabenIndex().parse(data(knabenJSON))
        XCTAssertEqual(hits.count, 2, "the row without a hash is dropped")

        let tpb = hits[0]
        XCTAssertEqual(tpb.infoHash, "dafc8c076ca2f3ed376eeae7c76a0d6be2415c45")
        XCTAssertEqual(tpb.seeders, 147, "live seeders win over the index's count")
        XCTAssertEqual(tpb.leechers, 108)
        XCTAssertEqual(tpb.size, 6_517_612_871)
        XCTAssertEqual(tpb.category, .apps)
        XCTAssertEqual(tpb.origin.label, "The Pirate Bay")
        XCTAssertEqual(tpb.origin.pirateBayID, "82917197")
        XCTAssertEqual(tpb.trackers, ["udp://tracker.opentrackr.org:1337", "udp://open.stealth.si:80/announce"])
        XCTAssertEqual(tpb.added, Date(timeIntervalSince1970: 1_777_131_300))

        let nyaa = hits[1]
        XCTAssertEqual(nyaa.origin.label, "Nyaa")
        XCTAssertEqual(nyaa.origin.torrentURL, URL(string: "https://nyaa.si/download/1993131.torrent"))
        XCTAssertEqual(nyaa.category, .books, "first top-level id wins")
        XCTAssertEqual(nyaa.seeders, 234)
        XCTAssertEqual(nyaa.added, Date(timeIntervalSince1970: 1_446_940_800), "no zone means UTC")
    }

    func testKnabenRequestHidesAdultUnlessAsked() {
        let plain = KnabenIndex().request(for: "big buck bunny", adult: false).url!.absoluteString
        XCTAssertEqual(plain, "https://api.knaben.org/v2/search?q=big%20buck%20bunny&o=seeders&d=desc&s=150")
        XCTAssertTrue(KnabenIndex().request(for: "x", adult: true).url!.absoluteString.hasSuffix("&xxx"))
    }

    func testPirateBay() throws {
        let hits = try PirateBayIndex().parse(data(apibayJSON))
        XCTAssertEqual(hits.count, 3)
        XCTAssertEqual(hits[0].seeders, 34)
        XCTAssertEqual(hits[0].size, 3_654_957_056)
        XCTAssertEqual(hits[0].uploader, "rjaa")
        XCTAssertEqual(hits[0].category, .apps)
        XCTAssertEqual(hits[0].origin.pirateBayID, "59191690")
        XCTAssertEqual(hits[0].added, Date(timeIntervalSince1970: 1_652_877_231))
        XCTAssertNil(hits[1].uploader)
        XCTAssertEqual(hits[1].category, .books)
        XCTAssertEqual(hits[2].category, .adult)
        XCTAssertNil(hits[2].added)
    }

    func testPirateBayEmptyAnswers() throws {
        XCTAssertEqual(try PirateBayIndex().parse(data(apibayNoResults)), [])
        XCTAssertEqual(try PirateBayIndex().parse(Data()), [])
    }

    func testBitsearch() throws {
        let hits = try BitsearchIndex().parse(data(bitsearchJSON))
        XCTAssertEqual(hits.count, 2)
        XCTAssertEqual(hits[0].infoHash, "a7838b75c42b612da3b6cc99beed4ecb2d04cff2")
        XCTAssertEqual(hits[0].category, .apps)
        XCTAssertEqual(hits[0].origin.page, URL(string: "https://bitsearch.eu/torrent/63f864e1ae697358dc80e874"))
        XCTAssertEqual(hits[0].added, Date(timeIntervalSince1970: 1_677_232_800))
        XCTAssertNil(hits[1].added, "updatedAt is a scrape time, not an upload date")
    }

    func testTorrentsCSV() throws {
        let hits = try TorrentsCSVIndex().parse(data(torrentsCSVJSON))
        XCTAssertEqual(hits.count, 1)
        XCTAssertEqual(hits[0].seeders, 27)
        XCTAssertEqual(hits[0].category, .other)
    }

    func testFileLists() throws {
        let tpb = try PirateBayIndex.parseFiles(data(apibayFilesJSON))
        XCTAssertEqual(tpb.map(\.path), ["Course/01 - Intro.mp4", "TutsNode.com.txt"])
        XCTAssertEqual(tpb.map(\.length), [160_755_461, 63])
        XCTAssertEqual(tpb.map(\.index), [1, 2])
        XCTAssertThrowsError(try PirateBayIndex.parseFiles(data(#"[{"name":{"0":"Filelist not found"},"size":{"0":"0"}}]"#)))

        let bs = try BitsearchIndex.parseFiles(data(bitsearchDetailJSON))
        XCTAssertEqual(bs.map(\.path), ["ubuntu-22.04.2-desktop-amd64.iso"])
        XCTAssertEqual(bs[0].length, 0, "Bitsearch gives paths without sizes")
    }
}

// MARK: - Merging

final class SearchMergerTests: XCTestCase {
    private func hit(_ hash: String, _ source: SearchSourceID, name: String = "Name", size: Int64 = 100, seeds: Int = 1,
                     leech: Int = 0, added: Date? = nil, category: SearchCategory = .other, trackers: [String] = [],
                     label: String? = nil) -> SearchHit {
        SearchHit(infoHash: hash, name: name, size: size, seeders: seeds, leechers: leech, added: added,
                  category: category, trackers: trackers, origin: SourceHit(source: source, label: label))
    }

    func testMergesTheSameTorrentAcrossSources() throws {
        let a = String(repeating: "a", count: 40)
        let merged = SearchMerger.merge([
            hit(a, .bitsearch, name: "bitsearch name", size: 100, seeds: 40, leech: 9, added: Date(timeIntervalSince1970: 300),
                trackers: ["udp://b"]),
            hit(a, .knaben, name: "knaben name", size: 100, seeds: 147, leech: 2, added: Date(timeIntervalSince1970: 200),
                category: .apps, trackers: ["udp://a", "udp://b"], label: "The Pirate Bay"),
            hit(a, .piratebay, name: "tpb name", size: 101, seeds: 34, leech: 11, added: nil),
        ], showAdult: false)
        XCTAssertEqual(merged.count, 1)
        let r = try XCTUnwrap(merged.first)
        XCTAssertEqual(r.name, "knaben name", "Knaben's name wins")
        XCTAssertEqual(r.seeders, 147)
        XCTAssertEqual(r.leechers, 11)
        XCTAssertEqual(r.size, 100, "the size most sources agree on")
        XCTAssertEqual(r.added, Date(timeIntervalSince1970: 200), "earliest date")
        XCTAssertEqual(r.category, .apps)
        XCTAssertEqual(r.trackers, ["udp://a", "udp://b"])
        XCTAssertEqual(r.labels, ["The Pirate Bay", "Bitsearch"], "Knaben's TPB and direct TPB share a badge")
    }

    func testSortsBySeedsAndAddsDefaultTrackers() {
        let merged = SearchMerger.merge([
            hit(String(repeating: "1", count: 40), .torrentscsv, seeds: 3),
            hit(String(repeating: "2", count: 40), .torrentscsv, seeds: 30),
        ], showAdult: false)
        XCTAssertEqual(merged.map(\.seeders), [30, 3])
        XCTAssertEqual(merged[0].trackers, DefaultTrackers.list)
        XCTAssertTrue(merged[0].magnet.hasPrefix("magnet:?xt=urn:btih:2222"))
    }

    func testCapsTrackers() {
        let many = (0..<30).map { "udp://t\($0)" }
        let merged = SearchMerger.merge([hit(String(repeating: "c", count: 40), .knaben, trackers: many)], showAdult: false)
        XCTAssertEqual(merged[0].trackers.count, SearchMerger.maxTrackers)
    }

    func testAdultIsHiddenUnlessAsked() {
        let h = String(repeating: "d", count: 40)
        let hits = [hit(h, .bitsearch, category: .other), hit(h, .piratebay, category: .adult)]
        XCTAssertTrue(SearchMerger.merge(hits, showAdult: false).isEmpty, "one source calling it adult is enough")
        XCTAssertEqual(SearchMerger.merge(hits, showAdult: true).count, 1)
    }
}

// MARK: - Fake network

private final class FakeNet: @unchecked Sendable {
    typealias Handler = @Sendable (URL) async throws -> HTTPResponse
    private let lock = NSLock()
    private var _requests: [URL] = []
    private let handler: Handler

    init(_ handler: @escaping Handler) { self.handler = handler }

    var requests: [URL] { lock.withLock { _requests } }
    func requests(to host: String) -> Int { requests.filter { $0.host == host }.count }

    var transport: HTTPTransport {
        { [self] request in
            lock.withLock { _requests.append(request.url!) }
            return try await handler(request.url!)
        }
    }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    /// Returns the count before incrementing.
    func next() -> Int { lock.withLock { defer { n += 1 }; return n } }
}

private func ok(_ s: String, headers: [String: String] = [:]) -> HTTPResponse {
    HTTPResponse(status: 200, headers: headers, body: Data(s.utf8))
}

/// Answers every source with its fixture.
private let allSources: FakeNet.Handler = { url in
    switch url.host {
    case "api.knaben.org": return ok(knabenJSON)
    case "apibay.org": return ok(apibayJSON)
    case "bitsearch.eu": return ok(bitsearchJSON)
    case "torrents-csv.com": return ok(torrentsCSVJSON)
    default: return HTTPResponse(status: 404, body: Data())
    }
}

// MARK: - Searching

@MainActor
final class TorrentSearchTests: XCTestCase {
    func testMergesEverySourceOnce() async {
        let net = FakeNet(allSources)
        let s = TorrentSearch(transport: net.transport)
        s.search("ubuntu", sources: SearchSourceID.allCases, showAdult: false)
        XCTAssertEqual(s.phase, .searching)
        await s.wait()
        XCTAssertEqual(s.phase, .done)
        XCTAssertEqual(s.query, "ubuntu")
        XCTAssertTrue(s.failures.isEmpty)
        // 2 Knaben + 3 TPB + 2 Bitsearch + 1 CSV = 8 hits; 2 duplicates merged, 1 adult hidden.
        XCTAssertEqual(s.results.count, 5)
        XCTAssertEqual(Set(s.results.map(\.id)).count, s.results.count)
        let ubuntu = s.results.first { $0.infoHash == "2c6b6858d61da9543d4231a71db4b1c9264b0685" }
        XCTAssertEqual(ubuntu?.labels, ["The Pirate Bay", "Bitsearch"])
        XCTAssertEqual(ubuntu?.seeders, 40)
        XCTAssertEqual(s.summary, "5 results from 4 sources")
        XCTAssertNil(s.failureNote)
    }

    func testAFailingSourceLeavesTheOthers() async {
        let net = FakeNet { url in
            if url.host == "bitsearch.eu" { return HTTPResponse(status: 503, body: Data()) }
            if url.host == "torrents-csv.com" { throw URLError(.cannotFindHost) }
            return try await allSources(url)
        }
        let s = TorrentSearch(transport: net.transport)
        s.search("ubuntu", sources: SearchSourceID.allCases, showAdult: false)
        await s.wait()
        XCTAssertEqual(s.failures, [.bitsearch: .unavailable, .torrentscsv: .unavailable])
        XCTAssertEqual(net.requests(to: "bitsearch.eu"), 2, "a 5xx is retried once")
        XCTAssertEqual(net.requests(to: "torrents-csv.com"), 1)
        XCTAssertFalse(s.results.isEmpty)
        XCTAssertFalse(s.allFailed)
        XCTAssertEqual(s.summary, "4 results from 2 sources")
        XCTAssertEqual(s.failureNote, "Bitsearch and Torrents-CSV didn't respond")
    }

    func testASlowSourceIsDroppedAtTheDeadline() async {
        let net = FakeNet { url in
            if url.host == "api.knaben.org" { try await Task.sleep(for: .seconds(30)) }
            return try await allSources(url)
        }
        let s = TorrentSearch(transport: net.transport, deadline: .milliseconds(200))
        let started = Date()
        s.search("ubuntu", sources: [.knaben, .bitsearch], showAdult: false)
        await s.wait()
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
        XCTAssertEqual(s.failures, [.knaben: .unavailable])
        XCTAssertEqual(s.results.count, 2)
    }

    func testOfflineEverywhere() async {
        let net = FakeNet { _ in throw URLError(.notConnectedToInternet) }
        let s = TorrentSearch(transport: net.transport)
        s.search("ubuntu", sources: [.knaben, .bitsearch], showAdult: false)
        await s.wait()
        XCTAssertTrue(s.allFailed)
        XCTAssertTrue(s.isOffline)
        XCTAssertTrue(s.results.isEmpty)
    }

    func testRepeatSearchComesFromTheCache() async {
        let net = FakeNet(allSources)
        let s = TorrentSearch(transport: net.transport)
        s.search("ubuntu", sources: [.knaben], showAdult: false)
        await s.wait()
        s.search("  Ubuntu ", sources: [.knaben], showAdult: false)
        await s.wait()
        XCTAssertEqual(net.requests.count, 1)
        XCTAssertEqual(s.results.count, 2)
        s.search("ubuntu", sources: [.knaben], showAdult: true)
        await s.wait()
        XCTAssertEqual(net.requests.count, 2, "a different adult setting is a different search")
    }

    func testAFailedSourceIsAskedAgain() async {
        let failures = Counter()
        let net = FakeNet { url in
            if url.host == "api.knaben.org", failures.next() < 2 { return HTTPResponse(status: 500, body: Data()) }
            return try await allSources(url)
        }
        let s = TorrentSearch(transport: net.transport)
        s.search("ubuntu", sources: [.knaben, .bitsearch], showAdult: false)
        await s.wait()
        XCTAssertEqual(s.failures, [.knaben: .unavailable])
        s.search("ubuntu", sources: [.knaben, .bitsearch], showAdult: false)
        await s.wait()
        XCTAssertTrue(s.failures.isEmpty, "a partial answer isn't cached, so Return asks Knaben again")
        XCTAssertEqual(s.results.count, 4)
    }

    func testRateLimitSkipsTheSourceUntilItResets() async {
        let net = FakeNet { url in
            if url.host == "bitsearch.eu" {
                return HTTPResponse(status: 429, headers: ["X-RateLimit-Reset": "2099-01-01T00:00:00.000Z"], body: Data())
            }
            return try await allSources(url)
        }
        let s = TorrentSearch(transport: net.transport)
        s.search("ubuntu", sources: [.knaben, .bitsearch], showAdult: false)
        await s.wait()
        XCTAssertEqual(s.failures[.bitsearch], .rateLimited)
        XCTAssertEqual(s.failureNote, "Bitsearch's daily limit is reached")
        s.search("debian", sources: [.knaben, .bitsearch], showAdult: false)
        await s.wait()
        XCTAssertEqual(net.requests(to: "bitsearch.eu"), 1, "not asked again before the reset")
        XCTAssertEqual(s.failures[.bitsearch], .rateLimited)
    }

    func testANewSearchReplacesTheOldOne() async {
        let net = FakeNet { url in
            if url.absoluteString.contains("slow") { try await Task.sleep(for: .seconds(2)) }
            return try await allSources(url)
        }
        let s = TorrentSearch(transport: net.transport)
        s.search("slow", sources: [.knaben], showAdult: false)
        s.search("fast", sources: [.bitsearch], showAdult: false)
        await s.wait()
        XCTAssertEqual(s.query, "fast")
        XCTAssertEqual(s.searched, [.bitsearch])
        XCTAssertEqual(s.results.count, 2)
        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(s.query, "fast", "the cancelled search never publishes")
    }

    func testBlankQueryClears() {
        let s = TorrentSearch(transport: FakeNet(allSources).transport)
        s.search("   ", sources: SearchSourceID.allCases, showAdult: false)
        XCTAssertEqual(s.phase, .idle)
    }
}

// MARK: - File details

@MainActor
final class TorrentDetailsTests: XCTestCase {
    private var dir: URL!

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("TideSearchTests-\(UUID().uuidString)")
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private let fakeTorrent = Data("d8:announce3:udp4:infod6:lengthi10e4:name4:test12:piece lengthi16384e6:pieces0:ee".utf8)

    private func result(_ hash: String, tpb: String? = nil) -> SearchResult {
        SearchResult(infoHash: hash, name: "Course", size: 1, seeders: 1, leechers: 0, added: nil, category: .other,
                     sources: [SourceHit(source: .piratebay, pirateBayID: tpb)], trackers: [], uploader: nil)
    }

    private func preview(_ url: URL, hash: String) -> AddPreview {
        AddPreview(input: .torrentFile(url), kind: .torrent, name: "Course", totalBytes: 10,
                   files: [TaskFile(index: 1, path: "a.mp4", length: 10, selected: true, tag: .video)], infoHash: hash)
    }

    func testListsFilesFromTheIndexWhenTheCacheMisses() async {
        let net = FakeNet { url in
            switch url.host {
            case "apibay.org": return ok(apibayFilesJSON)
            case "itorrents.net": return ok("<html>not cached</html>")   // a miss is a 200 page
            default: return HTTPResponse(status: 404, body: Data())
            }
        }
        let hash = String(repeating: "e", count: 40)
        let d = TorrentDetails(transport: net.transport, directory: dir, settle: .zero) { _ in
            XCTFail("nothing to inspect"); return PreviewFixtures.torrentPreview
        }
        let r = result(hash, tpb: "123")
        d.select(r, sources: Set(SearchSourceID.allCases))
        await d.wait()
        guard case .listed(let files)? = d.files[hash] else { return XCTFail("\(String(describing: d.files[hash]))") }
        XCTAssertEqual(files.count, 2)
        XCTAssertEqual(d.addInput(for: r), .link(r.magnet), "no verified torrent: add the magnet")
        XCTAssertEqual(net.requests(to: "bitsearch.eu"), 0, "TPB answered, so Bitsearch isn't asked")
    }

    func testUsesAVerifiedTorrent() async {
        let hash = String(repeating: "f", count: 40)
        let net = FakeNet { [fakeTorrent] url in
            url.host == "itorrents.net" ? HTTPResponse(status: 200, body: fakeTorrent) : HTTPResponse(status: 404, body: Data())
        }
        let d = TorrentDetails(transport: net.transport, directory: dir, settle: .zero) { [self] input in
            guard case .torrentFile(let url) = input else { return PreviewFixtures.urlPreview }
            return preview(url, hash: hash)
        }
        let r = result(hash)
        d.select(r, sources: [])
        await d.wait()
        guard case .full(let p)? = d.files[hash] else { return XCTFail("\(String(describing: d.files[hash]))") }
        XCTAssertEqual(p.files.count, 1)
        let file = dir.appendingPathComponent("\(hash).torrent")
        XCTAssertEqual(d.addInput(for: r), .torrentFile(file))
        XCTAssertEqual(net.requests.map(\.absoluteString), ["https://itorrents.net/torrent/\(hash.uppercased()).torrent"],
                       "with every source off, only the .torrent cache is asked")

        TorrentDetails.removeTemporaryFiles(in: dir, keeping: [file])
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path), "an open Add window still needs it")
        TorrentDetails.removeTemporaryFiles(in: dir, keeping: [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }

    func testRejectsATorrentWithTheWrongHash() async {
        let hash = String(repeating: "a", count: 40)
        let net = FakeNet { [fakeTorrent] url in HTTPResponse(status: 200, body: fakeTorrent) }
        let d = TorrentDetails(transport: net.transport, directory: dir, settle: .zero) { [self] input in
            guard case .torrentFile(let url) = input else { return PreviewFixtures.urlPreview }
            return preview(url, hash: String(repeating: "b", count: 40))
        }
        d.select(result(hash), sources: [])
        await d.wait()
        XCTAssertEqual(d.files[hash], .unavailable)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("\(hash).torrent").path))
    }

    func testSelectingAgainDoesNotRefetch() async {
        let net = FakeNet { _ in HTTPResponse(status: 404, body: Data()) }
        let d = TorrentDetails(transport: net.transport, directory: dir, settle: .zero) { _ in PreviewFixtures.urlPreview }
        let r = result(String(repeating: "c", count: 40))
        d.select(r, sources: [])
        await d.wait()
        let count = net.requests.count
        d.select(nil, sources: [])
        d.select(r, sources: [])
        await d.wait()
        XCTAssertEqual(net.requests.count, count)
    }

    func testLooksLikeTorrent() {
        XCTAssertTrue(TorrentDetails.looksLikeTorrent(fakeTorrent))
        XCTAssertFalse(TorrentDetails.looksLikeTorrent(Data("<!doctype html><html>…</html> 4:info padding padding".utf8)))
        XCTAssertFalse(TorrentDetails.looksLikeTorrent(Data()))
    }
}

// MARK: - Live (opt-in)

/// Hits the real sources: `TIDE_LIVE_SEARCH=1 swift test --filter LiveSearchTests`. Skipped otherwise.
@MainActor
final class LiveSearchTests: XCTestCase {
    override func setUp() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["TIDE_LIVE_SEARCH"] == "1", "set TIDE_LIVE_SEARCH=1")
    }

    func testEverySourceAnswersAndMerges() async throws {
        let s = TorrentSearch()
        s.search("ubuntu", sources: SearchSourceID.allCases, showAdult: false)
        await s.wait()
        print("live:", s.summary, s.failureNote ?? "no failures")
        XCTAssertFalse(s.allFailed)
        XCTAssertGreaterThan(s.results.count, 20)
        XCTAssertEqual(Set(s.results.map(\.id)).count, s.results.count, "no duplicate hashes")
        XCTAssertTrue(s.results.contains { $0.labels.count > 1 }, "some torrents come from several sources")
        for r in s.results.prefix(5) {
            print(" ", r.seeders, TideFormat.bytes(r.size), r.labels.joined(separator: "+"), r.name)
        }
    }

    func testFilesForAKnownTorrent() async throws {
        // Ubuntu 22.04 on The Pirate Bay (id 59191690).
        let r = SearchResult(infoHash: "2c6b6858d61da9543d4231a71db4b1c9264b0685", name: "Ubuntu 22.04 LTS", size: 0,
                             seeders: 0, leechers: 0, added: nil, category: .apps,
                             sources: [SourceHit(source: .piratebay, pirateBayID: "59191690")], trackers: [], uploader: nil)
        let list = await TorrentDetails.listFiles(r, sources: Set(SearchSourceID.allCases), transport: SearchHTTP.live)
        print("live files:", list?.map { "\($0.path) \($0.length)" } ?? [])
        XCTAssertFalse(list?.isEmpty ?? true)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("TideLive-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = await TorrentDetails.fetchTorrent(r, into: dir, transport: SearchHTTP.live)
        print("live torrent:", file?.path ?? "cache miss")
        if let file { XCTAssertTrue(TorrentDetails.looksLikeTorrent(try Data(contentsOf: file))) }
    }
}

// MARK: - Settings compatibility

final class SearchSettingsTests: XCTestCase {
    /// A settings.json written before search existed must still load, keeping the user's values.
    func testSettingsFromBeforeSearchStillDecode() throws {
        var old = TideSettings()
        old.maxPeers = 120
        old.extraTrackers = "udp://example.org:1337/announce"
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(old)) as! [String: Any]
        json["searchDisabledSources"] = nil
        json["searchShowAdult"] = nil
        XCTAssertNil(json["searchDisabledSources"])
        let decoded = try JSONDecoder().decode(TideSettings.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(decoded.maxPeers, 120)
        XCTAssertEqual(decoded.extraTrackers, "udp://example.org:1337/announce")
        XCTAssertEqual(decoded.searchSources, SearchSourceID.allCases)
        XCTAssertFalse(decoded.showAdultResults)
    }

    func testTogglingSources() {
        var s = TideSettings()
        s.setSearchSource(.bitsearch, enabled: false)
        XCTAssertEqual(s.searchSources, [.knaben, .piratebay, .torrentscsv])
        XCTAssertEqual(s.searchDisabledSources, ["bitsearch"])
        s.setSearchSource(.bitsearch, enabled: true)
        XCTAssertNil(s.searchDisabledSources, "all on is stored as the default")
    }
}
