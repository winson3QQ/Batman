//! Remove a member: the admin's side (docs/design/254-app-remove-member.md v6.4 §2.1-§2.5, §3.1, §3.3), sans-IO.
//! - `precheck`: the §3.1 preconditions and the §2.4 version check over the info answers the caller read from this
//!   phone's own nodes in the network (`own_nodes`; an unreachable node is not checked).
//! - `Rekey`: v+1 — netcfg (version / prev_hash only), members (key 11's applied / approved entries minus the excluded
//!   ones, keys 1-5, key 11's order; removed = (v's ∪ excluded) − listed) — 2 x SignAdmin, then the one record write
//!   (CAS): key 13 += v+1, keys 5-8 new, key 11 without the excluded (always written), every unused invite used.
//!   Nothing is sent to any node (§3.1).
//! - `recipients` / `UpdateBundle`: the update (qr-object kind 4) for one person, from the record read when the button
//!   was pressed and its CURRENT key 11 only (§2.3 recipient contract): {1 net_id, 2 [{1 netcfg, 2 members}] from
//!   start to the current version, 3 [net_secrets per node of that person], 4 member_secrets}. Nothing is written.
//! The record holds SAE / net_root; no type here derives Debug over it.

use sha2::{Digest, Sha256};

use crate::cbor::{self, Value};
use crate::cose;
use crate::flow::{self, JoinState};
use crate::invite::qr_hex;
use crate::joinflow;
use crate::netrec::{self, Member, MemberState, NetRec, Version, APPLIED, HISTORY_KEEP};
use crate::nodecert::hex_lower;
use crate::sig;

/// qr-object kind of an update (219-protocol.cddl, §2.3)
pub const QR_UPDATE: u64 = 4;
/// an update carries at most this many versions (§2.3: start ≥ current − 15)
pub const MAX_STEPS: u32 = 16;
/// an update's decoded size limit (§2.3)
pub const MAX_BUNDLE: usize = 128 * 1024;

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Target {
    /// every node of this owner_pub (another person)
    Person([u8; 65]),
    /// one of this phone's own nodes (lost / captured)
    Node([u8; 32]),
}

/// Why a removal does not start (§3.1 preconditions, §2.4).
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Refusal {
    Record,
    /// 1: the record is not applied
    NotApplied,
    /// 1: the admins are not exactly [this phone's admin key]
    NotSoleAdmin,
    /// 2: a joining entry other than the excluded node (its device id's last 4)
    Joining(String),
    /// 3: the person is this phone's owner
    SelfPerson,
    /// the target is not in key 11 (a person without nodes / not one of this phone's nodes)
    NoTarget,
    /// §2.4: these own nodes are at a newer version than the record (their last 4)
    NodeNewer(Vec<String>),
}

/// One own node's info answer (None = could not be read: not checked, §2.4).
pub struct NodeRead {
    pub dac_hash: [u8; 32],
    pub info: Option<Value>,
}

/// What `precheck` found.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Plan {
    /// the version about to be made (v + 1)
    pub version: u32,
    /// the entries leaving key 11
    pub excluded: Vec<Member>,
    /// no own node could vouch for the record (none left, or none answered as applied): the dialog says so (§2.4)
    pub unverified: bool,
}

/// A person's fingerprint for the screen (§3.1): the first 8 hex digits of SHA-256(owner_pub).
pub fn fingerprint(owner_pub: &[u8; 65]) -> String {
    hex_lower(&Sha256::digest(owner_pub)[..4])
}

fn last4(m: &Member) -> String {
    m.device_id.as_deref().map(|d| d[d.len().saturating_sub(4)..].to_string()).unwrap_or_default()
}

/// The own nodes whose info the caller reads before `precheck` (key 11, owner_pub = this phone's, not the target):
/// (dac_hash, device_id).
pub fn own_nodes(rec_plain: &[u8], owner_pub: &[u8; 65], target: &Target) -> Result<Vec<([u8; 32], String)>, Refusal> {
    let rec = netrec::decode(rec_plain).map_err(|_| Refusal::Record)?;
    let list = rec.members().map_err(|_| Refusal::Record)?;
    Ok(list
        .iter()
        .filter(|m| m.owner_pub == *owner_pub && Target::Node(m.dac_pub_hash) != *target)
        .filter_map(|m| m.device_id.clone().map(|d| (m.dac_pub_hash, d)))
        .collect())
}

