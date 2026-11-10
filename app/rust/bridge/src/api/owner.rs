//! The owner path for Dart (design v8.5.1 §5.3 login, §5.5 status): one of this phone's nodes, from its sealed node
//! record (Kotlin opens it with the Keystore record key and the AAD from here), over BLE (sans-IO: Dart moves frames,
//! Kotlin signs auth/owner with the owner key). After login: `status` and `settings/get`, answered as display text.
//! The record's secrets (K, owner_tag_key, root password) stay in Rust; only the device id's last 4 go out.
//! Net records (254-app-join2 v7.1): make-network, join a second node, confirm network and forget joining all write
//! `net/<net_id>` by CAS (`store_write_cas` from the generation the record was read at); the plain record goes to
//! Kotlin only to be sealed and is never shown or logged.

use batman_proto::cbor::{self, Value};
use batman_proto::conn::Conn;
use batman_proto::envelope::Outcome;
use batman_proto::flow::{self, JoinReply, JoinState};
use batman_proto::join2flow::{self, Fail, Join2, Keep, Pre, Revert};
use batman_proto::joinflow::{self, Join};
use batman_proto::loginflow::{Action, End, Login, NodeRecord};
use batman_proto::netrec::{self, Confirm, MemberState, NetRec};
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

fn list_kind(dir: &str, kind: &str) -> Vec<String> {
    let mut v: Vec<String> = std::fs::read_dir(std::path::Path::new(dir).join(kind))
        .map(|d| d.filter_map(|e| e.ok()).map(|e| e.file_name().to_string_lossy().to_string()).filter(|n| !n.starts_with('.')).collect())
        .unwrap_or_default();
    v.sort();
    v
}

/// The device ids this phone holds a node record for (file names under node/; no record is opened).
pub fn list_nodes(dir: String) -> Vec<String> {
    list_kind(&dir, "node")
}

/// The net ids (hex) this phone holds a net record for (file names under net/; no record is opened).
pub fn list_nets(dir: String) -> Vec<String> {
    list_kind(&dir, "net")
}

const STALE_RECORD: &str = "紀錄已被別處更新，請重新開啟再試";

/// Write a sealed net record by compare-and-swap (join2 §3.1): only when its generation on disk is still
/// `expected_gen` (the generation it was read at; 0 = new), at `expected_gen + 1` (the generation it was sealed for).
/// Returns the new generation.
pub fn store_write_cas(dir: String, rel: String, expected_gen: u64, sealed: Vec<u8>) -> Result<u64, String> {
    store::Store::new(dir).write_cas(&rel, expected_gen, &sealed).map_err(|e| match e {
        store::Error::Stale { .. } => STALE_RECORD.to_string(),
        e => format!("{e:?}"),
    })
}

/// One member of a net record, for the screen (no secret).
pub struct MemberView {
    pub name: String,
    /// the device id's last 4 ("" when the record does not know it: a node from before join2)
    pub last4: String,
    pub joining: bool,
    /// the node's country before this phone changed it ("" = not changed)
    pub prev_country: String,
    /// SHA-256(DAC pub), hex: what `net_forget_joining` names a member by
    pub dac_hash: String,
}

/// A net record, for the screen (no secret: no SAE, net_root or signed objects).
pub struct NetView {
    pub net_id: String,
    pub mesh_id: String,
    pub applied: bool,
    pub country: String,
    pub members: Vec<MemberView>,
}

/// What an opened net record shows (choosing a network to join / confirm / forget in).
#[flutter_rust_bridge::frb(sync)]
pub fn net_summary(record_plain: Vec<u8>) -> Result<NetView, String> {
    let r = netrec::decode(&record_plain).map_err(|_| NET_DAMAGED.to_string())?;
    let country = r.netcfg().map(|c| c.country).unwrap_or_default();
    let members = r
        .members()
        .map_err(|_| NET_DAMAGED.to_string())?
        .into_iter()
        .map(|m| MemberView {
            last4: m.device_id.as_deref().map(|d| d[d.len().saturating_sub(4)..].to_string()).unwrap_or_default(),
            name: m.name,
            joining: m.state == MemberState::Joining,
            prev_country: m.prev_country.unwrap_or_default(),
            dac_hash: nodecert::hex_lower(&m.dac_pub_hash),
        })
        .collect();
    Ok(NetView { net_id: nodecert::hex_lower(&r.base.net_id), mesh_id: r.base.mesh_id, applied: r.state == netrec::APPLIED, country, members })
}

/// "Forget joining" (join2 §3.4): the record without that joining member, as a PersistNet step (seal, write by CAS
/// from `record_gen`); its `detail` is the line to show once written.
#[flutter_rust_bridge::frb(sync)]
pub fn net_forget_joining(record_plain: Vec<u8>, record_gen: u64, dac_hash: String) -> Result<OwnerStep, String> {
    let mut r = netrec::decode(&record_plain).map_err(|_| NET_DAMAGED.to_string())?;
    let h: [u8; 32] = (0..dac_hash.len())
        .step_by(2)
        .map(|i| dac_hash.get(i..i + 2).and_then(|x| u8::from_str_radix(x, 16).ok()))
        .collect::<Option<Vec<u8>>>()
        .and_then(|v| v.try_into().ok())
        .ok_or("App 內部錯誤（dac_hash is not 32 bytes of hex）")?;
    let name = r.members().ok().and_then(|l| l.into_iter().find(|m| m.dac_pub_hash == h)).map(|m| m.name).unwrap_or_default();
    let prev = netrec::forget_joining(&mut r, &h).map_err(|_| "這台節點不在「加入中」，沒有東西可以忘記".to_string())?;
    let want = r.netcfg().map(|c| c.country).unwrap_or_default();
    let mut st = persist_step(&r.base.net_id, netrec::encode(&r), record_gen);
    st.detail = match prev {
        Some(p) => format!("[JOIN_STATE] 已忘記加入中的節點 {name}；這台的國家可能仍是 {want}（原本是 {p}）"),
        None => format!("[JOIN_STATE] 已忘記加入中的節點 {name}"),
    };
    Ok(st)
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
    /// make-network / join / confirm: seal `record` with `aad`, write it with store_write_cas(rel, expected_gen) (it
    /// lands at `generation` = expected_gen + 1, fsynced), then `net_persisted()` — or `persist_failed()` when the
    /// write fails. Nothing is sent before (§3: the net record lands before network/join)
    PersistNet,
    /// join (join2 §3.3-3): ask the user the question in `detail`, then `country_confirmed(yes)`
    ConfirmCountry,
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
    /// PersistNet: the generation the record must still have on disk (store_write_cas)
    pub expected_gen: u64,
    /// an Answer after a join was applied: poll `request_link_check` (join2 §3.3-7)
    pub poll_link: bool,
}

