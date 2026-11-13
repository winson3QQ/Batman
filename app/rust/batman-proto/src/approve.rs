//! Remote invites, the second half (219 §7.4 / §7.6; 254-app-member-join §3, §4 steps 5-7), sans-IO:
//! - `check_joinreq` (admin): the join request's Sign1 verified with its own payload owner_pub, exact keys, sig_enc,
//!   the name rule, the node_cert offline (strict keys + trust gate); key 1 = an UNUSED invite hash of this record's
//!   key 12; the same DAC already in the record -> refused unless an approved entry of the same owner_pub; the SAS.
//! - `ApproveFlow` (admin): check_joinreq again on the same record, its OBJECT_HASH = the one the admin confirmed,
//!   the admin preconditions -> net_secrets for the node + member_secrets for the owner app (2 x SignAdmin) ->
//!   key 12 used + an "approved" member entry (PersistNet, CAS) -> only then the approval (qr kind 3) hex.
//! - `prepare_import` / `import` (joiner): the approval bound to this network's pending request (mpend): key 1 absent
//!   or the request's netcfg byte for byte; the three Sign1s verified with that netcfg's admins; net_id / version;
//!   secrets key 3 = the own DAC hash, msecrets key 3 = SHA-256(owner_enc_pub); the rules against an existing mnet.
//!   `import` also needs the mpend generation `prepare_import` saw, the SAS string the user confirmed, a point on
//!   the curve, the AEAD and a plaintext of exactly {2: bstr32}.
//! Remove member (254-app-remove-member v6.4): a node "removed before" (some version's key 5) or a person "listed
//! before and not in key 11 now" needs the admin's confirmation, a parameter of `ApproveFlow::start` (§3.6; before
//! the first SignAdmin); the approved entry's key 10 = the current version. The import carries mnet keys 9 / 10
//! (§2.2): same version -> both kept; next version -> key 9 + the new one (its members' prev_hash checked), key 10
//! cleared; 2+ versions ahead -> replaced only when the user confirmed and the new netcfg is signed by the stored
//! admins (§3.6-2: key 9 = the new version only, key 10 cleared). An own entry whose node the new members list as
//! removed counts as none (§3.6-2b).

use sha2::{Digest, Sha256};

use crate::cbor::{self, Value};
use crate::cose;
use crate::invite::{admin_preconditions, check_name, qr_hex, qr_object, sas, Action, End, Error, QR_APPROVAL, QR_JOINREQ};
use crate::mrec::{MNet, Pend};
use crate::netrec::{self, Member, MemberState, NetCfg, NetRec, Version, HISTORY_KEEP};
use crate::nodecert::{self, hex_lower, Verified};
use crate::sig;
use crate::teamview;

/// A join request that passed `open_joinreq`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct JoinReq {
    pub invite_hash: [u8; 32],
    pub node: Verified,
    pub owner_pub: [u8; 65],
    pub owner_enc_pub: [u8; 65],
    pub name: String,
    pub hash: [u8; 32],
    /// key 7 (254-app-team-status §4.2): the joining node's mesh address as its owner's app read it; accepted from
    /// version N on, written into the list only from N+1 (`teamview::gate`)
    pub mesh_addr: Option<[u8; 6]>,
}

fn arr<const N: usize>(v: &Value, k: u64, what: &'static str) -> Result<[u8; N], Error> {
    v.get(k).and_then(Value::as_bytes).and_then(|b| b.try_into().ok()).ok_or(Error::Invalid(what))
}

