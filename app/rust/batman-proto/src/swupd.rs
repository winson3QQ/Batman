//! Software update, the app side (docs/design/254-app-update.md v0.4 FROZEN), sans-IO. The operator picks two files
//! (D1: the manifest and the payload, told apart by content); every verb goes over the BLE owner session; the payload
//! goes in ONE raw-socket HTTP PUT made by Kotlin (D3, D4). This module decides; the caller moves bytes:
//!   `Action::Send`   one BLE request (owner-ops: the caller does op/nonce + the owner signature), answer -> `on_reply`
//!   `Action::Wait`   sleep, then `resume`
//!   `Action::Upload` the PUT on the node's phone AP (D5), result -> `uploaded`; meanwhile `keepalive` every 10 s
//!   `Action::Show`   a screen; the operator's press -> `press` / `picked`
//!   `Action::Done`   the flow is over (the screen says how)
//! Rules: the node is the only source of truth (D7, D15: after ANY failure update/status is read first); the HTTP
//! answer is only "200" or "other" (D4); no state is written on the phone. Secrets (the AP passphrase and the upload
//! bearer from bulk/open) live in `Window` only, are never part of a text, and are zeroed when dropped.
//! Times are the caller's monotonic milliseconds (`now`).

use crate::cbor::{self, Value};
use crate::flow::{E_RATE, E_REJECTED, E_UNSUPPORTED};
use crate::invite::display_name;

pub const E_BUSY: u64 = 7;
pub const E_STORAGE: u64 = 10;

/// D1 / F3: a manifest is at most 64 KiB (decoded only below that)
pub const MANIFEST_MAX: usize = 64 * 1024;
pub const GZIP: [u8; 2] = [0x1f, 0x8b];
/// D14: update/check and update/apply wait at least 340 s (precheck-node 120 s, arm 180 s, provd's 330 s); others 15 s
pub const WAIT_LONG_MS: u64 = 340_000;
pub const WAIT_MS: u64 = 15_000;
/// §3.4: after a PUT that did not answer 200, wait 31 s (an interrupted PUT holds the upload slot up to 30 s, F12)
pub const PUT_FAIL_WAIT_MS: u64 = 31_000;
/// §3.4: the same verb again after 10 s, at most 3 sends
pub const RETRY_MS: u64 = 10_000;
pub const TRIES: u32 = 3;
/// U2: E_RATE -> once more after 10 s
pub const RATE_RETRY_MS: u64 = 10_000;
/// U6: update/status every 10 s during the upload (the BLE session must not idle out, F22)
pub const KEEPALIVE_MS: u64 = 10_000;
/// U8: status every 5 s while the node writes
pub const WRITE_POLL_MS: u64 = 5_000;
/// §3.5: after the AP is set, 16 / 21 again every 5 s for up to 30 s
pub const AP_RETRY_MS: u64 = 5_000;
pub const AP_RETRY_FOR_MS: u64 = 30_000;
/// U10 / D11: log in again every 10 s for up to 5 minutes; the trial is read every 30 s for up to 15 minutes
pub const RELOGIN_MS: u64 = 10_000;
pub const REBOOT_FOR_MS: u64 = 300_000;
pub const TRIAL_POLL_MS: u64 = 30_000;
pub const TRIAL_FOR_MS: u64 = 900_000;
/// §3.3: 0 without a reason after 2 / 3 / 4 was seen: read every 30 s for up to 2 minutes
pub const UNSURE_POLL_MS: u64 = 30_000;
pub const UNSURE_FOR_MS: u64 = 120_000;
/// the entry's status read refused with E_RATE (the status page read it a moment ago): again after 1.5 s, 3 times
pub const STATUS_RATE_MS: u64 = 1_500;
/// node strings shown: display_name, then at most this many characters (§7)
pub const SHOWN_MAX: usize = 64;
/// D13: the production release root key's fingerprint (16 hex). None until #255: a field build offers no update.
pub const PROD_TRUST: Option<&str> = None;

// ---- texts (§3, §4; the design's wording) -------------------------------------------------------------------

pub const T_TRUST_NONE: &str = "這台節點的軟體不能經 App 更新,只能用電腦(ssh)更新或重燒卡";
pub const T_TRUST_BAD: &str = "這台節點的更新設定損壞 — 請找維修人員";
pub const T_TRUST_FIELD: &str = "這版 App 還不能更新節點";
pub const T_BIND_FAILED: &str = "節點的上傳埠被佔用,請重開節點後再更新";
pub const T_CHECKING: &str = "節點正在檢查,最多約 6 分鐘,這段時間不能取消";
pub const T_CONFIRM: &str = "開始傳送後請留在這個畫面,不要離開、不要關螢幕。寫入開始後不能取消;寫好後舊版本的退路已失效。";
pub const T_SPECIFIER: &str = "手機會暫時離開目前的 Wi-Fi(TAK 會中斷),傳完自動回來";
pub const T_NO_WIFI: &str = "沒有連上節點的 Wi-Fi — 請確認手機 Wi-Fi 已開啟";
pub const T_UPLOADING: &str = "正在傳送更新檔,請留在這個畫面";
pub const T_WRITING: &str = "節點正在驗證並寫入新版,可以離開這個畫面";
pub const T_TAK: &str = "重開約 2 分鐘,全隊 TAK 中斷";
pub const T_REBOOTING: &str = "節點重新開機中…";
pub const T_TRIAL: &str = "試用中";
pub const T_REVERTED: &str = "新版不健康,已退回原本的版本";
pub const T_REVERTED_18: &str = "新版沒有完成試用,已回到原本的版本";
pub const T_LATER: &str = "請稍後在狀態頁確認";
pub const T_UNSURE: &str = "結果還不確定 — 1 分鐘後自動再看";
pub const T_NOT_DONE: &str = "這次更新沒有完成,目前版本沒變";
pub const T_LAST: &str = "上一次更新:";
pub const T_PUT_FAILED: &str = "傳送一直中斷 — 請靠近節點後再試";
/// P3 :517, as written
pub const T_REJECTED_UPLOAD: &str = "節點拒絕上傳檔:請重開節點;若仍失敗,可能有人在節點 Wi-Fi 上干擾,請換節點 Wi-Fi 密碼;換了仍失敗,只能重燒";
pub const T_NOT_BACK: &str = "節點還沒回來";
pub const T_NO_STATUS: &str = "讀不到更新狀態";
pub const T_NOT_MINE: &str = "這個更新不是這支手機開始的(或已經過期)— 請稍後再試";
pub const T_REPICK: &str = "請重新選 manifest 檔,就能套用已寫好的新版";
pub const T_AP_OFF: &str = "節點給手機連的 Wi-Fi 還沒設定(或被關閉),要先設定才能傳更新檔";
pub const T_IDLE: &str = "選手機裡的兩個檔(manifest 和更新檔)開始更新";
pub const T_CANCELLED: &str = "已取消,目前版本不變";
pub const T_BAD_WINDOW: &str = "節點的回應不完整,已停止 — 請再試一次";
pub const T_STATUS_UNREAD: &str = "讀不到節點的狀態 — 請重新整理";
pub const E_BUSY_TEXT: &str = "節點正在處理另一個更新(可能是另一支擁有者手機)— 請稍後再試";
pub const E_STORAGE_TEXT: &str = "節點的儲存區寫不進去,這次沒有開始 — 請重開節點後再試";
pub const E_RATE_TEXT: &str = "太快了,請稍等 10 秒再按";
pub const E_UNSUPPORTED_TEXT: &str = "這台節點的軟體太舊,不能經 App 更新";
pub const OTHER_TEXT: &str = "更新沒有成功 — 請再試一次;一直如此請找維修人員";

