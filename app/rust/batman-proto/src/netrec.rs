//! The net record `net/<net_id>` (254-app-s1 §3 / §5.4; 254-app-join2 v7.1 §3.1), as CBOR:
//!   {1 net_id, 2 mesh_id, 3 channel, 4 bw, 5 SAE, 6 net_root, 7 signed net_config v1, 8 signed members v1,
//!    9 the first node's net_secrets, 10 state "pending" / "applied", ?11 member list}.
//! Key 11, one entry per node = {1 dac_pub_hash, 2 ecdh_pub, 3 name, 4 owner_pub, 5 owner_enc_pub, ?6 device_id,
//! 8 state "joining" / "applied" / "approved", ?9 prev_country}; keys 1-5 are the members v1 entry keys.
//! ?12 = the invites this admin phone issued: [{1 invite_hash (OBJECT_HASH), 2 kind, 3 used}] (member-join §3;
//! "approved" = a remote member this phone approved, member-join §3). A node is its
//! dac_pub_hash: one entry per node (replaced, never added twice). No net_secrets are kept per member (each join makes
//! them afresh). A record without key 11 (written by 36e2f57) gets its list from key 8: the members v1 entries, state
//! applied when key 10 is "applied", else joining.
//! Remove member (254-app-remove-member v6.4 §2.1): ?13 = the versions [{1 version, 2 netcfg Sign1, 3 members Sign1}]
//! (increasing, contiguous, the last 32; absent = one version made from keys 7 / 8); keys 5-8 are the current version.
//! A key 11 entry's ?10 = the version its owner surely holds (set when this phone approved it; absent = the oldest
//! version of key 13 − 1). Key 10 is in key 11 only, never in a member's mnet key 7. Key 9 is no longer read.
//! ?14 = every entry a removal excluded [{1 dac_hash, 2 owner_pub, 3 name}] (only grows; v6.5, code review r1 MAJOR:
//! an entry approved after version v and removed at v+1 is in no members list, so "removed before" and "the previous
//! owner" look here first; an older app drops it on write -> back to the members lists, an honest limit).
//! The record holds SAE / net_root: it leaves Rust only to be sealed by the platform; nothing here formats it.

use sha2::{Digest, Sha256};

use crate::cbor::{self, Value};
use crate::flow::{self, JoinState};
use crate::joinflow::NetRecord;

/// The app's own cap on members (join2 §3.3-1d; the node has none).
pub const MAX_MEMBERS: usize = 16;
pub const PENDING: &str = "pending";
pub const APPLIED: &str = "applied";
/// key 13 keeps the last this many versions (§2.1, §2.5)
pub const HISTORY_KEEP: usize = 32;