pub fn open_joinreq(sign1: &[u8]) -> Result<JoinReq, Error> {
    use p256::ecdsa::signature::Verifier;
    let p = netrec::sign1_payload(sign1).map_err(|_| Error::Invalid("not a COSE_Sign1"))?;
    let owner_pub: [u8; 65] = arr(&p, 3, "owner_pub")?;
    let s = cose::verify_sign1(sign1, cose::CT_JOINREQ, cose::LABEL_JOINREQ, &[owner_pub])?;
    let p = s.payload;
    cose::exact_keys(&p, &[1, 2, 3, 4, 5, 6], &[7]).map_err(|_| Error::Invalid("join request keys"))?;
    let mesh_addr = match p.get(7) {
        None => None,
        Some(v) => Some(v.as_bytes().and_then(|b| <[u8; 6]>::try_from(b).ok()).ok_or(Error::Invalid("join request mesh address"))?),
    };
    let owner_enc_pub: [u8; 65] = arr(&p, 4, "owner_enc_pub")?;
    let sig_enc: [u8; 64] = arr(&p, 5, "sig_enc")?;
    let vk = p256::ecdsa::VerifyingKey::from_sec1_bytes(&owner_pub).map_err(|_| Error::Invalid("owner_pub"))?;
    let se = p256::ecdsa::Signature::from_slice(&sig_enc).map_err(|_| Error::Invalid("sig_enc"))?;
    if !sig::is_low_s(&sig_enc) || vk.verify(&sig::owner_enc_input(&owner_enc_pub), &se).is_err() {
        return Err(Error::Invalid("sig_enc"));
    }
    let name = p.get(6).and_then(Value::as_text).ok_or(Error::Invalid("name"))?.to_string();
    check_name(&name)?;
    let node_cert = p.get(2).ok_or(Error::Invalid("node_cert"))?;
    let node = nodecert::verify_offline(&cbor::encode(node_cert)).map_err(Error::NodeCert)?;
    Ok(JoinReq { invite_hash: arr(&p, 1, "invite hash")?, node, owner_pub, owner_enc_pub, name, hash: s.hash, mesh_addr })
}

/// A node / person this network removed before (remove-member §3.6): the admin confirms before approving.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Previous {
    /// true: the node itself left (key 14 / some version removed list); false: its owner (owner_pub) was listed before
    pub node: bool,
    /// the previous owner as key 14 (or else the newest kept version listing the node / person) names it (None: "不明")
    pub owner_name: Option<String>,
    pub owner_pub: Option<[u8; 65]>,
}

/// What the admin checks before showing the SAS (§4 step 5).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Checked {
    pub jr: JoinReq,
    pub sas: String,
    /// the node is in the record as an approved entry of the same owner (re-approval)
    pub replaces_approved: bool,
    /// removed before: `ApproveFlow::start` needs `previous_confirmed`
    pub previous: Option<Previous>,
    /// this person still lacks a version (another entry's key 10 < current): "ask them to paste the update first"
    pub update_first: bool,
}

/// remove-member §3.6: the node in some version's key 5, or the owner_pub in some kept version's members and not in
/// key 11 now.
pub fn previous_of(rec: &NetRec, dac: &[u8; 32], owner_pub: &[u8; 65]) -> Result<Option<Previous>, Error> {
    let bad = |_| Error::Invalid("record versions");
    let list = rec.members().map_err(bad)?;
    let removed = rec.removed_ever().map_err(bad)?;
    let (node, seen) = if removed.contains(dac) {
        (true, rec.last_listed(|m| m.dac_pub_hash == *dac).map_err(bad)?)
    } else if !list.iter().any(|m| m.owner_pub == *owner_pub) {
        match rec.last_listed(|m| m.owner_pub == *owner_pub).map_err(bad)? {
            Some(m) => (false, Some(m)),
            None => return Ok(None),
        }
    } else {
        return Ok(None);
    };
    Ok(Some(Previous { node, owner_name: seen.as_ref().map(|m| m.name.clone()), owner_pub: seen.map(|m| m.owner_pub) }))
}