/// §3.1 preconditions 1-4 and the §2.4 version check.
pub fn precheck(rec: &NetRec, admin_pub: &[u8; 65], owner_pub: &[u8; 65], target: &Target, reads: &[NodeRead]) -> Result<Plan, Refusal> {
    if rec.state != APPLIED {
        return Err(Refusal::NotApplied);
    }
    let cfg = rec.netcfg().map_err(|_| Refusal::Record)?;
    if cfg.admins != [*admin_pub] {
        return Err(Refusal::NotSoleAdmin);
    }
    let list = rec.members().map_err(|_| Refusal::Record)?;
    let excluded: Vec<Member> = match target {
        Target::Person(p) if p == owner_pub => return Err(Refusal::SelfPerson),
        Target::Person(p) => list.iter().filter(|m| m.owner_pub == *p).cloned().collect(),
        Target::Node(d) => list.iter().filter(|m| m.dac_pub_hash == *d && m.owner_pub == *owner_pub).cloned().collect(),
    };
    if excluded.is_empty() {
        return Err(Refusal::NoTarget);
    }
    let out = |m: &Member| excluded.iter().any(|x| x.dac_pub_hash == m.dac_pub_hash);
    if let Some(j) = list.iter().find(|m| m.state == MemberState::Joining && !out(m)) {
        return Err(Refusal::Joining(last4(j)));
    }
    let history = rec.history().map_err(|_| Refusal::Record)?;
    let v = cfg.version as u64;
    let mut newer = vec![];
    let mut vouched = false;
    for m in list.iter().filter(|m| m.owner_pub == *owner_pub && !out(m)) {
        let Some(info) = reads.iter().find(|r| r.dac_hash == m.dac_pub_hash).and_then(|r| r.info.as_ref()) else { continue };
        if !matches!(flow::join_state(info, &rec.base.net_id), JoinState::Applied { .. }) {
            continue;
        }
        let Some(k9) = info.get(9).and_then(Value::as_uint) else { continue };
        if k9 > v {
            newer.push(last4(m));
        } else if history.iter().any(|x| x.version as u64 == k9) {
            vouched = true;
        }
    }
    if !newer.is_empty() {
        return Err(Refusal::NodeNewer(newer));
    }
    Ok(Plan { version: cfg.version + 1, excluded, unverified: !vouched })
}

/// The netcfg payload of v+1: v's payload with key 2 = v+1 and key 3 = OBJECT_HASH(v's netcfg), every other field as is.
fn next_netcfg(cur: &[u8]) -> Result<Vec<u8>, Refusal> {
    let p = netrec::sign1_payload(cur).map_err(|_| Refusal::Record)?;
    let v = netrec::netcfg_of(&p).map_err(|_| Refusal::Record)?.version;
    let prev = cose::object_hash(cur).map_err(|_| Refusal::Record)?;
    let Value::Map(mut e) = p else { return Err(Refusal::Record) };
    for (k, x) in e.iter_mut() {
        match k {
            Value::Uint(2) => *x = Value::Uint(v as u64 + 1),
            Value::Uint(3) => *x = Value::Bytes(prev.to_vec()),
            _ => {}
        }
    }
    Ok(cbor::encode(&Value::Map(e)))
}

