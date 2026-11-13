//! The claim path for Dart (design v8.5.1 §5.1): the QR, one claim attempt over BLE (sans-IO: Dart moves the frames),
//! and the records it leaves. Long-term keys stay in Kotlin: sig_enc is signed there (owner key, allow-listed input)
//! and passed in; records are sealed there (Keystore AES-GCM) with the AAD from here, then written by the Rust store.

use batman_proto::cbor::{self, Value};
use batman_proto::claimflow::{Action, Claim, End, Input, Pending};
use batman_proto::flow::ClaimFinish;
use batman_proto::{sig, store};

/// The claim QR (`batman-provhelper qr`): hex of CBOR {1: device_id (18 lower-case hex), 2: K (32 bytes)}. Strict:
/// anything else is refused (a QR that is not ours never starts a handshake).
pub struct ClaimQr {
    pub device_id: String,
    pub k: Vec<u8>,
}

pub fn parse_claim_qr(text: String) -> Result<ClaimQr, String> {
    let raw = hex_decode(text.trim()).ok_or("QR 碼內容不是 16 進位文字")?;
    let v = cbor::decode(&raw).map_err(|e| format!("QR 碼內容看不懂（{e}）"))?;
    let Value::Map(m) = &v else { return Err("QR 碼格式不對（not a map）".into()) };
    if m.len() != 2 {
        return Err("QR 碼格式不對（只能有欄位 1 和 2）".into());
    }
    let id = v.get(1).and_then(Value::as_text).ok_or("QR 碼缺少節點編號")?;
    if id.len() != 18 || !id.bytes().all(|c| c.is_ascii_digit() || (b'a'..=b'f').contains(&c)) {
        return Err("QR 碼裡的節點編號格式不對".into());
    }
    let k = v.get(2).and_then(Value::as_bytes).ok_or("QR 碼缺少認領金鑰")?;
    if k.len() != 32 {
        return Err("QR 碼裡的認領金鑰長度不對".into());
    }
    Ok(ClaimQr { device_id: id.to_string(), k: k.to_vec() })
}

fn hex_decode(s: &str) -> Option<Vec<u8>> {
    if s.len() % 2 != 0 {
        return None;
    }
    (0..s.len()).step_by(2).map(|i| u8::from_str_radix(s.get(i..i + 2)?, 16).ok()).collect()
}

/// CTRL characteristic {1:1, 2:0, 3: node frame size, 4: max message} -> the frame limit min(CTRL 3, MTU - 3).
pub fn frame_limit(ctrl: Vec<u8>, mtu: u32) -> Result<u32, String> {
    let v = cbor::decode(&ctrl).map_err(|e| format!("看不懂節點的連線參數（CTRL：{e}）"))?;
    let n = v.get(3).and_then(Value::as_uint).ok_or("節點的連線參數不完整（CTRL key 3 missing）")?;
    let lim = n.min(mtu.saturating_sub(3) as u64);
    if lim < 20 {
        return Err(format!("藍牙連線的封包太小，無法傳輸（{lim}：CTRL {n}，MTU {mtu}）"));
    }
    Ok(lim as u32)
}

/// sig_enc's input ("batman-owner-enc-v1" ‖ owner_enc_pub); Kotlin signs it with the owner key.
pub fn owner_enc_sign_input(owner_enc_pub: Vec<u8>) -> Result<Vec<u8>, String> {
    let p: [u8; 65] = owner_enc_pub.try_into().map_err(|_| "手機金鑰格式不對（owner_enc_pub is not 65 bytes）")?;
    Ok(sig::owner_enc_input(&p))
}

/// Keystore's DER ECDSA signature -> the 64-byte low-s form the node checks.
pub fn der_to_raw(der: Vec<u8>) -> Result<Vec<u8>, String> {
    sig::der_to_raw_low_s(&der).map(|r| r.to_vec()).map_err(|e| format!("{e:?}"))
}

pub fn pending_path(device_id: &str) -> String {
    format!("claim-pending/{device_id}")
}
pub fn node_path(device_id: &str) -> String {
    format!("node/{device_id}")
}

