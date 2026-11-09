//! The net record `net/<net_id>` (254-app-s1 §3 / §5.4; 254-app-join2 v7.1 §3.1), as CBOR:
//!   {1 net_id, 2 mesh_id, 3 channel, 4 bw, 5 SAE, 6 net_root, 7 signed net_config v1, 8 signed members v1,
//!    9 the first node's net_secrets, 10 state "pending" / "applied", ?11 member list}.
//! Key 11, one entry per node = {1 dac_pub_hash, 2 ecdh_pub, 3 name, 4 owner_pub, 5 owner_enc_pub, ?6 device_id,
//! 8 state "joining" / "applied", ?9 prev_country}; keys 1-5 are the members v1 entry keys. A node is its
//! dac_pub_hash: one entry per node (replaced, never added twice). No net_secrets are kept per member (each join makes
//! them afresh). A record without key 11 (written by 36e2f57) gets its list from key 8: the members v1 entries, state
//! applied when key 10 is "applied", else joining.
//! The record holds SAE / net_root: it leaves Rust only to be sealed by the platform; nothing here formats it.

use sha2::{Digest, Sha256};

use crate::cbor::{self, Value};
use crate::flow::{self, JoinState};
use crate::joinflow::NetRecord;

/// The app's own cap on members (join2 §3.3-1d; the node has none).
pub const MAX_MEMBERS: usize = 16;
pub const PENDING: &str = "pending";
pub const APPLIED: &str = "applied";

#[derive(Debug, PartialEq, Eq)]
pub enum Error {
    Cbor(cbor::Error),
    Field(&'static str),
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum MemberState {
    Joining,
    Applied,
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
}

/// A decoded net record. `list` is key 11 as stored (None = an old record: `members()` derives it).
#[derive(Clone, PartialEq, Eq)]
pub struct NetRec {
    pub base: NetRecord,
    pub state: String,
    pub list: Option<Vec<Member>>,
}

/// What the signed net_config v1 says (the parts the app checks).
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct NetCfg {
    pub net_id: [u8; 16],
    pub version: u32,
    pub country: String,
    pub admins: Vec<[u8; 65]>,
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
    }
}

fn member_value(m: &Member) -> Value {
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
    Value::Map(e)
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
    })
}

fn member_of(v: &Value) -> Result<Member, Error> {
    let state = match v.get(8).and_then(Value::as_text) {
        Some("joining") => MemberState::Joining,
        Some("applied") => MemberState::Applied,
        _ => return Err(Error::Field("member state")),
    };
    let text = |k: u64, what| match v.get(k) {
        None => Ok(None),
        Some(Value::Text(t)) => Ok(Some(t.clone())),
        Some(_) => Err(Error::Field(what)),
    };
    Ok(Member { device_id: text(6, "member device_id")?, prev_country: text(9, "member prev_country")?, ..member_base(v, state)? })
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
        m.push((Value::Uint(11), Value::Array(l.iter().map(member_value).collect())));
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
    Ok(NetRec { base, state, list })
}

impl NetRec {
    /// make-network's record (254-app-s1 §5.4): no key 11 while pending.
    pub fn made(base: NetRecord) -> NetRec {
        NetRec { base, state: PENDING.into(), list: None }
    }

    pub fn netcfg(&self) -> Result<NetCfg, Error> {
        let p = sign1_payload(&self.base.netcfg)?;
        let admins = match p.get(8) {
            Some(Value::Array(a)) => a.iter().map(|x| arr(Some(x), "admin")).collect::<Result<Vec<_>, _>>()?,
            _ => return Err(Error::Field("admins")),
        };
        Ok(NetCfg {
            net_id: arr(p.get(1), "netcfg net_id")?,
            version: f(p.get(2).and_then(Value::as_uint).and_then(|n| u32::try_from(n).ok()), "netcfg version")?,
            country: f(p.get(5).and_then(Value::as_text), "netcfg country")?.to_string(),
            admins,
        })
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

    /// The node that made the network: the first members v1 entry.
    pub fn creator(&self) -> Result<[u8; 32], Error> {
        self.v1_members(MemberState::Joining)?.first().map(|m| m.dac_pub_hash).ok_or(Error::Field("members v1 empty"))
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
/// must not get into the list).
pub fn confirm(rec: &mut NetRec, info: &Value) -> Result<Confirm, Error> {
    let cfg = rec.netcfg()?;
    let save_pending = match flow::join_state(info, &rec.base.net_id) {
        JoinState::Applied { save_pending } => save_pending,
        s => return Ok(Confirm::NoChange(s)),
    };
    if info.get(9).and_then(Value::as_uint) != Some(cfg.version as u64) {
        return Ok(Confirm::OtherVersion);
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

/// "Forget joining" (join2 §3.4): removes the joining entry of `dac_pub_hash`. Returns its prev_country (the node may
/// still have the network's country). An applied entry or an unknown node is refused.
pub fn forget_joining(rec: &mut NetRec, dac_pub_hash: &[u8; 32]) -> Result<Option<String>, Error> {
    let mut list = rec.members()?;
    let i = list
        .iter()
        .position(|m| m.dac_pub_hash == *dac_pub_hash && m.state == MemberState::Joining)
        .ok_or(Error::Field("no joining member with that dac_pub_hash"))?;
    let m = list.remove(i);
    rec.list = Some(list);
    Ok(m.prev_country)
}
