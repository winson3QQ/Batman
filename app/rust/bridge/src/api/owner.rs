//! The owner path for Dart (design v8.5.1 §5.3 login, §5.5 status): one of this phone's nodes, from its sealed node
//! record (Kotlin opens it with the Keystore record key and the AAD from here), over BLE (sans-IO: Dart moves frames,
//! Kotlin signs auth/owner with the owner key). After login: `status` and `settings/get`, answered as display text.
//! The record's secrets (K, owner_tag_key, root password) stay in Rust; only the device id's last 4 go out.

use batman_proto::cbor::{self, Value};
use batman_proto::conn::Conn;
use batman_proto::envelope::Outcome;
use batman_proto::flow::{self, JoinReply, JoinState};
use batman_proto::joinflow::{self, Join, NetRecord};
use batman_proto::loginflow::{Action, End, Login, NodeRecord};
use batman_proto::nodecert::{self, Verified};
use batman_proto::{sig, status};
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
    /// make-network (§5.4): Kotlin signs `sign_input` (a COSE Sig_structure) with the ADMIN key, then `signed(der)`
    SignAdmin,
    /// make-network: seal `record` with `aad`, write it at `rel` / `generation` (store_write_sealed, fsynced), then
    /// `net_persisted()` — nothing is sent before (§3: the net record lands before network/join)
    PersistNet,
}

pub struct OwnerStep {
    pub kind: OwnerKind,
    pub frames: Vec<Vec<u8>>,
    pub sign_input: Vec<u8>,
    pub detail: String,
    /// PersistNet: the plain net record (holds SAE / net_root: sealed by Kotlin, never shown), its path and AAD
    pub record: Vec<u8>,
    pub rel: String,
    pub generation: u64,
    pub aad: Vec<u8>,
}

impl OwnerStep {
    fn new(kind: OwnerKind) -> OwnerStep {
        OwnerStep { kind, frames: vec![], sign_input: vec![], detail: String::new(), record: vec![], rel: String::new(), generation: 0, aad: vec![] }
    }
    fn text(kind: OwnerKind, d: String) -> OwnerStep {
        OwnerStep { detail: d, ..OwnerStep::new(kind) }
    }
}

enum St {
    Login(Login),
    Conn { conn: Conn, asked: &'static str, op: Option<(&'static str, Value)> },
    /// make-network in flight (§5.4); `rec` once persisted; `applied` while the applied record is written;
    /// `resent` after the one NewNonce resend
    Join { join: Join, rec: Option<NetRecord>, applied: bool, resent: bool },
    Over,
}

#[flutter_rust_bridge::frb(opaque)]
pub struct OwnerSession {
    st: St,
    last4: String,
    owner_pub: [u8; 65],
    /// the node_cert verified at this login (dac_pub, ecdh_pub)
    node: Option<Verified>,
    /// the net_id of the last make-network of this session (what `check_network` reads info against)
    net_id: Option<[u8; 16]>,
}

/// The net record (design §3) as stored: CBOR {1 net_id, 2 mesh_id, 3 channel, 4 bw, 5 SAE, 6 net_root, 7 netcfg,
/// 8 members, 9 secrets, 10 state}. Secrets inside: it only leaves Rust to be sealed by Kotlin.
pub(crate) fn net_record_plain(r: &NetRecord, state: &str) -> Vec<u8> {
    cbor::encode(&Value::Map(vec![
        (Value::Uint(1), Value::Bytes(r.net_id.to_vec())),
        (Value::Uint(2), Value::Text(r.mesh_id.clone())),
        (Value::Uint(3), Value::Uint(r.channel)),
        (Value::Uint(4), Value::Uint(r.bw)),
        (Value::Uint(5), Value::Text(r.sae.clone())),
        (Value::Uint(6), Value::Bytes(r.net_root.to_vec())),
        (Value::Uint(7), Value::Bytes(r.netcfg.clone())),
        (Value::Uint(8), Value::Bytes(r.members.clone())),
        (Value::Uint(9), Value::Bytes(r.secrets.clone())),
        (Value::Uint(10), Value::Text(state.into())),
    ]))
}

fn persist_step(r: &NetRecord, generation: u64, state: &str) -> OwnerStep {
    let rel = format!("net/{}", nodecert::hex_lower(&r.net_id));
    OwnerStep { record: net_record_plain(r, state), aad: store::aad(&rel, generation), rel, generation, ..OwnerStep::new(OwnerKind::PersistNet) }
}