/// The next generation of a record and its AAD (final path + generation, design §3) for Kotlin's seal.
pub struct SealParams {
    pub generation: u64,
    pub aad: Vec<u8>,
}

pub fn store_seal_params(dir: String, rel: String) -> Result<SealParams, String> {
    let g = store::Store::new(dir).next_generation(&rel).map_err(|e| format!("{e:?}"))?;
    Ok(SealParams { generation: g, aad: store::aad(&rel, g) })
}

/// Write a sealed record (atomic, synced: design §3). The pending must be on disk before `pending_persisted`.
pub fn store_write_sealed(dir: String, rel: String, generation: u64, sealed: Vec<u8>) -> Result<(), String> {
    store::Store::new(dir).write(&rel, generation, &sealed).map_err(|e| format!("{e:?}"))
}

pub fn store_remove(dir: String, rel: String) -> Result<(), String> {
    store::Store::new(dir).remove(&rel).map_err(|e| format!("{e:?}"))
}

/// What this phone already holds for a device id, checked before a claim sends or writes anything (design §5.1: a
/// device id seen again is never overwritten without asking). A node record wins over a pending (§5.1: both = the
/// node record counts).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ClaimTarget {
    /// nothing: a new claim
    Nothing,
    /// only `claim-pending/<id>`: an unfinished claim (§5.2)
    Pending,
    /// `node/<id>` only
    Node,
    /// `node/<id>` and `claim-pending/<id>`: the node record counts (254-app-claim-noover R2); the dialog says there
    /// also is an unfinished claim
    NodeAndPending,
}

/// Both paths are read (254-app-claim-noover R5): a record that cannot be read (unknown version, not a record) at
/// either is an error: the claim stops (fail-closed).
pub fn claim_target(dir: String, device_id: String) -> Result<ClaimTarget, String> {
    let s = store::Store::new(dir);
    let node = s.read(&node_path(&device_id)).map_err(|e| format!("{e:?}"))?.is_some();
    let pending = s.read(&pending_path(&device_id)).map_err(|e| format!("{e:?}"))?.is_some();
    Ok(match (node, pending) {
        (true, true) => ClaimTarget::NodeAndPending,
        (true, false) => ClaimTarget::Node,
        (false, true) => ClaimTarget::Pending,
        (false, false) => ClaimTarget::Nothing,
    })
}

/// Whether an opened pending record is for this QR (same device id and K). Then claiming again is the recovery's
/// first step (§5.2-1: on NX success the new pending, with the same K, replaces the old one); otherwise the user is
/// asked first, and the old pending is copied aside before it is replaced (254-app-claim-noover R4).
pub fn pending_matches_qr(record: Vec<u8>, qr: &ClaimQr) -> Result<bool, String> {
    let v = cbor::decode(&record).map_err(|_| "手機裡的認領紀錄看不懂（pending is not CBOR）")?;
    let id = v.get(1).and_then(Value::as_text).ok_or("手機裡的認領紀錄不完整（pending key 1）")?;
    let k = v.get(2).and_then(Value::as_bytes).ok_or("手機裡的認領紀錄不完整（pending key 2）")?;
    Ok(id == qr.device_id && k == &qr.k[..])
}

/// Keep a copy of the record at `rel` before it is replaced (254-app-claim-noover R1 / R4 / R8): `node/<id>` ->
/// `forgotten-node/<id>-<n>`, `claim-pending/<id>` -> `forgotten-pending/<id>-<n>`; the record itself is not changed.
/// Returns whether there was one to copy. The app keeps the copies only (no restore in this version).
pub fn store_keep_copy(dir: String, rel: String) -> Result<bool, String> {
    let kind = match rel.split('/').next() {
        Some("node") => FORGOTTEN_NODE,
        Some("claim-pending") => FORGOTTEN_PENDING,
        _ => return Err("App 內部錯誤（no copy kind for this record）".into()),
    };
    store::Store::new(dir).copy_aside(&rel, kind).map(|c| c.is_some()).map_err(|e| format!("{e:?}"))
}

pub(crate) const FORGOTTEN_NODE: &str = "forgotten-node";
pub(crate) const FORGOTTEN_PENDING: &str = "forgotten-pending";

