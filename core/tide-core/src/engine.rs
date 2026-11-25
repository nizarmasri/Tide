//! The engine: Tide's library + a supervised aria2 + scheduler/policy + verifier, reconciled on a
//! single loop. Swift drives it through `lib.rs`; it reports through a `Sink`.

use crate::control_file::ControlFile;
use crate::importer::{self, Candidate};
use crate::journal::{self, Journal};
use crate::model::*;
use crate::problem;
use crate::rpc::RpcError;
use crate::scheduler::{self, Clock, Hold, Hours, Window};
use crate::smart_select::{self, Tag};
use crate::store::{new_gid, Intent, Kind, Library, Record, Seed, Store, StoredProblem};
use crate::supervisor::{Aria2, EngineOptions};
use crate::tlog;
use crate::torrent::{self, Torrent, TorrentFile};
use crate::verify::{self, VerifyJob};
use crate::volume;
use crossbeam_channel::{select, tick as cb_tick, unbounded, Receiver, Sender};
use serde_json::{json, Value};
use std::collections::{HashMap, HashSet};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

pub trait Sink: Send + Sync {
    fn snapshot(&self, s: CoreSnapshot);
    fn event(&self, e: CoreEvent);
}

const KEYS: &[&str] = &[
    "gid", "status", "totalLength", "completedLength", "uploadLength", "downloadSpeed", "uploadSpeed",
    "connections", "numSeeders", "errorCode", "errorMessage", "followedBy", "seeder", "verifiedLength",
    "verifyIntegrityPending", "numPieces", "pieceLength", "bitfield", "infoHash", "dir",
];

#[derive(Debug, Clone, Default)]
struct Live {
    status: String,
    total: u64,
    completed: u64,
    uploaded: u64,
    down: u64,
    up: u64,
    connections: u32,
    seeders: u32,
    error_code: Option<i64>,
    error_message: String,
    followed_by: Vec<String>,
    seeder: bool,
    verify_pending: bool,
    num_pieces: u32,
    #[allow(dead_code)]
    piece_length: u64,
    bitfield: Option<String>,
    waiting_position: u32,
}

fn num(v: &Value, k: &str) -> u64 {
    v.get(k).and_then(|x| x.as_str().and_then(|s| s.parse().ok()).or_else(|| x.as_u64())).unwrap_or(0)
}

fn parse_live(v: &Value) -> Live {
    Live {
        status: v.get("status").and_then(Value::as_str).unwrap_or("").to_string(),
        total: num(v, "totalLength"),
        completed: num(v, "completedLength"),
        uploaded: num(v, "uploadLength"),
        down: num(v, "downloadSpeed"),
        up: num(v, "uploadSpeed"),
        connections: num(v, "connections") as u32,
        seeders: num(v, "numSeeders") as u32,
        error_code: v.get("errorCode").and_then(Value::as_str).and_then(|s| s.parse().ok()).filter(|&c: &i64| c != 0),
        error_message: v.get("errorMessage").and_then(Value::as_str).unwrap_or("").to_string(),
        followed_by: v
            .get("followedBy")
            .and_then(Value::as_array)
            .map(|a| a.iter().filter_map(Value::as_str).map(str::to_string).collect())
            .unwrap_or_default(),
        seeder: v.get("seeder").and_then(Value::as_str) == Some("true"),
        verify_pending: v.get("verifyIntegrityPending").and_then(Value::as_str) == Some("true"),
        num_pieces: num(v, "numPieces") as u32,
        piece_length: num(v, "pieceLength"),
        bitfield: v.get("bitfield").and_then(Value::as_str).map(str::to_string),
        waiting_position: 0,
    }
}

fn popcount_hex(h: &str) -> u32 {
    h.chars().filter_map(|c| c.to_digit(16)).map(|d| d.count_ones()).sum()
}

#[derive(Debug, Clone)]
enum VerifyMode {
    Missing,
    Full,
    Suspect(Vec<u32>),
}

struct State {
    store: Store,
    lib: Library,
    journal: Journal,
    settings: CoreSettings,
    env: CoreEnvironment,
    aria2: Option<Aria2>,
    engine: CoreEngineState,
    engine_opts: Option<EngineOptions>,
    next_restart: Option<Instant>,
    backoff: Duration,
    live: HashMap<String, Live>,
    added: HashSet<String>,
    torrents: HashMap<String, Arc<Torrent>>,
    jobs: HashMap<String, Arc<VerifyJob>>,
    suspect_pending: HashSet<String>,
    crashed_at: Option<i64>,
    last_moving: HashMap<String, Instant>,
    /// `env.network_generation` when the running aria2 started (None while none runs).
    engine_net_gen: Option<u64>,
    /// When `env.network_generation` last changed.
    net_changed_at: Instant,
    /// Torrents running in aria2 without a single peer connection, and since when.
    zero_peers_since: HashMap<String, Instant>,
    last_discovery_restart: Option<Instant>,
    discovery_backoff: Duration,
    applied_global: Option<(u64, u64)>,
    applied_concurrency: Option<u32>,
    last_journal: Instant,
    last_snapshot: Option<CoreSnapshot>,
    volumes_present: HashMap<String, bool>,
    last_scan: HashMap<String, Candidate>,
    events: Vec<CoreEvent>,
    started: bool,
}

pub struct Engine {
    cfg: CoreConfig,
    st: Mutex<State>,
    wake_tx: Sender<()>,
    wake_rx: Receiver<()>,
    running: AtomicBool,
    visible: AtomicBool,
    sink: Mutex<Option<Arc<dyn Sink>>>,
    thread: Mutex<Option<std::thread::JoinHandle<()>>>,
}

fn now() -> i64 {
    journal::now()
}

fn window(w: &CoreWindow) -> Window {
    let mut mask = 0u8;
    for &d in &w.weekdays {
        if (1..=7).contains(&d) {
            mask |= 1 << (d - 1);
        }
    }
    Window { start: w.start_minute.min(1439), end: w.end_minute.min(1440) % 1440, weekdays: mask }
}

fn engine_options(s: &CoreSettings) -> EngineOptions {
    EngineOptions {
        max_concurrent: s.max_concurrent.max(1),
        connections_per_server: s.connections_per_server.clamp(1, 16),
        max_peers: s.max_peers.max(1),
        listen_port: s.listen_port,
        dht: s.dht,
        pex: s.pex,
        lpd: s.lpd,
        prefer_encryption: s.prefer_encryption,
        down_limit: s.down_limit.unwrap_or(0).max(0) as u64,
        up_limit: s.up_limit.unwrap_or(0).max(0) as u64,
        advanced: s.advanced_options.clone(),
    }
}

/// Options whose change needs an aria2 restart (everything else is applied live).
fn restart_key(o: &EngineOptions) -> (u16, bool, bool, bool, bool, u32, String) {
    (o.listen_port, o.dht, o.pex, o.lpd, o.prefer_encryption, o.max_peers, o.advanced.clone())
}

// MARK: Peer-discovery health
//
// aria2 opens its DHT/UDP-tracker socket once and keeps it for its whole life. After the Mac moved
// to another Wi-Fi network, that socket was seen refusing every send with EWOULDBLOCK for good.
// aria2 takes that as "try later" (DHT queue stuck, lookups never finish) or even as sent (UDP
// trackers), logs nothing, and torrents sit at 0 peers ("Looking for peers") forever while the
// rest of aria2 works. A fresh aria2 (fresh sockets) fixes it and is cheap, since every download
// continues from its progress file without rehashing.

/// A network change must settle this long before aria2 is restarted for it.
const NETWORK_SETTLE: Duration = Duration::from_secs(5);
/// Working discovery finds peers for a live swarm within a minute or two (aria2 asks the DHT every
/// minute while a torrent has no peers), so this long without any is a wedge, not bad luck.
const DISCOVERY_STALL: Duration = Duration::from_secs(10 * 60);
/// Restarts for a stall back off from DISCOVERY_STALL up to this, so a truly dead swarm costs at
/// most one restart this often.
const DISCOVERY_BACKOFF_MAX: Duration = Duration::from_secs(2 * 60 * 60);

/// The running aria2 was started on an older network and BitTorrent is about to rely on it.
/// While nothing BitTorrent wants to run, the restart waits (it then happens before the resume).
fn network_refresh_due(engine_gen: Option<u64>, env_gen: u64, network_up: bool, settled_for: Duration, torrent_wants_to_run: bool) -> bool {
    engine_gen.is_some_and(|g| g != env_gen) && network_up && settled_for >= NETWORK_SETTLE && torrent_wants_to_run
}

/// Peer discovery is presumed dead when a running torrent has had no peer for DISCOVERY_STALL and
/// no torrent has any peer (if one does, discovery works and that swarm is just empty), and the
/// previous stall restart was at least `backoff` ago.
fn discovery_dead(longest_without_peers: Option<Duration>, any_torrent_connected: bool, since_last_restart: Option<Duration>, backoff: Duration) -> bool {
    !any_torrent_connected
        && longest_without_peers.is_some_and(|d| d >= DISCOVERY_STALL)
        && since_last_restart.map_or(true, |d| d >= backoff)
}

fn tag(t: Tag) -> CoreFileTag {
    match t {
        Tag::Video => CoreFileTag::Video,
        Tag::Sample => CoreFileTag::Sample,
        Tag::Image => CoreFileTag::Image,
        Tag::Text => CoreFileTag::Text,
        Tag::Other => CoreFileTag::Other,
    }
}

fn smart_summary(files: &[TorrentFile], selected: &[u32]) -> CoreSmart {
    let skipped: Vec<&TorrentFile> = files.iter().filter(|f| !selected.contains(&f.index) && !f.is_padding).collect();
    CoreSmart {
        skipped_count: skipped.len() as u32,
        skipped_bytes: skipped.iter().map(|f| f.length as i64).sum(),
        skipped_description: smart_select::describe(&skipped),
    }
}

fn core_files(t: &Torrent, selected: &[u32], control: Option<&ControlFile>) -> Vec<CoreFile> {
    t.files
        .iter()
        .filter(|f| !f.is_padding)
        .map(|f| {
            let done = control.map_or(0, |c| {
                if f.length == 0 { return 0; }
                let first = (f.offset / t.piece_length) as u32;
                let last = ((f.offset + f.length - 1) / t.piece_length) as u32;
                (first..=last).filter(|&p| c.has(p)).map(|p| t.selected_bytes_in_piece(p, &[f.index])).sum::<u64>()
            });
            CoreFile {
                index: f.index,
                path: f.path.clone(),
                length: f.length as i64,
                completed_length: done as i64,
                selected: selected.contains(&f.index),
                tag: tag(smart_select::classify(f)),
            }
        })
        .collect()
}

fn primary_file(t: &Torrent, selected: &[u32]) -> Option<String> {
    t.files.iter().filter(|f| selected.contains(&f.index)).max_by_key(|f| f.length).map(|f| f.path.clone())
}

fn csv(v: &[u32]) -> String {
    v.iter().map(u32::to_string).collect::<Vec<_>>().join(",")
}

fn url_file_name(url: &str) -> String {
    let no_query = url.split(['?', '#']).next().unwrap_or(url);
    let last = no_query.trim_end_matches('/').rsplit('/').next().unwrap_or("");
    let decoded = torrent::percent_decode(last, false);
    if decoded.is_empty() || decoded.contains("://") {
        no_query.split("://").nth(1).and_then(|r| r.split('/').next()).unwrap_or("download").to_string()
    } else {
        decoded
    }
}

