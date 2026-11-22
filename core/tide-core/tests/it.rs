//! End-to-end: the real engine driving a real aria2c against a local, throttled HTTP server with
//! Range support. Run with `cargo test --features it -- --test-threads=1`.
#![cfg(feature = "it")]

use std::io::Read;
use std::path::PathBuf;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};
use tide_core::engine::{Engine, Sink};
use tide_core::model::*;

const SIZE: usize = 24 * 1024 * 1024;

fn payload() -> Vec<u8> {
    (0..SIZE).map(|i| ((i * 31 + 7) % 251) as u8).collect()
}

/// Serves /file.bin at ~4 MB/s per connection, honouring Range.
fn serve() -> (u16, Arc<Vec<u8>>) {
    let data = Arc::new(payload());
    let server = tiny_http::Server::http("127.0.0.1:0").unwrap();
    let port = server.server_addr().to_ip().unwrap().port();
    let d = data.clone();
    std::thread::spawn(move || {
        for req in server.incoming_requests() {
            let d = d.clone();
            std::thread::spawn(move || {
                let range = req.headers().iter().find(|h| h.field.equiv("Range")).map(|h| h.value.as_str().to_string());
                let (start, end) = range
                    .and_then(|r| r.strip_prefix("bytes=").map(str::to_string))
                    .map(|r| {
                        let (s, e) = r.split_once('-').unwrap_or((&r, ""));
                        (s.parse::<usize>().unwrap_or(0), e.parse::<usize>().ok().map(|e| e + 1).unwrap_or(d.len()))
                    })
                    .unwrap_or((0, d.len()));
                let end = end.min(d.len());
                let body = Throttled { data: d, pos: start, end };
                let mut resp = tiny_http::Response::new(
                    if start > 0 || end < SIZE { 206.into() } else { 200.into() },
                    vec![
                        "Accept-Ranges: bytes".parse().unwrap(),
                        format!("Content-Range: bytes {}-{}/{}", start, end - 1, SIZE).parse().unwrap(),
                    ],
                    body,
                    Some(end - start),
                    None,
                );
                resp = resp.with_chunked_threshold(usize::MAX);
                if start == 0 && end == SIZE {
                    resp = resp.with_status_code(200);
                }
                let _ = req.respond(resp);
            });
        }
    });
    (port, data)
}

struct Throttled {
    data: Arc<Vec<u8>>,
    pos: usize,
    end: usize,
}

impl Read for Throttled {
    fn read(&mut self, buf: &mut [u8]) -> std::io::Result<usize> {
        if self.pos >= self.end {
            return Ok(0);
        }
        std::thread::sleep(Duration::from_millis(8));
        let n = buf.len().min(32 * 1024).min(self.end - self.pos);
        buf[..n].copy_from_slice(&self.data[self.pos..self.pos + n]);
        self.pos += n;
        Ok(n)
    }
}

#[derive(Default)]
struct Capture {
    last: Mutex<Option<CoreSnapshot>>,
    events: Mutex<Vec<CoreEvent>>,
}

impl Sink for Capture {
    fn snapshot(&self, s: CoreSnapshot) {
        *self.last.lock().unwrap() = Some(s);
    }
    fn event(&self, e: CoreEvent) {
        self.events.lock().unwrap().push(e);
    }
}

fn aria2_path() -> String {
    std::env::var("TIDE_ARIA2").unwrap_or_else(|_| "/opt/homebrew/bin/aria2c".into())
}

struct Env {
    support: tempfile::TempDir,
    logs: tempfile::TempDir,
    downloads: tempfile::TempDir,
}

fn engine(env: &Env, cap: Arc<Capture>) -> Arc<Engine> {
    let e = Engine::new(CoreConfig {
        aria2_path: aria2_path(),
        support_dir: env.support.path().to_string_lossy().into(),
        log_dir: env.logs.path().to_string_lossy().into(),
        app_pid: std::process::id(),
    });
    let mut s = CoreSettings::default();
    s.default_directory = env.downloads.path().to_string_lossy().into();
    s.dht = false;
    s.lpd = false;
    s.listen_port = 40000 + (std::process::id() % 20000) as u16;
    e.start(s, cap);
    e.set_visible(true);
    e
}

