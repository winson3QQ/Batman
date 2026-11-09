//! The owner path for Dart (design v8.5.1 §5.3 login, §5.5 status): one of this phone's nodes, from its sealed node
//! record (Kotlin opens it with the Keystore record key and the AAD from here), over BLE (sans-IO: Dart moves frames,
//! Kotlin signs auth/owner with the owner key). After login: `status` and `settings/get`, answered as display text.
//! The record's secrets (K, owner_tag_key, root password) stay in Rust; only the device id's last 4 go out.

use batman_proto::cbor::{self, Value};
use batman_proto::conn::Conn;
use batman_proto::envelope::Outcome;
use batman_proto::loginflow::{Action, End, Login, NodeRecord};
use batman_proto::status;
use batman_proto::store;

/// A sealed record and the AAD Kotlin opens it with.
pub struct SealedRecord {
    pub generation: u64,
    pub sealed: Vec<u8>,
    pub aad: Vec<u8>,
}

pub fn store_read_sealed(dir: String, rel: String) -> Result<Option<SealedRecord>, String> {
    match store::Store::new(dir).read(&rel).map_err(|e| format!("{e:?}"))? {
        None => Ok(None),
        Some(r) => Ok(Some(SealedRecord { generation: r.generation, aad: store::aad(&rel, r.generation), sealed: r.sealed })),
    }
}

/// The device ids this phone holds a node record for (file names under node/; no record is opened).
pub fn list_nodes(dir: String) -> Vec<String> {
    let mut v: Vec<String> = std::fs::read_dir(std::path::Path::new(&dir).join("node"))
        .map(|d| d.filter_map(|e| e.ok()).map(|e| e.file_name().to_string_lossy().to_string()).filter(|n| !n.starts_with('.')).collect())
        .unwrap_or_default();
    v.sort();
    v
}

struct Rec {
    device_id: String,
    owner_tag_key: [u8; 32],
    dac_der: Vec<u8>,
}