/// The members payload of v+1 (§2.4).
fn next_members(rec: &NetRec, version: u32, keep: &[Member], excluded: &[Member]) -> Result<Vec<u8>, Refusal> {
    let cur = &rec.base.members;
    let p = netrec::sign1_payload(cur).map_err(|_| Refusal::Record)?;
    let prev = cose::object_hash(cur).map_err(|_| Refusal::Record)?;
    let listed: Vec<[u8; 32]> = keep.iter().map(|m| m.dac_pub_hash).collect();
    let mut removed = netrec::removed_of(&p).map_err(|_| Refusal::Record)?;
    for m in excluded {
        if !removed.contains(&m.dac_pub_hash) {
            removed.push(m.dac_pub_hash);
        }
    }
    removed.retain(|d| !listed.contains(d));
    let entries = keep
        .iter()
        .map(|m| {
            Value::Map(vec![
                (Value::Uint(1), Value::Bytes(m.dac_pub_hash.to_vec())),
                (Value::Uint(2), Value::Bytes(m.ecdh_pub.to_vec())),
                (Value::Uint(3), Value::Text(m.name.clone())),
                (Value::Uint(4), Value::Bytes(m.owner_pub.to_vec())),
                (Value::Uint(5), Value::Bytes(m.owner_enc_pub.to_vec())),
            ])
        })
        .collect();
    let same = |k: u64| p.get(k).cloned().unwrap_or(Value::Array(vec![]));
    Ok(cbor::encode(&Value::Map(vec![
        (Value::Uint(1), Value::Bytes(rec.base.net_id.to_vec())),
        (Value::Uint(2), Value::Uint(version as u64)),
        (Value::Uint(3), Value::Bytes(prev.to_vec())),
        (Value::Uint(4), Value::Array(entries)),
        (Value::Uint(5), Value::Array(removed.into_iter().map(|d| Value::Bytes(d.to_vec())).collect())),
        (Value::Uint(6), same(6)),
        (Value::Uint(7), same(7)),
    ])))
}

/// What a removal asks for next.
#[derive(PartialEq)]
pub enum Action {
    SignAdmin { tbs: Vec<u8> },
    /// seal `plain` with aad(`rel`, expected_gen + 1), write_cas(rel, expected_gen), then `persisted` / `persist_failed`
    /// (`plain` holds the new SAE / net_root: never formatted)
    Persist { rel: String, plain: Vec<u8>, expected_gen: u64 },
    Done(End),
}

impl std::fmt::Debug for Action {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Action::SignAdmin { tbs } => write!(f, "SignAdmin({} B)", tbs.len()),
            Action::Persist { rel, plain, expected_gen } => write!(f, "Persist {{ rel: {rel:?}, plain: <{} B>, expected_gen: {expected_gen} }}", plain.len()),
            Action::Done(e) => write!(f, "Done({e:?})"),
        }
    }
}

#[derive(Debug, PartialEq, Eq)]
pub enum End {
    /// the record now holds v+1 (= `version`); nothing was sent to any node
    Committed { version: u32 },
    Refused(Refusal),
    /// the admin key did not sign: nothing written
    SignFailed,
    /// the record write failed: None = written elsewhere since it was read, else why; nothing changed
    PersistFailed(Option<String>),
    Broken(String),
}

enum RStep {
    NetCfg { payload: Vec<u8> },
    Members { netcfg: Vec<u8>, payload: Vec<u8> },
    Persist { version: u32 },
    Over,
}

/// §3.1 from the confirmation to the commit.
pub struct Rekey {
    rec: Option<NetRec>,
    plan: Option<Plan>,
    gen: u64,
    sae: String,
    net_root: [u8; 32],
    st: RStep,
}

fn random32() -> Result<[u8; 32], String> {
    let mut b = [0u8; 32];
    getrandom::fill(&mut b).map_err(|e| format!("getrandom: {e}"))?;
    Ok(b)
}

impl Rekey {
    /// `reads`: the own nodes' info answers (`own_nodes`); the checks run again here on the record read now.
    pub fn start(record_plain: &[u8], record_gen: u64, admin_pub: &[u8; 65], owner_pub: &[u8; 65], target: &Target, reads: &[NodeRead]) -> (Rekey, Action) {
        let mut r = Rekey { rec: None, plan: None, gen: record_gen, sae: String::new(), net_root: [0; 32], st: RStep::Over };
        let a = match r.begin(record_plain, admin_pub, owner_pub, target, reads) {
            Ok(a) => a,
            Err(e) => Action::Done(e),
        };
        (r, a)
    }