impl OwnerStep {
    fn new(kind: OwnerKind) -> OwnerStep {
        OwnerStep {
            kind,
            frames: vec![],
            sign_input: vec![],
            detail: String::new(),
            record: vec![],
            rel: String::new(),
            generation: 0,
            aad: vec![],
            expected_gen: 0,
            poll_link: false,
        }
    }
    fn text(kind: OwnerKind, d: String) -> OwnerStep {
        OwnerStep { detail: d, ..OwnerStep::new(kind) }
    }
}

enum St {
    Login(Login),
    Conn { conn: Conn, asked: &'static str, op: Option<(&'static str, Value)> },
    /// make-network in flight (§5.4); `rec` once persisted (at generation `gen`); `applied` while the applied record
    /// is written; `resent` after the one NewNonce resend
    Join { join: Join, rec: Option<NetRec>, gen: u64, applied: bool, resent: bool },
    /// a second node joining (join2 §3.3); `mesh_id` for the texts
    Join2 { flow: Join2, mesh_id: String },
    Over,
}

#[flutter_rust_bridge::frb(opaque)]
pub struct OwnerSession {
    st: St,
    last4: String,
    owner_pub: [u8; 65],
    /// the node_cert verified at this login (dac_pub, ecdh_pub)
    node: Option<Verified>,
    /// the net record of the last make-network of this session and its generation on disk (`check_network`)
    made: Option<(NetRec, u64)>,
    /// the record a "confirm network" info read is for, and the generation it was read at
    confirm: Option<(NetRec, u64)>,
    /// a confirm-network write in flight: the record, its new generation and the line to show once written
    persist_then: Option<(NetRec, u64, String)>,
    /// seconds from the join reply to the outstanding link check
    link_secs: u64,
}

/// A PersistNet step for the net record (netrec: the plain CBOR holds SAE / net_root; sealed by Kotlin, never shown):
/// written by CAS from `expected_gen`, sealed for `expected_gen + 1`.
fn persist_step(net_id: &[u8; 16], record: Vec<u8>, expected_gen: u64) -> OwnerStep {
    let rel = format!("net/{}", nodecert::hex_lower(net_id));
    let generation = expected_gen + 1;
    OwnerStep { record, aad: store::aad(&rel, generation), rel, generation, expected_gen, ..OwnerStep::new(OwnerKind::PersistNet) }
}

// Display text (#254 app): plain Traditional Chinese for a non-technical user; protocol codes stay in parentheses for
// support. An answer's `detail` may start with one ASCII log marker "[TAG] " (NET_MADE, NET_STATE, SSH_DONE, REQ_FAIL)
// that Dart keeps in logcat and strips from the screen. No text ever carries a secret.

const NOT_LOGGED_IN: &str = "還沒連線到節點";
const NO_NETWORK: &str = "這次連線還沒有建立過網路";
const NET_DAMAGED: &str = "手機裡的網路資料損壞";