fn parse_record(plain: &[u8]) -> Result<Rec, String> {
    let v = cbor::decode(plain).map_err(|e| format!("node record: {e}"))?;
    Ok(Rec {
        device_id: v.get(1).and_then(Value::as_text).ok_or("node record: no device id")?.to_string(),
        owner_tag_key: v.get(5).and_then(Value::as_bytes).and_then(|b| b.try_into().ok()).ok_or("node record: no owner_tag_key")?,
        dac_der: v.get(4).and_then(Value::as_bytes).ok_or("node record: no DAC")?.to_vec(),
    })
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum OwnerKind {
    /// write `frames` to RX in order
    Write,
    /// Kotlin signs `sign_input` with the owner key, then `signed(der)`
    Sign,
    /// an owner session: `request_status` / `request_settings` may follow
    LoggedIn,
    /// the answer to a request: `detail` is display text
    Answer,
    /// over: `detail` says why (msg2 undecryptable = not this node / PSK not loaded yet — try the next one)
    Ended,
}

pub struct OwnerStep {
    pub kind: OwnerKind,
    pub frames: Vec<Vec<u8>>,
    pub sign_input: Vec<u8>,
    pub detail: String,
}

impl OwnerStep {
    fn new(kind: OwnerKind) -> OwnerStep {
        OwnerStep { kind, frames: vec![], sign_input: vec![], detail: String::new() }
    }
    fn text(kind: OwnerKind, d: String) -> OwnerStep {
        OwnerStep { detail: d, ..OwnerStep::new(kind) }
    }
}

enum St {
    Login(Login),
    Conn { conn: Conn, asked: &'static str },
    Over,
}

#[flutter_rust_bridge::frb(opaque)]
pub struct OwnerSession {
    st: St,
    last4: String,
}

fn status_text(b: &Value) -> String {
    match status::decode_owner(b) {
        Ok(t) => t,
        Err(e) => format!("status not understood: {e}"),
    }
}

fn settings_text(b: &Value) -> String {
    let mut out = vec![];
    if let Some(n) = b.get(1).and_then(Value::as_text) {
        out.push(format!("name {n}"));
    }
    if let Some(c) = b.get(2).and_then(Value::as_text) {
        out.push(format!("country {c}"));
    }
    if let Some(h) = b.get(10) {
        let ch = h.get(1).and_then(Value::as_uint).map(|c| c.to_string()).unwrap_or("?".into());
        let bw = h.get(2).and_then(Value::as_uint).map(|c| format!(" {c} MHz")).unwrap_or_default();
        out.push(format!("HaLow ch {ch}{bw}"));
    }
    if let Some(s) = b.get(20).and_then(|a| a.get(1)).and_then(Value::as_text) {
        out.push(format!("phone AP \"{s}\""));
    }
    if out.is_empty() { "settings: (none readable)".into() } else { out.join(", ") }
}

impl OwnerSession {
    /// Login to the node of this (opened) node record; the first step is the msg1 frames.
    #[flutter_rust_bridge::frb(sync)]
    pub fn start(record_plain: Vec<u8>, owner_pub: Vec<u8>, frame_limit: u32) -> Result<(OwnerSession, OwnerStep), String> {
        let r = parse_record(&record_plain)?;
        let op: [u8; 65] = owner_pub.try_into().map_err(|_| "owner_pub is not 65 bytes")?;
        let nr = NodeRecord { device_id: &r.device_id, owner_tag_key: &r.owner_tag_key, pinned_dac_der: &r.dac_der, owner_pub: &op };
        let (login, a) = Login::start(&nr, frame_limit as usize);
        let last4 = r.device_id[r.device_id.len().saturating_sub(4)..].to_string();
        let mut s = OwnerSession { st: St::Login(login), last4 };
        let step = s.login_step(Some(a)).ok_or("no first step")?;
        Ok((s, step))
    }

    #[flutter_rust_bridge::frb(sync)]
    pub fn last4(&self) -> String {
        self.last4.clone()
    }

    #[flutter_rust_bridge::frb(sync)]
    pub fn signed(&mut self, der: Vec<u8>) -> Option<OwnerStep> {
        let a = match &mut self.st {
            St::Login(l) => l.signed(&der),
            _ => None,
        };
        self.login_step(a)
    }

    #[flutter_rust_bridge::frb(sync)]
    pub fn on_frame(&mut self, frame: Vec<u8>) -> Option<OwnerStep> {
        match &mut self.st {
            St::Login(l) => {
                let a = l.on_frame(&frame);
                self.login_step(a)
            }
            St::Conn { conn, asked } => match conn.on_frame(&frame) {
                Ok(None) => None,
                Ok(Some(Outcome::Ok(b))) => {
                    let t = if *asked == "status" { status_text(&b) } else { settings_text(&b) };
                    Some(OwnerStep::text(OwnerKind::Answer, t))
                }
                Ok(Some(Outcome::Err { code, detail })) => Some(OwnerStep::text(OwnerKind::Answer, format!("{asked}: error {code} {detail:?}"))),
                Err(e) => {
                    self.st = St::Over;
                    Some(OwnerStep::text(OwnerKind::Ended, format!("connection: {e:?}")))
                }
            },
            St::Over => None,
        }
    }

    /// `status` {1: 0} (self) — design §5.5
    #[flutter_rust_bridge::frb(sync)]
    pub fn request_status(&mut self) -> Result<OwnerStep, String> {
        self.request("status", Value::Map(vec![(Value::Uint(1), Value::Uint(0))]))
    }

    /// `settings/get` {} — 254-p3-impl §3.3
    #[flutter_rust_bridge::frb(sync)]
    pub fn request_settings(&mut self) -> Result<OwnerStep, String> {
        self.request("settings/get", Value::Map(vec![]))
    }

    fn request(&mut self, verb: &'static str, body: Value) -> Result<OwnerStep, String> {
        match &mut self.st {
            St::Conn { conn, asked } => {
                let (_, f) = conn.request(verb, body).map_err(|e| format!("{e:?}"))?;
                *asked = verb;
                Ok(OwnerStep { frames: f, ..OwnerStep::new(OwnerKind::Write) })
            }
            _ => Err("not logged in".into()),
        }
    }

    fn login_step(&mut self, a: Option<Action>) -> Option<OwnerStep> {
        Some(match a? {
            Action::Write(frames) => OwnerStep { frames, ..OwnerStep::new(OwnerKind::Write) },
            Action::Sign { input } => OwnerStep { sign_input: input, ..OwnerStep::new(OwnerKind::Sign) },
            Action::Done(End::LoggedIn) => {
                let login = match std::mem::replace(&mut self.st, St::Over) {
                    St::Login(l) => l,
                    other => {
                        self.st = other;
                        return Some(OwnerStep::text(OwnerKind::Ended, "logged in without a login".into()));
                    }
                };
                match login.into_conn() {
                    Some(conn) => {
                        self.st = St::Conn { conn, asked: "" };
                        OwnerStep::text(OwnerKind::LoggedIn, format!("owner session with …{}", self.last4))
                    }
                    None => OwnerStep::text(OwnerKind::Ended, "no connection after login".into()),
                }
            }
            Action::Done(e) => {
                self.st = St::Over;
                OwnerStep::text(OwnerKind::Ended, format!("{e:?}"))
            }
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn record_parse_and_texts() {
        let rec = cbor::encode(&Value::Map(vec![
            (Value::Uint(1), Value::Text("e61551410cfd538e24".into())),
            (Value::Uint(2), Value::Bytes(vec![7; 32])),
            (Value::Uint(4), Value::Bytes(vec![8; 5])),
            (Value::Uint(5), Value::Bytes(vec![5; 32])),
        ]));
        let r = parse_record(&rec).unwrap();
        assert_eq!(r.device_id, "e61551410cfd538e24");
        assert_eq!(r.owner_tag_key, [5; 32]);
        assert!(parse_record(&[0xa0]).is_err());
        let s = Value::Map(vec![
            (Value::Uint(1), Value::Text("BCM2711-6c89".into())),
            (Value::Uint(2), Value::Text("US".into())),
            (Value::Uint(10), Value::Map(vec![(Value::Uint(1), Value::Uint(42)), (Value::Uint(2), Value::Uint(2))])),
            (Value::Uint(20), Value::Map(vec![(Value::Uint(1), Value::Text("BCM2711-6c89".into()))])),
        ]);
        assert_eq!(settings_text(&s), "name BCM2711-6c89, country US, HaLow ch 42 2 MHz, phone AP \"BCM2711-6c89\"");
        assert_eq!(settings_text(&Value::Map(vec![])), "settings: (none readable)");
    }

    #[test]
    fn list_and_read() {
        let d = std::env::temp_dir().join(format!("bm-owner-{}", std::process::id()));
        let dir = d.to_string_lossy().to_string();
        assert!(list_nodes(dir.clone()).is_empty());
        let s = store::Store::new(&d);
        s.write("node/e61551410cfd538e24", 1, &[1, 2, 3]).unwrap();
        assert_eq!(list_nodes(dir.clone()), vec!["e61551410cfd538e24".to_string()]);
        let r = store_read_sealed(dir.clone(), "node/e61551410cfd538e24".into()).unwrap().unwrap();
        assert_eq!(r.aad, store::aad("node/e61551410cfd538e24", r.generation));
        assert_eq!(r.sealed, vec![1, 2, 3]);
        assert!(store_read_sealed(dir, "node/nope".into()).unwrap().is_none());
        let _ = std::fs::remove_dir_all(d);
    }
}
