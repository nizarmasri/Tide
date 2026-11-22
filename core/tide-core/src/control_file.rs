//! aria2's `.aria2` control file (version 1, big-endian). This is aria2's resume data: with it,
//! aria2 continues instantly without hashing. Tide reads it for import/progress and rewrites the
//! bitfield after its own verification.
//!
//! Layout (aria2 DefaultBtProgressInfoFile):
//!   u16 version (1) | u32 extension (bit 0 = "infohash checking") | u32 infoHashLength |
//!   infoHash | u32 pieceLength | u64 totalLength | u64 uploadLength | u32 bitfieldLength |
//!   bitfield | u32 numInFlightPiece | { u32 index | u32 length | u32 bitfieldLength | bitfield }*

use std::io::{self, Write};
use std::path::Path;

#[derive(Debug, Clone, PartialEq)]
pub struct InFlightPiece {
    pub index: u32,
    pub length: u32,
    pub bitfield: Vec<u8>,
}

#[derive(Debug, Clone, PartialEq)]
pub struct ControlFile {
    pub version: u16,
    pub extension: u32,
    pub info_hash: Vec<u8>, // empty for HTTP/FTP
    pub piece_length: u32,
    pub total_length: u64,
    pub upload_length: u64,
    pub bitfield: Vec<u8>,
    pub in_flight: Vec<InFlightPiece>,
}

impl ControlFile {
    pub fn piece_count(&self) -> u32 {
        if self.piece_length == 0 { return 0; }
        self.total_length.div_ceil(self.piece_length as u64) as u32
    }

    pub fn has(&self, i: u32) -> bool {
        let byte = (i / 8) as usize;
        byte < self.bitfield.len() && self.bitfield[byte] & (0x80 >> (i % 8)) != 0
    }

    pub fn set(&mut self, i: u32, on: bool) {
        let byte = (i / 8) as usize;
        if byte >= self.bitfield.len() { return; }
        let mask = 0x80u8 >> (i % 8);
        if on { self.bitfield[byte] |= mask } else { self.bitfield[byte] &= !mask }
    }

    pub fn done_count(&self) -> u32 {
        let n = self.piece_count();
        (0..n).filter(|&i| self.has(i)).count() as u32
    }

    pub fn info_hash_hex(&self) -> Option<String> {
        (!self.info_hash.is_empty()).then(|| crate::torrent::hex(&self.info_hash))
    }

    /// A fresh control file for a torrent with the given verified bitfield.
    pub fn new_bt(info_hash: &[u8], piece_length: u32, total_length: u64, bitfield: Vec<u8>) -> Self {
        ControlFile {
            version: 1,
            extension: 0,
            info_hash: info_hash.to_vec(),
            piece_length,
            total_length,
            upload_length: 0,
            bitfield,
            in_flight: Vec::new(),
        }
    }

    pub fn parse(b: &[u8]) -> Result<Self, String> {
        let mut r = Reader { b, pos: 0 };
        let version = r.u16()?;
        if version != 1 {
            return Err(format!("unsupported control file version {version}"));
        }
        let extension = r.u32()?;
        let ih_len = r.u32()? as usize;
        if ih_len > 64 { return Err("bad info hash length".into()); }
        let info_hash = r.bytes(ih_len)?.to_vec();
        let piece_length = r.u32()?;
        let total_length = r.u64()?;
        let upload_length = r.u64()?;
        let bf_len = r.u32()? as usize;
        let expected = if piece_length == 0 { 0 } else { total_length.div_ceil(piece_length as u64).div_ceil(8) as usize };
        if bf_len != expected {
            return Err(format!("bitfield length {bf_len} doesn't match {expected}"));
        }
        let bitfield = r.bytes(bf_len)?.to_vec();
        let mut in_flight = Vec::new();
        if r.remaining() >= 4 {
            let n = r.u32()?;
            for _ in 0..n.min(100_000) {
                let index = r.u32()?;
                let length = r.u32()?;
                let l = r.u32()? as usize;
                let bitfield = r.bytes(l)?.to_vec();
                in_flight.push(InFlightPiece { index, length, bitfield });
            }
        }
        Ok(ControlFile { version, extension, info_hash, piece_length, total_length, upload_length, bitfield, in_flight })
    }

