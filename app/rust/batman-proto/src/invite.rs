//! Remote invites, the admin's and the joiner's first half (219 §5.5 / §7.6; 254-app-member-join §4 steps 1, 2, 4),
//! sans-IO:
//! - `InviteFlow` (admin): preconditions -> invite payload {1 net_id, 2 invite_id (16 B random), 3 kind 1 (remote),
//!   4 the record's netcfg Sign1 (item), 5 admin_pub} -> SignAdmin -> the record with key 12 += {hash, 1, unused}
//!   (PersistNet, CAS) -> only then the qr-object kind 1 as hex.
//! - `open_invite` (joiner): verify_sign1 with the payload's admin_pub, exact keys, kind 1, the embedded netcfg
//!   verified as a version-1 net_config self-signed by one of ITS OWN admins (node.go adminsOf), admin_pub in those
//!   admins, key 1 == the netcfg's net_id.
//! - `JoinReqFlow` (joiner, over its own owner session's verified node_cert): open_invite again -> either the pending
//!   request of this network (same DAC, same invite: the same hex / SAS, nothing signed) or SignOwner(sig_enc) ->
//!   SignOwner(joinreq Sig_structure) -> PersistPend (CAS from the generation read) -> qr-object kind 2 hex + SAS.
//! Dev / bench only (member-join §5-5): the bridge gates every entry on the dev-trust build.

use sha2::{Digest, Sha256};

use crate::cbor::{self, Value};
use crate::cose;
use crate::mrec::{self, Pend};
use crate::netrec::{self, InviteRec, NetCfg, NetRec, MAX_MEMBERS};
use crate::nodecert::{self, hex_lower, Verified};
use crate::sig;

pub const KIND_REMOTE: u64 = 1;
pub const QR_INVITE: u64 = 1;
pub const QR_JOINREQ: u64 = 2;
pub const QR_APPROVAL: u64 = 3;
/// a device name: at most this many UTF-8 bytes, no control / format characters (member-join §4)
pub const NAME_MAX: usize = 32;
pub const LABEL_SAS: &[u8] = b"batman-sas-v1";

