//! Plain-language copy for aria2 failures (DESIGN.md §7: lead with the consequence, name the
//! drive/folder, ≤ 45 characters, one fix).

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ProblemKind {
    DiskFull,
    CantWrite,
    FileExists,
    NotFound,
    NeedsLogin,
    Fat32,
    BadTorrent,
    Unknown,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Fix {
    Retry,
    ChooseFolder,
    Resolve,
    CopyLink,
    ChooseAnotherFile,
}

#[derive(Debug, Clone, PartialEq)]
pub struct Problem {
    pub kind: ProblemKind,
    pub status: String,
    pub explanation: Option<String>,
    pub fix: Fix,
    pub raw: String,
    pub code: i64,
}

pub struct Context<'a> {
    pub volume: &'a str,
    pub folder: &'a str,
    pub remaining_bytes: u64,
    pub free_bytes: Option<u64>,
    pub fat32: bool,
    pub largest_file: u64,
}

pub fn fmt_bytes(b: u64) -> String {
    // Decimal units like Finder, 3 significant digits.
    let units = ["bytes", "KB", "MB", "GB", "TB", "PB"];
    if b < 1000 {
        return format!("{b} bytes");
    }
    let mut v = b as f64;
    let mut u = 0;
    while v >= 1000.0 && u < units.len() - 1 {
        v /= 1000.0;
        u += 1;
    }
    let s = if v >= 100.0 { format!("{v:.0}") } else if v >= 10.0 { format!("{v:.1}") } else { format!("{v:.2}") };
    format!("{s} {}", units[u])
}

pub fn from_aria2(code: i64, raw: &str, cx: &Context) -> Problem {
    let p = |kind, status: String, explanation: Option<String>, fix| Problem {
        kind, status, explanation, fix, raw: raw.to_string(), code,
    };
    match code {
        9 => {
            let need = cx.remaining_bytes.saturating_sub(cx.free_bytes.unwrap_or(0));
            p(ProblemKind::DiskFull, format!("Not enough space on {}", cx.volume),
              Some(format!("{} needs {} more. Free up space, then try again.", cx.volume, fmt_bytes(need.max(1)))),
              Fix::Retry)
        }
        13 => p(ProblemKind::FileExists, truncate(format!("A file with this name is already in {}", cx.folder)), None, Fix::Resolve),
        14..=18 if cx.fat32 && cx.largest_file > 4_294_967_295 => p(
            ProblemKind::Fat32, truncate(format!("{} can't store files over 4 GB", cx.volume)),
            Some(format!("{} is formatted as FAT32. Choose a folder on another drive.", cx.volume)), Fix::ChooseFolder),
        14..=18 => p(ProblemKind::CantWrite, truncate(format!("Can't save to {}", cx.folder)),
                     Some("Tide doesn't have permission to write to this folder.".into()), Fix::ChooseFolder),
        3 | 4 => p(ProblemKind::NotFound, "The server doesn't have this file anymore".into(), None, Fix::CopyLink),
        24 => p(ProblemKind::NeedsLogin, "This link needs a login".into(), None, Fix::CopyLink),
        25..=27 => p(ProblemKind::BadTorrent, "This torrent file can't be read".into(), None, Fix::ChooseAnotherFile),
        _ => p(ProblemKind::Unknown, "Something went wrong with this download".into(), None, Fix::Retry),
    }
}

fn truncate(s: String) -> String {
    if s.chars().count() <= 45 { s } else { s.chars().take(44).collect::<String>() + "…" }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn cx() -> Context<'static> {
        Context { volume: "Media", folder: "Movies", remaining_bytes: 75_900_000_000, free_bytes: Some(31_000_000_000), fat32: false, largest_file: 75_900_000_000 }
    }

    #[test]
    fn disk_full_copy() {
        let p = from_aria2(9, "No space left on device", &cx());
        assert_eq!(p.status, "Not enough space on Media");
        assert_eq!(p.explanation.as_deref(), Some("Media needs 44.9 GB more. Free up space, then try again."));
        assert_eq!(p.fix, Fix::Retry);
    }

    #[test]
    fn fat32_and_lengths() {
        let mut c = cx();
        c.fat32 = true;
        assert_eq!(from_aria2(16, "", &c).kind, ProblemKind::Fat32);
        for code in [1, 3, 9, 13, 16, 24, 25, 99] {
            assert!(from_aria2(code, "", &cx()).status.chars().count() <= 45);
        }
    }

    #[test]
    fn bytes() {
        assert_eq!(fmt_bytes(68_200_000_000), "68.2 GB");
        assert_eq!(fmt_bytes(412_000_000_000), "412 GB");
        assert_eq!(fmt_bytes(1_210_000_000_000), "1.21 TB");
        assert_eq!(fmt_bytes(512), "512 bytes");
    }
}
