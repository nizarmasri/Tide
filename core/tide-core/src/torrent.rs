//! .torrent metainfo parsing (BitTorrent v1), tracker sanitization and magnet links.

use crate::bencode::{self, Value};
use sha1::{Digest, Sha1};

#[derive(Debug, Clone, PartialEq)]
pub struct TorrentFile {
    /// aria2 1-based index.
    pub index: u32,
    /// Path relative to the download directory, including the torrent's root folder for
    /// multi-file torrents ("Name/sub/file.mkv"). "/"-separated.
    pub path: String,
    pub length: u64,
    /// Byte offset of this file in the concatenated torrent payload.
    pub offset: u64,
    pub is_padding: bool,
}

#[derive(Debug, Clone, PartialEq)]
pub struct Torrent {
    pub info_hash: String, // lowercase hex
    pub name: String,
    pub piece_length: u64,
    pub piece_hashes: Vec<[u8; 20]>,
    pub files: Vec<TorrentFile>,
    pub multi_file: bool,
    pub total_length: u64,
    pub trackers: Vec<String>, // sanitized, deduped, in tier order
    pub trackers_were_malformed: bool,
    pub private: bool,
    pub created_by: Option<String>,
    pub comment: Option<String>,
}

#[derive(Debug, Clone, PartialEq)]
pub enum TorrentError {
    Unreadable(String),
    Unsupported(String),
}

impl std::fmt::Display for TorrentError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            TorrentError::Unreadable(m) => write!(f, "unreadable torrent: {m}"),
            TorrentError::Unsupported(m) => write!(f, "unsupported torrent: {m}"),
        }
    }
}

impl Torrent {
    pub fn piece_count(&self) -> u32 {
        self.piece_hashes.len() as u32
    }

    /// Length of piece `i` (the last one is usually shorter).
    pub fn piece_len(&self, i: u32) -> u64 {
        let start = i as u64 * self.piece_length;
        self.piece_length.min(self.total_length.saturating_sub(start))
    }

    /// Indices of pieces that overlap any of the given files (1-based file indexes).
    pub fn pieces_for_files(&self, selected: &[u32]) -> Vec<u32> {
        let mut out = Vec::new();
        let mut last: Option<u32> = None;
        for f in self.files.iter().filter(|f| selected.contains(&f.index) && f.length > 0) {
            let first = (f.offset / self.piece_length) as u32;
            let end = ((f.offset + f.length - 1) / self.piece_length) as u32;
            for p in first..=end {
                if last.map_or(true, |l| p > l) || !out.contains(&p) {
                    out.push(p);
                }
            }
            last = Some(end);
        }
        out.sort_unstable();
        out.dedup();
        out
    }

    /// Bytes of the selected files covered by piece `p` — used to turn a bitfield into
    /// "bytes done of the selected files".
    pub fn selected_bytes_in_piece(&self, p: u32, selected: &[u32]) -> u64 {
        let ps = p as u64 * self.piece_length;
        let pe = ps + self.piece_len(p);
        self.files
            .iter()
            .filter(|f| selected.contains(&f.index))
            .map(|f| {
                let s = f.offset.max(ps);
                let e = (f.offset + f.length).min(pe);
                e.saturating_sub(s)
            })
            .sum()
    }

    pub fn selected_length(&self, selected: &[u32]) -> u64 {
        self.files.iter().filter(|f| selected.contains(&f.index)).map(|f| f.length).sum()
    }

    pub fn all_indexes(&self) -> Vec<u32> {
        self.files.iter().map(|f| f.index).collect()
    }

    /// Magnet link for "Copy Magnet Link".
    pub fn magnet(&self) -> String {
        let mut s = format!("magnet:?xt=urn:btih:{}&dn={}", self.info_hash, percent_encode(&self.name));
        for t in self.trackers.iter().take(10) {
            s.push_str("&tr=");
            s.push_str(&percent_encode(t));
        }
        s
    }
}

