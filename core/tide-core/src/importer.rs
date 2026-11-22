//! Finds unfinished aria2 downloads in a folder (torrent + `<name>.aria2` + data) and reports
//! their progress straight from the bitfield — no hashing.

use crate::control_file::ControlFile;
use crate::smart_select;
use crate::torrent::{self, Torrent};
use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::time::UNIX_EPOCH;

#[derive(Debug, Clone, PartialEq)]
pub struct Candidate {
    pub id: String, // info hash
    pub name: String,
    pub dir: PathBuf,
    pub info_hash: String,
    pub torrent_file: Option<PathBuf>,
    pub torrent: Option<Torrent>,
    pub progress_file: Option<PathBuf>,
    pub progress_saved_at: Option<i64>,
    pub data_path: Option<PathBuf>,
    pub control: Option<ControlFile>,
    pub selected: Vec<u32>,
    pub total_bytes: u64,
    pub completed_bytes: u64,
    pub needs_check: bool,
    pub estimated_check_secs: Option<u32>,
}

fn list(dir: &Path) -> Vec<PathBuf> {
    std::fs::read_dir(dir)
        .map(|rd| rd.filter_map(|e| e.ok()).map(|e| e.path()).collect())
        .unwrap_or_default()
}

fn is_hidden_junk(p: &Path) -> bool {
    p.file_name().and_then(|n| n.to_str()).is_some_and(|n| n.starts_with("._") || n == ".DS_Store")
}

/// Directories to scan: the folder itself and its immediate subfolders.
fn scan_dirs(root: &Path) -> Vec<PathBuf> {
    let mut dirs = vec![root.to_path_buf()];
    for p in list(root) {
        if p.is_dir() && !is_hidden_junk(&p) && !p.file_name().is_some_and(|n| n.to_string_lossy().starts_with('.')) {
            dirs.push(p);
        }
    }
    dirs
}

/// Other places .torrent files for an info hash commonly live.
fn extra_torrent_locations(support: &Path, info_hash: &str) -> Vec<PathBuf> {
    let home = std::env::var("HOME").unwrap_or_default();
    vec![
        support.join("torrents").join(format!("{info_hash}.torrent")),
        PathBuf::from(format!("{home}/Library/Application Support/Folx/TorrentFiles/{info_hash}.torrent")),
    ]
}

pub fn selected_progress(t: &Torrent, c: &ControlFile, selected: &[u32]) -> u64 {
    (0..t.piece_count()).filter(|&p| c.has(p)).map(|p| t.selected_bytes_in_piece(p, selected)).sum()
}

