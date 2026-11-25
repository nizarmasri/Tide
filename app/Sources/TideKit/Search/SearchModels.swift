import Foundation

/// The free, keyless indexes Tide searches. The order is also the priority used when sources
/// disagree about a torrent's name or category.
public enum SearchSourceID: String, CaseIterable, Codable, Sendable, Identifiable {
    case knaben, piratebay, bitsearch, torrentscsv

    public var id: String { rawValue }

    public var name: String {
        switch self {
        case .knaben: return "Knaben"
        case .piratebay: return "The Pirate Bay"
        case .bitsearch: return "Bitsearch"
        case .torrentscsv: return "Torrents-CSV"
        }
    }

    /// One line for Settings: what searching this source covers.
    public var coverage: String {
        switch self {
        case .knaben: return "The Pirate Bay, YTS, Nyaa and more"
        case .piratebay: return "Directly, when Knaben is down"
        case .bitsearch: return "A large index of the DHT"
        case .torrentscsv: return "An open index of public torrents"
        }
    }

    var priority: Int { Self.allCases.firstIndex(of: self) ?? 0 }
}

public enum SearchCategory: String, CaseIterable, Sendable, Identifiable {
    case movies, tv, music, anime, apps, games, books, adult, other

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .movies: return "Movies"
        case .tv: return "TV"
        case .music: return "Music"
        case .anime: return "Anime"
        case .apps: return "Apps"
        case .games: return "Games"
        case .books: return "Books"
        case .adult: return "Adult"
        case .other: return "Other"
        }
    }
}

/// Where one source saw a torrent.
public struct SourceHit: Equatable, Sendable {
    public var source: SearchSourceID
    /// The index the torrent comes from, for the badge: Knaben reports the original site.
    public var label: String
    /// The torrent's page on the index.
    public var page: URL?
    /// A direct .torrent download, when the index offers one.
    public var torrentURL: URL?
    /// The Pirate Bay's id, which lists the files with `f.php`.
    public var pirateBayID: String?

    public init(source: SearchSourceID, label: String? = nil, page: URL? = nil, torrentURL: URL? = nil,
                pirateBayID: String? = nil) {
        self.source = source; self.label = label ?? source.name; self.page = page
        self.torrentURL = torrentURL; self.pirateBayID = pirateBayID
    }
}

/// One row from one source, before merging.
public struct SearchHit: Equatable, Sendable {
    /// Lowercase hex.
    public var infoHash: String
    public var name: String
    public var size: Int64
    public var seeders: Int
    public var leechers: Int
    public var added: Date?
    public var category: SearchCategory
    public var trackers: [String]
    public var uploader: String?
    public var origin: SourceHit

    public init(infoHash: String, name: String, size: Int64, seeders: Int, leechers: Int, added: Date? = nil,
                category: SearchCategory = .other, trackers: [String] = [], uploader: String? = nil,
                origin: SourceHit) {
        self.infoHash = infoHash; self.name = name; self.size = size; self.seeders = seeders
        self.leechers = leechers; self.added = added; self.category = category; self.trackers = trackers
        self.uploader = uploader; self.origin = origin
    }
}

/// A torrent after merging every source that has it.
public struct SearchResult: Identifiable, Equatable, Sendable {
    public var id: String { infoHash }
    public var infoHash: String
    public var name: String
    public var size: Int64
    public var seeders: Int
    public var leechers: Int
    public var added: Date?
    public var category: SearchCategory
    public var sources: [SourceHit]
    public var trackers: [String]
    public var uploader: String?

    public init(infoHash: String, name: String, size: Int64, seeders: Int, leechers: Int, added: Date?,
                category: SearchCategory, sources: [SourceHit], trackers: [String], uploader: String?) {
        self.infoHash = infoHash; self.name = name; self.size = size; self.seeders = seeders
        self.leechers = leechers; self.added = added; self.category = category; self.sources = sources
        self.trackers = trackers; self.uploader = uploader
    }

    public var magnet: String { InfoHash.magnet(hash: infoHash, name: name, trackers: trackers) }

    /// Unique badge labels, in source order.
    public var labels: [String] {
        var seen = Set<String>()
        return sources.map(\.label).filter { seen.insert($0).inserted }
    }

    /// Sort key for the Added column (unknown dates sort as oldest).
    public var addedOrDistantPast: Date { added ?? .distantPast }

    public var pirateBayID: String? { sources.lazy.compactMap(\.pirateBayID).first }
    public var torrentURLs: [URL] { sources.compactMap(\.torrentURL) }
}

/// Why a source gave no results this time.
public enum SearchFailure: Equatable, Sendable {
    case unavailable          // error status, bad response, or no answer in time
    case rateLimited          // the source's free daily allowance is used up
    case offline
}

extension TideSettings {
    /// The sources the user left on, in priority order.
    public var searchSources: [SearchSourceID] {
        let off = Set(searchDisabledSources ?? [])
        return SearchSourceID.allCases.filter { !off.contains($0.rawValue) }
    }

    public mutating func setSearchSource(_ source: SearchSourceID, enabled: Bool) {
        var off = Set(searchDisabledSources ?? [])
        if enabled { off.remove(source.rawValue) } else { off.insert(source.rawValue) }
        searchDisabledSources = off.isEmpty ? nil : SearchSourceID.allCases.map(\.rawValue).filter(off.contains)
    }

    public var showAdultResults: Bool { searchShowAdult ?? false }
}
