//! Make a network on the first node (design §5.4), sans-IO, over an owner session (loginflow::into_conn):
//!   net_id / SAE / net_root drawn here -> three admin signatures on the platform (net_config v1, members v1,
//!   net_secrets: COSE_Encrypt to the node's sig_ecdh-verified ecdh_pub) -> PersistNet (the caller fsyncs the net
//!   record; nothing is sent before) -> op/nonce -> owner-op signature on the platform -> network/join
//!   {1: netcfg, 2: members, 3: secrets, 31: owner-op} -> flow::network_join.
//! `resend` sends a persisted record again (same net_id: §5.4 rows "3" and "10 absent, 11 == false"). Reading info
//! after an unclear reply (flow::join_state) and the retry counts are the caller's.

use crate::cbor::{self, Value};
use crate::conn::Conn;
use crate::cose::{self, Member};
use crate::envelope::Outcome;
use crate::flow::{self, JoinReply};
use crate::sig;
use sha2::{Digest, Sha256};

/// S1: the radio country is fixed (design §5.4)
pub const COUNTRY: &str = "US";
const SAE_LEN: usize = 24;
const SAE_ALPHABET: &[u8] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789";

/// The US channels S1 offers (halow-setkey:28-32); the bandwidth (MHz, halow key 3) follows from the channel.
pub fn bw_for_channel(ch: u64) -> Option<u64> {
    match ch {
        40 => Some(4),
        42 => Some(2),
        _ => None,
    }
}

/// The network/join body without key 31: the three Sign1 objects embedded as CBOR items (tag 18), not as byte strings
/// (cddl:205-212; vector owner_op.request_network_join).
pub fn join_body(netcfg: &[u8], members: &[u8], secrets: &[u8]) -> Result<Value, cbor::Error> {
    Ok(Value::Map(vec![
        (Value::Uint(1), cbor::decode(netcfg)?),
        (Value::Uint(2), cbor::decode(members)?),
        (Value::Uint(3), cbor::decode(secrets)?),
    ]))
}

pub struct Input {
    pub net_name: String,
    pub channel: u64,
    pub node_name: String,
    /// from the node record (node_cert verified at claim)
    pub dac_pub: [u8; 65],
    pub ecdh_pub: [u8; 65],
    pub owner_pub: [u8; 65],
    pub owner_enc_pub: [u8; 65],
    pub admin_pub: [u8; 65],
}

/// The net record (design §3): persisted BEFORE network/join is sent. Holds secrets: the caller encrypts it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct NetRecord {
    pub net_id: [u8; 16],
    pub mesh_id: String,
    pub channel: u64,
    pub bw: u64,
    pub sae: String,
    pub net_root: [u8; 32],
    pub netcfg: Vec<u8>,
    pub members: Vec<u8>,
    pub secrets: Vec<u8>,
}

#[derive(Debug, PartialEq)]
pub enum End {
    Replied(JoinReply),
    /// op/nonce refused
    NonceRefused(Outcome),
    BadChannel,
    Broken(String),
}

#[derive(Debug, PartialEq)]
pub enum Action {
    /// the admin key over a COSE Sig_structure (0x84 "Signature1", one of the three labels); feed the DER to `signed`
    SignAdmin { tbs: Vec<u8> },
    PersistNet(NetRecord),
    Write(Vec<Vec<u8>>),
    /// the owner key over the owner-op input (prefix batman-owner-op-v1); feed the DER to `signed`
    SignOwner { input: Vec<u8> },
    Done(End),
}

enum Step {
    NetCfg { payload: Vec<u8> },
    Members { rec: Draft, payload: Vec<u8> },
    Secrets { rec: Draft, payload: Vec<u8> },
    Persist { rec: NetRecord },
    Nonce { rec: NetRecord },
    Owner { body: Value },
    Reply,
    Over,
}

/// a record whose signed objects are not all there yet
struct Draft {
    net_id: [u8; 16],
    mesh_id: String,
    channel: u64,
    bw: u64,
    sae: String,
    net_root: [u8; 32],
    netcfg: Vec<u8>,
    members: Vec<u8>,
}

pub struct Join {
    conn: Conn,
    inp: Option<Input>,
    st: Step,
    pending_draft: Option<Draft>,
}

