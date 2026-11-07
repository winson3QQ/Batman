//! Request chunking and response envelopes (219-protocol.md §4.2; node S/provd/session.go:424-501, cddl:108-119).
//! - A request whose whole envelope exceeds `max_msg − 16` is chunked: the ENCODED body is cut into slices, each sent
//!   as {0, 1: id, 2: type, 3: bstr slice, 6: {1: n, 2: total}[, 7: idem]}, every chunk's whole envelope ≤ max_msg − 16
//!   (vector chunk_boundary). All chunks share the id.
//! - Responses: success {1: id, 3: body, 4: 0}; error {1: id, 4: code ≠ 0, 5: detail}, no key 3; chunked success
//!   {1: id, 3: bstr, 4: 0, 6: {1: n, 2: total}}. No key 0. The app checks id == the request's id; a duplicate (id, n),
//!   a changed total or an oversized message is refused and the session closed by the caller.

use crate::cbor::{self, Value};
use crate::sig;

/// 219 §4.2: the reassembled message cap (P2's provd caps lower, 65400 B — facts §7; the node refuses first).
pub const MAX_REASSEMBLED: usize = 1 << 20;

#[derive(Debug, PartialEq, Eq)]
pub enum Error {
    Cbor(cbor::Error),
    /// max_msg too small for even a one-byte slice
    LimitTooSmall,
    TooManyChunks,
    NotAMap,
    UnknownKey(u64),
    WrongId { want: u64, got: u64 },
    BadStatus,
    BadPart,
    DuplicatePart(u64),
    PartTotalChanged,
    TooLarge,
}

impl From<cbor::Error> for Error {
    fn from(e: cbor::Error) -> Self {
        Error::Cbor(e)
    }
}

/// One chunk of a request.
pub fn chunk_request(id: u64, verb: &str, idem: Option<&[u8; 16]>, slice: &[u8], n: u64, total: u64) -> Vec<u8> {
    let mut m = vec![
        (Value::Uint(0), Value::Array(vec![Value::Uint(1), Value::Uint(0)])),
        (Value::Uint(1), Value::Uint(id)),
        (Value::Uint(2), Value::Text(verb.into())),
        (Value::Uint(3), Value::Bytes(slice.to_vec())),
        (Value::Uint(6), Value::Map(vec![(Value::Uint(1), Value::Uint(n)), (Value::Uint(2), Value::Uint(total))])),
    ];
    if let Some(k) = idem {
        m.push((Value::Uint(7), Value::Bytes(k.to_vec())));
    }
    cbor::encode(&Value::Map(m))
}

/// The largest body slice whose chunk envelope (with these id / verb / idem / n / total) fits in `limit` bytes.
pub fn max_slice(limit: usize, id: u64, verb: &str, idem: Option<&[u8; 16]>, n: u64, total: u64) -> Option<usize> {
    // the envelope is a fixed overhead plus the slice's bstr head (1, 2, 3, 5 or 9 bytes) plus the slice
    let fixed = chunk_request(id, verb, idem, &[], n, total).len() - 1;
    let mut best = None;
    for (head, lo, hi) in [(1usize, 0usize, 23usize), (2, 24, 0xff), (3, 0x100, 0xffff), (5, 0x1_0000, 0xffff_ffff)] {
        let Some(room) = limit.checked_sub(fixed + head) else { break };
        let s = room.min(hi);
        if s >= lo {
            best = Some(s);
        }
    }
    best.filter(|s| *s > 0)
}

/// A request as the messages to send: one whole envelope, or chunks of the encoded body.
pub fn split_request(id: u64, verb: &str, body: Value, max_msg: usize) -> Result<Vec<Vec<u8>>, Error> {
    let limit = max_msg.checked_sub(16).ok_or(Error::LimitTooSmall)?;
    let body_enc = cbor::encode(&body);
    let whole = sig::request(id, verb, body);
    if whole.len() <= limit {
        return Ok(vec![whole]);
    }
    if body_enc.len() > MAX_REASSEMBLED {
        return Err(Error::TooLarge);
    }
    // size the slices for the worst n / total of this message, then check every chunk against the limit
    let mut total = 2u64;
    loop {
        let s = max_slice(limit, id, verb, None, total, total).ok_or(Error::LimitTooSmall)?;
        let need = body_enc.len().div_ceil(s) as u64;
        if need > 0xffff {
            return Err(Error::TooManyChunks);
        }
        if need <= total {
            let out: Vec<Vec<u8>> = body_enc
                .chunks(s)
                .enumerate()
                .map(|(i, c)| chunk_request(id, verb, None, c, i as u64 + 1, need))
                .collect();
            debug_assert!(out.iter().all(|c| c.len() <= limit));
            return Ok(out);
        }
        total = need;
    }
}