pub fn parse(data: &[u8]) -> Result<Torrent, TorrentError> {
    let (root, span) = bencode::decode_with_span(data, b"info")
        .map_err(|e| TorrentError::Unreadable(e.to_string()))?;
    let (s, e) = span.ok_or_else(|| TorrentError::Unreadable("no info dictionary".into()))?;
    let info = root.get("info").ok_or_else(|| TorrentError::Unreadable("no info dictionary".into()))?;
    let info_hash = hex(&Sha1::digest(&data[s..e]));

    let name = info
        .get("name.utf-8")
        .or_else(|| info.get("name"))
        .and_then(Value::as_str)
        .map(|n| sanitize_component(&n))
        .filter(|n| !n.is_empty())
        .ok_or_else(|| TorrentError::Unreadable("no name".into()))?;

    let piece_length = info
        .get("piece length")
        .and_then(Value::as_int)
        .filter(|&l| l > 0)
        .ok_or_else(|| {
            if info.get("meta version").and_then(Value::as_int) == Some(2) {
                TorrentError::Unsupported("BitTorrent v2-only torrent".into())
            } else {
                TorrentError::Unreadable("no piece length".into())
            }
        })? as u64;

    let pieces = match info.get("pieces").and_then(Value::as_bytes) {
        Some(p) if !p.is_empty() && p.len() % 20 == 0 => p,
        _ if info.get("meta version").and_then(Value::as_int) == Some(2) => {
            return Err(TorrentError::Unsupported("BitTorrent v2-only torrent".into()));
        }
        _ => return Err(TorrentError::Unreadable("bad piece hashes".into())),
    };
    let piece_hashes: Vec<[u8; 20]> = pieces.chunks_exact(20).map(|c| c.try_into().unwrap()).collect();

    let mut files = Vec::new();
    let mut offset = 0u64;
    let multi_file;
    if let Some(list) = info.get("files").and_then(Value::as_list) {
        multi_file = true;
        for (i, f) in list.iter().enumerate() {
            let length = f.get("length").and_then(Value::as_int).filter(|&l| l >= 0)
                .ok_or_else(|| TorrentError::Unreadable("file without length".into()))? as u64;
            let parts = f.get("path.utf-8").or_else(|| f.get("path")).and_then(Value::as_list)
                .ok_or_else(|| TorrentError::Unreadable("file without path".into()))?;
            let mut path = name.clone();
            for p in parts {
                let comp = sanitize_component(&p.as_str().unwrap_or_default());
                if comp.is_empty() { continue; }
                path.push('/');
                path.push_str(&comp);
            }
            let attr = f.get("attr").and_then(Value::as_str).unwrap_or_default();
            let last = path.rsplit('/').next().unwrap_or("");
            let is_padding = attr.contains('p') || last.starts_with(".pad") || last.starts_with("_____padding_file");
            files.push(TorrentFile { index: i as u32 + 1, path, length, offset, is_padding });
            offset += length;
        }
        if files.is_empty() {
            return Err(TorrentError::Unreadable("empty file list".into()));
        }
    } else {
        multi_file = false;
        let length = info.get("length").and_then(Value::as_int).filter(|&l| l >= 0)
            .ok_or_else(|| TorrentError::Unreadable("no length".into()))? as u64;
        files.push(TorrentFile { index: 1, path: name.clone(), length, offset: 0, is_padding: false });
        offset = length;
    }
    let total_length = offset;
    let expected_pieces = total_length.div_ceil(piece_length);
    if expected_pieces != piece_hashes.len() as u64 {
        return Err(TorrentError::Unreadable(format!(
            "piece count mismatch: {} hashes for {} pieces", piece_hashes.len(), expected_pieces
        )));
    }

    let mut raw_trackers = Vec::new();
    if let Some(a) = root.get("announce").and_then(Value::as_str) {
        raw_trackers.push(a);
    }
    if let Some(tiers) = root.get("announce-list").and_then(Value::as_list) {
        for tier in tiers {
            if let Some(list) = tier.as_list() {
                raw_trackers.extend(list.iter().filter_map(Value::as_str));
            } else if let Some(s) = tier.as_str() {
                raw_trackers.push(s);
            }
        }
    }
    let (trackers, malformed) = sanitize_trackers(&raw_trackers);

    Ok(Torrent {
        info_hash,
        name,
        piece_length,
        piece_hashes,
        files,
        multi_file,
        total_length,
        trackers,
        trackers_were_malformed: malformed,
        private: info.get("private").and_then(Value::as_int) == Some(1),
        created_by: root.get("created by").and_then(Value::as_str).filter(|s| !s.is_empty()),
        comment: root.get("comment").and_then(Value::as_str).filter(|s| !s.is_empty()),
    })
}

/// Strips embedded whitespace (some torrents carry "udp://new-\n  line.net"), drops entries that
/// aren't valid tracker URLs and dedupes, keeping order. Returns (trackers, anything_changed).
pub fn sanitize_trackers(raw: &[String]) -> (Vec<String>, bool) {
    let mut out: Vec<String> = Vec::new();
    let mut changed = false;
    for r in raw {
        let cleaned: String = r.chars().filter(|c| !c.is_whitespace() && !c.is_control()).collect();
        if cleaned != *r {
            changed = true;
        }
        let lower = cleaned.to_ascii_lowercase();
        let valid_scheme = ["http://", "https://", "udp://", "wss://"].iter().any(|s| lower.starts_with(s));
        let host_ok = cleaned.split("://").nth(1).map(|rest| {
            let host = rest.split(['/', ':']).next().unwrap_or("");
            !host.is_empty() && host.contains('.') || host.starts_with('[')
        }).unwrap_or(false);
        if !valid_scheme || !host_ok {
            changed = true;
            continue;
        }
        if out.iter().any(|t| t.eq_ignore_ascii_case(&cleaned)) {
            changed = true;
            continue;
        }
        out.push(cleaned);
    }
    (out, changed)
}

