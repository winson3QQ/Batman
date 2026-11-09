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
    let raw = hex_decode(text.trim()).ok_or("QR is not hex")?;
    let v = cbor::decode(&raw).map_err(|e| format!("QR is not CBOR: {e}"))?;
    let Value::Map(m) = &v else { return Err("QR is not a map".into()) };
    if m.len() != 2 {
        return Err("QR map must have exactly keys 1 and 2".into());
    }
    let id = v.get(1).and_then(Value::as_text).ok_or("QR key 1 (device id) missing")?;
    if id.len() != 18 || !id.bytes().all(|c| c.is_ascii_digit() || (b'a'..=b'f').contains(&c)) {
        return Err("QR device id is not 18 lower-case hex".into());
    }
    let k = v.get(2).and_then(Value::as_bytes).ok_or("QR key 2 (K) missing")?;
    if k.len() != 32 {
        return Err("QR K is not 32 bytes".into());
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
    let v = cbor::decode(&ctrl).map_err(|e| format!("CTRL: {e}"))?;
    let n = v.get(3).and_then(Value::as_uint).ok_or("CTRL key 3 missing")?;
    let lim = n.min(mtu.saturating_sub(3) as u64);
    if lim < 20 {
        return Err(format!("frame limit {lim} too small (CTRL {n}, MTU {mtu})"));
    }
    Ok(lim as u32)
}

/// sig_enc's input ("batman-owner-enc-v1" ‖ owner_enc_pub); Kotlin signs it with the owner key.
pub fn owner_enc_sign_input(owner_enc_pub: Vec<u8>) -> Result<Vec<u8>, String> {
    let p: [u8; 65] = owner_enc_pub.try_into().map_err(|_| "owner_enc_pub is not 65 bytes")?;
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
    fn ended(kind: &str, detail: String) -> ClaimStep {
        let d = if detail.is_empty() { kind.to_string() } else { format!("{kind}: {detail}") };
        ClaimStep { detail: d, ..ClaimStep::new(StepKind::Ended) }
    }
}

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
            k: qr.k.clone().try_into().map_err(|_| "K is not 32 bytes")?,
            owner_pub: owner_pub.try_into().map_err(|_| "owner_pub is not 65 bytes")?,
            owner_enc_pub: owner_enc_pub.try_into().map_err(|_| "owner_enc_pub is not 65 bytes")?,
            sig_enc: sig_enc.try_into().map_err(|_| "sig_enc is not 64 bytes")?,
            frame_limit: frame_limit as usize,
        };
        let (claim, a) = Claim::start(input);
        let mut s = ClaimSession { claim, pending: None };
        let step = s.step(Some(a)).ok_or("no first step")?;
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
                    ]));
                    ClaimStep {
                        path: node_path(&p.device_id),
                        record: rec,
                        pending_path: pending_path(&p.device_id),
                        detail: format!("claimed {}", &p.device_id[p.device_id.len() - 4..]),
                        ..ClaimStep::new(StepKind::Claimed)
                    }
                }
                None => ClaimStep::ended("Broken", "claimed without a pending record".into()),
            },
            Action::Done(End::Finished(f)) => ClaimStep::ended(&format!("{f:?}"), String::new()),
            Action::Done(End::Msg2Undecryptable) => ClaimStep::ended("Msg2Undecryptable", String::new()),
            Action::Done(End::CertRejected(e)) => ClaimStep::ended("CertRejected", format!("{e:?}")),
            Action::Done(End::BeginRefused(o)) => ClaimStep::ended("BeginRefused", format!("{o:?}")),
            Action::Done(End::Broken(s)) => ClaimStep::ended("Broken", s),
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
        assert!(parse_claim_qr("zz".into()).is_err());
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
        assert!(st.kind == StepKind::Ended && st.detail.starts_with("Broken"), "claimed without a pending: {}", st.detail);
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
        assert_eq!(st.detail, "claimed 8e24");
        let v = cbor::decode(&st.record).unwrap();
        assert_eq!(v.get(2).and_then(Value::as_bytes), Some(&[7u8; 32][..]), "K");
        assert_eq!(v.get(4).and_then(Value::as_bytes), Some(&[8u8; 5][..]), "pinned DAC");
        assert_eq!(v.get(5).and_then(Value::as_bytes), Some(&[5u8; 32][..]), "owner_tag_key");
        assert_eq!(v.get(7).and_then(Value::as_text), Some("pw"));
        let st = s.step(Some(Action::Done(End::Finished(ClaimFinish::TryReplay)))).unwrap();
        assert!(st.kind == StepKind::Ended && st.detail == "TryReplay", "{}", st.detail);
    }
}