fn is_http_like(s: &str) -> bool {
    let l = s.trim().to_ascii_lowercase();
    ["http://", "https://", "ftp://", "sftp://"].iter().any(|p| l.starts_with(p)) && l.len() > 10
}

fn client_name(peer_id: &str) -> String {
    let id = torrent::percent_decode(peer_id, false);
    let b = id.as_bytes();
    if b.len() >= 8 && b[0] == b'-' && b[7] == b'-' {
        let code = &id[1..3];
        let ver: String = id[3..7].chars().filter(|c| c.is_ascii_alphanumeric()).collect();
        let name = match code {
            "qB" => "qBittorrent", "TR" => "Transmission", "UT" => "µTorrent", "UM" => "µTorrent Mac",
            "lt" => "libtorrent", "LT" => "libtorrent", "DE" => "Deluge", "AZ" => "Vuze", "BC" => "BitComet",
            "BT" => "BitTorrent", "TX" => "Tixati", "FD" => "Free Download Manager", "WW" => "WebTorrent",
            "BI" => "BiglyBT", "PI" => "PicoTorrent", "SD" => "Thunder", "XL" => "Xunlei", "FX" => "Folx",
            "MO" => "Motrix", "TI" => "Tide", _ => return String::new(),
        };
        let v: Vec<String> = ver.chars().take(3).map(|c| c.to_digit(36).map(|d| d.to_string()).unwrap_or_default()).collect();
        return format!("{name} {}", v.join("."));
    }
    if id.starts_with("A2-") {
        return "aria2".into();
    }
    String::new()
}

impl Engine {
    pub fn new(cfg: CoreConfig) -> Arc<Engine> {
        let support = PathBuf::from(&cfg.support_dir);
        let _ = std::fs::create_dir_all(&support);
        crate::util::set_log_file(PathBuf::from(&cfg.log_dir).join("tide.log"));
        let store = Store::new(&support);
        let mut lib = store.load();
        lib.records.sort_by_key(|r| r.order);
        let (wake_tx, wake_rx) = unbounded();
        Arc::new(Engine {
            st: Mutex::new(State {
                journal: Journal::new(&support),
                store,
                lib,
                settings: CoreSettings::default(),
                env: CoreEnvironment::default(),
                aria2: None,
                engine: CoreEngineState::Starting,
                engine_opts: None,
                next_restart: Some(Instant::now()),
                backoff: Duration::from_secs(1),
                live: HashMap::new(),
                added: HashSet::new(),
                torrents: HashMap::new(),
                jobs: HashMap::new(),
                suspect_pending: HashSet::new(),
                crashed_at: None,
                last_moving: HashMap::new(),
                engine_net_gen: None,
                net_changed_at: Instant::now(),
                zero_peers_since: HashMap::new(),
                last_discovery_restart: None,
                discovery_backoff: DISCOVERY_STALL,
                applied_global: None,
                applied_concurrency: None,
                last_journal: Instant::now(),
                last_snapshot: None,
                volumes_present: HashMap::new(),
                last_scan: HashMap::new(),
                events: Vec::new(),
                started: false,
            }),
            cfg,
            wake_tx,
            wake_rx,
            running: AtomicBool::new(false),
            visible: AtomicBool::new(false),
            sink: Mutex::new(None),
            thread: Mutex::new(None),
        })
    }

    fn wake(&self) {
        let _ = self.wake_tx.try_send(());
    }

    pub fn start(self: &Arc<Self>, settings: CoreSettings, sink: Arc<dyn Sink>) {
        if self.running.swap(true, Ordering::SeqCst) {
            return;
        }
        *self.sink.lock().unwrap() = Some(sink);
        {
            let mut st = self.st.lock().unwrap();
            st.engine_opts = None;
            st.settings = settings;
            st.started = true;
            st.crashed_at = st.journal.begin();
            if let Some(at) = st.crashed_at {
                tlog!("previous run ended without a clean shutdown at {at} and the Mac rebooted since; checking recent pieces");
                let ids: Vec<String> = st
                    .lib
                    .records
                    .iter()
                    .filter(|r| r.kind == Kind::Torrent && !r.is_complete())
                    .map(|r| r.id.clone())
                    .collect();
                st.suspect_pending.extend(ids);
            }
        }
        let me = Arc::clone(self);
        let h = std::thread::Builder::new().name("tide-engine".into()).spawn(move || me.run_loop()).expect("engine thread");
        *self.thread.lock().unwrap() = Some(h);
        self.wake();
    }

    fn run_loop(self: Arc<Self>) {
        let mut ticker = cb_tick(Duration::from_secs(1));
        let mut visible = self.visible.load(Ordering::Relaxed);
        let mut last_tick = Instant::now() - Duration::from_secs(10);
        while self.running.load(Ordering::Relaxed) {
            let notes = self.st.lock().unwrap().aria2.as_ref().map(|a| a.rpc.notifications.clone());
            let never = crossbeam_channel::never();
            let notes = notes.unwrap_or(never);
            select! {
                recv(self.wake_rx) -> _ => {}
                recv(ticker) -> _ => {}
                recv(notes) -> _ => {}
            }
            // Drain bursts.
            while self.wake_rx.try_recv().is_ok() {}
            let v = self.visible.load(Ordering::Relaxed);
            if v != visible {
                visible = v;
                ticker = cb_tick(Duration::from_secs(if v { 1 } else { 5 }));
            }
            if !self.running.load(Ordering::Relaxed) {
                break;
            }
            // Rate-limit wake storms to ~10 ticks/s.
            if last_tick.elapsed() < Duration::from_millis(100) {
                std::thread::sleep(Duration::from_millis(100) - last_tick.elapsed());
            }
            last_tick = Instant::now();
            self.tick();
        }
    }

    pub fn set_visible(&self, v: bool) {
        self.visible.store(v, Ordering::Relaxed);
        self.wake();
    }

    fn tick(self: &Arc<Self>) {
        let (snap, events) = {
            let mut st = self.st.lock().unwrap();
            self.ensure_engine(&mut st);
            if st.aria2.is_some() {
                self.poll(&mut st);
                self.transitions(&mut st);
                // A restart hands everything back on the next tick, from a fresh aria2.
                if !self.refresh_peer_discovery(&mut st) {
                    self.reconcile(&mut st);
                    self.apply_globals(&mut st);
                    self.journal_tick(&mut st);
                }
            } else {
                self.volume_transitions(&mut st);
            }
            let snap = self.build_snapshot(&st);
            let changed = st.last_snapshot.as_ref() != Some(&snap);
            if changed {
                st.last_snapshot = Some(snap.clone());
            }
            (changed.then_some(snap), std::mem::take(&mut st.events))
        };
        let sink = self.sink.lock().unwrap().clone();
        if let Some(sink) = sink {
            if let Some(s) = snap {
                sink.snapshot(s);
            }
            for e in events {
                sink.event(e);
            }
        }
    }

    // MARK: aria2 process

    fn ensure_engine(&self, st: &mut State) {
        if let Some(a) = st.aria2.as_mut() {
            if a.is_running() {
                return;
            }
            tlog!("aria2 stopped unexpectedly; restarting");
            let old = st.aria2.take().unwrap();
            drop(old);
            st.added.clear();
            st.live.clear();
            st.next_restart = Some(Instant::now() + st.backoff);
            st.engine = CoreEngineState::Starting;
        }
        let Some(when) = st.next_restart else { return };
        if Instant::now() < when {
            return;
        }
        let opts = engine_options(&st.settings);
        let support = PathBuf::from(&self.cfg.support_dir);
        let logs = PathBuf::from(&self.cfg.log_dir);
        match Aria2::start(Path::new(&self.cfg.aria2_path), &support, &logs, &opts, self.cfg.app_pid) {
            Ok(a) => {
                tlog!("aria2 {} running on port {} (pid {})", a.version, a.port, a.pid());
                st.engine = CoreEngineState::Running { version: a.version.clone() };
                st.aria2 = Some(a);
                st.engine_net_gen = Some(st.env.network_generation);
                st.zero_peers_since.clear();
                st.engine_opts = Some(opts.clone());
                st.applied_global = Some((opts.down_limit, opts.up_limit));
                st.applied_concurrency = Some(opts.max_concurrent);
                st.next_restart = None;
                st.backoff = Duration::from_secs(1);
                st.added.clear();
                st.live.clear();
            }
            Err(e) => {
                tlog!("aria2 failed to start: {e}");
                let was_running = !matches!(st.engine, CoreEngineState::Stopped { .. });
                st.engine = CoreEngineState::Stopped { reason: e.clone() };
                st.backoff = (st.backoff * 2).min(Duration::from_secs(30));
                st.next_restart = Some(Instant::now() + st.backoff);
                if was_running {
                    st.events.push(CoreEvent::EngineStopped { reason: e });
                }
            }
        }
    }

    fn call(st: &State, method: &str, params: Vec<Value>) -> Result<Value, RpcError> {
        match st.aria2.as_ref() {
            Some(a) => a.call(method, params),
            None => Err(RpcError::Disconnected),
        }
    }

    fn poll(&self, st: &mut State) {
        let Some(a) = st.aria2.as_ref() else { return };
        let keys = json!(KEYS);
        let res = a.rpc.multicall(vec![
            ("aria2.tellActive", vec![keys.clone()]),
            ("aria2.tellWaiting", vec![json!(0), json!(1000), keys.clone()]),
            ("aria2.tellStopped", vec![json!(0), json!(1000), keys]),
        ]);
        let Ok(res) = res else { return };
        let mut live = HashMap::new();
        let mut pos = 0;
        for (i, r) in res.into_iter().enumerate() {
            let Ok(Value::Array(items)) = r else { continue };
            for item in items {
                let mut l = parse_live(&item);
                if i == 1 && l.status == "waiting" {
                    pos += 1;
                    l.waiting_position = pos;
                }
                if let Some(g) = item.get("gid").and_then(Value::as_str) {
                    live.insert(g.to_string(), l);
                }
            }
        }
        st.live = live;
        let live_gids: HashSet<String> = st.live.keys().cloned().collect();
        st.added.retain(|g| live_gids.contains(g));
    }

    fn remove_result(st: &mut State, gid: &str) {
        let _ = Self::call(st, "aria2.removeDownloadResult", vec![json!(gid)]);
        st.added.remove(gid);
        st.live.remove(gid);
    }

    /// Takes a download out of aria2 (its progress file stays) and waits until aria2 let go of
    /// the files, so a drive can eject or a verification can rewrite the progress file.
    fn evict(st: &mut State, gid: &str) {
        if Self::call(st, "aria2.forceRemove", vec![json!(gid)]).is_ok() {
            let deadline = Instant::now() + Duration::from_millis(2500);
            while Instant::now() < deadline {
                match Self::call(st, "aria2.tellStatus", vec![json!(gid), json!(["status"])]) {
                    Ok(v) if v.get("status").and_then(Value::as_str) == Some("removed") => break,
                    Err(_) => break,
                    _ => std::thread::sleep(Duration::from_millis(40)),
                }
            }
        }
        Self::remove_result(st, gid);
    }

