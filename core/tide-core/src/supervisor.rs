//! Owns the bundled aria2c process: writes its private config (with a per-launch RPC secret, so
//! the secret never shows in `ps`), starts it, connects, and stops it gracefully.

use crate::rpc::{Rpc, RpcError};
use serde_json::{json, Value};
use std::io::Read;
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::time::{Duration, Instant};

#[derive(Debug, Clone)]
pub struct EngineOptions {
    pub max_concurrent: u32,
    pub connections_per_server: u32,
    pub max_peers: u32,
    pub listen_port: u16,
    pub dht: bool,
    pub pex: bool,
    pub lpd: bool,
    pub prefer_encryption: bool,
    pub down_limit: u64, // bytes/s, 0 = unlimited
    pub up_limit: u64,
    /// Extra raw "key=value" lines from Settings ▸ Engine ▸ Advanced.
    pub advanced: String,
}

impl Default for EngineOptions {
    fn default() -> Self {
        EngineOptions {
            max_concurrent: 3,
            connections_per_server: 16,
            max_peers: 55,
            listen_port: 51413,
            dht: true,
            pex: true,
            lpd: true,
            prefer_encryption: false,
            down_limit: 0,
            up_limit: 0,
            advanced: String::new(),
        }
    }
}

pub struct Aria2 {
    child: Child,
    pub rpc: Rpc,
    pub version: String,
    pub port: u16,
}

pub fn random_hex(n: usize) -> String {
    let mut b = vec![0u8; n];
    if let Ok(mut f) = std::fs::File::open("/dev/urandom") {
        let _ = f.read_exact(&mut b);
    }
    crate::torrent::hex(&b)
}

fn free_port() -> Option<u16> {
    std::net::TcpListener::bind("127.0.0.1:0").ok()?.local_addr().ok().map(|a| a.port())
}

/// Options Tide treats as its own; Advanced lines may not override these.
const RESERVED: &[&str] = &[
    "enable-rpc", "rpc-listen-port", "rpc-secret", "rpc-listen-all", "rpc-allow-origin-all", "input-file",
    "save-session", "stop-with-process", "daemon", "log", "dht-file-path", "dht-file-path6", "dir",
];

pub fn config_text(o: &EngineOptions, rpc_port: u16, secret: &str, support: &Path, log: &Path, app_pid: u32) -> String {
    let mut lines = vec![
        "# Written by Tide on every launch. Edit Settings ▸ Engine ▸ Advanced instead.".to_string(),
        "enable-rpc=true".into(),
        format!("rpc-listen-port={rpc_port}"),
        "rpc-listen-all=false".into(),
        format!("rpc-secret={secret}"),
        "rpc-max-request-size=16M".into(),
        "rpc-save-upload-metadata=false".into(),
        format!("stop-with-process={app_pid}"),
        format!("log={}", log.display()),
        "log-level=notice".into(),
        "console-log-level=error".into(),
        "summary-interval=0".into(),
        // Resume safety (power cuts, crashes): progress files every 10 s, never rehash on resume.
        "continue=true".into(),
        "check-integrity=false".into(),
        "auto-save-interval=10".into(),
        "save-session-interval=0".into(),
        "force-save=false".into(),
        "file-allocation=none".into(),
        "disk-cache=16M".into(),
        "auto-file-renaming=false".into(),
        "allow-overwrite=false".into(),
        "remote-time=false".into(),
        "content-disposition-default-utf8=true".into(),
        "max-file-not-found=5".into(),
        "max-tries=0".into(),
        "retry-wait=10".into(),
        "connect-timeout=30".into(),
        "timeout=60".into(),
        "lowest-speed-limit=0".into(),
        // HTTP: the classic -x16 -s16.
        format!("max-connection-per-server={}", o.connections_per_server.clamp(1, 16)),
        "split=16".into(),
        "min-split-size=4M".into(),
        format!("max-concurrent-downloads={}", o.max_concurrent.max(1)),
        format!("max-overall-download-limit={}", o.down_limit),
        format!("max-overall-upload-limit={}", o.up_limit),
        // BitTorrent.
        "seed-time=0".into(),
        "bt-save-metadata=true".into(),
        "bt-metadata-only=false".into(),
        "pause-metadata=true".into(),
        "bt-hash-check-seed=true".into(),
        "bt-seed-unverified=false".into(),
        "bt-remove-unselected-file=false".into(),
        "follow-torrent=true".into(),
        format!("bt-max-peers={}", o.max_peers),
        format!("listen-port={}", valid_port(o.listen_port)),
        format!("dht-listen-port={}", valid_port(o.listen_port)),
        format!("enable-dht={}", o.dht),
        format!("enable-dht6={}", o.dht),
        format!("enable-peer-exchange={}", o.pex),
        format!("bt-enable-lpd={}", o.lpd),
        format!("bt-require-crypto={}", o.prefer_encryption),
        format!("bt-min-crypto-level={}", if o.prefer_encryption { "arc4" } else { "plain" }),
        format!("dht-file-path={}", support.join("dht.dat").display()),
        format!("dht-file-path6={}", support.join("dht6.dat").display()),
        "dht-entry-point=dht.transmissionbt.com:6881".into(),
        "bt-tracker-connect-timeout=10".into(),
        "bt-tracker-timeout=10".into(),
        "user-agent=Tide/1.0".into(),
        "peer-agent=Tide/1.0".into(),
        "async-dns=true".into(),
    ];
    for raw in o.advanced.lines() {
        let l = raw.trim();
        if l.is_empty() || l.starts_with('#') { continue; }
        let key = l.split('=').next().unwrap_or("").trim().trim_start_matches("--");
        if key.is_empty() || RESERVED.contains(&key) || !l.contains('=') { continue; }
        lines.push(l.trim_start_matches("--").to_string());
    }
    lines.join("\n") + "\n"
}