#[derive(Debug, PartialEq, Eq, Clone)]
pub enum Error {
    /// not hex / not the expected qr-object
    Format(&'static str),
    /// a signed object that does not verify or has the wrong shape
    Invalid(&'static str),
    /// admin preconditions (member-join §4): the record is not applied / this phone is not an admin / 16 members
    NotApplied,
    NotAdmin,
    Full,
    Name,
    /// the join request's node_cert failed the offline checks or the trust gate
    NodeCert(nodecert::Error),
    NoNodeCert,
    UnknownInvite,
    InviteUsed,
    DuplicateInvite,
    /// the node is already in the record (other than an approved entry of the same owner)
    AlreadyMember,
    HashMismatch,
    // import (approve.rs)
    NoRequest,
    TooOld,
    SameVersionDifferent,
    PreviousNode,
    Stale,
    SasMismatch,
    Aead,
    Broken(String),
}

impl From<cose::Error> for Error {
    fn from(e: cose::Error) -> Self {
        match e {
            cose::Error::Malformed(w) => Error::Invalid(w),
            cose::Error::Signature => Error::Invalid("signature"),
            cose::Error::Aead => Error::Aead,
            _ => Error::Invalid("COSE"),
        }
    }
}

pub fn from_hex(s: &str) -> Result<Vec<u8>, Error> {
    let s: String = s.chars().filter(|c| !c.is_whitespace()).collect();
    // only ASCII hex digits (then every byte index below is a char boundary)
    if s.is_empty() || s.len() % 2 != 0 || !s.bytes().all(|b| b.is_ascii_hexdigit()) {
        return Err(Error::Format("not hex"));
    }
    (0..s.len()).step_by(2).map(|i| u8::from_str_radix(&s[i..i + 2], 16).map_err(|_| Error::Format("not hex"))).collect()
}

/// qr-object {1: kind, 2: bstr} (CDDL qr-object), as the hex the dev build pastes.
pub fn qr_hex(kind: u64, obj: &[u8]) -> String {
    hex_lower(&cbor::encode(&Value::Map(vec![(Value::Uint(1), Value::Uint(kind)), (Value::Uint(2), Value::Bytes(obj.to_vec()))])))
}

/// The object inside a pasted qr-object of `kind`.
pub fn qr_object(hex: &str, kind: u64) -> Result<Vec<u8>, Error> {
    let v = cbor::decode(&from_hex(hex)?).map_err(|_| Error::Format("not a qr-object"))?;
    cose::exact_keys(&v, &[1, 2], &[]).map_err(|_| Error::Format("not a qr-object"))?;
    if v.get(1).and_then(Value::as_uint) != Some(kind) {
        return Err(Error::Format("another kind of qr-object"));
    }
    Ok(v.get(2).and_then(Value::as_bytes).ok_or(Error::Format("not a qr-object"))?.to_vec())
}

/// Unicode general category Cf (format characters, incl. the bidi controls) as of Unicode 15, and the line / paragraph
/// separators Zl / Zp (U+2028 / U+2029): nothing that reorders or breaks the text around a name.
fn is_format(c: char) -> bool {
    matches!(c as u32,
        0x2028 | 0x2029 | 0xAD | 0x600..=0x605 | 0x61C | 0x6DD | 0x70F | 0x890..=0x891 | 0x8E2 | 0x180E | 0x200B..=0x200F
        | 0x202A..=0x202E | 0x2060..=0x2064 | 0x2066..=0x206F | 0xFEFF | 0xFFF9..=0xFFFB | 0x110BD | 0x110CD
        | 0x13430..=0x1343F | 0x1BCA0..=0x1BCA3 | 0x1D173..=0x1D17A | 0xE0001 | 0xE0020..=0xE007F)
}

/// A name from a signed object (a network name: netcfg key 4) for the screen: control / format characters (incl.
/// bidi overrides and newlines) replaced with U+FFFD, so it cannot reorder or break the text around it.
pub fn display_name(s: &str) -> String {
    s.chars().map(|c| if c.is_control() || is_format(c) { '\u{FFFD}' } else { c }).collect()
}

/// A device name: ≤ 32 UTF-8 bytes, no Cc / Cf (incl. bidi) — display only, never part of a decision.
pub fn check_name(name: &str) -> Result<(), Error> {
    if name.len() > NAME_MAX || name.chars().any(|c| c.is_control() || is_format(c)) {
        return Err(Error::Name);
    }
    Ok(())
}

/// §5.5: 6 digits of int_be(SHA-256("batman-sas-v1" ‖ OBJECT_HASH(invite) ‖ OBJECT_HASH(join request))) mod 10^6.
pub fn sas(invite_hash: &[u8; 32], joinreq_hash: &[u8; 32]) -> String {
    let mut h = Sha256::new();
    h.update(LABEL_SAS);
    h.update(invite_hash);
    h.update(joinreq_hash);
    let d = h.finalize();
    let n = d.iter().fold(0u64, |acc, b| (acc * 256 + *b as u64) % 1_000_000);
    format!("{n:06}")
}

/// An invite that passed `open_invite`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Invite {
    pub net_id: [u8; 16],
    pub invite_id: [u8; 16],
    /// the embedded net_config Sign1 (bytes) and what it says
    pub netcfg: Vec<u8>,
    pub cfg: NetCfg,
    pub admin_pub: [u8; 65],
    pub hash: [u8; 32],
}

/// A net_config Sign1 verified as version 1 self-signed by one of its own admins (node.go adminsOf(cfg)).
pub fn open_netcfg_v1(netcfg: &[u8]) -> Result<NetCfg, Error> {
    let p = netrec::sign1_payload(netcfg).map_err(|_| Error::Invalid("netcfg"))?;
    let cfg = netrec::netcfg_of(&p).map_err(|_| Error::Invalid("netcfg keys"))?;
    let s = cose::verify_sign1(netcfg, cose::CT_NETCFG, cose::LABEL_NETCFG, &cfg.admins)?;
    let cfg = netrec::netcfg_of(&s.payload).map_err(|_| Error::Invalid("netcfg keys"))?;
    if cfg.version != 1 || cfg.prev_hash.is_some() {
        return Err(Error::Invalid("netcfg is not version 1"));
    }
    Ok(cfg)
}

/// §4 step 2.
pub fn open_invite(sign1: &[u8]) -> Result<Invite, Error> {
    let p = netrec::sign1_payload(sign1).map_err(|_| Error::Invalid("not a COSE_Sign1"))?;
    let admin_pub: [u8; 65] = p.get(5).and_then(Value::as_bytes).and_then(|b| b.try_into().ok()).ok_or(Error::Invalid("admin_pub"))?;
    let s = cose::verify_sign1(sign1, cose::CT_INVITE, cose::LABEL_INVITE, &[admin_pub])?;
    let p = s.payload;
    cose::exact_keys(&p, &[1, 2, 3, 4, 5], &[]).map_err(|_| Error::Invalid("invite keys"))?;
    if p.get(3).and_then(Value::as_uint) != Some(KIND_REMOTE) {
        return Err(Error::Invalid("not a remote invite"));
    }
    let item = p.get(4).filter(|x| matches!(x, Value::Tag(18, _))).ok_or(Error::Invalid("netcfg is not an embedded Sign1"))?;
    let netcfg = cbor::encode(item);
    let cfg = open_netcfg_v1(&netcfg)?;
    if !cfg.admins.contains(&admin_pub) {
        return Err(Error::Invalid("admin_pub is not one of the network's admins"));
    }
    let net_id: [u8; 16] = p.get(1).and_then(Value::as_bytes).and_then(|b| b.try_into().ok()).ok_or(Error::Invalid("net_id"))?;
    if net_id != cfg.net_id {
        return Err(Error::Invalid("invite net_id is not the netcfg's"));
    }
    let invite_id: [u8; 16] = p.get(2).and_then(Value::as_bytes).and_then(|b| b.try_into().ok()).ok_or(Error::Invalid("invite_id"))?;
    Ok(Invite { net_id, invite_id, netcfg, cfg, admin_pub, hash: s.hash })
}

/// Admin preconditions (member-join §4): applied; this phone's admin key in the netcfg admins; fewer than 16 members
/// not counting an older entry of `dac` (approved entries count).
pub fn admin_preconditions(rec: &NetRec, admin_pub: &[u8; 65], dac: Option<&[u8; 32]>) -> Result<NetCfg, Error> {
    if rec.state != netrec::APPLIED {
        return Err(Error::NotApplied);
    }
    let cfg = rec.netcfg().map_err(|_| Error::Invalid("record netcfg"))?;
    if !cfg.admins.contains(admin_pub) {
        return Err(Error::NotAdmin);
    }
    let list = rec.members().map_err(|_| Error::Invalid("record members"))?;
    if list.iter().filter(|m| Some(&m.dac_pub_hash) != dac).count() >= MAX_MEMBERS {
        return Err(Error::Full);
    }
    Ok(cfg)
}

/// What an admin / joiner flow asks for next.
#[derive(Debug, PartialEq)]
pub enum Action {
    SignAdmin { tbs: Vec<u8> },
    SignOwner { input: Vec<u8> },
    /// seal `plain` with aad(`rel`, expected_gen + 1), write_cas(rel, expected_gen), then `persisted` / `persist_failed`
    Persist { rel: String, plain: Vec<u8>, expected_gen: u64 },
    Done(End),
}

/// What a flow produced.
#[derive(Debug, PartialEq)]
pub enum End {
    /// the qr-object hex to hand over; `sas` / `name` for a join request; `renewed` = an existing request of this
    /// network was replaced (verify the SAS again)
    Out { hex: String, sas: String, name: String, renewed: bool },
    Refused(Error),
    /// the record write failed: None = written elsewhere since it was read, else why; nothing is handed out
    PersistFailed(Option<String>),
}

fn random16() -> Result<[u8; 16], Error> {
    let mut b = [0u8; 16];
    getrandom::fill(&mut b).map_err(|e| Error::Broken(format!("getrandom: {e}")))?;
    Ok(b)
}

enum IStep {
    Sign { payload: Vec<u8> },
    Persist { hex: String },
    Over,
}

/// §4 step 1 (admin).
pub struct InviteFlow {
    rec: Option<NetRec>,
    gen: u64,
    st: IStep,
}

impl InviteFlow {
    pub fn start(record_plain: &[u8], record_gen: u64, admin_pub: &[u8; 65]) -> (InviteFlow, Action) {
        match random16() {
            Ok(id) => Self::start_with_id(record_plain, record_gen, admin_pub, id),
            Err(e) => (InviteFlow { rec: None, gen: record_gen, st: IStep::Over }, Action::Done(End::Refused(e))),
        }
    }

