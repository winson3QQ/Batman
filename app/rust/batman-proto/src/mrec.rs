//! A member phone's records for a remote invite (254-app-member-join §3), sealed like every record
//! (aad(path, generation), written by CAS):
//! - `mpend/<net_id hex>` — the one pending join request per network (public data):
//!   {1 invite_hash, 2 invite netcfg Sign1, 3 joinreq_hash, 4 own DAC hash, 5 SHA-256(owner_enc_pub), 6 device_id,
//!    7 joinreq Sign1}.
//! - `mnet/<net_id hex>` — an imported network (holds net_root: never shown or logged):
//!   {1 net_id, 2 net_version, 3 netcfg, 4 members, 5 secrets (for the own node), 6 net_root, ?7 own node's entry
//!    (netrec member encoding), 8 invite_hash}. "Removing the entry" = dropping key 7.
//!   Remove member (254-app-remove-member v6.4 §2.2): ?9 = the versions [{1 version, 2 netcfg, 3 members}] since this
//!   phone's first import (the last 32; absent = only the current one, keys 3 / 4); ?10 = this version's net_secrets
//!   for the own nodes [{1 dac_hash, 2 net_secrets Sign1}] (used only when its version is the current one). Key 5 =
//!   the key 7 node's current secrets.

use crate::cbor::{self, Value};
use crate::netrec::{self, Member, Version};
use crate::nodecert::hex_lower;