#[derive(Debug, PartialEq, Eq)]
pub enum Error {
    Cbor(cbor::Error),
    Field(&'static str),
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum MemberState {
    Joining,
    Applied,
    /// a remote member's node this admin approved (member-join §3): it joins with the approval, not through this phone
    Approved,
}

/// One issued invite (key 12): its OBJECT_HASH, kind (1 = remote) and whether an approval used it.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct InviteRec {
    pub hash: [u8; 32],
    pub kind: u64,
    pub used: bool,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Member {
    pub dac_pub_hash: [u8; 32],
    pub ecdh_pub: [u8; 65],
    pub name: String,
    pub owner_pub: [u8; 65],
    pub owner_enc_pub: [u8; 65],
    pub device_id: Option<String>,
    pub state: MemberState,
    /// the node's country before this phone changed it for the join (join2 §3.3-3); kept until it is put back or the
    /// join is applied
    pub prev_country: Option<String>,
    /// key 10 (net records only): the version this node's owner surely holds (remove-member §2.1)
    pub known: Option<u32>,
    /// key 7 (254-app-team-status §4.2): the node's mesh address (a members entry key; written from version N+1)
    pub mesh_addr: Option<[u8; 6]>,
}

/// An entry a removal excluded (net key 14).
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Departed {
    pub dac_hash: [u8; 32],
    pub owner_pub: [u8; 65],
    pub name: String,
}

/// One version of the network (net key 13 / mnet key 9): the signed netcfg and members.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Version {
    pub version: u32,
    pub netcfg: Vec<u8>,
    pub members: Vec<u8>,
}

/// A decoded net record. `list` is key 11 as stored (None = an old record: `members()` derives it).
#[derive(Clone, PartialEq, Eq)]
pub struct NetRec {
    pub base: NetRecord,
    pub state: String,
    pub list: Option<Vec<Member>>,
    /// key 12 as stored (None = never issued one)
    pub invites: Option<Vec<InviteRec>>,
    /// key 13 as stored (None = an older record: `history()` derives one version from keys 7 / 8)
    pub versions: Option<Vec<Version>>,
    /// key 14 as stored (None = no removal yet, or written by an older app)
    pub departed: Option<Vec<Departed>>,
}

/// What a signed net_config says (the parts the app checks).
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct NetCfg {
    pub net_id: [u8; 16],
    pub version: u32,
    pub prev_hash: Option<[u8; 32]>,
    pub name: String,
    pub country: String,
    pub admins: Vec<[u8; 65]>,
}

/// A net_config payload parsed strictly (CDDL net-config; unknown keys refused, the nested halow / lora maps too).
pub fn netcfg_of(p: &Value) -> Result<NetCfg, Error> {
    use crate::cose::exact_keys;
    let bad = |_| Error::Field("net_config keys");
    exact_keys(p, &[1, 2, 3, 4, 5, 6, 8], &[7]).map_err(bad)?;
    exact_keys(p.get(6).unwrap_or(&Value::Null), &[1, 2, 3], &[]).map_err(bad)?;
    if let Some(l) = p.get(7) {
        exact_keys(l, &[1, 2], &[]).map_err(bad)?;
    }
    let admins = match p.get(8) {
        Some(Value::Array(a)) if !a.is_empty() => a.iter().map(|x| arr(Some(x), "admin")).collect::<Result<Vec<_>, _>>()?,
        _ => return Err(Error::Field("admins")),
    };
    let prev_hash = match p.get(3) {
        Some(Value::Null) => None,
        x => Some(arr(x, "netcfg prev_hash")?),
    };
    Ok(NetCfg {
        net_id: arr(p.get(1), "netcfg net_id")?,
        version: f(p.get(2).and_then(Value::as_uint).and_then(|n| u32::try_from(n).ok()), "netcfg version")?,
        prev_hash,
        name: f(p.get(4).and_then(Value::as_text), "netcfg name")?.to_string(),
        country: f(p.get(5).and_then(Value::as_text), "netcfg country")?.to_string(),
        admins,
    })
}

fn f<T>(o: Option<T>, what: &'static str) -> Result<T, Error> {
    o.ok_or(Error::Field(what))
}

fn arr<const N: usize>(v: Option<&Value>, what: &'static str) -> Result<[u8; N], Error> {
    f(v.and_then(Value::as_bytes).and_then(|b| b.try_into().ok()), what)
}

/// The payload of a COSE_Sign1 (tag 18 [protected, {}, payload, sig]), decoded. The signature is not checked: the
/// record is this phone's own, read from its sealed store.
pub fn sign1_payload(obj: &[u8]) -> Result<Value, Error> {
    let v = cbor::decode(obj).map_err(Error::Cbor)?;
    let Value::Tag(18, a) = v else { return Err(Error::Field("not a COSE_Sign1")) };
    let Value::Array(a) = *a else { return Err(Error::Field("not a COSE_Sign1")) };
    let p = f(a.get(2).and_then(Value::as_bytes), "Sign1 payload")?;
    cbor::decode(p).map_err(Error::Cbor)
}

fn state_text(s: MemberState) -> &'static str {
    match s {
        MemberState::Joining => "joining",
        MemberState::Applied => "applied",
        MemberState::Approved => "approved",
    }
}

/// A key 11 item: the member entry and its key 10.
fn list_value(m: &Member) -> Value {
    let Value::Map(mut e) = member_value(m) else { unreachable!("member_value is a map") };
    if let Some(k) = m.known {
        e.push((Value::Uint(10), Value::Uint(k as u64)));
    }
    Value::Map(e)
}