/// Where a reason-code was met: 15 / 21 / 23 read differently (§4).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Ctx {
    /// it is update/status's phase 0 reason (not a verb's refusal)
    pub status: bool,
    /// phase 2 was reached in this update (the writing began)
    pub written: bool,
    /// a manifest is at hand
    pub manifest: bool,
}

/// §4: a reason-code in words.
pub fn reason_text(r: u64, c: Ctx) -> String {
    match r {
        1 => "節點正在試用新版,等它確認(約 5 分鐘)後再更新",
        2 => "節點的設定還沒存好,不能更新 — 請重開節點;仍然如此請找維修人員",
        3 => "這個更新檔是給別種板子的",
        4 => "要先裝中間版本才能更新到這版",
        5 => "這版需要重燒卡,不能經 App 更新",
        6 => "不允許降回這個版本",
        8 => "節點的記憶體不夠放這個更新檔 — 請重開節點再試",
        11 => "更新檔內容與簽章不符 — 檔案可能不是同一份(請確認 manifest 和更新檔是一起產生的),或傳輸中被換掉;請重新選檔或重新上傳",
        12 => "節點有一個沒完成的網路變更 — 請等一下再試",
        15 if c.status => "上傳不完整,請重新上傳",
        15 => "這個更新不是這支手機開始的,或已超過 30 分鐘 — 請重新開始更新",
        16 => T_AP_OFF,
        17 => "節點的設定沒有存到最新 — 請重開節點後再試",
        18 => "新版沒有完成試用,節點已回到原本的版本",
        21 if c.written => "這次寫入失敗,舊版本的退路可能已失效,請再更新一次",
        21 => "節點現在無法寫入,請稍後再試",
        22 => "上次寫入沒有完成,退路已失效,請再更新一次",
        23 if c.manifest => "新版已寫入但沒有啟用(節點重開過),請重新更新",
        23 => "請重新選 manifest 檔;若節點重開過,要整個重新更新",
        24 => "這台節點的軟體不能經 App 更新,請用電腦(ssh)更新或重燒卡",
        _ => OTHER_TEXT,
    }
    .into()
}

/// §4: an error answer in words (E_REJECTED with a reason -> the reason; E_RATE is the second one's text).
pub fn error_text(code: u64, detail: &Value, c: Ctx) -> String {
    match code {
        E_REJECTED => match detail.get(2).and_then(Value::as_uint) {
            Some(r) => reason_text(r, c),
            None => OTHER_TEXT.into(),
        },
        E_BUSY => E_BUSY_TEXT.into(),
        E_STORAGE => E_STORAGE_TEXT.into(),
        E_RATE => E_RATE_TEXT.into(),
        E_UNSUPPORTED => E_UNSUPPORTED_TEXT.into(),
        _ => OTHER_TEXT.into(),
    }
}

/// a node / file string as shown: control and format characters (bidi included) replaced, at most 64 characters
pub fn shown(s: &str) -> String {
    display_name(s).chars().take(SHOWN_MAX).collect()
}

// ---- the manifest (D1, U1, T1) ----------------------------------------------------------------------------------

