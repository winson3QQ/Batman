//! Deterministic CBOR (RFC 8949 §4.2.1 core deterministic encoding), the subset the protocol uses:
//! unsigned / negative integers, byte and text strings, arrays, maps, tags, false / true / null.
//!
//! The node closes the connection on a non-deterministic request (provd session.go:441-443) and owner-op signatures
//! hash the encoded body (proto.go:82), so encoding must be byte-exact. Decoding is strict in the same way: a
//! non-shortest head, an indefinite length, an unsorted or duplicate map key, a float, an unknown simple value or
//! trailing bytes is an error — never "accepted and re-encoded differently".

use std::fmt;

/// A CBOR data item.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Value {
    /// Major type 0.
    Uint(u64),
    /// Major type 1: the value is -1 - n.
    Nint(u64),
    Bytes(Vec<u8>),
    Text(String),
    Array(Vec<Value>),
    /// Map entries in any order; [`encode`] sorts them by their encoded keys.
    Map(Vec<(Value, Value)>),
    Tag(u64, Box<Value>),
    Bool(bool),
    Null,
}

#[derive(Debug, PartialEq, Eq)]
pub enum Error {
    Truncated,
    TrailingBytes,
    NotShortest,
    Indefinite,
    UnsortedOrDuplicateKey,
    Unsupported(u8),
    InvalidUtf8,
    TooDeep,
}

impl fmt::Display for Error {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "cbor: {self:?}")
    }
}

impl std::error::Error for Error {}

const MAX_DEPTH: usize = 32;

fn head(out: &mut Vec<u8>, major: u8, n: u64) {
    let m = major << 5;
    match n {
        0..=23 => out.push(m | n as u8),
        24..=0xff => out.extend([m | 24, n as u8]),
        0x100..=0xffff => {
            out.push(m | 25);
            out.extend((n as u16).to_be_bytes());
        }
        0x1_0000..=0xffff_ffff => {
            out.push(m | 26);
            out.extend((n as u32).to_be_bytes());
        }
        _ => {
            out.push(m | 27);
            out.extend(n.to_be_bytes());
        }
    }
}

/// Encodes `v` deterministically: shortest heads, definite lengths, map keys sorted by their encoded bytes.
pub fn encode(v: &Value) -> Vec<u8> {
    let mut out = Vec::new();
    encode_into(v, &mut out);
    out
}

fn encode_into(v: &Value, out: &mut Vec<u8>) {
    match v {
        Value::Uint(n) => head(out, 0, *n),
        Value::Nint(n) => head(out, 1, *n),
        Value::Bytes(b) => {
            head(out, 2, b.len() as u64);
            out.extend(b);
        }
        Value::Text(s) => {
            head(out, 3, s.len() as u64);
            out.extend(s.as_bytes());
        }
        Value::Array(a) => {
            head(out, 4, a.len() as u64);
            for x in a {
                encode_into(x, out);
            }
        }
        Value::Map(m) => {
            let mut entries: Vec<(Vec<u8>, &Value)> = m.iter().map(|(k, v)| (encode(k), v)).collect();
            entries.sort_by(|a, b| a.0.cmp(&b.0));
            head(out, 5, entries.len() as u64);
            for (k, v) in entries {
                out.extend(k);
                encode_into(v, out);
            }
        }
        Value::Tag(t, x) => {
            head(out, 6, *t);
            encode_into(x, out);
        }
        Value::Bool(false) => out.push(0xf4),
        Value::Bool(true) => out.push(0xf5),
        Value::Null => out.push(0xf6),
    }
}

/// Decodes exactly one deterministically encoded item; anything else in `buf` is an error.
pub fn decode(buf: &[u8]) -> Result<Value, Error> {
    let mut r = Reader { buf, pos: 0 };
    let v = r.item(0)?;
    if r.pos != buf.len() {
        return Err(Error::TrailingBytes);
    }
    Ok(v)
}

struct Reader<'a> {
    buf: &'a [u8],
    pos: usize,
}