#[derive(Debug, PartialEq, Eq)]
pub enum Error {
    Cbor(cbor::Error),
    Field(&'static str),
}

fn f<T>(o: Option<T>, what: &'static str) -> Result<T, Error> {
    o.ok_or(Error::Field(what))
}

fn arr<const N: usize>(v: &Value, k: u64, what: &'static str) -> Result<[u8; N], Error> {
    f(v.get(k).and_then(Value::as_bytes).and_then(|b| b.try_into().ok()), what)
}

fn bytes(v: &Value, k: u64, what: &'static str) -> Result<Vec<u8>, Error> {
    f(v.get(k).and_then(Value::as_bytes).map(<[u8]>::to_vec), what)
}

pub fn pend_path(net_id: &[u8; 16]) -> String {
    format!("mpend/{}", hex_lower(net_id))
}

pub fn mnet_path(net_id: &[u8; 16]) -> String {
    format!("mnet/{}", hex_lower(net_id))
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Pend {
    pub invite_hash: [u8; 32],
    pub netcfg: Vec<u8>,
    pub joinreq_hash: [u8; 32],
    pub dac_hash: [u8; 32],
    pub owner_enc_hash: [u8; 32],
    pub device_id: String,
    pub joinreq: Vec<u8>,
}

impl Pend {
    pub fn encode(&self) -> Vec<u8> {
        cbor::encode(&Value::Map(vec![
            (Value::Uint(1), Value::Bytes(self.invite_hash.to_vec())),
            (Value::Uint(2), Value::Bytes(self.netcfg.clone())),
            (Value::Uint(3), Value::Bytes(self.joinreq_hash.to_vec())),
            (Value::Uint(4), Value::Bytes(self.dac_hash.to_vec())),
            (Value::Uint(5), Value::Bytes(self.owner_enc_hash.to_vec())),
            (Value::Uint(6), Value::Text(self.device_id.clone())),
            (Value::Uint(7), Value::Bytes(self.joinreq.clone())),
        ]))
    }

    pub fn decode(plain: &[u8]) -> Result<Pend, Error> {
        let v = cbor::decode(plain).map_err(Error::Cbor)?;
        Ok(Pend {
            invite_hash: arr(&v, 1, "invite_hash")?,
            netcfg: bytes(&v, 2, "netcfg")?,
            joinreq_hash: arr(&v, 3, "joinreq_hash")?,
            dac_hash: arr(&v, 4, "dac_hash")?,
            owner_enc_hash: arr(&v, 5, "owner_enc_hash")?,
            device_id: f(v.get(6).and_then(Value::as_text), "device_id")?.to_string(),
            joinreq: bytes(&v, 7, "joinreq")?,
        })
    }
}

/// One own node's net_secrets of the current version (mnet key 10).
#[derive(Clone, PartialEq, Eq)]
pub struct NodeSecrets {
    pub dac_hash: [u8; 32],
    pub secrets: Vec<u8>,
}

/// An imported network. Holds net_root: no Debug.
#[derive(Clone, PartialEq, Eq)]
pub struct MNet {
    pub net_id: [u8; 16],
    pub version: u32,
    pub netcfg: Vec<u8>,
    pub members: Vec<u8>,
    pub secrets: Vec<u8>,
    pub net_root: [u8; 32],
    pub me: Option<Member>,
    pub invite_hash: [u8; 32],
    /// key 9 (None = only the current version)
    pub versions: Option<Vec<Version>>,
    /// key 10
    pub node_secrets: Vec<NodeSecrets>,
}

impl MNet {
    pub fn encode(&self) -> Vec<u8> {
        let mut m = vec![
            (Value::Uint(1), Value::Bytes(self.net_id.to_vec())),
            (Value::Uint(2), Value::Uint(self.version as u64)),
            (Value::Uint(3), Value::Bytes(self.netcfg.clone())),
            (Value::Uint(4), Value::Bytes(self.members.clone())),
            (Value::Uint(5), Value::Bytes(self.secrets.clone())),
            (Value::Uint(6), Value::Bytes(self.net_root.to_vec())),
            (Value::Uint(8), Value::Bytes(self.invite_hash.to_vec())),
        ];
        if let Some(me) = &self.me {
            m.push((Value::Uint(7), netrec::member_value(me)));
        }
        if let Some(h) = &self.versions {
            m.push((Value::Uint(9), Value::Array(h.iter().map(netrec::version_value).collect())));
        }
        if !self.node_secrets.is_empty() {
            let e = self.node_secrets.iter().map(|x| {
                Value::Map(vec![(Value::Uint(1), Value::Bytes(x.dac_hash.to_vec())), (Value::Uint(2), Value::Bytes(x.secrets.clone()))])
            });
            m.push((Value::Uint(10), Value::Array(e.collect())));
        }
        cbor::encode(&Value::Map(m))
    }

    pub fn decode(plain: &[u8]) -> Result<MNet, Error> {
        let v = cbor::decode(plain).map_err(Error::Cbor)?;
        let me = match v.get(7) {
            None => None,
            Some(x) => Some(netrec::member_of(x).map_err(|_| Error::Field("own node entry"))?),
        };
        let versions = match v.get(9) {
            None => None,
            Some(x) => Some(netrec::versions_of(x).map_err(|_| Error::Field("versions"))?),
        };
        let node_secrets = match v.get(10) {
            None => vec![],
            Some(Value::Array(a)) => a
                .iter()
                .map(|x| Ok(NodeSecrets { dac_hash: arr(x, 1, "node secrets dac_hash")?, secrets: bytes(x, 2, "node secrets")? }))
                .collect::<Result<Vec<_>, Error>>()?,
            Some(_) => return Err(Error::Field("node secrets")),
        };
        Ok(MNet {
            net_id: arr(&v, 1, "net_id")?,
            version: f(v.get(2).and_then(Value::as_uint).and_then(|n| u32::try_from(n).ok()), "version")?,
            netcfg: bytes(&v, 3, "netcfg")?,
            members: bytes(&v, 4, "members")?,
            secrets: bytes(&v, 5, "secrets")?,
            net_root: arr(&v, 6, "net_root")?,
            me,
            invite_hash: arr(&v, 8, "invite_hash")?,
            versions,
            node_secrets,
        })
    }

    /// Key 9, or only the current version (keys 3 / 4).
    pub fn history(&self) -> Vec<Version> {
        self.versions.clone().unwrap_or_else(|| vec![Version { version: self.version, netcfg: self.netcfg.clone(), members: self.members.clone() }])
    }

    /// The current version's net_secrets for an own node: key 5 for the key 7 node, else key 10 — each only when its
    /// payload names that node and the current version (§2.2: anything else counts as none).
    pub fn secrets_for(&self, dac_hash: &[u8; 32]) -> Option<Vec<u8>> {
        let ok = |s: &[u8]| {
            netrec::sign1_payload(s).ok().is_some_and(|p| {
                p.get(1).and_then(Value::as_bytes) == Some(&self.net_id[..])
                    && p.get(2).and_then(Value::as_uint) == Some(self.version as u64)
                    && p.get(3).and_then(Value::as_bytes) == Some(&dac_hash[..])
            })
        };
        if self.me.as_ref().is_some_and(|m| m.dac_pub_hash == *dac_hash) && ok(&self.secrets) {
            return Some(self.secrets.clone());
        }
        self.node_secrets.iter().find(|x| x.dac_hash == *dac_hash && ok(&x.secrets)).map(|x| x.secrets.clone())
    }

    pub fn netcfg(&self) -> Result<netrec::NetCfg, Error> {
        let p = netrec::sign1_payload(&self.netcfg).map_err(|_| Error::Field("netcfg"))?;
        netrec::netcfg_of(&p).map_err(|_| Error::Field("netcfg"))
    }
}