    fn begin(&mut self, record_plain: &[u8], admin_pub: &[u8; 65], owner_pub: &[u8; 65], target: &Target, reads: &[NodeRead]) -> Result<Action, End> {
        let rec = netrec::decode(record_plain).map_err(|_| End::Refused(Refusal::Record))?;
        let plan = precheck(&rec, admin_pub, owner_pub, target, reads).map_err(End::Refused)?;
        let payload = next_netcfg(&rec.base.netcfg).map_err(End::Refused)?;
        self.sae = joinflow::sae().map_err(End::Broken)?;
        self.net_root = random32().map_err(End::Broken)?;
        self.rec = Some(rec);
        self.plan = Some(plan);
        let tbs = cose::sign1_tbs(cose::CT_NETCFG, cose::LABEL_NETCFG, &payload);
        self.st = RStep::NetCfg { payload };
        Ok(Action::SignAdmin { tbs })
    }

    fn end(&mut self, e: End) -> Option<Action> {
        self.st = RStep::Over;
        self.net_root = [0; 32];
        Some(Action::Done(e))
    }

    /// The platform's DER signature for the last SignAdmin (empty / bad = it failed: nothing written).
    pub fn signed(&mut self, der: &[u8]) -> Option<Action> {
        if !matches!(self.st, RStep::NetCfg { .. } | RStep::Members { .. }) {
            return None;
        }
        let Ok(s) = sig::der_to_raw_low_s(der) else { return self.end(End::SignFailed) };
        match std::mem::replace(&mut self.st, RStep::Over) {
            RStep::NetCfg { payload } => {
                let netcfg = cose::sign1(cose::CT_NETCFG, &payload, &s);
                let (Some(rec), Some(plan)) = (self.rec.as_ref(), self.plan.as_ref()) else { return self.end(End::Broken("no record".into())) };
                let keep = match keep_list(rec, plan) {
                    Ok(k) => k,
                    Err(e) => return self.end(End::Refused(e)),
                };
                let members = keep.iter().filter(|m| m.state != MemberState::Joining).cloned().collect::<Vec<_>>();
                let payload = match next_members(rec, plan.version, &members, &plan.excluded) {
                    Ok(p) => p,
                    Err(e) => return self.end(End::Refused(e)),
                };
                let tbs = cose::sign1_tbs(cose::CT_MEMBERS, cose::LABEL_MEMBERS, &payload);
                self.st = RStep::Members { netcfg, payload };
                Some(Action::SignAdmin { tbs })
            }
            RStep::Members { netcfg, payload } => {
                let members = cose::sign1(cose::CT_MEMBERS, &payload, &s);
                let (Some(mut rec), Some(plan)) = (self.rec.take(), self.plan.clone()) else { return self.end(End::Broken("no record".into())) };
                let keep = match keep_list(&rec, &plan) {
                    Ok(k) => k,
                    Err(e) => return self.end(End::Refused(e)),
                };
                let mut h = match rec.history() {
                    Ok(h) => h,
                    Err(_) => return self.end(End::Refused(Refusal::Record)),
                };
                h.push(Version { version: plan.version, netcfg: netcfg.clone(), members: members.clone() });
                let cut = h.len().saturating_sub(HISTORY_KEEP);
                rec.versions = Some(h.split_off(cut));
                rec.base.netcfg = netcfg;
                rec.base.members = members;
                rec.base.sae = std::mem::take(&mut self.sae);
                rec.base.net_root = self.net_root;
                self.net_root = [0; 32];
                // key 11 is always written as the list itself (also when empty: never None, review r9 B-m5)
                rec.list = Some(keep);
                // key 14: who left (v6.5) — the newest entry per node
                let d = rec.departed.get_or_insert_with(Vec::new);
                for m in &plan.excluded {
                    d.retain(|x| x.dac_hash != m.dac_pub_hash);
                    d.push(netrec::Departed { dac_hash: m.dac_pub_hash, owner_pub: m.owner_pub, name: m.name.clone() });
                }
                for i in rec.invites.iter_mut().flatten() {
                    i.used = true;
                }
                let rel = format!("net/{}", hex_lower(&rec.base.net_id));
                let plain = netrec::encode(&rec);
                clear_secrets(&mut rec);
                self.st = RStep::Persist { version: plan.version };
                Some(Action::Persist { rel, plain, expected_gen: self.gen })
            }
            _ => None,
        }
    }

    pub fn persisted(&mut self) -> Option<Action> {
        let RStep::Persist { version } = std::mem::replace(&mut self.st, RStep::Over) else { return None };
        Some(Action::Done(End::Committed { version }))
    }