impl Reader<'_> {
    fn take(&mut self, n: usize) -> Result<&[u8], Error> {
        let end = self.pos.checked_add(n).ok_or(Error::Truncated)?;
        let s = self.buf.get(self.pos..end).ok_or(Error::Truncated)?;
        self.pos = end;
        Ok(s)
    }

    /// The argument of a head, rejecting indefinite lengths and non-shortest forms.
    fn arg(&mut self, info: u8) -> Result<u64, Error> {
        let (n, min) = match info {
            0..=23 => return Ok(info as u64),
            24 => (self.take(1)?[0] as u64, 24),
            25 => (u16::from_be_bytes(self.take(2)?.try_into().unwrap()) as u64, 0x100),
            26 => (u32::from_be_bytes(self.take(4)?.try_into().unwrap()) as u64, 0x1_0000),
            27 => (u64::from_be_bytes(self.take(8)?.try_into().unwrap()), 0x1_0000_0000),
            31 => return Err(Error::Indefinite),
            _ => return Err(Error::Unsupported(info)),
        };
        if n < min {
            return Err(Error::NotShortest);
        }
        Ok(n)
    }

    fn len(&mut self, info: u8) -> Result<usize, Error> {
        let n = self.arg(info)?;
        // a length can never exceed what is left in the buffer (each element is at least one byte)
        if n > (self.buf.len() - self.pos) as u64 {
            return Err(Error::Truncated);
        }
        Ok(n as usize)
    }

    fn item(&mut self, depth: usize) -> Result<Value, Error> {
        if depth > MAX_DEPTH {
            return Err(Error::TooDeep);
        }
        let ib = self.take(1)?[0];
        let (major, info) = (ib >> 5, ib & 0x1f);
        Ok(match major {
            0 => Value::Uint(self.arg(info)?),
            1 => Value::Nint(self.arg(info)?),
            2 => {
                let n = self.len(info)?;
                Value::Bytes(self.take(n)?.to_vec())
            }
            3 => {
                let n = self.len(info)?;
                let b = self.take(n)?.to_vec();
                Value::Text(String::from_utf8(b).map_err(|_| Error::InvalidUtf8)?)
            }
            4 => {
                let n = self.len(info)?;
                let mut a = Vec::with_capacity(n);
                for _ in 0..n {
                    a.push(self.item(depth + 1)?);
                }
                Value::Array(a)
            }
            5 => {
                let n = self.len(info)?;
                let mut m = Vec::with_capacity(n);
                let mut prev: Option<Vec<u8>> = None;
                for _ in 0..n {
                    let start = self.pos;
                    let k = self.item(depth + 1)?;
                    let kb = self.buf[start..self.pos].to_vec();
                    if let Some(p) = &prev {
                        if kb <= *p {
                            return Err(Error::UnsortedOrDuplicateKey);
                        }
                    }
                    prev = Some(kb);
                    let v = self.item(depth + 1)?;
                    m.push((k, v));
                }
                Value::Map(m)
            }
            6 => {
                let t = self.arg(info)?;
                Value::Tag(t, Box::new(self.item(depth + 1)?))
            }
            7 => match info {
                20 => Value::Bool(false),
                21 => Value::Bool(true),
                22 => Value::Null,
                _ => return Err(Error::Unsupported(ib)),
            },
            _ => unreachable!(),
        })
    }
}

impl Value {
    /// The value under integer key `k` of a map (None for a non-map or a missing key).
    pub fn get(&self, k: u64) -> Option<&Value> {
        match self {
            Value::Map(m) => m.iter().find(|(key, _)| *key == Value::Uint(k)).map(|(_, v)| v),
            _ => None,
        }
    }
    pub fn as_uint(&self) -> Option<u64> {
        match self {
            Value::Uint(n) => Some(*n),
            _ => None,
        }
    }
    pub fn as_bytes(&self) -> Option<&[u8]> {
        match self {
            Value::Bytes(b) => Some(b),
            _ => None,
        }
    }
    pub fn as_text(&self) -> Option<&str> {
        match self {
            Value::Text(s) => Some(s),
            _ => None,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn heads_are_shortest() {
        for (n, want) in [(0u64, "00"), (23, "17"), (24, "1818"), (255, "18ff"), (256, "190100"), (65536, "1a00010000")] {
            assert_eq!(encode(&Value::Uint(n)), hex(want), "{n}");
        }
    }

    #[test]
    fn map_keys_sorted_by_encoding() {
        // 10 (0x0a) sorts before 100 (0x18 0x64) and before "a" (0x61 0x61)
        let m = Value::Map(vec![
            (Value::Text("a".into()), Value::Null),
            (Value::Uint(100), Value::Null),
            (Value::Uint(10), Value::Null),
        ]);
        assert_eq!(encode(&m), hex("a30af61864f66161f6"));
    }

    #[test]
    fn strict_decoding() {
        assert_eq!(decode(&hex("1817")), Err(Error::NotShortest)); // 23 in two bytes
        assert_eq!(decode(&hex("5f40ff")), Err(Error::Indefinite));
        assert_eq!(decode(&hex("a20af60af6")), Err(Error::UnsortedOrDuplicateKey)); // duplicate key
        assert_eq!(decode(&hex("a20bf60af6")), Err(Error::UnsortedOrDuplicateKey)); // unsorted
        assert_eq!(decode(&hex("0000")), Err(Error::TrailingBytes));
        assert_eq!(decode(&hex("f93c00")), Err(Error::Unsupported(0xf9))); // a float
        assert_eq!(decode(&hex("5a")), Err(Error::Truncated));
        assert_eq!(decode(&hex("9bffffffffffffffff")), Err(Error::Truncated)); // huge length, no data
    }

    fn hex(s: &str) -> Vec<u8> {
        (0..s.len()).step_by(2).map(|i| u8::from_str_radix(&s[i..i + 2], 16).unwrap()).collect()
    }
}
