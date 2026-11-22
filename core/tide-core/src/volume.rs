//! Volume facts for a path via statfs: which volume it's on, its format and free space. Used to
//! hold downloads while their drive is unplugged and to warn about FAT32 / low space.

use std::ffi::{CStr, CString};
use std::path::{Path, PathBuf};

#[derive(Debug, Clone, PartialEq)]
pub struct VolumeInfo {
    pub mount_point: String,
    pub fs_type: String, // "apfs", "exfat", "msdos", "hfs", …
    pub free_bytes: u64,
}

pub fn statfs(path: &Path) -> Option<VolumeInfo> {
    let c = CString::new(path.as_os_str().as_encoded_bytes()).ok()?;
    let mut s: libc::statfs = unsafe { std::mem::zeroed() };
    if unsafe { libc::statfs(c.as_ptr(), &mut s) } != 0 {
        return None;
    }
    let mount = unsafe { CStr::from_ptr(s.f_mntonname.as_ptr()) }.to_string_lossy().into_owned();
    let fs = unsafe { CStr::from_ptr(s.f_fstypename.as_ptr()) }.to_string_lossy().into_owned();
    Some(VolumeInfo { mount_point: mount, fs_type: fs, free_bytes: s.f_bavail as u64 * s.f_bsize as u64 })
}

/// The mount point a path is *supposed* to live on: "/Volumes/Media" for anything under it,
/// otherwise "/". Works even when the drive is unplugged (no statfs needed).
pub fn expected_mount(path: &Path) -> String {
    let s = path.to_string_lossy();
    if let Some(rest) = s.strip_prefix("/Volumes/") {
        let name = rest.split('/').next().unwrap_or("");
        if !name.is_empty() {
            return format!("/Volumes/{name}");
        }
    }
    "/".to_string()
}

pub fn is_external(path: &Path) -> bool {
    expected_mount(path) != "/"
}

/// Display name: the folder under /Volumes, or the boot volume's name.
pub fn display_name(path: &Path, boot_name: &str) -> String {
    let m = expected_mount(path);
    if m == "/" { boot_name.to_string() } else { m.trim_start_matches("/Volumes/").to_string() }
}

/// True when the path's expected volume is actually mounted right now (and isn't a stray folder
/// on the boot disk that happens to sit at /Volumes/<name>).
pub fn is_available(path: &Path) -> bool {
    let want = expected_mount(path);
    if want == "/" {
        return true;
    }
    match statfs(Path::new(&want)) {
        Some(v) => v.mount_point == want,
        None => false,
    }
}

/// Free space on the volume holding `path` (walking up to an existing ancestor).
pub fn free_bytes(path: &Path) -> Option<u64> {
    let mut p: PathBuf = path.to_path_buf();
    loop {
        if p.exists() {
            return statfs(&p).map(|v| v.free_bytes);
        }
        if !p.pop() {
            return None;
        }
    }
}

pub fn fs_type(path: &Path) -> Option<String> {
    let mut p: PathBuf = path.to_path_buf();
    loop {
        if p.exists() {
            return statfs(&p).map(|v| v.fs_type);
        }
        if !p.pop() {
            return None;
        }
    }
}

pub fn is_fat32(path: &Path) -> bool {
    fs_type(path).is_some_and(|t| t == "msdos")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn expected_mounts() {
        assert_eq!(expected_mount(Path::new("/Volumes/Media/Movies")), "/Volumes/Media");
        assert_eq!(expected_mount(Path::new("/Users/me/Downloads")), "/");
        assert_eq!(display_name(Path::new("/Volumes/Media/Movies"), "Macintosh HD"), "Media");
        assert_eq!(display_name(Path::new("/Users/me"), "Macintosh HD"), "Macintosh HD");
        assert!(!is_available(Path::new("/Volumes/DefinitelyNotMounted-xyz/a")));
        assert!(is_available(Path::new("/Users")));
    }

    #[test]
    fn statfs_home() {
        let v = statfs(Path::new("/")).unwrap();
        assert!(v.free_bytes > 0);
        assert!(!v.fs_type.is_empty());
    }
}