/// A member entry as stored (key 11 item without key 10; a member's own node in mnet key 7).
pub fn member_value(m: &Member) -> Value {
    let mut e = vec![
        (Value::Uint(1), Value::Bytes(m.dac_pub_hash.to_vec())),
        (Value::Uint(2), Value::Bytes(m.ecdh_pub.to_vec())),
        (Value::Uint(3), Value::Text(m.name.clone())),
        (Value::Uint(4), Value::Bytes(m.owner_pub.to_vec())),
        (Value::Uint(5), Value::Bytes(m.owner_enc_pub.to_vec())),
        (Value::Uint(8), Value::Text(state_text(m.state).into())),
    ];
    if let Some(d) = &m.device_id {
        e.push((Value::Uint(6), Value::Text(d.clone())));
    }
    if let Some(c) = &m.prev_country {
        e.push((Value::Uint(9), Value::Text(c.clone())));
    }
    if let Some(a) = &m.mesh_addr {
        e.push((Value::Uint(7), Value::Bytes(a.to_vec())));
    }
    Value::Map(e)
}

/// A signed members-list entry's shape (CDDL member): keys 1-5, optional 6 and — from version N on, 254-app-team-status
/// §4.2 — optional 7, which must then be 6 bytes. Used where a received list is checked (approve, mupdate).
pub fn member_entry_ok(m: &Value) -> bool {
    crate::cose::exact_keys(m, &[1, 2, 3, 4, 5], &[6, 7]).is_ok() && m.get(7).map_or(true, |a| a.as_bytes().is_some_and(|b| b.len() == 6))
}

/// keys 1-5 of a member (a members v1 entry or a key 11 entry)
fn member_base(v: &Value, state: MemberState) -> Result<Member, Error> {
    Ok(Member {
        dac_pub_hash: arr(v.get(1), "member dac_pub_hash")?,
        ecdh_pub: arr(v.get(2), "member ecdh_pub")?,
        name: f(v.get(3).and_then(Value::as_text), "member name")?.to_string(),
        owner_pub: arr(v.get(4), "member owner_pub")?,
        owner_enc_pub: arr(v.get(5), "member owner_enc_pub")?,
        device_id: None,
        state,
        prev_country: None,
        known: None,
        mesh_addr: match v.get(7) {
            None => None,
            Some(a) => Some(a.as_bytes().and_then(|b| b.try_into().ok()).ok_or(Error::Field("member mesh address"))?),
        },
    })
}

pub fn member_of(v: &Value) -> Result<Member, Error> {
    let state = match v.get(8).and_then(Value::as_text) {
        Some("joining") => MemberState::Joining,
        Some("applied") => MemberState::Applied,
        Some("approved") => MemberState::Approved,
        _ => return Err(Error::Field("member state")),
    };
    let text = |k: u64, what| match v.get(k) {
        None => Ok(None),
        Some(Value::Text(t)) => Ok(Some(t.clone())),
        Some(_) => Err(Error::Field(what)),
    };
    let known = match v.get(10) {
        None => None,
        Some(x) => Some(f(x.as_uint().and_then(|n| u32::try_from(n).ok()), "member known version")?),
    };
    Ok(Member { device_id: text(6, "member device_id")?, prev_country: text(9, "member prev_country")?, known, ..member_base(v, state)? })
}

pub fn version_value(x: &Version) -> Value {
    Value::Map(vec![
        (Value::Uint(1), Value::Uint(x.version as u64)),
        (Value::Uint(2), Value::Bytes(x.netcfg.clone())),
        (Value::Uint(3), Value::Bytes(x.members.clone())),
    ])
}

/// Key 13 / mnet key 9: non-empty, increasing by one.
pub fn versions_of(v: &Value) -> Result<Vec<Version>, Error> {
    let Value::Array(a) = v else { return Err(Error::Field("versions")) };
    let out = a
        .iter()
        .map(|x| {
            Ok(Version {
                version: f(x.get(1).and_then(Value::as_uint).and_then(|n| u32::try_from(n).ok()), "version number")?,
                netcfg: f(x.get(2).and_then(Value::as_bytes), "version netcfg")?.to_vec(),
                members: f(x.get(3).and_then(Value::as_bytes), "version members")?.to_vec(),
            })
        })
        .collect::<Result<Vec<_>, Error>>()?;
    if out.is_empty() || out.windows(2).any(|w| w[1].version != w[0].version.wrapping_add(1)) {
        return Err(Error::Field("versions are not contiguous"));
    }
    Ok(out)
}