fn pending_record(p: &Pending) -> Vec<u8> {
    cbor::encode(&Value::Map(vec![
        (Value::Uint(1), Value::Text(p.device_id.clone())),
        (Value::Uint(2), Value::Bytes(p.k.to_vec())),
        (Value::Uint(3), Value::Bytes(p.node_cert.clone())),
        (Value::Uint(4), Value::Bytes(p.dac_der.clone())),
        (Value::Uint(5), Value::Bytes(p.ecdh_pub.to_vec())),
        (Value::Uint(6), Value::Bytes(p.owner_pub.to_vec())),
        (Value::Uint(7), Value::Bytes(p.owner_enc_pub.to_vec())),
    ]))
}

/// What Dart does next (a plain enum + a struct: no generated sealed classes on the Dart side).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum StepKind {
    /// write `frames` to RX, in order, each after the previous write's callback
    Write,
    /// seal + write `record` at `path`, sync, then call `pending_persisted` (nothing goes out before)
    PersistPending,
    /// claimed: seal + write `record` (the node record) at `path`, THEN remove `pending_path` (design §5.1)
    Claimed,
    /// over without credentials: `detail` = the design's case (+ reason); the pending (if any) stays
    Ended,
}

pub struct ClaimStep {
    pub kind: StepKind,
    pub frames: Vec<Vec<u8>>,
    pub path: String,
    pub record: Vec<u8>,
    pub pending_path: String,
    /// never a secret (shown, logged)
    pub detail: String,
}

impl ClaimStep {
    fn new(kind: StepKind) -> ClaimStep {
        ClaimStep { kind, frames: vec![], path: String::new(), record: vec![], pending_path: String::new(), detail: String::new() }
    }
    /// `text`: what happened, for the user; `code`: the design's case (+ detail) in parentheses, for support.
    fn ended(text: &str, code: &str, detail: String) -> ClaimStep {
        let d = if detail.is_empty() { format!("{text}（{code}）") } else { format!("{text}（{code}：{detail}）") };
        ClaimStep { detail: d, ..ClaimStep::new(StepKind::Ended) }
    }
}

const BROKEN: &str = "連線或資料出錯，這次的紀錄先保留";

#[flutter_rust_bridge::frb(opaque)]
pub struct ClaimSession {
    claim: Claim,
    pending: Option<Pending>,
}

impl ClaimSession {
    /// Starts an attempt: the first step is the msg1 frames.
    #[flutter_rust_bridge::frb(sync)]
    pub fn start(qr: &ClaimQr, owner_pub: Vec<u8>, owner_enc_pub: Vec<u8>, sig_enc: Vec<u8>, frame_limit: u32) -> Result<(ClaimSession, ClaimStep), String> {
        let input = Input {
            device_id: qr.device_id.clone(),
            k: qr.k.clone().try_into().map_err(|_| "QR 碼裡的認領金鑰長度不對")?,
            owner_pub: owner_pub.try_into().map_err(|_| "手機金鑰格式不對（owner_pub is not 65 bytes）")?,
            owner_enc_pub: owner_enc_pub.try_into().map_err(|_| "手機金鑰格式不對（owner_enc_pub is not 65 bytes）")?,
            sig_enc: sig_enc.try_into().map_err(|_| "手機簽章格式不對（sig_enc is not 64 bytes）")?,
            frame_limit: frame_limit as usize,
        };
        let (claim, a) = Claim::start(input);
        let mut s = ClaimSession { claim, pending: None };
        let step = s.step(Some(a)).ok_or("App 內部錯誤（no first step）")?;
        Ok((s, step))
    }

    /// A frame received on TX; None = keep reading.
    #[flutter_rust_bridge::frb(sync)]
    pub fn on_frame(&mut self, frame: Vec<u8>) -> Option<ClaimStep> {
        let a = self.claim.on_frame(&frame);
        self.step(a)
    }

    /// The pending record is on disk: claim/begin goes out.
    #[flutter_rust_bridge::frb(sync)]
    pub fn pending_persisted(&mut self) -> Option<ClaimStep> {
        let a = self.claim.pending_persisted();
        self.step(a)
    }