    /// `start` with a given invite_id (tests: a repeated invite hash, vector bytes).
    #[doc(hidden)]
    pub fn start_with_id(record_plain: &[u8], record_gen: u64, admin_pub: &[u8; 65], invite_id: [u8; 16]) -> (InviteFlow, Action) {
        let mut f = InviteFlow { rec: None, gen: record_gen, st: IStep::Over };
        let a = match Self::begin(record_plain, admin_pub, invite_id) {
            Ok((rec, payload)) => {
                let tbs = cose::sign1_tbs(cose::CT_INVITE, cose::LABEL_INVITE, &payload);
                f.rec = Some(rec);
                f.st = IStep::Sign { payload };
                Action::SignAdmin { tbs }
            }
            Err(e) => Action::Done(End::Refused(e)),
        };
        (f, a)
    }

    fn begin(record_plain: &[u8], admin_pub: &[u8; 65], invite_id: [u8; 16]) -> Result<(NetRec, Vec<u8>), Error> {
        let rec = netrec::decode(record_plain).map_err(|_| Error::Invalid("record"))?;
        let cfg = admin_preconditions(&rec, admin_pub, None)?;
        let netcfg = cbor::decode(&rec.base.netcfg).map_err(|_| Error::Invalid("record netcfg"))?;
        Ok((rec, invite_payload(&cfg.net_id, &invite_id, netcfg, admin_pub)))
    }