/// The stored form; key 11 only when `r.list` is Some (make-network's pending record has none, join2 §3.1).
pub fn encode(r: &NetRec) -> Vec<u8> {
    let b = &r.base;
    let mut m = vec![
        (Value::Uint(1), Value::Bytes(b.net_id.to_vec())),
        (Value::Uint(2), Value::Text(b.mesh_id.clone())),
        (Value::Uint(3), Value::Uint(b.channel)),
        (Value::Uint(4), Value::Uint(b.bw)),
        (Value::Uint(5), Value::Text(b.sae.clone())),
        (Value::Uint(6), Value::Bytes(b.net_root.to_vec())),
        (Value::Uint(7), Value::Bytes(b.netcfg.clone())),
        (Value::Uint(8), Value::Bytes(b.members.clone())),
        (Value::Uint(9), Value::Bytes(b.secrets.clone())),
        (Value::Uint(10), Value::Text(r.state.clone())),
    ];
    if let Some(l) = &r.list {
        m.push((Value::Uint(11), Value::Array(l.iter().map(list_value).collect())));
    }
    if let Some(i) = &r.invites {
        let e = i.iter().map(|x| {
            Value::Map(vec![
                (Value::Uint(1), Value::Bytes(x.hash.to_vec())),
                (Value::Uint(2), Value::Uint(x.kind)),
                (Value::Uint(3), Value::Bool(x.used)),
            ])
        });
        m.push((Value::Uint(12), Value::Array(e.collect())));
    }
    if let Some(h) = &r.versions {
        m.push((Value::Uint(13), Value::Array(h.iter().map(version_value).collect())));
    }
    if let Some(d) = &r.departed {
        let e = d.iter().map(|x| {
            Value::Map(vec![
                (Value::Uint(1), Value::Bytes(x.dac_hash.to_vec())),
                (Value::Uint(2), Value::Bytes(x.owner_pub.to_vec())),
                (Value::Uint(3), Value::Text(x.name.clone())),
            ])
        });
        m.push((Value::Uint(14), Value::Array(e.collect())));
    }
    cbor::encode(&Value::Map(m))
}

pub fn decode(plain: &[u8]) -> Result<NetRec, Error> {
    let v = cbor::decode(plain).map_err(Error::Cbor)?;
    let bytes = |k: u64, what| f(v.get(k).and_then(Value::as_bytes).map(<[u8]>::to_vec), what);
    let base = NetRecord {
        net_id: arr(v.get(1), "net_id")?,
        mesh_id: f(v.get(2).and_then(Value::as_text), "mesh_id")?.to_string(),
        channel: f(v.get(3).and_then(Value::as_uint), "channel")?,
        bw: f(v.get(4).and_then(Value::as_uint), "bw")?,
        sae: f(v.get(5).and_then(Value::as_text), "SAE")?.to_string(),
        net_root: arr(v.get(6), "net_root")?,
        netcfg: bytes(7, "netcfg")?,
        members: bytes(8, "members")?,
        secrets: bytes(9, "secrets")?,
    };
    let state = f(v.get(10).and_then(Value::as_text), "state")?.to_string();
    let list = match v.get(11) {
        None => None,
        Some(Value::Array(a)) => Some(a.iter().map(member_of).collect::<Result<Vec<_>, _>>()?),
        Some(_) => return Err(Error::Field("member list")),
    };
    let invites = match v.get(12) {
        None => None,
        Some(Value::Array(a)) => Some(
            a.iter()
                .map(|x| {
                    Ok(InviteRec {
                        hash: arr(x.get(1), "invite hash")?,
                        kind: f(x.get(2).and_then(Value::as_uint), "invite kind")?,
                        used: match x.get(3) {
                            Some(Value::Bool(b)) => *b,
                            _ => return Err(Error::Field("invite used")),
                        },
                    })
                })
                .collect::<Result<Vec<_>, _>>()?,
        ),
        Some(_) => return Err(Error::Field("invites")),
    };
    let versions = match v.get(13) {
        None => None,
        Some(x) => Some(versions_of(x)?),
    };
    let departed = match v.get(14) {
        None => None,
        Some(Value::Array(a)) => Some(
            a.iter()
                .map(|x| {
                    Ok(Departed {
                        dac_hash: arr(x.get(1), "departed dac_hash")?,
                        owner_pub: arr(x.get(2), "departed owner_pub")?,
                        name: f(x.get(3).and_then(Value::as_text), "departed name")?.to_string(),
                    })
                })
                .collect::<Result<Vec<_>, Error>>()?,
        ),
        Some(_) => return Err(Error::Field("departed")),
    };
    Ok(NetRec { base, state, list, invites, versions, departed })
}