pub fn check_joinreq(rec: &NetRec, sign1: &[u8]) -> Result<Checked, Error> {
    let jr = open_joinreq(sign1)?;
    let inv = rec.invites.as_deref().unwrap_or_default().iter().find(|i| i.hash == jr.invite_hash).ok_or(Error::UnknownInvite)?;
    if inv.used {
        return Err(Error::InviteUsed);
    }
    let dac = netrec::dac_hash(&jr.node.dac_pub);
    let list = rec.members().map_err(|_| Error::Invalid("record members"))?;
    let mut replaces_approved = false;
    if let Some(m) = list.iter().find(|m| m.dac_pub_hash == dac) {
        if m.state == MemberState::Approved && m.owner_pub == jr.owner_pub {
            replaces_approved = true;
        } else {
            return Err(Error::AlreadyMember);
        }
    }
    let previous = previous_of(rec, &dac, &jr.owner_pub)?;
    let cur = rec.netcfg().map_err(|_| Error::Invalid("record netcfg"))?.version;
    let mut update_first = false;
    for m in list.iter().filter(|m| m.owner_pub == jr.owner_pub && m.dac_pub_hash != dac) {
        update_first |= rec.known_of(m).map_err(|_| Error::Invalid("record versions"))? < cur;
    }
    Ok(Checked { sas: sas(&jr.invite_hash, &jr.hash), jr, replaces_approved, previous, update_first })
}

enum AStep {
    Secrets { jr: JoinReq, cfg: NetCfg, payload: Vec<u8> },
    MSecrets { jr: JoinReq, secrets: Vec<u8>, payload: Vec<u8> },
    // dup: the duplicate-address line (254-app-team-status §4.2; "" = none)
    Persist { hex: String, dup: String },
    Over,
}

/// §4 step 6 (admin).
pub struct ApproveFlow {
    rec: Option<NetRec>,
    gen: u64,
    st: AStep,
}

fn refused(e: Error) -> Option<Action> {
    Some(Action::Done(End::Refused(e)))
}

impl ApproveFlow {
    /// `previous_confirmed`: the admin answered yes to "this node / person was removed before" (remove-member §3.6);
    /// without it such a request stops here, before the first SignAdmin.
    pub fn start(record_plain: &[u8], record_gen: u64, joinreq_hex: &str, joinreq_hash: &[u8; 32], admin_pub: &[u8; 65], previous_confirmed: bool) -> (ApproveFlow, Action) {
        let mut f = ApproveFlow { rec: None, gen: record_gen, st: AStep::Over };
        let a = match f.begin(record_plain, joinreq_hex, joinreq_hash, admin_pub, previous_confirmed) {
            Ok(a) => a,
            Err(e) => Action::Done(End::Refused(e)),
        };
        (f, a)
    }

    fn begin(&mut self, record_plain: &[u8], joinreq_hex: &str, joinreq_hash: &[u8; 32], admin_pub: &[u8; 65], previous_confirmed: bool) -> Result<Action, Error> {
        let rec = netrec::decode(record_plain).map_err(|_| Error::Invalid("record"))?;
        // the same checks as step 5, on the same record, and bound to the request the admin saw
        let c = check_joinreq(&rec, &qr_object(joinreq_hex, QR_JOINREQ)?)?;
        if c.jr.hash != *joinreq_hash {
            return Err(Error::HashMismatch);
        }
        let dac = netrec::dac_hash(&c.jr.node.dac_pub);
        let cfg = admin_preconditions(&rec, admin_pub, Some(&dac))?;
        // remove-member §3.6: before the first SignAdmin
        if c.previous.is_some() && !previous_confirmed {
            return Err(Error::NeedsConfirm);
        }
        let payload = secrets_payload(&rec, &cfg, &c.jr.node.ecdh_pub, &dac, cose::LABEL_SECRETS, false)?;
        let tbs = cose::sign1_tbs(cose::CT_SECRETS, cose::LABEL_SECRETS, &payload);
        self.rec = Some(rec);
        self.st = AStep::Secrets { jr: c.jr, cfg, payload };
        Ok(Action::SignAdmin { tbs })
    }