fn wait_for(cap: &Capture, what: &str, secs: u64, f: impl Fn(&CoreSnapshot) -> bool) -> CoreSnapshot {
    let deadline = Instant::now() + Duration::from_secs(secs);
    loop {
        if let Some(s) = cap.last.lock().unwrap().clone() {
            if f(&s) {
                return s;
            }
        }
        if Instant::now() > deadline {
            panic!("timed out waiting for {what}; last = {:#?}", cap.last.lock().unwrap());
        }
        std::thread::sleep(Duration::from_millis(100));
    }
}

fn task(s: &CoreSnapshot) -> &CoreTask {
    &s.tasks[0]
}

#[test]
fn http_lifecycle_pause_resume_restart_crash() {
    let (port, data) = serve();
    let env = Env { support: tempfile::tempdir().unwrap(), logs: tempfile::tempdir().unwrap(), downloads: tempfile::tempdir().unwrap() };
    let cap = Arc::new(Capture::default());
    let e = engine(&env, cap.clone());
    wait_for(&cap, "engine running", 10, |s| matches!(s.engine, CoreEngineState::Running { .. }));

    // The RPC secret never appears on aria2c's command line.
    let ps = std::process::Command::new("ps").args(["-ww", "-o", "args=", "-c"]).output().ok();
    let all = std::process::Command::new("ps").args(["-ww", "-axo", "args="]).output().unwrap();
    let listing = String::from_utf8_lossy(&all.stdout);
    assert!(listing.contains("aria2c --conf-path="));
    assert!(!listing.lines().any(|l| l.contains("aria2c") && l.contains("rpc-secret")));
    drop(ps);

    let url = format!("http://127.0.0.1:{port}/file.bin");
    let preview = e.inspect(CoreSource::Link { link: url.clone() }, env.downloads.path().to_str().unwrap());
    assert_eq!(preview.name, "file.bin");
    assert_eq!(preview.kind, CoreKind::Http);
    let id = e
        .add(CoreAddRequest { source: CoreSource::Link { link: url.clone() }, directory: env.downloads.path().to_string_lossy().into(), selected_files: None, start: CoreStart::Now })
        .unwrap();
    assert!(e.add(CoreAddRequest { source: CoreSource::Link { link: url.clone() }, directory: env.downloads.path().to_string_lossy().into(), selected_files: None, start: CoreStart::Now }).is_err(), "duplicate refused");

    wait_for(&cap, "bytes arriving", 20, |s| !s.tasks.is_empty() && task(s).completed_bytes > 2_000_000);
    e.pause(vec![id.clone()]);
    let paused = wait_for(&cap, "paused", 20, |s| !s.tasks.is_empty() && task(s).phase == CorePhase::Paused && task(s).download_speed == 0);
    let at_pause = task(&paused).completed_bytes;
    std::thread::sleep(Duration::from_millis(1500));
    let still = cap.last.lock().unwrap().clone().unwrap();
    assert!(task(&still).completed_bytes <= at_pause + 2_000_000, "kept downloading while paused");

    e.resume(vec![id.clone()]);
    wait_for(&cap, "downloading again", 15, |s| !s.tasks.is_empty() && task(s).completed_bytes > at_pause + 1_000_000);

    // Clean shutdown mid-download, then a new engine on the same library resumes from the .aria2.
    let before = task(&cap.last.lock().unwrap().clone().unwrap()).completed_bytes;
    e.shutdown();
    let part = env.downloads.path().join("file.bin.aria2");
    assert!(part.exists(), "aria2 progress file kept on shutdown");
    let cap2 = Arc::new(Capture::default());
    let e2 = engine(&env, cap2.clone());
    let resumed = wait_for(&cap2, "resumed task visible", 15, |s| !s.tasks.is_empty() && task(s).completed_bytes > 0);
    assert!(task(&resumed).completed_bytes as f64 >= before as f64 * 0.8, "resume restarted from scratch");

    // Simulate aria2 crashing: the supervisor restarts it and the download continues.
    let pid_line = String::from_utf8_lossy(&std::process::Command::new("pgrep").args(["-f", &format!("aria2c --conf-path={}", env.support.path().join("aria2.conf").display())]).output().unwrap().stdout).to_string();
    let pid: i32 = pid_line.lines().next().unwrap_or("0").trim().parse().unwrap_or(0);
    assert!(pid > 0, "found aria2c pid");
    unsafe { libc::kill(pid, libc::SIGKILL) };
    wait_for(&cap2, "engine back after crash", 20, |s| matches!(s.engine, CoreEngineState::Running { .. }) && !s.tasks.is_empty() && task(s).download_speed > 0);

    let done = wait_for(&cap2, "complete", 60, |s| !s.tasks.is_empty() && matches!(task(s).phase, CorePhase::Completed { .. }));
    assert_eq!(task(&done).completed_bytes as usize, SIZE);
    let got = std::fs::read(env.downloads.path().join("file.bin")).unwrap();
    assert_eq!(got.len(), data.len());
    assert!(got == *data, "downloaded bytes differ");
    assert!(!part.exists(), "progress file removed on completion");
    assert!(cap2.events.lock().unwrap().iter().any(|e| matches!(e, CoreEvent::Completed { .. })));
    e2.shutdown();
    let _: PathBuf = env.support.path().join("library.json");
}