    pub fn persist_failed(&mut self, error: Option<String>) -> Option<Action> {
        let RStep::Persist { .. } = std::mem::replace(&mut self.st, RStep::Over) else { return None };
        Some(Action::Done(End::PersistFailed(error)))
    }
}

impl Drop for Rekey {
    /// the new SAE / net_root of a removal that did not commit (or the copies left after it did) are cleared
    fn drop(&mut self) {
        self.net_root = [0; 32];
        // the SAE bytes overwritten in place
        let mut b = std::mem::take(&mut self.sae).into_bytes();
        b.iter_mut().for_each(|x| *x = 0);
        if let Some(r) = self.rec.as_mut() {
            clear_secrets(r);
        }
    }
}

/// key 11 without the excluded entries, in key 11's order
fn keep_list(rec: &NetRec, plan: &Plan) -> Result<Vec<Member>, Refusal> {
    let list = rec.members().map_err(|_| Refusal::Record)?;
    Ok(list.into_iter().filter(|m| !plan.excluded.iter().any(|x| x.dac_pub_hash == m.dac_pub_hash)).collect())
}

// ---- §3.3 the updates for the members ----

/// One person who may still need an update (key 11, owner_pub ≠ this phone's, key 10 < current), for the screen.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Recipient {
    pub owner_pub: [u8; 65],
    pub name: String,
    /// the device ids' last 4 of this person's nodes
    pub nodes: Vec<String>,
    /// an entry without key 10 while key 13's oldest version > 1 (after a downgrade and upgrade): 「升級前的版本不明」
    pub unknown_before: bool,
    /// an approved entry still behind (an approval made before a removal and maybe not used yet): the paste-order line
    pub old_approval: bool,
}

/// §3.3's list, in key 11's order (grouped by owner_pub).
pub fn recipients(rec: &NetRec, owner_pub: &[u8; 65]) -> Result<Vec<Recipient>, netrec::Error> {
    let cur = rec.netcfg()?.version;
    let oldest = rec.history()?.first().map(|x| x.version).unwrap_or(1);
    let list = rec.members()?;
    let mut out: Vec<Recipient> = vec![];
    for m in list.iter().filter(|m| m.owner_pub != *owner_pub) {
        if out.iter().any(|r| r.owner_pub == m.owner_pub) {
            continue;
        }
        let mine: Vec<&Member> = list.iter().filter(|x| x.owner_pub == m.owner_pub).collect();
        let mut behind = false;
        let mut old_approval = false;
        for x in &mine {
            let k = rec.known_of(x)?;
            behind |= k < cur;
            old_approval |= x.state == MemberState::Approved && k < cur;
        }
        if !behind {
            continue;
        }
        out.push(Recipient {
            owner_pub: m.owner_pub,
            name: m.name.clone(),
            nodes: mine.iter().map(|x| last4(x)).collect(),
            unknown_before: mine.iter().any(|x| x.known.is_none()) && oldest > 1,
            old_approval,
        });
    }
    Ok(out)
}

/// Why an update is not made (§2.3).
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum BundleRefusal {
    Record,
    NotApplied,
    NotAdmin,
    /// no entry of this owner_pub in key 11 now (e.g. removed since the screen was drawn), or it is this phone's own
    NotRecipient,
    /// the person's entries do not agree on owner_enc_pub: 「請先移除這個人,再重新邀請」
    Inconsistent,
    /// the person already holds the current version
    Current,
    /// over MAX_BUNDLE
    TooLarge,
}

#[derive(Debug, PartialEq, Eq)]
pub enum BundleEnd {
    /// the qr-object kind 4 hex to hand over
    Out { hex: String },
    Refused(BundleRefusal),
    SignFailed,
    Broken(String),
}

#[derive(PartialEq)]
pub enum BundleAction {
    SignAdmin { tbs: Vec<u8> },
    Done(BundleEnd),
}

impl std::fmt::Debug for BundleAction {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            BundleAction::SignAdmin { tbs } => write!(f, "SignAdmin({} B)", tbs.len()),
            BundleAction::Done(e) => write!(f, "Done({e:?})"),
        }
    }
}