fn join_state_text(s: &JoinState) -> String {
    match s {
        JoinState::Applied { save_pending: false } => "network: applied".into(),
        JoinState::Applied { save_pending: true } => "network: applied (the save completes at the node's next boot)".into(),
        JoinState::InProgress => "network: still being applied — check again in a minute".into(),
        JoinState::NotApplied => "network: not applied (or rolled back) — the same network may be sent again".into(),
        JoinState::OtherNetwork => "network: the node is in ANOTHER network — stopped".into(),
        JoinState::Unknown => "network: unknown for now — check again later".into(),
    }
}

fn status_text(b: &Value) -> String {
    match status::decode_owner(b) {
        Ok(t) => t,
        Err(e) => format!("status not understood: {e}"),
    }
}

/// An error body's reason-code (CDDL; 254-p3-impl §3.1-8): E_UNSUPPORTED {1: verb, 2: reason} / E_REJECTED {2: reason}.
/// Only the code and its meaning: an error body never echoes the request.
fn reason_text(detail: &Value) -> String {
    let verb = detail.get(1).and_then(Value::as_text).map(|v| format!(" ({v})")).unwrap_or_default();
    let why = match detail.get(2).and_then(Value::as_uint) {
        None => String::new(),
        Some(7) => ": this node has no such setting".into(),
        Some(13) => ": value refused (the node kept the previous one)".into(),
        Some(14) => ": the country changes only while the node is not in a network".into(),
        Some(20) => ": a legacy node (its radio is not managed by the app)".into(),
        Some(r) => format!(": reason {r}"),
    };
    format!("{verb}{why}")
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
        let mut s = OwnerSession { st: St::Login(login), last4, owner_pub: op, node: None, net_id: None };
        let step = s.login_step(Some(a)).ok_or("no first step")?;
        Ok((s, step))
    }

    #[flutter_rust_bridge::frb(sync)]
    pub fn last4(&self) -> String {
        self.last4.clone()
    }

    #[flutter_rust_bridge::frb(sync)]
    pub fn signed(&mut self, der: Vec<u8>) -> Option<OwnerStep> {
        if let St::Join { join, .. } = &mut self.st {
            let a = join.signed(&der);
            return self.join_step(a);
        }
        if let St::Conn { conn, asked, op } = &mut self.st {
            // the owner-op signature: the operation goes out with key 31 = {1: verb, 2: sig}
            let (verb, body) = op.take()?;
            let raw = match sig::der_to_raw_low_s(&der) {
                Ok(r) => r,
                Err(e) => return Some(OwnerStep::text(OwnerKind::Answer, format!("signature: {e:?}"))),
            };
            let req = sig::with_owner_op(&body, verb, &raw).map_err(|e| format!("{e:?}")).and_then(|b| conn.request(verb, b).map_err(|e| format!("{e:?}")));
            return Some(match req {
                Ok((_, f)) => {
                    *asked = verb;
                    OwnerStep { frames: f, ..OwnerStep::new(OwnerKind::Write) }
                }
                Err(e) => OwnerStep::text(OwnerKind::Answer, format!("{verb}: {e}")),
            });
        }
        let a = match &mut self.st {
            St::Login(l) => l.signed(&der),
            _ => None,
        };
        self.login_step(a)
    }

    /// `ssh_keys/set` {1: [lines]} (an owner-op; P2): the node keeps every line it did not add for an app, so this adds
    /// (or replaces the app-added) keys. op/nonce goes out first; its answer becomes a Sign step.
    #[flutter_rust_bridge::frb(sync)]
    pub fn request_ssh_keys(&mut self, lines: Vec<String>) -> Result<OwnerStep, String> {
        self.owner_op("ssh_keys/set", Value::Map(vec![(Value::Uint(1), Value::Array(lines.into_iter().map(Value::Text).collect()))]))
    }

    /// `settings/set` {2: country} (an owner-op; 254-p3-impl §3.3): only while not in a network (else reason 14).
    /// The answer is the applied settings.
    #[flutter_rust_bridge::frb(sync)]
    pub fn request_set_country(&mut self, country: String) -> Result<OwnerStep, String> {
        self.owner_op("settings/set", Value::Map(vec![(Value::Uint(2), Value::Text(country))]))
    }

    /// `settings/set` {20: {1: ssid, 2: passphrase}} (an owner-op; §3.3): the phone AP. The passphrase stays in here
    /// and in the encrypted request; it is never part of a step's text.
    #[flutter_rust_bridge::frb(sync)]
    pub fn request_set_ap(&mut self, ssid: String, passphrase: String) -> Result<OwnerStep, String> {
        let ap = Value::Map(vec![(Value::Uint(1), Value::Text(ssid)), (Value::Uint(2), Value::Text(passphrase))]);
        self.owner_op("settings/set", Value::Map(vec![(Value::Uint(20), ap)]))
    }

    /// An owner-op: op/nonce goes out first; its answer becomes a Sign step, `signed` sends the operation with key 31.
    fn owner_op(&mut self, verb: &'static str, body: Value) -> Result<OwnerStep, String> {
        match &mut self.st {
            St::Conn { conn, asked, op } => {
                let (_, f) = conn.request("op/nonce", Value::Map(vec![])).map_err(|e| format!("{e:?}"))?;
                *asked = "op/nonce";
                *op = Some((verb, body));
                Ok(OwnerStep { frames: f, ..OwnerStep::new(OwnerKind::Write) })
            }
            _ => Err("not logged in".into()),
        }
    }

    #[flutter_rust_bridge::frb(sync)]
    pub fn on_frame(&mut self, frame: Vec<u8>) -> Option<OwnerStep> {
        if let St::Join { join, .. } = &mut self.st {
            let a = join.on_frame(&frame);
            return self.join_step(a);
        }
        match &mut self.st {
            St::Login(l) => {
                let a = l.on_frame(&frame);
                self.login_step(a)
            }
            St::Conn { conn, asked, op } => match conn.on_frame(&frame) {
                Ok(None) => None,
                Ok(Some(Outcome::Ok(b))) if *asked == "op/nonce" => {
                    // owner-op (design §5.4 pattern): sign "batman-owner-op-v1" ‖ h ‖ nonce_helper ‖ verb ‖ args_hash
                    let Some((verb, body)) = op.as_ref() else { return Some(OwnerStep::text(OwnerKind::Answer, "op/nonce without an operation".into())) };
                    let helper: Option<[u8; 32]> = b.get(1).and_then(Value::as_bytes).and_then(|x| x.try_into().ok());
                    let Some(helper) = helper else { return Some(OwnerStep::text(OwnerKind::Answer, "op/nonce without a 32-byte nonce".into())) };
                    match sig::owner_op_input(&conn.h(), &helper, verb, body) {
                        Ok(input) => Some(OwnerStep { sign_input: input, ..OwnerStep::new(OwnerKind::Sign) }),
                        Err(e) => Some(OwnerStep::text(OwnerKind::Answer, format!("owner-op input: {e:?}"))),
                    }
                }
                Ok(Some(Outcome::Ok(b))) if *asked == "info-net" => {
                    *asked = "";
                    let t = match self.net_id {
                        Some(id) => join_state_text(&flow::join_state(&b, &id)),
                        None => "no network made in this session".into(),
                    };
                    Some(OwnerStep::text(OwnerKind::Answer, t))
                }
                Ok(Some(Outcome::Ok(b))) => {
                    let t = match *asked {
                        "status" => status_text(&b),
                        "settings/get" | "settings/set" => settings_text(&b),
                        v => format!("{v}: done"),
                    };
                    *op = None;
                    Some(OwnerStep::text(OwnerKind::Answer, t))
                }
                Ok(Some(Outcome::Err { code, detail })) => {
                    *op = None;
                    Some(OwnerStep::text(OwnerKind::Answer, format!("{asked}: error {code}{}", reason_text(&detail))))
                }
                Err(e) => {
                    self.st = St::Over;
                    Some(OwnerStep::text(OwnerKind::Ended, format!("connection: {e:?}")))
                }
            },
            St::Join { .. } | St::Over => None,
        }
    }

    /// make-network on this (claimed, not joined) node — design §5.4. The first step is SignAdmin (net_config).
    /// owner_enc_pub / admin_pub: this phone's keys (Kotlin publicKeys). The node's dac_pub / ecdh_pub come from the
    /// node_cert verified at this login, never from the node's word alone.
    #[flutter_rust_bridge::frb(sync)]
    pub fn request_make_network(&mut self, net_name: String, channel: u32, owner_enc_pub: Vec<u8>, admin_pub: Vec<u8>) -> Result<OwnerStep, String> {
        let node = self.node.clone().ok_or("no verified node_cert in this session")?;
        let enc: [u8; 65] = owner_enc_pub.try_into().map_err(|_| "owner_enc_pub is not 65 bytes")?;
        let adm: [u8; 65] = admin_pub.try_into().map_err(|_| "admin_pub is not 65 bytes")?;
        let conn = match std::mem::replace(&mut self.st, St::Over) {
            St::Conn { conn, .. } => conn,
            other => {
                self.st = other;
                return Err("not logged in (or a request is in flight)".into());
            }
        };
        let inp = joinflow::Input {
            net_name,
            channel: channel as u64,
            node_name: format!("node-{}", self.last4),
            dac_pub: node.dac_pub,
            ecdh_pub: node.ecdh_pub,
            owner_pub: self.owner_pub,
            owner_enc_pub: enc,
            admin_pub: adm,
        };
        let (join, a) = Join::start(conn, inp);
        self.st = St::Join { join, rec: None, applied: false, resent: false };
        self.join_step(Some(a)).ok_or_else(|| "no first step".into())
    }

    /// The net record was sealed and written (fsynced): network/join goes out (op/nonce first), or — after "applied" —
    /// the session is an owner session again.
    #[flutter_rust_bridge::frb(sync)]
    pub fn net_persisted(&mut self) -> Option<OwnerStep> {
        if let St::Join { applied: true, .. } = &self.st {
            let St::Join { join, rec, .. } = std::mem::replace(&mut self.st, St::Over) else { return None };
            self.st = St::Conn { conn: join.into_conn(), asked: "", op: None };
            let t = rec.map(|r| format!("network made: mesh {} ch {} ({} MHz)", r.mesh_id, r.channel, r.bw)).unwrap_or_default();
            return Some(OwnerStep::text(OwnerKind::Answer, t));
        }
        let a = match &mut self.st {
            St::Join { join, .. } => join.net_persisted(),
            _ => None,
        };
        self.join_step(a)
    }

    /// After an unclear join reply: read info and say where the node stands for this session's net_id (§5.4 table).
    #[flutter_rust_bridge::frb(sync)]
    pub fn check_network(&mut self) -> Result<OwnerStep, String> {
        if self.net_id.is_none() {
            return Err("no network made in this session".into());
        }
        self.request_tagged("info", "info-net", Value::Map(vec![]))
    }

    fn back_to_conn(&mut self) {
        if let St::Join { join, .. } = std::mem::replace(&mut self.st, St::Over) {
            self.st = St::Conn { conn: join.into_conn(), asked: "", op: None };
        }
    }

    fn join_step(&mut self, a: Option<joinflow::Action>) -> Option<OwnerStep> {
        use joinflow::{Action as J, End as JE};
        Some(match a? {
            J::SignAdmin { tbs } => OwnerStep { sign_input: tbs, ..OwnerStep::new(OwnerKind::SignAdmin) },
            J::SignOwner { input } => OwnerStep { sign_input: input, ..OwnerStep::new(OwnerKind::Sign) },
            J::Write(frames) => OwnerStep { frames, ..OwnerStep::new(OwnerKind::Write) },
            J::PersistNet(rec) => {
                self.net_id = Some(rec.net_id);
                let st = persist_step(&rec, 1, "pending");
                if let St::Join { rec: r, .. } = &mut self.st {
                    *r = Some(rec);
                }
                st
            }
            J::Done(JE::Replied(JoinReply::Applied)) => {
                // the applied state lands too (generation 2), then the session is an owner session again
                let rec = match &mut self.st {
                    St::Join { rec, applied, .. } => {
                        *applied = true;
                        rec.clone()
                    }
                    _ => None,
                };
                match rec {
                    Some(r) => persist_step(&r, 2, "applied"),
                    None => {
                        self.back_to_conn();
                        OwnerStep::text(OwnerKind::Answer, "network/join: applied (no record?)".into())
                    }
                }
            }
            J::Done(JE::Replied(JoinReply::NewNonce)) => {
                // 3 (nonce / signature): a new op/nonce, the same net_id, once (§5.4)
                let again = match std::mem::replace(&mut self.st, St::Over) {
                    St::Join { join, rec: Some(rec), applied, resent: false } => {
                        let (j, a) = Join::resend(join.into_conn(), rec.clone());
                        self.st = St::Join { join: j, rec: Some(rec), applied, resent: true };
                        Some(a)
                    }
                    other => {
                        self.st = other;
                        None
                    }
                };
                match again {
                    Some(a) => return self.join_step(Some(a)),
                    None => {
                        self.back_to_conn();
                        OwnerStep::text(OwnerKind::Answer, "network/join: refused again after a new nonce — not sent a third time".into())
                    }
                }
            }
            J::Done(JE::Replied(JoinReply::ReadInfo)) => {
                // 11 / other / lost: the outcome is unclear — read info against our net_id (the record stays pending)
                self.back_to_conn();
                match self.request_tagged("info", "info-net", Value::Map(vec![])) {
                    Ok(st) => st,
                    Err(e) => OwnerStep::text(OwnerKind::Answer, format!("network/join unclear, info not read: {e}")),
                }
            }
            J::Done(JE::Replied(JoinReply::Rejected)) => {
                self.back_to_conn();
                OwnerStep::text(OwnerKind::Answer, "network/join: rejected as malformed (an app bug) — the next try uses a new net_id".into())
            }
            J::Done(JE::BadChannel) => {
                self.back_to_conn();
                OwnerStep::text(OwnerKind::Answer, "make network: this channel is not offered (US ch 40 / 42)".into())
            }
            J::Done(e) => {
                self.back_to_conn();
                OwnerStep::text(OwnerKind::Answer, format!("make network stopped: {e:?}"))
            }
        })
    }

    #[flutter_rust_bridge::frb(sync)]
    pub fn request_status(&mut self) -> Result<OwnerStep, String> {
        self.request("status", Value::Map(vec![(Value::Uint(1), Value::Uint(0))]))
    }

    /// `settings/get` {} — 254-p3-impl §3.3
    #[flutter_rust_bridge::frb(sync)]
    pub fn request_settings(&mut self) -> Result<OwnerStep, String> {
        self.request("settings/get", Value::Map(vec![]))
    }

    /// `verb` goes on the wire; `tag` is what the answer is read as (`info` read for make-network = "info-net")
    fn request_tagged(&mut self, verb: &'static str, tag: &'static str, body: Value) -> Result<OwnerStep, String> {
        let st = self.request(verb, body)?;
        if let St::Conn { asked, .. } = &mut self.st {
            *asked = tag;
        }
        Ok(st)
    }

    fn request(&mut self, verb: &'static str, body: Value) -> Result<OwnerStep, String> {
        match &mut self.st {
            St::Conn { conn, asked, .. } => {
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
                self.node = login.verified().cloned();
                match login.into_conn() {
                    Some(conn) => {
                        self.st = St::Conn { conn, asked: "", op: None };
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
    fn reasons() {
        let m = |kv: Vec<(u64, Value)>| Value::Map(kv.into_iter().map(|(k, v)| (Value::Uint(k), v)).collect());
        assert_eq!(reason_text(&m(vec![(2, Value::Uint(14))])), ": the country changes only while the node is not in a network");
        assert_eq!(reason_text(&m(vec![(1, Value::Text("status".into()))])), " (status)");
        assert_eq!(reason_text(&m(vec![(1, Value::Text("settings/set".into())), (2, Value::Uint(20))])), " (settings/set): a legacy node (its radio is not managed by the app)");
        assert_eq!(reason_text(&m(vec![(2, Value::Uint(99))])), ": reason 99");
        assert_eq!(reason_text(&Value::Map(vec![])), "");
    }

    #[test]
    fn net_record_persist_steps() {
        let r = NetRecord {
            net_id: [0xab; 16],
            mesh_id: "bm-abababababab".into(),
            channel: 40,
            bw: 4,
            sae: "A".repeat(24),
            net_root: [7; 32],
            netcfg: vec![1],
            members: vec![2],
            secrets: vec![3],
        };
        let p = persist_step(&r, 1, "pending");
        assert_eq!(p.kind, OwnerKind::PersistNet);
        assert_eq!(p.rel, format!("net/{}", "ab".repeat(16)));
        assert_eq!(p.generation, 1);
        assert_eq!(p.aad, store::aad(&p.rel, 1)); // the AAD binds path + generation (design §3)
        let v = cbor::decode(&p.record).unwrap();
        assert_eq!(v.get(1).and_then(Value::as_bytes), Some(&[0xab; 16][..]));
        assert_eq!(v.get(5).and_then(Value::as_text), Some("A".repeat(24).as_str()));
        assert_eq!(v.get(10).and_then(Value::as_text), Some("pending"));
        assert!(p.detail.is_empty(), "the record's secrets never go into display text");
        let a = persist_step(&r, 2, "applied");
        assert_eq!(a.aad, store::aad(&a.rel, 2));
        assert_eq!(cbor::decode(&a.record).unwrap().get(10).and_then(Value::as_text), Some("applied"));
        assert_eq!(join_state_text(&JoinState::OtherNetwork), "network: the node is in ANOTHER network — stopped");
    }

    #[test]
    fn make_network_needs_a_login() {
        let rec = cbor::encode(&Value::Map(vec![
            (Value::Uint(1), Value::Text("e61551410cfd538e24".into())),
            (Value::Uint(4), Value::Bytes(vec![8; 5])),
            (Value::Uint(5), Value::Bytes(vec![5; 32])),
        ]));
        let (mut s, _) = OwnerSession::start(rec, vec![4; 65], 244).unwrap();
        assert!(s.request_make_network("n".into(), 40, vec![4; 65], vec![4; 65]).is_err(), "no verified node_cert yet");
        assert!(s.check_network().is_err());
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
