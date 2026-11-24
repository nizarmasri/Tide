//! Power-cut safety. aria2's `.aria2` file can claim pieces whose data was still in the OS page
//! cache when the power went. Tide snapshots each torrent's bitfield every 30 s; after a reboot
//! that interrupted Tide, only the pieces that became "done" after the last snapshot that was
//! certainly flushed (≥ 60 s before the crash) are re-verified — seconds instead of minutes.

use serde::{Deserialize, Serialize};
use std::path::{Path, PathBuf};
use std::time::{SystemTime, UNIX_EPOCH};

/// Pieces completed less than this long before a crash may not have reached the disk.
pub const FLUSH_MARGIN_SECS: i64 = 60;
const KEEP: usize = 6;

#[derive(Debug, Clone, Default, Serialize, Deserialize, PartialEq)]
pub struct Snapshot {
    pub ts: i64,
    pub bitfield_hex: String,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize, PartialEq)]
pub struct TaskJournal {
    pub snapshots: Vec<Snapshot>,
}

pub fn now() -> i64 {
    SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_secs() as i64).unwrap_or(0)
}

pub struct Journal {
    dir: PathBuf,
    marker: PathBuf,
}

impl Journal {
    pub fn new(support: &Path) -> Self {
        let dir = support.join("journal");
        let _ = std::fs::create_dir_all(&dir);
        Journal { dir, marker: support.join("running") }
    }

    /// Call at startup. Returns Some(crash time) if the previous run didn't shut down cleanly
    /// *and* the machine rebooted since (power cut / panic) — the only case where data can be lost.
    pub fn begin(&self) -> Option<i64> {
        let previous = std::fs::metadata(&self.marker).ok().and_then(|m| m.modified().ok()).map(|t| {
            t.duration_since(UNIX_EPOCH).map(|d| d.as_secs() as i64).unwrap_or(0)
        });
        let _ = std::fs::write(&self.marker, format!("{}\n", std::process::id()));
        let crashed_at = previous?;
        // The marker is touched on every journal write, so its mtime ≈ last time Tide was alive.
        let boot = boot_time()?;
        (boot > crashed_at).then_some(crashed_at)
    }

    /// Touches the running marker (≈ "alive at").
    pub fn heartbeat(&self) {
        let _ = std::fs::write(&self.marker, format!("{}\n", std::process::id()));
    }

    pub fn end(&self) {
        let _ = std::fs::remove_file(&self.marker);
    }

    fn path(&self, id: &str) -> PathBuf {
        self.dir.join(format!("{id}.json"))
    }

    pub fn load(&self, id: &str) -> TaskJournal {
        std::fs::read(self.path(id)).ok().and_then(|b| serde_json::from_slice(&b).ok()).unwrap_or_default()
    }

    pub fn record(&self, id: &str, bitfield_hex: &str) {
        let mut j = self.load(id);
        if j.snapshots.last().map(|s| s.bitfield_hex.as_str()) == Some(bitfield_hex) {
            // Unchanged: just bump nothing; the old timestamp is the conservative choice.
            return;
        }
        j.snapshots.push(Snapshot { ts: now(), bitfield_hex: bitfield_hex.to_string() });
        if j.snapshots.len() > KEEP {
            let drop = j.snapshots.len() - KEEP;
            j.snapshots.drain(..drop);
        }
        if let Ok(b) = serde_json::to_vec(&j) {
            let tmp = self.path(id).with_extension("tmp");
            if std::fs::write(&tmp, b).is_ok() {
                let _ = std::fs::rename(&tmp, self.path(id));
            }
        }
    }

    pub fn forget(&self, id: &str) {
        let _ = std::fs::remove_file(self.path(id));
    }
}

/// Pieces to re-verify after a crash at `crashed_at`: done in the control file but not in the
/// newest snapshot taken ≥ FLUSH_MARGIN before the crash. Without a usable snapshot every done
/// piece is suspect.
///
/// Pieces still in flight are never suspect: they can't pass a hash check (they're incomplete),
/// and aria2 hash-checks each piece when it completes, so blocks that never reached the disk just
/// make that piece fail and download again. Keeping their partial progress is safe.
pub fn suspects(control_bits: &[u8], piece_count: u32, journal: &TaskJournal, crashed_at: i64) -> Vec<u32> {
    let safe = journal
        .snapshots
        .iter()
        .rev()
        .find(|s| s.ts <= crashed_at - FLUSH_MARGIN_SECS)
        .and_then(|s| crate::torrent::unhex(&s.bitfield_hex));
    let has = |bits: &[u8], i: u32| bits.get((i / 8) as usize).is_some_and(|b| b & (0x80 >> (i % 8)) != 0);
    (0..piece_count).filter(|&i| has(control_bits, i) && safe.as_deref().map_or(true, |s| !has(s, i))).collect()
}

fn boot_time() -> Option<i64> {
    let mut tv = libc::timeval { tv_sec: 0, tv_usec: 0 };
    let mut size = std::mem::size_of::<libc::timeval>();
    let mut mib = [libc::CTL_KERN, libc::KERN_BOOTTIME];
    let r = unsafe {
        libc::sysctl(mib.as_mut_ptr(), 2, &mut tv as *mut _ as *mut libc::c_void, &mut size, std::ptr::null_mut(), 0)
    };
    (r == 0).then_some(tv.tv_sec as i64)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn suspect_set_is_only_recent_pieces() {
        // 16 pieces. Control says 0..=9 done; snapshot from 90 s before crash had 0..=5.
        let control = vec![0b1111_1111, 0b1100_0000];
        let j = TaskJournal {
            snapshots: vec![
                Snapshot { ts: 1000 - 90, bitfield_hex: "fc00".into() }, // 0..=5
                Snapshot { ts: 1000 - 10, bitfield_hex: "ff80".into() }, // too recent to trust
            ],
        };
        assert_eq!(suspects(&control, 16, &j, 1000), vec![6, 7, 8, 9]);
    }

    #[test]
    fn idle_before_the_crash_means_nothing_to_check() {
        // Paused for hours before the power went: the last snapshot matches the control file, so
        // nothing is suspect (in-flight pieces are left to aria2's own piece hash check).
        let control = vec![0b1111_0000];
        let j = TaskJournal { snapshots: vec![Snapshot { ts: 1000 - 6 * 3600, bitfield_hex: "f0".into() }] };
        assert!(suspects(&control, 8, &j, 1000).is_empty());
    }

    #[test]
    fn no_snapshot_means_all_done_pieces() {
        let control = vec![0b1010_0000];
        assert_eq!(suspects(&control, 8, &TaskJournal::default(), 1000), vec![0, 2]);
    }

    #[test]
    fn boot_time_is_sane() {
        let b = boot_time().unwrap();
        assert!(b > 1_600_000_000 && b <= now());
    }

    #[test]
    fn marker_lifecycle() {
        let d = tempfile::tempdir().unwrap();
        let j = Journal::new(d.path());
        assert_eq!(j.begin(), None); // first run
        // Marker exists now with mtime after boot → a crash without reboot isn't flagged.
        assert_eq!(j.begin(), None);
        j.end();
        assert!(!d.path().join("running").exists());
        j.record("t", "ff");
        j.record("t", "ff");
        assert_eq!(j.load("t").snapshots.len(), 1);
    }
}
