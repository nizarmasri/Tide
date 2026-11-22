//! "Take the movie, leave the junk." Default file selection for torrents (DESIGN.md §6).

use crate::torrent::TorrentFile;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Tag {
    Video,
    Sample,
    Image,
    Text,
    Other,
}

const VIDEO: &[&str] = &["mkv", "mp4", "m2ts", "ts", "mov", "avi", "m4v", "webm", "wmv", "mpg", "mpeg"];
const IMAGE: &[&str] = &["jpg", "jpeg", "png", "gif", "bmp", "webp", "tif", "tiff"];
const TEXT: &[&str] = &["txt", "nfo", "url", "md", "rtf", "html", "htm", "sfv", "md5"];
const JUNK_OTHER: &[&str] = &["exe", "bat", "cmd", "lnk", "scr", "com"];
const SUBTITLE: &[&str] = &["srt", "ass", "ssa", "sub", "idx", "vtt", "sup"];

fn ext(path: &str) -> String {
    path.rsplit('/').next().unwrap_or("").rsplit_once('.').map(|(_, e)| e.to_ascii_lowercase()).unwrap_or_default()
}

pub fn is_sample(path: &str) -> bool {
    path.split('/').any(|c| {
        let l = c.to_ascii_lowercase();
        l == "sample" || l == "samples" || l.starts_with("sample.") || l.contains(".sample.") || l.contains("-sample.")
            || l.ends_with("-sample") || l.ends_with(".sample") || l.contains("_sample.")
    })
}

pub fn classify(f: &TorrentFile) -> Tag {
    let e = ext(&f.path);
    if is_sample(&f.path) {
        return Tag::Sample;
    }
    if VIDEO.contains(&e.as_str()) { Tag::Video }
    else if IMAGE.contains(&e.as_str()) { Tag::Image }
    else if TEXT.contains(&e.as_str()) { Tag::Text }
    else { Tag::Other }
}

fn is_junk(f: &TorrentFile) -> bool {
    f.is_padding
        || matches!(classify(f), Tag::Sample | Tag::Image | Tag::Text)
        || JUNK_OTHER.contains(&ext(&f.path).as_str())
}

#[derive(Debug, Clone, PartialEq)]
pub struct Selection {
    pub selected: Vec<u32>,
    pub skipped_count: u32,
    pub skipped_bytes: u64,
    /// "sample, 2 images, 1 text file"
    pub skipped_description: String,
}

/// Applies the rules:
/// 1. one video ≥ 50% of the total → only that video (+ subtitles next to it);
/// 2. otherwise all videos ≥ 100 MB (+ their subtitles);
/// 3. never samples / .nfo / .txt / images / .url / .exe / padding;
/// 4. no video at all → everything that isn't junk (or everything, if all is "junk").
pub fn select(files: &[TorrentFile], only_main_video: bool, skip_extras: bool) -> Selection {
    let total: u64 = files.iter().map(|f| f.length).sum();
    let videos: Vec<&TorrentFile> = files.iter().filter(|f| classify(f) == Tag::Video && !f.is_padding).collect();

    let mut selected: Vec<u32> = if !only_main_video && !skip_extras {
        files.iter().filter(|f| !f.is_padding).map(|f| f.index).collect()
    } else if !only_main_video {
        files.iter().filter(|f| !is_junk(f)).map(|f| f.index).collect()
    } else if let Some(main) = videos.iter().max_by_key(|f| f.length).filter(|m| total > 0 && m.length * 2 >= total) {
        let mut v = vec![main.index];
        v.extend(subtitles_for(files, &[main]));
        v
    } else if !videos.is_empty() {
        let big: Vec<&TorrentFile> = videos.iter().copied().filter(|f| f.length >= 100_000_000).collect();
        let chosen = if big.is_empty() { videos.clone() } else { big };
        let mut v: Vec<u32> = chosen.iter().map(|f| f.index).collect();
        v.extend(subtitles_for(files, &chosen));
        v
    } else {
        let keep: Vec<u32> = files.iter().filter(|f| !is_junk(f)).map(|f| f.index).collect();
        if keep.is_empty() { files.iter().filter(|f| !f.is_padding).map(|f| f.index).collect() } else { keep }
    };
    selected.sort_unstable();
    selected.dedup();
    if selected.is_empty() {
        selected = files.iter().map(|f| f.index).collect();
    }

    let skipped: Vec<&TorrentFile> = files.iter().filter(|f| !selected.contains(&f.index) && !f.is_padding).collect();
    Selection {
        selected,
        skipped_count: skipped.len() as u32,
        skipped_bytes: skipped.iter().map(|f| f.length).sum(),
        skipped_description: describe(&skipped),
    }
}

