//! Types that cross the FFI boundary (UniFFI records/enums). Swift's TideEngine target maps them
//! onto TideKit's UI models. Times are unix seconds; sizes are bytes (i64 for Swift's Int64).

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum CoreKind {
    Torrent,
    Magnet,
    Http,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum CoreAutoPause {
    Battery,
    ExpensiveNetwork,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum CoreProblemKind {
    DiskFull,
    CantWrite,
    FileExists,
    NotFound,
    NeedsLogin,
    Fat32,
    BadTorrent,
    Unknown,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum CoreFix {
    Retry,
    ChooseFolder,
    Resolve,
    CopyLink,
    ChooseAnotherFile,
}

#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct CoreProblem {
    pub kind: CoreProblemKind,
    pub status: String,
    pub explanation: Option<String>,
    pub fix: CoreFix,
    pub raw_message: Option<String>,
    pub code: Option<i64>,
}

#[derive(Debug, Clone, PartialEq, uniffi::Enum)]
pub enum CorePhase {
    Downloading,
    Stalled,
    Resuming,
    FetchingMetadata { peers: u32 },
    Queued { position: u32 },
    Paused,
    AutoPaused { reason: CoreAutoPause },
    Scheduled { starts_at: i64 },
    Checking { progress: f64, seconds_left: Option<u32> },
    WaitingForDrive { volume_name: String },
    WaitingForNetwork,
    Error { problem: CoreProblem },
    Completed { at: i64 },
    Seeding { ratio: f64, target: Option<f64> },
}

#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct CoreTask {
    pub id: String,
    pub name: String,
    pub kind: CoreKind,
    pub phase: CorePhase,
    pub completed_bytes: i64,
    pub total_bytes: i64,
    pub download_speed: i64,
    pub upload_speed: i64,
    pub seeders: u32,
    pub peers: u32,
    pub directory: String,
    pub volume_name: String,
    pub volume_is_external: bool,
    pub primary_file: Option<String>,
    pub added_at: i64,
    pub completed_at: Option<i64>,
    pub speed_limit: Option<i64>,
    pub start_at: Option<i64>,
    pub info_hash: Option<String>,
    pub magnet_link: Option<String>,
    pub source_url: Option<String>,
    pub gid: Option<String>,
    pub piece_length: Option<i64>,
    pub piece_count: Option<u32>,
    pub pieces_done: Option<u32>,
    pub tracker_count: u32,
    pub created_by: Option<String>,
    pub comment: Option<String>,
    pub just_imported: bool,
}

#[derive(Debug, Clone, PartialEq, uniffi::Enum)]
pub enum CoreEngineState {
    Starting,
    Running { version: String },
    Stopped { reason: String },
}

#[derive(Debug, Clone, PartialEq, uniffi::Enum)]
pub enum CoreSchedule {
    AnyTime,
    Inside { ends_at: i64 },
    Outside { starts_at: i64 },
}

#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct CoreVolume {
    pub name: String,
    pub is_external: bool,
    pub is_connected: bool,
    pub free_bytes: Option<i64>,
}

#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct CoreSnapshot {
    pub tasks: Vec<CoreTask>,
    pub download_speed: i64,
    pub upload_speed: i64,
    pub slow_mode: bool,
    pub engine: CoreEngineState,
    pub schedule: CoreSchedule,
    pub default_volume: Option<CoreVolume>,
    pub auto_pause: Option<CoreAutoPause>,
}

#[derive(Debug, Clone, PartialEq, uniffi::Enum)]
pub enum CoreEvent {
    Completed { id: String, name: String, directory: String, volume_name: String },
    Stopped { id: String, name: String, reason: String },
    WaitingForDrive { volume_name: String },
    EngineStopped { reason: String },
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum CoreFileTag {
    Video,
    Sample,
    Image,
    Text,
    Other,
}

#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct CoreFile {
    pub index: u32,
    pub path: String,
    pub length: i64,
    pub completed_length: i64,
    pub selected: bool,
    pub tag: CoreFileTag,
}

#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct CorePeer {
    pub address: String,
    pub client: String,
    pub progress: f64,
    pub download_speed: i64,
    pub upload_speed: i64,
    pub is_seeder: bool,
}

#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct CorePieces {
    pub count: u32,
    pub bits: Vec<u8>,
}

#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct CoreSmart {
    pub skipped_count: u32,
    pub skipped_bytes: i64,
    pub skipped_description: String,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum CoreInputProblem {
    UnreadableTorrent,
    InvalidLink,
}

#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct CorePreview {
    pub kind: CoreKind,
    pub name: String,
    pub total_bytes: Option<i64>,
    pub files: Vec<CoreFile>,
    pub smart: Option<CoreSmart>,
    pub metadata_pending: bool,
    pub metadata_peers: u32,
    pub duplicate_of: Option<String>,
    pub existing_completed: Option<i64>,
    pub existing_fraction: Option<f64>,
    pub problem: Option<CoreInputProblem>,
    /// Lowercase hex v1 info hash, for torrents and magnets.
    pub info_hash: Option<String>,
}