/// net_secrets payload ({1 SAE, 2 net_root} to `to`, key 3 = `target`) or member_secrets payload ({2 net_root}).
pub(crate) fn secrets_payload(rec: &NetRec, version: u32, to: &[u8; 65], target: &[u8; 32], member: bool) -> Result<Vec<u8>, String> {
    let mut m = Value::Map(vec![(Value::Uint(2), Value::Bytes(rec.base.net_root.to_vec()))]);
    if !member {
        if let Value::Map(e) = &mut m {
            e.push((Value::Uint(1), Value::Text(rec.base.sae.clone())));
        }
    }
    let mut plain = cbor::encode(&m);
    // the Value copies are cleared too (code review r1 B-m2)
    if let Value::Map(e) = &mut m {
        for (_, x) in e.iter_mut() {
            match x {
                Value::Bytes(b) => b.iter_mut().for_each(|y| *y = 0),
                Value::Text(t) => {
                    // overwrite the bytes themselves, not only drop the buffer (code review r2 A-m1)
                    let mut b = std::mem::take(t).into_bytes();
                    b.iter_mut().for_each(|y| *y = 0);
                }
                _ => {}
            }
        }
    }
    let label = if member { cose::LABEL_MSECRETS } else { cose::LABEL_SECRETS };
    let enc = cose::encrypt_to(&plain, label, to, target, &rec.base.net_id, version);
    plain.iter_mut().for_each(|b| *b = 0);
    let enc = enc.map_err(|e| format!("{e:?}"))?;
    Ok(cose::net_secrets_payload(&rec.base.net_id, version, target, &enc.object))
}

/// SAE / net_root of a record copy overwritten (code review r2 A-m1: best effort, the copies this crate holds)
pub(crate) fn clear_secrets(r: &mut NetRec) {
    r.base.net_root = [0; 32];
    let mut b = std::mem::take(&mut r.base.sae).into_bytes();
    b.iter_mut().for_each(|y| *y = 0);
}

impl Drop for UpdateBundle {
    /// the record copy is cleared when the bundle is dropped before it finished
    fn drop(&mut self) {
        if let Some(r) = self.rec.as_mut() {
            clear_secrets(r);
        }
    }
}

/// §2.3 for one person: N net_secrets + 1 member_secrets, each signed, then the hex.
pub struct UpdateBundle {
    rec: Option<NetRec>,
    version: u32,
    chain: Vec<Version>,
    nodes: Vec<Member>,
    enc_pub: [u8; 65],
    signed: Vec<Vec<u8>>,
    payload: Vec<u8>,
    over: bool,
}

impl UpdateBundle {
    /// `record_plain`: the record read when the button was pressed; `person`: the owner_pub chosen on the screen.
    pub fn start(record_plain: &[u8], admin_pub: &[u8; 65], owner_pub: &[u8; 65], person: &[u8; 65]) -> (UpdateBundle, BundleAction) {
        let mut b = UpdateBundle { rec: None, version: 0, chain: vec![], nodes: vec![], enc_pub: [0; 65], signed: vec![], payload: vec![], over: true };
        let a = match b.begin(record_plain, admin_pub, owner_pub, person) {
            Ok(a) => a,
            Err(e) => BundleAction::Done(BundleEnd::Refused(e)),
        };
        (b, a)
    }