fn net_made_text(r: &joinflow::NetRecord) -> String {
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

fn confirm_text(c: &Confirm) -> String {
    let save = |p: &bool| if *p { "；存檔要等這台節點下次開機才完成" } else { "" };
    match c {
        Confirm::Upgraded { save_pending } => format!("[NET_STATE] 網路已確認：手機紀錄改為「已建立」{}", save(save_pending)),
        Confirm::Already { save_pending } => format!("[NET_STATE] 網路已確認（手機紀錄本來就是「已建立」）{}", save(save_pending)),
        Confirm::OtherVersion => "[NET_STATE] 節點上的網路版本和手機紀錄不同，紀錄沒有改變".into(),
        Confirm::NoChange(s) => format!("[NET_STATE] {}（手機紀錄沒有改變）", join_state_text(s)),
    }
}

fn country_question(have: &str, want: &str) -> String {
    format!("[COUNTRY] 這台的國家是 {have}，要改成 {want} 才能加入。要改嗎？")
}

const LATER: &str = "稍後在這台按「繼續加入」";

/// How a join of this node (join2 §3.3) ended, in words. Never a secret: the inputs are codes, countries and names.
fn join2_text(e: &join2flow::End, mesh_id: &str, last4: &str) -> String {
    use join2flow::End as E;
    let fail = "[REQ_FAIL] 加入網路沒有成功：";
    match e {
        E::Refused(Pre::Record) => format!("{fail}{NET_DAMAGED}"),
        E::Refused(Pre::NotApplied) => format!("{fail}這個網路還沒確認建立完成，請先在建立網路的節點按「確認網路」"),
        E::Refused(Pre::NotVerified) => format!("{fail}這次連線沒有驗證過節點身分，請重新連線"),
        E::Refused(Pre::NotAdmin) => format!("{fail}這個網路不是這支手機建立的（手機不是它的管理者）"),
        E::Refused(Pre::Full) => format!("{fail}這個網路已經有 {} 台節點（App 目前的上限）", netrec::MAX_MEMBERS),
        E::Applied { country_unverified, save_pending } => format!(
            "[JOINED] 已套用：節點 …{last4} 已加入網路 {mesh_id}{}{}",
            if *save_pending { "（存檔要等這台節點下次開機才完成）" } else { "" },
            if *country_unverified { "；國家未驗證（這台節點的軟體還不能回報國家）" } else { "" }
        ),
        E::Declined { have, want } => format!("[COUNTRY] 已取消：這台的國家仍是 {have}，沒有加入網路（這個網路用 {want}）"),
        E::CountryRefused { code, reason } => {
            let why = reason_text(&Value::Map(vec![(Value::Uint(2), Value::Uint(*reason))])).unwrap_or_default();
            format!("{fail}節點不讓改國家：{why}（代碼 {code}，原因 {reason}），沒有改動任何東西")
        }
        E::SettingsError(o) => match o {
            Outcome::Err { code, detail } => {
                let why = reason_text(detail).unwrap_or_else(|| code_text(*code).into());
                let reason = detail.get(2).and_then(Value::as_uint).map(|r| format!("，原因 {r}")).unwrap_or_default();
                format!("{fail}讀不到這台的國家：{why}（代碼 {code}{reason}）")
            }
            Outcome::Ok(_) => format!("{fail}讀不到這台的國家（節點的設定裡沒有國家）"),
        },
        E::Joining(Keep::Unclear7) => format!("[JOIN_STATE] 結果不明（節點可能正在更新或連線中斷），{LATER}"),
        E::Joining(Keep::Unclear) => format!("[JOIN_STATE] 結果不明（節點可能還在處理），{LATER}"),
        E::Joining(Keep::CountryUnknown) => format!("[COUNTRY] 國家狀態不明，{LATER}"),
        E::Joining(Keep::TwiceRefused) => format!("[JOIN_STATE] 節點連續兩次拒絕（代碼 3），不會再送；{LATER}"),
        E::Joining(Keep::NonceRefused(c)) => format!("[JOIN_STATE] 還沒送出：節點拒絕準備操作（代碼 {c}），{LATER}"),
        E::Failed(f, r) => {
            let head = match f {
                Fail::Rejected => "節點不接受這份網路設定（回覆碼 4）".to_string(),
                Fail::OtherNetwork => "這台已在別的網路".to_string(),
                Fail::NotApplied(c) => format!(
                    "節點沒有套用這個網路（回覆碼 {c}）。常見原因：國家或頻道不合、無線電被關、手動改過網路設定、節點剛更新完還沒穩定"
                ),
                Fail::NotSent(c) => format!("還沒送出：節點拒絕準備操作（代碼 {c}）"),
            };
            let tail = match r {
                Revert::NoChange => String::new(),
                Revert::Reverted { country } => format!("；國家已改回 {country}"),
                Revert::NotReverted { now, was } => {
                    format!("；國家可能仍是 {now}，原本是 {was}，未能改回；{LATER}或手動改回")
                }
            };
            format!("[JOIN_STATE] {head}{tail}")
        }
        E::AdminSignFailed => format!(
            "{fail}手機的管理者金鑰無法簽章，沒有寫入、沒有改國家、也沒有送出。若 App 重裝過，這支手機不能再加節點；新建網路會讓整隊分成兩個網路，舊節點要重燒"
        ),
        E::PersistFailed { applied: false, error: None } => format!("[REQ_FAIL] {STALE_RECORD}"),
        E::PersistFailed { applied: true, error: None } => {
            format!("[REQ_FAIL] {STALE_RECORD}（節點已套用；重新開啟後在這台按「繼續加入」就會補上紀錄）")
        }
        E::PersistFailed { applied: false, error: Some(why) } => format!("[REQ_FAIL] 手機儲存失敗（{why}）"),
        E::PersistFailed { applied: true, error: Some(why) } => {
            format!("[REQ_FAIL] 節點已套用，手機紀錄沒存好（手機儲存失敗：{why}），請在這台按「繼續加入」補上紀錄")
        }
        E::Broken(e) => format!("[REQ_FAIL] 加入網路中斷（{e}）"),
    }
}

fn link_text(s: &flow::LinkState) -> String {
    match s {
        flow::LinkState::Connected { neighbours } => format!("[CONNECTED] 已連上：看得到 {neighbours} 台鄰近節點"),
        flow::LinkState::NotYet => "[JOINED] 已套用，還沒看到其他成員（請確認其他節點已開機、在範圍內）".into(),
        flow::LinkState::Unknown => "[JOINED] 已套用，連線狀態未知".into(),
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
        "info-confirm" => "確認網路".into(),
        "status-link" => "查看連線狀態".into(),
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
        let mut s = OwnerSession {
            st: St::Login(login),
            last4,
            owner_pub: op,
            node: None,
            made: None,
            confirm: None,
            persist_then: None,
            link_secs: 0,
        };
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
        if let St::Join2 { flow, .. } = &mut self.st {
            let a = flow.signed(&der);
            return self.join2_step(a);
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
        if let St::Join2 { flow, .. } = &mut self.st {
            let a = flow.on_frame(&frame);
            return self.join2_step(a);
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
                Ok(Some(Outcome::Ok(b))) if *asked == "info-confirm" => {
                    // confirm network (join2 §3.2): the record read before the request, upgraded only on a match
                    *asked = "";
                    let Some((mut rec, g)) = self.confirm.take() else {
                        return Some(OwnerStep::text(OwnerKind::Answer, format!("[NET_STATE] {NO_NETWORK}")));
                    };
                    match netrec::confirm(&mut rec, &b) {
                        Ok(c @ Confirm::Upgraded { .. }) => {
                            let st = persist_step(&rec.base.net_id, netrec::encode(&rec), g);
                            self.persist_then = Some((rec, g + 1, confirm_text(&c)));
                            Some(st)
                        }
                        Ok(c) => Some(OwnerStep::text(OwnerKind::Answer, confirm_text(&c))),
                        Err(_) => Some(OwnerStep::text(OwnerKind::Answer, format!("[REQ_FAIL] {NET_DAMAGED}"))),
                    }
                }
                Ok(Some(o)) if *asked == "status-link" => {
                    *asked = "";
                    let s = match &o {
                        Outcome::Ok(b) => flow::link_state(b, self.link_secs),
                        Outcome::Err { .. } => flow::LinkState::Unknown,
                    };
                    Some(OwnerStep::text(OwnerKind::Answer, link_text(&s)))
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
            St::Join { .. } | St::Join2 { .. } | St::Over => None,
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
        self.st = St::Join { join, rec: None, gen: 0, applied: false, resent: false };
        self.join_step(Some(a)).ok_or_else(|| "App 內部錯誤（no first step）".into())
    }

    /// The net record was sealed and written (fsynced): network/join goes out (op/nonce first), or — after "applied" —
    /// the session is an owner session again.
    #[flutter_rust_bridge::frb(sync)]
    pub fn net_persisted(&mut self) -> Option<OwnerStep> {
        if let St::Join { applied: true, .. } = &self.st {
            let St::Join { join, rec, gen, .. } = std::mem::replace(&mut self.st, St::Over) else { return None };
            self.st = St::Conn { conn: join.into_conn(), asked: "", op: None };
            let t = rec.as_ref().map(|r| net_made_text(&r.base)).unwrap_or_default();
            self.made = rec.map(|r| (r, gen + 1));
            return Some(OwnerStep::text(OwnerKind::Answer, t));
        }
        if let St::Join { rec: Some(r), gen, .. } = &mut self.st {
            // the pending record landed
            *gen += 1;
            self.made = Some((r.clone(), *gen));
        }
        if let (St::Conn { .. }, true) = (&self.st, self.persist_then.is_some()) {
            // a confirm-network write landed
            let (rec, g, t) = self.persist_then.take()?;
            if self.made.as_ref().is_some_and(|(m, _)| m.base.net_id == rec.base.net_id) {
                self.made = Some((rec, g));
            }
            return Some(OwnerStep::text(OwnerKind::Answer, t));
        }
        if let St::Join2 { flow, .. } = &mut self.st {
            let a = flow.net_persisted();
            return self.join2_step(a);
        }
        let a = match &mut self.st {
            St::Join { join, .. } => join.net_persisted(),
            _ => None,
        };
        self.join_step(a)
    }

    /// The last PersistNet failed (sealing or store_write_cas): stop; nothing more is sent (join2 §3.1). `error`: what
    /// failed — exactly store_write_cas's "changed elsewhere" line for a generation mismatch, else the reason.
    #[flutter_rust_bridge::frb(sync)]
    pub fn persist_failed(&mut self, error: String) -> Option<OwnerStep> {
        let stale = error == STALE_RECORD;
        let why = if stale { STALE_RECORD.to_string() } else { format!("手機儲存失敗（{error}）") };
        if let St::Join2 { flow, .. } = &mut self.st {
            let a = flow.persist_failed((!stale).then_some(error));
            return self.join2_step(a);
        }
        if let St::Join { applied, .. } = &self.st {
            let t = if *applied {
                // the node applied; only the phone's "applied" copy is missing (the record stays pending on disk)
                format!("[REQ_FAIL] 節點已套用，手機紀錄沒存好（{why}），請按「確認網路」")
            } else {
                format!("[REQ_FAIL] 建立網路沒有成功：{why}")
            };
            self.back_to_conn();
            return Some(OwnerStep::text(OwnerKind::Answer, t));
        }
        self.persist_then.take().map(|_| OwnerStep::text(OwnerKind::Answer, format!("[REQ_FAIL] {why}")))
    }

    /// After an unclear make-network reply: "confirm network" (join2 §3.2) on the record this session made.
    #[flutter_rust_bridge::frb(sync)]
    pub fn check_network(&mut self) -> Result<OwnerStep, String> {
        let made = self.made.clone().ok_or(NO_NETWORK)?;
        self.confirm = Some(made);
        self.request_tagged("info", "info-confirm", Value::Map(vec![]))
    }

    /// "Confirm network" (join2 §3.2) for one of this phone's net records (opened by Kotlin; `record_gen` = the
    /// generation store_read_sealed gave): info key 10 / key 9 against the record; a match makes it applied.
    #[flutter_rust_bridge::frb(sync)]
    pub fn request_confirm_network(&mut self, record_plain: Vec<u8>, record_gen: u64) -> Result<OwnerStep, String> {
        let rec = netrec::decode(&record_plain).map_err(|_| NET_DAMAGED.to_string())?;
        if !matches!(self.st, St::Conn { .. }) {
            return Err(NOT_LOGGED_IN.into());
        }
        self.confirm = Some((rec, record_gen));
        self.request_tagged("info", "info-confirm", Value::Map(vec![]))
    }

    /// Join this (claimed, verified at this login) node to the network of an opened net record (join2 §3.3).
    /// `record_gen`: the generation store_read_sealed gave (every record write of the join is a CAS from it).
    /// admin_pub / owner_enc_pub: this phone's keys (Kotlin publicKeys).
    #[flutter_rust_bridge::frb(sync)]
    pub fn request_join_network(&mut self, record_plain: Vec<u8>, record_gen: u64, admin_pub: Vec<u8>, owner_enc_pub: Vec<u8>) -> Result<OwnerStep, String> {
        let adm: [u8; 65] = admin_pub.try_into().map_err(|_| "手機金鑰格式不對（admin_pub is not 65 bytes）")?;
        let enc: [u8; 65] = owner_enc_pub.try_into().map_err(|_| "手機金鑰格式不對（owner_enc_pub is not 65 bytes）")?;
        let conn = match std::mem::replace(&mut self.st, St::Over) {
            St::Conn { conn, .. } => conn,
            other => {
                self.st = other;
                return Err("還沒連線到節點（或上一個操作還沒結束）".into());
            }
        };
        let mesh_id = netrec::decode(&record_plain).map(|r| r.base.mesh_id).unwrap_or_default();
        let inp = join2flow::Input {
            record_plain,
            record_gen,
            node: self.node.clone(),
            node_name: format!("node-{}", self.last4),
            owner_pub: self.owner_pub,
            owner_enc_pub: enc,
            admin_pub: adm,
        };
        let (flow, a) = Join2::start(conn, inp);
        self.st = St::Join2 { flow, mesh_id };
        self.join2_step(Some(a)).ok_or_else(|| "App 內部錯誤（no first step）".into())
    }

    /// The user's answer to a ConfirmCountry step.
    #[flutter_rust_bridge::frb(sync)]
    pub fn country_confirmed(&mut self, yes: bool) -> Option<OwnerStep> {
        let a = match &mut self.st {
            St::Join2 { flow, .. } => flow.country_confirmed(yes),
            _ => None,
        };
        self.join2_step(a)
    }

    /// After an applied join: one `status` read, answered as connected / not yet / unknown (join2 §3.3-7).
    /// `secs_since_join`: seconds from the join reply to now.
    #[flutter_rust_bridge::frb(sync)]
    pub fn request_link_check(&mut self, secs_since_join: u64) -> Result<OwnerStep, String> {
        self.link_secs = secs_since_join;
        self.request_tagged("status", "status-link", Value::Map(vec![(Value::Uint(1), Value::Uint(0))]))
    }

    fn back_to_conn(&mut self) {
        match std::mem::replace(&mut self.st, St::Over) {
            St::Join { join, .. } => self.st = St::Conn { conn: join.into_conn(), asked: "", op: None },
            St::Join2 { flow, .. } => self.st = St::Conn { conn: flow.into_conn(), asked: "", op: None },
            other => self.st = other,
        }
    }

    fn join2_step(&mut self, a: Option<join2flow::Action>) -> Option<OwnerStep> {
        use join2flow::Action as A;
        Some(match a? {
            A::SignAdmin { tbs } => OwnerStep { sign_input: tbs, ..OwnerStep::new(OwnerKind::SignAdmin) },
            A::SignOwner { input } => OwnerStep { sign_input: input, ..OwnerStep::new(OwnerKind::Sign) },
            A::Write(frames) => OwnerStep { frames, ..OwnerStep::new(OwnerKind::Write) },
            A::PersistNet { net_id, plain, expected_gen } => persist_step(&net_id, plain, expected_gen),
            A::ConfirmCountry { have, want } => OwnerStep::text(OwnerKind::ConfirmCountry, country_question(&have, &want)),
            A::Done(e) => {
                let mesh_id = match &self.st {
                    St::Join2 { mesh_id, .. } => mesh_id.clone(),
                    _ => String::new(),
                };
                self.back_to_conn();
                let mut st = OwnerStep::text(OwnerKind::Answer, join2_text(&e, &mesh_id, &self.last4));
                // P2 (country not verified) has no status to read: "applied" only
                st.poll_link = matches!(e, join2flow::End::Applied { country_unverified: false, .. });
                st
            }
        })
    }

    fn join_step(&mut self, a: Option<joinflow::Action>) -> Option<OwnerStep> {
        use joinflow::{Action as J, End as JE};
        Some(match a? {
            J::SignAdmin { tbs } => OwnerStep { sign_input: tbs, ..OwnerStep::new(OwnerKind::SignAdmin) },
            J::SignOwner { input } => OwnerStep { sign_input: input, ..OwnerStep::new(OwnerKind::Sign) },
            J::Write(frames) => OwnerStep { frames, ..OwnerStep::new(OwnerKind::Write) },
            J::PersistNet(rec) => {
                // a new record (CAS from 0); no key 11 while pending (join2 §3.1)
                let r = NetRec::made(rec);
                let st = persist_step(&r.base.net_id, netrec::encode(&r), 0);
                if let St::Join { rec: x, .. } = &mut self.st {
                    *x = Some(r);
                }
                st
            }
            J::Done(JE::Replied(JoinReply::Applied)) => {
                // the applied state lands too, with key 11 = [this node applied] (join2 §3.1), then the session is an
                // owner session again
                let device_id = self.node.as_ref().map(|n| n.device_id.clone());
                let rec = match &mut self.st {
                    St::Join { rec: Some(r), gen, applied, .. } => {
                        *applied = true;
                        r.state = netrec::APPLIED.into();
                        let list = r.members().ok().map(|mut l| {
                            l.iter_mut().for_each(|m| m.device_id = device_id.clone());
                            l
                        });
                        r.list = list;
                        Some((netrec::encode(r), r.base.net_id, *gen))
                    }
                    _ => None,
                };
                match rec {
                    Some((plain, id, g)) => persist_step(&id, plain, g),
                    None => {
                        self.back_to_conn();
                        OwnerStep::text(OwnerKind::Answer, "[NET_MADE] 網路已建立（但手機找不到這個網路的紀錄，請回報）".into())
                    }
                }
            }
            J::Done(JE::Replied(JoinReply::NewNonce)) => {
                // 3 (nonce / signature): a new op/nonce, the same net_id, once (§5.4)
                let again = match std::mem::replace(&mut self.st, St::Over) {
                    St::Join { join, rec: Some(rec), gen, applied, resent: false } => {
                        let (j, a) = Join::resend(join.into_conn(), rec.base.clone());
                        self.st = St::Join { join: j, rec: Some(rec), gen, applied, resent: true };
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
                // 11 / other / lost: the outcome is unclear — "confirm network" on the pending record (join2 §3.2)
                self.back_to_conn();
                match self.check_network() {
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

    fn base() -> joinflow::NetRecord {
        joinflow::NetRecord {
            net_id: [0xab; 16],
            mesh_id: "bm-abababababab".into(),
            channel: 40,
            bw: 4,
            sae: SAE.into(),
            net_root: [7; 32],
            netcfg: vec![1],
            // a members v1 Sign1 whose creator is [0xa1; 32] (the signature is not checked on the phone's own record)
            members: batman_proto::cose::sign1(
                batman_proto::cose::CT_MEMBERS,
                &batman_proto::cose::member_list_payload(
                    &[0xab; 16],
                    1,
                    None,
                    &[batman_proto::cose::Member { dac_pub_hash: &[0xa1; 32], ecdh_pub: &[4; 65], name: "node-0001", owner_pub: &[4; 65], owner_enc_pub: &[4; 65] }],
                ),
                &[1; 64],
            ),
            secrets: vec![3],
        }
    }
    const SAE: &str = "Sae0123456789abcdefghijk";

    #[test]
    fn net_record_persist_steps() {
        let r = base();
        let p = persist_step(&r.net_id, netrec::encode(&NetRec::made(r.clone())), 0);
        assert_eq!(p.kind, OwnerKind::PersistNet);
        assert_eq!(p.rel, format!("net/{}", "ab".repeat(16)));
        assert_eq!((p.expected_gen, p.generation), (0, 1), "a new record: CAS from 0, sealed for 1");
        assert_eq!(p.aad, store::aad(&p.rel, 1)); // the AAD binds path + generation (design §3)
        let v = cbor::decode(&p.record).unwrap();
        assert_eq!(v.get(1).and_then(Value::as_bytes), Some(&[0xab; 16][..]));
        assert_eq!(v.get(5).and_then(Value::as_text), Some(SAE));
        assert_eq!(v.get(10).and_then(Value::as_text), Some("pending"));
        assert!(v.get(11).is_none(), "no member list while pending (join2 §3.1)");
        assert!(p.detail.is_empty(), "the record's secrets never go into display text");
        let a = persist_step(&r.net_id, vec![], 1);
        assert_eq!((a.expected_gen, a.generation, a.aad.clone()), (1, 2, store::aad(&a.rel, 2)));
        assert_eq!(join_state_text(&JoinState::OtherNetwork), "網路：這台節點已經在「另一個」網路裡，已停止");
        assert_eq!(net_made_text(&r), "[NET_MADE] 網路已建立：網路代號 bm-abababababab，頻道 40（4 MHz）");
        assert!(!net_made_text(&r).contains(&r.sae), "the SAE never goes into display text");
    }

    #[test]
    fn join2_texts_carry_no_secret() {
        use join2flow::End as E;
        let r = base();
        let root_hex = nodecert::hex_lower(&r.net_root);
        let ends = [
            E::Refused(Pre::Record),
            E::Refused(Pre::NotApplied),
            E::Refused(Pre::NotVerified),
            E::Refused(Pre::NotAdmin),
            E::Refused(Pre::Full),
            E::Applied { country_unverified: true, save_pending: true },
            E::Applied { country_unverified: false, save_pending: false },
            E::Declined { have: "JP".into(), want: "US".into() },
            E::CountryRefused { code: 11, reason: 14 },
            E::SettingsError(Outcome::Err { code: 12, detail: Value::Map(vec![]) }),
            E::Joining(Keep::Unclear7),
            E::Joining(Keep::Unclear),
            E::Joining(Keep::CountryUnknown),
            E::Joining(Keep::TwiceRefused),
            E::Joining(Keep::NonceRefused(12)),
            E::Failed(Fail::Rejected, Revert::NoChange),
            E::Failed(Fail::OtherNetwork, Revert::Reverted { country: "JP".into() }),
            E::Failed(Fail::NotApplied(11), Revert::NotReverted { now: "US".into(), was: "JP".into() }),
            E::AdminSignFailed,
            E::PersistFailed { applied: false, error: None },
            E::PersistFailed { applied: true, error: None },
            E::PersistFailed { applied: true, error: Some("Io(StorageFull)".into()) },
            E::Failed(Fail::NotSent(12), Revert::NoChange),
            E::Broken("Closed".into()),
        ];
        for e in &ends {
            let t = join2_text(e, &r.mesh_id, "2233");
            assert!(!t.contains(SAE) && !t.contains(&root_hex), "{t}");
            assert!(t.starts_with('['), "a log marker first: {t}");
        }
        assert_eq!(join2_text(&E::Applied { country_unverified: false, save_pending: false }, "bm-ab", "2233"), "[JOINED] 已套用：節點 …2233 已加入網路 bm-ab");
        assert_eq!(
            join2_text(&E::Failed(Fail::NotApplied(11), Revert::NotReverted { now: "US".into(), was: "JP".into() }), "", ""),
            "[JOIN_STATE] 節點沒有套用這個網路（回覆碼 11）。常見原因：國家或頻道不合、無線電被關、手動改過網路設定、節點剛更新完還沒穩定；國家可能仍是 US，原本是 JP，未能改回；稍後在這台按「繼續加入」或手動改回"
        );
        assert_eq!(join2_text(&E::Joining(Keep::Unclear7), "", ""), "[JOIN_STATE] 結果不明（節點可能正在更新或連線中斷），稍後在這台按「繼續加入」");
        assert_eq!(join2_text(&E::PersistFailed { applied: false, error: None }, "", ""), "[REQ_FAIL] 紀錄已被別處更新，請重新開啟再試");
        assert_eq!(join2_text(&E::PersistFailed { applied: false, error: Some("seal x".into()) }, "", ""), "[REQ_FAIL] 手機儲存失敗（seal x）");
        assert_eq!(country_question("JP", "US"), "[COUNTRY] 這台的國家是 JP，要改成 US 才能加入。要改嗎？");
        assert_eq!(link_text(&flow::LinkState::Connected { neighbours: 1 }), "[CONNECTED] 已連上：看得到 1 台鄰近節點");
    }

    #[test]
    fn summary_and_forget_show_no_secret() {
        let mut r = NetRec::made(base());
        r.state = netrec::APPLIED.into();
        let joining = netrec::Member {
            dac_pub_hash: [0xb2; 32],
            ecdh_pub: [4; 65],
            name: "node-2233".into(),
            owner_pub: [4; 65],
            owner_enc_pub: [4; 65],
            device_id: Some("aabbccddeeff00112233".into()),
            state: MemberState::Joining,
            prev_country: Some("JP".into()),
        };
        r.list = Some(vec![joining]);
        let plain = netrec::encode(&r);
        let v = net_summary(plain.clone()).unwrap();
        assert_eq!((v.mesh_id.as_str(), v.applied, v.members.len()), ("bm-abababababab", true, 1));
        assert_eq!((v.members[0].last4.as_str(), v.members[0].joining, v.members[0].prev_country.as_str()), ("2233", true, "JP"));
        let st = net_forget_joining(plain.clone(), 5, nodecert::hex_lower(&[0xb2; 32])).unwrap();
        assert_eq!((st.kind, st.expected_gen, st.generation), (OwnerKind::PersistNet, 5, 6));
        assert!(st.detail.starts_with("[JOIN_STATE] 已忘記加入中的節點 node-2233；這台的國家可能仍是"), "{}", st.detail);
        assert!(!st.detail.contains(SAE));
        assert!(netrec::decode(&st.record).unwrap().list.unwrap().is_empty());
        assert!(net_forget_joining(plain, 5, "zz".into()).is_err());
    }

    #[test]
    fn store_write_cas_says_stale_in_words() {
        let d = std::env::temp_dir().join(format!("bm-owner-cas-{}", std::process::id()));
        let dir = d.to_string_lossy().to_string();
        assert_eq!(store_write_cas(dir.clone(), "net/ab".into(), 0, vec![1]), Ok(1));
        assert_eq!(store_write_cas(dir.clone(), "net/ab".into(), 0, vec![2]), Err("紀錄已被別處更新，請重新開啟再試".into()));
        assert_eq!(list_nets(dir.clone()), vec!["ab".to_string()]);
        let _ = std::fs::remove_dir_all(d);
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
        assert!(s.request_join_network(vec![], 1, vec![4; 65], vec![4; 65]).is_err(), "not logged in yet");
        assert!(s.request_link_check(10).is_err());
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

    // ---- make-network: pending (CAS from 0) -> unclear reply -> confirm network (CAS from 1) -> check_network ----

    use batman_proto::{frame, noise};
    use p256::ecdsa::signature::Signer;

    const FL: usize = 244;

    struct FakeNode {
        t: snow::TransportState,
        rx: frame::Reassembler,
    }

    impl FakeNode {
        /// the request in `frames`: (id, verb)
        fn request(&mut self, frames: &[Vec<u8>]) -> (u64, String) {
            let mut msg = None;
            for f in frames {
                msg = self.rx.push(f).unwrap();
            }
            let mut buf = vec![0u8; 65535];
            let n = self.t.read_message(&msg.expect("a whole request"), &mut buf).unwrap();
            let req = cbor::decode(&buf[..n]).unwrap();
            (req.get(1).and_then(Value::as_uint).unwrap(), req.get(2).and_then(Value::as_text).unwrap().to_string())
        }
        fn answer(&mut self, id: u64, r: Result<Value, u64>) -> Vec<Vec<u8>> {
            let m = |kv: Vec<(u64, Value)>| Value::Map(kv.into_iter().map(|(k, v)| (Value::Uint(k), v)).collect());
            let env = match r {
                Ok(b) => m(vec![(1, Value::Uint(id)), (3, b), (4, Value::Uint(0))]),
                Err(c) => m(vec![(1, Value::Uint(id)), (4, Value::Uint(c)), (5, Value::Map(vec![]))]),
            };
            let mut buf = vec![0u8; 65535];
            let n = self.t.write_message(&cbor::encode(&env), &mut buf).unwrap();
            frame::split(&buf[..n], FL).unwrap()
        }
    }

    fn key(b: u8) -> p256::ecdsa::SigningKey {
        p256::ecdsa::SigningKey::from_slice(&[b; 32]).unwrap()
    }
    fn pub65(b: u8) -> [u8; 65] {
        key(b).verifying_key().to_sec1_point(false).as_bytes().try_into().unwrap()
    }
    fn der(b: u8, input: &[u8]) -> Vec<u8> {
        let s: p256::ecdsa::Signature = key(b).sign(input);
        s.to_der().as_bytes().to_vec()
    }

    fn logged_in() -> (OwnerSession, FakeNode) {
        let p: snow::params::NoiseParams = "Noise_NX_25519_ChaChaPoly_SHA256".parse().unwrap();
        let kp = snow::Builder::new(p.clone()).generate_keypair().unwrap();
        let pro = noise::prologue(noise::Mode::Nx, Some("x"));
        let mut r = snow::Builder::new(p).prologue(&pro).unwrap().local_private_key(&kp.private).unwrap().build_responder().unwrap();
        let mut i = noise::Initiator::new(noise::Mode::Nx, Some("x"), None).unwrap();
        let mut buf = vec![0u8; 65535];
        r.read_message(&i.msg1().unwrap(), &mut buf).unwrap();
        let n = r.write_message(b"cert", &mut buf).unwrap();
        let (_, sess) = i.read_msg2(&buf[..n]).unwrap();
        let node = Verified { device_id: "aabbccddeeff00112233".into(), dac_der: vec![], dac_pub: pub65(0x55), ecdh_pub: pub65(0x43), sn: [0; 9] };
        let s = OwnerSession {
            st: St::Conn { conn: Conn::new(sess, FL), asked: "", op: None },
            last4: "2233".into(),
            owner_pub: pub65(0x11),
            node: Some(node),
            made: None,
            confirm: None,
            persist_then: None,
            link_secs: 0,
        };
        (s, FakeNode { t: r.into_transport_mode().unwrap(), rx: frame::Reassembler::new(FL, 8192) })
    }

    /// drives steps until an Answer; network/join answers `join_code`, info answers ours applied
    fn drive(s: &mut OwnerSession, n: &mut FakeNode, mut st: OwnerStep, verbs: &mut Vec<String>, persists: &mut Vec<(u64, u64)>) -> String {
        loop {
            st = match st.kind {
                OwnerKind::SignAdmin => s.signed(der(0x66, &st.sign_input)).unwrap(),
                OwnerKind::Sign => s.signed(der(0x11, &st.sign_input)).unwrap(),
                OwnerKind::PersistNet => {
                    persists.push((st.expected_gen, st.generation));
                    assert_eq!(st.aad, store::aad(&st.rel, st.generation));
                    s.net_persisted().unwrap()
                }
                OwnerKind::Write => {
                    let (id, verb) = n.request(&st.frames);
                    let net_id = s.made.as_ref().map(|(r, _)| r.base.net_id.to_vec()).unwrap_or_default();
                    let r = match verb.as_str() {
                        "op/nonce" => Ok(Value::Map(vec![(Value::Uint(1), Value::Bytes(vec![0x6d; 32]))])),
                        "network/join" => Err(11),
                        "info" => Ok(Value::Map(vec![
                            (Value::Uint(9), Value::Uint(1)),
                            (Value::Uint(10), Value::Bytes(net_id)),
                            (Value::Uint(11), Value::Bool(false)),
                        ])),
                        v => panic!("unexpected {v}"),
                    };
                    verbs.push(verb);
                    let mut next = None;
                    for f in n.answer(id, r) {
                        next = s.on_frame(f).or(next);
                    }
                    next.expect("a step after the node's answer")
                }
                OwnerKind::Answer => return st.detail,
                k => panic!("unexpected step {k:?}"),
            };
        }
    }

    #[test]
    fn make_network_unclear_reply_confirms_with_chained_generations() {
        let (mut s, mut n) = logged_in();
        let (mut verbs, mut persists) = (vec![], vec![]);
        let st = s.request_make_network("home".into(), 40, pub65(0x22).to_vec(), pub65(0x66).to_vec()).unwrap();
        let t = drive(&mut s, &mut n, st, &mut verbs, &mut persists);
        // pending: a new record (CAS from 0 -> 1); join answers 11 -> confirm network: info -> applied (CAS 1 -> 2)
        assert_eq!(verbs, ["op/nonce", "network/join", "info"]);
        assert_eq!(persists, [(0, 1), (1, 2)]);
        assert_eq!(t, "[NET_STATE] 網路已確認：手機紀錄改為「已建立」");
        let (rec, g) = s.made.clone().unwrap();
        assert_eq!((g, rec.state.as_str()), (2, "applied"));
        assert_eq!(rec.members().unwrap()[0].state, MemberState::Applied);
        // check_network afterwards reads info against the made record at generation 2: nothing more to write
        let (mut verbs, mut persists) = (vec![], vec![]);
        let st = s.check_network().unwrap();
        let t = drive(&mut s, &mut n, st, &mut verbs, &mut persists);
        assert_eq!(verbs, ["info"]);
        assert!(persists.is_empty());
        assert_eq!(t, "[NET_STATE] 網路已確認（手機紀錄本來就是「已建立」）");
        assert_eq!(s.made.as_ref().unwrap().1, 2);
    }

    #[test]
    fn make_network_applied_write_failure_says_confirm_network() {
        let (mut s, mut n) = logged_in();
        let mut st = s.request_make_network("home".into(), 40, pub65(0x22).to_vec(), pub65(0x66).to_vec()).unwrap();
        let mut writes = 0;
        let t = loop {
            st = match st.kind {
                OwnerKind::SignAdmin => s.signed(der(0x66, &st.sign_input)).unwrap(),
                OwnerKind::Sign => s.signed(der(0x11, &st.sign_input)).unwrap(),
                // the pending write lands; the applied write (after the node applied) fails in storage
                OwnerKind::PersistNet if writes == 0 => {
                    writes += 1;
                    s.net_persisted().unwrap()
                }
                OwnerKind::PersistNet => s.persist_failed("Io(StorageFull)".into()).unwrap(),
                OwnerKind::Write => {
                    let (id, verb) = n.request(&st.frames);
                    let r = match verb.as_str() {
                        "op/nonce" => Ok(Value::Map(vec![(Value::Uint(1), Value::Bytes(vec![0x6d; 32]))])),
                        _ => Ok(Value::Map(vec![(Value::Uint(1), Value::Uint(0))])),
                    };
                    let mut next = None;
                    for f in n.answer(id, r) {
                        next = s.on_frame(f).or(next);
                    }
                    next.unwrap()
                }
                OwnerKind::Answer => break st.detail,
                k => panic!("unexpected step {k:?}"),
            };
        };
        assert_eq!(t, "[REQ_FAIL] 節點已套用，手機紀錄沒存好（手機儲存失敗（Io(StorageFull)）），請按「確認網路」");
        assert_eq!(s.made.as_ref().unwrap().1, 1, "the pending record (generation 1) is what is on disk");
        assert!(matches!(s.st, St::Conn { .. }), "an owner session again");
        assert_eq!(verb_text("info-confirm"), "確認網路");
    }

    #[test]
    fn join_record_write_failure_says_why() {
        use batman_proto::cose;
        let payload = cose::net_config_payload(&[0x5a; 16], 1, None, "home", "US", "bm-5a5a5a5a5a5a", 40, 4, &[pub65(0x66)]);
        let members = cose::member_list_payload(
            &[0x5a; 16],
            1,
            None,
            &[cose::Member { dac_pub_hash: &[0xa1; 32], ecdh_pub: &pub65(0x43), name: "node-0001", owner_pub: &pub65(0x11), owner_enc_pub: &pub65(0x22) }],
        );
        let mut r = NetRec::made(joinflow::NetRecord {
            net_id: [0x5a; 16],
            mesh_id: "bm-5a5a5a5a5a5a".into(),
            channel: 40,
            bw: 4,
            sae: SAE.into(),
            net_root: [7; 32],
            netcfg: cose::sign1(cose::CT_NETCFG, &payload, &[1; 64]),
            members: cose::sign1(cose::CT_MEMBERS, &members, &[1; 64]),
            secrets: vec![3],
        });
        r.state = netrec::APPLIED.into();
        for (error, want) in [
            ("Io(StorageFull)", "[REQ_FAIL] 手機儲存失敗（Io(StorageFull)）"),
            (STALE_RECORD, "[REQ_FAIL] 紀錄已被別處更新，請重新開啟再試"),
        ] {
            let (mut s, mut n) = logged_in();
            let mut st = s.request_join_network(netrec::encode(&r), 1, pub65(0x66).to_vec(), pub65(0x22).to_vec()).unwrap();
            let t = loop {
                st = match st.kind {
                    OwnerKind::SignAdmin => s.signed(der(0x66, &st.sign_input)).unwrap(),
                    OwnerKind::Write => {
                        let (id, verb) = n.request(&st.frames);
                        assert_eq!(verb, "settings/get");
                        let mut next = None;
                        for f in n.answer(id, Ok(Value::Map(vec![(Value::Uint(2), Value::Text("US".into()))]))) {
                            next = s.on_frame(f).or(next);
                        }
                        next.unwrap()
                    }
                    OwnerKind::PersistNet => {
                        assert_eq!((st.expected_gen, st.generation), (1, 2));
                        s.persist_failed(error.into()).unwrap()
                    }
                    OwnerKind::Answer => break st.detail,
                    k => panic!("unexpected step {k:?}"),
                };
            };
            assert_eq!(t, want);
            assert!(matches!(s.st, St::Conn { .. }), "an owner session again");
        }
    }
}