#[derive(Clone, Debug, PartialEq)]
pub struct Manifest {
    /// as picked; strict deterministic CBOR, so `cbor::encode(&value)` gives these bytes back
    pub bytes: Vec<u8>,
    pub value: Value,
    /// key 1, as shown (never a decision)
    pub version: String,
    pub size: u64,
    /// key 4: SHA-256(SHA256SUMS) — "ours" in update/status (§3.3)
    pub sha: [u8; 32],
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ManifestError {
    TooLarge,
    /// not one strict deterministic CBOR item (non-shortest, unsorted keys, trailing bytes, ...)
    NotCbor,
    NotMap,
    /// this key is missing or of the wrong type / length
    Key(u64),
}

/// U1: ≤ 64 KiB, strict CBOR map; key 1 / 2 tstr, 3 uint, 4 32 bytes, 5 bstr. Whether it can be trusted is the node's
/// call (it verifies the signatures); this only refuses what cannot be sent as an update-manifest.
pub fn parse_manifest(b: &[u8]) -> Result<Manifest, ManifestError> {
    if b.len() > MANIFEST_MAX {
        return Err(ManifestError::TooLarge);
    }
    let v = cbor::decode(b).map_err(|_| ManifestError::NotCbor)?;
    if !matches!(v, Value::Map(_)) {
        return Err(ManifestError::NotMap);
    }
    let version = v.get(1).and_then(Value::as_text).ok_or(ManifestError::Key(1))?;
    v.get(2).and_then(Value::as_text).ok_or(ManifestError::Key(2))?;
    let size = v.get(3).and_then(Value::as_uint).ok_or(ManifestError::Key(3))?;
    let sha: [u8; 32] = v.get(4).and_then(Value::as_bytes).and_then(|x| x.try_into().ok()).ok_or(ManifestError::Key(4))?;
    v.get(5).and_then(Value::as_bytes).ok_or(ManifestError::Key(5))?;
    Ok(Manifest { bytes: b.to_vec(), version: shown(version), size, sha, value: v })
}

/// One picked file as Kotlin read it: SAF statSize (-1 = unknown), its first bytes, and the whole file only when it
/// does not start with the gzip magic and is at most 64 KiB (nothing else is read).
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Picked {
    pub size: i64,
    pub head: Vec<u8>,
    pub data: Vec<u8>,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum PickError {
    /// not exactly two files
    Count,
    /// statSize -1
    SizeUnknown,
    /// neither starts with the gzip magic, and both are manifests
    BothManifest,
    /// no file starts with the gzip magic
    NotGzip,
    /// both start with the gzip magic
    NoManifest,
    Manifest(ManifestError),
    /// the payload's size is not the manifest's key 3
    Size,
}

/// D1 / D2: which one is the payload (by its first two bytes) and the manifest, checked on the phone (size + magic
/// only; the node verifies the content). Ok = (the payload's index, the manifest).
pub fn pick(files: &[Picked]) -> Result<(usize, Manifest), PickError> {
    if files.len() != 2 {
        return Err(PickError::Count);
    }
    if files.iter().any(|f| f.size < 0) {
        return Err(PickError::SizeUnknown);
    }
    let gz: Vec<usize> = (0..2).filter(|&i| files[i].head.starts_with(&GZIP)).collect();
    let as_manifest = |f: &Picked| {
        if f.size as u64 > MANIFEST_MAX as u64 {
            return Err(ManifestError::TooLarge);
        }
        parse_manifest(&f.data)
    };
    let (p, m) = match gz.as_slice() {
        [p] => (*p, as_manifest(&files[1 - *p]).map_err(PickError::Manifest)?),
        [] if files.iter().all(|f| as_manifest(f).is_ok()) => return Err(PickError::BothManifest),
        [] => return Err(PickError::NotGzip),
        _ => return Err(PickError::NoManifest),
    };
    if files[p].size as u64 != m.size {
        return Err(PickError::Size);
    }
    Ok((p, m))
}

/// U1: 「檔案不對:<哪一項>」
pub fn pick_text(e: PickError) -> String {
    let what = match e {
        PickError::Count => "請選兩個檔(manifest 和更新檔)".to_string(),
        PickError::SizeUnknown => "讀不到檔案大小".into(),
        PickError::BothManifest => "兩個都是 manifest,沒有更新檔".into(),
        PickError::NotGzip => "更新檔不是 gzip 格式".into(),
        PickError::NoManifest => "兩個都是更新檔,沒有 manifest".into(),
        PickError::Manifest(ManifestError::TooLarge) => "manifest 超過 64 KiB".into(),
        PickError::Manifest(ManifestError::NotCbor | ManifestError::NotMap) => "manifest 格式不對".into(),
        PickError::Manifest(ManifestError::Key(k)) => format!("manifest 的欄位 {k} 不對"),
        PickError::Size => "更新檔的大小和 manifest 寫的不同".into(),
    };
    format!("檔案不對:{what}")
}

// ---- the node's answers ---------------------------------------------------------------------------------------

/// update-progress (cddl update-progress)
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Progress {
    pub phase: u64,
    pub percent: u64,
    pub reason: Option<u64>,
    pub sha: Option<[u8; 32]>,
    /// key 5 as shown
    pub version: String,
}

pub fn progress(b: &Value) -> Option<Progress> {
    Some(Progress {
        phase: b.get(1).and_then(Value::as_uint)?,
        percent: b.get(2).and_then(Value::as_uint)?.min(100),
        reason: b.get(3).and_then(Value::as_uint),
        sha: b.get(4).and_then(Value::as_bytes).and_then(|x| x.try_into().ok()),
        version: b.get(5).and_then(Value::as_text).map(shown).unwrap_or_default(),
    })
}

fn text_key<'a>(m: &'a Value, k: &str) -> Option<&'a Value> {
    match m {
        Value::Map(e) => e.iter().find(|(key, _)| matches!(key, Value::Text(t) if t == k)).map(|(_, v)| v),
        _ => None,
    }
}

/// What status key 15 says for the update (§3.1): Ok(the trust line shown on dev builds) or Err(why not).
pub fn gate(status: &Value, dev_trust: bool) -> Result<String, String> {
    let k15 = status.get(15);
    let trust = k15.and_then(|m| text_key(m, "trust")).and_then(Value::as_text);
    let line = match trust {
        None | Some("none") => return Err(T_TRUST_NONE.into()),
        Some(t) if t.len() == 16 && t.bytes().all(|c| c.is_ascii_digit() || (b'a'..=b'f').contains(&c)) => {
            if dev_trust {
                format!("測試信任:{t}")
            } else if PROD_TRUST == Some(t) {
                String::new()
            } else {
                return Err(T_TRUST_FIELD.into());
            }
        }
        Some(_) => return Err(T_TRUST_BAD.into()),
    };
    if k15.and_then(|m| text_key(m, "http_bind_failed")) == Some(&Value::Bool(true)) {
        return Err(T_BIND_FAILED.into());
    }
    Ok(line)
}

/// §10-7: the node runs TAK when status key 15 "tenants" lists opentakserver
pub fn runs_tak(status: &Value) -> bool {
    status
        .get(15)
        .and_then(|m| text_key(m, "tenants"))
        .and_then(Value::as_text)
        .is_some_and(|t| t.split_whitespace().any(|w| w.starts_with("opentakserver:")))
}

/// bulk-open-resp (§5.2): 6 keys of the right types; else None (the caller stops and closes the window)
pub struct Window {
    pub ssid: String,
    pub pass: String,
    pub ip: std::net::Ipv4Addr,
    pub port: u16,
    pub bearer: [u8; 16],
}

impl Drop for Window {
    fn drop(&mut self) {
        wipe(&mut self.pass);
        self.bearer.fill(0);
    }
}

/// zero a secret string in place (Dart / Kotlin copies cannot be cleared: the honest limit, §7)
pub fn wipe(s: &mut String) {
    let mut b = std::mem::take(s).into_bytes();
    b.fill(0);
}

pub fn window(b: &Value) -> Option<Window> {
    let ssid = b.get(1).and_then(Value::as_text)?.to_string();
    let pass = b.get(2).and_then(Value::as_text)?.to_string();
    let ip = b.get(3).and_then(Value::as_text)?.parse().ok()?;
    let port = b.get(4).and_then(Value::as_uint).and_then(|p| u16::try_from(p).ok()).filter(|p| *p > 0)?;
    b.get(5).and_then(Value::as_uint)?;
    let bearer = b.get(6).and_then(Value::as_bytes).and_then(|x| x.try_into().ok())?;
    Some(Window { ssid, pass, ip, port, bearer })
}