    /// Stops aria2 (it writes every progress file) and starts a fresh one on the next tick;
    /// reconcile then hands each download back as it was, continuing from its progress file.
    fn restart_aria2(st: &mut State, reason: &str) {
        tlog!("restarting aria2: {reason}");
        if let Some(a) = st.aria2.take() {
            a.stop();
        }
        st.added.clear();
        st.live.clear();
        st.zero_peers_since.clear();
        st.engine_net_gen = None;
        st.engine = CoreEngineState::Starting;
        st.backoff = Duration::from_secs(1);
        st.next_restart = Some(Instant::now());
    }

    /// Keeps `zero_peers_since` current from the latest poll. Returns whether any torrent in aria2
    /// has a peer connection right now.
    fn track_discovery(st: &mut State) -> bool {
        let now = Instant::now();
        let mut without_peers = HashSet::new();
        let mut any_connected = false;
        for r in st.lib.records.iter().filter(|r| matches!(r.kind, Kind::Torrent | Kind::Magnet)) {
            let Some(l) = st.live.get(&r.gid) else { continue };
            if l.connections > 0 {
                any_connected = true;
            } else if l.status == "active" && !l.seeder && !l.verify_pending && st.env.network_available {
                without_peers.insert(r.id.clone());
            }
        }
        st.zero_peers_since.retain(|id, _| without_peers.contains(id));
        for id in without_peers {
            st.zero_peers_since.entry(id).or_insert(now);
        }
        if any_connected {
            st.discovery_backoff = DISCOVERY_STALL;
            st.last_discovery_restart = None;
        }
        any_connected
    }

    /// Restarts aria2 when its peer discovery can't be trusted: the network changed under it, or
    /// every running torrent has gone without peers for too long. Returns true if it restarted.
    fn refresh_peer_discovery(&self, st: &mut State) -> bool {
        let any_connected = Self::track_discovery(st);
        let (hours, auto) = (Self::hours(st), Self::auto_pause(st));
        let torrent_wants_to_run = st.lib.records.iter().any(|r| {
            matches!(r.kind, Kind::Torrent | Kind::Magnet) && Self::desired_running(st, r, hours, auto) && volume::is_available(&r.dir_path())
        });
        let reason = if network_refresh_due(st.engine_net_gen, st.env.network_generation, st.env.network_available, st.net_changed_at.elapsed(), torrent_wants_to_run) {
            "the network changed, so peer discovery has to start over on the new one".to_string()
        } else {
            let longest = st.zero_peers_since.values().map(|t| t.elapsed()).max();
            let since_last = st.last_discovery_restart.map(|t| t.elapsed());
            if !discovery_dead(longest, any_connected, since_last, st.discovery_backoff) {
                return false;
            }
            st.last_discovery_restart = Some(Instant::now());
            let backoff = st.discovery_backoff;
            st.discovery_backoff = (backoff * 2).min(DISCOVERY_BACKOFF_MAX);
            format!("no torrent has found a peer in {} min (next check in {} min at the earliest)", DISCOVERY_STALL.as_secs() / 60, st.discovery_backoff.as_secs() / 60)
        };
        Self::restart_aria2(st, &reason);
        self.wake();
        true
    }

    // MARK: Transitions (what aria2 reports → library)

    fn volume_transitions(&self, st: &mut State) {
        let mounts: HashSet<String> = st.lib.records.iter().filter(|r| !r.is_complete()).map(|r| volume::expected_mount(&r.dir_path())).filter(|m| m != "/").collect();
        for m in mounts {
            let present = volume::is_available(Path::new(&format!("{m}/")));
            let before = st.volumes_present.insert(m.clone(), present);
            if before == Some(true) && !present {
                let name = m.trim_start_matches("/Volumes/").to_string();
                st.events.push(CoreEvent::WaitingForDrive { volume_name: name });
            }
        }
    }

    fn transitions(&self, st: &mut State) {
        self.volume_transitions(st);
        let t_now = now();
        for i in 0..st.lib.records.len() {
            let gid = st.lib.records[i].gid.clone();
            let Some(l) = st.live.get(&gid).cloned() else { continue };
            {
                let r = &mut st.lib.records[i];
                // While a magnet fetches metadata aria2 reports the metadata's own size: skip it.
                let metadata_phase = r.kind == Kind::Magnet && r.torrent_path.is_none();
                if !metadata_phase {
                    if l.total > 0 {
                        r.total_bytes = l.total;
                    }
                    r.completed_bytes = l.completed;
                }
                if let Some(b) = &l.bitfield {
                    r.pieces_done = Some(popcount_hex(b));
                }
            }
            if l.down > 0 {
                st.last_moving.insert(st.lib.records[i].id.clone(), Instant::now());
            }
            match l.status.as_str() {
                "complete" => {
                    if st.lib.records[i].kind == Kind::Magnet && !l.followed_by.is_empty() {
                        self.metadata_arrived(st, i, l.followed_by[0].clone());
                    } else if !st.lib.records[i].is_complete() {
                        self.mark_complete(st, i, t_now);
                        Self::remove_result(st, &gid);
                    } else {
                        Self::remove_result(st, &gid);
                    }
                }
                "active" if l.seeder && st.lib.records[i].kind == Kind::Torrent => {
                    if !st.lib.records[i].is_complete() {
                        self.mark_complete(st, i, t_now);
                    }
                }
                "error" => {
                    let r = st.lib.records[i].clone();
                    let vol_ok = volume::is_available(&r.dir_path());
                    let net_err = matches!(l.error_code, Some(2 | 6 | 19 | 29));
                    if !vol_ok || (net_err && !st.env.network_available) {
                        // Not a real failure: re-added automatically when the drive/network is back.
                        Self::remove_result(st, &gid);
                    } else if r.problem.is_none() {
                        let code = l.error_code.unwrap_or(1);
                        tlog!("download {} failed: {} {}", r.name, code, l.error_message);
                        st.lib.records[i].problem = Some(StoredProblem { code, message: l.error_message.clone() });
                        let reason = self.problem_for(st, &st.lib.records[i]).status;
                        st.events.push(CoreEvent::Stopped { id: r.id.clone(), name: r.name.clone(), reason });
                        Self::remove_result(st, &gid);
                        st.store.save(&st.lib);
                    }
                }
                _ => {}
            }
        }
    }

    fn mark_complete(&self, st: &mut State, i: usize, at: i64) {
        let r = &mut st.lib.records[i];
        r.completed_at = Some(at);
        r.completed_bytes = r.total_bytes.max(r.completed_bytes);
        r.problem = None;
        let (id, name, dir) = (r.id.clone(), r.name.clone(), r.dir.clone());
        tlog!("completed {name}");
        st.journal.forget(&id);
        let vol = volume::display_name(Path::new(&dir), &st.env.boot_volume_name);
        st.events.push(CoreEvent::Completed { id, name, directory: dir, volume_name: vol });
        st.store.save(&st.lib);
    }

    /// A magnet's metadata arrived: aria2 created a paused follow-up download (pause-metadata).
    /// Apply the smart selection, adopt the follow-up's GID, and let reconcile unpause it.
    fn metadata_arrived(&self, st: &mut State, i: usize, new_gid: String) {
        let r = st.lib.records[i].clone();
        let ih = r.info_hash.clone().unwrap_or_default();
        let saved = Path::new(&r.dir).join(format!("{ih}.torrent"));
        let parsed = std::fs::read(&saved).ok().and_then(|b| torrent::parse(&b).ok().map(|t| (b, t)));
        let (sel, name, total, primary, tpath, t_arc) = match parsed {
            Some((bytes, t)) => {
                let sel = r.selected.clone().unwrap_or_else(|| {
                    smart_select::select(&t.files, st.settings.only_main_video, st.settings.skip_extras).selected
                });
                let tpath = st.store.save_torrent(&t.info_hash, &bytes);
                let total = t.selected_length(&sel);
                let primary = primary_file(&t, &sel);
                (sel, t.name.clone(), total, primary, tpath, Some(Arc::new(t)))
            }
            None => {
                // Fall back to aria2's own file list.
                let files: Vec<TorrentFile> = Self::call(st, "aria2.getFiles", vec![json!(new_gid)])
                    .ok()
                    .and_then(|v| v.as_array().cloned())
                    .unwrap_or_default()
                    .iter()
                    .map(|f| TorrentFile {
                        index: num(f, "index") as u32,
                        path: f.get("path").and_then(Value::as_str).unwrap_or("").trim_start_matches(&format!("{}/", r.dir)).to_string(),
                        length: num(f, "length"),
                        offset: 0,
                        is_padding: false,
                    })
                    .collect();
                let sel = smart_select::select(&files, st.settings.only_main_video, st.settings.skip_extras).selected;
                let total = files.iter().filter(|f| sel.contains(&f.index)).map(|f| f.length).sum();
                let primary = files.iter().filter(|f| sel.contains(&f.index)).max_by_key(|f| f.length).map(|f| f.path.clone());
                let name = primary.as_deref().and_then(|p| p.split('/').next()).unwrap_or(&r.name).to_string();
                (sel, name, total, primary, None, None)
            }
        };
        let _ = Self::call(st, "aria2.changeOption", vec![json!(new_gid), json!({"select-file": csv(&sel)})]);
        Self::remove_result(st, &r.gid);
        let rec = &mut st.lib.records[i];
        rec.gid = new_gid.clone();
        rec.kind = if tpath.is_some() { Kind::Torrent } else { Kind::Magnet };
        rec.torrent_path = tpath.or(rec.torrent_path.take());
        rec.name = name;
        rec.selected = Some(sel);
        rec.total_bytes = total;
        rec.primary_file = primary;
        let id = rec.id.clone();
        if let Some(t) = t_arc {
            st.torrents.insert(id, t);
        }
        st.added.insert(new_gid);
        tlog!("metadata for {} arrived; selected files applied", st.lib.records[i].name);
        st.store.save(&st.lib);
    }

    // MARK: Reconcile (library intent → aria2)

    fn clock(st: &State) -> Clock {
        Clock { now: now(), utc_offset: st.env.utc_offset_seconds }
    }

    fn hours(st: &State) -> Hours {
        scheduler::hours_status(st.settings.download_hours_enabled, &window(&st.settings.download_hours), &Self::clock(st))
    }

    fn auto_pause(st: &State) -> Option<CoreAutoPause> {
        if st.settings.pause_on_battery && st.env.on_battery {
            Some(CoreAutoPause::Battery)
        } else if st.settings.pause_on_expensive_network && st.env.network_expensive {
            Some(CoreAutoPause::ExpensiveNetwork)
        } else {
            None
        }
    }

    fn desired_running(st: &State, r: &Record, hours: Hours, auto: Option<CoreAutoPause>) -> bool {
        r.intent == Intent::Run
            && scheduler::task_hold(hours, r.start_at, r.override_until, now()) == Hold::Run
            && (auto.is_none() || r.ignore_auto_pause)
            && r.problem.is_none()
            && !r.is_complete()
            && !st.jobs.contains_key(&r.id)
    }

