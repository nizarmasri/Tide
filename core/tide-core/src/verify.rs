//! Fast piece verification. Only checks what it's asked to (suspect pieces after a power cut, or
//! everything when progress data is missing), in parallel, without polluting the page cache.
//! Sparse holes (APFS) and all-zero pieces (exFAT zero-fills) are rejected without hashing.

use crate::torrent::Torrent;
use rayon::prelude::*;
use sha1::{Digest, Sha1};
use std::fs::File;
use std::os::fd::AsRawFd;
use std::os::unix::fs::FileExt;
use std::path::Path;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::Arc;
use std::time::{Duration, Instant};

#[derive(Debug, Clone, PartialEq)]
pub struct VerifyResult {
    /// Pieces that passed (subset of the requested ones).
    pub good: Vec<u32>,
    /// Pieces that failed or are missing.
    pub bad: Vec<u32>,
    pub bytes_read: u64,
    pub elapsed: Duration,
    pub cancelled: bool,
}

impl VerifyResult {
    pub fn throughput(&self) -> Option<f64> {
        let s = self.elapsed.as_secs_f64();
        (s > 0.05 && self.bytes_read > 0).then(|| self.bytes_read as f64 / s)
    }
}

struct OpenFile {
    file: Option<File>,
    /// SEEK_DATA is only trustworthy on APFS: macOS's exFAT driver reports "holes" over real data.
    sparse_aware: bool,
    offset: u64, // in the torrent payload
    length: u64,
}

fn open_nocache(path: &Path) -> Option<File> {
    let f = File::open(path).ok()?;
    unsafe {
        libc::fcntl(f.as_raw_fd(), libc::F_NOCACHE, 1);
    }
    Some(f)
}

/// True if [off, off+len) of `f` contains no data at all (a sparse hole), via SEEK_DATA.
fn is_hole(f: &File, off: u64, len: u64) -> bool {
    let r = unsafe { libc::lseek(f.as_raw_fd(), off as libc::off_t, libc::SEEK_DATA) };
    if r < 0 {
        // ENXIO: no data at or after `off`. Any other error: unknown, so read it.
        return std::io::Error::last_os_error().raw_os_error() == Some(libc::ENXIO);
    }
    (r as u64) >= off + len
}

/// Verifies `pieces` of `torrent` stored under `dir`. `progress(done_bytes, total_bytes)` is
/// called from worker threads (throttled). Uses up to `threads` threads.
pub fn verify_pieces(
    torrent: &Torrent,
    dir: &Path,
    pieces: &[u32],
    threads: usize,
    cancel: &AtomicBool,
    progress: &(dyn Fn(u64, u64) + Sync),
) -> VerifyResult {
    let start = Instant::now();
    let files: Vec<OpenFile> = torrent
        .files
        .iter()
        .map(|f| {
            let path = dir.join(&f.path);
            let sparse_aware = crate::volume::fs_type(&path).is_some_and(|t| t == "apfs");
            OpenFile { file: open_nocache(&path), sparse_aware, offset: f.offset, length: f.length }
        })
        .collect();
    let total_bytes: u64 = pieces.iter().map(|&p| torrent.piece_len(p)).sum();
    let done = AtomicU64::new(0);
    let last_report = std::sync::Mutex::new(Instant::now());

    let pool = rayon::ThreadPoolBuilder::new().num_threads(threads.max(1)).build().expect("thread pool");
    let results: Vec<(u32, bool, u64)> = pool.install(|| {
        pieces
            .par_iter()
            .map_init(
                || vec![0u8; torrent.piece_length as usize],
                |buf, &p| {
                    if cancel.load(Ordering::Relaxed) {
                        return (p, false, 0);
                    }
                    let (ok, read) = check_piece(torrent, &files, p, buf);
                    let d = done.fetch_add(torrent.piece_len(p), Ordering::Relaxed) + torrent.piece_len(p);
                    if let Ok(mut t) = last_report.try_lock() {
                        if t.elapsed() >= Duration::from_millis(200) {
                            *t = Instant::now();
                            progress(d, total_bytes);
                        }
                    }
                    (p, ok, read)
                },
            )
            .collect()
    });
    progress(done.load(Ordering::Relaxed), total_bytes);

    let cancelled = cancel.load(Ordering::Relaxed);
    let mut good = Vec::new();
    let mut bad = Vec::new();
    let mut bytes_read = 0;
    for (p, ok, read) in results {
        bytes_read += read;
        if ok { good.push(p) } else { bad.push(p) }
    }
    good.sort_unstable();
    bad.sort_unstable();
    VerifyResult { good, bad, bytes_read, elapsed: start.elapsed(), cancelled }
}