#[derive(Debug, PartialEq)]
pub enum Outcome {
    Ok(Value),
    Err { code: u64, detail: Value },
}

/// Reassembles one response to request `id`.
pub struct ResponseReader {
    id: u64,
    total: Option<u64>,
    parts: Vec<Option<Vec<u8>>>,
    size: usize,
}

impl ResponseReader {
    pub fn new(id: u64) -> Self {
        ResponseReader { id, total: None, parts: Vec::new(), size: 0 }
    }

    /// Feed one received message; Some(outcome) when the response is complete.
    pub fn push(&mut self, msg: &[u8]) -> Result<Option<Outcome>, Error> {
        let v = cbor::decode(msg)?;
        let Value::Map(m) = &v else { return Err(Error::NotAMap) };
        for (k, _) in m {
            match k {
                Value::Uint(1 | 3 | 4 | 5 | 6) => {}
                Value::Uint(k) => return Err(Error::UnknownKey(*k)),
                _ => return Err(Error::NotAMap),
            }
        }
        let got = v.get(1).and_then(Value::as_uint).ok_or(Error::BadStatus)?;
        if got != self.id {
            return Err(Error::WrongId { want: self.id, got });
        }
        let status = v.get(4).and_then(Value::as_uint).ok_or(Error::BadStatus)?;
        if status != 0 {
            // an error is never chunked and carries no body
            if self.total.is_some() || v.get(3).is_some() || v.get(6).is_some() {
                return Err(Error::BadStatus);
            }
            let detail = v.get(5).cloned().ok_or(Error::BadStatus)?;
            if !matches!(detail, Value::Map(_)) {
                return Err(Error::BadStatus);
            }
            return Ok(Some(Outcome::Err { code: status, detail }));
        }
        if v.get(5).is_some() {
            return Err(Error::BadStatus);
        }
        let body = v.get(3).ok_or(Error::BadStatus)?;
        let Some(part) = v.get(6) else {
            if self.total.is_some() {
                return Err(Error::BadPart);
            }
            if !matches!(body, Value::Map(_)) {
                return Err(Error::BadStatus);
            }
            return Ok(Some(Outcome::Ok(body.clone())));
        };
        let Value::Map(pm) = part else { return Err(Error::BadPart) };
        if pm.len() != 2 {
            return Err(Error::BadPart);
        }
        let n = part.get(1).and_then(Value::as_uint).ok_or(Error::BadPart)?;
        let total = part.get(2).and_then(Value::as_uint).ok_or(Error::BadPart)?;
        let slice = body.as_bytes().ok_or(Error::BadPart)?;
        if total < 2 || total > 0xffff || n == 0 || n > total {
            return Err(Error::BadPart);
        }
        match self.total {
            None => {
                self.total = Some(total);
                self.parts = vec![None; total as usize];
            }
            Some(t) if t != total => return Err(Error::PartTotalChanged),
            Some(_) => {}
        }
        let slot = &mut self.parts[(n - 1) as usize];
        if slot.is_some() {
            return Err(Error::DuplicatePart(n));
        }
        self.size += slice.len();
        if self.size > MAX_REASSEMBLED {
            return Err(Error::TooLarge);
        }
        *slot = Some(slice.to_vec());
        if self.parts.iter().any(Option::is_none) {
            return Ok(None);
        }
        let joined: Vec<u8> = self.parts.iter().flatten().flatten().copied().collect();
        let body = cbor::decode(&joined)?;
        if !matches!(body, Value::Map(_)) {
            return Err(Error::BadStatus);
        }
        Ok(Some(Outcome::Ok(body)))
    }
}
