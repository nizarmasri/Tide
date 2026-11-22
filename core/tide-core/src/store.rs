//! Tide's library: the source of truth for downloads. aria2 is stateless underneath (no session
//! file): on every engine start Tide re-adds its tasks with their stable GIDs, and aria2's own
//! `.aria2` progress files make that resume instant.

use crate::scheduler::SlowModeState;
use serde::{Deserialize, Serialize};
use std::path::{Path, PathBuf};

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum Kind {
    Torrent,
    Magnet,
    Http,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum Intent {
    Run,
    Paused,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub enum Seed {
    Stop,
    Ratio(f64),
    Minutes(u32),
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct StoredProblem {
    pub code: i64,
    pub message: String,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Record {
    pub id: String,
    /// Stable aria2 GID (16 hex chars), reused on every re-add.
    pub gid: String,
    pub kind: Kind,
    pub name: String,
    pub dir: String,
    #[serde(default)]
    pub info_hash: Option<String>,
    /// Tide's own copy of the .torrent (support/torrents/<hash>.torrent).
    #[serde(default)]
    pub torrent_path: Option<String>,
    #[serde(default)]
    pub magnet: Option<String>,
    #[serde(default)]
    pub url: Option<String>,
    /// aria2 1-based file indexes; None = everything.
    #[serde(default)]
    pub selected: Option<Vec<u32>>,
    pub intent: Intent,
    #[serde(default)]
    pub start_at: Option<i64>,
    #[serde(default)]
    pub override_until: Option<i64>,
    #[serde(default)]
    pub ignore_auto_pause: bool,
    #[serde(default)]
    pub speed_limit: Option<u64>,
    #[serde(default)]
    pub seed: Option<Seed>,
    pub added_at: i64,
    #[serde(default)]
    pub completed_at: Option<i64>,
    /// Last known progress (shown while the drive is unplugged).
    #[serde(default)]
    pub completed_bytes: u64,
    #[serde(default)]
    pub total_bytes: u64,
    #[serde(default)]
    pub pieces_done: Option<u32>,
    #[serde(default)]
    pub order: i64,
    #[serde(default)]
    pub problem: Option<StoredProblem>,
    #[serde(default)]
    pub imported_at: Option<i64>,
    #[serde(default)]
    pub resumed_at: Option<i64>,
    /// Relative path of the main file under `dir`.
    #[serde(default)]
    pub primary_file: Option<String>,
    /// Imported without a progress file: verify before handing to aria2.
    #[serde(default)]
    pub needs_check: bool,
    /// Seeding finished (or stopped by the user) after completion.
    #[serde(default)]
    pub seeding_done: bool,
}

impl Record {
    pub fn is_complete(&self) -> bool {
        self.completed_at.is_some()
    }
    pub fn dir_path(&self) -> PathBuf {
        PathBuf::from(&self.dir)
    }
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct Library {
    #[serde(default)]
    pub version: u32,
    #[serde(default)]
    pub records: Vec<Record>,
    #[serde(default)]
    pub slow_mode: SlowModeState,
}

pub struct Store {
    path: PathBuf,
    pub torrents_dir: PathBuf,
}

impl Store {
    pub fn new(support: &Path) -> Self {
        let torrents_dir = support.join("torrents");
        let _ = std::fs::create_dir_all(&torrents_dir);
        Store { path: support.join("library.json"), torrents_dir }
    }

    pub fn load(&self) -> Library {
        match std::fs::read(&self.path) {
            Ok(b) => serde_json::from_slice(&b).unwrap_or_else(|_| {
                // Keep a corrupt file aside instead of silently dropping the user's list.
                let _ = std::fs::copy(&self.path, self.path.with_extension("json.corrupt"));
                Library::default()
            }),
            Err(_) => Library::default(),
        }
    }

    pub fn save(&self, lib: &Library) {
        let Ok(b) = serde_json::to_vec_pretty(lib) else { return };
        let tmp = self.path.with_extension("json.tmp");
        if std::fs::write(&tmp, b).is_ok() {
            let _ = std::fs::rename(&tmp, &self.path);
        }
    }

    pub fn save_torrent(&self, info_hash: &str, bytes: &[u8]) -> Option<String> {
        let p = self.torrents_dir.join(format!("{info_hash}.torrent"));
        if !p.exists() {
            std::fs::write(&p, bytes).ok()?;
        }
        Some(p.to_string_lossy().into_owned())
    }
}

pub fn new_gid() -> String {
    // aria2 GIDs are 64-bit hex; avoid all-zero.
    let mut g = crate::supervisor::random_hex(8);
    if g == "0000000000000000" {
        g = "0000000000000001".into();
    }
    g
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn round_trip_and_corrupt_file() {
        let d = tempfile::tempdir().unwrap();
        let s = Store::new(d.path());
        let mut lib = Library::default();
        lib.records.push(Record {
            id: "a".into(), gid: new_gid(), kind: Kind::Torrent, name: "n".into(), dir: "/tmp".into(),
            info_hash: Some("ab".into()), torrent_path: None, magnet: None, url: None, selected: Some(vec![1]),
            intent: Intent::Run, start_at: None, override_until: None, ignore_auto_pause: false, speed_limit: None,
            seed: Some(Seed::Ratio(1.5)), added_at: 1, completed_at: None, completed_bytes: 0, total_bytes: 10,
            pieces_done: None, order: 0, problem: None, imported_at: None, resumed_at: None, primary_file: None,
            needs_check: false, seeding_done: false,
        });
        s.save(&lib);
        let back = s.load();
        assert_eq!(back.records, lib.records);
        assert_eq!(back.records[0].gid.len(), 16);
        std::fs::write(d.path().join("library.json"), b"{nope").unwrap();
        assert!(s.load().records.is_empty());
        assert!(d.path().join("library.json.corrupt").exists());
    }
}