/// Returns (hash matches, bytes actually read).
fn check_piece(t: &Torrent, files: &[OpenFile], p: u32, buf: &mut [u8]) -> (bool, u64) {
    let plen = t.piece_len(p) as usize;
    let pstart = p as u64 * t.piece_length;
    let pend = pstart + plen as u64;
    let buf = &mut buf[..plen];
    let mut read_total = 0u64;
    for f in files.iter().filter(|f| f.length > 0 && f.offset < pend && f.offset + f.length > pstart) {
        let s = f.offset.max(pstart);
        let e = (f.offset + f.length).min(pend);
        let file_off = s - f.offset;
        let len = (e - s) as usize;
        let dst = &mut buf[(s - pstart) as usize..(s - pstart) as usize + len];
        let Some(file) = &f.file else { return (false, read_total) };
        if f.sparse_aware && is_hole(file, file_off, len as u64) {
            return (false, read_total);
        }
        let mut got = 0;
        while got < len {
            match file.read_at(&mut dst[got..], file_off + got as u64) {
                Ok(0) => return (false, read_total), // short file
                Ok(n) => got += n,
                Err(e) if e.kind() == std::io::ErrorKind::Interrupted => continue,
                Err(_) => return (false, read_total),
            }
        }
        read_total += len as u64;
    }
    // exFAT zero-fills the unwritten parts of a preallocated file: an all-zero piece is missing
    // data (a genuinely all-zero 4 MiB piece of a video doesn't happen in practice).
    if buf.iter().all(|&b| b == 0) {
        return (false, read_total);
    }
    (Sha1::digest(&buf[..]).as_slice() == t.piece_hashes[p as usize], read_total)
}

/// Reads up to 128 MiB from `path` (uncached) to estimate drive throughput in bytes/s.
pub fn measure_read_throughput(path: &Path) -> Option<f64> {
    let f = open_nocache(path)?;
    let size = f.metadata().ok()?.len();
    if size == 0 { return None; }
    let chunk = 8 * 1024 * 1024;
    let mut buf = vec![0u8; chunk];
    let start = Instant::now();
    let mut read = 0u64;
    // Sample from the middle so a hole at the start doesn't fake a fast number.
    let mut off = size / 3;
    while read < 128 * 1024 * 1024 && off < size && start.elapsed() < Duration::from_secs(2) {
        match f.read_at(&mut buf, off) {
            Ok(0) | Err(_) => break,
            Ok(n) => { read += n as u64; off += n as u64; }
        }
    }
    let s = start.elapsed().as_secs_f64();
    (read > 0 && s > 0.0).then(|| (read as f64 / s) * 3.0) // parallel reads run ~3× a single stream
}

/// Shared cancel + progress state for a running verification, readable from the engine thread.
#[derive(Default)]
pub struct VerifyJob {
    pub cancel: AtomicBool,
    pub done_bytes: AtomicU64,
    pub total_bytes: AtomicU64,
    pub started: std::sync::Mutex<Option<Instant>>,
}

impl VerifyJob {
    pub fn new(total: u64) -> Arc<Self> {
        let j = VerifyJob::default();
        j.total_bytes.store(total, Ordering::Relaxed);
        *j.started.lock().unwrap() = Some(Instant::now());
        Arc::new(j)
    }
    pub fn fraction(&self) -> f64 {
        let t = self.total_bytes.load(Ordering::Relaxed);
        if t == 0 { return 0.0; }
        self.done_bytes.load(Ordering::Relaxed) as f64 / t as f64
    }
    pub fn seconds_left(&self) -> Option<u32> {
        let started = (*self.started.lock().unwrap())?;
        let el = started.elapsed().as_secs_f64();
        let d = self.done_bytes.load(Ordering::Relaxed) as f64;
        let t = self.total_bytes.load(Ordering::Relaxed) as f64;
        (el > 1.0 && d > 0.0).then(|| ((t - d) / (d / el)).max(0.0) as u32)
    }
}


#[cfg(test)]
mod tests {
    use super::*;
    use crate::torrent::{make_torrent, parse};
    use std::io::Write;