impl NetRec {
    /// make-network's record (254-app-s1 §5.4): no key 11 while pending.
    pub fn made(base: NetRecord) -> NetRec {
        NetRec { base, state: PENDING.into(), list: None, invites: None, versions: None, departed: None }
    }

    pub fn netcfg(&self) -> Result<NetCfg, Error> {
        netcfg_of(&sign1_payload(&self.base.netcfg)?)
    }

    /// The members v1 entries of key 8 (the network's creator first).
    fn v1_members(&self, state: MemberState) -> Result<Vec<Member>, Error> {
        match sign1_payload(&self.base.members)?.get(4) {
            Some(Value::Array(a)) => a.iter().map(|m| member_base(m, state)).collect(),
            _ => Err(Error::Field("members v1 list")),
        }
    }

    /// The member list: key 11, or — an old record — derived from key 8 (state from key 10).
    pub fn members(&self) -> Result<Vec<Member>, Error> {
        match &self.list {
            Some(l) => Ok(l.clone()),
            None => self.v1_members(if self.state == APPLIED { MemberState::Applied } else { MemberState::Joining }),
        }
    }

    /// The node that made the network: the first members v1 entry. Only meaningful while the record is pending
    /// (remove-member §2.1: once applied, key 8 is the current version and may name another node or nobody).
    pub fn creator(&self) -> Result<[u8; 32], Error> {
        self.v1_members(MemberState::Joining)?.first().map(|m| m.dac_pub_hash).ok_or(Error::Field("members v1 empty"))
    }

    /// The creator while pending; None when applied (no caller may use it then, §2.1).
    pub fn pending_creator(&self) -> Result<Option<[u8; 32]>, Error> {
        if self.state == APPLIED {
            Ok(None)
        } else {
            self.creator().map(Some)
        }
    }

    /// Key 13, or — an older record — one version made from keys 7 / 8 (its number = key 7's key 2).
    pub fn history(&self) -> Result<Vec<Version>, Error> {
        match &self.versions {
            Some(h) => Ok(h.clone()),
            None => Ok(vec![Version { version: self.netcfg()?.version, netcfg: self.base.netcfg.clone(), members: self.base.members.clone() }]),
        }
    }

    /// The version a member entry's owner surely holds (key 10; absent = the oldest kept version − 1).
    pub fn known_of(&self, m: &Member) -> Result<u32, Error> {
        match m.known {
            Some(k) => Ok(k),
            None => Ok(self.history()?.first().map(|x| x.version).unwrap_or(1).saturating_sub(1)),
        }
    }

    /// The DAC hashes key 14 or some kept version / the current members list as removed (key 5): "removed before"
    /// (§2.0-2).
    pub fn removed_ever(&self) -> Result<Vec<[u8; 32]>, Error> {
        let mut out: Vec<[u8; 32]> = self.departed.iter().flatten().map(|d| d.dac_hash).collect();
        let mut all = self.history()?.into_iter().map(|x| x.members).collect::<Vec<_>>();
        all.push(self.base.members.clone());
        for m in all {
            for d in removed_of(&sign1_payload(&m)?)? {
                if !out.contains(&d) {
                    out.push(d);
                }
            }
        }
        Ok(out)
    }