// ---- the flow ---------------------------------------------------------------------------------------------------

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Verb {
    /// status {1: 0}: key 15 (trust, tenants, http_bind_failed)
    Status,
    /// info: key 4 (the running version, shown)
    Info,
    UpdStatus,
    Check,
    BulkOpen,
    BulkClose,
    Prepare,
    Apply,
}

impl Verb {
    pub fn wire(self) -> &'static str {
        match self {
            Verb::Status => "status",
            Verb::Info => "info",
            Verb::UpdStatus => "update/status",
            Verb::Check => "update/check",
            Verb::BulkOpen => "bulk/open",
            Verb::BulkClose => "bulk/close",
            Verb::Prepare => "update/prepare",
            Verb::Apply => "update/apply",
        }
    }
    /// F2: these four are owner-ops (op/nonce first, key 31)
    pub fn owner_op(self) -> bool {
        matches!(self, Verb::BulkOpen | Verb::BulkClose | Verb::Prepare | Verb::Apply)
    }
}

/// The answer to a Send.
#[derive(Clone, Debug, PartialEq)]
pub enum Reply {
    Ok(Value),
    Err { code: u64, detail: Value },
    /// no answer: the wait ran out, the link went away, or the request could not be sent / signed
    Lost,
    /// no owner session could be opened (the node is not reachable over BLE)
    NoLink,
}

/// The PUT's result (D4: only 200 or other; §5.2 Kotlin's four results).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Put {
    Ok200,
    Other,
    /// neither the current Wi-Fi nor the Specifier reached the node's AP (U5)
    NoNetwork,
    /// the operator refused the system dialog
    Denied,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Button {
    /// pick the two files (the caller opens the picker, then `picked`)
    Pick,
    /// U3: start sending
    Start,
    Cancel,
    /// 「套用並重開」
    Apply,
    /// U9: TAK runs here — apply anyway
    ApplyAnyway,
    /// §3.3 row 1: 「放棄這個上傳」 (bulk/close)
    Abandon,
    /// §3.5: to the node page's 「設定 Wi-Fi」 row (the caller's; the flow waits)
    SetAp,
    /// §3.5: the AP was set — go on
    ApDone,
    /// U5: try the Wi-Fi again
    Retry,
    /// U5: the system Wi-Fi panel (the caller's)
    WifiPanel,
    /// read the node again (the entry reads)
    Refresh,
}

#[derive(Clone, Debug, PartialEq, Eq, Default)]
pub struct Screen {
    pub text: String,
    /// the codes, for 「技術資訊」 (and the dev build's trust line)
    pub tech: String,
    pub percent: Option<u64>,
    pub buttons: Vec<Button>,
}