/// Subtitles in the same folder as a chosen video whose name starts with the video's stem.
fn subtitles_for(files: &[TorrentFile], videos: &[&TorrentFile]) -> Vec<u32> {
    files
        .iter()
        .filter(|f| SUBTITLE.contains(&ext(&f.path).as_str()))
        .filter(|s| {
            videos.iter().any(|v| {
                let (vdir, vname) = v.path.rsplit_once('/').unwrap_or(("", &v.path));
                let stem = vname.rsplit_once('.').map(|(s, _)| s).unwrap_or(vname);
                let (sdir, sname) = s.path.rsplit_once('/').unwrap_or(("", &s.path));
                (sdir == vdir || sdir.starts_with(&format!("{vdir}/"))) && sname.starts_with(stem)
            })
        })
        .map(|f| f.index)
        .collect()
}

fn plural(n: usize, one: &str, many: &str) -> String {
    if n == 1 { format!("1 {one}") } else { format!("{n} {many}") }
}

pub fn describe(skipped: &[&TorrentFile]) -> String {
    let mut samples = 0;
    let mut images = 0;
    let mut texts = 0;
    let mut videos = 0;
    let mut others = 0;
    for f in skipped {
        match classify(f) {
            Tag::Sample => samples += 1,
            Tag::Image => images += 1,
            Tag::Text => texts += 1,
            Tag::Video => videos += 1,
            Tag::Other => others += 1,
        }
    }
    let mut parts = Vec::new();
    if samples == 1 { parts.push("sample".to_string()) } else if samples > 1 { parts.push(format!("{samples} samples")) }
    if videos > 0 { parts.push(plural(videos, "other video", "other videos")) }
    if images > 0 { parts.push(plural(images, "image", "images")) }
    if texts > 0 { parts.push(plural(texts, "text file", "text files")) }
    if others > 0 { parts.push(plural(others, "other file", "other files")) }
    parts.join(", ")
}

#[cfg(test)]
mod tests {
    use super::*;

    fn f(index: u32, path: &str, length: u64) -> TorrentFile {
        TorrentFile { index, path: path.into(), length, offset: 0, is_padding: false }
    }

    #[test]
    fn single_movie_selects_only_the_mkv() {
        let files = vec![
            f(1, "Big.Buck.Bunny.2008/Big.Buck.Bunny.2008.2160p.mkv", 72_814_480_399),
            f(2, "Big.Buck.Bunny.2008/Downloaded from example.org.txt", 38),
            f(3, "Big.Buck.Bunny.2008/release.txt", 64),
            f(4, "Big.Buck.Bunny.2008/info.txt", 418),
            f(5, "Big.Buck.Bunny.2008/poster.png", 143_111),
        ];
        let s = select(&files, true, true);
        assert_eq!(s.selected, vec![1]);
        assert_eq!(s.skipped_count, 4);
        assert_eq!(s.skipped_description, "1 image, 3 text files");
    }

    #[test]
    fn episodes_take_all_big_videos_and_their_subs() {
        let files = vec![
            f(1, "Show/S01E01.mkv", 3_000_000_000),
            f(2, "Show/S01E01.en.srt", 50_000),
            f(3, "Show/S01E02.mkv", 3_000_000_000),
            f(4, "Show/Sample/S01E01.sample.mkv", 60_000_000),
            f(5, "Show/S01E03.mkv", 3_100_000_000),
            f(6, "Show/extras.nfo", 2_000),
        ];
        let s = select(&files, true, true);
        assert_eq!(s.selected, vec![1, 2, 3, 5]);
        assert_eq!(s.skipped_description, "sample, 1 text file");
    }

    #[test]
    fn non_video_takes_everything_useful() {
        let files = vec![f(1, "Album/01.flac", 30_000_000), f(2, "Album/cover.jpg", 500_000), f(3, "Album/info.txt", 100)];
        let s = select(&files, true, true);
        assert_eq!(s.selected, vec![1]);
    }

    #[test]
    fn everything_when_rules_off() {
        let files = vec![f(1, "a.mkv", 10), f(2, "b.txt", 1)];
        assert_eq!(select(&files, false, false).selected, vec![1, 2]);
    }
}