/// Scans `path` (a folder, or a .torrent/.aria2 inside one). `known` maps info hash → already
/// in the library. `throughput` (bytes/s) estimates check time for downloads without progress.
pub fn scan(path: &Path, support: &Path, only_main_video: bool, skip_extras: bool) -> Vec<Candidate> {
    let (root, only): (PathBuf, Option<PathBuf>) = if path.is_dir() {
        (path.to_path_buf(), None)
    } else {
        (path.parent().map(Path::to_path_buf).unwrap_or_default(), Some(path.to_path_buf()))
    };
    let dirs = scan_dirs(&root);

    // Index every readable .torrent by info hash.
    let mut torrents: HashMap<String, (PathBuf, Torrent)> = HashMap::new();
    for d in &dirs {
        for p in list(d) {
            if is_hidden_junk(&p) || p.extension().and_then(|e| e.to_str()) != Some("torrent") {
                continue;
            }
            if let Ok(b) = std::fs::read(&p) {
                if let Ok(t) = torrent::parse(&b) {
                    torrents.entry(t.info_hash.clone()).or_insert((p, t));
                }
            }
        }
    }

    let mut out: Vec<Candidate> = Vec::new();
    for d in &dirs {
        for p in list(d) {
            if is_hidden_junk(&p) || p.extension().and_then(|e| e.to_str()) != Some("aria2") {
                continue;
            }
            let Ok(c) = ControlFile::read(&p) else { continue };
            let Some(ih) = c.info_hash_hex() else { continue }; // HTTP progress: URL unknown, skip
            let name = p.file_stem().map(|s| s.to_string_lossy().into_owned()).unwrap_or_default();
            let mut found = torrents.get(&ih).cloned();
            if found.is_none() {
                for loc in extra_torrent_locations(support, &ih) {
                    if let Some(t) = std::fs::read(&loc).ok().and_then(|b| torrent::parse(&b).ok()) {
                        found = Some((loc, t));
                        break;
                    }
                }
            }
            let data = d.join(&name);
            let saved_at = std::fs::metadata(&p).ok().and_then(|m| m.modified().ok())
                .and_then(|t| t.duration_since(UNIX_EPOCH).ok()).map(|d| d.as_secs() as i64);
            let (selected, total, done) = match &found {
                Some((_, t)) => {
                    let sel = smart_select::select(&t.files, only_main_video, skip_extras).selected;
                    (sel.clone(), t.selected_length(&sel), selected_progress(t, &c, &sel))
                }
                None => {
                    let done = (0..c.piece_count()).filter(|&i| c.has(i)).count() as u64 * c.piece_length as u64;
                    (vec![], c.total_length, done.min(c.total_length))
                }
            };
            out.push(Candidate {
                id: ih.clone(),
                name: found.as_ref().map(|(_, t)| t.name.clone()).unwrap_or(name),
                dir: d.clone(),
                info_hash: ih,
                torrent_file: found.as_ref().map(|(p, _)| p.clone()),
                torrent: found.map(|(_, t)| t),
                progress_file: Some(p.clone()),
                progress_saved_at: saved_at,
                data_path: data.exists().then_some(data),
                control: Some(c),
                selected,
                total_bytes: total,
                completed_bytes: done,
                needs_check: false,
                estimated_check_secs: None,
            });
        }
    }

    // Torrents whose data is on disk but whose progress file is missing: verify first.
    for (ih, (tp, t)) in &torrents {
        if out.iter().any(|c| &c.info_hash == ih) {
            continue;
        }
        let dir = tp.parent().map(Path::to_path_buf).unwrap_or_else(|| root.clone());
        let data = dir.join(&t.name);
        if !data.exists() {
            continue;
        }
        let sel = smart_select::select(&t.files, only_main_video, skip_extras).selected;
        let total = t.selected_length(&sel);
        let main = t.files.iter().filter(|f| sel.contains(&f.index)).max_by_key(|f| f.length).map(|f| dir.join(&f.path));
        let est = main
            .as_deref()
            .and_then(crate::verify::measure_read_throughput)
            .map(|bps| (total as f64 / bps).ceil() as u32);
        out.push(Candidate {
            id: ih.clone(),
            name: t.name.clone(),
            dir,
            info_hash: ih.clone(),
            torrent_file: Some(tp.clone()),
            torrent: Some(t.clone()),
            progress_file: None,
            progress_saved_at: None,
            data_path: Some(data),
            control: None,
            selected: sel,
            total_bytes: total,
            completed_bytes: 0,
            needs_check: true,
            estimated_check_secs: est,
        });
    }

    if let Some(only) = only {
        let want_hash = std::fs::read(&only).ok().and_then(|b| torrent::parse(&b).ok()).map(|t| t.info_hash)
            .or_else(|| ControlFile::read(&only).ok().and_then(|c| c.info_hash_hex()));
        out.retain(|c| Some(&c.info_hash) == want_hash.as_ref());
    }
    out.sort_by(|a, b| b.progress_saved_at.cmp(&a.progress_saved_at).then(a.name.cmp(&b.name)));
    out
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::torrent::make_torrent;

    #[test]
    fn finds_partial_download_with_progress() {
        let d = tempfile::tempdir().unwrap();
        let data: Vec<u8> = (0..40_000u32).map(|i| (i % 200) as u8 + 1).collect();
        let raw = make_torrent("Film", &[("Film.mkv", 39_000), ("info.txt", 1_000)], 8192, &data, &[]);
        let t = torrent::parse(&raw).unwrap();
        std::fs::write(d.path().join(format!("{}.torrent", t.info_hash)), &raw).unwrap();
        std::fs::create_dir_all(d.path().join("Film")).unwrap();
        std::fs::write(d.path().join("Film/Film.mkv"), &data[..39_000]).unwrap();
        let mut c = ControlFile::new_bt(&torrent::unhex(&t.info_hash).unwrap(), 8192, 40_000, vec![0]);
        c.set(0, true);
        c.set(1, true);
        c.write(&d.path().join("Film.aria2")).unwrap();

        let support = tempfile::tempdir().unwrap();
        let found = scan(d.path(), support.path(), true, true);
        assert_eq!(found.len(), 1);
        let f = &found[0];
        assert_eq!(f.name, "Film");
        assert_eq!(f.selected, vec![1]);
        assert_eq!(f.completed_bytes, 16_384);
        assert_eq!(f.total_bytes, 39_000);
        assert!(!f.needs_check);
        assert!(f.data_path.is_some());

        // Picking the .aria2 file directly finds the same download.
        assert_eq!(scan(&d.path().join("Film.aria2"), support.path(), true, true).len(), 1);
    }

    #[test]
    fn torrent_with_data_but_no_progress_needs_check() {
        let d = tempfile::tempdir().unwrap();
        let data = vec![5u8; 20_000];
        let raw = make_torrent("X", &[("x.mkv", 20_000)], 8192, &data, &[]);
        std::fs::write(d.path().join("x.torrent"), &raw).unwrap();
        std::fs::create_dir_all(d.path().join("X")).unwrap();
        std::fs::write(d.path().join("X/x.mkv"), &data).unwrap();
        let support = tempfile::tempdir().unwrap();
        let found = scan(d.path(), support.path(), true, true);
        assert_eq!(found.len(), 1);
        assert!(found[0].needs_check);
    }

    /// Optional read-only scan of a real folder: the one holding TIDE_REAL_TORRENT. It must find
    /// that download straight from its progress file, without hashing. Skipped otherwise.
    #[test]
    fn real_folder_from_env() {
        let Ok(tp) = std::env::var("TIDE_REAL_TORRENT") else { return };
        let t = torrent::parse(&std::fs::read(&tp).unwrap()).unwrap();
        let dir = Path::new(&tp).parent().unwrap();
        if !dir.join(format!("{}.aria2", t.name)).exists() { return; }
        let support = tempfile::tempdir().unwrap();
        let start = std::time::Instant::now();
        let found = scan(dir, support.path(), true, true);
        let c = found.iter().find(|c| c.info_hash == t.info_hash).expect("download found");
        assert!(!c.needs_check);
        assert!(c.completed_bytes <= c.total_bytes);
        assert!(start.elapsed().as_secs() < 3, "scan must not hash");
    }
}