fn sanitize_component(s: &str) -> String {
    s.chars().map(|c| if c == '/' || c == '\0' { '_' } else { c }).collect::<String>().trim().to_string()
}

pub fn hex(b: &[u8]) -> String {
    const H: &[u8; 16] = b"0123456789abcdef";
    let mut s = String::with_capacity(b.len() * 2);
    for &x in b {
        s.push(H[(x >> 4) as usize] as char);
        s.push(H[(x & 15) as usize] as char);
    }
    s
}

pub fn unhex(s: &str) -> Option<Vec<u8>> {
    if s.len() % 2 != 0 { return None; }
    (0..s.len()).step_by(2).map(|i| u8::from_str_radix(&s[i..i + 2], 16).ok()).collect()
}

pub fn percent_encode(s: &str) -> String {
    let mut out = String::new();
    for b in s.bytes() {
        if b.is_ascii_alphanumeric() || b"-_.~".contains(&b) {
            out.push(b as char);
        } else {
            out.push_str(&format!("%{b:02X}"));
        }
    }
    out
}

pub fn percent_decode(s: &str, plus_is_space: bool) -> String {
    let bytes = s.as_bytes();
    let mut out = Vec::with_capacity(bytes.len());
    let mut i = 0;
    while i < bytes.len() {
        match bytes[i] {
            b'%' if i + 2 < bytes.len() => {
                if let Some(v) = std::str::from_utf8(&bytes[i + 1..i + 3]).ok().and_then(|h| u8::from_str_radix(h, 16).ok()) {
                    out.push(v);
                    i += 3;
                    continue;
                }
                out.push(b'%');
                i += 1;
            }
            b'+' if plus_is_space => { out.push(b' '); i += 1; }
            c => { out.push(c); i += 1; }
        }
    }
    String::from_utf8_lossy(&out).into_owned()
}

#[derive(Debug, Clone, PartialEq)]
pub struct Magnet {
    pub info_hash: String, // lowercase hex
    pub name: Option<String>,
    pub trackers: Vec<String>,
}

pub fn parse_magnet(uri: &str) -> Option<Magnet> {
    let rest = uri.trim().strip_prefix("magnet:?").or_else(|| uri.trim().strip_prefix("magnet:"))?;
    let mut info_hash = None;
    let mut name = None;
    let mut raw_trackers = Vec::new();
    for pair in rest.split('&') {
        let (k, v) = pair.split_once('=').unwrap_or((pair, ""));
        match k {
            "xt" => {
                let v = percent_decode(v, false);
                if let Some(h) = v.strip_prefix("urn:btih:").or_else(|| v.strip_prefix("urn:BTIH:")) {
                    info_hash = normalize_btih(h);
                }
            }
            "dn" => name = Some(percent_decode(v, true)).filter(|s| !s.trim().is_empty()),
            "tr" => raw_trackers.push(percent_decode(v, false)),
            _ => {}
        }
    }
    let (trackers, _) = sanitize_trackers(&raw_trackers);
    Some(Magnet { info_hash: info_hash?, name, trackers })
}

fn normalize_btih(h: &str) -> Option<String> {
    if h.len() == 40 && h.chars().all(|c| c.is_ascii_hexdigit()) {
        return Some(h.to_ascii_lowercase());
    }
    if h.len() == 32 {
        // base32
        let alphabet = b"ABCDEFGHIJKLMNOPQRSTUVWXYZ234567";
        let mut bits: u64 = 0;
        let mut nbits = 0;
        let mut out = Vec::new();
        for c in h.to_ascii_uppercase().bytes() {
            let v = alphabet.iter().position(|&a| a == c)? as u64;
            bits = (bits << 5) | v;
            nbits += 5;
            if nbits >= 8 {
                nbits -= 8;
                out.push((bits >> nbits) as u8);
                bits &= (1 << nbits) - 1;
            }
        }
        if out.len() == 20 {
            return Some(hex(&out));
        }
    }
    None
}

#[cfg(test)]
mod tests {
    use super::*;