    pub fn signed(&mut self, der: &[u8]) -> Option<Action> {
        let s = match sig::der_to_raw_low_s(der) {
            Ok(s) => s,
            Err(e) => {
                self.st = AStep::Over;
                return refused(Error::Broken(format!("signature: {e:?}")));
            }
        };
        match std::mem::replace(&mut self.st, AStep::Over) {
            AStep::Secrets { jr, cfg, payload } => {
                let secrets = cose::sign1(cose::CT_SECRETS, &payload, &s);
                let target: [u8; 32] = Sha256::digest(jr.owner_enc_pub).into();
                let payload = match secrets_payload(self.rec.as_ref()?, &cfg, &jr.owner_enc_pub, &target, cose::LABEL_MSECRETS, true) {
                    Ok(p) => p,
                    Err(e) => return refused(e),
                };
                let tbs = cose::sign1_tbs(cose::CT_MSECRETS, cose::LABEL_MSECRETS, &payload);
                self.st = AStep::MSecrets { jr, secrets, payload };
                Some(Action::SignAdmin { tbs })
            }
            AStep::MSecrets { jr, secrets, payload, .. } => {
                let msecrets = cose::sign1(cose::CT_MSECRETS, &payload, &s);
                let mut rec = self.rec.take()?;
                let item = |b: &[u8]| cbor::decode(b).map_err(|_| Error::Invalid("Sign1"));
                let bundle = match (item(&rec.base.members), item(&secrets), item(&msecrets)) {
                    (Ok(m), Ok(se), Ok(ms)) => cbor::encode(&Value::Map(vec![(Value::Uint(2), m), (Value::Uint(3), se), (Value::Uint(4), ms)])),
                    _ => return refused(Error::Invalid("Sign1")),
                };
                for i in rec.invites.iter_mut().flatten().filter(|i| i.hash == jr.invite_hash) {
                    i.used = true;
                }
                let dac = netrec::dac_hash(&jr.node.dac_pub);
                let current = match rec.netcfg() {
                    Ok(c) => c.version,
                    Err(_) => return refused(Error::Invalid("record netcfg")),
                };
                let mut entry = Member {
                    dac_pub_hash: dac,
                    ecdh_pub: jr.node.ecdh_pub,
                    name: jr.name.clone(),
                    owner_pub: jr.owner_pub,
                    owner_enc_pub: jr.owner_enc_pub,
                    device_id: Some(jr.node.device_id.clone()),
                    state: MemberState::Approved,
                    prev_country: None,
                    // the approval carries the current version: its owner surely holds it (§2.1)
                    known: Some(current),
                    // 254-app-team-status §4.3: version N accepts the request's key 7 and drops it
                    mesh_addr: teamview::gate(jr.mesh_addr),
                };
                let mut list = match rec.members() {
                    Ok(l) => l,
                    Err(_) => return refused(Error::Invalid("record members")),
                };
                // 254-app-team-status §4.2 (B-M2): the same mesh address on another entry -> neither keeps it
                let mut dup = String::new();
                if let Some(a) = entry.mesh_addr {
                    let others: Vec<String> = list
                        .iter_mut()
                        .filter(|m| m.dac_pub_hash != dac && m.mesh_addr == Some(a))
                        .map(|m| {
                            m.mesh_addr = None;
                            m.name.clone()
                        })
                        .collect();
                    if !others.is_empty() {
                        entry.mesh_addr = None;
                        dup = teamview::dup_hint(&[vec![entry.name.clone()], others].concat());
                    }
                }
                match list.iter().position(|m| m.dac_pub_hash == dac) {
                    Some(i) => list[i] = entry,
                    None => list.push(entry),
                }
                rec.list = Some(list);
                self.st = AStep::Persist { hex: qr_hex(QR_APPROVAL, &bundle), dup };
                Some(Action::Persist { rel: format!("net/{}", hex_lower(&rec.base.net_id)), plain: netrec::encode(&rec), expected_gen: self.gen })
            }
            other => {
                self.st = other;
                None
            }
        }
    }

    pub fn persisted(&mut self) -> Option<Action> {
        let AStep::Persist { hex, dup } = std::mem::replace(&mut self.st, AStep::Over) else { return None };
        Some(Action::Done(End::Out { hex, sas: String::new(), name: dup, renewed: false }))
    }