#[test]
fn schedule_holds_and_start_now_overrides() {
    let (port, _) = serve();
    let env = Env { support: tempfile::tempdir().unwrap(), logs: tempfile::tempdir().unwrap(), downloads: tempfile::tempdir().unwrap() };
    let cap = Arc::new(Capture::default());
    let e = engine(&env, cap.clone());
    wait_for(&cap, "engine running", 10, |s| matches!(s.engine, CoreEngineState::Running { .. }));
    // A window that is never "now": one minute, an hour away.
    let mut s = CoreSettings::default();
    s.default_directory = env.downloads.path().to_string_lossy().into();
    s.dht = false;
    s.lpd = false;
    s.listen_port = 40000 + (std::process::id() % 20000) as u16;
    let utc_min = ((tide_core::journal::now() / 60) % 1440) as u32;
    s.download_hours_enabled = true;
    s.download_hours = CoreWindow { start_minute: (utc_min + 60) % 1440, end_minute: (utc_min + 61) % 1440, weekdays: (1..=7).collect() };
    e.update_settings(s);
    let id = e
        .add(CoreAddRequest { source: CoreSource::Link { link: format!("http://127.0.0.1:{port}/file.bin") }, directory: env.downloads.path().to_string_lossy().into(), selected_files: None, start: CoreStart::Now })
        .unwrap();
    wait_for(&cap, "scheduled", 10, |s| !s.tasks.is_empty() && matches!(task(s).phase, CorePhase::Scheduled { .. }) && matches!(s.schedule, CoreSchedule::Outside { .. }));
    std::thread::sleep(Duration::from_secs(2));
    assert_eq!(task(&cap.last.lock().unwrap().clone().unwrap()).completed_bytes, 0, "downloaded outside hours");
    e.start_now(vec![id]);
    wait_for(&cap, "downloading after Start Now", 15, |s| !s.tasks.is_empty() && task(s).completed_bytes > 0);
    e.shutdown();
}