    fn begin(&mut self, record_plain: &[u8], admin_pub: &[u8; 65], owner_pub: &[u8; 65], person: &[u8; 65]) -> Result<BundleAction, BundleRefusal> {
        let rec = netrec::decode(record_plain).map_err(|_| BundleRefusal::Record)?;
        if rec.state != APPLIED {
            return Err(BundleRefusal::NotApplied);
        }
        let cfg = rec.netcfg().map_err(|_| BundleRefusal::Record)?;
        if !cfg.admins.contains(admin_pub) {
            return Err(BundleRefusal::NotAdmin);
        }
        if person == owner_pub {
            return Err(BundleRefusal::NotRecipient);
        }
        let nodes: Vec<Member> = rec.members().map_err(|_| BundleRefusal::Record)?.into_iter().filter(|m| m.owner_pub == *person).collect();
        let Some(first) = nodes.first() else { return Err(BundleRefusal::NotRecipient) };
        if nodes.iter().any(|m| m.owner_enc_pub != first.owner_enc_pub) {
            return Err(BundleRefusal::Inconsistent);
        }
        let mut known = u32::MAX;
        for m in &nodes {
            known = known.min(rec.known_of(m).map_err(|_| BundleRefusal::Record)?);
        }
        let cur = cfg.version;
        if known >= cur {
            return Err(BundleRefusal::Current);
        }
        let history = rec.history().map_err(|_| BundleRefusal::Record)?;
        let oldest = history.first().map(|x| x.version).unwrap_or(cur);
        let start = (known + 1).max(cur.saturating_sub(MAX_STEPS - 1)).max(oldest);
        let chain: Vec<Version> = history.into_iter().filter(|x| x.version >= start && x.version <= cur).collect();
        if chain.first().map(|x| x.version) != Some(start) || chain.last().map(|x| x.version) != Some(cur) {
            return Err(BundleRefusal::Record);
        }
        self.enc_pub = first.owner_enc_pub;
        self.version = cur;
        self.chain = chain;
        self.nodes = nodes;
        self.rec = Some(rec);
        self.over = false;
        self.next().ok_or(BundleRefusal::Record)
    }

    /// the next SignAdmin: the i-th node's net_secrets, then the member_secrets
    fn next(&mut self) -> Option<BundleAction> {
        let rec = self.rec.as_ref()?;
        let i = self.signed.len();
        let r = if let Some(m) = self.nodes.get(i) {
            secrets_payload(rec, self.version, &m.ecdh_pub, &m.dac_pub_hash, false).map(|p| (p, cose::CT_SECRETS, cose::LABEL_SECRETS))
        } else {
            let target: [u8; 32] = Sha256::digest(self.enc_pub).into();
            secrets_payload(rec, self.version, &self.enc_pub, &target, true).map(|p| (p, cose::CT_MSECRETS, cose::LABEL_MSECRETS))
        };
        match r {
            Ok((p, ct, label)) => {
                let tbs = cose::sign1_tbs(ct, label, &p);
                self.payload = p;
                Some(BundleAction::SignAdmin { tbs })
            }
            Err(e) => self.done(BundleEnd::Broken(e)),
        }
    }

    fn done(&mut self, e: BundleEnd) -> Option<BundleAction> {
        self.over = true;
        if let Some(r) = self.rec.as_mut() {
            clear_secrets(r);
        }
        self.rec = None;
        Some(BundleAction::Done(e))
    }

    pub fn signed(&mut self, der: &[u8]) -> Option<BundleAction> {
        if self.over {
            return None;
        }
        let Ok(s) = sig::der_to_raw_low_s(der) else { return self.done(BundleEnd::SignFailed) };
        let ct = if self.signed.len() < self.nodes.len() { cose::CT_SECRETS } else { cose::CT_MSECRETS };
        self.signed.push(cose::sign1(ct, &self.payload, &s));
        if self.signed.len() <= self.nodes.len() {
            return self.next();
        }
        let item = |b: &[u8]| cbor::decode(b).map_err(|e| format!("{e:?}"));
        let build = || -> Result<Vec<u8>, String> {
            let steps = self
                .chain
                .iter()
                .map(|x| Ok(Value::Map(vec![(Value::Uint(1), item(&x.netcfg)?), (Value::Uint(2), item(&x.members)?)])))
                .collect::<Result<Vec<_>, String>>()?;
            let n = self.nodes.len();
            let secrets = self.signed[..n].iter().map(|s| item(s)).collect::<Result<Vec<_>, String>>()?;
            let rec = self.rec.as_ref().ok_or("no record")?;
            Ok(cbor::encode(&Value::Map(vec![
                (Value::Uint(1), Value::Bytes(rec.base.net_id.to_vec())),
                (Value::Uint(2), Value::Array(steps)),
                (Value::Uint(3), Value::Array(secrets)),
                (Value::Uint(4), item(&self.signed[n])?),
            ])))
        };
        match build() {
            Ok(b) if b.len() > MAX_BUNDLE => self.done(BundleEnd::Refused(BundleRefusal::TooLarge)),
            Ok(b) => self.done(BundleEnd::Out { hex: qr_hex(QR_UPDATE, &b) }),
            Err(e) => self.done(BundleEnd::Broken(e)),
        }
    }
}