    pub fn persist_failed(&mut self, error: Option<String>) -> Option<Action> {
        let AStep::Persist { .. } = std::mem::replace(&mut self.st, AStep::Over) else { return None };
        Some(Action::Done(End::PersistFailed(error)))
    }
}

/// net_secrets (`member` false: {SAE, net_root} to the node's ecdh_pub) or member_secrets (true: {2: net_root} to
/// the owner_enc_pub), the netcfg's net_id / version.
fn secrets_payload(rec: &NetRec, cfg: &NetCfg, to: &[u8; 65], target: &[u8; 32], label: &[u8], member: bool) -> Result<Vec<u8>, Error> {
    let mut m = vec![(Value::Uint(2), Value::Bytes(rec.base.net_root.to_vec()))];
    if !member {
        m.push((Value::Uint(1), Value::Text(rec.base.sae.clone())));
    }
    let mut plain = cbor::encode(&Value::Map(m));
    let enc = cose::encrypt_to(&plain, label, to, target, &cfg.net_id, cfg.version);
    plain.iter_mut().for_each(|b| *b = 0);
    let enc = enc.map_err(|e| Error::Broken(format!("{e:?}")))?;
    Ok(cose::net_secrets_payload(&cfg.net_id, cfg.version, target, &enc.object))
}

// ---- the joiner's import (§4 step 7) ----

struct Bundle {
    netcfg: Option<Vec<u8>>,
    members: Vec<u8>,
    secrets: Vec<u8>,
    msecrets: Vec<u8>,
}

fn bundle(hex: &str) -> Result<Bundle, Error> {
    let v = cbor::decode(&qr_object(hex, QR_APPROVAL)?).map_err(|_| Error::Format("not an approval"))?;
    cose::exact_keys(&v, &[2, 3, 4], &[1]).map_err(|_| Error::Format("approval keys"))?;
    let item = |k: u64| match v.get(k) {
        Some(x @ Value::Tag(18, _)) => Ok(cbor::encode(x)),
        _ => Err(Error::Format("approval item is not a COSE_Sign1")),
    };
    Ok(Bundle { netcfg: if v.get(1).is_some() { Some(item(1)?) } else { None }, members: item(2)?, secrets: item(3)?, msecrets: item(4)? })
}

/// §4 step 7a's first move: the net_id an approval names, parsed only (never trusted: it only picks which files to
/// read; a wrong one reads the wrong files and the checks fail). Lowercase hex.
pub fn approval_net_id(hex: &str) -> Result<String, Error> {
    let b = bundle(hex)?;
    let p = netrec::sign1_payload(&b.secrets).map_err(|_| Error::Format("approval secrets"))?;
    let id: [u8; 16] = arr(&p, 1, "net_id")?;
    Ok(hex_lower(&id))
}

/// A secrets / msecrets / members payload of this netcfg (exact keys, net_id, version).
fn same_net(p: &Value, cfg: &NetCfg, members: bool) -> Result<(), Error> {
    if members {
        cose::exact_keys(p, &[1, 2, 3, 4, 5, 6, 7], &[]).map_err(|_| Error::Invalid("members keys"))?;
        // nested: every member entry (CDDL member) and the three lists
        let Some(Value::Array(list)) = p.get(4) else { return Err(Error::Invalid("members keys")) };
        for m in list {
            if !netrec::member_entry_ok(m) {
                return Err(Error::Invalid("member entry keys"));
            }
        }
        if ![5, 6, 7].iter().all(|k| matches!(p.get(*k), Some(Value::Array(_)))) {
            return Err(Error::Invalid("members keys"));
        }
    } else {
        cose::exact_keys(p, &[1, 2, 3, 4], &[]).map_err(|_| Error::Invalid("secrets keys"))?;
    }
    if p.get(1).and_then(Value::as_bytes) != Some(&cfg.net_id[..]) || p.get(2).and_then(Value::as_uint) != Some(cfg.version as u64) {
        return Err(Error::Invalid("another net_id / version"));
    }
    Ok(())
}

