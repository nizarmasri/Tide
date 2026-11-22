//! Minimal bencode decoder that keeps the raw byte span of every value, so the torrent's info
//! hash can be computed over the exact bytes of the `info` dictionary.

use std::collections::BTreeMap;

#[derive(Debug, Clone, PartialEq)]
pub enum Value {
    Int(i64),
    Bytes(Vec<u8>),
    List(Vec<Value>),
    Dict(BTreeMap<Vec<u8>, Value>),
}

#[derive(Debug, Clone, PartialEq)]
pub struct DecodeError(pub String);

impl std::fmt::Display for DecodeError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "bencode: {}", self.0)
    }
}

impl Value {
    pub fn as_int(&self) -> Option<i64> {
        if let Value::Int(i) = self { Some(*i) } else { None }
    }
    pub fn as_bytes(&self) -> Option<&[u8]> {
        if let Value::Bytes(b) = self { Some(b) } else { None }
    }
    pub fn as_str(&self) -> Option<String> {
        self.as_bytes().map(|b| String::from_utf8_lossy(b).into_owned())
    }
    pub fn as_list(&self) -> Option<&[Value]> {
        if let Value::List(l) = self { Some(l) } else { None }
    }
    pub fn as_dict(&self) -> Option<&BTreeMap<Vec<u8>, Value>> {
        if let Value::Dict(d) = self { Some(d) } else { None }
    }
    pub fn get(&self, key: &str) -> Option<&Value> {
        self.as_dict().and_then(|d| d.get(key.as_bytes()))
    }
}

/// Decodes `data` and returns the value plus the byte range of the top-level dict key `span_key`
/// (e.g. "info") if present.
pub fn decode_with_span(data: &[u8], span_key: &[u8]) -> Result<(Value, Option<(usize, usize)>), DecodeError> {
    let mut p = Parser { data, pos: 0, depth: 0, span_key, span: None };
    let v = p.value(0)?;
    if p.pos != data.len() {
        // Trailing garbage is tolerated by most clients; keep going but don't fail.
    }
    Ok((v, p.span))
}

pub fn decode(data: &[u8]) -> Result<Value, DecodeError> {
    decode_with_span(data, b"").map(|(v, _)| v)
}

struct Parser<'a> {
    data: &'a [u8],
    pos: usize,
    depth: usize,
    span_key: &'a [u8],
    span: Option<(usize, usize)>,
}

impl<'a> Parser<'a> {
    fn err<T>(&self, msg: &str) -> Result<T, DecodeError> {
        Err(DecodeError(format!("{msg} at byte {}", self.pos)))
    }

    fn peek(&self) -> Option<u8> {
        self.data.get(self.pos).copied()
    }

    fn value(&mut self, level: usize) -> Result<Value, DecodeError> {
        self.depth += 1;
        if self.depth > 64 {
            return self.err("nested too deeply");
        }
        let v = match self.peek() {
            Some(b'i') => self.int(),
            Some(b'l') => self.list(level),
            Some(b'd') => self.dict(level),
            Some(b'0'..=b'9') => self.bytes().map(Value::Bytes),
            Some(_) => self.err("unexpected byte"),
            None => self.err("unexpected end"),
        };
        self.depth -= 1;
        v
    }

    fn int(&mut self) -> Result<Value, DecodeError> {
        self.pos += 1; // 'i'
        let start = self.pos;
        while let Some(c) = self.peek() {
            if c == b'e' { break; }
            self.pos += 1;
        }
        if self.peek() != Some(b'e') {
            return self.err("unterminated int");
        }
        let s = std::str::from_utf8(&self.data[start..self.pos]).map_err(|_| DecodeError("bad int".into()))?;
        self.pos += 1;
        s.parse::<i64>().map(Value::Int).map_err(|_| DecodeError(format!("bad int {s:?}")))
    }

    fn bytes(&mut self) -> Result<Vec<u8>, DecodeError> {
        let start = self.pos;
        while let Some(c) = self.peek() {
            if c == b':' { break; }
            if !c.is_ascii_digit() { return self.err("bad string length"); }
            self.pos += 1;
        }
        if self.peek() != Some(b':') {
            return self.err("unterminated string length");
        }
        let len: usize = std::str::from_utf8(&self.data[start..self.pos])
            .ok()
            .and_then(|s| s.parse().ok())
            .ok_or_else(|| DecodeError("bad string length".into()))?;
        self.pos += 1;
        if self.pos + len > self.data.len() {
            return self.err("string runs past end");
        }
        let out = self.data[self.pos..self.pos + len].to_vec();
        self.pos += len;
        Ok(out)
    }

    fn list(&mut self, level: usize) -> Result<Value, DecodeError> {
        self.pos += 1;
        let mut items = Vec::new();
        loop {
            match self.peek() {
                Some(b'e') => { self.pos += 1; return Ok(Value::List(items)); }
                None => return self.err("unterminated list"),
                _ => items.push(self.value(level + 1)?),
            }
        }
    }

    fn dict(&mut self, level: usize) -> Result<Value, DecodeError> {
        self.pos += 1;
        let mut map = BTreeMap::new();
        loop {
            match self.peek() {
                Some(b'e') => { self.pos += 1; return Ok(Value::Dict(map)); }
                None => return self.err("unterminated dict"),
                _ => {
                    let key = self.bytes()?;
                    let vstart = self.pos;
                    let v = self.value(level + 1)?;
                    if level == 0 && !self.span_key.is_empty() && key == self.span_key {
                        self.span = Some((vstart, self.pos));
                    }
                    map.insert(key, v);
                }
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn decodes_basic_types() {
        let v = decode(b"d3:fooi42e4:spaml1:a1:bee").unwrap();
        assert_eq!(v.get("foo").and_then(Value::as_int), Some(42));
        assert_eq!(v.get("spam").and_then(Value::as_list).map(|l| l.len()), Some(2));
    }

    #[test]
    fn records_info_span() {
        let data = b"d8:announce3:url4:infod4:name1:xee";
        let (_, span) = decode_with_span(data, b"info").unwrap();
        let (s, e) = span.unwrap();
        assert_eq!(&data[s..e], b"d4:name1:xe");
    }

    #[test]
    fn rejects_truncated() {
        assert!(decode(b"d3:foo").is_err());
        assert!(decode(b"5:ab").is_err());
        assert!(decode(b"i12").is_err());
    }
}