    fn reconcile(self: &Arc<Self>, st: &mut State) {
        let hours = Self::hours(st);
        let auto = Self::auto_pause(st);
        if auto.is_none() {
            for r in st.lib.records.iter_mut() {
                r.ignore_auto_pause = false;
            }
        }
        let mut dirty = false;
        for i in 0..st.lib.records.len() {
            let r = st.lib.records[i].clone();
            if r.is_complete() || st.jobs.contains_key(&r.id) {
                continue;
            }
            let in_aria2 = st.added.contains(&r.gid);
            if !volume::is_available(&r.dir_path()) {
                if in_aria2 {
                    Self::evict(st, &r.gid);
                }
                continue;
            }
            if r.problem.is_some() {
                continue;
            }
            let desired = Self::desired_running(st, &r, hours, auto);
            if !in_aria2 {
                if r.needs_check {
                    self.start_verify(st, &r.id, VerifyMode::Missing);
                    continue;
                }
                if st.suspect_pending.contains(&r.id) {
                    if self.start_suspect_check(st, &r.id) {
                        continue;
                    }
                }
                match self.add_to_aria2(st, i, !desired) {
                    Ok(()) => {
                        if desired {
                            st.lib.records[i].resumed_at = Some(now());
                        }
                        dirty = true;
                    }
                    Err(e) => {
                        tlog!("couldn't hand {} to aria2: {e}", r.name);
                        if let RpcError::Aria2 { code, message } = e {
                            st.lib.records[i].problem = Some(StoredProblem { code, message });
                            dirty = true;
                        }
                    }
                }
                continue;
            }
            let status = st.live.get(&r.gid).map(|l| l.status.clone()).unwrap_or_default();
            if desired && status == "paused" {
                if Self::call(st, "aria2.unpause", vec![json!(r.gid)]).is_ok() {
                    st.lib.records[i].resumed_at = Some(now());
                    dirty = true;
                }
            } else if !desired && (status == "active" || status == "waiting") {
                let _ = Self::call(st, "aria2.forcePause", vec![json!(r.gid)]);
            }
        }
        if dirty {
            st.store.save(&st.lib);
        }
    }

    fn seed_options(st: &State, r: &Record, opts: &mut serde_json::Map<String, Value>) {
        let policy = r.seed.clone().unwrap_or(match &st.settings.after_download {
            CoreSeed::Stop => Seed::Stop,
            CoreSeed::Ratio { ratio } => Seed::Ratio(*ratio),
            CoreSeed::Minutes { minutes } => Seed::Minutes(*minutes),
        });
        match policy {
            Seed::Stop => {
                opts.insert("seed-time".into(), json!("0"));
            }
            Seed::Ratio(x) => {
                opts.insert("seed-time".into(), json!("525600"));
                opts.insert("seed-ratio".into(), json!(format!("{x:.2}")));
            }
            Seed::Minutes(m) => {
                opts.insert("seed-time".into(), json!(m.to_string()));
                opts.insert("seed-ratio".into(), json!("0.0"));
            }
        }
    }

    fn torrent_for(st: &mut State, id: &str) -> Option<Arc<Torrent>> {
        if let Some(t) = st.torrents.get(id) {
            return Some(t.clone());
        }
        let r = st.lib.records.iter().find(|r| r.id == id)?;
        let path = r.torrent_path.clone()?;
        let t = Arc::new(torrent::parse(&std::fs::read(path).ok()?).ok()?);
        st.torrents.insert(id.to_string(), t.clone());
        Some(t)
    }

    fn add_to_aria2(&self, st: &mut State, i: usize, paused: bool) -> Result<(), RpcError> {
        let r = st.lib.records[i].clone();
        let mut opts = serde_json::Map::new();
        opts.insert("gid".into(), json!(r.gid));
        opts.insert("dir".into(), json!(r.dir));
        opts.insert("pause".into(), json!(if paused { "true" } else { "false" }));
        if let Some(l) = r.speed_limit {
            opts.insert("max-download-limit".into(), json!(l.to_string()));
        }
        let extra: Vec<String> = st.settings.extra_trackers.split(['\n', ',', ' ']).map(str::trim).filter(|s| !s.is_empty()).map(str::to_string).collect();
        let (extra, _) = torrent::sanitize_trackers(&extra);
        let res = match r.kind {
            Kind::Torrent => {
                let t = Self::torrent_for(st, &r.id).ok_or(RpcError::Aria2 { code: 26, message: "torrent file missing".into() })?;
                let bytes = std::fs::read(r.torrent_path.as_deref().unwrap_or_default())
                    .map_err(|e| RpcError::Aria2 { code: 26, message: e.to_string() })?;
                Self::seed_options(st, &r, &mut opts);
                if let Some(sel) = &r.selected {
                    if sel.len() < t.files.len() {
                        opts.insert("select-file".into(), json!(csv(sel)));
                    }
                }
                if t.trackers_were_malformed || !extra.is_empty() {
                    let mut all = t.trackers.clone();
                    all.extend(extra);
                    opts.insert("bt-exclude-tracker".into(), json!("*"));
                    opts.insert("bt-tracker".into(), json!(all.join(",")));
                }
                Self::call(st, "aria2.addTorrent", vec![json!(crate::util::base64(&bytes)), json!([]), Value::Object(opts)])
            }
            Kind::Magnet => {
                Self::seed_options(st, &r, &mut opts);
                if !extra.is_empty() {
                    opts.insert("bt-tracker".into(), json!(extra.join(",")));
                }
                let uri = r.magnet.clone().unwrap_or_default();
                Self::call(st, "aria2.addUri", vec![json!([uri]), Value::Object(opts)])
            }
            Kind::Http => {
                if let Some(p) = &r.primary_file {
                    opts.insert("out".into(), json!(p));
                }
                let uri = r.url.clone().unwrap_or_default();
                Self::call(st, "aria2.addUri", vec![json!([uri]), Value::Object(opts)])
            }
        };
        match res {
            Ok(_) => {
                st.added.insert(r.gid.clone());
                tlog!("handed {} to aria2 (paused={paused})", r.name);
                Ok(())
            }
            // GID already known to aria2 (e.g. a race with a previous add): adopt it.
            Err(RpcError::Aria2 { message, .. }) if message.contains("GID") && message.contains("not unique") => {
                st.added.insert(r.gid.clone());
                Ok(())
            }
            Err(e) => Err(e),
        }
    }

    fn apply_globals(&self, st: &mut State) {
        let clock = Self::clock(st);
        let scheduled = st.settings.slow_mode_scheduled;
        let w = window(&st.settings.slow_mode_hours);
        let mut sm = st.lib.slow_mode;
        let slow = scheduler::slow_mode_effective(&mut sm, scheduled, &w, &clock);
        if sm != st.lib.slow_mode {
            st.lib.slow_mode = sm;
            st.store.save(&st.lib);
        }
        let want = if slow {
            (st.settings.slow_down_limit.max(0) as u64, st.settings.slow_up_limit.max(0) as u64)
        } else {
            (st.settings.down_limit.unwrap_or(0).max(0) as u64, st.settings.up_limit.unwrap_or(0).max(0) as u64)
        };
        if st.applied_global != Some(want) {
            if let Some(a) = st.aria2.as_ref() {
                if a.change_global(crate::supervisor::global_limits(want.0, want.1)).is_ok() {
                    st.applied_global = Some(want);
                }
            }
        }
        let conc = st.settings.max_concurrent.max(1);
        if st.applied_concurrency != Some(conc) {
            if let Some(a) = st.aria2.as_ref() {
                let o = json!({"max-concurrent-downloads": conc.to_string(), "max-connection-per-server": st.settings.connections_per_server.clamp(1, 16).to_string()});
                if a.change_global(o).is_ok() {
                    st.applied_concurrency = Some(conc);
                }
            }
        }
    }

    fn journal_tick(&self, st: &mut State) {
        if st.last_journal.elapsed() < Duration::from_secs(30) {
            return;
        }
        st.last_journal = Instant::now();
        st.journal.heartbeat();
        let items: Vec<(String, String)> = st
            .lib
            .records
            .iter()
            .filter(|r| r.kind == Kind::Torrent && !r.is_complete())
            .filter_map(|r| st.live.get(&r.gid).and_then(|l| l.bitfield.clone()).map(|b| (r.id.clone(), b)))
            .collect();
        for (id, b) in items {
            st.journal.record(&id, &b);
        }
        // Housekeeping: keep the library's progress cache fresh on disk.
        st.store.save(&st.lib);
    }

    // MARK: Verification

    /// Returns true if a check was started (the task waits for it).
    fn start_suspect_check(self: &Arc<Self>, st: &mut State, id: &str) -> bool {
        st.suspect_pending.remove(id);
        let Some(crashed_at) = st.crashed_at else { return false };
        let Some(r) = st.lib.records.iter().find(|r| r.id == id).cloned() else { return false };
        let Some(t) = Self::torrent_for(st, id) else { return false };
        let cpath = Path::new(&r.dir).join(format!("{}.aria2", t.name));
        let Ok(c) = ControlFile::read(&cpath) else { return false };
        let sel = r.selected.clone().unwrap_or_else(|| t.all_indexes());
        let wanted: HashSet<u32> = t.pieces_for_files(&sel).into_iter().collect();
        let mut suspects = journal::suspects(&c.bitfield, c.piece_count(), &st.journal.load(id), crashed_at);
        suspects.retain(|p| wanted.contains(p));
        if suspects.is_empty() {
            return false;
        }
        tlog!("power-cut check for {}: {} suspect pieces", r.name, suspects.len());
        self.start_verify(st, id, VerifyMode::Suspect(suspects));
        true
    }

    fn start_verify(self: &Arc<Self>, st: &mut State, id: &str, mode: VerifyMode) {
        if st.jobs.contains_key(id) {
            return;
        }
        let Some(r) = st.lib.records.iter().find(|r| r.id == id).cloned() else { return };
        let Some(t) = Self::torrent_for(st, id) else { return };
        let sel = r.selected.clone().unwrap_or_else(|| t.all_indexes());
        let pieces = match &mode {
            VerifyMode::Missing | VerifyMode::Full => t.pieces_for_files(&sel),
            VerifyMode::Suspect(p) => p.clone(),
        };
        let total: u64 = pieces.iter().map(|&p| t.piece_len(p)).sum();
        let job = VerifyJob::new(total);
        st.jobs.insert(id.to_string(), job.clone());
        if st.added.contains(&r.gid) {
            Self::evict(st, &r.gid);
        }
        let me = Arc::clone(self);
        let id = id.to_string();
        let dir = r.dir_path();
        std::thread::Builder::new()
            .name("tide-verify".into())
            .spawn(move || {
                let threads = std::thread::available_parallelism().map(|n| n.get()).unwrap_or(4).min(8);
                let res = verify::verify_pieces(&t, &dir, &pieces, threads, &job.cancel, &|d, _| {
                    job.done_bytes.store(d, Ordering::Relaxed);
                });
                me.finish_verify(&id, &t, &dir, mode, res);
            })
            .ok();
    }