/// aria2 only accepts listening ports 1024–65535.
fn valid_port(p: u16) -> u16 {
    if p >= 1024 { p } else { 51413 }
}

impl Aria2 {
    pub fn start(binary: &Path, support: &Path, log_dir: &Path, opts: &EngineOptions, app_pid: u32) -> Result<Aria2, String> {
        std::fs::create_dir_all(support).map_err(|e| e.to_string())?;
        std::fs::create_dir_all(log_dir).map_err(|e| e.to_string())?;
        let port = free_port().ok_or("no free port")?;
        let secret = random_hex(16);
        let conf = support.join("aria2.conf");
        let log = log_dir.join("aria2.log");
        rotate_log(&log);
        std::fs::write(&conf, config_text(opts, port, &secret, support, &log, app_pid)).map_err(|e| e.to_string())?;
        std::fs::set_permissions(&conf, std::fs::Permissions::from_mode(0o600)).ok();

        let child = Command::new(binary)
            .arg(format!("--conf-path={}", conf.display()))
            .current_dir(support)
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .spawn()
            .map_err(|e| format!("couldn't start aria2c at {}: {e}", binary.display()))?;
        let mut a2 = Aria2Child { child: Some(child) };

        let deadline = Instant::now() + Duration::from_secs(8);
        let rpc = loop {
            if let Some(status) = a2.child.as_mut().and_then(|c| c.try_wait().ok().flatten()) {
                return Err(format!("aria2c exited during startup ({status}); see {}", log.display()));
            }
            match Rpc::connect(port, &secret, Duration::from_millis(300)) {
                Ok(r) => break r,
                Err(_) if Instant::now() < deadline => std::thread::sleep(Duration::from_millis(40)),
                Err(e) => return Err(format!("aria2c RPC didn't come up: {e}")),
            }
        };
        let version = rpc
            .call_timeout("aria2.getVersion", vec![], Duration::from_secs(3))
            .ok()
            .and_then(|v| v.get("version").and_then(Value::as_str).map(str::to_string))
            .unwrap_or_else(|| "?".into());
        Ok(Aria2 { child: a2.child.take().unwrap(), rpc, version, port })
    }

    pub fn is_running(&mut self) -> bool {
        matches!(self.child.try_wait(), Ok(None)) && self.rpc.is_alive()
    }

    pub fn pid(&self) -> u32 {
        self.child.id()
    }

    /// Graceful stop: aria2 writes every control file on shutdown. Falls back to SIGTERM/SIGKILL.
    pub fn stop(mut self) {
        let _ = self.rpc.call_timeout("aria2.forceShutdown", vec![], Duration::from_secs(2));
        let deadline = Instant::now() + Duration::from_secs(4);
        while Instant::now() < deadline {
            if matches!(self.child.try_wait(), Ok(Some(_))) {
                return;
            }
            std::thread::sleep(Duration::from_millis(50));
        }
        unsafe { libc::kill(self.child.id() as i32, libc::SIGTERM) };
        let deadline = Instant::now() + Duration::from_secs(2);
        while Instant::now() < deadline {
            if matches!(self.child.try_wait(), Ok(Some(_))) {
                return;
            }
            std::thread::sleep(Duration::from_millis(50));
        }
        let _ = self.child.kill();
        let _ = self.child.wait();
    }

    pub fn call(&self, method: &str, params: Vec<Value>) -> Result<Value, RpcError> {
        self.rpc.call(method, params)
    }

    pub fn change_global(&self, opts: Value) -> Result<Value, RpcError> {
        self.rpc.call("aria2.changeGlobalOption", vec![opts])
    }
}

/// Kills the child if startup fails half-way.
struct Aria2Child {
    child: Option<Child>,
}

impl Drop for Aria2Child {
    fn drop(&mut self) {
        if let Some(mut c) = self.child.take() {
            let _ = c.kill();
            let _ = c.wait();
        }
    }
}

fn rotate_log(log: &Path) {
    if std::fs::metadata(log).map(|m| m.len() > 8 * 1024 * 1024).unwrap_or(false) {
        let _ = std::fs::rename(log, log.with_extension("log.1"));
    }
}

pub fn global_limits(down: u64, up: u64) -> Value {
    json!({"max-overall-download-limit": down.to_string(), "max-overall-upload-limit": up.to_string()})
}

pub fn default_binary() -> PathBuf {
    // Next to the app's executable: Tide.app/Contents/Helpers/aria2c.
    if let Ok(exe) = std::env::current_exe() {
        if let Some(contents) = exe.parent().and_then(Path::parent) {
            let p = contents.join("Helpers/aria2c");
            if p.exists() {
                return p;
            }
        }
    }
    PathBuf::from("/opt/homebrew/bin/aria2c")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn config_has_secret_and_filters_reserved_advanced() {
        let mut o = EngineOptions::default();
        o.advanced = "rpc-secret=hack\n--max-tries=3\n# comment\nbogus\nbt-tracker-timeout=5".into();
        let c = config_text(&o, 1234, "s3cr3t", Path::new("/tmp/s"), Path::new("/tmp/l.log"), 42);
        assert!(c.contains("rpc-secret=s3cr3t"));
        assert!(!c.contains("rpc-secret=hack"));
        assert!(c.contains("\nmax-tries=3\n"));
        assert!(!c.contains("bogus"));
        assert!(c.contains("stop-with-process=42"));
        assert!(c.contains("seed-time=0"));
        assert!(c.contains("auto-save-interval=10"));
    }
}