fn random<const N: usize>() -> Result<[u8; N], String> {
    let mut b = [0u8; N];
    getrandom::fill(&mut b).map_err(|e| format!("getrandom: {e}"))?;
    Ok(b)
}

/// A 24-character SAE password, uniform over [A-Za-z0-9] (public for the distribution test).
pub fn sae() -> Result<String, String> {
    let mut out = String::with_capacity(SAE_LEN);
    while out.len() < SAE_LEN {
        for b in random::<32>()? {
            // 248 = 4 * 62: rejection keeps the 62 characters uniform
            if b < 248 && out.len() < SAE_LEN {
                out.push(SAE_ALPHABET[(b % 62) as usize] as char);
            }
        }
    }
    Ok(out)
}

impl Join {
    /// A new network: draws net_id / SAE / net_root and asks for the net_config signature.
    pub fn start(conn: Conn, inp: Input) -> (Join, Action) {
        let mut j = Join { conn, inp: None, st: Step::Over, pending_draft: None };
        let Some(bw) = bw_for_channel(inp.channel) else { return (j, Action::Done(End::BadChannel)) };
        let drawn = random::<16>().and_then(|id| Ok((id, random::<32>()?, sae()?)));
        let (net_id, net_root, sae) = match drawn {
            Ok(x) => x,
            Err(e) => return (j, Action::Done(End::Broken(e))),
        };
        let mesh_id = format!("bm-{}", crate::nodecert::hex_lower(&net_id[..6]));
        let payload = cose::net_config_payload(&net_id, 1, None, &inp.net_name, COUNTRY, &mesh_id, inp.channel, bw, &[inp.admin_pub]);
        let tbs = cose::sign1_tbs(cose::CT_NETCFG, cose::LABEL_NETCFG, &payload);
        j.pending_draft =
            Some(Draft { net_id, mesh_id, channel: inp.channel, bw, sae, net_root, netcfg: vec![], members: vec![] });
        j.inp = Some(inp);
        j.st = Step::NetCfg { payload };
        (j, Action::SignAdmin { tbs })
    }

    /// Send a persisted record again (same net_id): straight to op/nonce.
    pub fn resend(conn: Conn, rec: NetRecord) -> (Join, Action) {
        let mut j = Join { conn, inp: None, st: Step::Over, pending_draft: None };
        let a = j.ask_nonce(rec).unwrap_or(Action::Done(End::Broken("resend".into())));
        (j, a)
    }

    pub fn into_conn(self) -> Conn {
        self.conn
    }

    fn end(&mut self, e: End) -> Option<Action> {
        self.st = Step::Over;
        Some(Action::Done(e))
    }

    fn ask_nonce(&mut self, rec: NetRecord) -> Option<Action> {
        match self.conn.request("op/nonce", Value::Map(vec![])) {
            Ok((_, f)) => {
                self.st = Step::Nonce { rec };
                Some(Action::Write(f))
            }
            Err(e) => self.end(End::Broken(format!("{e:?}"))),
        }
    }

