//! Tide's core. Swift talks to `TideEngine` over UniFFI; everything else is internal.

uniffi::setup_scaffolding!();

pub mod bencode;
pub mod control_file;
pub mod engine;
pub mod importer;
pub mod journal;
pub mod model;
pub mod problem;
pub mod rpc;
pub mod scheduler;
pub mod smart_select;
pub mod store;
pub mod supervisor;
pub mod torrent;
pub mod util;
pub mod verify;
pub mod volume;

use model::*;
use std::sync::Arc;

/// Implemented in Swift. Called from Tide's engine thread.
#[uniffi::export(with_foreign)]
pub trait EngineListener: Send + Sync {
    fn on_snapshot(&self, snapshot: CoreSnapshot);
    fn on_event(&self, event: CoreEvent);
}

struct ListenerSink(Arc<dyn EngineListener>);

impl engine::Sink for ListenerSink {
    fn snapshot(&self, s: CoreSnapshot) {
        self.0.on_snapshot(s);
    }
    fn event(&self, e: CoreEvent) {
        self.0.on_event(e);
    }
}

#[derive(uniffi::Object)]
pub struct TideEngine {
    inner: Arc<engine::Engine>,
}

#[uniffi::export]
impl TideEngine {
    #[uniffi::constructor]
    pub fn new(config: CoreConfig) -> Arc<Self> {
        Arc::new(TideEngine { inner: engine::Engine::new(config) })
    }

    pub fn start(&self, settings: CoreSettings, listener: Arc<dyn EngineListener>) {
        self.inner.start(settings, Arc::new(ListenerSink(listener)));
    }

    pub fn shutdown(&self) {
        self.inner.shutdown();
    }

    pub fn set_ui_visible(&self, visible: bool) {
        self.inner.set_visible(visible);
    }

    pub fn snapshot(&self) -> CoreSnapshot {
        self.inner.snapshot_now()
    }

    pub fn inspect(&self, source: CoreSource, destination: String) -> CorePreview {
        self.inner.inspect(source, &destination)
    }

    pub fn add(&self, request: CoreAddRequest) -> Result<String, CoreError> {
        self.inner.add(request)
    }

    pub fn pause(&self, ids: Vec<String>) {
        self.inner.pause(ids);
    }

    pub fn resume(&self, ids: Vec<String>) {
        self.inner.resume(ids);
    }

    pub fn pause_all(&self) {
        self.inner.pause_all();
    }

    pub fn resume_all(&self) {
        self.inner.resume_all();
    }

    pub fn start_now(&self, ids: Vec<String>) {
        self.inner.start_now(ids);
    }

    pub fn start_at(&self, ids: Vec<String>, time: Option<i64>) {
        self.inner.start_at(ids, time);
    }

    /// Returns the paths Swift should move to the Trash.
    pub fn remove(&self, ids: Vec<String>, trash_files: bool) -> Vec<String> {
        self.inner.remove(ids, trash_files)
    }

    pub fn clear_completed(&self) {
        self.inner.clear_completed();
    }

    pub fn set_selected_files(&self, id: String, indexes: Vec<u32>) -> Result<(), CoreError> {
        self.inner.set_selected_files(&id, indexes)
    }

    pub fn set_speed_limit(&self, ids: Vec<String>, bytes_per_second: Option<i64>) {
        self.inner.set_speed_limit(ids, bytes_per_second);
    }

    pub fn set_seed_policy(&self, ids: Vec<String>, policy: Option<CoreSeed>) {
        self.inner.set_seed_policy(ids, policy);
    }

    pub fn move_task(&self, id: String, to: CoreMove) {
        self.inner.move_task(&id, to);
    }

    pub fn verify(&self, id: String) {
        self.inner.verify(&id);
    }

    pub fn retry(&self, id: String) {
        self.inner.retry(&id);
    }

    pub fn files(&self, id: String) -> Vec<CoreFile> {
        self.inner.files(&id)
    }

    pub fn peers(&self, id: String) -> Vec<CorePeer> {
        self.inner.peers(&id)
    }

    pub fn pieces(&self, id: String) -> Option<CorePieces> {
        self.inner.pieces(&id)
    }

    pub fn scan_imports(&self, path: String) -> Vec<CoreImport> {
        self.inner.scan_imports(&path)
    }

    pub fn import_downloads(&self, items: Vec<CoreImportRequest>) -> Result<Vec<String>, CoreError> {
        self.inner.import(items)
    }

    pub fn set_slow_mode(&self, on: bool) {
        self.inner.set_slow_mode(on);
    }

    pub fn update_settings(&self, settings: CoreSettings) {
        self.inner.update_settings(settings);
    }

    pub fn update_environment(&self, environment: CoreEnvironment) {
        self.inner.update_environment(environment);
    }

    pub fn volume_will_unmount(&self, mount_path: String) {
        self.inner.volume_will_unmount(&mount_path);
    }

    pub fn restart_engine(&self) {
        self.inner.restart_engine();
    }

    pub fn log_path(&self) -> String {
        self.inner.log_path()
    }
}

#[uniffi::export]
pub fn core_version() -> String {
    env!("CARGO_PKG_VERSION").to_string()
}

/// Bundled aria2c next to the running executable, else Homebrew's.
#[uniffi::export]
pub fn default_aria2_path() -> String {
    supervisor::default_binary().to_string_lossy().into_owned()
}

/// Read-only verification of up to `sample` random done pieces of a torrent download — used by
/// `Tide --cli verify-sample` to check real data and measure throughput.
#[uniffi::export]
pub fn verify_sample(torrent_path: String, directory: String, sample: u32) -> String {
    let Ok(bytes) = std::fs::read(&torrent_path) else { return "can't read torrent".into() };
    let Ok(t) = torrent::parse(&bytes) else { return "torrent can't be parsed".into() };
    let cpath = std::path::Path::new(&directory).join(format!("{}.aria2", t.name));
    let Ok(c) = control_file::ControlFile::read(&cpath) else { return "no progress file".into() };
    let done: Vec<u32> = (0..c.piece_count()).filter(|&i| c.has(i)).collect();
    if done.is_empty() {
        return "no finished pieces".into();
    }
    let step = (done.len() as f64 / sample.max(1) as f64).max(1.0);
    let pick: Vec<u32> = (0..sample.min(done.len() as u32)).map(|k| done[(k as f64 * step) as usize]).collect();
    let r = verify::verify_pieces(&t, std::path::Path::new(&directory), &pick, 8, &std::sync::atomic::AtomicBool::new(false), &|_, _| {});
    format!(
        "checked {} of {} finished pieces: {} good, {} bad, {:.0} MB/s",
        pick.len(), done.len(), r.good.len(), r.bad.len(), r.throughput().unwrap_or(0.0) / 1e6
    )
}