    pub fn signed(&mut self, der: &[u8]) -> Option<Action> {
        let IStep::Sign { payload } = std::mem::replace(&mut self.st, IStep::Over) else { return None };
        let s = match sig::der_to_raw_low_s(der) {
            Ok(s) => s,
            Err(e) => return Some(Action::Done(End::Refused(Error::Broken(format!("signature: {e:?}"))))),
        };
        let sign1 = cose::sign1(cose::CT_INVITE, &payload, &s);
        let hash = match cose::object_hash(&sign1) {
            Ok(h) => h,
            Err(e) => return Some(Action::Done(End::Refused(e.into()))),
        };
        let mut rec = self.rec.take()?;
        let inv = rec.invites.get_or_insert_with(Vec::new);
        if inv.iter().any(|i| i.hash == hash) {
            return Some(Action::Done(End::Refused(Error::DuplicateInvite)));
        }
        inv.push(InviteRec { hash, kind: KIND_REMOTE, used: false });
        self.st = IStep::Persist { hex: qr_hex(QR_INVITE, &sign1) };
        Some(Action::Persist { rel: format!("net/{}", hex_lower(&rec.base.net_id)), plain: netrec::encode(&rec), expected_gen: self.gen })
    }

    /// The record (with the new key 12 entry) landed: the invite may be handed out.
    pub fn persisted(&mut self) -> Option<Action> {
        let IStep::Persist { hex } = std::mem::replace(&mut self.st, IStep::Over) else { return None };
        Some(Action::Done(End::Out { hex, sas: String::new(), name: String::new(), renewed: false }))
    }

