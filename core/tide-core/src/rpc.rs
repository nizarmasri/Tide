//! aria2 JSON-RPC 2.0 over one WebSocket. A single IO thread owns the socket: it writes queued
//! requests and reads responses/notifications with a short read timeout, so callers on any
//! thread just block on their own reply channel.

use crossbeam_channel::{bounded, unbounded, Receiver, RecvTimeoutError, Sender};
use serde_json::{json, Value};
use std::collections::HashMap;
use std::net::TcpStream;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;
use tungstenite::stream::MaybeTlsStream;
use tungstenite::{Message, WebSocket};

#[derive(Debug, Clone, PartialEq)]
pub enum RpcError {
    /// aria2 answered with an error object.
    Aria2 { code: i64, message: String },
    Disconnected,
    Timeout,
    Protocol(String),
}

impl std::fmt::Display for RpcError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            RpcError::Aria2 { code, message } => write!(f, "aria2 error {code}: {message}"),
            RpcError::Disconnected => write!(f, "engine disconnected"),
            RpcError::Timeout => write!(f, "engine didn't answer in time"),
            RpcError::Protocol(m) => write!(f, "protocol: {m}"),
        }
    }
}

/// aria2 push notifications.
#[derive(Debug, Clone, PartialEq)]
pub struct Notification {
    pub method: String, // e.g. "aria2.onDownloadComplete"
    pub gid: String,
}

type Pending = Arc<Mutex<HashMap<u64, Sender<Result<Value, RpcError>>>>>;

pub struct Rpc {
    secret: String,
    out: Sender<String>,
    pending: Pending,
    next_id: AtomicU64,
    alive: Arc<AtomicBool>,
    pub notifications: Receiver<Notification>,
}

impl Rpc {
    pub fn connect(port: u16, secret: &str, timeout: Duration) -> Result<Rpc, RpcError> {
        let addr = format!("127.0.0.1:{port}");
        let stream = TcpStream::connect_timeout(&addr.parse().unwrap(), timeout).map_err(|_| RpcError::Disconnected)?;
        stream.set_nodelay(true).ok();
        let (mut ws, _) = tungstenite::client(format!("ws://{addr}/jsonrpc"), MaybeTlsStream::Plain(stream))
            .map_err(|e| RpcError::Protocol(e.to_string()))?;
        if let MaybeTlsStream::Plain(s) = ws.get_mut() {
            s.set_read_timeout(Some(Duration::from_millis(15))).ok();
        }
        let (out_tx, out_rx) = unbounded::<String>();
        let (note_tx, note_rx) = unbounded::<Notification>();
        let pending: Pending = Arc::new(Mutex::new(HashMap::new()));
        let alive = Arc::new(AtomicBool::new(true));
        {
            let pending = pending.clone();
            let alive = alive.clone();
            std::thread::Builder::new()
                .name("tide-rpc".into())
                .spawn(move || io_loop(ws, out_rx, note_tx, pending, alive))
                .map_err(|e| RpcError::Protocol(e.to_string()))?;
        }
        Ok(Rpc { secret: secret.to_string(), out: out_tx, pending, next_id: AtomicU64::new(1), alive, notifications: note_rx })
    }

    pub fn is_alive(&self) -> bool {
        self.alive.load(Ordering::Relaxed)
    }

    fn params(&self, params: Vec<Value>) -> Vec<Value> {
        let mut p = Vec::with_capacity(params.len() + 1);
        p.push(json!(format!("token:{}", self.secret)));
        p.extend(params);
        p
    }

    pub fn call_timeout(&self, method: &str, params: Vec<Value>, timeout: Duration) -> Result<Value, RpcError> {
        if !self.is_alive() {
            return Err(RpcError::Disconnected);
        }
        let id = self.next_id.fetch_add(1, Ordering::Relaxed);
        let (tx, rx) = bounded(1);
        self.pending.lock().unwrap().insert(id, tx);
        let msg = json!({"jsonrpc": "2.0", "id": id.to_string(), "method": method, "params": self.params(params)});
        if self.out.send(msg.to_string()).is_err() {
            self.pending.lock().unwrap().remove(&id);
            return Err(RpcError::Disconnected);
        }
        match rx.recv_timeout(timeout) {
            Ok(r) => r,
            Err(RecvTimeoutError::Timeout) => {
                self.pending.lock().unwrap().remove(&id);
                Err(RpcError::Timeout)
            }
            Err(RecvTimeoutError::Disconnected) => Err(RpcError::Disconnected),
        }
    }

    pub fn call(&self, method: &str, params: Vec<Value>) -> Result<Value, RpcError> {
        self.call_timeout(method, params, Duration::from_secs(10))
    }

