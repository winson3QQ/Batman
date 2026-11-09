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
    let v = cbor::decode(plain).map_err(|e| format!("手機裡的節點資料損壞（{e}）"))?;
    Ok(Rec {
        device_id: v.get(1).and_then(Value::as_text).ok_or("手機裡的節點資料損壞（no device id）")?.to_string(),
        owner_tag_key: v.get(5).and_then(Value::as_bytes).and_then(|b| b.try_into().ok()).ok_or("手機裡的節點資料損壞（no owner_tag_key）")?,
        dac_der: v.get(4).and_then(Value::as_bytes).ok_or("手機裡的節點資料損壞（no DAC）")?.to_vec(),
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

// Display text (#254 app): plain Traditional Chinese for a non-technical user; protocol codes stay in parentheses for
// support. An answer's `detail` may start with one ASCII log marker "[TAG] " (NET_MADE, NET_STATE, SSH_DONE, REQ_FAIL)
// that Dart keeps in logcat and strips from the screen. No text ever carries a secret.

const NOT_LOGGED_IN: &str = "還沒連線到節點";
const NO_NETWORK: &str = "這次連線還沒有建立過網路";

fn net_made_text(r: &NetRecord) -> String {
    format!("[NET_MADE] 網路已建立：網路代號 {}，頻道 {}（{} MHz）", r.mesh_id, r.channel, r.bw)
}

/// Why a login attempt ended (logged; a msg2 that does not decrypt just means "try the next nearby node").
fn login_end_text(e: &End) -> String {
    match e {
        End::LoggedIn => "已登入".into(),
        End::Msg2Undecryptable => "不是這台節點（或節點剛認領完還沒準備好）".into(),
        End::CertRejected(c) => format!("節點的身分證明和手機記錄的不同，已中斷（CertRejected: {c:?}）"),
        End::AuthRefused(o) => format!("節點拒絕登入（AuthRefused: {o:?}）"),
        End::Broken(s) => format!("連線出錯（{s}）"),
    }
}

fn join_state_text(s: &JoinState) -> String {
    match s {
        JoinState::Applied { save_pending: false } => "網路：已套用，節點已加入網路".into(),
        JoinState::Applied { save_pending: true } => "網路：已套用（節點下次重新開機時會完成存檔）".into(),
        JoinState::InProgress => "網路：還在設定中，請一分鐘後再按「檢查網路」".into(),
        JoinState::NotApplied => "網路：沒有套用（或已還原），可以再建立一次同一個網路".into(),
        JoinState::OtherNetwork => "網路：這台節點已經在「另一個」網路裡，已停止".into(),
        JoinState::Unknown => "網路：目前還無法確定，請稍後再按「檢查網路」".into(),
    }
}

fn status_text(b: &Value) -> String {
    match status::decode_owner(b) {
        Ok(t) => t,
        Err(e) => format!("看不懂節點回傳的狀態：{e}"),
    }
}

/// What the user asked for, in words (a wire verb or an internal tag).
fn verb_text(verb: &str) -> String {
    match verb {
        "status" => "查看狀態".into(),
        "settings/get" => "查看設定".into(),
        "settings/set" => "更改設定".into(),
        "ssh_keys/set" => "加入 SSH 金鑰".into(),
        "info" | "info-net" => "檢查網路".into(),
        "network/join" => "建立網路".into(),
        "op/nonce" => "準備操作".into(),
        v => format!("操作（{v}）"),
    }
}

/// An error body's reason-code (CDDL; 254-p3-impl §3.1-8): E_UNSUPPORTED {1: verb, 2: reason} / E_REJECTED {2: reason}.
/// Only the code and its meaning: an error body never echoes the request. None when there is no reason-code.
fn reason_text(detail: &Value) -> Option<String> {
    Some(match detail.get(2).and_then(Value::as_uint)? {
        7 => "這台節點沒有這個設定項目".into(),
        13 => "節點不接受這個值，仍保留原本的設定".into(),
        14 => "要先讓節點離開網路才能改國家".into(),
        20 => "這是舊版節點，它的無線電不由 App 管理".into(),
        r => format!("節點拒絕了（原因 {r}）"),
    })
}

/// The meaning of a protocol error code (S/provd/session.go:39-50; flow.rs).
fn code_text(code: u64) -> &'static str {
    match code {
        flow::E_FORBIDDEN => "節點拒絕了這個操作",
        flow::E_BAD_OBJECT => "要求的格式不對（App 的問題，請回報）",
        flow::E_UNSUPPORTED => "這台節點的軟體還不支援這個功能",
        flow::E_REJECTED => "節點不接受這個值",
        flow::E_RATE => "嘗試太多次，請稍後再試",
        flow::E_LOCK_INCOMPLETE => "節點還沒準備好，請稍後再試",
        _ => "節點回報錯誤",
    }
}

/// One error answer as a line: what failed, why, then the codes (and the verb the node named) for support.
fn error_text(asked: &str, code: u64, detail: &Value) -> String {
    let why = reason_text(detail).unwrap_or_else(|| code_text(code).into());
    let reason = detail.get(2).and_then(Value::as_uint).map(|r| format!("，原因 {r}")).unwrap_or_default();
    let verb = detail.get(1).and_then(Value::as_text).map(|v| format!("，{v}")).unwrap_or_default();
    format!("[REQ_FAIL] {}沒有成功：{why}（代碼 {code}{reason}{verb}）", verb_text(asked))
}

fn settings_text(b: &Value) -> String {
    let mut out = vec![];
    if let Some(n) = b.get(1).and_then(Value::as_text) {
        out.push(format!("名稱 {n}"));
    }
    if let Some(c) = b.get(2).and_then(Value::as_text) {
        out.push(format!("國家 {c}"));
    }
    if let Some(h) = b.get(10) {
        let ch = h.get(1).and_then(Value::as_uint).map(|c| c.to_string()).unwrap_or("?".into());
        let bw = h.get(2).and_then(Value::as_uint).map(|c| format!("（{c} MHz）")).unwrap_or_default();
        out.push(format!("HaLow 無線電 頻道 {ch}{bw}"));
    }
    if let Some(s) = b.get(20).and_then(|a| a.get(1)).and_then(Value::as_text) {
        out.push(format!("給手機連的 Wi-Fi「{s}」"));
    }
    if out.is_empty() { "（讀不到任何設定）".into() } else { out.join("，") }
}

impl OwnerSession {
    /// Login to the node of this (opened) node record; the first step is the msg1 frames.
    #[flutter_rust_bridge::frb(sync)]
    pub fn start(record_plain: Vec<u8>, owner_pub: Vec<u8>, frame_limit: u32) -> Result<(OwnerSession, OwnerStep), String> {
        let r = parse_record(&record_plain)?;
        let op: [u8; 65] = owner_pub.try_into().map_err(|_| "手機金鑰格式不對（owner_pub is not 65 bytes）")?;
        let nr = NodeRecord { device_id: &r.device_id, owner_tag_key: &r.owner_tag_key, pinned_dac_der: &r.dac_der, owner_pub: &op };
        let (login, a) = Login::start(&nr, frame_limit as usize);
        let last4 = r.device_id[r.device_id.len().saturating_sub(4)..].to_string();
        let mut s = OwnerSession { st: St::Login(login), last4, owner_pub: op, node: None, net_id: None };
        let step = s.login_step(Some(a)).ok_or("App 內部錯誤（no first step）")?;
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
                Err(e) => return Some(OwnerStep::text(OwnerKind::Answer, format!("[REQ_FAIL] {}沒有成功：手機簽章出錯（{e:?}）", verb_text(verb)))),
            };
            let req = sig::with_owner_op(&body, verb, &raw).map_err(|e| format!("{e:?}")).and_then(|b| conn.request(verb, b).map_err(|e| format!("{e:?}")));
            return Some(match req {
                Ok((_, f)) => {
                    *asked = verb;
                    OwnerStep { frames: f, ..OwnerStep::new(OwnerKind::Write) }
                }
                Err(e) => OwnerStep::text(OwnerKind::Answer, format!("[REQ_FAIL] {}沒有成功：送不出去（{e}）", verb_text(verb))),
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
            _ => Err(NOT_LOGGED_IN.into()),
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
                    let Some((verb, body)) = op.as_ref() else {
                        return Some(OwnerStep::text(OwnerKind::Answer, "[REQ_FAIL] 操作沒有成功：App 內部錯誤（op/nonce without an operation）".into()));
                    };
                    let helper: Option<[u8; 32]> = b.get(1).and_then(Value::as_bytes).and_then(|x| x.try_into().ok());
                    let Some(helper) = helper else {
                        return Some(OwnerStep::text(OwnerKind::Answer, format!("[REQ_FAIL] {}沒有成功：節點的回應不完整（op/nonce without a 32-byte nonce）", verb_text(verb))));
                    };
                    match sig::owner_op_input(&conn.h(), &helper, verb, body) {
                        Ok(input) => Some(OwnerStep { sign_input: input, ..OwnerStep::new(OwnerKind::Sign) }),
                        Err(e) => Some(OwnerStep::text(OwnerKind::Answer, format!("[REQ_FAIL] {}沒有成功：無法準備要求（{e:?}）", verb_text(verb)))),
                    }
                }
                Ok(Some(Outcome::Ok(b))) if *asked == "info-net" => {
                    *asked = "";
                    let t = match self.net_id {
                        Some(id) => format!("[NET_STATE] {}", join_state_text(&flow::join_state(&b, &id))),
                        None => format!("[NET_STATE] {NO_NETWORK}"),
                    };
                    Some(OwnerStep::text(OwnerKind::Answer, t))
                }
                Ok(Some(Outcome::Ok(b))) => {
                    let t = match *asked {
                        "status" => status_text(&b),
                        "settings/get" => format!("目前設定：{}", settings_text(&b)),
                        "settings/set" => format!("設定已更新：{}", settings_text(&b)),
                        "ssh_keys/set" => "[SSH_DONE] 已加入 SSH 金鑰".into(),
                        v => format!("{}：完成", verb_text(v)),
                    };
                    *op = None;
                    Some(OwnerStep::text(OwnerKind::Answer, t))
                }
                Ok(Some(Outcome::Err { code, detail })) => {
                    // an owner-op refused at op/nonce is reported as the operation the user asked for
                    let what = op.take().map(|(v, _)| v).unwrap_or(*asked);
                    Some(OwnerStep::text(OwnerKind::Answer, error_text(what, code, &detail)))
                }
                Err(e) => {
                    self.st = St::Over;
                    Some(OwnerStep::text(OwnerKind::Ended, format!("連線出錯（{e:?}）")))
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
        let node = self.node.clone().ok_or("這次連線沒有驗證過節點身分，請重新連線")?;
        let enc: [u8; 65] = owner_enc_pub.try_into().map_err(|_| "手機金鑰格式不對（owner_enc_pub is not 65 bytes）")?;
        let adm: [u8; 65] = admin_pub.try_into().map_err(|_| "手機金鑰格式不對（admin_pub is not 65 bytes）")?;
        let conn = match std::mem::replace(&mut self.st, St::Over) {
            St::Conn { conn, .. } => conn,
            other => {
                self.st = other;
                return Err("還沒連線到節點（或上一個操作還沒結束）".into());
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
        self.join_step(Some(a)).ok_or_else(|| "App 內部錯誤（no first step）".into())
    }

    /// The net record was sealed and written (fsynced): network/join goes out (op/nonce first), or — after "applied" —
    /// the session is an owner session again.
    #[flutter_rust_bridge::frb(sync)]
    pub fn net_persisted(&mut self) -> Option<OwnerStep> {
        if let St::Join { applied: true, .. } = &self.st {
            let St::Join { join, rec, .. } = std::mem::replace(&mut self.st, St::Over) else { return None };
            self.st = St::Conn { conn: join.into_conn(), asked: "", op: None };
            let t = rec.map(|r| net_made_text(&r)).unwrap_or_default();
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
            return Err(NO_NETWORK.into());
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
                        OwnerStep::text(OwnerKind::Answer, "[NET_MADE] 網路已建立（但手機找不到這個網路的紀錄，請回報）".into())
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
                        OwnerStep::text(OwnerKind::Answer, "[REQ_FAIL] 建立網路沒有成功：節點連續兩次拒絕，不會再送第三次（代碼 3）".into())
                    }
                }
            }
            J::Done(JE::Replied(JoinReply::ReadInfo)) => {
                // 11 / other / lost: the outcome is unclear — read info against our net_id (the record stays pending)
                self.back_to_conn();
                match self.request_tagged("info", "info-net", Value::Map(vec![])) {
                    Ok(st) => st,
                    Err(e) => OwnerStep::text(OwnerKind::Answer, format!("[REQ_FAIL] 建立網路：結果不明，也讀不到節點的網路狀態，請按「檢查網路」（{e}）")),
                }
            }
            J::Done(JE::Replied(JoinReply::Rejected)) => {
                self.back_to_conn();
                OwnerStep::text(OwnerKind::Answer, "[REQ_FAIL] 建立網路沒有成功：節點說要求格式不對（App 的問題，請回報），下次會用新的網路編號".into())
            }
            J::Done(JE::BadChannel) => {
                self.back_to_conn();
                OwnerStep::text(OwnerKind::Answer, "[REQ_FAIL] 建立網路沒有成功：不支援這個頻道（只能選頻道 40 或 42）".into())
            }
            J::Done(e) => {
                self.back_to_conn();
                OwnerStep::text(OwnerKind::Answer, format!("[REQ_FAIL] 建立網路中斷（{e:?}）"))
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
            _ => Err(NOT_LOGGED_IN.into()),
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
                        return Some(OwnerStep::text(OwnerKind::Ended, "App 內部錯誤（logged in without a login）".into()));
                    }
                };
                self.node = login.verified().cloned();
                match login.into_conn() {
                    Some(conn) => {
                        self.st = St::Conn { conn, asked: "", op: None };
                        OwnerStep::text(OwnerKind::LoggedIn, format!("已連線到節點 …{}（擁有者）", self.last4))
                    }
                    None => OwnerStep::text(OwnerKind::Ended, "登入後沒有連線（no connection after login）".into()),
                }
            }
            Action::Done(e) => {
                self.st = St::Over;
                OwnerStep::text(OwnerKind::Ended, login_end_text(&e))
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
        assert_eq!(settings_text(&s), "名稱 BCM2711-6c89，國家 US，HaLow 無線電 頻道 42（2 MHz），給手機連的 Wi-Fi「BCM2711-6c89」");
        assert_eq!(settings_text(&Value::Map(vec![])), "（讀不到任何設定）");
        assert_eq!(status_text(&Value::Map(vec![])), "看不懂節點回傳的狀態：缺少節點狀態（欄位 1）");
    }

    #[test]
    fn reasons() {
        let m = |kv: Vec<(u64, Value)>| Value::Map(kv.into_iter().map(|(k, v)| (Value::Uint(k), v)).collect());
        assert_eq!(reason_text(&m(vec![(2, Value::Uint(14))])).as_deref(), Some("要先讓節點離開網路才能改國家"));
        assert_eq!(reason_text(&m(vec![(1, Value::Text("status".into()))])), None);
        assert_eq!(reason_text(&m(vec![(1, Value::Text("settings/set".into())), (2, Value::Uint(20))])).as_deref(), Some("這是舊版節點，它的無線電不由 App 管理"));
        assert_eq!(reason_text(&m(vec![(2, Value::Uint(99))])).as_deref(), Some("節點拒絕了（原因 99）"));
        assert_eq!(reason_text(&Value::Map(vec![])), None);
        // the whole error line: what failed, why, then the codes
        assert_eq!(error_text("settings/set", 11, &m(vec![(2, Value::Uint(14))])), "[REQ_FAIL] 更改設定沒有成功：要先讓節點離開網路才能改國家（代碼 11，原因 14）");
        assert_eq!(error_text("status", 6, &m(vec![(1, Value::Text("status".into()))])), "[REQ_FAIL] 查看狀態沒有成功：這台節點的軟體還不支援這個功能（代碼 6，status）");
        assert_eq!(
            error_text("settings/set", 6, &m(vec![(1, Value::Text("settings/set".into())), (2, Value::Uint(20))])),
            "[REQ_FAIL] 更改設定沒有成功：這是舊版節點，它的無線電不由 App 管理（代碼 6，原因 20，settings/set）"
        );
        assert_eq!(error_text("ssh_keys/set", 12, &Value::Map(vec![])), "[REQ_FAIL] 加入 SSH 金鑰沒有成功：嘗試太多次，請稍後再試（代碼 12）");
        assert_eq!(error_text("x/y", 99, &Value::Map(vec![])), "[REQ_FAIL] 操作（x/y）沒有成功：節點回報錯誤（代碼 99）");
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
        assert_eq!(join_state_text(&JoinState::OtherNetwork), "網路：這台節點已經在「另一個」網路裡，已停止");
        assert_eq!(net_made_text(&r), "[NET_MADE] 網路已建立：網路代號 bm-abababababab，頻道 40（4 MHz）");
        assert!(!net_made_text(&r).contains(&r.sae), "the SAE never goes into display text");
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
        assert_eq!(s.check_network().err().as_deref(), Some("這次連線還沒有建立過網路"));
        assert_eq!(s.request_status().err().as_deref(), Some("還沒連線到節點"));
        assert_eq!(login_end_text(&End::Msg2Undecryptable), "不是這台節點（或節點剛認領完還沒準備好）");
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