    fn setup() -> (tempfile::TempDir, Torrent, Vec<u8>) {
        let data: Vec<u8> = (0..50_000u32).map(|i| ((i * 7 + 3) % 251) as u8 + 1).collect();
        let raw = make_torrent("T", &[("a.bin", 30_000), ("b.bin", 20_000)], 8192, &data, &[]);
        let t = parse(&raw).unwrap();
        let dir = tempfile::tempdir().unwrap();
        std::fs::create_dir_all(dir.path().join("T")).unwrap();
        std::fs::write(dir.path().join("T/a.bin"), &data[..30_000]).unwrap();
        std::fs::write(dir.path().join("T/b.bin"), &data[30_000..]).unwrap();
        (dir, t, data)
    }

    #[test]
    fn all_good() {
        let (dir, t, _) = setup();
        let all: Vec<u32> = (0..t.piece_count()).collect();
        let r = verify_pieces(&t, dir.path(), &all, 4, &AtomicBool::new(false), &|_, _| {});
        assert_eq!(r.good, all);
        assert!(r.bad.is_empty());
    }

    #[test]
    fn detects_corruption_zeros_and_missing() {
        let (dir, t, data) = setup();
        // Corrupt one byte in piece 1, zero piece 4 (spans the file boundary at 30000? piece 3 does).
        let mut a = data[..30_000].to_vec();
        a[9000] ^= 0xff;
        std::fs::write(dir.path().join("T/a.bin"), &a).unwrap();
        let mut b = data[30_000..].to_vec();
        for x in &mut b[(32768 - 30_000)..(40960 - 30_000)] { *x = 0; }
        std::fs::write(dir.path().join("T/b.bin"), &b).unwrap();
        let all: Vec<u32> = (0..t.piece_count()).collect();
        let r = verify_pieces(&t, dir.path(), &all, 2, &AtomicBool::new(false), &|_, _| {});
        assert_eq!(r.bad, vec![1, 4]);

        std::fs::remove_file(dir.path().join("T/b.bin")).unwrap();
        let r = verify_pieces(&t, dir.path(), &all, 2, &AtomicBool::new(false), &|_, _| {});
        // Pieces touching b.bin (3 spans both files) fail.
        assert!(r.bad.contains(&3) && r.bad.contains(&5) && r.bad.contains(&6));
        assert!(r.good.contains(&0));
    }

    #[test]
    fn sparse_hole_is_missing() {
        let (dir, t, data) = setup();
        // Recreate a.bin as sparse: data only in the first 8192 bytes.
        let p = dir.path().join("T/a.bin");
        let mut f = std::fs::File::create(&p).unwrap();
        f.write_all(&data[..8192]).unwrap();
        f.set_len(30_000).unwrap();
        drop(f);
        let r = verify_pieces(&t, dir.path(), &[0, 1, 2], 2, &AtomicBool::new(false), &|_, _| {});
        assert_eq!(r.good, vec![0]);
        assert_eq!(r.bad, vec![1, 2]);
    }

    /// Read-only regression for the exFAT SEEK_DATA bug: finished pieces of a real download
    /// (TIDE_REAL_TORRENT, with its .aria2 next to it) must verify as good. Skipped otherwise.
    #[test]
    fn real_finished_pieces_are_good() {
        let Ok(tp) = std::env::var("TIDE_REAL_TORRENT") else { return };
        let dir = std::path::Path::new(&tp).parent().unwrap();
        let t = parse(&std::fs::read(&tp).unwrap()).unwrap();
        let Ok(c) = crate::control_file::ControlFile::read(&dir.join(format!("{}.aria2", t.name))) else { return };
        let done: Vec<u32> = (0..c.piece_count()).filter(|&i| c.has(i)).collect();
        if done.is_empty() { return; }
        let pick: Vec<u32> = done.iter().copied().step_by((done.len() / 40).max(1)).take(40).collect();
        let r = verify_pieces(&t, dir, &pick, 4, &AtomicBool::new(false), &|_, _| {});
        assert!(r.bad.is_empty(), "good data reported bad: {:?}", r.bad);
    }

    #[test]
    fn cancel_stops_early() {
        let (dir, t, _) = setup();
        let cancel = AtomicBool::new(true);
        let r = verify_pieces(&t, dir.path(), &[0, 1, 2], 1, &cancel, &|_, _| {});
        assert!(r.cancelled);
        assert!(r.good.is_empty());
    }
}