/// How an approval meets an existing mnet (§3 / remove-member §2.2).
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
enum Path {
    New,
    Same,
    Next,
    Replace,
}

struct Bound {
    cfg: NetCfg,
    ms_enc: Value,
    /// the existing own-node entry to carry (same DAC), or None for a fresh joining entry
    carry: Option<Member>,
    path: Path,
}

/// The import conditions shared by 7a and 7c. `replace`: the user confirmed replacing a stored network 2+ versions
/// behind (§3.6-2).
fn bind(b: &Bundle, pend: &Pend, mnet: Option<&MNet>, replace: bool) -> Result<Bound, Error> {
    if b.netcfg.as_ref().is_some_and(|n| *n != pend.netcfg) {
        return Err(Error::Invalid("approval netcfg is not the invite's"));
    }
    let cfg = netrec::netcfg_of(&netrec::sign1_payload(&pend.netcfg).map_err(|_| Error::Invalid("pending netcfg"))?)
        .map_err(|_| Error::Invalid("pending netcfg"))?;
    let m = cose::verify_sign1(&b.members, cose::CT_MEMBERS, cose::LABEL_MEMBERS, &cfg.admins)?;
    same_net(&m.payload, &cfg, true)?;
    let se = cose::verify_sign1(&b.secrets, cose::CT_SECRETS, cose::LABEL_SECRETS, &cfg.admins)?;
    same_net(&se.payload, &cfg, false)?;
    let ms = cose::verify_sign1(&b.msecrets, cose::CT_MSECRETS, cose::LABEL_MSECRETS, &cfg.admins)?;
    same_net(&ms.payload, &cfg, false)?;
    if se.payload.get(3).and_then(Value::as_bytes) != Some(&pend.dac_hash[..]) {
        return Err(Error::Invalid("secrets are not for this node"));
    }
    if ms.payload.get(3).and_then(Value::as_bytes) != Some(&pend.owner_enc_hash[..]) {
        return Err(Error::Invalid("member secrets are not for this phone"));
    }
    let (carry, path) = match mnet {
        Some(x) => existing(x, &pend.netcfg, &cfg, &pend.dac_hash, &m.payload, replace)?,
        None => (None, Path::New),
    };
    Ok(Bound { cfg, ms_enc: ms.payload.get(4).cloned().ok_or(Error::Invalid("enc"))?, carry, path })
}

/// §3.6-2: a stored network 2+ versions behind may be replaced — the new netcfg signed by the STORED admins, the
/// same net_id, a higher version.
fn replaceable(x: &MNet, new: &[u8], cfg: &NetCfg) -> Result<bool, Error> {
    let old = x.netcfg().map_err(|_| Error::Invalid("stored netcfg"))?;
    Ok(cfg.version > old.version.saturating_add(1) && cfg.net_id == x.net_id && cose::verify_sign1(new, cose::CT_NETCFG, cose::LABEL_NETCFG, &old.admins).is_ok())
}

