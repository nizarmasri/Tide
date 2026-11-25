import Foundation

/// Folds the hits from every source into one result per torrent (by info hash).
public enum SearchMerger {
    static let maxTrackers = 12

    public static func merge(_ hits: [SearchHit], showAdult: Bool) -> [SearchResult] {
        var order: [String] = []
        var groups: [String: [SearchHit]] = [:]
        for h in hits {
            if groups[h.infoHash] == nil { order.append(h.infoHash) }
            groups[h.infoHash, default: []].append(h)
        }

        let results: [SearchResult] = order.compactMap { hash in
            let group = groups[hash]!.sorted { $0.origin.source.priority < $1.origin.source.priority }
            if !showAdult, group.contains(where: { $0.category == .adult }) { return nil }
            let first = group[0]

            var trackers: [String] = []
            var seen = Set<String>()
            for t in group.flatMap(\.trackers) where trackers.count < maxTrackers && seen.insert(t).inserted {
                trackers.append(t)
            }
            if trackers.isEmpty { trackers = DefaultTrackers.list }

            return SearchResult(
                infoHash: hash,
                name: first.name,
                size: commonSize(group.map(\.size)),
                seeders: group.map(\.seeders).max() ?? 0,
                leechers: group.map(\.leechers).max() ?? 0,
                added: group.compactMap(\.added).min(),
                category: group.first { $0.category != .other }?.category ?? .other,
                sources: group.map(\.origin),
                trackers: trackers,
                uploader: group.lazy.compactMap(\.uploader).first)
        }

        return results.sorted {
            if $0.seeders != $1.seeders { return $0.seeders > $1.seeders }
            if $0.leechers != $1.leechers { return $0.leechers > $1.leechers }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    /// The size most sources agree on (the larger one on a tie); zero when nobody knows.
    static func commonSize(_ sizes: [Int64]) -> Int64 {
        let known = sizes.filter { $0 > 0 }
        guard !known.isEmpty else { return 0 }
        var counts: [Int64: Int] = [:]
        for s in known { counts[s, default: 0] += 1 }
        return counts.max { a, b in a.value != b.value ? a.value < b.value : a.key < b.key }!.key
    }
}