/// Import + resume a half-finished BitTorrent download straight from aria2's progress file:
/// progress must appear at once and aria2 must not rehash (no peers needed for this check).
#[test]
fn bt_import_resumes_from_progress_file_without_hashing() {
    use tide_core::control_file::ControlFile;
    let env = Env { support: tempfile::tempdir().unwrap(), logs: tempfile::tempdir().unwrap(), downloads: tempfile::tempdir().unwrap() };
    let dir = env.downloads.path();
    // A typical 2-file torrent: big video + junk text, 16 KiB pieces.
    let piece = 16 * 1024usize;
    let movie_len = 40 * piece + 123;
    let data: Vec<u8> = (0..movie_len + 64).map(|i| ((i * 13 + 5) % 251) as u8 + 1).collect();
    let mut pieces = Vec::new();
    for chunk in data.chunks(piece) {
        use sha1::Digest;
        pieces.extend_from_slice(&sha1::Sha1::digest(chunk));
    }
    let name = "Film.2024.2160p";
    let mut info = format!("d5:filesld6:lengthi{}e4:pathl8:Film.mkveed6:lengthi64e4:pathl8:info.txteee4:name{}:{}12:piece lengthi{}e6:pieces{}:", movie_len, name.len(), name, piece, pieces.len()).into_bytes();
    info.extend_from_slice(&pieces);
    info.push(b'e');
    let ann = "udp://new-\n  line.example.org:6969/announce";
    let mut raw = format!("d8:announce{}:{}4:info", ann.len(), ann).into_bytes();
    raw.extend_from_slice(&info);
    raw.push(b'e');
    let t = tide_core::torrent::parse(&raw).unwrap();
    std::fs::write(dir.join(format!("{}.torrent", t.info_hash)), &raw).unwrap();
    // Partial data on disk: first 15 pieces written; the file is full size (exFAT-style zero fill).
    std::fs::create_dir_all(dir.join(name)).unwrap();
    let mut on_disk = vec![0u8; movie_len];
    on_disk[..15 * piece].copy_from_slice(&data[..15 * piece]);
    std::fs::write(dir.join(name).join("Film.mkv"), &on_disk).unwrap();
    let mut c = ControlFile::new_bt(&tide_core::torrent::unhex(&t.info_hash).unwrap(), piece as u32, t.total_length, vec![0; (t.piece_count() as usize).div_ceil(8)]);
    for p in 0..15 { c.set(p, true); }
    c.write(&dir.join(format!("{name}.aria2"))).unwrap();

    let cap = Arc::new(Capture::default());
    let e = engine(&env, cap.clone());
    wait_for(&cap, "engine running", 10, |s| matches!(s.engine, CoreEngineState::Running { .. }));
    let found = e.scan_imports(&dir.to_string_lossy());
    assert_eq!(found.len(), 1);
    assert_eq!(found[0].completed_bytes as usize, 15 * piece);
    assert!(!found[0].needs_check);
    let ids = e.import(vec![CoreImportRequest { id: found[0].id.clone(), directory: found[0].directory.clone(), selected_files: None }]).unwrap();
    assert_eq!(ids.len(), 1);
    // aria2 has the task with the progress file's bitfield loaded, no rehash, only the .mkv.
    let s = wait_for(&cap, "imported task in aria2", 15, |s| {
        !s.tasks.is_empty() && matches!(task(s).phase, CorePhase::Resuming | CorePhase::Downloading | CorePhase::Stalled)
            && task(s).completed_bytes as usize == 15 * piece && task(s).pieces_done == Some(15)
    });
    assert_eq!(task(&s).total_bytes as usize, movie_len, "only the video is selected");
    let files = e.files(&task(&s).id);
    assert!(files.iter().any(|f| f.path.ends_with("Film.mkv") && f.selected));
    assert!(files.iter().any(|f| f.path.ends_with("info.txt") && !f.selected));
    // Still exactly 15 pieces after a few seconds: nothing was re-verified or lost.
    std::thread::sleep(Duration::from_secs(3));
    let later = cap.last.lock().unwrap().clone().unwrap();
    assert_eq!(task(&later).completed_bytes as usize, 15 * piece);
    assert!(!matches!(task(&later).phase, CorePhase::Checking { .. } | CorePhase::Error { .. }), "{:?}", task(&later).phase);
    // The progress file is still aria2's (it rewrites it every 10 s; bits must survive).
    e.shutdown();
    let after = ControlFile::read(&dir.join(format!("{name}.aria2"))).unwrap();
    assert!(after.done_count() >= 15, "progress lost: {}", after.done_count());
}