    fn step(&mut self, a: Option<Action>) -> Option<ClaimStep> {
        Some(match a? {
            Action::Write(frames) => ClaimStep { frames, ..ClaimStep::new(StepKind::Write) },
            Action::PersistPending(p) => {
                let s = ClaimStep { path: pending_path(&p.device_id), record: pending_record(&p), ..ClaimStep::new(StepKind::PersistPending) };
                self.pending = Some(p);
                s
            }
            Action::Done(End::Finished(ClaimFinish::Claimed(c))) => match &self.pending {
                Some(p) => {
                    let rec = cbor::encode(&Value::Map(vec![
                        (Value::Uint(1), Value::Text(p.device_id.clone())),
                        (Value::Uint(2), Value::Bytes(p.k.to_vec())),
                        (Value::Uint(3), Value::Bytes(p.node_cert.clone())),
                        (Value::Uint(4), Value::Bytes(p.dac_der.clone())),
                        (Value::Uint(5), Value::Bytes(c.owner_tag_key.to_vec())),
                        (Value::Uint(6), Value::Bytes(c.adv_owner_key.to_vec())),
                        (Value::Uint(7), Value::Text(c.root_password.clone())),
                        (Value::Uint(8), Value::Text("claimed".into())),
                        // 254-app-claim-noover R2: the pending this record came from (informational)
                        (Value::Uint(9), Value::Bytes(batman_proto::claimflow::pending_link(&pending_record(p)).to_vec())),
                    ]));
                    ClaimStep {
                        path: node_path(&p.device_id),
                        record: rec,
                        pending_path: pending_path(&p.device_id),
                        detail: format!("認領成功：節點 …{} 現在由這支手機管理", &p.device_id[p.device_id.len() - 4..]),
                        ..ClaimStep::new(StepKind::Claimed)
                    }
                }
                None => ClaimStep::ended(BROKEN, "Broken", "手機沒有這次認領的暫存紀錄".into()),
            },
            Action::Done(End::Finished(f)) => {
                let text = match &f {
                    ClaimFinish::Claimed(_) => "認領成功", // handled above; never reached
                    ClaimFinish::Committed => "節點已記下認領，但沒有交回登入資料；這次的紀錄先保留，請稍後再試",
                    ClaimFinish::LegacyNoSshKey => "這是舊版節點，還沒設定 SSH 金鑰，無法用 App 認領",
                    ClaimFinish::BeginAgain => "認領逾時，請再按一次「認領」",
                    ClaimFinish::AppBug => "認領要求的格式不對（App 的問題，請回報）",
                    ClaimFinish::TryReplay => "認領被拒絕：QR 碼不符、節點已被別人認領，或之前的認領其實已經成功",
                    ClaimFinish::Unknown => "沒有收到明確的結果；這次的紀錄先保留，請稍後再試",
                };
                let code = match &f {
                    ClaimFinish::Claimed(_) => "Claimed".to_string(),
                    other => format!("{other:?}"),
                };
                ClaimStep::ended(text, &code, String::new())
            }
            Action::Done(End::Msg2Undecryptable) => ClaimStep::ended("連到的不是這台節點，或 QR 碼不對", "Msg2Undecryptable", String::new()),
            Action::Done(End::CertRejected(e)) => ClaimStep::ended("節點的身分證明沒有通過檢查，已停止", "CertRejected", format!("{e:?}")),
            Action::Done(End::BeginRefused(o)) => ClaimStep::ended("節點拒絕開始認領", "BeginRefused", format!("{o:?}")),
            Action::Done(End::Broken(s)) => ClaimStep::ended(BROKEN, "Broken", s),
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn qr_hex(id: &str, k: &[u8]) -> String {
        let b = cbor::encode(&Value::Map(vec![(Value::Uint(1), Value::Text(id.into())), (Value::Uint(2), Value::Bytes(k.to_vec()))]));
        b.iter().map(|x| format!("{x:02x}")).collect()
    }

    #[test]
    fn qr() {
        let q = parse_claim_qr(qr_hex("e61551410cfd538e24", &[7; 32])).unwrap();
        assert_eq!(q.device_id, "e61551410cfd538e24");
        assert_eq!(q.k, vec![7; 32]);
        assert!(parse_claim_qr(format!(" {} \n", qr_hex("e61551410cfd538e24", &[7; 32]))).is_ok());
        assert!(parse_claim_qr(qr_hex("E61551410CFD538E24", &[7; 32])).is_err());
        assert!(parse_claim_qr(qr_hex("e61551410cfd538e2", &[7; 32])).is_err());
        assert!(parse_claim_qr(qr_hex("e61551410cfd538e24", &[7; 31])).is_err());
        assert_eq!(parse_claim_qr("zz".into()).err().as_deref(), Some("QR 碼內容不是 16 進位文字"));
        assert!(parse_claim_qr("a0".into()).is_err());
    }

    #[test]
    fn ctrl_frame_limit() {
        // CTRL as provd encodes it (server.go:556-559): {1:1, 2:0, 3:244, 4:8192}
        let c = cbor::encode(&Value::Map(vec![
            (Value::Uint(1), Value::Uint(1)),
            (Value::Uint(2), Value::Uint(0)),
            (Value::Uint(3), Value::Uint(244)),
            (Value::Uint(4), Value::Uint(8192)),
        ]));
        assert_eq!(frame_limit(c.clone(), 517).unwrap(), 244);
        assert_eq!(frame_limit(c.clone(), 185).unwrap(), 182);
        assert_eq!(frame_limit(c.clone(), 23).unwrap(), 20); // the BLE default MTU still works
        assert!(frame_limit(c, 22).is_err());
    }

    #[test]
    fn seal_params_and_write() {
        let d = std::env::temp_dir().join(format!("bm-claim-{}", std::process::id()));
        let dir = d.to_string_lossy().to_string();
        let rel = pending_path("e61551410cfd538e24");
        let p = store_seal_params(dir.clone(), rel.clone()).unwrap();
        assert_eq!(p.aad, store::aad(&rel, p.generation));
        store_write_sealed(dir.clone(), rel.clone(), p.generation, vec![1, 2, 3]).unwrap();
        let p2 = store_seal_params(dir.clone(), rel.clone()).unwrap();
        assert!(p2.generation > p.generation, "the generation must move on after a write");
        store_remove(dir.clone(), rel).unwrap();
        let _ = std::fs::remove_dir_all(d);
    }

    // the node record joins the pending (DAC, node_cert, K) with the credentials of claim/finish; the order is the
    // design's (§5.1): node record first, then the pending goes. Negative: claimed with no pending -> Ended.
    #[test]
    fn claimed_builds_the_node_record_from_the_pending() {
        use batman_proto::flow::Creds;
        let q = ClaimQr { device_id: "e61551410cfd538e24".into(), k: vec![7; 32] };
        let (mut s, first) = ClaimSession::start(&q, vec![4; 65], vec![4; 65], vec![1; 64], 244).unwrap();
        assert_eq!(first.kind, StepKind::Write);
        let creds = || Creds { owner_tag_key: [5; 32], adv_owner_key: [6; 32], root_password: "pw".into() };
        let st = s.step(Some(Action::Done(End::Finished(ClaimFinish::Claimed(creds()))))).unwrap();
        assert!(st.kind == StepKind::Ended, "claimed without a pending: {}", st.detail);
        assert_eq!(st.detail, "連線或資料出錯，這次的紀錄先保留（Broken：手機沒有這次認領的暫存紀錄）");
        let p = Pending {
            device_id: q.device_id.clone(), k: [7; 32], node_cert: vec![9; 10], dac_der: vec![8; 5], ecdh_pub: [4; 65],
            owner_pub: [4; 65], owner_enc_pub: [4; 65],
        };
        let st = s.step(Some(Action::PersistPending(p))).unwrap();
        assert_eq!(st.kind, StepKind::PersistPending);
        assert_eq!(st.path, "claim-pending/e61551410cfd538e24");
        assert_eq!(cbor::decode(&st.record).unwrap().get(2).and_then(Value::as_bytes), Some(&[7u8; 32][..]));
        let st = s.step(Some(Action::Done(End::Finished(ClaimFinish::Claimed(creds()))))).unwrap();
        assert_eq!(st.kind, StepKind::Claimed);
        assert_eq!(st.path, "node/e61551410cfd538e24");
        assert_eq!(st.pending_path, "claim-pending/e61551410cfd538e24");
        assert_eq!(st.detail, "認領成功：節點 …8e24 現在由這支手機管理");
        let v = cbor::decode(&st.record).unwrap();
        assert_eq!(v.get(2).and_then(Value::as_bytes), Some(&[7u8; 32][..]), "K");
        assert_eq!(v.get(4).and_then(Value::as_bytes), Some(&[8u8; 5][..]), "pinned DAC");
        assert_eq!(v.get(5).and_then(Value::as_bytes), Some(&[5u8; 32][..]), "owner_tag_key");
        assert_eq!(v.get(7).and_then(Value::as_text), Some("pw"));
        let st = s.step(Some(Action::Done(End::Finished(ClaimFinish::TryReplay)))).unwrap();
        assert!(st.kind == StepKind::Ended, "{}", st.detail);
        assert_eq!(st.detail, "認領被拒絕：QR 碼不符、節點已被別人認領，或之前的認領其實已經成功（TryReplay）");
        let st = s.step(Some(Action::Done(End::Msg2Undecryptable))).unwrap();
        assert_eq!(st.detail, "連到的不是這台節點，或 QR 碼不對（Msg2Undecryptable）");
        let st = s.step(Some(Action::Done(End::Broken("lost".into())))).unwrap();
        assert_eq!(st.detail, "連線或資料出錯，這次的紀錄先保留（Broken：lost）");
    }

    // 254-app-claim-noover T1 (R5, R2): a device id seen again. nothing -> Nothing; only a pending -> Pending; a node
    // record -> Node, with a pending beside it -> NodeAndPending (the node record counts); a record that cannot be read
    // at EITHER path stops the claim (Err), never "Nothing" / "Node".
    #[test]
    fn t1_claim_target_reads_both_paths() {
        let d = std::env::temp_dir().join(format!("bm-target-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&d);
        let dir = d.to_string_lossy().to_string();
        let id = "e61551410cfd538e24".to_string();
        let s = store::Store::new(&d);
        assert_eq!(claim_target(dir.clone(), id.clone()).unwrap(), ClaimTarget::Nothing);
        s.write(&pending_path(&id), 1, b"p").unwrap();
        assert_eq!(claim_target(dir.clone(), id.clone()).unwrap(), ClaimTarget::Pending);
        assert_eq!(claim_target(dir.clone(), "e61551410cfd538e25".into()).unwrap(), ClaimTarget::Nothing, "another node");
        s.write(&node_path(&id), 1, b"n").unwrap();
        assert_eq!(claim_target(dir.clone(), id.clone()).unwrap(), ClaimTarget::NodeAndPending);
        std::fs::write(d.join(pending_path(&id)), b"garbage").unwrap();
        assert!(claim_target(dir.clone(), id.clone()).is_err(), "readable node + unreadable pending -> no claim");
        s.remove(&pending_path(&id)).unwrap();
        assert_eq!(claim_target(dir.clone(), id.clone()).unwrap(), ClaimTarget::Node);
        std::fs::write(d.join(node_path(&id)), b"garbage").unwrap();
        assert!(claim_target(dir.clone(), id.clone()).is_err(), "unreadable node -> no claim");
        assert!(claim_target(dir, "../x".into()).is_err());
        let _ = std::fs::remove_dir_all(d);
    }

    // §5.2-1: the same QR (device id and K) resumes an unfinished claim; another K, or another id, does not.
    #[test]
    fn pending_matches_only_the_same_qr() {
        let q = ClaimQr { device_id: "e61551410cfd538e24".into(), k: vec![7; 32] };
        let p = |id: &str, k: [u8; 32]| pending_record(&Pending {
            device_id: id.into(), k, node_cert: vec![9; 10], dac_der: vec![8; 5], ecdh_pub: [4; 65], owner_pub: [4; 65], owner_enc_pub: [4; 65],
        });
        assert!(pending_matches_qr(p("e61551410cfd538e24", [7; 32]), &q).unwrap());
        assert!(!pending_matches_qr(p("e61551410cfd538e24", [6; 32]), &q).unwrap(), "another K");
        assert!(!pending_matches_qr(p("e61551410cfd538e25", [7; 32]), &q).unwrap(), "another node");
        assert!(pending_matches_qr(vec![0xff], &q).is_err());
    }

    // 254-app-claim-noover R8 / T9: keep_copy copies node/ to forgotten-node/ and claim-pending/ to forgotten-pending/,
    // leaves the record itself, refuses other kinds; a phone holding only copies still has records (keys kept).
    #[test]
    fn keep_copy_keeps_the_record_and_its_copy() {
        let d = std::env::temp_dir().join(format!("bm-keep-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&d);
        let dir = d.to_string_lossy().to_string();
        let id = "e61551410cfd538e24".to_string();
        assert!(!store_keep_copy(dir.clone(), node_path(&id)).unwrap(), "nothing to copy");
        let s = store::Store::new(&d);
        s.write(&node_path(&id), 2, b"old").unwrap();
        s.write(&pending_path(&id), 1, b"pend").unwrap();
        assert!(store_keep_copy(dir.clone(), node_path(&id)).unwrap());
        assert!(store_keep_copy(dir.clone(), pending_path(&id)).unwrap());
        assert_eq!(claim_target(dir.clone(), id.clone()).unwrap(), ClaimTarget::NodeAndPending, "the records stay");
        assert_eq!(s.read("forgotten-node/e61551410cfd538e24-1").unwrap().unwrap().sealed, b"old");
        assert_eq!(s.read("forgotten-pending/e61551410cfd538e24-1").unwrap().unwrap().sealed, b"pend");
        assert!(store_keep_copy(dir.clone(), "net/abc".into()).is_err());
        s.remove(&node_path(&id)).unwrap();
        s.remove(&pending_path(&id)).unwrap();
        assert!(crate::api::simple::store_has_records(dir), "copies are records");
        let _ = std::fs::remove_dir_all(d);
    }

    // 254-app-claim-noover T10 (R2): the node record's key 9 is SHA-256 of the pending persisted in the same attempt;
    // beside a node record, that very pending is a leftover, a pending of another attempt (here: only K differs) is not,
    // and a node record without key 9 is unknown.
    #[test]
    fn t10_node_key9_links_the_pending_it_came_from() {
        use batman_proto::claimflow::pending_is_leftover;
        use batman_proto::flow::Creds;
        let q = ClaimQr { device_id: "e61551410cfd538e24".into(), k: vec![7; 32] };
        let (mut s, _) = ClaimSession::start(&q, vec![4; 65], vec![4; 65], vec![1; 64], 244).unwrap();
        let mk = |k: [u8; 32]| Pending {
            device_id: q.device_id.clone(), k, node_cert: vec![9; 10], dac_der: vec![8; 5], ecdh_pub: [4; 65], owner_pub: [4; 65],
            owner_enc_pub: [4; 65],
        };
        let persisted = s.step(Some(Action::PersistPending(mk([7; 32])))).unwrap().record;
        let creds = Creds { owner_tag_key: [5; 32], adv_owner_key: [6; 32], root_password: "pw".into() };
        let node = s.step(Some(Action::Done(End::Finished(ClaimFinish::Claimed(creds))))).unwrap().record;
        assert_eq!(pending_is_leftover(&node, &persisted), Some(true), "the same attempt: a leftover");
        assert_eq!(pending_is_leftover(&node, &pending_record(&mk([6; 32]))), Some(false), "only K differs: another attempt");
        let mut old = cbor::decode(&node).unwrap();
        if let Value::Map(m) = &mut old {
            m.retain(|(k, _)| k != &Value::Uint(9));
        }
        assert_eq!(pending_is_leftover(&cbor::encode(&old), &persisted), None, "an older node record: unknown");
    }
}
