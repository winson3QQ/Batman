//! Remove a member: a member phone imports the admin's update (docs/design/254-app-remove-member.md v6.4 §3.4),
//! sans-IO, in two parts like the approval import (approve.rs): `prepare` checks everything it can without the ECDH
//! (rules 1-6) against mnet as read (its generation); Kotlin does the ECDH with the member_secrets' ephemeral key;
//! `import` checks everything again with the same generation, decrypts net_root and returns the new mnet (key 9 +
//! the new versions, keys 2-6 the current one, key 5 = the key 7 node's secrets, key 10 = this version's secrets of
//! the own nodes). Nothing is written here; trust comes only from the admin signatures and the encryption to this
//! phone's / its nodes' keys.

use sha2::{Digest, Sha256};

use crate::cbor::{self, Value};
use crate::cose;
use crate::invite::qr_object;
use crate::mrec::{MNet, NodeSecrets};
use crate::netrec::{self, NetCfg, Version, HISTORY_KEEP};
use crate::nodecert::hex_lower;
use crate::rekey::{MAX_BUNDLE, MAX_STEPS, QR_UPDATE};

/// Why an update is not imported (§3.4).
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Refusal {
    /// 1: not an update / its shape / its size
    Format(&'static str),
    /// 1: no mnet for its net_id: 「請先匯入網主的同意」
    NoNetwork,
    /// 2: a version this phone holds differs byte for byte: another history (warn)
    Fork,
    /// 2: the first new version is not mnet's + 1: 「你的資料太舊…」
    TooOld,
    /// the update's current version is older than mnet's: 「這份更新包比你的紀錄舊,已忽略」
    Older,
    /// 2 / 3: a signature, a link or a payload that does not check (named)
    Invalid(&'static str),
    /// 4: no net_secrets for any node of this phone
    NotForMe,
    /// 4: advancing without the key 7 node's secrets (its last 4)
    MissingOwn(String),
    /// 5
    NotForThisPhone,
    /// 6: an own node with secrets in the update is removed in that version (its last 4)
    Removed(String),
    /// the record changed since `prepare`: 「請網主再複製一次你的包,再貼上」
    Stale,
    Aead,
}

impl From<cose::Error> for Refusal {
    fn from(e: cose::Error) -> Self {
        match e {
            cose::Error::Malformed(w) => Refusal::Invalid(w),
            cose::Error::Aead => Refusal::Aead,
            _ => Refusal::Invalid("signature"),
        }
    }
}

/// One own node of this phone: its DAC hash and device id (node/ records).
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct OwnNode {
    pub dac_hash: [u8; 32],
    pub device_id: String,
}

fn last4(d: &str) -> String {
    d[d.len().saturating_sub(4)..].to_string()
}

struct Parsed {
    net_id: [u8; 16],
    steps: Vec<Version>,
    secrets: Vec<Vec<u8>>,
    msecrets: Vec<u8>,
}

fn sign1_item(v: &Value) -> Result<Vec<u8>, Refusal> {
    match v {
        x @ Value::Tag(18, _) => Ok(cbor::encode(x)),
        _ => Err(Refusal::Format("an item is not a COSE_Sign1")),
    }
}

fn version_of(netcfg: &[u8]) -> Result<u32, Refusal> {
    let p = netrec::sign1_payload(netcfg).map_err(|_| Refusal::Format("netcfg"))?;
    p.get(2).and_then(Value::as_uint).and_then(|n| u32::try_from(n).ok()).ok_or(Refusal::Format("netcfg version"))
}

/// Rule 1: hex -> qr-object kind 4 -> exact shape, ≤ 16 steps, ≤ 128 KiB decoded (before any signature).
fn parse(hex: &str) -> Result<Parsed, Refusal> {
    // the size first, on the pasted text itself (code review r1 B-m4): 2 hex digits a byte + the qr-object wrapping
    if hex.bytes().filter(|b| !b.is_ascii_whitespace()).count() > 2 * (MAX_BUNDLE + 16) {
        return Err(Refusal::Format("too large"));
    }
    let raw = qr_object(hex, QR_UPDATE).map_err(|_| Refusal::Format("not an update"))?;
    if raw.len() > MAX_BUNDLE {
        return Err(Refusal::Format("too large"));
    }
    let v = cbor::decode(&raw).map_err(|_| Refusal::Format("not deterministic CBOR"))?;
    cose::exact_keys(&v, &[1, 2, 3, 4], &[]).map_err(|_| Refusal::Format("update keys"))?;
    let net_id: [u8; 16] = v.get(1).and_then(Value::as_bytes).and_then(|b| b.try_into().ok()).ok_or(Refusal::Format("net_id"))?;
    let Some(Value::Array(st)) = v.get(2) else { return Err(Refusal::Format("steps")) };
    if st.is_empty() || st.len() > MAX_STEPS as usize {
        return Err(Refusal::Format("steps"));
    }
    let mut steps = vec![];
    for s in st {
        cose::exact_keys(s, &[1, 2], &[]).map_err(|_| Refusal::Format("step keys"))?;
        let netcfg = sign1_item(s.get(1).unwrap_or(&Value::Null))?;
        let members = sign1_item(s.get(2).unwrap_or(&Value::Null))?;
        steps.push(Version { version: version_of(&netcfg)?, netcfg, members });
    }
    if steps.windows(2).any(|w| w[1].version != w[0].version.wrapping_add(1)) {
        return Err(Refusal::Format("steps are not contiguous"));
    }
    let Some(Value::Array(se)) = v.get(3) else { return Err(Refusal::Format("secrets")) };
    if se.is_empty() || se.len() > netrec::MAX_MEMBERS {
        return Err(Refusal::Format("secrets"));
    }
    let secrets = se.iter().map(sign1_item).collect::<Result<Vec<_>, _>>()?;
    let msecrets = sign1_item(v.get(4).unwrap_or(&Value::Null))?;
    Ok(Parsed { net_id, steps, secrets, msecrets })
}

/// The net_id an update names (parsed only: it picks which mnet to read, never trusted).
pub fn update_net_id(hex: &str) -> Result<String, Refusal> {
    Ok(hex_lower(&parse(hex)?.net_id))
}

/// A members payload of version `ver` of `net_id`, prev_hash = `prev` (exact keys, nested entries too).
fn members_ok(p: &Value, net_id: &[u8; 16], ver: u32, prev: &[u8; 32]) -> Result<(), Refusal> {
    cose::exact_keys(p, &[1, 2, 3, 4, 5, 6, 7], &[]).map_err(|_| Refusal::Invalid("members keys"))?;
    let Some(Value::Array(list)) = p.get(4) else { return Err(Refusal::Invalid("members keys")) };
    for m in list {
        if !netrec::member_entry_ok(m) {
            return Err(Refusal::Invalid("member entry keys"));
        }
    }
    if ![5, 6, 7].iter().all(|k| matches!(p.get(*k), Some(Value::Array(_)))) {
        return Err(Refusal::Invalid("members keys"));
    }
    if p.get(1).and_then(Value::as_bytes) != Some(&net_id[..]) || p.get(2).and_then(Value::as_uint) != Some(ver as u64) {
        return Err(Refusal::Invalid("members net_id / version"));
    }
    if p.get(3).and_then(Value::as_bytes) != Some(&prev[..]) {
        return Err(Refusal::Invalid("members prev_hash"));
    }
    Ok(())
}

/// A secrets / msecrets payload of this net_id / version (exact keys).
fn secrets_ok(p: &Value, net_id: &[u8; 16], ver: u32) -> Result<(), Refusal> {
    cose::exact_keys(p, &[1, 2, 3, 4], &[]).map_err(|_| Refusal::Invalid("secrets keys"))?;
    if p.get(1).and_then(Value::as_bytes) != Some(&net_id[..]) || p.get(2).and_then(Value::as_uint) != Some(ver as u64) {
        return Err(Refusal::Invalid("secrets net_id / version"));
    }
    Ok(())
}

/// What the checks found (no ECDH yet).
struct Checked {
    /// the versions after mnet's (empty: the same version)
    new: Vec<Version>,
    /// the current version's admins (= the previous one's, the invariant): what signed the secrets
    cur: u32,
    /// (own node dac, its net_secrets)
    mine: Vec<NodeSecrets>,
    ms_enc: Value,
    ms_target: [u8; 32],
}

/// Rules 1-6 against mnet.
fn check(p: &Parsed, x: &MNet, own: &[OwnNode], owner_enc_pub: &[u8; 65]) -> Result<Checked, Refusal> {
    if p.net_id != x.net_id {
        return Err(Refusal::NoNetwork);
    }
    let last = p.steps.last().map(|s| s.version).unwrap_or(0);
    if last < x.version {
        return Err(Refusal::Older);
    }
    // rule 2: what this phone holds is compared byte for byte; older than its history is skipped
    let held = x.history();
    let oldest = held.first().map(|v| v.version).unwrap_or(x.version);
    let mut new = vec![];
    for s in &p.steps {
        if s.version <= x.version {
            if s.version < oldest {
                continue;
            }
            match held.iter().find(|h| h.version == s.version) {
                Some(h) if h.netcfg == s.netcfg && h.members == s.members => {}
                // another history only when it is signed (by the stored admins: the invariant); an unsigned edit is
                // just invalid, no fork warning (code review r1 B-m3)
                Some(_) => {
                    let admins = x.netcfg().map_err(|_| Refusal::Invalid("stored netcfg"))?.admins;
                    cose::verify_sign1(&s.netcfg, cose::CT_NETCFG, cose::LABEL_NETCFG, &admins)?;
                    cose::verify_sign1(&s.members, cose::CT_MEMBERS, cose::LABEL_MEMBERS, &admins)?;
                    return Err(Refusal::Fork);
                }
                None => continue,
            }
        } else {
            new.push(s.clone());
        }
    }
    if new.first().is_some_and(|s| s.version != x.version + 1) {
        return Err(Refusal::TooOld);
    }
    // the chain from mnet's version: netcfg signed by the previous admins, prev_hash / version / net_id / country;
    // members signed by the previous admins, net_id / version, prev_hash
    let mut prev_cfg: NetCfg = x.netcfg().map_err(|_| Refusal::Invalid("stored netcfg"))?;
    let mut prev_cfg_hash = cose::object_hash(&x.netcfg)?;
    let mut prev_mem_hash = cose::object_hash(&x.members)?;
    // the admins valid for the current version = the previous version's (node §7.1; by the invariant the same set)
    let mut signers = prev_cfg.admins.clone();
    for s in &new {
        let c = cose::verify_sign1(&s.netcfg, cose::CT_NETCFG, cose::LABEL_NETCFG, &prev_cfg.admins)?;
        let cfg = netrec::netcfg_of(&c.payload).map_err(|_| Refusal::Invalid("netcfg keys"))?;
        if cfg.version != prev_cfg.version + 1 || cfg.prev_hash != Some(prev_cfg_hash) || cfg.net_id != x.net_id {
            return Err(Refusal::Invalid("not the next version"));
        }
        if cfg.country != prev_cfg.country {
            return Err(Refusal::Invalid("country changed"));
        }
        let m = cose::verify_sign1(&s.members, cose::CT_MEMBERS, cose::LABEL_MEMBERS, &prev_cfg.admins)?;
        members_ok(&m.payload, &x.net_id, cfg.version, &prev_mem_hash)?;
        prev_cfg_hash = c.hash;
        prev_mem_hash = m.hash;
        signers = prev_cfg.admins.clone();
        prev_cfg = cfg;
    }
    // rule 3: the secrets signed by the admins valid for the current version (the stored ones when nothing is new)
    let cur = prev_cfg.version;
    let signers = &signers;
    let removed = {
        let members = new.last().map(|s| s.members.clone()).unwrap_or_else(|| x.members.clone());
        netrec::removed_of(&netrec::sign1_payload(&members).map_err(|_| Refusal::Invalid("members"))?).map_err(|_| Refusal::Invalid("removed"))?
    };
    let mut mine = vec![];
    for s in &p.secrets {
        let v = cose::verify_sign1(s, cose::CT_SECRETS, cose::LABEL_SECRETS, signers)?;
        secrets_ok(&v.payload, &x.net_id, cur)?;
        let t: [u8; 32] = v.payload.get(3).and_then(Value::as_bytes).and_then(|b| b.try_into().ok()).ok_or(Refusal::Invalid("secrets target"))?;
        // rule 4: matched against this phone's own nodes; rule 6: none of them removed in this version
        if let Some(o) = own.iter().find(|o| o.dac_hash == t) {
            if removed.contains(&t) {
                return Err(Refusal::Removed(last4(&o.device_id)));
            }
            if !mine.iter().any(|m: &NodeSecrets| m.dac_hash == t) {
                mine.push(NodeSecrets { dac_hash: t, secrets: s.clone() });
            }
        }
    }
    if mine.is_empty() {
        return Err(Refusal::NotForMe);
    }
    if !new.is_empty() {
        if let Some(me) = &x.me {
            if !mine.iter().any(|m| m.dac_hash == me.dac_pub_hash) {
                return Err(Refusal::MissingOwn(me.device_id.as_deref().map(last4).unwrap_or_default()));
            }
        }
    }
    // rule 5
    let ms = cose::verify_sign1(&p.msecrets, cose::CT_MSECRETS, cose::LABEL_MSECRETS, signers)?;
    secrets_ok(&ms.payload, &x.net_id, cur)?;
    let ms_target: [u8; 32] = Sha256::digest(owner_enc_pub).into();
    if ms.payload.get(3).and_then(Value::as_bytes) != Some(&ms_target[..]) {
        return Err(Refusal::NotForThisPhone);
    }
    let ms_enc = ms.payload.get(4).cloned().ok_or(Refusal::Invalid("member secrets"))?;
    Ok(Checked { new, cur, mine, ms_enc, ms_target })
}

/// What `prepare` found.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Prepared {
    /// new versions up to `to`: Kotlin ECDH(OWNER_ENC) with `eph_pub`, then `import` with the same `mnet_gen`
    Advance { to: u32, eph_pub: [u8; 65], mnet_gen: u64 },
    /// the same version, with own-node secrets mnet key 10 lacks: `import` (no ECDH) writes them
    AddSecrets { mnet_gen: u64 },
    /// the same version, nothing new: 「已經匯入過」
    AlreadyImported,
}

fn mnet_of(mnet: Option<&[u8]>) -> Result<MNet, Refusal> {
    MNet::decode(mnet.ok_or(Refusal::NoNetwork)?).map_err(|_| Refusal::Invalid("stored network"))
}

/// mnet has no current-version secrets for one of `mine` (B-m4: only then the same version writes)
fn adds(x: &MNet, mine: &[NodeSecrets]) -> bool {
    mine.iter().any(|m| x.secrets_for(&m.dac_hash).is_none())
}

/// §3.4 first part. `mnet`: mnet/<net_id> as read (plain) and its generation.
pub fn prepare(hex: &str, mnet: Option<&[u8]>, mnet_gen: u64, own: &[OwnNode], owner_enc_pub: &[u8; 65]) -> Result<Prepared, Refusal> {
    let p = parse(hex)?;
    let x = mnet_of(mnet)?;
    let c = check(&p, &x, own, owner_enc_pub)?;
    if c.new.is_empty() {
        return Ok(if adds(&x, &c.mine) { Prepared::AddSecrets { mnet_gen } } else { Prepared::AlreadyImported });
    }
    let eph_pub = cose::recipient_eph(&c.ms_enc)?;
    Ok(Prepared::Advance { to: c.cur, eph_pub, mnet_gen })
}

/// §3.4 second part: everything again on mnet read now (its generation must still be `expected_gen`), then the new
/// mnet. `z`: Kotlin's ECDH x coordinate (Advance; None for AddSecrets). Returns (mnet plain, net_id, the generation
/// to write from). z / the plaintext are cleared here.
pub fn import(hex: &str, mnet: Option<&[u8]>, mnet_gen: u64, expected_gen: u64, own: &[OwnNode], owner_enc_pub: &[u8; 65], z: Option<&[u8; 32]>) -> Result<(Vec<u8>, [u8; 16], u64), Refusal> {
    if mnet_gen != expected_gen {
        return Err(Refusal::Stale);
    }
    let p = parse(hex)?;
    let mut x = mnet_of(mnet)?;
    let c = check(&p, &x, own, owner_enc_pub)?;
    if c.new.is_empty() {
        if !adds(&x, &c.mine) {
            return Err(Refusal::Stale);
        }
        merge(&mut x, &c.mine);
        return Ok((x.encode(), x.net_id, mnet_gen));
    }
    let z = z.ok_or(Refusal::Stale)?;
    cose::recipient_eph(&c.ms_enc)?;
    let mut pt = cose::decrypt(&c.ms_enc, cose::LABEL_MSECRETS, &c.ms_target, &x.net_id, c.cur, z)?;
    let parsed = cbor::decode(&pt).ok();
    pt.iter_mut().for_each(|b| *b = 0);
    let mut v = parsed.ok_or(Refusal::Invalid("member secrets plaintext"))?;
    let shape = cose::exact_keys(&v, &[2], &[]).map_err(|_| Refusal::Invalid("member secrets plaintext is not {2: net_root}"));
    let net_root: Option<[u8; 32]> = v.get(2).and_then(Value::as_bytes).and_then(|b| b.try_into().ok());
    // the decoded copy is cleared too (code review r1 B-m2)
    if let Value::Map(e) = &mut v {
        for (_, x) in e.iter_mut() {
            if let Value::Bytes(b) = x {
                b.iter_mut().for_each(|y| *y = 0);
            }
        }
    }
    shape?;
    let net_root = net_root.ok_or(Refusal::Invalid("net_root"))?;
    let mut h = x.history();
    h.extend(c.new.iter().cloned());
    let cut = h.len().saturating_sub(HISTORY_KEEP);
    let last = c.new.last().cloned().ok_or(Refusal::Invalid("no version"))?;
    x.versions = Some(h.split_off(cut));
    x.version = last.version;
    x.netcfg = last.netcfg;
    x.members = last.members;
    x.net_root = net_root;
    // key 5 = the key 7 node's new secrets (rule 4 made sure they are here); key 10 = this version's own secrets
    if let Some(me) = &x.me {
        if let Some(s) = c.mine.iter().find(|m| m.dac_hash == me.dac_pub_hash) {
            x.secrets = s.secrets.clone();
        }
    }
    x.node_secrets = c.mine;
    let out = x.encode();
    x.net_root = [0; 32];
    Ok((out, x.net_id, mnet_gen))
}

/// the same version: own-node secrets added to / replaced in key 10 (key 5 too for the key 7 node)
fn merge(x: &mut MNet, mine: &[NodeSecrets]) {
    for m in mine.iter().filter(|m| x.secrets_for(&m.dac_hash).is_none()).cloned().collect::<Vec<_>>().iter() {
        if x.me.as_ref().is_some_and(|me| me.dac_pub_hash == m.dac_hash) {
            x.secrets = m.secrets.clone();
        }
        x.node_secrets.retain(|n| n.dac_hash != m.dac_hash);
        x.node_secrets.push(m.clone());
    }
}