    /// The platform's DER signature for the last SignAdmin / SignOwner.
    pub fn signed(&mut self, der: &[u8]) -> Option<Action> {
        let s = match sig::der_to_raw_low_s(der) {
            Ok(s) => s,
            Err(e) => return self.end(End::Broken(format!("{e:?}"))),
        };
        match std::mem::replace(&mut self.st, Step::Over) {
            Step::NetCfg { payload } => {
                let (Some(inp), Some(mut d)) = (self.inp.as_ref(), self.pending_draft.take()) else {
                    return self.end(End::Broken("no draft".into()));
                };
                d.netcfg = cose::sign1(cose::CT_NETCFG, &payload, &s);
                let dac_hash: [u8; 32] = Sha256::digest(inp.dac_pub).into();
                let m = Member {
                    dac_pub_hash: &dac_hash,
                    ecdh_pub: &inp.ecdh_pub,
                    name: &inp.node_name,
                    owner_pub: &inp.owner_pub,
                    owner_enc_pub: &inp.owner_enc_pub,
                };
                let payload = cose::member_list_payload(&d.net_id, 1, None, &[m]);
                let tbs = cose::sign1_tbs(cose::CT_MEMBERS, cose::LABEL_MEMBERS, &payload);
                self.st = Step::Members { rec: d, payload };
                Some(Action::SignAdmin { tbs })
            }
            Step::Members { mut rec, payload } => {
                let Some(inp) = self.inp.as_ref() else { return self.end(End::Broken("no input".into())) };
                rec.members = cose::sign1(cose::CT_MEMBERS, &payload, &s);
                let dac_hash: [u8; 32] = Sha256::digest(inp.dac_pub).into();
                let plain = cbor::encode(&Value::Map(vec![
                    (Value::Uint(1), Value::Text(rec.sae.clone())),
                    (Value::Uint(2), Value::Bytes(rec.net_root.to_vec())),
                ]));
                let enc = match cose::encrypt_to(&plain, cose::LABEL_SECRETS, &inp.ecdh_pub, &dac_hash, &rec.net_id, 1) {
                    Ok(e) => e,
                    Err(e) => return self.end(End::Broken(format!("{e:?}"))),
                };
                let payload = cose::net_secrets_payload(&rec.net_id, 1, &dac_hash, &enc.object);
                let tbs = cose::sign1_tbs(cose::CT_SECRETS, cose::LABEL_SECRETS, &payload);
                self.st = Step::Secrets { rec, payload };
                Some(Action::SignAdmin { tbs })
            }
            Step::Secrets { rec, payload } => {
                let d = rec;
                let rec = NetRecord {
                    net_id: d.net_id,
                    mesh_id: d.mesh_id,
                    channel: d.channel,
                    bw: d.bw,
                    sae: d.sae,
                    net_root: d.net_root,
                    netcfg: d.netcfg,
                    members: d.members,
                    secrets: cose::sign1(cose::CT_SECRETS, &payload, &s),
                };
                self.st = Step::Persist { rec: rec.clone() };
                Some(Action::PersistNet(rec))
            }
            Step::Owner { body } => match sig::with_owner_op(&body, "network/join", &s) {
                Ok(full) => match self.conn.request("network/join", full) {
                    Ok((_, f)) => {
                        self.st = Step::Reply;
                        Some(Action::Write(f))
                    }
                    Err(e) => self.end(End::Broken(format!("{e:?}"))),
                },
                Err(e) => self.end(End::Broken(format!("{e:?}"))),
            },
            other => {
                self.st = other;
                None
            }
        }
    }

    /// The caller has synced the net record: op/nonce goes out.
    pub fn net_persisted(&mut self) -> Option<Action> {
        match std::mem::replace(&mut self.st, Step::Over) {
            Step::Persist { rec } => self.ask_nonce(rec),
            other => {
                self.st = other;
                None
            }
        }
    }

    pub fn on_frame(&mut self, f: &[u8]) -> Option<Action> {
        if !matches!(self.st, Step::Nonce { .. } | Step::Reply) {
            return match self.st {
                Step::Over => None,
                _ => self.end(End::Broken("unexpected frame".into())),
            };
        }
        let o = match self.conn.on_frame(f) {
            Ok(None) => return None,
            Ok(Some(o)) => o,
            Err(e) => return self.end(End::Broken(format!("{e:?}"))),
        };
        match std::mem::replace(&mut self.st, Step::Over) {
            Step::Nonce { rec } => {
                let helper: Option<[u8; 32]> = match &o {
                    Outcome::Ok(b) => b.get(1).and_then(Value::as_bytes).and_then(|n| n.try_into().ok()),
                    Outcome::Err { .. } => return self.end(End::NonceRefused(o)),
                };
                let Some(helper) = helper else { return self.end(End::Broken("op/nonce without a 32-byte nonce".into())) };
                let body = match join_body(&rec.netcfg, &rec.members, &rec.secrets) {
                    Ok(b) => b,
                    Err(e) => return self.end(End::Broken(format!("{e:?}"))),
                };
                match sig::owner_op_input(&self.conn.h(), &helper, "network/join", &body) {
                    Ok(input) => {
                        self.st = Step::Owner { body };
                        Some(Action::SignOwner { input })
                    }
                    Err(e) => self.end(End::Broken(format!("{e:?}"))),
                }
            }
            Step::Reply => self.end(End::Replied(flow::network_join(&o))),
            _ => None,
        }
    }
}
