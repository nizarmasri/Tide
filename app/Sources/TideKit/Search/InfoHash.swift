import Foundation

/// BitTorrent v1 info hashes as search sources report them (40 hex or 32 base32 characters),
/// normalised to lowercase hex so results from different sources can be merged.
public enum InfoHash {
    /// Lowercase hex, or nil when the text isn't a hash or is all zeros (apibay's "no results" row).
    public static func normalize(_ raw: String) -> String? {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let hex: String
        if s.count == 40, s.allSatisfy(\.isHexDigit) {
            hex = s.lowercased()
        } else if s.count == 32, let bytes = base32(s) {
            hex = bytes.map { String(format: "%02x", $0) }.joined()
        } else {
            return nil
        }
        return hex.allSatisfy { $0 == "0" } ? nil : hex
    }

    private static let base32Alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567")

    private static func base32(_ s: String) -> [UInt8]? {
        var bits = 0, value = 0
        var out: [UInt8] = []
        for c in s.uppercased() {
            guard let i = base32Alphabet.firstIndex(of: c) else { return nil }
            value = (value << 5) | i
            bits += 5
            if bits >= 8 {
                bits -= 8
                out.append(UInt8((value >> bits) & 0xff))
            }
        }
        return out.count == 20 ? out : nil
    }

    /// The trackers (`tr`) of a magnet link, in order.
    public static func trackers(inMagnet link: String) -> [String] {
        guard let items = URLComponents(string: link)?.queryItems else { return [] }
        return items.filter { $0.name == "tr" }.compactMap(\.value).filter { !$0.isEmpty }
    }

    /// `magnet:?xt=urn:btih:<hash>&dn=<name>&tr=…`
    public static func magnet(hash: String, name: String, trackers: [String]) -> String {
        var s = "magnet:?xt=urn:btih:\(hash)"
        if !name.isEmpty { s += "&dn=\(escape(name))" }
        for t in trackers { s += "&tr=\(escape(t))" }
        return s
    }

    private static let unreserved = CharacterSet(charactersIn:
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    static func escape(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: unreserved) ?? s
    }
}