/// §3 rules against an existing mnet: the same netcfg byte for byte, or the next version (signed by the existing
/// admins, prev_hash = OBJECT_HASH(existing), the same net_id, and its members' prev_hash = OBJECT_HASH(stored
/// members)); 2+ versions ahead = this phone's data is too old (replaced only when `replace` and `replaceable`);
/// anything else = another network under the same number. The own-node entry: one the new members list as removed
/// counts as none (remove-member §3.6-2b); same DAC -> carried (state, prev_country); another DAC whose entry is
/// joining or has a prev_country -> refused; else a fresh joining entry.
fn existing(x: &MNet, new: &[u8], cfg: &NetCfg, dac: &[u8; 32], mp: &Value, replace: bool) -> Result<(Option<Member>, Path), Error> {
    let mut path = Path::Same;
    if new != x.netcfg.as_slice() {
        let old = x.netcfg().map_err(|_| Error::Invalid("stored netcfg"))?;
        if cfg.version == old.version.saturating_add(1) {
            cose::verify_sign1(new, cose::CT_NETCFG, cose::LABEL_NETCFG, &old.admins)?;
            let prev = cose::object_hash(&x.netcfg)?;
            if cfg.prev_hash != Some(prev) || cfg.net_id != x.net_id {
                return Err(Error::Invalid("not the next version of the stored network"));
            }
            // remove-member §2.2 (B-m9): the members of the next version chain to the stored ones
            let mprev = cose::object_hash(&x.members)?;
            if mp.get(3).and_then(Value::as_bytes) != Some(&mprev[..]) {
                return Err(Error::Invalid("members are not the next version of the stored ones"));
            }
            path = Path::Next;
        } else if cfg.version > old.version.saturating_add(1) {
            if !(replace && replaceable(x, new, cfg)?) {
                return Err(Error::TooOld);
            }
            path = Path::Replace;
        } else {
            return Err(Error::SameVersionDifferent);
        }
    }
    let removed = netrec::removed_of(mp).map_err(|_| Error::Invalid("members removed"))?;
    let me = x.me.as_ref().filter(|m| !removed.contains(&m.dac_pub_hash));
    let carry = match me {
        Some(m) if m.dac_pub_hash == *dac => Some(m.clone()),
        Some(m) if m.state == MemberState::Joining || m.prev_country.is_some() => return Err(Error::PreviousNode),
        _ => None,
    };
    Ok((carry, path))
}

/// What 7a found.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Prepared {
    /// show `sas` and ask the user to confirm it; Kotlin ECDH with `eph_pub`; 7c must see mpend at `pend_gen`
    Ready { sas: String, eph_pub: [u8; 65], pend_gen: u64 },
    /// remove-member §3.6-2: the stored network (version `stored`) is 2+ versions behind and may be replaced — ask
    /// "這支手機有這個網路的舊紀錄(v…),要換成新的嗎?", then prepare again with `replace`
    Replace { stored: u32 },
    /// no pending request, but this approval's secrets are the stored network's and the node entry is there
    AlreadyImported,
    /// the same, but the node entry was dropped (a definite join failure): a new invite is needed
    NeedsNewInvite,
}

/// §4 step 7a. `pend`: mpend/<id> as read (generation, plain); `mnet`: mnet/<id> plain; `replace`: the user
/// confirmed replacing a stored network 2+ versions behind (remove-member §3.6-2).
pub fn prepare_import(hex: &str, pend: Option<(u64, &[u8])>, mnet: Option<&[u8]>, replace: bool) -> Result<Prepared, Error> {
    let b = bundle(hex)?;
    let mnet = match mnet {
        Some(p) => Some(MNet::decode(p).map_err(|_| Error::Invalid("stored network"))?),
        None => None,
    };
    let Some((pend_gen, plain)) = pend else {
        // re-pasting an imported approval: its secrets verified with the stored admins and equal to the stored ones
        let Some(x) = mnet else { return Err(Error::NoRequest) };
        let cfg = x.netcfg().map_err(|_| Error::Invalid("stored netcfg"))?;
        if cose::verify_sign1(&b.secrets, cose::CT_SECRETS, cose::LABEL_SECRETS, &cfg.admins).is_ok() && b.secrets == x.secrets {
            return Ok(if x.me.is_some() { Prepared::AlreadyImported } else { Prepared::NeedsNewInvite });
        }
        return Err(Error::NoRequest);
    };
    let p = Pend::decode(plain).map_err(|_| Error::NoRequest)?;
    let bound = match bind(&b, &p, mnet.as_ref(), replace) {
        Err(Error::TooOld) if !replace => {
            let x = mnet.as_ref().ok_or(Error::TooOld)?;
            let cfg = netrec::netcfg_of(&netrec::sign1_payload(&p.netcfg).map_err(|_| Error::Invalid("pending netcfg"))?)
                .map_err(|_| Error::Invalid("pending netcfg"))?;
            return if replaceable(x, &p.netcfg, &cfg)? { Ok(Prepared::Replace { stored: x.version }) } else { Err(Error::TooOld) };
        }
        r => r?,
    };
    let eph_pub = cose::recipient_eph(&bound.ms_enc)?;
    Ok(Prepared::Ready { sas: sas(&p.invite_hash, &p.joinreq_hash), eph_pub, pend_gen })
}