    fn finish_verify(&self, id: &str, t: &Torrent, dir: &Path, mode: VerifyMode, res: verify::VerifyResult) {
        let mut st = self.st.lock().unwrap();
        st.jobs.remove(id);
        if res.cancelled {
            return;
        }
        let cpath = dir.join(format!("{}.aria2", t.name));
        let ih = torrent::unhex(&t.info_hash).unwrap_or_default();
        let nbytes = (t.piece_count() as usize).div_ceil(8);
        let mut c = ControlFile::read(&cpath).ok().filter(|c| c.info_hash == ih && c.bitfield.len() == nbytes).unwrap_or_else(|| {
            ControlFile::new_bt(&ih, t.piece_length as u32, t.total_length, vec![0; nbytes])
        });
        match &mode {
            VerifyMode::Missing | VerifyMode::Full => {
                c.bitfield = vec![0; nbytes];
                for &p in &res.good {
                    c.set(p, true);
                }
                c.in_flight.clear();
            }
            VerifyMode::Suspect(_) => {
                // In-flight pieces weren't checked and stay as they are (see journal::suspects).
                for &p in &res.bad {
                    c.set(p, false);
                }
                for &p in &res.good {
                    c.set(p, true);
                }
            }
        }
        let written = c.write(&cpath);
        tlog!("verified {} pieces of {} in {:.1}s: {} good, {} bad", res.good.len() + res.bad.len(), t.name, res.elapsed.as_secs_f64(), res.good.len(), res.bad.len());
        if let Err(e) = written {
            tlog!("couldn't save the checked progress of {} to {}: {e}", t.name, cpath.display());
            if let Some(r) = st.lib.records.iter_mut().find(|r| r.id == id) {
                match mode {
                    // aria2 continues from the existing progress file: the record stays as it was.
                    VerifyMode::Suspect(_) => r.resumed_at = Some(now()),
                    // There's no usable progress file to continue from: say so instead of guessing.
                    VerifyMode::Missing | VerifyMode::Full => {
                        r.problem = Some(StoredProblem { code: 16, message: format!("couldn't save progress: {e}") });
                    }
                }
            }
            st.store.save(&st.lib);
            drop(st);
            self.wake();
            return;
        }
        let sel_done = {
            let r = st.lib.records.iter().find(|r| r.id == id);
            let sel = r.and_then(|r| r.selected.clone()).unwrap_or_else(|| t.all_indexes());
            importer::selected_progress(t, &c, &sel)
        };
        if let Some(r) = st.lib.records.iter_mut().find(|r| r.id == id) {
            r.needs_check = false;
            r.completed_bytes = sel_done;
            r.pieces_done = Some(c.done_count());
            r.resumed_at = Some(now());
        }
        st.store.save(&st.lib);
        drop(st);
        self.wake();
    }

    // MARK: Snapshot

    fn problem_for(&self, st: &State, r: &Record) -> problem::Problem {
        let p = r.problem.clone().unwrap_or(StoredProblem { code: 1, message: String::new() });
        let dir = r.dir_path();
        let vol = volume::display_name(&dir, &st.env.boot_volume_name);
        let folder = dir.file_name().map(|f| f.to_string_lossy().into_owned()).unwrap_or_else(|| vol.clone());
        let largest = st.torrents.get(&r.id).map(|t| t.files.iter().map(|f| f.length).max().unwrap_or(0)).unwrap_or(r.total_bytes);
        problem::from_aria2(p.code, &p.message, &problem::Context {
            volume: &vol,
            folder: &folder,
            remaining_bytes: r.total_bytes.saturating_sub(r.completed_bytes),
            free_bytes: volume::free_bytes(&dir),
            fat32: volume::is_fat32(&dir),
            largest_file: largest,
        })
    }

    fn core_problem(p: problem::Problem) -> CoreProblem {
        CoreProblem {
            kind: match p.kind {
                problem::ProblemKind::DiskFull => CoreProblemKind::DiskFull,
                problem::ProblemKind::CantWrite => CoreProblemKind::CantWrite,
                problem::ProblemKind::FileExists => CoreProblemKind::FileExists,
                problem::ProblemKind::NotFound => CoreProblemKind::NotFound,
                problem::ProblemKind::NeedsLogin => CoreProblemKind::NeedsLogin,
                problem::ProblemKind::Fat32 => CoreProblemKind::Fat32,
                problem::ProblemKind::BadTorrent => CoreProblemKind::BadTorrent,
                problem::ProblemKind::Unknown => CoreProblemKind::Unknown,
            },
            status: p.status,
            explanation: p.explanation,
            fix: match p.fix {
                problem::Fix::Retry => CoreFix::Retry,
                problem::Fix::ChooseFolder => CoreFix::ChooseFolder,
                problem::Fix::Resolve => CoreFix::Resolve,
                problem::Fix::CopyLink => CoreFix::CopyLink,
                problem::Fix::ChooseAnotherFile => CoreFix::ChooseAnotherFile,
            },
            raw_message: (!p.raw.is_empty()).then_some(p.raw),
            code: Some(p.code),
        }
    }

    fn phase_for(&self, st: &State, r: &Record, hours: Hours, auto: Option<CoreAutoPause>) -> CorePhase {
        if let Some(job) = st.jobs.get(&r.id) {
            return CorePhase::Checking { progress: job.fraction(), seconds_left: job.seconds_left() };
        }
        let live = st.live.get(&r.gid);
        if let Some(at) = r.completed_at {
            if let Some(l) = live.filter(|l| l.status == "active" && l.seeder) {
                let ratio = if r.total_bytes > 0 { l.uploaded as f64 / r.total_bytes as f64 } else { 0.0 };
                let target = match r.seed.clone().unwrap_or(match &st.settings.after_download {
                    CoreSeed::Ratio { ratio } => Seed::Ratio(*ratio),
                    _ => Seed::Stop,
                }) {
                    Seed::Ratio(x) => Some(x),
                    _ => None,
                };
                return CorePhase::Seeding { ratio, target };
            }
            return CorePhase::Completed { at };
        }
        if r.problem.is_some() {
            return CorePhase::Error { problem: Self::core_problem(self.problem_for(st, r)) };
        }
        if !volume::is_available(&r.dir_path()) {
            return CorePhase::WaitingForDrive { volume_name: volume::display_name(&r.dir_path(), &st.env.boot_volume_name) };
        }
        if r.intent == Intent::Paused {
            return CorePhase::Paused;
        }
        if let Some(reason) = auto.filter(|_| !r.ignore_auto_pause) {
            return CorePhase::AutoPaused { reason };
        }
        if let Hold::Scheduled { starts_at } = scheduler::task_hold(hours, r.start_at, r.override_until, now()) {
            return CorePhase::Scheduled { starts_at };
        }
        let Some(l) = live else { return CorePhase::Resuming };
        match l.status.as_str() {
            "waiting" => return CorePhase::Queued { position: l.waiting_position.max(1) },
            "paused" => return CorePhase::Resuming,
            _ => {}
        }
        if l.verify_pending {
            return CorePhase::Checking { progress: 0.0, seconds_left: None };
        }
        if r.kind == Kind::Magnet && r.torrent_path.is_none() {
            return CorePhase::FetchingMetadata { peers: l.connections };
        }
        if !st.env.network_available {
            return CorePhase::WaitingForNetwork;
        }
        let recently_resumed = r.resumed_at.is_some_and(|t| now() - t <= 10) || r.imported_at.is_some_and(|t| now() - t <= 10);
        if recently_resumed && l.down == 0 {
            return CorePhase::Resuming;
        }
        if l.down == 0 {
            let since = st.last_moving.get(&r.id).map(|t| t.elapsed()).unwrap_or(Duration::from_secs(0));
            let resumed_ago = r.resumed_at.map(|t| now() - t).unwrap_or(i64::MAX);
            if since > Duration::from_secs(120) || (!st.last_moving.contains_key(&r.id) && resumed_ago > 120) {
                return CorePhase::Stalled;
            }
        }
        CorePhase::Downloading
    }

    fn build_snapshot(&self, st: &State) -> CoreSnapshot {
        let hours = Self::hours(st);
        let auto = Self::auto_pause(st);
        let mut down = 0i64;
        let mut up = 0i64;
        let tasks: Vec<CoreTask> = st
            .lib
            .records
            .iter()
            .map(|r| {
                let live = st.live.get(&r.gid);
                let t = st.torrents.get(&r.id);
                let (dl, ul) = live.map(|l| (l.down as i64, l.up as i64)).unwrap_or((0, 0));
                down += dl;
                up += ul;
                let dir = r.dir_path();
                CoreTask {
                    id: r.id.clone(),
                    name: r.name.clone(),
                    kind: match r.kind {
                        Kind::Torrent => CoreKind::Torrent,
                        Kind::Magnet => CoreKind::Magnet,
                        Kind::Http => CoreKind::Http,
                    },
                    phase: self.phase_for(st, r, hours, auto),
                    completed_bytes: r.completed_bytes as i64,
                    total_bytes: r.total_bytes as i64,
                    download_speed: dl,
                    upload_speed: ul,
                    seeders: live.map(|l| l.seeders).unwrap_or(0),
                    peers: live.map(|l| l.connections).unwrap_or(0),
                    directory: r.dir.clone(),
                    volume_name: volume::display_name(&dir, &st.env.boot_volume_name),
                    volume_is_external: volume::is_external(&dir),
                    primary_file: r.primary_file.as_ref().map(|p| dir.join(p).to_string_lossy().into_owned()),
                    added_at: r.added_at,
                    completed_at: r.completed_at,
                    speed_limit: r.speed_limit.map(|l| l as i64),
                    start_at: r.start_at,
                    info_hash: r.info_hash.clone(),
                    magnet_link: t.map(|t| t.magnet()).or_else(|| r.magnet.clone()),
                    source_url: r.url.clone(),
                    gid: Some(r.gid.clone()),
                    piece_length: t.map(|t| t.piece_length as i64),
                    piece_count: t.map(|t| t.piece_count()),
                    pieces_done: r.pieces_done,
                    tracker_count: t.map(|t| t.trackers.len() as u32).unwrap_or(0),
                    created_by: t.and_then(|t| t.created_by.clone()),
                    comment: t.and_then(|t| t.comment.clone()),
                    just_imported: r.imported_at.is_some_and(|t| now() - t <= 8),
                }
            })
            .collect();
        let dd = PathBuf::from(&st.settings.default_directory);
        let default_volume = Some(CoreVolume {
            name: volume::display_name(&dd, &st.env.boot_volume_name),
            is_external: volume::is_external(&dd),
            is_connected: volume::is_available(&dd),
            free_bytes: volume::is_available(&dd).then(|| volume::free_bytes(&dd)).flatten().map(|b| b as i64),
        });
        CoreSnapshot {
            tasks,
            download_speed: down,
            upload_speed: up,
            slow_mode: {
                let mut sm = st.lib.slow_mode;
                scheduler::slow_mode_effective(&mut sm, st.settings.slow_mode_scheduled, &window(&st.settings.slow_mode_hours), &Self::clock(st))
            },
            engine: st.engine.clone(),
            schedule: match hours {
                Hours::AnyTime => CoreSchedule::AnyTime,
                Hours::Inside { ends_at } => CoreSchedule::Inside { ends_at },
                Hours::Outside { starts_at } => CoreSchedule::Outside { starts_at },
            },
            default_volume,
            auto_pause: auto,
        }
    }

    // MARK: Public actions

    fn with<R>(&self, f: impl FnOnce(&mut State) -> R) -> R {
        let r = {
            let mut st = self.st.lock().unwrap();
            f(&mut st)
        };
        self.wake();
        r
    }

    pub fn snapshot_now(&self) -> CoreSnapshot {
        let st = self.st.lock().unwrap();
        self.build_snapshot(&st)
    }

    pub fn shutdown(&self) {
        if !self.running.swap(false, Ordering::SeqCst) {
            return;
        }
        self.wake();
        if let Some(h) = self.thread.lock().unwrap().take() {
            let _ = h.join();
        }
        let mut st = self.st.lock().unwrap();
        for job in st.jobs.values() {
            job.cancel.store(true, Ordering::Relaxed);
        }
        st.store.save(&st.lib);
        if let Some(a) = st.aria2.take() {
            a.stop();
        }
        st.journal.end();
        tlog!("engine stopped cleanly");
    }