#[derive(Debug, Clone, PartialEq, uniffi::Enum)]
pub enum CoreSource {
    TorrentFile { path: String },
    Link { link: String },
}

#[derive(Debug, Clone, PartialEq, uniffi::Enum)]
pub enum CoreStart {
    Now,
    At { time: i64 },
    Paused,
}

#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct CoreAddRequest {
    pub source: CoreSource,
    pub directory: String,
    pub selected_files: Option<Vec<u32>>,
    pub start: CoreStart,
}

#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct CoreImport {
    pub id: String,
    pub name: String,
    pub directory: String,
    pub volume_name: String,
    pub total_bytes: i64,
    pub completed_bytes: i64,
    pub torrent_file: Option<String>,
    pub progress_file: Option<String>,
    pub progress_saved_at: Option<i64>,
    pub data_file: Option<String>,
    pub pieces: Option<CorePieces>,
    pub files: Vec<CoreFile>,
    pub smart: Option<CoreSmart>,
    pub needs_check: bool,
    pub estimated_check_seconds: Option<u32>,
    pub already_in_library: bool,
}

#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct CoreImportRequest {
    pub id: String,
    pub directory: String,
    pub selected_files: Option<Vec<u32>>,
}

#[derive(Debug, Clone, PartialEq, uniffi::Enum)]
pub enum CoreSeed {
    Stop,
    Ratio { ratio: f64 },
    Minutes { minutes: u32 },
}

#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct CoreWindow {
    pub start_minute: u32,
    pub end_minute: u32,
    /// 1 = Sunday … 7 = Saturday.
    pub weekdays: Vec<u32>,
}

#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct CoreSettings {
    pub default_directory: String,
    pub only_main_video: bool,
    pub skip_extras: bool,
    pub download_hours_enabled: bool,
    pub download_hours: CoreWindow,
    pub slow_down_limit: i64,
    pub slow_up_limit: i64,
    pub slow_mode_scheduled: bool,
    pub slow_mode_hours: CoreWindow,
    pub pause_on_battery: bool,
    pub pause_on_expensive_network: bool,
    pub down_limit: Option<i64>,
    pub up_limit: Option<i64>,
    pub max_concurrent: u32,
    pub connections_per_server: u32,
    pub after_download: CoreSeed,
    pub max_peers: u32,
    pub listen_port: u16,
    pub dht: bool,
    pub pex: bool,
    pub lpd: bool,
    pub prefer_encryption: bool,
    pub extra_trackers: String,
    pub advanced_options: String,
}

#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct CoreEnvironment {
    pub on_battery: bool,
    pub network_available: bool,
    pub network_expensive: bool,
    pub boot_volume_name: String,
    pub utc_offset_seconds: i64,
    /// Bumped by the app whenever the Mac joins a different network or comes back from having
    /// none. aria2's peer discovery (DHT, UDP trackers) doesn't survive that, so the engine starts
    /// a fresh aria2 before BitTorrent needs it.
    pub network_generation: u64,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum CoreMove {
    Top,
    Bottom,
    Up,
    Down,
    Index { index: u32 },
}

#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct CoreConfig {
    pub aria2_path: String,
    pub support_dir: String,
    pub log_dir: String,
    pub app_pid: u32,
}

#[derive(Debug, Clone, PartialEq, uniffi::Error)]
pub enum CoreError {
    Failed { message: String },
}

impl std::fmt::Display for CoreError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            CoreError::Failed { message } => f.write_str(message),
        }
    }
}

impl std::error::Error for CoreError {}

impl CoreError {
    pub fn msg(m: impl Into<String>) -> Self {
        CoreError::Failed { message: m.into() }
    }
}

impl Default for CoreSettings {
    fn default() -> Self {
        CoreSettings {
            default_directory: format!("{}/Downloads", std::env::var("HOME").unwrap_or_default()),
            only_main_video: true,
            skip_extras: true,
            download_hours_enabled: false,
            download_hours: CoreWindow { start_minute: 60, end_minute: 480, weekdays: (1..=7).collect() },
            slow_down_limit: 2_000_000,
            slow_up_limit: 500_000,
            slow_mode_scheduled: false,
            slow_mode_hours: CoreWindow { start_minute: 18 * 60, end_minute: 23 * 60, weekdays: (1..=7).collect() },
            pause_on_battery: false,
            pause_on_expensive_network: false,
            down_limit: None,
            up_limit: None,
            max_concurrent: 3,
            connections_per_server: 16,
            after_download: CoreSeed::Stop,
            max_peers: 55,
            listen_port: 51413,
            dht: true,
            pex: true,
            lpd: true,
            prefer_encryption: false,
            extra_trackers: String::new(),
            advanced_options: String::new(),
        }
    }
}

impl Default for CoreEnvironment {
    fn default() -> Self {
        CoreEnvironment {
            on_battery: false,
            network_available: true,
            network_expensive: false,
            boot_volume_name: "Macintosh HD".into(),
            utc_offset_seconds: 0,
            network_generation: 0,
        }
    }
}