    /// system.multicall: one round trip for several calls. Each result is Ok(value) or the
    /// per-call aria2 error.
    pub fn multicall(&self, calls: Vec<(&str, Vec<Value>)>) -> Result<Vec<Result<Value, RpcError>>, RpcError> {
        let list: Vec<Value> = calls
            .into_iter()
            .map(|(m, p)| json!({"methodName": m, "params": self.params(p)}))
            .collect();
        // multicall itself takes no token; each inner call carries one.
        if !self.is_alive() {
            return Err(RpcError::Disconnected);
        }
        let id = self.next_id.fetch_add(1, Ordering::Relaxed);
        let (tx, rx) = bounded(1);
        self.pending.lock().unwrap().insert(id, tx);
        let msg = json!({"jsonrpc": "2.0", "id": id.to_string(), "method": "system.multicall", "params": [list]});
        self.out.send(msg.to_string()).map_err(|_| RpcError::Disconnected)?;
        let v = match rx.recv_timeout(Duration::from_secs(10)) {
            Ok(r) => r?,
            Err(_) => {
                self.pending.lock().unwrap().remove(&id);
                return Err(RpcError::Timeout);
            }
        };
        let arr = v.as_array().ok_or_else(|| RpcError::Protocol("multicall result not an array".into()))?;
        Ok(arr
            .iter()
            .map(|item| {
                if let Some(a) = item.as_array() {
                    Ok(a.first().cloned().unwrap_or(Value::Null))
                } else {
                    Err(RpcError::Aria2 {
                        code: item.get("code").and_then(Value::as_i64).unwrap_or(1),
                        message: item.get("message").and_then(Value::as_str).unwrap_or("").to_string(),
                    })
                }
            })
            .collect())
    }
}

impl Drop for Rpc {
    fn drop(&mut self) {
        self.alive.store(false, Ordering::Relaxed);
    }
}

fn io_loop(
    mut ws: WebSocket<MaybeTlsStream<TcpStream>>,
    out: Receiver<String>,
    notes: Sender<Notification>,
    pending: Pending,
    alive: Arc<AtomicBool>,
) {
    let fail_all = |pending: &Pending| {
        for (_, tx) in pending.lock().unwrap().drain() {
            let _ = tx.send(Err(RpcError::Disconnected));
        }
    };
    loop {
        if !alive.load(Ordering::Relaxed) {
            let _ = ws.close(None);
            break;
        }
        // Write everything queued.
        let mut wrote = false;
        while let Ok(text) = out.try_recv() {
            if ws.write(Message::Text(text.into())).is_err() {
                alive.store(false, Ordering::Relaxed);
                break;
            }
            wrote = true;
        }
        if wrote && ws.flush().is_err() {
            alive.store(false, Ordering::Relaxed);
        }
        match ws.read() {
            Ok(Message::Text(t)) => dispatch(t.as_str(), &notes, &pending),
            Ok(Message::Close(_)) => {
                alive.store(false, Ordering::Relaxed);
            }
            Ok(_) => {}
            Err(tungstenite::Error::Io(e))
                if matches!(e.kind(), std::io::ErrorKind::WouldBlock | std::io::ErrorKind::TimedOut) => {}
            Err(_) => {
                alive.store(false, Ordering::Relaxed);
            }
        }
        if !alive.load(Ordering::Relaxed) {
            fail_all(&pending);
            break;
        }
    }
    fail_all(&pending);
}

fn dispatch(text: &str, notes: &Sender<Notification>, pending: &Pending) {
    let Ok(v) = serde_json::from_str::<Value>(text) else { return };
    if let Some(method) = v.get("method").and_then(Value::as_str) {
        if let Some(events) = v.get("params").and_then(Value::as_array) {
            for e in events {
                if let Some(gid) = e.get("gid").and_then(Value::as_str) {
                    let _ = notes.send(Notification { method: method.to_string(), gid: gid.to_string() });
                }
            }
        }
        return;
    }
    let Some(id) = v.get("id").and_then(|i| i.as_str().and_then(|s| s.parse::<u64>().ok()).or_else(|| i.as_u64())) else {
        return;
    };
    let Some(tx) = pending.lock().unwrap().remove(&id) else { return };
    let r = if let Some(err) = v.get("error") {
        Err(RpcError::Aria2 {
            code: err.get("code").and_then(Value::as_i64).unwrap_or(1),
            message: err.get("message").and_then(Value::as_str).unwrap_or("").to_string(),
        })
    } else {
        Ok(v.get("result").cloned().unwrap_or(Value::Null))
    };
    let _ = tx.send(r);
}