    pub fn update_settings(&self, s: CoreSettings) {
        self.with(|st| {
            let old = engine_options(&st.settings);
            let new = engine_options(&s);
            st.settings = s;
            if st.aria2.is_some() && restart_key(&old) != restart_key(&new) {
                Self::restart_aria2(st, "engine options changed");
            }
            st.applied_concurrency = None;
        });
    }

    pub fn update_environment(&self, env: CoreEnvironment) {
        self.with(|st| {
            if env.network_generation != st.env.network_generation {
                st.net_changed_at = Instant::now();
            }
            st.env = env;
        });
    }

    pub fn restart_engine(&self) {
        self.with(|st| Self::restart_aria2(st, "requested"));
    }

    pub fn volume_will_unmount(&self, mount: &str) {
        self.with(|st| {
            let gids: Vec<String> = st
                .lib
                .records
                .iter()
                .filter(|r| volume::expected_mount(&r.dir_path()) == mount && st.added.contains(&r.gid))
                .map(|r| r.gid.clone())
                .collect();
            for g in &gids {
                Self::evict(st, g);
            }
            if !gids.is_empty() {
                tlog!("{mount} is ejecting: released {} downloads", gids.len());
            }
        });
    }

    pub fn set_slow_mode(&self, on: bool) {
        self.with(|st| {
            let clock = Self::clock(st);
            let sched = scheduler::in_window(&window(&st.settings.slow_mode_hours), &clock, clock.now);
            st.lib.slow_mode.manual = Some(on);
            st.lib.slow_mode.schedule_at_toggle = st.settings.slow_mode_scheduled && sched;
            st.store.save(&st.lib);
        });
    }