    /// "The previous owner" (§3.6): the newest key 14 entry `pick` matches (as a member: name / owner_pub / dac), else
    /// the newest kept version's members entry.
    pub fn last_listed(&self, pick: impl Fn(&Member) -> bool) -> Result<Option<Member>, Error> {
        for d in self.departed.iter().flatten().rev() {
            let m = Member {
                dac_pub_hash: d.dac_hash,
                ecdh_pub: [0; 65],
                name: d.name.clone(),
                owner_pub: d.owner_pub,
                owner_enc_pub: [0; 65],
                device_id: None,
                state: MemberState::Applied,
                prev_country: None,
                known: None,
                mesh_addr: None,
            };
            if pick(&m) {
                return Ok(Some(m));
            }
        }
        for x in self.history()?.iter().rev() {
            if let Some(Value::Array(a)) = sign1_payload(&x.members)?.get(4) {
                for e in a {
                    let m = member_base(e, MemberState::Applied)?;
                    if pick(&m) {
                        return Ok(Some(m));
                    }
                }
            }
        }
        Ok(None)
    }
}

/// A members payload's key 5 (removed DAC hashes).
pub fn removed_of(p: &Value) -> Result<Vec<[u8; 32]>, Error> {
    match p.get(5) {
        Some(Value::Array(a)) => a.iter().map(|x| arr(Some(x), "removed dac_hash")).collect(),
        None => Ok(vec![]),
        Some(_) => Err(Error::Field("removed")),
    }
}

/// SHA-256 of a 65-byte DAC public key: a member's identity.
pub fn dac_hash(dac_pub: &[u8; 65]) -> [u8; 32] {
    Sha256::digest(dac_pub).into()
}

/// "Confirm network" (join2 §3.2) over an info answer read with the record's net_id.
#[derive(Debug, PartialEq, Eq)]
pub enum Confirm {
    /// the record (and the creator's entry) became applied: write it
    Upgraded { save_pending: bool },
    /// it already was applied: nothing to write
    Already { save_pending: bool },
    /// key 10 is ours but key 9 is another version: nothing changes
    OtherVersion,
    /// anything else (key 10 absent / another network / unknown): nothing changes
    NoChange(JoinState),
}

/// key 10 == the record's net_id AND key 9 == the netcfg version -> the record and the creator's entry become applied
/// (key 11 == true counts too: p5 is the commit point). No member entry is ever added here (a node lying about key 10
/// must not get into the list). An applied record: both checks first as ever, then Already — the creator step is
/// skipped (remove-member §2.1: key 8 may name another node then, or nobody).
pub fn confirm(rec: &mut NetRec, info: &Value) -> Result<Confirm, Error> {
    let cfg = rec.netcfg()?;
    let save_pending = match flow::join_state(info, &rec.base.net_id) {
        JoinState::Applied { save_pending } => save_pending,
        s => return Ok(Confirm::NoChange(s)),
    };
    if info.get(9).and_then(Value::as_uint) != Some(cfg.version as u64) {
        return Ok(Confirm::OtherVersion);
    }
    if rec.state == APPLIED {
        return Ok(Confirm::Already { save_pending });
    }
    let creator = rec.creator()?;
    let mut list = rec.members()?;
    let mut changed = rec.state != APPLIED;
    for m in list.iter_mut().filter(|m| m.dac_pub_hash == creator && m.state != MemberState::Applied) {
        m.state = MemberState::Applied;
        changed = true;
    }
    if !changed {
        return Ok(Confirm::Already { save_pending });
    }
    rec.state = APPLIED.into();
    rec.list = Some(list);
    Ok(Confirm::Upgraded { save_pending })
}

/// "Forget joining" (join2 §3.4): removes a joining entry. Returns the removed entry (its prev_country: the node may
/// still have the network's country). Refused: an applied entry, an unknown node, the network's creator while the
/// record is pending ("confirm network" upgrades it), and an approved entry — another person's node: "remove this
/// person" instead (remove-member §3.6; forgetting revokes nothing and keeps it out of the next removal).
pub fn forget_joining(rec: &mut NetRec, dac_pub_hash: &[u8; 32]) -> Result<Member, Error> {
    if rec.pending_creator()? == Some(*dac_pub_hash) {
        return Err(Error::Field("the network's creator is never forgotten"));
    }
    let mut list = rec.members()?;
    let i = list
        .iter()
        .position(|m| m.dac_pub_hash == *dac_pub_hash && m.state == MemberState::Joining)
        .ok_or(Error::Field("no joining member with that dac_pub_hash"))?;
    let m = list.remove(i);
    rec.list = Some(list);
    Ok(m)
}