    pub fn read(path: &Path) -> Result<Self, String> {
        let b = std::fs::read(path).map_err(|e| e.to_string())?;
        Self::parse(&b)
    }

    pub fn to_bytes(&self) -> Vec<u8> {
        let mut o = Vec::with_capacity(64 + self.bitfield.len());
        o.extend_from_slice(&self.version.to_be_bytes());
        o.extend_from_slice(&self.extension.to_be_bytes());
        o.extend_from_slice(&(self.info_hash.len() as u32).to_be_bytes());
        o.extend_from_slice(&self.info_hash);
        o.extend_from_slice(&self.piece_length.to_be_bytes());
        o.extend_from_slice(&self.total_length.to_be_bytes());
        o.extend_from_slice(&self.upload_length.to_be_bytes());
        o.extend_from_slice(&(self.bitfield.len() as u32).to_be_bytes());
        o.extend_from_slice(&self.bitfield);
        o.extend_from_slice(&(self.in_flight.len() as u32).to_be_bytes());
        for p in &self.in_flight {
            o.extend_from_slice(&p.index.to_be_bytes());
            o.extend_from_slice(&p.length.to_be_bytes());
            o.extend_from_slice(&(p.bitfield.len() as u32).to_be_bytes());
            o.extend_from_slice(&p.bitfield);
        }
        o
    }

    /// Atomic write (temp file + rename) next to the target.
    pub fn write(&self, path: &Path) -> io::Result<()> {
        let tmp = path.with_extension("aria2.tide-tmp");
        {
            let mut f = std::fs::File::create(&tmp)?;
            f.write_all(&self.to_bytes())?;
            f.sync_all()?;
        }
        std::fs::rename(&tmp, path)
    }
}

struct Reader<'a> {
    b: &'a [u8],
    pos: usize,
}

impl<'a> Reader<'a> {
    fn remaining(&self) -> usize { self.b.len() - self.pos }
    fn bytes(&mut self, n: usize) -> Result<&'a [u8], String> {
        if self.pos + n > self.b.len() { return Err("truncated control file".into()); }
        let s = &self.b[self.pos..self.pos + n];
        self.pos += n;
        Ok(s)
    }
    fn u16(&mut self) -> Result<u16, String> { Ok(u16::from_be_bytes(self.bytes(2)?.try_into().unwrap())) }
    fn u32(&mut self) -> Result<u32, String> { Ok(u32::from_be_bytes(self.bytes(4)?.try_into().unwrap())) }
    fn u64(&mut self) -> Result<u64, String> { Ok(u64::from_be_bytes(self.bytes(8)?.try_into().unwrap())) }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn round_trip_synthetic() {
        let mut c = ControlFile::new_bt(&[7u8; 20], 4096, 10_000, vec![0; 1]);
        c.set(0, true);
        c.set(2, true);
        c.in_flight.push(InFlightPiece { index: 1, length: 4096, bitfield: vec![0b1010_0000] });
        let b = c.to_bytes();
        let p = ControlFile::parse(&b).unwrap();
        assert_eq!(p, c);
        assert_eq!(p.done_count(), 2);
        assert!(p.has(2) && !p.has(1));
    }

    #[test]
    fn rejects_bad() {
        assert!(ControlFile::parse(&[0, 2, 0, 0]).is_err());
        assert!(ControlFile::parse(&[0, 1]).is_err());
    }

    /// Optional check against a real download: with TIDE_REAL_TORRENT set, its `<name>.aria2`
    /// next to it must parse and rewrite byte for byte. Skipped otherwise.
    #[test]
    fn real_control_file_from_env() {
        let Ok(tp) = std::env::var("TIDE_REAL_TORRENT") else { return };
        let t = crate::torrent::parse(&std::fs::read(&tp).unwrap()).unwrap();
        let path = Path::new(&tp).parent().unwrap().join(format!("{}.aria2", t.name));
        let Ok(raw) = std::fs::read(&path) else { return };
        let c = ControlFile::parse(&raw).unwrap();
        assert_eq!(c.info_hash_hex().as_deref(), Some(t.info_hash.as_str()));
        assert_eq!(c.piece_count(), t.piece_count());
        assert_eq!(c.to_bytes(), raw, "rewrite must be byte-identical");
    }
}