    fn records_mut<'a>(st: &'a mut State, ids: &[String]) -> impl Iterator<Item = &'a mut Record> {
        let set: HashSet<String> = ids.iter().cloned().collect();
        st.lib.records.iter_mut().filter(move |r| set.contains(&r.id))
    }

    pub fn pause(&self, ids: Vec<String>) {
        self.with(|st| {
            let mut stop_seeding = Vec::new();
            for r in Self::records_mut(st, &ids) {
                if r.is_complete() {
                    r.seeding_done = true;
                    stop_seeding.push(r.gid.clone());
                } else {
                    r.intent = Intent::Paused;
                }
            }
            for g in stop_seeding {
                if st.added.contains(&g) {
                    Self::evict(st, &g);
                }
            }
            for id in &ids {
                if let Some(r) = st.lib.records.iter().find(|r| &r.id == id) {
                    if st.added.contains(&r.gid) && !r.is_complete() {
                        let _ = Self::call(st, "aria2.forcePause", vec![json!(r.gid)]);
                    }
                }
            }
            st.store.save(&st.lib);
        });
    }

    pub fn resume(&self, ids: Vec<String>) {
        self.with(|st| {
            let auto = Self::auto_pause(st).is_some();
            for r in Self::records_mut(st, &ids) {
                if r.is_complete() {
                    continue;
                }
                if r.intent == Intent::Run && auto {
                    r.ignore_auto_pause = true; // "Resume Anyway"
                }
                r.intent = Intent::Run;
                r.problem = None;
            }
            st.store.save(&st.lib);
        });
    }

    pub fn pause_all(&self) {
        let ids = self.st.lock().unwrap().lib.records.iter().filter(|r| !r.is_complete()).map(|r| r.id.clone()).collect();
        self.pause(ids);
    }

    pub fn resume_all(&self) {
        let ids: Vec<String> = self.st.lock().unwrap().lib.records.iter().filter(|r| !r.is_complete()).map(|r| r.id.clone()).collect();
        self.with(|st| {
            let auto = Self::auto_pause(st).is_some();
            let hours_out = matches!(Self::hours(st), Hours::Outside { .. });
            for r in Self::records_mut(st, &ids) {
                if r.intent == Intent::Run && auto {
                    r.ignore_auto_pause = true;
                }
                if r.intent == Intent::Run && hours_out && r.start_at.is_none() {
                    r.override_until = Some(i64::MAX); // header's "Start Now"
                }
                r.intent = Intent::Run;
            }
            st.store.save(&st.lib);
        });
    }

    pub fn start_now(&self, ids: Vec<String>) {
        self.with(|st| {
            let mut gids = Vec::new();
            for r in Self::records_mut(st, &ids) {
                r.intent = Intent::Run;
                r.start_at = None;
                r.override_until = Some(i64::MAX);
                r.ignore_auto_pause = true;
                gids.push(r.gid.clone());
            }
            for g in gids {
                if st.live.get(&g).is_some_and(|l| l.status == "waiting") {
                    let _ = Self::call(st, "aria2.changePosition", vec![json!(g), json!(0), json!("POS_SET")]);
                }
            }
            st.store.save(&st.lib);
        });
    }

    pub fn start_at(&self, ids: Vec<String>, at: Option<i64>) {
        self.with(|st| {
            for r in Self::records_mut(st, &ids) {
                r.start_at = at;
                r.override_until = None;
                r.intent = Intent::Run;
            }
            st.store.save(&st.lib);
        });
    }

    /// Returns paths the caller should move to the Trash (only when `trash` is set).
    pub fn remove(&self, ids: Vec<String>, trash: bool) -> Vec<String> {
        self.with(|st| {
            let mut out = Vec::new();
            for id in &ids {
                let Some(pos) = st.lib.records.iter().position(|r| &r.id == id) else { continue };
                let r = st.lib.records[pos].clone();
                if let Some(job) = st.jobs.remove(id) {
                    job.cancel.store(true, Ordering::Relaxed);
                }
                if st.added.contains(&r.gid) || st.live.contains_key(&r.gid) {
                    Self::evict(st, &r.gid);
                }
                if trash {
                    let dir = r.dir_path();
                    let top = match r.kind {
                        Kind::Http => r.primary_file.clone().unwrap_or(r.name.clone()),
                        _ => Self::torrent_for(st, id).map(|t| t.name.clone()).unwrap_or(r.name.clone()),
                    };
                    for p in [dir.join(&top), dir.join(format!("{top}.aria2"))] {
                        if p.exists() {
                            out.push(p.to_string_lossy().into_owned());
                        }
                    }
                }
                st.lib.records.remove(pos);
                st.journal.forget(id);
                st.torrents.remove(id);
                tlog!("removed {} (trash={trash})", r.name);
            }
            st.store.save(&st.lib);
            out
        })
    }

    pub fn clear_completed(&self) {
        self.with(|st| {
            let gone: Vec<String> = st.lib.records.iter().filter(|r| r.is_complete() && !st.added.contains(&r.gid)).map(|r| r.id.clone()).collect();
            st.lib.records.retain(|r| !gone.contains(&r.id));
            st.store.save(&st.lib);
        });
    }

    pub fn set_selected_files(&self, id: &str, indexes: Vec<u32>) -> Result<(), CoreError> {
        if indexes.is_empty() {
            return Err(CoreError::msg("Choose at least one file."));
        }
        self.with(|st| {
            let Some(i) = st.lib.records.iter().position(|r| r.id == id) else { return Err(CoreError::msg("not found")) };
            let gid = st.lib.records[i].gid.clone();
            if st.added.contains(&gid) {
                // select-file can only change on a paused download.
                let was = st.live.get(&gid).map(|l| l.status.clone()).unwrap_or_default();
                let _ = Self::call(st, "aria2.forcePause", vec![json!(gid)]);
                let deadline = Instant::now() + Duration::from_secs(3);
                while Instant::now() < deadline {
                    match Self::call(st, "aria2.tellStatus", vec![json!(gid), json!(["status"])]) {
                        Ok(v) if v.get("status").and_then(Value::as_str) == Some("paused") => break,
                        Err(_) => break,
                        _ => std::thread::sleep(Duration::from_millis(40)),
                    }
                }
                Self::call(st, "aria2.changeOption", vec![json!(gid), json!({"select-file": csv(&indexes)})])
                    .map_err(|e| CoreError::msg(e.to_string()))?;
                if was == "active" || was == "waiting" {
                    let _ = Self::call(st, "aria2.unpause", vec![json!(gid)]);
                }
            }
            let t = Self::torrent_for(st, id);
            let r = &mut st.lib.records[i];
            r.selected = Some(indexes.clone());
            if let Some(t) = t {
                r.total_bytes = t.selected_length(&indexes);
                r.primary_file = primary_file(&t, &indexes);
            }
            st.store.save(&st.lib);
            Ok(())
        })
    }

    pub fn set_speed_limit(&self, ids: Vec<String>, limit: Option<i64>) {
        self.with(|st| {
            let lim = limit.filter(|&l| l > 0).map(|l| l as u64);
            let mut gids = Vec::new();
            for r in Self::records_mut(st, &ids) {
                r.speed_limit = lim;
                gids.push(r.gid.clone());
            }
            for g in gids {
                if st.added.contains(&g) {
                    let _ = Self::call(st, "aria2.changeOption", vec![json!(g), json!({"max-download-limit": lim.unwrap_or(0).to_string()})]);
                }
            }
            st.store.save(&st.lib);
        });
    }

    pub fn set_seed_policy(&self, ids: Vec<String>, policy: Option<CoreSeed>) {
        self.with(|st| {
            for r in Self::records_mut(st, &ids) {
                r.seed = policy.as_ref().map(|p| match p {
                    CoreSeed::Stop => Seed::Stop,
                    CoreSeed::Ratio { ratio } => Seed::Ratio(*ratio),
                    CoreSeed::Minutes { minutes } => Seed::Minutes(*minutes),
                });
            }
            st.store.save(&st.lib);
        });
    }

    pub fn move_task(&self, id: &str, mv: CoreMove) {
        self.with(|st| {
            let incomplete: Vec<usize> = (0..st.lib.records.len()).filter(|&i| !st.lib.records[i].is_complete()).collect();
            let Some(cur) = incomplete.iter().position(|&i| st.lib.records[i].id == id) else { return };
            let target = match mv {
                CoreMove::Top => 0,
                CoreMove::Bottom => incomplete.len() - 1,
                CoreMove::Up => cur.saturating_sub(1),
                CoreMove::Down => (cur + 1).min(incomplete.len() - 1),
                CoreMove::Index { index } => (index as usize).min(incomplete.len() - 1),
            };
            let mut order: Vec<Record> = incomplete.iter().map(|&i| st.lib.records[i].clone()).collect();
            let item = order.remove(cur);
            order.insert(target, item);
            let done: Vec<Record> = st.lib.records.iter().filter(|r| r.is_complete()).cloned().collect();
            st.lib.records = order.into_iter().chain(done).collect();
            for (n, r) in st.lib.records.iter_mut().enumerate() {
                r.order = n as i64;
            }
            // Mirror the new order onto aria2's waiting queue.
            let waiting: Vec<String> = st.lib.records.iter().filter(|r| st.live.get(&r.gid).is_some_and(|l| l.status == "waiting")).map(|r| r.gid.clone()).collect();
            for (n, g) in waiting.iter().enumerate() {
                let _ = Self::call(st, "aria2.changePosition", vec![json!(g), json!(n), json!("POS_SET")]);
            }
            st.store.save(&st.lib);
        });
    }

    pub fn verify(self: &Arc<Self>, id: &str) {
        let mut st = self.st.lock().unwrap();
        if st.lib.records.iter().any(|r| r.id == id && r.kind == Kind::Torrent) {
            self.start_verify(&mut st, id, VerifyMode::Full);
        }
        drop(st);
        self.wake();
    }

    pub fn retry(&self, id: &str) {
        self.with(|st| {
            let gid = st.lib.records.iter().find(|r| r.id == id).map(|r| r.gid.clone());
            if let Some(g) = gid {
                if st.live.get(&g).is_some_and(|l| l.status == "error") {
                    Self::remove_result(st, &g);
                }
            }
            if let Some(r) = st.lib.records.iter_mut().find(|r| r.id == id) {
                r.problem = None;
                r.intent = Intent::Run;
            }
            st.store.save(&st.lib);
        });
    }

    // MARK: Details

    pub fn files(&self, id: &str) -> Vec<CoreFile> {
        let mut st = self.st.lock().unwrap();
        let Some(r) = st.lib.records.iter().find(|r| r.id == id).cloned() else { return vec![] };
        if st.added.contains(&r.gid) {
            if let Ok(Value::Array(files)) = Self::call(&st, "aria2.getFiles", vec![json!(r.gid)]) {
                let t = Self::torrent_for(&mut st, id);
                return files
                    .iter()
                    .map(|f| {
                        let index = num(f, "index") as u32;
                        let abs = f.get("path").and_then(Value::as_str).unwrap_or("");
                        let path = abs.strip_prefix(&format!("{}/", r.dir)).unwrap_or(abs).to_string();
                        let tf = t.as_ref().and_then(|t| t.files.iter().find(|x| x.index == index).cloned()).unwrap_or(TorrentFile {
                            index, path: path.clone(), length: num(f, "length"), offset: 0, is_padding: false,
                        });
                        CoreFile {
                            index,
                            path: if path.is_empty() { tf.path.clone() } else { path },
                            length: num(f, "length") as i64,
                            completed_length: num(f, "completedLength") as i64,
                            selected: f.get("selected").and_then(Value::as_str) == Some("true"),
                            tag: tag(smart_select::classify(&tf)),
                        }
                    })
                    .filter(|f| !(t.as_ref().is_some_and(|t| t.files.iter().any(|x| x.index == f.index && x.is_padding))))
                    .collect();
            }
        }
        let Some(t) = Self::torrent_for(&mut st, id) else { return vec![] };
        let sel = r.selected.clone().unwrap_or_else(|| t.all_indexes());
        let c = ControlFile::read(&r.dir_path().join(format!("{}.aria2", t.name))).ok();
        core_files(&t, &sel, c.as_ref())
    }

    pub fn peers(&self, id: &str) -> Vec<CorePeer> {
        let st = self.st.lock().unwrap();
        let Some(r) = st.lib.records.iter().find(|r| r.id == id) else { return vec![] };
        if !st.added.contains(&r.gid) {
            return vec![];
        }
        let Ok(Value::Array(peers)) = Self::call(&st, "aria2.getPeers", vec![json!(r.gid)]) else { return vec![] };
        let pieces = st.live.get(&r.gid).map(|l| l.num_pieces).unwrap_or(0).max(1);
        let mut out: Vec<CorePeer> = peers
            .iter()
            .map(|p| {
                let ip = p.get("ip").and_then(Value::as_str).unwrap_or("");
                let port = p.get("port").and_then(Value::as_str).unwrap_or("");
                let address = if ip.contains(':') { format!("[{ip}]:{port}") } else { format!("{ip}:{port}") };
                let bits = p.get("bitfield").and_then(Value::as_str).map(popcount_hex).unwrap_or(0);
                CorePeer {
                    address,
                    client: client_name(p.get("peerId").and_then(Value::as_str).unwrap_or("")),
                    progress: (bits as f64 / pieces as f64).min(1.0),
                    download_speed: num(p, "downloadSpeed") as i64,
                    upload_speed: num(p, "uploadSpeed") as i64,
                    is_seeder: p.get("seeder").and_then(Value::as_str) == Some("true"),
                }
            })
            .collect();
        out.sort_by(|a, b| b.download_speed.cmp(&a.download_speed));
        out
    }

    pub fn pieces(&self, id: &str) -> Option<CorePieces> {
        let mut st = self.st.lock().unwrap();
        let r = st.lib.records.iter().find(|r| r.id == id).cloned()?;
        if let Some(l) = st.live.get(&r.gid) {
            if let (Some(b), n) = (&l.bitfield, l.num_pieces) {
                if n > 0 {
                    return Some(CorePieces { count: n, bits: torrent::unhex(b).unwrap_or_default() });
                }
            }
        }
        let t = Self::torrent_for(&mut st, id)?;
        let c = ControlFile::read(&r.dir_path().join(format!("{}.aria2", t.name))).ok()?;
        Some(CorePieces { count: c.piece_count(), bits: c.bitfield })
    }

    // MARK: Adding

    fn duplicate_of(st: &State, info_hash: Option<&str>, url: Option<&str>) -> Option<String> {
        st.lib.records.iter().find(|r| {
            (info_hash.is_some() && r.info_hash.as_deref() == info_hash) || (url.is_some() && r.url.as_deref() == url)
        }).map(|r| r.id.clone())
    }

    /// Progress already on disk for this torrent at `dir` (its `.aria2`), for the add window banner.
    fn existing_at(dir: &Path, info_hash: &str, t: Option<&Torrent>, sel: &[u32]) -> Option<(i64, f64)> {
        let try_file = |p: PathBuf| -> Option<ControlFile> {
            ControlFile::read(&p).ok().filter(|c| c.info_hash_hex().as_deref() == Some(info_hash))
        };
        let c = match t {
            Some(t) => try_file(dir.join(format!("{}.aria2", t.name))),
            None => std::fs::read_dir(dir).ok()?.filter_map(|e| e.ok()).map(|e| e.path())
                .filter(|p| p.extension().and_then(|e| e.to_str()) == Some("aria2"))
                .find_map(try_file),
        }?;
        let (done, total) = match t {
            Some(t) => (importer::selected_progress(t, &c, sel), t.selected_length(sel)),
            None => ((0..c.piece_count()).filter(|&i| c.has(i)).count() as u64 * c.piece_length as u64, c.total_length),
        };
        (done > 0 && total > 0).then(|| (done as i64, done as f64 / total as f64))
    }

    pub fn inspect(&self, source: CoreSource, destination: &str) -> CorePreview {
        let st = self.st.lock().unwrap();
        let dir = PathBuf::from(destination);
        let blank = |kind, name: String, problem| CorePreview {
            kind, name, total_bytes: None, files: vec![], smart: None, metadata_pending: false, metadata_peers: 0,
            duplicate_of: None, existing_completed: None, existing_fraction: None, problem, info_hash: None,
        };
        match source {
            CoreSource::TorrentFile { path } => {
                let fname = Path::new(&path).file_stem().map(|s| s.to_string_lossy().into_owned()).unwrap_or_default();
                let Some(t) = std::fs::read(&path).ok().and_then(|b| torrent::parse(&b).ok()) else {
                    return blank(CoreKind::Torrent, fname, Some(CoreInputProblem::UnreadableTorrent));
                };
                let sel = smart_select::select(&t.files, st.settings.only_main_video, st.settings.skip_extras).selected;
                let existing = Self::existing_at(&dir, &t.info_hash, Some(&t), &sel);
                CorePreview {
                    kind: CoreKind::Torrent,
                    name: t.name.clone(),
                    total_bytes: Some(t.total_length as i64),
                    files: core_files(&t, &sel, None),
                    smart: Some(smart_summary(&t.files, &sel)),
                    metadata_pending: false,
                    metadata_peers: 0,
                    duplicate_of: Self::duplicate_of(&st, Some(&t.info_hash), None),
                    existing_completed: existing.map(|e| e.0),
                    existing_fraction: existing.map(|e| e.1),
                    problem: None,
                    info_hash: Some(t.info_hash.clone()),
                }
            }
            CoreSource::Link { link } => {
                let link = link.trim().to_string();
                if let Some(m) = torrent::parse_magnet(&link) {
                    let existing = Self::existing_at(&dir, &m.info_hash, None, &[]);
                    let mut p = blank(CoreKind::Magnet, m.name.clone().unwrap_or_else(|| "Magnet link".into()), None);
                    p.metadata_pending = true;
                    p.info_hash = Some(m.info_hash.clone());
                    p.duplicate_of = Self::duplicate_of(&st, Some(&m.info_hash), None);
                    p.existing_completed = existing.map(|e| e.0);
                    p.existing_fraction = existing.map(|e| e.1);
                    p
                } else if is_http_like(&link) {
                    let mut p = blank(CoreKind::Http, url_file_name(&link), None);
                    p.duplicate_of = Self::duplicate_of(&st, None, Some(&link));
                    p
                } else {
                    blank(CoreKind::Http, link, Some(CoreInputProblem::InvalidLink))
                }
            }
        }
    }

    fn next_order(st: &State) -> i64 {
        st.lib.records.iter().map(|r| r.order).max().map_or(0, |m| m + 1)
    }

    pub fn add(&self, req: CoreAddRequest) -> Result<String, CoreError> {
        self.with(|st| {
            let (intent, start_at) = match req.start {
                CoreStart::Now => (Intent::Run, None),
                CoreStart::At { time } => (Intent::Run, Some(time)),
                CoreStart::Paused => (Intent::Paused, None),
            };
            let id = new_gid();
            let mut r = Record {
                id: id.clone(), gid: new_gid(), kind: Kind::Http, name: String::new(), dir: req.directory.clone(),
                info_hash: None, torrent_path: None, magnet: None, url: None, selected: None, intent, start_at,
                override_until: None, ignore_auto_pause: false, speed_limit: None, seed: None, added_at: now(),
                completed_at: None, completed_bytes: 0, total_bytes: 0, pieces_done: None, order: Self::next_order(st),
                problem: None, imported_at: None, resumed_at: None, primary_file: None, needs_check: false, seeding_done: false,
            };
            match &req.source {
                CoreSource::TorrentFile { path } => {
                    let bytes = std::fs::read(path).map_err(|e| CoreError::msg(e.to_string()))?;
                    let t = torrent::parse(&bytes).map_err(|_| CoreError::msg("This torrent file can't be read."))?;
                    if Self::duplicate_of(st, Some(&t.info_hash), None).is_some() {
                        return Err(CoreError::msg("Already in your downloads."));
                    }
                    let sel = req.selected_files.clone().filter(|s| !s.is_empty()).unwrap_or_else(|| {
                        smart_select::select(&t.files, st.settings.only_main_video, st.settings.skip_extras).selected
                    });
                    r.kind = Kind::Torrent;
                    r.name = t.name.clone();
                    r.info_hash = Some(t.info_hash.clone());
                    r.torrent_path = st.store.save_torrent(&t.info_hash, &bytes);
                    r.total_bytes = t.selected_length(&sel);
                    r.primary_file = primary_file(&t, &sel);
                    r.selected = Some(sel.clone());
                    if let Some((done, _)) = Self::existing_at(Path::new(&req.directory), &t.info_hash, Some(&t), &sel) {
                        r.completed_bytes = done as u64;
                    }
                    st.torrents.insert(id.clone(), Arc::new(t));
                }
                CoreSource::Link { link } => {
                    let link = link.trim().to_string();
                    if let Some(m) = torrent::parse_magnet(&link) {
                        if Self::duplicate_of(st, Some(&m.info_hash), None).is_some() {
                            return Err(CoreError::msg("Already in your downloads."));
                        }
                        // If aria2 already saved this torrent's metadata in the folder, use it.
                        let saved = Path::new(&req.directory).join(format!("{}.torrent", m.info_hash));
                        if let Some((bytes, t)) = std::fs::read(&saved).ok().and_then(|b| torrent::parse(&b).ok().map(|t| (b, t))) {
                            let sel = req.selected_files.clone().unwrap_or_else(|| {
                                smart_select::select(&t.files, st.settings.only_main_video, st.settings.skip_extras).selected
                            });
                            r.kind = Kind::Torrent;
                            r.name = t.name.clone();
                            r.torrent_path = st.store.save_torrent(&t.info_hash, &bytes);
                            r.total_bytes = t.selected_length(&sel);
                            r.primary_file = primary_file(&t, &sel);
                            r.selected = Some(sel);
                            st.torrents.insert(id.clone(), Arc::new(t));
                        } else {
                            r.kind = Kind::Magnet;
                            r.name = m.name.clone().unwrap_or_else(|| m.info_hash.clone());
                            r.selected = req.selected_files.clone();
                        }
                        r.info_hash = Some(m.info_hash);
                        r.magnet = Some(link);
                    } else if is_http_like(&link) {
                        if Self::duplicate_of(st, None, Some(&link)).is_some() {
                            return Err(CoreError::msg("Already in your downloads."));
                        }
                        r.kind = Kind::Http;
                        r.name = url_file_name(&link);
                        r.url = Some(link);
                    } else {
                        return Err(CoreError::msg("That doesn't look like a magnet link or URL."));
                    }
                }
            }
            tlog!("added {} to {}", r.name, r.dir);
            st.lib.records.push(r);
            st.store.save(&st.lib);
            Ok(id)
        })
    }

    // MARK: Import

    pub fn scan_imports(&self, path: &str) -> Vec<CoreImport> {
        let (support, only, skip) = {
            let st = self.st.lock().unwrap();
            (PathBuf::from(&self.cfg.support_dir), st.settings.only_main_video, st.settings.skip_extras)
        };
        let found = importer::scan(Path::new(path), &support, only, skip);
        let mut st = self.st.lock().unwrap();
        let boot = st.env.boot_volume_name.clone();
        let out = found
            .iter()
            .map(|c| {
                let files = c.torrent.as_ref().map(|t| core_files(t, &c.selected, c.control.as_ref())).unwrap_or_default();
                let data_file = c.torrent.as_ref().and_then(|t| primary_file(t, &c.selected)).map(|p| c.dir.join(p))
                    .or_else(|| c.data_path.clone());
                CoreImport {
                    id: c.id.clone(),
                    name: c.name.clone(),
                    directory: c.dir.to_string_lossy().into_owned(),
                    volume_name: volume::display_name(&c.dir, &boot),
                    total_bytes: c.total_bytes as i64,
                    completed_bytes: c.completed_bytes as i64,
                    torrent_file: c.torrent_file.as_ref().map(|p| p.to_string_lossy().into_owned()),
                    progress_file: c.progress_file.as_ref().map(|p| p.to_string_lossy().into_owned()),
                    progress_saved_at: c.progress_saved_at,
                    data_file: data_file.filter(|p| p.exists()).map(|p| p.to_string_lossy().into_owned()),
                    pieces: c.control.as_ref().map(|c| CorePieces { count: c.piece_count(), bits: c.bitfield.clone() }),
                    files,
                    smart: c.torrent.as_ref().map(|t| smart_summary(&t.files, &c.selected)),
                    needs_check: c.needs_check,
                    estimated_check_seconds: c.estimated_check_secs,
                    already_in_library: Self::duplicate_of(&st, Some(&c.info_hash), None).is_some(),
                }
            })
            .collect();
        for c in found {
            st.last_scan.insert(c.id.clone(), c);
        }
        out
    }

    pub fn import(&self, items: Vec<CoreImportRequest>) -> Result<Vec<String>, CoreError> {
        let support = PathBuf::from(&self.cfg.support_dir);
        // Rescan anything the UI didn't scan through us first.
        let missing: Vec<CoreImportRequest> = {
            let st = self.st.lock().unwrap();
            items.iter().filter(|i| !st.last_scan.contains_key(&i.id)).cloned().collect()
        };
        for m in missing {
            let (only, skip) = {
                let st = self.st.lock().unwrap();
                (st.settings.only_main_video, st.settings.skip_extras)
            };
            let found = importer::scan(Path::new(&m.directory), &support, only, skip);
            let mut st = self.st.lock().unwrap();
            for c in found {
                st.last_scan.insert(c.id.clone(), c);
            }
        }
        self.with(|st| {
            let mut ids = Vec::new();
            for item in &items {
                let Some(c) = st.last_scan.get(&item.id).cloned() else {
                    return Err(CoreError::msg("That download isn't there anymore."));
                };
                if Self::duplicate_of(st, Some(&c.info_hash), None).is_some() {
                    continue;
                }
                let id = new_gid();
                let mut r = Record {
                    id: id.clone(), gid: new_gid(), kind: Kind::Magnet, name: c.name.clone(),
                    dir: c.dir.to_string_lossy().into_owned(), info_hash: Some(c.info_hash.clone()), torrent_path: None,
                    magnet: Some(format!("magnet:?xt=urn:btih:{}&dn={}", c.info_hash, torrent::percent_encode(&c.name))),
                    url: None, selected: None, intent: Intent::Run, start_at: None, override_until: None,
                    ignore_auto_pause: false, speed_limit: None, seed: None, added_at: now(), completed_at: None,
                    completed_bytes: c.completed_bytes, total_bytes: c.total_bytes,
                    pieces_done: c.control.as_ref().map(|c| c.done_count()), order: Self::next_order(st), problem: None,
                    imported_at: Some(now()), resumed_at: Some(now()), primary_file: None, needs_check: c.needs_check,
                    seeding_done: false,
                };
                if let (Some(t), Some(tp)) = (&c.torrent, &c.torrent_file) {
                    let bytes = std::fs::read(tp).map_err(|e| CoreError::msg(e.to_string()))?;
                    let sel = item.selected_files.clone().filter(|s| !s.is_empty()).unwrap_or_else(|| c.selected.clone());
                    r.kind = Kind::Torrent;
                    r.torrent_path = st.store.save_torrent(&t.info_hash, &bytes);
                    r.selected = Some(sel.clone());
                    r.total_bytes = t.selected_length(&sel);
                    if let Some(ctl) = &c.control {
                        r.completed_bytes = importer::selected_progress(t, ctl, &sel);
                    }
                    r.primary_file = primary_file(t, &sel);
                    st.torrents.insert(id.clone(), Arc::new(t.clone()));
                }
                tlog!("imported {} from {} at {:.1}%", r.name, r.dir, if r.total_bytes > 0 { r.completed_bytes as f64 * 100.0 / r.total_bytes as f64 } else { 0.0 });
                st.lib.records.push(r);
                ids.push(id);
            }
            st.store.save(&st.lib);
            Ok(ids)
        })
    }

    pub fn log_path(&self) -> String {
        PathBuf::from(&self.cfg.log_dir).join("tide.log").to_string_lossy().into_owned()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn helpers() {
        assert_eq!(url_file_name("https://cdimage.ubuntu.com/releases/ubuntu-26.04-desktop-arm64.iso?x=1"), "ubuntu-26.04-desktop-arm64.iso");
        assert_eq!(url_file_name("https://example.com/"), "example.com");
        assert_eq!(url_file_name("https://example.com/My%20File.zip"), "My File.zip");
        assert!(is_http_like("https://example.com/a"));
        assert!(!is_http_like("hello"));
        assert_eq!(client_name("-qB4620-abcdefghijkl"), "qBittorrent 4.6.2");
        assert_eq!(client_name("-TR4060-xxxxxxxxxxxx"), "Transmission 4.0.6");
        assert_eq!(client_name("A2-1-37-0-xxxx"), "aria2");
        assert_eq!(popcount_hex("f0a"), 6);
        let w = window(&CoreWindow { start_minute: 60, end_minute: 480, weekdays: vec![1, 7] });
        assert_eq!(w.weekdays, 0b100_0001);
    }

    #[test]
    fn inspect_reports_the_info_hash() {
        let support = tempfile::tempdir().unwrap();
        let logs = tempfile::tempdir().unwrap();
        let e = Engine::new(CoreConfig {
            aria2_path: String::new(),
            support_dir: support.path().to_string_lossy().into(),
            log_dir: logs.path().to_string_lossy().into(),
            app_pid: std::process::id(),
        });
        let dir = support.path().to_string_lossy().into_owned();

        let data = vec![7u8; 40_000];
        let bytes = torrent::make_torrent("Show", &[("a.mkv", 30_000), ("b.txt", 10_000)], 16_384, &data, &[]);
        let expected = torrent::parse(&bytes).unwrap().info_hash;
        let path = support.path().join("x.torrent");
        std::fs::write(&path, &bytes).unwrap();
        let p = e.inspect(CoreSource::TorrentFile { path: path.to_string_lossy().into() }, &dir);
        assert_eq!(p.info_hash.as_deref(), Some(expected.as_str()));
        assert_eq!(p.files.len(), 2);

        let magnet = "magnet:?xt=urn:btih:2C6B6858D61DA9543D4231A71DB4B1C9264B0685&dn=Ubuntu";
        let p = e.inspect(CoreSource::Link { link: magnet.into() }, &dir);
        assert_eq!(p.info_hash.as_deref(), Some("2c6b6858d61da9543d4231a71db4b1c9264b0685"));

        let p = e.inspect(CoreSource::Link { link: "https://example.com/file.zip".into() }, &dir);
        assert_eq!(p.info_hash, None);
    }

    #[test]
    fn network_change_refreshes_aria2_only_when_bittorrent_needs_it() {
        let settled = NETWORK_SETTLE;
        // Same network as aria2 started on: nothing to do.
        assert!(!network_refresh_due(Some(3), 3, true, settled, true));
        // New network while a torrent wants to run: refresh.
        assert!(network_refresh_due(Some(3), 4, true, settled, true));
        // New network while everything BitTorrent is paused: wait for the resume.
        assert!(!network_refresh_due(Some(3), 4, true, settled, false));
        // Still settling, or offline, or no aria2: wait.
        assert!(!network_refresh_due(Some(3), 4, true, Duration::from_secs(1), true));
        assert!(!network_refresh_due(Some(3), 4, false, settled, true));
        assert!(!network_refresh_due(None, 4, true, settled, true));
    }

    #[test]
    fn discovery_watchdog_needs_a_long_silence_everywhere_and_backs_off() {
        let stall = Some(DISCOVERY_STALL);
        let short = Some(DISCOVERY_STALL - Duration::from_secs(1));
        assert!(discovery_dead(stall, false, None, DISCOVERY_STALL));
        // Not long enough, or no torrent waiting for peers.
        assert!(!discovery_dead(short, false, None, DISCOVERY_STALL));
        assert!(!discovery_dead(None, false, None, DISCOVERY_STALL));
        // Another torrent has peers: discovery works, that swarm is just empty.
        assert!(!discovery_dead(stall, true, None, DISCOVERY_STALL));
        // Backoff since the last stall restart.
        let backoff = DISCOVERY_STALL * 2;
        assert!(!discovery_dead(stall, false, Some(backoff - Duration::from_secs(1)), backoff));
        assert!(discovery_dead(stall, false, Some(backoff), backoff));
    }
}