#[derive(Debug, PartialEq)]
pub enum Action {
    Send { verb: Verb, body: Value, wait_ms: u64, note: String },
    Wait { ms: u64, note: String, percent: Option<u64> },
    /// the PUT (D4 / D5); `payload` = the index into the picked files. The bearer is a secret: only for the PUT.
    Upload { ip: String, port: u16, bearer: [u8; 16], size: u64, payload: usize },
    Show(Screen),
    Done(Screen),
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Fail {
    Check,
    Open,
    /// prepare E_BUSY / outcome unknown / lost
    Prepare,
    /// prepare answered 15
    Prepare15,
    Apply,
    /// the PUT answered other (read after the 31 s wait)
    Put,
}

/// what an update/status answer is read for
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Read {
    Entry,
    Writing,
    Reboot,
    Unsure,
    /// after a re-check (apply 15 / 0 + 23)
    Recheck,
    Failed(Fail),
}

/// what a Wait resumes with
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Then {
    Status,
    Check,
    Open,
    Prepare,
    Read(Read),
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Out {
    Req(Verb, Option<Read>),
    Wait(Then),
    Upload,
    /// a screen is up
    Press,
    Over,
}

/// One software update of one node (one at a time in the app). Memory only (D7).
pub struct Flow {
    dev_trust: bool,
    out: Out,
    /// the bulk/close in flight: a cancel (true), or 「放棄這個上傳」 / a bad window (false, with the text after it)
    close: Option<(bool, &'static str)>,
    mf: Option<Manifest>,
    payload: usize,
    /// info key 4 as shown
    current: String,
    /// the trust line (dev builds) or ""
    trust: String,
    blocked: Option<String>,
    tak: bool,
    tak_ok: bool,
    asking_tak: bool,
    /// status 3: its sha (apply without a manifest at hand)
    written_sha: Option<[u8; 32]>,
    win: Option<Window>,
    /// a bulk/open was answered and no bulk/close or prepare followed
    window_open: bool,
    /// §3.4 counters: PUTs that were not 200; prepare 15 (ours) / 0 + 15 / 0 + 11 in a row; sends of one verb
    put_fails: u32,
    bad: u32,
    tries: u32,
    rate_once: bool,
    status_tries: u32,
    rechecked: bool,
    /// 2 / 3 / 4 seen in this run (§3.3: 0 without a reason then is "not sure yet")
    seen_busy: bool,
    /// phase 2 reached in this update (21: the two texts)
    written: bool,
    ap_until: Option<u64>,
    /// U10 / §3.3: when the reboot wait, the trial, the unsure wait and a lost link began
    since: u64,
    trial_since: Option<u64>,
    link_since: Option<u64>,
    /// the upload phase (D5: the Specifier network is kept until it ends)
    uploading: bool,
    keepalive: bool,
}

impl Flow {
    pub fn new(dev_trust: bool) -> Flow {
        Flow {
            dev_trust,
            out: Out::Over,
            close: None,
            mf: None,
            payload: 0,
            current: String::new(),
            trust: String::new(),
            blocked: None,
            tak: false,
            tak_ok: false,
            asking_tak: false,
            written_sha: None,
            win: None,
            window_open: false,
            put_fails: 0,
            bad: 0,
            tries: 0,
            rate_once: false,
            status_tries: 0,
            rechecked: false,
            seen_busy: false,
            written: false,
            ap_until: None,
            since: 0,
            trial_since: None,
            link_since: None,
            uploading: false,
            keepalive: false,
        }
    }

    /// §3.1: the read-only entry (status key 15, info key 4, update/status); also 「重新整理」.
    pub fn start(&mut self) -> Action {
        self.status_tries = 0;
        self.seen_busy = false;
        self.send(Verb::Status, None, "正在讀節點的狀態…")
    }

    /// D5: the upload phase is on — the caller keeps the Specifier network; once false it releases it.
    pub fn uploading(&self) -> bool {
        self.uploading
    }

    /// D5 / D8: the AP ssid and passphrase, only to join it with the Specifier (never shown, never logged)
    pub fn ap_credentials(&self) -> Option<(String, String)> {
        self.win.as_ref().map(|w| (w.ssid.clone(), w.pass.clone()))
    }

    pub fn manifest(&self) -> Option<&Manifest> {
        self.mf.as_ref()
    }

    fn ctx(&self, status: bool) -> Ctx {
        Ctx { status, written: self.written, manifest: self.mf.is_some() }
    }

    fn ours(&self, p: &Progress) -> bool {
        matches!((&self.mf, p.sha), (Some(m), Some(s)) if m.sha == s)
    }

    fn body(&self, verb: Verb) -> Value {
        let m = |kv: Vec<(u64, Value)>| Value::Map(kv.into_iter().map(|(k, v)| (Value::Uint(k), v)).collect());
        let sha = || self.mf.as_ref().map(|x| x.sha).or(self.written_sha).map(|s| Value::Bytes(s.to_vec())).unwrap_or(Value::Null);
        match verb {
            Verb::Status => m(vec![(1, Value::Uint(0))]),
            Verb::Check => m(vec![(1, self.mf.as_ref().map(|x| x.value.clone()).unwrap_or(Value::Null))]),
            Verb::BulkOpen => m(vec![(1, Value::Uint(0)), (2, sha())]),
            Verb::Prepare | Verb::Apply => m(vec![(1, sha())]),
            Verb::Info | Verb::UpdStatus | Verb::BulkClose => m(vec![]),
        }
    }

    fn send(&mut self, verb: Verb, read: Option<Read>, note: &str) -> Action {
        self.out = Out::Req(verb, read);
        let wait_ms = if matches!(verb, Verb::Check | Verb::Apply) { WAIT_LONG_MS } else { WAIT_MS };
        Action::Send { verb, body: self.body(verb), wait_ms, note: note.into() }
    }

    fn read(&mut self, r: Read) -> Action {
        self.send(Verb::UpdStatus, Some(r), "正在讀節點的更新狀態…")
    }

    fn wait(&mut self, ms: u64, then: Then, note: &str, percent: Option<u64>) -> Action {
        self.out = Out::Wait(then);
        Action::Wait { ms, note: note.into(), percent }
    }

    fn screen(&mut self, text: String, tech: String, buttons: Vec<Button>) -> Action {
        self.out = Out::Press;
        self.end_upload();
        Action::Show(self.decorate(Screen { text, tech, percent: None, buttons }))
    }

    fn done(&mut self, text: String) -> Action {
        self.out = Out::Over;
        self.end_upload();
        Action::Done(self.decorate(Screen { text, ..Screen::default() }))
    }

    /// the trust line goes with every screen of a dev build (D13)
    fn decorate(&self, mut s: Screen) -> Screen {
        if !self.trust.is_empty() {
            s.tech = if s.tech.is_empty() { self.trust.clone() } else { format!("{};{}", s.tech, self.trust) };
        }
        s
    }

    fn end_upload(&mut self) {
        self.uploading = false;
        self.keepalive = false;
        self.ap_until = None;
        self.win = None; // the Window zeroes the passphrase and the bearer when dropped
    }

    fn idle(&mut self, lead: &str) -> Action {
        let t = if lead.is_empty() { T_IDLE.to_string() } else { format!("{lead}\n{T_IDLE}") };
        self.screen(t, String::new(), vec![Button::Pick, Button::Refresh])
    }

    fn text_with_pick(&mut self, text: String, tech: String) -> Action {
        self.screen(text, tech, vec![Button::Pick, Button::Refresh])
    }

    /// U1: the two files Kotlin read. None = not now (nothing changed).
    pub fn picked(&mut self, files: &[Picked]) -> Option<Action> {
        if self.out != Out::Press || self.blocked.is_some() {
            return None;
        }
        Some(match pick(files) {
            Ok((p, m)) => {
                self.payload = p;
                self.mf = Some(m);
                self.written_sha = None;
                self.put_fails = 0;
                self.bad = 0;
                self.tries = 0;
                self.rate_once = false;
                self.rechecked = false;
                self.written = false;
                self.check()
            }
            Err(e) => self.text_with_pick(pick_text(e), String::new()),
        })
    }

    fn check(&mut self) -> Action {
        let v = self.mf.as_ref().map(|m| m.version.clone()).unwrap_or_default();
        self.send(Verb::Check, None, &format!("選好的版本:{v}(還沒驗證)\n{T_CHECKING}"))
    }

    fn open(&mut self) -> Action {
        self.send(Verb::BulkOpen, None, "正在打開節點的上傳…")
    }

    fn fail(&mut self, f: Fail) -> Action {
        self.read(Read::Failed(f))
    }

    /// a button of the current screen (U6: also Cancel during the upload). None = not now (nothing changed).
    pub fn press(&mut self, b: Button, now: u64) -> Option<Action> {
        let in_upload = matches!(self.out, Out::Upload | Out::Wait(Then::Read(Read::Failed(Fail::Put))) | Out::Wait(Then::Open));
        if b == Button::Cancel && in_upload {
            return Some(self.close(true, T_CANCELLED));
        }
        if self.out != Out::Press {
            return None;
        }
        let asking_tak = std::mem::take(&mut self.asking_tak);
        Some(match b {
            Button::Refresh => self.start(),
            Button::Start if self.mf.is_some() => {
                self.tries = 0;
                self.open()
            }
            Button::Retry if self.mf.is_some() => self.open(),
            Button::ApDone if self.mf.is_some() => {
                self.ap_until = Some(now + AP_RETRY_FOR_MS);
                self.tries = 0;
                self.open()
            }
            Button::Apply if self.tak && !self.tak_ok => {
                let a = self.screen(T_TAK.into(), String::new(), vec![Button::ApplyAnyway, Button::Cancel]);
                self.asking_tak = true;
                a
            }
            Button::Apply | Button::ApplyAnyway => {
                self.tak_ok = true;
                self.tries = 0;
                self.send(Verb::Apply, None, T_REBOOTING)
            }
            Button::Abandon => self.close(false, ""),
            Button::Cancel if asking_tak => self.written_screen(),
            // U5 cancel: the window is open on the node — close it
            Button::Cancel if self.window_open => self.close(true, T_CANCELLED),
            Button::Cancel => self.idle("已取消,沒有送出任何東西"),
            Button::Pick | Button::SetAp | Button::WifiPanel | Button::Start | Button::Retry | Button::ApDone => return None,
        })
    }

    fn close(&mut self, cancel: bool, after: &'static str) -> Action {
        self.close = Some((cancel, after));
        self.window_open = false;
        self.end_upload();
        self.send(Verb::BulkClose, None, "正在關閉節點的上傳…")
    }

    /// after a Wait. None = not waiting (nothing changed).
    pub fn resume(&mut self) -> Option<Action> {
        let Out::Wait(then) = self.out else { return None };
        Some(match then {
            Then::Status => self.send(Verb::Status, None, "正在讀節點的狀態…"),
            Then::Check => self.check(),
            Then::Open => self.open(),
            Then::Prepare => self.send(Verb::Prepare, None, T_WRITING),
            Then::Read(r) => self.read(r),
        })
    }

    /// U6: every 10 s during the upload; None = nothing to send now. Its answer goes to `on_reply` as usual (and the
    /// caller does not report the PUT before that answer is in).
    pub fn keepalive(&mut self) -> Option<Action> {
        if self.out != Out::Upload || self.keepalive {
            return None;
        }
        self.keepalive = true;
        Some(Action::Send { verb: Verb::UpdStatus, body: Value::Map(vec![]), wait_ms: WAIT_MS, note: String::new() })
    }

    /// the PUT result. None = not uploading (a cancel came first: the late result means nothing).
    pub fn uploaded(&mut self, r: Put) -> Option<Action> {
        if self.out != Out::Upload {
            return None;
        }
        self.keepalive = false;
        Some(match r {
            Put::Ok200 => {
                self.put_fails = 0;
                self.send(Verb::Prepare, None, T_WRITING)
            }
            Put::Other => {
                self.put_fails += 1;
                if self.put_fails >= TRIES {
                    return Some(self.text_with_pick(T_PUT_FAILED.into(), format!("PUT x{}", self.put_fails)));
                }
                self.wait(PUT_FAIL_WAIT_MS, Then::Read(Read::Failed(Fail::Put)), "傳送中斷,等節點放掉上一次的傳送(約 30 秒)…", None)
            }
            Put::NoNetwork | Put::Denied => self.screen(T_NO_WIFI.into(), String::new(), vec![Button::WifiPanel, Button::Retry, Button::Cancel]),
        })
    }

    /// the request got no answer (timeout / link lost / not sent)
    pub fn lost(&mut self, now: u64) -> Option<Action> {
        self.on_reply(Reply::Lost, now)
    }

    /// the node is not reachable over BLE
    pub fn no_link(&mut self, now: u64) -> Option<Action> {
        self.on_reply(Reply::NoLink, now)
    }

    /// the answer to the last Send (None: it was the keepalive, or nothing was asked)
    pub fn on_reply(&mut self, r: Reply, now: u64) -> Option<Action> {
        if self.keepalive && self.out == Out::Upload {
            self.keepalive = false;
            return None;
        }
        let Out::Req(verb, read) = self.out else { return None };
        Some(match (verb, read) {
            (Verb::Status, _) => self.on_status(r),
            (Verb::Info, _) => self.on_info(r),
            (Verb::UpdStatus, Some(rd)) => self.on_progress(rd, r, now),
            (Verb::UpdStatus, None) => return None,
            (Verb::Check, _) => self.on_check(r),
            (Verb::BulkOpen, _) => self.on_open(r, now),
            (Verb::BulkClose, _) => self.on_close(r),
            (Verb::Prepare, _) => self.on_prepare(r),
            (Verb::Apply, _) => self.on_apply(r, now),
        })
    }

    fn on_status(&mut self, r: Reply) -> Action {
        match r {
            Reply::Ok(b) => {
                self.tak = runs_tak(&b);
                match gate(&b, self.dev_trust) {
                    Ok(t) => {
                        self.trust = t;
                        self.blocked = None;
                    }
                    Err(why) => self.blocked = Some(why),
                }
                self.send(Verb::Info, None, "正在讀節點的版本…")
            }
            Reply::Err { code: E_RATE, .. } if self.status_tries + 1 < TRIES => {
                self.status_tries += 1;
                self.wait(STATUS_RATE_MS, Then::Status, "正在讀節點的狀態…", None)
            }
            Reply::NoLink => self.screen(T_NOT_BACK.into(), String::new(), vec![Button::Refresh]),
            _ => self.screen(T_STATUS_UNREAD.into(), String::new(), vec![Button::Refresh]),
        }
    }

    fn on_info(&mut self, r: Reply) -> Action {
        self.current = match &r {
            Reply::Ok(b) => b.get(4).and_then(Value::as_text).map(shown).unwrap_or_default(),
            _ => String::new(),
        };
        if let Some(why) = self.blocked.clone() {
            return self.screen(why, String::new(), vec![Button::Refresh]);
        }
        self.read(Read::Entry)
    }

    /// §3.3: what a read update/status means in general
    fn interpret(&mut self, p: Progress, now: u64) -> Action {
        let ver = p.version.clone();
        match p.phase {
            // our PUT was just cut: the slot is held up to 30 s (§3.4), then bulk/open again
            1 if self.ours(&p) => self.wait(PUT_FAIL_WAIT_MS, Then::Open, "等節點放掉上一次的傳送(約 30 秒)…", None),
            1 => self.screen(format!("節點上有一個上傳中的更新({ver})"), String::new(), vec![Button::Abandon, Button::Refresh]),
            2 => self.writing(p),
            3 => self.written_from(p),
            4 => {
                self.seen_busy = true;
                self.trial_since = Some(now);
                self.wait(TRIAL_POLL_MS, Then::Read(Read::Reboot), T_TRIAL, None)
            }
            5 => self.text_with_pick(format!("{T_LAST}更新完成:{ver}"), String::new()),
            6 => {
                let t = if p.reason == Some(18) { T_REVERTED_18 } else { T_REVERTED };
                self.text_with_pick(format!("{T_LAST}{t}"), String::new())
            }
            0 => match p.reason {
                Some(r @ (15 | 11)) if self.ours(&p) => {
                    self.bad += 1;
                    if self.bad >= TRIES {
                        return self.text_with_pick(T_REJECTED_UPLOAD.into(), format!("原因 {r}"));
                    }
                    self.open()
                }
                Some(23) if self.mf.is_some() && !self.rechecked => {
                    self.rechecked = true;
                    self.check()
                }
                Some(r) => {
                    let c = self.ctx(true);
                    self.text_with_pick(reason_text(r, c), format!("原因 {r}"))
                }
                None if self.seen_busy => {
                    self.since = now;
                    self.wait(UNSURE_POLL_MS, Then::Read(Read::Unsure), T_UNSURE, None)
                }
                None => self.idle(""),
            },
            _ => self.text_with_pick(OTHER_TEXT.into(), format!("phase {}", p.phase)),
        }
    }

    fn writing(&mut self, p: Progress) -> Action {
        self.seen_busy = true;
        self.written = true;
        self.window_open = false;
        self.end_upload();
        self.wait(WRITE_POLL_MS, Then::Read(Read::Writing), T_WRITING, Some(p.percent))
    }

    fn written_from(&mut self, p: Progress) -> Action {
        self.seen_busy = true;
        self.bad = 0;
        self.written_sha = p.sha;
        self.written_screen()
    }

    fn written_screen(&mut self) -> Action {
        self.screen("節點上有一個已寫好、還沒套用的更新".into(), String::new(), vec![Button::Apply, Button::Refresh])
    }

    fn on_progress(&mut self, rd: Read, r: Reply, now: u64) -> Action {
        let p = match &r {
            Reply::Ok(b) => progress(b),
            _ => None,
        };
        // U10: the reboot / trial reads go on while the link is gone (also an apply whose answer was lost)
        if rd == Read::Reboot || (rd == Read::Failed(Fail::Apply) && p.is_none()) {
            return self.on_reboot(p, now);
        }
        // U8: the node writes for minutes; a lost link is read again (the caller logs in again) for up to 5 minutes
        if rd == Read::Writing && p.is_none() {
            let from = *self.link_since.get_or_insert(now);
            if now.saturating_sub(from) < REBOOT_FOR_MS {
                return self.wait(WRITE_POLL_MS, Then::Read(Read::Writing), T_WRITING, None);
            }
        }
        self.link_since = None;
        let Some(p) = p else {
            let t = if r == Reply::NoLink { T_NOT_BACK } else { T_NO_STATUS };
            return self.screen(t.into(), String::new(), vec![Button::Refresh]);
        };
        let ours = self.ours(&p);
        let no_news = p.phase == 0 && p.reason.is_none();
        match rd {
            Read::Entry | Read::Recheck | Read::Reboot => self.interpret(p, now),
            Read::Writing => match (p.phase, p.reason) {
                (2, _) => self.writing(p),
                (3, _) => self.written_from(p),
                _ => self.interpret(p, now),
            },
            Read::Unsure => {
                if no_news && now.saturating_sub(self.since) >= UNSURE_FOR_MS {
                    self.text_with_pick(T_NOT_DONE.into(), String::new())
                } else if no_news {
                    self.out = Out::Wait(Then::Read(Read::Unsure));
                    Action::Wait { ms: UNSURE_POLL_MS, note: T_UNSURE.into(), percent: None }
                } else {
                    self.interpret(p, now)
                }
            }
            Read::Failed(f) => match f {
                Fail::Check if no_news => self.again(Then::Check),
                Fail::Open if no_news || (p.phase == 1 && ours) => self.again(Then::Open),
                Fail::Prepare if p.phase == 2 => self.writing(p),
                Fail::Prepare if p.phase == 1 && ours => self.again(Then::Prepare),
                Fail::Prepare15 if p.phase == 1 && ours => {
                    self.bad += 1;
                    if self.bad >= TRIES {
                        return self.text_with_pick(T_REJECTED_UPLOAD.into(), "原因 15".into());
                    }
                    self.wait(PUT_FAIL_WAIT_MS, Then::Open, "等節點放掉上一次的傳送(約 30 秒)…", None)
                }
                // prepare 15 with anything else: bulk/open again, not counted (its own 15 goes back to U2)
                Fail::Prepare15 => self.open(),
                Fail::Apply if p.phase == 3 => self.written_from(p),
                Fail::Apply if matches!(p.phase, 4..=6) => self.on_reboot(Some(p), now),
                Fail::Put if p.phase == 1 || no_news => self.open(),
                _ => self.interpret(p, now),
            },
        }
    }

    /// §3.4: the same verb again after 10 s, at most 3 sends; then E_BUSY text
    fn again(&mut self, then: Then) -> Action {
        self.tries += 1;
        if self.tries >= TRIES {
            return self.text_with_pick(E_BUSY_TEXT.into(), format!("x{}", self.tries));
        }
        self.wait(RETRY_MS, then, "節點忙碌中,10 秒後再試…", None)
    }

    /// U10: after apply — 4 trial, 5 done, 6 / 6 + 18 reverted; a gone link = still rebooting (5 minutes)
    fn on_reboot(&mut self, p: Option<Progress>, now: u64) -> Action {
        let Some(p) = p else {
            let from = *self.link_since.get_or_insert(now);
            if now.saturating_sub(from) >= REBOOT_FOR_MS {
                return self.done(T_LATER.into());
            }
            return self.wait(RELOGIN_MS, Then::Read(Read::Reboot), T_REBOOTING, None);
        };
        self.link_since = None;
        self.seen_busy = true;
        match p.phase {
            4 => {
                let from = *self.trial_since.get_or_insert(now);
                if now.saturating_sub(from) >= TRIAL_FOR_MS {
                    return self.done(T_LATER.into());
                }
                self.wait(TRIAL_POLL_MS, Then::Read(Read::Reboot), T_TRIAL, None)
            }
            5 => self.done(format!("更新完成:{}", p.version)),
            6 if p.reason == Some(18) => self.done(T_REVERTED_18.into()),
            6 => self.done(T_REVERTED.into()),
            // still the same boot, before the reboot
            3 if now.saturating_sub(self.since) < REBOOT_FOR_MS => self.wait(RELOGIN_MS, Then::Read(Read::Reboot), T_REBOOTING, None),
            _ => self.interpret(p, now),
        }
    }

    fn on_check(&mut self, r: Reply) -> Action {
        match r {
            Reply::Ok(b) => {
                self.tries = 0;
                if b.get(1) == Some(&Value::Bool(true)) {
                    if self.rechecked {
                        return self.read(Read::Recheck);
                    }
                    let v = self.mf.as_ref().map(|m| m.version.clone()).unwrap_or_default();
                    let from = if self.current.is_empty() { "目前的版本".to_string() } else { self.current.clone() };
                    return self.screen(format!("可以從 {from} 更新到 {v}\n{T_CONFIRM}"), String::new(), vec![Button::Start, Button::Cancel]);
                }
                let reason = b.get(2).and_then(Value::as_uint);
                let c = self.ctx(false);
                let t = reason.map(|x| reason_text(x, c)).unwrap_or_else(|| OTHER_TEXT.into());
                self.text_with_pick(t, reason.map(|x| format!("原因 {x}")).unwrap_or_default())
            }
            Reply::Err { code: E_RATE, .. } if !self.rate_once => {
                self.rate_once = true;
                self.wait(RATE_RETRY_MS, Then::Check, "太快了,10 秒後再送一次…", None)
            }
            Reply::Err { code: E_BUSY, .. } | Reply::Lost => self.fail(Fail::Check),
            Reply::Err { code, detail } => {
                let c = self.ctx(false);
                self.text_with_pick(error_text(code, &detail, c), tech(code, &detail))
            }
            Reply::NoLink => self.screen(T_NOT_BACK.into(), String::new(), vec![Button::Refresh]),
        }
    }

    fn on_open(&mut self, r: Reply, now: u64) -> Action {
        let ap_retry = self.ap_until.is_some_and(|u| now < u);
        match r {
            Reply::Ok(b) => {
                self.tries = 0;
                self.window_open = true;
                match (window(&b), self.mf.as_ref()) {
                    (Some(w), Some(m)) => {
                        let a = Action::Upload { ip: w.ip.to_string(), port: w.port, bearer: w.bearer, size: m.size, payload: self.payload };
                        self.win = Some(w);
                        self.uploading = true;
                        self.ap_until = None;
                        self.out = Out::Upload;
                        a
                    }
                    // §5.2: a malformed answer stops; the window is closed again
                    _ => self.close(false, T_BAD_WINDOW),
                }
            }
            Reply::Err { code: E_REJECTED, detail } => match detail.get(2).and_then(Value::as_uint) {
                Some(16 | 21) if ap_retry => self.wait(AP_RETRY_MS, Then::Open, "等節點的 Wi-Fi 起來…", None),
                Some(16) if self.ap_until.is_none() => {
                    self.screen(T_AP_OFF.into(), "原因 16".into(), vec![Button::SetAp, Button::ApDone, Button::Cancel])
                }
                // the pending is gone (expired / another boot): back to U2
                Some(15) => self.check(),
                _ => {
                    let c = self.ctx(false);
                    let t = error_text(E_REJECTED, &detail, c);
                    self.text_with_pick(t, tech(E_REJECTED, &detail))
                }
            },
            Reply::Err { code: E_BUSY, .. } | Reply::Lost => self.fail(Fail::Open),
            Reply::Err { code, detail } => {
                let c = self.ctx(false);
                self.text_with_pick(error_text(code, &detail, c), tech(code, &detail))
            }
            Reply::NoLink => self.screen(T_NOT_BACK.into(), String::new(), vec![Button::Refresh]),
        }
    }

    fn on_close(&mut self, r: Reply) -> Action {
        let (cancel, after) = self.close.take().unwrap_or((true, T_CANCELLED));
        if cancel {
            return self.done(T_CANCELLED.into());
        }
        if !after.is_empty() {
            return self.text_with_pick(after.into(), String::new());
        }
        match r {
            Reply::Ok(_) => self.idle("已放棄節點上的上傳"),
            Reply::Err { code: E_REJECTED, detail } if detail.get(2).and_then(Value::as_uint) == Some(15) => {
                self.screen(T_NOT_MINE.into(), "原因 15".into(), vec![Button::Refresh])
            }
            Reply::Err { code, detail } => {
                let c = self.ctx(false);
                self.screen(error_text(code, &detail, c), tech(code, &detail), vec![Button::Refresh])
            }
            Reply::Lost | Reply::NoLink => self.screen(T_NOT_BACK.into(), String::new(), vec![Button::Refresh]),
        }
    }

    fn on_prepare(&mut self, r: Reply) -> Action {
        match r {
            Reply::Ok(b) => {
                self.tries = 0;
                let p = progress(&b).unwrap_or(Progress { phase: 2, percent: 0, reason: None, sha: None, version: String::new() });
                self.writing(p)
            }
            Reply::Err { code: E_REJECTED, ref detail } if detail.get(2).and_then(Value::as_uint) == Some(15) => self.fail(Fail::Prepare15),
            Reply::Err { code: E_BUSY, .. } | Reply::Lost => self.fail(Fail::Prepare),
            Reply::Err { code, detail } => {
                let c = self.ctx(false);
                self.text_with_pick(error_text(code, &detail, c), tech(code, &detail))
            }
            Reply::NoLink => self.screen(T_NOT_BACK.into(), String::new(), vec![Button::Refresh]),
        }
    }

    fn on_apply(&mut self, r: Reply, now: u64) -> Action {
        match r {
            Reply::Ok(_) => {
                self.since = now;
                self.link_since = None;
                self.trial_since = None;
                self.seen_busy = true;
                self.wait(RELOGIN_MS, Then::Read(Read::Reboot), T_REBOOTING, None)
            }
            Reply::Err { code: E_REJECTED, ref detail } if detail.get(2).and_then(Value::as_uint) == Some(15) => {
                if self.mf.is_some() && !self.rechecked {
                    // §3.4 last rule: the pending is gone in this boot — check again, then 3 -> apply
                    self.rechecked = true;
                    self.check()
                } else if self.mf.is_none() {
                    self.text_with_pick(T_REPICK.into(), "原因 15".into())
                } else {
                    self.screen(T_NOT_MINE.into(), "原因 15".into(), vec![Button::Refresh])
                }
            }
            Reply::Err { code: E_BUSY, .. } | Reply::Lost | Reply::NoLink => {
                self.since = now;
                self.fail(Fail::Apply)
            }
            Reply::Err { code, detail } => {
                let c = self.ctx(false);
                self.screen(error_text(code, &detail, c), tech(code, &detail), vec![Button::Apply, Button::Refresh])
            }
        }
    }
}

/// 「技術資訊」: the codes
fn tech(code: u64, detail: &Value) -> String {
    match detail.get(2).and_then(Value::as_uint) {
        Some(r) => format!("代碼 {code},原因 {r}"),
        None => format!("代碼 {code}"),
    }
}