    pub fn make_torrent(name: &str, files: &[(&str, u64)], piece_length: u64, data: &[u8], trackers: &[&str]) -> Vec<u8> {
        // Builds a real bencoded multi-file torrent whose piece hashes match `data`.
        let mut pieces = Vec::new();
        for chunk in data.chunks(piece_length as usize) {
            pieces.extend_from_slice(&Sha1::digest(chunk));
        }
        let mut info = Vec::new();
        info.extend_from_slice(b"d5:filesl");
        for (p, l) in files {
            info.extend_from_slice(format!("d6:lengthi{l}e4:pathl{}:{}ee", p.len(), p).as_bytes());
        }
        info.extend_from_slice(format!("e4:name{}:{}12:piece lengthi{piece_length}e6:pieces{}:", name.len(), name, pieces.len()).as_bytes());
        info.extend_from_slice(&pieces);
        info.push(b'e');
        let mut t = Vec::new();
        t.extend_from_slice(b"d");
        if let Some(first) = trackers.first() {
            t.extend_from_slice(format!("8:announce{}:{}", first.len(), first).as_bytes());
            t.extend_from_slice(b"13:announce-listl");
            for tr in trackers {
                t.extend_from_slice(format!("l{}:{}e", tr.len(), tr).as_bytes());
            }
            t.push(b'e');
        }
        t.extend_from_slice(b"4:info");
        t.extend_from_slice(&info);
        t.push(b'e');
        t
    }

    #[test]
    fn parses_synthetic_multi_file() {
        let data: Vec<u8> = (0..10_000u32).map(|i| (i % 251) as u8).collect();
        let raw = make_torrent("Movie", &[("movie.mkv", 9_000), ("info.txt", 1_000)], 4096, &data,
                               &["udp://tracker.example.org:1337/announce", "udp://new-\n  line.net:6969/announce", "udp://tracker.example.org:1337/announce", "garbage"]);
        let t = parse(&raw).unwrap();
        assert_eq!(t.name, "Movie");
        assert_eq!(t.files.len(), 2);
        assert_eq!(t.files[1].offset, 9_000);
        assert_eq!(t.piece_count(), 3);
        assert_eq!(t.piece_len(2), 10_000 - 8192);
        assert_eq!(t.trackers, vec!["udp://tracker.example.org:1337/announce", "udp://new-line.net:6969/announce"]);
        assert!(t.trackers_were_malformed);
        assert_eq!(t.pieces_for_files(&[2]), vec![2]);
        assert_eq!(t.pieces_for_files(&[1]), vec![0, 1, 2]);
        assert_eq!(t.selected_bytes_in_piece(2, &[1]), 9_000 - 8192);
    }

    #[test]
    fn rejects_garbage() {
        assert!(matches!(parse(b"not a torrent"), Err(TorrentError::Unreadable(_))));
        assert!(matches!(parse(b"d4:infod4:name1:xee"), Err(TorrentError::Unreadable(_))));
    }

    #[test]
    fn magnet_hex_and_base32() {
        let m = parse_magnet("magnet:?xt=urn:btih:DD8255ECDC7CA55FB0BBF81323D87062DB1F6D1C&dn=Big+Buck+Bunny&tr=udp%3A%2F%2Ftracker.opentrackr.org%3A1337%2Fannounce").unwrap();
        assert_eq!(m.info_hash, "dd8255ecdc7ca55fb0bbf81323d87062db1f6d1c");
        assert_eq!(m.name.as_deref(), Some("Big Buck Bunny"));
        assert_eq!(m.trackers, vec!["udp://tracker.opentrackr.org:1337/announce"]);
        let b32 = parse_magnet("magnet:?xt=urn:btih:WOEM2DRYZ2BTWFHPUKQXOOS7SGUN3B75").unwrap();
        assert_eq!(b32.info_hash.len(), 40);
        assert!(parse_magnet("https://example.com").is_none());
    }

    /// Optional check against a real torrent on disk: set TIDE_REAL_TORRENT to a .torrent file
    /// (ideally one with a half-finished aria2 download next to it). Skipped otherwise.
    #[test]
    fn real_torrent_from_env() {
        let Ok(path) = std::env::var("TIDE_REAL_TORRENT") else { return };
        let raw = std::fs::read(&path).expect("TIDE_REAL_TORRENT readable");
        let t = parse(&raw).unwrap();
        assert_eq!(t.info_hash.len(), 40);
        assert_eq!(t.piece_count() as u64, t.total_length.div_ceil(t.piece_length));
        assert!(t.trackers.iter().all(|t| !t.chars().any(char::is_whitespace)));
        // aria2 names saved metadata <infohash>.torrent; if so, the hash must match the name.
        let stem = std::path::Path::new(&path).file_stem().unwrap().to_string_lossy().to_lowercase();
        if stem.len() == 40 && stem.chars().all(|c| c.is_ascii_hexdigit()) {
            assert_eq!(t.info_hash, stem);
        }
    }
}

#[cfg(test)]
pub use tests::make_torrent;