    pub fn persist_failed(&mut self, error: Option<String>) -> Option<Action> {
        let IStep::Persist { .. } = std::mem::replace(&mut self.st, IStep::Over) else { return None };
        Some(Action::Done(End::PersistFailed(error)))
    }
}

/// The remote invite payload (CDDL invite, kind 1; the netcfg Sign1 embedded as an item).
pub fn invite_payload(net_id: &[u8; 16], invite_id: &[u8; 16], netcfg_item: Value, admin_pub: &[u8; 65]) -> Vec<u8> {
    cbor::encode(&Value::Map(vec![
        (Value::Uint(1), Value::Bytes(net_id.to_vec())),
        (Value::Uint(2), Value::Bytes(invite_id.to_vec())),
        (Value::Uint(3), Value::Uint(KIND_REMOTE)),
        (Value::Uint(4), netcfg_item),
        (Value::Uint(5), Value::Bytes(admin_pub.to_vec())),
    ]))
}

/// The join request payload (CDDL join-request; the node_cert embedded as an item).
pub fn joinreq_payload(invite_hash: &[u8; 32], node_cert: Value, owner_pub: &[u8; 65], owner_enc_pub: &[u8; 65], sig_enc: &[u8; 64], name: &str) -> Vec<u8> {
    cbor::encode(&Value::Map(vec![
        (Value::Uint(1), Value::Bytes(invite_hash.to_vec())),
        (Value::Uint(2), node_cert),
        (Value::Uint(3), Value::Bytes(owner_pub.to_vec())),
        (Value::Uint(4), Value::Bytes(owner_enc_pub.to_vec())),
        (Value::Uint(5), Value::Bytes(sig_enc.to_vec())),
        (Value::Uint(6), Value::Text(name.into())),
    ]))
}

pub struct JoinReqInput {
    pub invite_hex: String,
    pub name: String,
    /// this login's verified node and its raw node_cert (None unless verify_pinned passed)
    pub node: Option<Verified>,
    pub node_cert_raw: Option<Vec<u8>>,
    pub owner_pub: [u8; 65],
    pub owner_enc_pub: [u8; 65],
    /// mpend/<net_id> as read: its generation (0 = none) and plain (None = none or does not open)
    pub pend_gen: u64,
    pub pend_plain: Option<Vec<u8>>,
}

enum JStep {
    SigEnc { inv: Invite, dac_hash: [u8; 32], device_id: String },
    Joinreq { inv: Invite, dac_hash: [u8; 32], device_id: String, payload: Vec<u8> },
    Persist { out: End },
    Over,
}

/// §4 step 4 (joiner).
pub struct JoinReqFlow {
    inp: JoinReqInput,
    st: JStep,
}

fn stored_name(joinreq: &[u8]) -> String {
    netrec::sign1_payload(joinreq).ok().and_then(|p| p.get(6).and_then(Value::as_text).map(str::to_string)).unwrap_or_default()
}

impl JoinReqFlow {
    pub fn start(inp: JoinReqInput) -> (JoinReqFlow, Action) {
        let mut f = JoinReqFlow { inp, st: JStep::Over };
        let a = match f.begin() {
            Ok(a) => a,
            Err(e) => Action::Done(End::Refused(e)),
        };
        (f, a)
    }

    fn begin(&mut self) -> Result<Action, Error> {
        let inv = open_invite(&qr_object(&self.inp.invite_hex, QR_INVITE)?)?;
        check_name(&self.inp.name)?;
        let (Some(node), Some(_)) = (&self.inp.node, &self.inp.node_cert_raw) else { return Err(Error::NoNodeCert) };
        let dac_hash = netrec::dac_hash(&node.dac_pub);
        let device_id = node.device_id.clone();
        // the pending request of this network for this node and this invite: shown again, nothing signed
        if let Some(p) = self.inp.pend_plain.as_deref().and_then(|b| Pend::decode(b).ok()) {
            if p.dac_hash == dac_hash && p.invite_hash == inv.hash {
                let out = End::Out { hex: qr_hex(QR_JOINREQ, &p.joinreq), sas: sas(&p.invite_hash, &p.joinreq_hash), name: stored_name(&p.joinreq), renewed: false };
                return Ok(Action::Done(out));
            }
        }
        let input = sig::owner_enc_input(&self.inp.owner_enc_pub);
        self.st = JStep::SigEnc { inv, dac_hash, device_id };
        Ok(Action::SignOwner { input })
    }