/// §4 step 7c: everything again with the mpend generation 7a saw and the SAS string the user confirmed; then the
/// member secrets decrypted with `z` (Kotlin ECDH) and the new mnet. Returns (mnet plain, net_id, the mnet
/// generation to write from: CAS, sealed for + 1). Nothing is written here.
#[allow(clippy::too_many_arguments)]
pub fn import(hex: &str, pend: (u64, &[u8]), expected_pend_gen: u64, mnet: Option<(&[u8], u64)>, z: &[u8; 32], confirmed_sas: &str, replace: bool) -> Result<(Vec<u8>, [u8; 16], u64), Error> {
    let (pend_gen, plain) = pend;
    if pend_gen != expected_pend_gen {
        return Err(Error::Stale);
    }
    let b = bundle(hex)?;
    let p = Pend::decode(plain).map_err(|_| Error::NoRequest)?;
    let (old, mnet_gen) = match mnet {
        Some((x, g)) => (Some(MNet::decode(x).map_err(|_| Error::Invalid("stored network"))?), g),
        None => (None, 0),
    };
    let bound = bind(&b, &p, old.as_ref(), replace)?;
    if confirmed_sas != sas(&p.invite_hash, &p.joinreq_hash) {
        return Err(Error::SasMismatch);
    }
    cose::recipient_eph(&bound.ms_enc)?;
    let cfg = &bound.cfg;
    let mut pt = cose::decrypt(&bound.ms_enc, cose::LABEL_MSECRETS, &p.owner_enc_hash, &cfg.net_id, cfg.version, z)?;
    let parsed = cbor::decode(&pt).ok();
    pt.iter_mut().for_each(|x| *x = 0);
    let v = parsed.ok_or(Error::Invalid("member secrets plaintext"))?;
    cose::exact_keys(&v, &[2], &[]).map_err(|_| Error::Invalid("member secrets plaintext is not {2: net_root}"))?;
    let net_root: [u8; 32] = arr(&v, 2, "net_root")?;
    // the own node's entry: from the request (its node_cert, owner keys, name), joining, unless carried
    let jr = netrec::sign1_payload(&p.joinreq).map_err(|_| Error::Invalid("pending request"))?;
    let nc = jr.get(2).ok_or(Error::Invalid("pending request"))?;
    let me = match bound.carry {
        Some(m) => m,
        None => Member {
            dac_pub_hash: p.dac_hash,
            ecdh_pub: arr(nc, 4, "ecdh_pub")?,
            name: jr.get(6).and_then(Value::as_text).unwrap_or_default().to_string(),
            owner_pub: arr(&jr, 3, "owner_pub")?,
            owner_enc_pub: arr(&jr, 4, "owner_enc_pub")?,
            device_id: Some(p.device_id.clone()),
            state: MemberState::Joining,
            prev_country: None,
            known: None,
            mesh_addr: None,
        },
    };
    // remove-member §2.2: the other writers keep keys 9 / 10
    let (versions, node_secrets) = match (bound.path, old) {
        (Path::Same, Some(o)) => (o.versions, o.node_secrets),
        (Path::Next, Some(o)) => {
            let mut h = o.history();
            h.push(Version { version: cfg.version, netcfg: p.netcfg.clone(), members: b.members.clone() });
            let cut = h.len().saturating_sub(HISTORY_KEEP);
            (Some(h.split_off(cut)), vec![])
        }
        _ => (None, vec![]),
    };
    let m = MNet {
        net_id: cfg.net_id,
        version: cfg.version,
        netcfg: p.netcfg.clone(),
        members: b.members,
        secrets: b.secrets,
        net_root,
        me: Some(me),
        invite_hash: p.invite_hash,
        versions,
        node_secrets,
    };
    Ok((m.encode(), cfg.net_id, mnet_gen))
}

