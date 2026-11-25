import Foundation

/// Canned search results for previews and the render matrix: open movies and Linux images.
public extension PreviewFixtures {
    private static func src(_ s: SearchSourceID, _ label: String? = nil) -> SourceHit { SourceHit(source: s, label: label) }
    private static func daysAgo(_ d: Double) -> Date { now.addingTimeInterval(-d * 86_400) }

    static let searchResults: [SearchResult] = [
        SearchResult(infoHash: "209c8226b299b308beaf2b9cd3fb49212dbd13ec", name: "Tears.of.Steel.2012.4K.HDR",
                     size: 72_814_624_030, seeders: 412, leechers: 96, added: daysAgo(31), category: .movies,
                     sources: [src(.knaben, "The Pirate Bay"), src(.bitsearch)], trackers: DefaultTrackers.list,
                     uploader: "blender"),
        SearchResult(infoHash: "dafc8c076ca2f3ed376eeae7c76a0d6be2415c45", name: "ubuntu-26.04-desktop-amd64.iso",
                     size: 6_517_612_871, seeders: 147, leechers: 108, added: daysAgo(214), category: .apps,
                     sources: [src(.knaben, "The Pirate Bay"), src(.bitsearch), src(.torrentscsv)],
                     trackers: DefaultTrackers.list, uploader: nil),
        SearchResult(infoHash: "08ada5a7a6183aae1e09d831df6748d566095a10", name: "Sintel.2010.1080p.mkv",
                     size: 1_448_431_616, seeders: 88, leechers: 12, added: daysAgo(900), category: .movies,
                     sources: [src(.bitsearch)], trackers: DefaultTrackers.list, uploader: nil),
        SearchResult(infoHash: "dd8255ecdc7ca55fb0bbf81323d87062db1f6d1c", name: "Big Buck Bunny 2008 4K 60fps",
                     size: 10_861_000_000, seeders: 61, leechers: 4, added: daysAgo(1_400), category: .movies,
                     sources: [src(.knaben, "Nyaa"), src(.piratebay)], trackers: DefaultTrackers.list, uploader: "peach"),
        SearchResult(infoHash: "4a3f5e08bcef825718eda30637230585e3330599", name: "ubuntu-24.04.1-desktop-amd64.iso",
                     size: 6_206_227_742, seeders: 47, leechers: 15, added: daysAgo(810), category: .apps,
                     sources: [src(.piratebay)], trackers: DefaultTrackers.list, uploader: "metheguy"),
        SearchResult(infoHash: "c9bc96d23542e5430f6bf8232b402a85172ca28b", name: "Cosmos Laundromat (2015) – First Cycle",
                     size: 2_210_000_000, seeders: 9, leechers: 1, added: nil, category: .other,
                     sources: [src(.torrentscsv)], trackers: DefaultTrackers.list, uploader: nil),
    ]
}
