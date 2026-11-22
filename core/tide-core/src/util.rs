//! Small helpers: base64, logging.

use std::io::Write;
use std::path::PathBuf;
use std::sync::Mutex;

pub fn base64(data: &[u8]) -> String {
    const T: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    let mut out = String::with_capacity(data.len().div_ceil(3) * 4);
    for chunk in data.chunks(3) {
        let b = [chunk[0], *chunk.get(1).unwrap_or(&0), *chunk.get(2).unwrap_or(&0)];
        let n = (b[0] as u32) << 16 | (b[1] as u32) << 8 | b[2] as u32;
        out.push(T[(n >> 18) as usize & 63] as char);
        out.push(T[(n >> 12) as usize & 63] as char);
        out.push(if chunk.len() > 1 { T[(n >> 6) as usize & 63] as char } else { '=' });
        out.push(if chunk.len() > 2 { T[n as usize & 63] as char } else { '=' });
    }
    out
}

static LOG: Mutex<Option<PathBuf>> = Mutex::new(None);

pub fn set_log_file(p: PathBuf) {
    if let Some(dir) = p.parent() {
        let _ = std::fs::create_dir_all(dir);
    }
    if std::fs::metadata(&p).map(|m| m.len() > 4 * 1024 * 1024).unwrap_or(false) {
        let _ = std::fs::rename(&p, p.with_extension("log.1"));
    }
    *LOG.lock().unwrap() = Some(p);
}

pub fn log(msg: &str) {
    let ts = crate::journal::now();
    let line = format!("{ts} {msg}\n");
    if let Some(p) = LOG.lock().unwrap().as_ref() {
        if let Ok(mut f) = std::fs::OpenOptions::new().create(true).append(true).open(p) {
            let _ = f.write_all(line.as_bytes());
        }
    } else if cfg!(test) {
        eprint!("{line}");
    }
}

#[macro_export]
macro_rules! tlog {
    ($($arg:tt)*) => { $crate::util::log(&format!($($arg)*)) };
}

#[cfg(test)]
mod tests {
    #[test]
    fn b64() {
        assert_eq!(super::base64(b""), "");
        assert_eq!(super::base64(b"f"), "Zg==");
        assert_eq!(super::base64(b"fo"), "Zm8=");
        assert_eq!(super::base64(b"foo"), "Zm9v");
        assert_eq!(super::base64(b"foobar"), "Zm9vYmFy");
    }
}