    pub fn signed(&mut self, der: &[u8]) -> Option<Action> {
        let s = match sig::der_to_raw_low_s(der) {
            Ok(s) => s,
            Err(e) => {
                self.st = JStep::Over;
                return Some(Action::Done(End::Refused(Error::Broken(format!("signature: {e:?}")))));
            }
        };
        match std::mem::replace(&mut self.st, JStep::Over) {
            JStep::SigEnc { inv, dac_hash, device_id } => {
                let raw = self.inp.node_cert_raw.as_deref()?;
                let node_cert = match cbor::decode(raw) {
                    Ok(v) => v,
                    Err(_) => return Some(Action::Done(End::Refused(Error::NoNodeCert))),
                };
                let payload = joinreq_payload(&inv.hash, node_cert, &self.inp.owner_pub, &self.inp.owner_enc_pub, &s, &self.inp.name);
                let input = cose::sign1_tbs(cose::CT_JOINREQ, cose::LABEL_JOINREQ, &payload);
                self.st = JStep::Joinreq { inv, dac_hash, device_id, payload };
                Some(Action::SignOwner { input })
            }
            JStep::Joinreq { inv, dac_hash, device_id, payload } => {
                let joinreq = cose::sign1(cose::CT_JOINREQ, &payload, &s);
                let joinreq_hash = match cose::object_hash(&joinreq) {
                    Ok(h) => h,
                    Err(e) => return Some(Action::Done(End::Refused(e.into()))),
                };
                let pend = Pend {
                    invite_hash: inv.hash,
                    netcfg: inv.netcfg.clone(),
                    joinreq_hash,
                    dac_hash,
                    owner_enc_hash: Sha256::digest(self.inp.owner_enc_pub).into(),
                    device_id,
                    joinreq: joinreq.clone(),
                };
                // "renewed" = a request of this network was there and is replaced (verify the SAS again)
                let renewed = self.inp.pend_gen > 0;
                let out = End::Out { hex: qr_hex(QR_JOINREQ, &joinreq), sas: sas(&inv.hash, &joinreq_hash), name: self.inp.name.clone(), renewed };
                self.st = JStep::Persist { out };
                Some(Action::Persist { rel: mrec::pend_path(&inv.net_id), plain: pend.encode(), expected_gen: self.inp.pend_gen })
            }
            other => {
                self.st = other;
                None
            }
        }
    }

    /// The mpend record landed: the request may be handed out.
    pub fn persisted(&mut self) -> Option<Action> {
        let JStep::Persist { out } = std::mem::replace(&mut self.st, JStep::Over) else { return None };
        Some(Action::Done(out))
    }

    pub fn persist_failed(&mut self, error: Option<String>) -> Option<Action> {
        let JStep::Persist { .. } = std::mem::replace(&mut self.st, JStep::Over) else { return None };
        Some(Action::Done(End::PersistFailed(error)))
    }
}

/// "Show the request again" (member-join §3): the hex and SAS from a pending request's key 7.
pub fn pend_view(pend_plain: &[u8]) -> Result<End, Error> {
    let p = Pend::decode(pend_plain).map_err(|_| Error::Invalid("pending request"))?;
    Ok(End::Out { hex: qr_hex(QR_JOINREQ, &p.joinreq), sas: sas(&p.invite_hash, &p.joinreq_hash), name: stored_name(&p.joinreq), renewed: false })
}
