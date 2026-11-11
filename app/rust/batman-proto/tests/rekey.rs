//! Remove a member (docs/design/254-app-remove-member.md v6.4 §7): the admin's removal (rekey), the update for a
//! member (UpdateBundle), the member's import (mupdate) and 「把新密碼送給節點」 (updflow) against each other with
//! real keys, and against a fake node that checks a network/update the way node.go netUpdate does (each version
//! signed by the previous admins, version + 1, prev_hash = the stored netcfg's OBJECT_HASH, members signed, secrets in
//! the last step only, decrypted with ITS OWN ECDH key).

use batman_proto::cbor::{self, Value as V};
use batman_proto::conn::Conn;
use batman_proto::joinflow::NetRecord;
use batman_proto::mrec::MNet;
use batman_proto::mupdate::{self, OwnNode, Prepared};
use batman_proto::netrec::{self, InviteRec, Member, MemberState, NetRec};
use batman_proto::nodecert::Verified;
use batman_proto::rekey::{self, Action, BundleAction, BundleEnd, BundleRefusal, End, NodeRead, Refusal, Rekey, Target, UpdateBundle};
use batman_proto::updflow::{self, SendUpdate};
use batman_proto::{cose, frame, noise};
use p256::ecdsa::signature::Signer;
use serde_json::Value as J;
use sha2::{Digest, Sha256};
use std::collections::VecDeque;
use std::path::PathBuf;

const FL: usize = 244;
const NET_ID: [u8; 16] = [0x5a; 16];
const SAE1: &str = "Sae0123456789abcdefghijk";
const ROOT1: [u8; 32] = [0x77; 32];

// keys: 0x66 admin; 0x11 / 0x22 this (admin) phone's owner / owner_enc; 0x31 / 0x32 person P; 0x33 / 0x34 person Q
// nodes (DAC / ECDH): A 0x55 / 0x43 (the admin's, the creator), A2 0x56 / 0x47 (the admin's second), B 0x57 / 0x44
// and B2 0x58 / 0x45 (P's), D 0x59 / 0x46 (Q's)
const ADMIN: u8 = 0x66;
const OWNER: u8 = 0x11;
const OWNER_ENC: u8 = 0x22;
const P: u8 = 0x31;
const P_ENC: u8 = 0x32;
const Q: u8 = 0x33;
const Q_ENC: u8 = 0x34;

fn key(b: u8) -> p256::ecdsa::SigningKey {
    p256::ecdsa::SigningKey::from_slice(&[b; 32]).unwrap()
}
fn pk(b: u8) -> [u8; 65] {
    key(b).verifying_key().to_sec1_point(false).as_bytes().try_into().unwrap()
}
fn der(b: u8, tbs: &[u8]) -> Vec<u8> {
    let s: p256::ecdsa::Signature = key(b).sign(tbs);
    s.to_der().as_bytes().to_vec()
}
fn dac(b: u8) -> [u8; 32] {
    netrec::dac_hash(&pk(b))
}
fn ecdh_z(priv_b: u8, peer: &[u8; 65]) -> [u8; 32] {
    let s = p256::SecretKey::from_slice(&[priv_b; 32]).unwrap();
    let z = p256::ecdh::diffie_hellman(s.to_nonzero_scalar(), p256::PublicKey::from_sec1_bytes(peer).unwrap().as_affine());
    z.raw_secret_bytes().as_slice().try_into().unwrap()
}
fn m(pairs: Vec<(u64, V)>) -> V {
    V::Map(pairs.into_iter().map(|(k, v)| (V::Uint(k), v)).collect())
}
fn sign1(by: u8, ct: &str, payload: &[u8]) -> Vec<u8> {
    let label = cose::label_of(ct).unwrap();
    let raw = batman_proto::sig::der_to_raw_low_s(&der(by, &cose::sign1_tbs(ct, label, payload))).unwrap();
    cose::sign1(ct, payload, &raw)
}

#[derive(Clone, Copy)]
struct N {
    dac: u8,
    ecdh: u8,
    owner: u8,
    enc: u8,
}
const A: N = N { dac: 0x55, ecdh: 0x43, owner: OWNER, enc: OWNER_ENC };
const A2: N = N { dac: 0x56, ecdh: 0x47, owner: OWNER, enc: OWNER_ENC };
const B: N = N { dac: 0x57, ecdh: 0x44, owner: P, enc: P_ENC };
const B2: N = N { dac: 0x58, ecdh: 0x45, owner: P, enc: P_ENC };
const D: N = N { dac: 0x59, ecdh: 0x46, owner: Q, enc: Q_ENC };

fn dev(n: N) -> String {
    format!("aabbccddeeff0011{:02x}{:02x}", n.dac, n.ecdh)
}
fn entry(n: N, state: MemberState, known: Option<u32>) -> Member {
    Member {
        dac_pub_hash: dac(n.dac),
        ecdh_pub: pk(n.ecdh),
        name: format!("n{:02x}", n.dac),
        owner_pub: pk(n.owner),
        owner_enc_pub: pk(n.enc),
        device_id: Some(dev(n)),
        state,
        prev_country: None,
        known,
    }
}
fn verified(n: N) -> Verified {
    Verified { device_id: dev(n), dac_der: vec![], dac_pub: pk(n.dac), ecdh_pub: pk(n.ecdh), sn: [0; 9] }
}
fn netcfg_v1() -> Vec<u8> {
    sign1(ADMIN, cose::CT_NETCFG, &cose::net_config_payload(&NET_ID, 1, None, "隊伍", "TW", "bm-5a5a5a5a5a5a", 40, 4, &[pk(ADMIN)]))
}
fn members_v1() -> Vec<u8> {
    let e = entry(A, MemberState::Applied, None);
    let c = cose::Member { dac_pub_hash: &e.dac_pub_hash, ecdh_pub: &e.ecdh_pub, name: &e.name, owner_pub: &e.owner_pub, owner_enc_pub: &e.owner_enc_pub };
    sign1(ADMIN, cose::CT_MEMBERS, &cose::member_list_payload(&NET_ID, 1, None, &[c]))
}
/// an applied v1 record (keys 7 / 8 = v1, no key 13: a record from before this change) with key 11 = `list`
fn record(list: Vec<Member>) -> NetRec {
    let base = NetRecord {
        net_id: NET_ID,
        mesh_id: "bm-5a5a5a5a5a5a".into(),
        channel: 40,
        bw: 4,
        sae: SAE1.into(),
        net_root: ROOT1,
        netcfg: netcfg_v1(),
        members: members_v1(),
        secrets: vec![1, 2, 3],
    };
    NetRec { base, state: "applied".into(), list: Some(list), invites: None, versions: None, departed: None }
}
fn team() -> NetRec {
    record(vec![entry(A, MemberState::Applied, None), entry(B, MemberState::Approved, None), entry(D, MemberState::Approved, None)])
}
fn applied_info(version: u64) -> V {
    m(vec![(4, V::Text("1.5.14-wsl.25+fbc01ae.fw02f0913".into())), (9, V::Uint(version)), (10, V::Bytes(NET_ID.to_vec())), (11, V::Bool(false))])
}
fn reads(pairs: &[(N, Option<V>)]) -> Vec<NodeRead> {
    pairs.iter().map(|(n, i)| NodeRead { dac_hash: dac(n.dac), info: i.clone() }).collect()
}

/// a removal driven to its end: (end, the record after (None = nothing written), admin signatures)
struct Ran {
    end: End,
    rec: Option<NetRec>,
    signs: usize,
}
fn run_rekey(rec: &NetRec, target: Target, r: &[NodeRead], sign_fail_at: Option<usize>, persist_ok: bool) -> Ran {
    let (mut f, mut a) = Rekey::start(&netrec::encode(rec), 1, &pk(ADMIN), &pk(OWNER), &target, r);
    let (mut signs, mut out) = (0, None);
    loop {
        a = match a {
            Action::SignAdmin { tbs } => {
                let d = if sign_fail_at == Some(signs) { vec![] } else { der(ADMIN, &tbs) };
                signs += 1;
                f.signed(&d).unwrap()
            }
            Action::Persist { plain, rel, expected_gen } => {
                assert_eq!((rel.as_str(), expected_gen), ("net/5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a", 1));
                if persist_ok {
                    out = Some(netrec::decode(&plain).unwrap());
                    f.persisted().unwrap()
                } else {
                    f.persist_failed(None).unwrap()
                }
            }
            Action::Done(end) => return Ran { end, rec: out, signs },
        }
    }
}
fn removed(rec: &NetRec, target: Target) -> NetRec {
    let r = run_rekey(rec, target, &[], None, true);
    assert!(matches!(r.end, End::Committed { .. }), "{:?}", r.end);
    r.rec.unwrap()
}
fn bundle(rec: &NetRec, person: u8) -> Result<String, BundleEnd> {
    let (mut b, mut a) = UpdateBundle::start(&netrec::encode(rec), &pk(ADMIN), &pk(OWNER), &pk(person));
    loop {
        a = match a {
            BundleAction::SignAdmin { tbs } => b.signed(&der(ADMIN, &tbs)).unwrap(),
            BundleAction::Done(BundleEnd::Out { hex }) => return Ok(hex),
            BundleAction::Done(e) => return Err(e),
        }
    }
}
fn bundle_signs(rec: &NetRec, person: u8) -> usize {
    let (mut b, mut a) = UpdateBundle::start(&netrec::encode(rec), &pk(ADMIN), &pk(OWNER), &pk(person));
    let mut n = 0;
    while let BundleAction::SignAdmin { tbs } = a {
        n += 1;
        a = b.signed(&der(ADMIN, &tbs)).unwrap();
    }
    n
}

/// net_secrets of `version` for node `n` with these SAE / net_root (what an admin would make)
fn node_secrets(version: u32, sae: &str, root: &[u8; 32], n: N) -> Vec<u8> {
    let plain = cbor::encode(&m(vec![(1, V::Text(sae.into())), (2, V::Bytes(root.to_vec()))]));
    let enc = cose::encrypt_to(&plain, cose::LABEL_SECRETS, &pk(n.ecdh), &dac(n.dac), &NET_ID, version).unwrap();
    sign1(ADMIN, cose::CT_SECRETS, &cose::net_secrets_payload(&NET_ID, version, &dac(n.dac), &enc.object))
}
/// (SAE, net_root) a node decrypts from a net_secrets Sign1 with its own ECDH key
fn open_secrets(s: &[u8], n: N) -> (String, Vec<u8>) {
    let p = netrec::sign1_payload(s).unwrap();
    assert_eq!(p.get(3).and_then(V::as_bytes), Some(&dac(n.dac)[..]), "secrets for this node");
    let ver = p.get(2).and_then(V::as_uint).unwrap() as u32;
    let enc = p.get(4).unwrap();
    let z = ecdh_z(n.ecdh, &cose::recipient_eph(enc).unwrap());
    let pt = cbor::decode(&cose::decrypt(enc, cose::LABEL_SECRETS, &dac(n.dac), &NET_ID, ver, &z).unwrap()).unwrap();
    (pt.get(1).and_then(V::as_text).unwrap().to_string(), pt.get(2).and_then(V::as_bytes).unwrap().to_vec())
}
/// P's phone after importing the v1 approval for node B
fn p_mnet(me: N) -> MNet {
    MNet {
        net_id: NET_ID,
        version: 1,
        netcfg: netcfg_v1(),
        members: members_v1(),
        secrets: node_secrets(1, SAE1, &ROOT1, me),
        net_root: ROOT1,
        me: Some(entry(me, MemberState::Applied, None)),
        invite_hash: [9; 32],
        versions: None,
        node_secrets: vec![],
    }
}
fn own(ns: &[N]) -> Vec<OwnNode> {
    ns.iter().map(|n| OwnNode { dac_hash: dac(n.dac), device_id: dev(*n) }).collect()
}
#[derive(Debug, PartialEq)]
enum Imp {
    Advanced(u32),
    Added,
    Already,
}
/// the member import, both parts (Kotlin's ECDH = `enc`'s private key); the new mnet when written
fn import_as(x: &MNet, hex: &str, mine: &[N], enc: u8) -> Result<(Imp, MNet), mupdate::Refusal> {
    let plain = x.encode();
    match mupdate::prepare(hex, Some(&plain), 3, &own(mine), &pk(enc))? {
        Prepared::Advance { to, eph_pub, mnet_gen } => {
            let z = ecdh_z(enc, &eph_pub);
            let (p, id, g) = mupdate::import(hex, Some(&plain), 3, mnet_gen, &own(mine), &pk(enc), Some(&z))?;
            assert_eq!((id, g), (NET_ID, 3));
            Ok((Imp::Advanced(to), MNet::decode(&p).unwrap()))
        }
        Prepared::AddSecrets { mnet_gen } => {
            let (p, _, _) = mupdate::import(hex, Some(&plain), 3, mnet_gen, &own(mine), &pk(enc), None)?;
            Ok((Imp::Added, MNet::decode(&p).unwrap()))
        }
        Prepared::AlreadyImported => Ok((Imp::Already, x.clone())),
    }
}
fn import(x: &MNet, hex: &str, mine: &[N]) -> Result<(Imp, MNet), mupdate::Refusal> {
    import_as(x, hex, mine, P_ENC)
}

// ---- the fake node -----------------------------------------------------------------------------------------------

#[derive(Clone)]
enum Ans {
    Info(V),
    Err(u64, V),
}

struct Node {
    t: snow::TransportState,
    rx: frame::Reassembler,
    who: N,
    version: u64,
    cfg_hash: [u8; 32],
    k4: String,
    in_net: bool,
    unfinished: bool,
    /// (SAE, net_root) the node runs with
    keys: (String, Vec<u8>),
    got: Vec<String>,
    /// queued answers to info (None = the node's own state)
    info_q: VecDeque<Option<Ans>>,
    /// the next network/update answer instead of applying (the node's own verdict when None)
    update_q: VecDeque<Ans>,
    chunks: Vec<u8>,
    /// the updates it refused, why
    refused: Vec<String>,
}

fn vectors() -> J {
    let p = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../../tests/vectors/219-protocol/vectors.json");
    serde_json::from_str(&std::fs::read_to_string(p).unwrap()).unwrap()
}

fn pair(who: N) -> (Conn, Node) {
    let v = vectors();
    let priv_ = hex::decode(v["keys"]["s_node_priv"].as_str().unwrap()).unwrap();
    let p: snow::params::NoiseParams = "Noise_NX_25519_ChaChaPoly_SHA256".parse().unwrap();
    let pro = noise::prologue(noise::Mode::Nx, Some("x"));
    let mut r = snow::Builder::new(p).prologue(&pro).unwrap().local_private_key(&priv_).unwrap().build_responder().unwrap();
    let mut i = noise::Initiator::new(noise::Mode::Nx, Some("x"), None).unwrap();
    let mut buf = vec![0u8; 65535];
    r.read_message(&i.msg1().unwrap(), &mut buf).unwrap();
    let n = r.write_message(b"cert", &mut buf).unwrap();
    let (_, s) = i.read_msg2(&buf[..n]).unwrap();
    let node = Node {
        t: r.into_transport_mode().unwrap(),
        rx: frame::Reassembler::new(FL, 8192),
        who,
        version: 1,
        cfg_hash: cose::object_hash(&netcfg_v1()).unwrap(),
        k4: "1.5.14-wsl.25+fbc01ae.fw02f0913".into(),
        in_net: true,
        unfinished: false,
        keys: (SAE1.into(), ROOT1.to_vec()),
        got: vec![],
        info_q: VecDeque::new(),
        update_q: VecDeque::new(),
        chunks: vec![],
        refused: vec![],
    };
    (Conn::new(s, FL), node)
}

impl Node {
    fn info(&self) -> V {
        let mut e = vec![(4, V::Text(self.k4.clone())), (11, V::Bool(self.unfinished))];
        if self.in_net {
            e.push((9, V::Uint(self.version)));
            e.push((10, V::Bytes(NET_ID.to_vec())));
        }
        m(e)
    }

    /// node.go netUpdate's checks, then the change
    fn update(&mut self, body: &V) -> Result<u64, String> {
        let Some(V::Array(chain)) = body.get(1) else { return Err("shape".into()) };
        let (mut ver, mut prev) = (self.version, self.cfg_hash);
        let mut last_sec = None;
        for (i, s) in chain.iter().enumerate() {
            let last = i + 1 == chain.len();
            if s.get(3).is_some() != last {
                return Err("update shape".into());
            }
            let cfg = cbor::encode(s.get(1).ok_or("1")?);
            let c = cose::verify_sign1(&cfg, cose::CT_NETCFG, cose::LABEL_NETCFG, &[pk(ADMIN)]).map_err(|_| "chain link")?;
            if c.payload.get(2).and_then(V::as_uint) != Some(ver + 1) || c.payload.get(3).and_then(V::as_bytes) != Some(&prev[..]) {
                return Err("chain not contiguous".into());
            }
            if c.payload.get(5).and_then(V::as_text) != Some("TW") {
                return Err("country".into());
            }
            let mem = cbor::encode(s.get(2).ok_or("2")?);
            let mm = cose::verify_sign1(&mem, cose::CT_MEMBERS, cose::LABEL_MEMBERS, &[pk(ADMIN)]).map_err(|_| "member_list")?;
            if mm.payload.get(2).and_then(V::as_uint) != Some(ver + 1) {
                return Err("member_list version".into());
            }
            ver += 1;
            prev = c.hash;
            if last {
                last_sec = Some(cbor::encode(s.get(3).unwrap()));
            }
        }
        let sec = last_sec.ok_or("no secrets")?;
        let sp = cose::verify_sign1(&sec, cose::CT_SECRETS, cose::LABEL_SECRETS, &[pk(ADMIN)]).map_err(|_| "secrets signature")?;
        if sp.payload.get(2).and_then(V::as_uint) != Some(ver) || sp.payload.get(3).and_then(V::as_bytes) != Some(&dac(self.who.dac)[..]) {
            return Err("secrets of another version / node".into());
        }
        self.keys = open_secrets(&sec, self.who);
        self.version = ver;
        self.cfg_hash = prev;
        Ok(ver)
    }

    fn on(&mut self, frames: &[Vec<u8>]) -> Vec<Vec<u8>> {
        let mut out = vec![];
        for f in frames {
            let Some(msg) = self.rx.push(f).unwrap() else { continue };
            let mut buf = vec![0u8; 65535];
            let n = self.t.read_message(&msg, &mut buf).unwrap();
            let req = cbor::decode(&buf[..n]).unwrap();
            let id = req.get(1).and_then(V::as_uint).unwrap();
            let verb = req.get(2).and_then(V::as_text).unwrap().to_string();
            let body = match req.get(6) {
                Some(c) => {
                    self.chunks.extend(req.get(3).and_then(V::as_bytes).unwrap());
                    if c.get(1) != c.get(2) {
                        continue;
                    }
                    let b = cbor::decode(&self.chunks).unwrap();
                    self.chunks.clear();
                    b
                }
                None => req.get(3).unwrap().clone(),
            };
            self.got.push(verb.clone());
            let a = match verb.as_str() {
                "info" => self.info_q.pop_front().flatten().unwrap_or_else(|| Ans::Info(self.info())),
                "network/update" => match self.update_q.pop_front() {
                    Some(x) => x,
                    None => match self.update(&body) {
                        Ok(v) => Ans::Info(m(vec![(1, V::Uint(v))])),
                        Err(why) => {
                            self.refused.push(why);
                            Ans::Err(4, m(vec![]))
                        }
                    },
                },
                _ => Ans::Err(2, m(vec![])),
            };
            let reply = match a {
                Ans::Info(b) => m(vec![(1, V::Uint(id)), (3, b), (4, V::Uint(0))]),
                Ans::Err(c, d) => m(vec![(1, V::Uint(id)), (4, V::Uint(c)), (5, d)]),
            };
            let n = self.t.write_message(&cbor::encode(&reply), &mut buf).unwrap();
            out.extend(frame::split(&buf[..n], FL).unwrap());
        }
        out
    }
}

struct Sent {
    end: updflow::End,
    signs: usize,
    waits: usize,
}
fn send(node: &mut Node, conn: Conn, record_plain: Vec<u8>, member: bool, who: Option<Verified>) -> Sent {
    let inp = updflow::Input { record_plain, member, node: who, owner_pub: pk(if member { P } else { OWNER }), admin_pub: pk(ADMIN) };
    let (mut f, mut a) = SendUpdate::start(conn, inp);
    let (mut signs, mut waits) = (0, 0);
    loop {
        a = match a {
            updflow::Action::Write(fr) => {
                let mut next = None;
                for r in node.on(&fr) {
                    if let Some(x) = f.on_frame(&r) {
                        next = Some(x);
                    }
                }
                next.expect("the node answered")
            }
            updflow::Action::SignAdmin { tbs } => {
                signs += 1;
                f.signed(&der(ADMIN, &tbs)).unwrap()
            }
            updflow::Action::Wait { ms } => {
                assert_eq!(ms, 2000);
                waits += 1;
                f.resume().unwrap()
            }
            updflow::Action::Done(end) => return Sent { end, signs, waits },
        }
    }
}

// ---- T1 / T3 / T4: v+1 --------------------------------------------------------------------------------------------

#[test]
fn t1_the_next_version_changes_only_what_it_must() {
    let rec = team();
    let after = removed(&rec, Target::Person(pk(P)));
    let (c1, c2) = (netrec::sign1_payload(&rec.base.netcfg).unwrap(), netrec::sign1_payload(&after.base.netcfg).unwrap());
    let V::Map(e1) = &c1 else { panic!() };
    let V::Map(e2) = &c2 else { panic!() };
    assert_eq!(e1.len(), e2.len(), "the same keys");
    for ((k1, v1), (k2, v2)) in e1.iter().zip(e2) {
        assert_eq!(k1, k2);
        match k1 {
            V::Uint(2) => assert_eq!(v2, &V::Uint(2)),
            V::Uint(3) => assert_eq!(v2.as_bytes(), Some(&cose::object_hash(&rec.base.netcfg).unwrap()[..])),
            _ => assert_eq!(v1, v2, "netcfg key {k1:?} as before"),
        }
    }
    // signed by v1's admins (this phone), the node rule (the fake node below checks the same)
    cose::verify_sign1(&after.base.netcfg, cose::CT_NETCFG, cose::LABEL_NETCFG, &[pk(ADMIN)]).unwrap();
    let mp = cose::verify_sign1(&after.base.members, cose::CT_MEMBERS, cose::LABEL_MEMBERS, &[pk(ADMIN)]).unwrap().payload;
    cose::exact_keys(&mp, &[1, 2, 3, 4, 5, 6, 7], &[]).unwrap();
    assert_eq!(mp.get(2), Some(&V::Uint(2)));
    assert_eq!(mp.get(3).and_then(V::as_bytes), Some(&cose::object_hash(&rec.base.members).unwrap()[..]));
    let V::Array(list) = mp.get(4).unwrap() else { panic!() };
    // key 11's order without B (P's), each entry exactly keys 1-5
    let dacs: Vec<_> = list.iter().map(|x| x.get(1).and_then(V::as_bytes).unwrap().to_vec()).collect();
    assert_eq!(dacs, vec![dac(A.dac).to_vec(), dac(D.dac).to_vec()]);
    for x in list {
        cose::exact_keys(x, &[1, 2, 3, 4, 5], &[]).unwrap();
    }
    assert_eq!(netrec::removed_of(&mp).unwrap(), vec![dac(B.dac)]);
    // the record: key 13 = [v1 (from keys 7 / 8), v2], keys 5-8 new, key 11 without B
    let h = after.versions.as_ref().unwrap();
    assert_eq!(h.iter().map(|x| x.version).collect::<Vec<_>>(), vec![1, 2]);
    assert_eq!((h[0].netcfg.clone(), h[0].members.clone()), (rec.base.netcfg.clone(), rec.base.members.clone()));
    assert_eq!((h[1].netcfg.clone(), h[1].members.clone()), (after.base.netcfg.clone(), after.base.members.clone()));
    assert_ne!(after.base.sae, rec.base.sae);
    assert_ne!(after.base.net_root, rec.base.net_root);
    assert_eq!(after.base.sae.len(), 24);
    let l = after.list.as_ref().unwrap();
    assert_eq!(l.iter().map(|x| x.dac_pub_hash).collect::<Vec<_>>(), vec![dac(A.dac), dac(D.dac)]);
    assert_eq!(after.base.secrets, rec.base.secrets, "key 9 untouched");
}

#[test]
fn t1_removed_lists_the_union_and_drops_a_listed_node() {
    // v2 removes P; P is re-approved (B back in key 11); v3 removes Q -> removed = {D}: B is listed again
    let v2 = removed(&team(), Target::Person(pk(P)));
    let mut back = v2.clone();
    back.list.as_mut().unwrap().push(entry(B, MemberState::Approved, Some(2)));
    let v3 = removed(&back, Target::Person(pk(Q)));
    let mp = netrec::sign1_payload(&v3.base.members).unwrap();
    assert_eq!(netrec::removed_of(&mp).unwrap(), vec![dac(D.dac)]);
    let listed: Vec<_> = match mp.get(4) {
        Some(V::Array(a)) => a.iter().map(|x| x.get(1).and_then(V::as_bytes).unwrap().to_vec()).collect(),
        _ => panic!(),
    };
    assert_eq!(listed, vec![dac(A.dac).to_vec(), dac(B.dac).to_vec()]);
    // "removed before" still knows B (some kept version lists it)
    assert!(v3.removed_ever().unwrap().contains(&dac(B.dac)));
}

#[test]
fn t3_an_older_record_gets_one_version_and_every_member_is_listed() {
    let rec = team();
    assert_eq!(rec.history().unwrap().iter().map(|x| x.version).collect::<Vec<_>>(), vec![1]);
    let e = entry(B, MemberState::Approved, None);
    assert_eq!(rec.known_of(&e).unwrap(), 0, "no key 10 = the oldest version − 1");
    let after = removed(&rec, Target::Person(pk(Q)));
    let r = rekey::recipients(&after, &pk(OWNER)).unwrap();
    assert_eq!(r.iter().map(|x| x.owner_pub).collect::<Vec<_>>(), vec![pk(P)]);
    assert!(!r[0].unknown_before, "oldest kept version is 1: nothing unknown");
    assert!(r[0].old_approval, "B is approved and behind: the paste-order line");
    // a record whose key 7 is already v2 (written back by an older app): the derived version is 2
    let mut old = after.clone();
    old.versions = None;
    assert_eq!(old.history().unwrap()[0].version, 2);
    let r = rekey::recipients(&old, &pk(OWNER)).unwrap();
    assert!(r[0].unknown_before, "after a downgrade: 「升級前的版本不明」");
}

#[test]
fn t4_updates_after_the_commit_sign_only_secrets_and_carry_the_stored_bytes() {
    let after = removed(&team(), Target::Person(pk(Q)));
    assert_eq!(bundle_signs(&after, P), 2, "one node + member_secrets: netcfg / members are never signed again");
    let hex = bundle(&after, P).unwrap();
    let raw = batman_proto::invite::qr_object(&hex, rekey::QR_UPDATE).unwrap();
    let v = cbor::decode(&raw).unwrap();
    let V::Array(steps) = v.get(2).unwrap() else { panic!() };
    // B has no key 10 = the oldest − 1 = 0: start = max(0 + 1, 2 − 15, 1) = 1 -> v1 and v2, the stored bytes
    assert_eq!(steps.len(), 2);
    let h = after.versions.unwrap();
    for (s, x) in steps.iter().zip(&h) {
        assert_eq!((cbor::encode(s.get(1).unwrap()), cbor::encode(s.get(2).unwrap())), (x.netcfg.clone(), x.members.clone()));
    }
}

// ---- T2: nothing written before the commit ------------------------------------------------------------------------

#[test]
fn t2_a_failed_signature_or_write_changes_nothing() {
    for at in [0, 1] {
        let r = run_rekey(&team(), Target::Person(pk(P)), &[], Some(at), true);
        assert_eq!((r.end, r.rec.is_none()), (End::SignFailed, true), "signature {at}");
    }
    let r = run_rekey(&team(), Target::Person(pk(P)), &[], None, false);
    assert_eq!(r.end, End::PersistFailed(None));
    assert!(r.rec.is_none());
}

// ---- §3.1 preconditions, §2.4 version check (T15, T26, T32, T33, T38) ------------------------------------------------

#[test]
fn t38_preconditions() {
    let mut pending = team();
    pending.state = "pending".into();
    assert_eq!(run_rekey(&pending, Target::Person(pk(P)), &[], None, true).end, End::Refused(Refusal::NotApplied));
    // admins != [this phone]
    let mut two = team();
    two.base.netcfg = sign1(ADMIN, cose::CT_NETCFG, &cose::net_config_payload(&NET_ID, 1, None, "隊伍", "TW", "bm-5a5a5a5a5a5a", 40, 4, &[pk(ADMIN), pk(0x67)]));
    let r = run_rekey(&two, Target::Person(pk(P)), &[], None, true);
    assert_eq!((r.end, r.signs), (End::Refused(Refusal::NotSoleAdmin), 0));
    // this phone's own person: never
    assert_eq!(run_rekey(&team(), Target::Person(pk(OWNER)), &[], None, true).end, End::Refused(Refusal::SelfPerson));
    // nobody of that owner_pub / not one of this phone's nodes
    assert_eq!(run_rekey(&team(), Target::Person(pk(0x70)), &[], None, true).end, End::Refused(Refusal::NoTarget));
    assert_eq!(run_rekey(&team(), Target::Node(dac(B.dac)), &[], None, true).end, End::Refused(Refusal::NoTarget));
    // key 11 is written as the list itself: excluding the last own node of a one-node network leaves Some([])
    let solo = record(vec![entry(A, MemberState::Applied, None)]);
    let after = removed(&solo, Target::Node(dac(A.dac)));
    assert_eq!(after.list, Some(vec![]));
    assert_eq!(netrec::decode(&netrec::encode(&after)).unwrap().list, Some(vec![]), "Some(empty) survives the codec");
}

#[test]
fn t32_a_joining_own_node_can_be_excluded_but_another_one_blocks() {
    let rec = record(vec![entry(A, MemberState::Applied, None), entry(A2, MemberState::Joining, None), entry(B, MemberState::Approved, None)]);
    let after = removed(&rec, Target::Node(dac(A2.dac)));
    assert!(after.removed_ever().unwrap().contains(&dac(A2.dac)), "the excluded joining node is in removed");
    // negative control: the joining node is not the one being excluded
    let r = run_rekey(&rec, Target::Person(pk(P)), &[], None, true);
    assert_eq!((r.end, r.signs), (End::Refused(Refusal::Joining(dev(A2)[16..].to_string())), 0));
}

#[test]
fn t15_the_own_nodes_vouch_for_the_record() {
    let rec = record(vec![entry(A, MemberState::Applied, None), entry(A2, MemberState::Applied, None), entry(B, MemberState::Approved, None)]);
    // a node at v + 1: no start, no signature, that node named
    let r = run_rekey(&rec, Target::Person(pk(P)), &reads(&[(A, Some(applied_info(2))), (A2, Some(applied_info(1)))]), None, true);
    assert_eq!((r.end, r.signs), (End::Refused(Refusal::NodeNewer(vec![dev(A)[16..].to_string()])), 0));
    // reachable and at v: vouched
    let p = rekey::precheck(&rec, &pk(ADMIN), &pk(OWNER), &Target::Person(pk(P)), &reads(&[(A, Some(applied_info(1)))])).unwrap();
    assert!(!p.unverified);
    // none reachable / a node not applied / no own node left: may start, the dialog says it could not be checked
    for r in [reads(&[(A, None), (A2, None)]), reads(&[(A, Some(m(vec![(11, V::Bool(false))])))]), vec![]] {
        let p = rekey::precheck(&rec, &pk(ADMIN), &pk(OWNER), &Target::Person(pk(P)), &r).unwrap();
        assert!(p.unverified);
    }
    // the second removal: the own node still at v1 while the record is v2 -> may start (k9 ≤ v and in key 13)
    let v2 = removed(&rec, Target::Person(pk(P)));
    let mut v2b = v2.clone();
    v2b.list.as_mut().unwrap().push(entry(D, MemberState::Approved, Some(2)));
    let p = rekey::precheck(&v2b, &pk(ADMIN), &pk(OWNER), &Target::Person(pk(Q)), &reads(&[(A, Some(applied_info(1)))])).unwrap();
    assert!(!p.unverified);
    // T38: the target lying about its key 9 does not block (the target is never checked)
    let p = rekey::precheck(&rec, &pk(ADMIN), &pk(OWNER), &Target::Node(dac(A2.dac)), &reads(&[(A2, Some(applied_info(9))), (A, Some(applied_info(1)))])).unwrap();
    assert_eq!(p.excluded.len(), 1);
    // T33: an info with a bad key 4 does not block the start (key 4 is checked only before each send)
    let mut bad = applied_info(1);
    if let V::Map(e) = &mut bad {
        e[0].1 = V::Text("1.5.14-wsl.24".into());
    }
    assert!(rekey::precheck(&rec, &pk(ADMIN), &pk(OWNER), &Target::Person(pk(P)), &reads(&[(A, Some(bad))])).is_ok());
}

#[test]
fn t26_the_last_own_node_can_be_excluded_and_the_record_still_works() {
    let solo = record(vec![entry(A, MemberState::Applied, None), entry(B, MemberState::Approved, None)]);
    let p = rekey::precheck(&solo, &pk(ADMIN), &pk(OWNER), &Target::Node(dac(A.dac)), &[]).unwrap();
    assert!(p.unverified, "no own node left to vouch");
    let v2 = removed(&solo, Target::Node(dac(A.dac)));
    // members v2 = [B]: key 8's first entry is now another person's node
    let mut v3in = v2.clone();
    v3in.list = Some(vec![entry(B, MemberState::Approved, Some(2))]);
    let v3 = removed(&v3in, Target::Person(pk(P)));
    // key 8 is empty now: confirm / forget / the next removal never ask for the creator
    let mp = netrec::sign1_payload(&v3.base.members).unwrap();
    assert_eq!(mp.get(4), Some(&V::Array(vec![])));
    let mut c = v3.clone();
    assert_eq!(netrec::confirm(&mut c, &applied_info(3)), Ok(netrec::Confirm::Already { save_pending: false }));
    let mut j = v3.clone();
    j.list = Some(vec![entry(A2, MemberState::Joining, None)]);
    assert_eq!(netrec::forget_joining(&mut j, &dac(A2.dac)).map(|x| x.dac_pub_hash), Ok(dac(A2.dac)));
    assert!(v3.creator().is_err(), "negative control: the creator of an empty key 8 is an error");
    let mut v3j = v3.clone();
    v3j.list = Some(vec![entry(A2, MemberState::Applied, None)]);
    removed(&v3j, Target::Node(dac(A2.dac)));
}

#[test]
fn t38_confirm_on_an_applied_record_never_touches_key_11() {
    // the creator (A) excluded: key 8's first entry is B (another person's approved entry)
    let v2 = removed(&record(vec![entry(A, MemberState::Applied, None), entry(B, MemberState::Approved, None), entry(A2, MemberState::Joining, None)]), Target::Node(dac(A2.dac)));
    let mut v2b = v2.clone();
    let v2c = removed(&v2b, Target::Node(dac(A.dac)));
    v2b = v2c.clone();
    let before = v2b.list.clone();
    assert_eq!(netrec::confirm(&mut v2b, &applied_info(3)), Ok(netrec::Confirm::Already { save_pending: false }));
    assert_eq!(v2b.list, before, "B stays approved");
    // both checks first as ever: another network -> NoChange, another version -> OtherVersion (never Already)
    let other = m(vec![(9, V::Uint(3)), (10, V::Bytes(vec![0x99; 16])), (11, V::Bool(false))]);
    assert_eq!(netrec::confirm(&mut v2b, &other), Ok(netrec::Confirm::NoChange(batman_proto::flow::JoinState::OtherNetwork)));
    assert_eq!(netrec::confirm(&mut v2b, &applied_info(1)), Ok(netrec::Confirm::OtherVersion));
    // the pending path is unchanged: the creator's joining entry becomes applied
    let mut pend = record(vec![entry(A, MemberState::Joining, None)]);
    pend.state = "pending".into();
    assert_eq!(netrec::confirm(&mut pend, &applied_info(1)), Ok(netrec::Confirm::Upgraded { save_pending: false }));
    assert_eq!(pend.list.unwrap()[0].state, MemberState::Applied);
}

#[test]
fn t39_forget_only_joining_and_the_creator_only_while_pending() {
    let mut rec = record(vec![entry(A, MemberState::Joining, None), entry(B, MemberState::Approved, None)]);
    assert!(netrec::forget_joining(&mut rec.clone(), &dac(B.dac)).is_err(), "another person's approved entry: remove the person");
    assert_eq!(netrec::forget_joining(&mut rec, &dac(A.dac)).map(|m| m.dac_pub_hash), Ok(dac(A.dac)), "applied record: the creator's joining entry may go");
    let mut p = record(vec![entry(A, MemberState::Joining, None)]);
    p.state = "pending".into();
    assert!(netrec::forget_joining(&mut p, &dac(A.dac)).is_err(), "pending: the creator never");
}

// ---- T40: the recipient contract -----------------------------------------------------------------------------------

#[test]
fn t40_updates_come_from_the_current_key_11_only() {
    let v2 = removed(&team(), Target::Person(pk(Q)));
    // Q removed: an update for Q is refused before any signature (the screen may still show Q)
    let (_, a) = UpdateBundle::start(&netrec::encode(&v2), &pk(ADMIN), &pk(OWNER), &pk(Q));
    assert_eq!(a, BundleAction::Done(BundleEnd::Refused(BundleRefusal::NotRecipient)));
    let (_, a) = UpdateBundle::start(&netrec::encode(&v2), &pk(ADMIN), &pk(OWNER), &pk(OWNER));
    assert_eq!(a, BundleAction::Done(BundleEnd::Refused(BundleRefusal::NotRecipient)));
    // two entries of P disagreeing on owner_enc_pub
    let mut bad = v2.clone();
    let mut b2 = entry(B2, MemberState::Approved, None);
    b2.owner_enc_pub = pk(0x40);
    bad.list.as_mut().unwrap().push(b2);
    let (_, a) = UpdateBundle::start(&netrec::encode(&bad), &pk(ADMIN), &pk(OWNER), &pk(P));
    assert_eq!(a, BundleAction::Done(BundleEnd::Refused(BundleRefusal::Inconsistent)));
    // already current: nothing to hand over
    let mut cur = v2.clone();
    cur.list.as_mut().unwrap().iter_mut().for_each(|m| m.known = Some(2));
    let (_, a) = UpdateBundle::start(&netrec::encode(&cur), &pk(ADMIN), &pk(OWNER), &pk(P));
    assert_eq!(a, BundleAction::Done(BundleEnd::Refused(BundleRefusal::Current)));
    // the update for P carries secrets for P's nodes only and member_secrets for P's owner_enc_pub
    let hex = bundle(&v2, P).unwrap();
    let v = cbor::decode(&batman_proto::invite::qr_object(&hex, 4).unwrap()).unwrap();
    let V::Array(se) = v.get(3).unwrap() else { panic!() };
    assert_eq!(se.len(), 1);
    assert_eq!(netrec::sign1_payload(&cbor::encode(&se[0])).unwrap().get(3).and_then(V::as_bytes), Some(&dac(B.dac)[..]));
    let ms = netrec::sign1_payload(&cbor::encode(v.get(4).unwrap())).unwrap();
    assert_eq!(ms.get(3).and_then(V::as_bytes), Some(&<[u8; 32]>::from(Sha256::digest(pk(P_ENC)))[..]));
}

// ---- the member's import (T6, T8, T8b, T11, T12, T20, T29, T37) ------------------------------------------------------

#[test]
fn t6_two_updates_for_one_person_hold_the_same_keys() {
    let v2 = removed(&team(), Target::Person(pk(Q)));
    let (h1, h2) = (bundle(&v2, P).unwrap(), bundle(&v2, P).unwrap());
    assert_ne!(h1, h2, "fresh ephemeral keys");
    let s = |hex: &str| {
        let v = cbor::decode(&batman_proto::invite::qr_object(hex, 4).unwrap()).unwrap();
        let V::Array(se) = v.get(3).unwrap() else { panic!() };
        open_secrets(&cbor::encode(&se[0]), B)
    };
    assert_eq!(s(&h1), s(&h2));
    assert_eq!(s(&h1), (v2.base.sae.clone(), v2.base.net_root.to_vec()));
    let (i1, x) = import(&p_mnet(B), &h1, &[B]).unwrap();
    assert_eq!(i1, Imp::Advanced(2));
    assert_eq!((x.version, x.net_root), (2, v2.base.net_root));
    assert_eq!(import(&x, &h2, &[B]).unwrap().0, Imp::Already);
}

#[test]
fn t8_a_member_two_versions_behind_gets_both_and_key_10_never_moves() {
    let v2 = removed(&team(), Target::Person(pk(Q)));
    let _lost = bundle(&v2, P).unwrap(); // copied, never imported
    assert_eq!(v2.list.as_ref().unwrap().iter().find(|m| m.owner_pub == pk(P)).unwrap().known, None, "copying does not move key 10");
    let mut v2b = v2.clone();
    v2b.list.as_mut().unwrap().push(entry(D, MemberState::Approved, Some(2)));
    let v3 = removed(&v2b, Target::Person(pk(Q)));
    let hex = bundle(&v3, P).unwrap();
    let (i, x) = import(&p_mnet(B), &hex, &[B]).unwrap();
    assert_eq!(i, Imp::Advanced(3));
    assert_eq!(x.history().iter().map(|v| v.version).collect::<Vec<_>>(), vec![1, 2, 3]);
    assert_eq!(open_secrets(&x.secrets, B), (v3.base.sae.clone(), v3.base.net_root.to_vec()), "key 5 = the key 7 node's current secrets");
}

#[test]
fn t8b_seventeen_removals() {
    // a member who always imports gets the last 16 at most and keeps up; one who never did is too old
    let mut rec = record(vec![entry(A, MemberState::Applied, None), entry(B, MemberState::Approved, Some(1))]);
    let mut x = p_mnet(B);
    let mut never = p_mnet(B);
    never.invite_hash = [8; 32];
    for i in 0..17u8 {
        let n = N { dac: 0x80 + i, ecdh: 0x43, owner: 0x60 + i, enc: 0x34 };
        rec.list.as_mut().unwrap().push(entry(n, MemberState::Approved, None));
        rec = removed(&rec, Target::Person(pk(0x60 + i)));
        let hex = bundle(&rec, P).unwrap();
        let steps = match cbor::decode(&batman_proto::invite::qr_object(&hex, 4).unwrap()).unwrap().get(2) {
            Some(V::Array(a)) => a.len(),
            _ => panic!(),
        };
        assert!(steps <= 16, "{steps}");
        x = import(&x, &hex, &[B]).unwrap().1;
        assert_eq!(x.version, rec.netcfg().unwrap().version);
    }
    let hex = bundle(&rec, P).unwrap();
    assert_eq!(import(&never, &hex, &[B]).map(|r| r.0), Err(mupdate::Refusal::TooOld));
    // key 13 keeps the last 32 only (here 18: all)
    assert_eq!(rec.versions.as_ref().unwrap().len(), 18);
}

#[test]
fn t11_the_removed_person_gets_nothing_from_another_update() {
    // Q removed; P's update pasted on Q's phone: no secrets for Q's nodes / not for Q's phone
    let v2 = removed(&team(), Target::Person(pk(Q)));
    let hex = bundle(&v2, P).unwrap();
    let q = p_mnet(D);
    assert_eq!(import_as(&q, &hex, &[D], Q_ENC).map(|r| r.0), Err(mupdate::Refusal::NotForMe));
    // even holding B's DAC hash (a lie about the own nodes): member_secrets are for P's phone only
    assert_eq!(import_as(&q, &hex, &[B], Q_ENC).map(|r| r.0), Err(mupdate::Refusal::MissingOwn(dev(D)[16..].to_string())));
    let mut q2 = q.clone();
    q2.me = None;
    assert_eq!(import_as(&q2, &hex, &[B], Q_ENC).map(|r| r.0), Err(mupdate::Refusal::NotForThisPhone));
    // and the node: secrets for B do not decrypt at D (the fake node refuses, see t5)
}

fn edit(hex: &str, f: impl FnOnce(&mut Vec<(V, V)>)) -> String {
    let mut v = cbor::decode(&batman_proto::invite::qr_object(hex, 4).unwrap()).unwrap();
    let V::Map(e) = &mut v else { panic!() };
    f(e);
    batman_proto::invite::qr_hex(4, &cbor::encode(&v))
}
fn set(e: &mut [(V, V)], k: u64, x: V) {
    for (kk, vv) in e.iter_mut() {
        if *kk == V::Uint(k) {
            *vv = x;
            return;
        }
    }
    panic!("no key {k}");
}

#[test]
fn t12_tampered_unsigned_old_and_forged_updates_are_refused_and_nothing_changes() {
    let v2 = removed(&team(), Target::Person(pk(Q)));
    let hex = bundle(&v2, P).unwrap();
    let x = p_mnet(B);
    // secrets signed by another key
    let s = netrec::sign1_payload(&{
        let v = cbor::decode(&batman_proto::invite::qr_object(&hex, 4).unwrap()).unwrap();
        let V::Array(se) = v.get(3).unwrap().clone() else { panic!() };
        cbor::encode(&se[0])
    })
    .unwrap();
    let forged = sign1(0x67, cose::CT_SECRETS, &cbor::encode(&s));
    let h = edit(&hex, |e| set(e, 3, V::Array(vec![cbor::decode(&forged).unwrap()])));
    assert_eq!(import(&x, &h, &[B]).map(|r| r.0), Err(mupdate::Refusal::Invalid("signature")));
    // a chain step signed by another key (a forged v2)
    let p = netrec::sign1_payload(&v2.base.netcfg).unwrap();
    let fake_cfg = sign1(0x67, cose::CT_NETCFG, &cbor::encode(&p));
    let h = edit(&hex, |e| {
        let V::Array(st) = &mut e.iter_mut().find(|(k, _)| *k == V::Uint(2)).unwrap().1 else { panic!() };
        let last = st.last_mut().unwrap();
        let V::Map(se) = last else { panic!() };
        set(se, 1, cbor::decode(&fake_cfg).unwrap());
    });
    assert_eq!(import(&x, &h, &[B]).map(|r| r.0), Err(mupdate::Refusal::Invalid("signature")));
    // unknown key / too large / another kind
    let h = edit(&hex, |e| e.push((V::Uint(9), V::Uint(1))));
    assert_eq!(import(&x, &h, &[B]).map(|r| r.0), Err(mupdate::Refusal::Format("update keys")));
    let big = batman_proto::invite::qr_hex(4, &vec![0u8; rekey::MAX_BUNDLE + 1]);
    assert_eq!(import(&x, &big, &[B]).map(|r| r.0), Err(mupdate::Refusal::Format("too large")));
    assert!(import(&x, &batman_proto::invite::qr_hex(3, b"x"), &[B]).is_err());
    // an older update than the phone holds
    let (_, x2) = import(&x, &hex, &[B]).unwrap();
    let mut v2b = v2.clone();
    v2b.list.as_mut().unwrap().push(entry(D, MemberState::Approved, Some(2)));
    let v3 = removed(&v2b, Target::Person(pk(Q)));
    let (_, x3) = import(&x2, &bundle(&v3, P).unwrap(), &[B]).unwrap();
    assert_eq!(import(&x3, &hex, &[B]).map(|r| r.0), Err(mupdate::Refusal::Older));
    // a same-numbered other v2 (a fork: other members): refused
    let mut t2 = team();
    t2.list.as_mut().unwrap().push(entry(N { dac: 0x5b, ecdh: 0x48, owner: 0x35, enc: 0x36 }, MemberState::Approved, None));
    let other = removed(&t2, Target::Person(pk(Q)));
    assert_eq!(import(&x2, &bundle(&other, P).unwrap(), &[B]).map(|r| r.0), Err(mupdate::Refusal::Fork));
    // the stale generation between the two parts
    let plain = x.encode();
    let Prepared::Advance { eph_pub, .. } = mupdate::prepare(&hex, Some(&plain), 3, &own(&[B]), &pk(P_ENC)).unwrap() else { panic!() };
    let z = ecdh_z(P_ENC, &eph_pub);
    assert_eq!(mupdate::import(&hex, Some(&plain), 4, 3, &own(&[B]), &pk(P_ENC), Some(&z)).map(|_| ()), Err(mupdate::Refusal::Stale));
    // no mnet: import the approval first
    assert_eq!(mupdate::prepare(&hex, None, 0, &own(&[B]), &pk(P_ENC)), Err(mupdate::Refusal::NoNetwork));
}

#[test]
fn t12_an_own_node_removed_in_that_version_is_refused() {
    // rule 6 (only a crafted update can get here: the admin never lists a removed node): v2's members re-signed with
    // B in removed
    let v2 = removed(&team(), Target::Person(pk(Q)));
    let hex = bundle(&v2, P).unwrap();
    let mut mp = netrec::sign1_payload(&v2.base.members).unwrap();
    if let V::Map(e) = &mut mp {
        set(e, 5, V::Array(vec![V::Bytes(dac(D.dac).to_vec()), V::Bytes(dac(B.dac).to_vec())]));
    }
    let mem = sign1(ADMIN, cose::CT_MEMBERS, &cbor::encode(&mp));
    let h = edit(&hex, |e| {
        let V::Array(st) = &mut e.iter_mut().find(|(k, _)| *k == V::Uint(2)).unwrap().1 else { panic!() };
        let V::Map(se) = st.last_mut().unwrap() else { panic!() };
        set(se, 2, cbor::decode(&mem).unwrap());
    });
    assert_eq!(import(&p_mnet(B), &h, &[B]).map(|r| r.0), Err(mupdate::Refusal::Removed(dev(B)[16..].to_string())));
    // negative control: the update as made imports
    assert!(import(&p_mnet(B), &hex, &[B]).is_ok());
}

#[test]
fn t20_two_removals_in_a_row() {
    let v2 = removed(&team(), Target::Person(pk(Q)));
    let mut v2b = v2.clone();
    v2b.list.as_mut().unwrap().push(entry(D, MemberState::Approved, Some(2)));
    let v3 = removed(&v2b, Target::Person(pk(Q)));
    let hex = bundle(&v3, P).unwrap();
    let steps = match cbor::decode(&batman_proto::invite::qr_object(&hex, 4).unwrap()).unwrap().get(2) {
        Some(V::Array(a)) => a.len(),
        _ => panic!(),
    };
    assert_eq!(steps, 3, "v1 (P's known 0 -> start 1), v2, v3");
    assert_eq!(import(&p_mnet(B), &hex, &[B]).unwrap().1.version, 3);
}

#[test]
fn t29_t37_one_person_two_nodes() {
    // P has B (key 7) and later B2 approved at v2 (+1 path: key 10 cleared); the update at v3 carries both
    let mut rec = team();
    rec.list.as_mut().unwrap().push(entry(B2, MemberState::Approved, None));
    let v2 = removed(&rec, Target::Person(pk(Q)));
    let hex = bundle(&v2, P).unwrap();
    let (_, x) = import(&p_mnet(B), &hex, &[B, B2]).unwrap();
    assert!(x.secrets_for(&dac(B.dac)).is_some() && x.secrets_for(&dac(B2.dac)).is_some(), "key 5 for B, key 10 for B2");
    assert_eq!(open_secrets(&x.secrets_for(&dac(B2.dac)).unwrap(), B2).0, v2.base.sae);
    // T37: an update that only has B's secrets on a phone already at that version and lacking B2's: Already for B;
    // with B2's secrets missing in key 10 the same version adds them (rules 3-6 run)
    let mut x_no_b2 = x.clone();
    x_no_b2.node_secrets.retain(|n| n.dac_hash != dac(B2.dac));
    let (i, y) = import(&x_no_b2, &hex, &[B, B2]).unwrap();
    assert_eq!(i, Imp::Added);
    assert!(y.secrets_for(&dac(B2.dac)).is_some());
    // key 10 of another version counts as none
    let mut stale = x.clone();
    stale.version = 3;
    assert!(stale.secrets_for(&dac(B2.dac)).is_none());
}

// ---- 「把新密碼送給節點」 against the fake node (T5, T9, T19, T27, T30) --------------------------------------------

#[test]
fn t5_the_admin_sends_the_chain_and_the_node_takes_it() {
    let rec = team();
    let v2 = removed(&rec, Target::Person(pk(P)));
    let (conn, mut node) = pair(A);
    let s = send(&mut node, conn, netrec::encode(&v2), false, Some(verified(A)));
    assert_eq!((s.end, s.signs), (updflow::End::Updated, 1));
    assert_eq!(node.version, 2);
    assert_eq!(node.keys, (v2.base.sae.clone(), v2.base.net_root.to_vec()), "the node runs with the new SAE / net_root");
    assert_eq!(node.got, vec!["info", "network/update", "info"]);
    // again: already current, nothing sent
    let (conn, mut n2) = pair(A);
    n2.version = 2;
    let s = send(&mut n2, conn, netrec::encode(&v2), false, Some(verified(A)));
    assert_eq!((s.end, n2.got.len()), (updflow::End::AlreadyCurrent, 1));
}

#[test]
fn t5_every_branch() {
    let v2 = removed(&team(), Target::Person(pk(P)));
    let plain = netrec::encode(&v2);
    let run = |f: &dyn Fn(&mut Node)| {
        let (conn, mut node) = pair(A);
        f(&mut node);
        let s = send(&mut node, conn, plain.clone(), false, Some(verified(A)));
        (s.end, node.got.iter().filter(|v| *v == "network/update").count(), s.waits)
    };
    use updflow::End as E;
    assert_eq!(run(&|n| n.in_net = false), (E::NotApplied { rejoin: true }, 0, 0));
    assert_eq!(run(&|n| n.unfinished = true), (E::Unfinished, 0, 0));
    assert_eq!(run(&|n| {
        n.in_net = false;
        n.unfinished = true;
    }), (E::InProgress, 0, 0));
    assert_eq!(run(&|n| n.info_q.push_back(Some(Ans::Info(m(vec![(9, V::Uint(1)), (10, V::Bytes(vec![0x99; 16])), (11, V::Bool(false))]))))), (E::OtherNetwork, 0, 0));
    // Unknown (E_RATE) twice, then readable: 2 waits of 2 s, then sent
    assert_eq!(run(&|n| {
        n.info_q.push_back(Some(Ans::Err(12, m(vec![]))));
        n.info_q.push_back(Some(Ans::Info(m(vec![]))));
    }), (E::Updated, 1, 2));
    assert_eq!(run(&|n| (0..3).for_each(|_| n.info_q.push_back(Some(Ans::Err(12, m(vec![])))))), (E::Unknown, 0, 2));
    // key 4: old / unparsable / overflowing / absent -> needs software, nothing sent
    for k4 in ["1.5.14-wsl.24+x", "1.5.14+x", "1.5.14-wsl.1234567890", ""] {
        assert_eq!(run(&|n| n.k4 = k4.into()), (E::NeedsSoftware, 0, 0), "{k4}");
    }
    assert_eq!(run(&|n| n.version = 3), (E::NodeNewer, 0, 0));
    // the node answers the update with E_REJECTED{2: 14} and stays at v1: an app bug
    assert_eq!(run(&|n| n.update_q.push_back(Ans::Err(11, m(vec![(2, V::Uint(14))])))), (E::AppBug, 1, 0));
    assert_eq!(run(&|n| n.update_q.push_back(Ans::Err(7, m(vec![])))), (E::NotChanged, 1, 0));
    // the answer is lost but the node applied (info after: v2) -> changed; key 11 true after -> applying
    assert_eq!(run(&|n| {
        n.update_q.push_back(Ans::Err(11, m(vec![])));
        n.info_q.push_back(None);
        n.info_q.push_back(Some(Ans::Info(applied_info(2))));
    }), (E::Updated, 1, 0));
    assert_eq!(run(&|n| {
        n.update_q.push_back(Ans::Err(11, m(vec![])));
        n.info_q.push_back(None);
        n.info_q.push_back(Some(Ans::Info(m(vec![(4, V::Text("1.5.14-wsl.25".into())), (9, V::Uint(1)), (10, V::Bytes(NET_ID.to_vec())), (11, V::Bool(true))]))));
    }), (E::Applying, 1, 0));
    assert!(updflow::version_ok(Some("1.5.14-wsl.25+fbc01ae.fw02f0913")));
    assert!(updflow::version_ok(Some("1.6.0-wsl.100")));
    assert!(!updflow::version_ok(None));
}

#[test]
fn t9_too_far_behind_is_never_sent() {
    // 16 members with 32-byte names over 17 versions: more than 8 chunks (NU §3: 14 steps of 16 members = 8 chunks)
    let long = |n: N| Member { name: format!("{:0>32}", n.dac), ..entry(n, MemberState::Approved, Some(1)) };
    let mut rec = record(vec![Member { name: "a".repeat(32), ..entry(A, MemberState::Applied, None) }]);
    for i in 0..15u8 {
        rec.list.as_mut().unwrap().push(long(N { dac: 0xa0 + i, ecdh: 0x44, owner: 0x40 + i, enc: 0x34 }));
    }
    for i in 0..17u8 {
        rec.list.as_mut().unwrap().push(long(N { dac: 0xc0 + i, ecdh: 0x44, owner: 0x90 + i, enc: 0x34 }));
        rec = removed(&rec, Target::Person(pk(0x90 + i)));
    }
    assert_eq!(rec.netcfg().unwrap().version, 18);
    let (conn, mut node) = pair(A);
    let s = send(&mut node, conn, netrec::encode(&rec), false, Some(verified(A)));
    assert_eq!((s.end, node.got.clone()), (updflow::End::TooFar { rejoin: true }, vec!["info".to_string()]));
    // older than the kept versions
    let mut cut = rec.clone();
    cut.versions.as_mut().unwrap().remove(0);
    let (conn, mut node) = pair(A);
    let s = send(&mut node, conn, netrec::encode(&cut), false, Some(verified(A)));
    assert_eq!(s.end, updflow::End::TooFar { rejoin: true });
    // a node 6 versions behind gets the chain in several chunks and takes it
    let (conn, mut node) = pair(A);
    node.version = 12;
    node.cfg_hash = cose::object_hash(&rec.versions.as_ref().unwrap()[11].netcfg).unwrap();
    let body = updflow::body(&rec.versions.as_ref().unwrap()[12..], &[0xa0]).map(|b| cbor::encode(&b).len());
    assert!(body.unwrap() > 8192, "chunked");
    let s = send(&mut node, conn, netrec::encode(&rec), false, Some(verified(A)));
    assert_eq!(s.end, updflow::End::Updated);
    assert_eq!(node.version, 18);
}

#[test]
fn t27_the_target_rule() {
    // rule 1: the excluded own node is not in key 11 -> nothing sent, nothing signed
    let rec = record(vec![entry(A, MemberState::Applied, None), entry(A2, MemberState::Applied, None)]);
    let v2 = removed(&rec, Target::Node(dac(A2.dac)));
    let (conn, mut node) = pair(A2);
    let s = send(&mut node, conn, netrec::encode(&v2), false, Some(verified(A2)));
    assert_eq!((s.end, s.signs, node.got.len()), (updflow::End::NotListed, 0, 0));
    // negative control: the record before the exclusion (A2 listed) sends
    let (conn, mut node) = pair(A2);
    node.version = 0;
    node.in_net = true;
    let s = send(&mut node, conn, netrec::encode(&rec), false, Some(verified(A2)));
    assert_ne!(s.end, updflow::End::NotListed);
    // rule 3: a member phone without B2's current secrets
    let mut x = p_mnet(B);
    x.version = 2;
    let (conn, mut node) = pair(B2);
    let s = send(&mut node, conn, x.encode(), true, Some(verified(B2)));
    assert_eq!((s.end, node.got.len()), (updflow::End::NoSecrets, 0));
    // not verified at login
    let (conn, mut node) = pair(A);
    assert_eq!(send(&mut node, conn, netrec::encode(&v2), false, None).end, updflow::End::NotVerified);
}

#[test]
fn t30_the_member_sends_after_import_and_both_nodes_take_it() {
    let mut rec = team();
    rec.list.as_mut().unwrap().push(entry(B2, MemberState::Approved, None));
    let v2 = removed(&rec, Target::Person(pk(Q)));
    let (_, x) = import(&p_mnet(B), &bundle(&v2, P).unwrap(), &[B, B2]).unwrap();
    for n in [B, B2] {
        let (conn, mut node) = pair(n);
        let s = send(&mut node, conn, x.encode(), true, Some(verified(n)));
        assert_eq!((s.end, s.signs), (updflow::End::Updated, 0), "member: the stored secrets, nothing signed");
        assert_eq!(node.keys, (v2.base.sae.clone(), v2.base.net_root.to_vec()));
    }
    // the member's non-key-7 node out of the network: the admin re-invites it
    let (conn, mut node) = pair(B2);
    node.in_net = false;
    assert_eq!(send(&mut node, conn, x.encode(), true, Some(verified(B2))).end, updflow::End::NotApplied { rejoin: false });
    // T29 negative control: the old secrets (v1) for B sent with the v2 chain -> the node refuses them
    let mut old = x.clone();
    old.secrets = node_secrets(1, SAE1, &ROOT1, B);
    old.node_secrets.clear();
    old.me = None;
    old.node_secrets.push(batman_proto::mrec::NodeSecrets { dac_hash: dac(B.dac), secrets: node_secrets(1, SAE1, &ROOT1, B) });
    let (conn, mut node) = pair(B);
    assert_eq!(send(&mut node, conn, old.encode(), true, Some(verified(B))).end, updflow::End::NoSecrets, "secrets of another version count as none");
}

// ---- T16 / T18 / T17b / T38: the other flows after a removal ----------------------------------------------------------

#[test]
fn t16_invites_from_before_are_used() {
    let mut rec = team();
    rec.invites = Some(vec![InviteRec { hash: [1; 32], kind: 1, used: false }, InviteRec { hash: [2; 32], kind: 1, used: true }]);
    let after = removed(&rec, Target::Person(pk(Q)));
    assert!(after.invites.unwrap().iter().all(|i| i.used));
}

#[test]
fn t18_other_writers_keep_key_13_and_key_10() {
    let v2 = removed(&team(), Target::Person(pk(Q)));
    let mut a = v2.clone();
    a.list.as_mut().unwrap()[1].known = Some(2);
    let back = netrec::decode(&netrec::encode(&a)).unwrap();
    assert!(back == a, "key 13 and key 10 survive the codec");
    // an invite (decode -> change -> encode) keeps them
    let (mut f, act) = batman_proto::invite::InviteFlow::start(&netrec::encode(&a), 1, &pk(ADMIN));
    let batman_proto::invite::Action::SignAdmin { tbs } = act else { panic!("{act:?}") };
    let Some(batman_proto::invite::Action::Persist { plain, .. }) = f.signed(&der(ADMIN, &tbs)) else { panic!() };
    let r = netrec::decode(&plain).unwrap();
    assert_eq!((r.versions.clone(), r.list.unwrap()[1].known), (a.versions.clone(), Some(2)));
    // forget keeps them
    let mut j = a.clone();
    j.list.as_mut().unwrap().push(entry(A2, MemberState::Joining, None));
    netrec::forget_joining(&mut j, &dac(A2.dac)).unwrap();
    let r = netrec::decode(&netrec::encode(&j)).unwrap();
    assert_eq!((r.versions, r.list.unwrap()[1].known), (a.versions, Some(2)));
    // key 10 is not written into a member's mnet key 7
    let mut x = p_mnet(B);
    x.me.as_mut().unwrap().known = Some(5);
    assert_eq!(MNet::decode(&x.encode()).unwrap().me.unwrap().known, None);
}

#[test]
fn t24_no_secret_in_any_debug_text() {
    let v2 = removed(&team(), Target::Person(pk(P)));
    let root = hex::encode(v2.base.net_root);
    let (_, a) = Rekey::start(&netrec::encode(&team()), 1, &pk(ADMIN), &pk(OWNER), &Target::Person(pk(P)), &[]);
    let p = Action::Persist { rel: "net/x".into(), plain: netrec::encode(&v2), expected_gen: 1 };
    let i = batman_proto::invite::Action::Persist { rel: "net/x".into(), plain: netrec::encode(&v2), expected_gen: 1 };
    for t in [format!("{a:?}"), format!("{p:?}"), format!("{i:?}"), format!("{:?}", v2.base)] {
        assert!(!t.contains(&root) && !t.contains(&v2.base.sae), "{t}");
        let bytes = format!("{:?}", v2.base.net_root);
        assert!(!t.contains(&bytes[1..40]), "{t}");
    }
}

/// the last step's netcfg (1) or members (2) replaced by `by`'s signature over the edited payload
fn edit_step(hex: &str, k: u64, by: u8, ct: &str, f: impl FnOnce(&mut Vec<(V, V)>)) -> String {
    let v = cbor::decode(&batman_proto::invite::qr_object(hex, 4).unwrap()).unwrap();
    let V::Array(st) = v.get(2).unwrap() else { panic!() };
    let mut p = netrec::sign1_payload(&cbor::encode(st.last().unwrap().get(k).unwrap())).unwrap();
    let V::Map(e) = &mut p else { panic!() };
    f(e);
    let obj = sign1(by, ct, &cbor::encode(&p));
    edit(hex, |e| {
        let V::Array(st) = &mut e.iter_mut().find(|(kk, _)| *kk == V::Uint(2)).unwrap().1 else { panic!() };
        let V::Map(se) = st.last_mut().unwrap() else { panic!() };
        set(se, k, cbor::decode(&obj).unwrap());
    })
}

/// mutation negative controls R03-R06, R08 (each check of §3.4 rules 2 / 3 on its own; nothing written)
#[test]
fn t12_every_chain_check_on_its_own() {
    let v2 = removed(&team(), Target::Person(pk(Q)));
    let hex = bundle(&v2, P).unwrap();
    let x = p_mnet(B);
    let r = |h: &str| import(&x, h, &[B]).map(|r| r.0);
    assert!(r(&hex).is_ok(), "the update as made imports");
    // R03: a v2 that names its own signer as admin and is signed by it (not by v1 admins)
    let h = edit_step(&hex, 1, 0x67, cose::CT_NETCFG, |e| set(e, 8, V::Array(vec![V::Bytes(pk(0x67).to_vec())])));
    assert_eq!(r(&h), Err(mupdate::Refusal::Invalid("signature")));
    // R04: prev_hash not v1's
    let h = edit_step(&hex, 1, ADMIN, cose::CT_NETCFG, |e| set(e, 3, V::Bytes(vec![9; 32])));
    assert_eq!(r(&h), Err(mupdate::Refusal::Invalid("not the next version")));
    // R05: the country changed in the chain
    let h = edit_step(&hex, 1, ADMIN, cose::CT_NETCFG, |e| set(e, 5, V::Text("US".into())));
    assert_eq!(r(&h), Err(mupdate::Refusal::Invalid("country changed")));
    // R06: members not chained to v1's
    let h = edit_step(&hex, 2, ADMIN, cose::CT_MEMBERS, |e| set(e, 3, V::Bytes(vec![9; 32])));
    assert_eq!(r(&h), Err(mupdate::Refusal::Invalid("members prev_hash")));
    // R08: the node's secrets of v1 (signed by the admin) in a v2 update
    let old = node_secrets(1, SAE1, &ROOT1, B);
    let h = edit(&hex, |e| set(e, 3, V::Array(vec![cbor::decode(&old).unwrap()])));
    assert_eq!(r(&h), Err(mupdate::Refusal::Invalid("secrets net_id / version")));
}

/// code review r1 F2 / B MAJOR-2: the remaining chain / secrets checks, each on its own
#[test]
fn t12_more_checks_on_their_own() {
    let v2 = removed(&team(), Target::Person(pk(Q)));
    let hex = bundle(&v2, P).unwrap();
    let x = p_mnet(B);
    let r = |h: &str| import(&x, h, &[B]).map(|r| r.0);
    // members of v2 signed by another key
    let h = edit_step(&hex, 2, 0x67, cose::CT_MEMBERS, |_| {});
    assert_eq!(r(&h), Err(mupdate::Refusal::Invalid("signature")));
    // members naming another version
    let h = edit_step(&hex, 2, ADMIN, cose::CT_MEMBERS, |e| set(e, 2, V::Uint(3)));
    assert_eq!(r(&h), Err(mupdate::Refusal::Invalid("members net_id / version")));
    // a netcfg of another net_id (signed by the admin, chained)
    let h = edit_step(&hex, 1, ADMIN, cose::CT_NETCFG, |e| set(e, 1, V::Bytes(vec![0x99; 16])));
    assert_eq!(r(&h), Err(mupdate::Refusal::Invalid("not the next version")));
    // member_secrets signed by another key (ECDH-ES does not name the sender: only the signature does)
    let ms = {
        let v = cbor::decode(&batman_proto::invite::qr_object(&hex, 4).unwrap()).unwrap();
        netrec::sign1_payload(&cbor::encode(v.get(4).unwrap())).unwrap()
    };
    let forged = sign1(0x67, cose::CT_MSECRETS, &cbor::encode(&ms));
    let h = edit(&hex, |e| set(e, 4, cbor::decode(&forged).unwrap()));
    assert_eq!(r(&h), Err(mupdate::Refusal::Invalid("signature")));
    // member_secrets of v1
    let mut ms1 = ms.clone();
    if let V::Map(e) = &mut ms1 {
        set(e, 2, V::Uint(1));
    }
    let old = sign1(ADMIN, cose::CT_MSECRETS, &cbor::encode(&ms1));
    let h = edit(&hex, |e| set(e, 4, cbor::decode(&old).unwrap()));
    assert_eq!(r(&h), Err(mupdate::Refusal::Invalid("secrets net_id / version")));
    // an UNSIGNED edit of a version the phone holds is invalid, not "another history" (B-m3)
    let (_, x2) = import(&x, &hex, &[B]).unwrap();
    let h = edit_step(&hex, 1, 0x67, cose::CT_NETCFG, |e| set(e, 4, V::Text("x".into())));
    assert_eq!(import(&x2, &h, &[B]).map(|r| r.0), Err(mupdate::Refusal::Invalid("signature")));
    // the size limit on the pasted text, before any decoding (B-m4)
    let huge = "a".repeat(2 * (rekey::MAX_BUNDLE + 16) + 2);
    assert_eq!(mupdate::update_net_id(&huge), Err(mupdate::Refusal::Format("too large")));
}

/// T37 core (code review r1 F3): the same version, an update with only the second node secrets: rule 4 does not
/// ask for the key 7 node (it is not advancing)
#[test]
fn t37_the_same_version_does_not_need_the_key_7_node() {
    let mut rec = team();
    rec.list.as_mut().unwrap().push(entry(B2, MemberState::Approved, None));
    let v2 = removed(&rec, Target::Person(pk(Q)));
    let hex = bundle(&v2, P).unwrap();
    let (_, x) = import(&p_mnet(B), &hex, &[B, B2]).unwrap();
    let only_b2 = edit(&hex, |e| {
        let V::Array(se) = e.iter().find(|(k, _)| *k == V::Uint(3)).unwrap().1.clone() else { panic!() };
        let keep: Vec<V> = se.into_iter().filter(|s| netrec::sign1_payload(&cbor::encode(s)).unwrap().get(3).and_then(V::as_bytes) == Some(&dac(B2.dac)[..])).collect();
        set(e, 3, V::Array(keep));
    });
    let mut lacking = x.clone();
    lacking.node_secrets.clear();
    assert_eq!(import(&lacking, &only_b2, &[B, B2]).map(|r| r.0), Ok(Imp::Added));
    // advancing with only the B2 secrets: the key 7 node secrets are required
    assert_eq!(import(&p_mnet(B), &only_b2, &[B, B2]).map(|r| r.0), Err(mupdate::Refusal::MissingOwn(dev(B)[16..].to_string())));
}

/// code review r1 F4: an own node at a key 9 older than every kept version does not vouch (§2.4)
#[test]
fn t15_a_node_older_than_the_kept_versions_does_not_vouch() {
    let rec = record(vec![entry(A, MemberState::Applied, None), entry(B, MemberState::Approved, None), entry(D, MemberState::Approved, None)]);
    let v2 = removed(&rec, Target::Person(pk(Q)));
    let mut cut = v2.clone();
    cut.versions.as_mut().unwrap().remove(0); // keeps v2 only
    let p = rekey::precheck(&cut, &pk(ADMIN), &pk(OWNER), &Target::Person(pk(P)), &reads(&[(A, Some(applied_info(1)))])).unwrap();
    assert!(p.unverified, "k9 = 1 is not kept: not vouched");
    let p = rekey::precheck(&v2, &pk(ADMIN), &pk(OWNER), &Target::Person(pk(P)), &reads(&[(A, Some(applied_info(1)))])).unwrap();
    assert!(!p.unverified, "negative control: kept -> vouched");
}

/// code review r1 F4 / B-m5: rule 1 needs this phone owner_pub and the ecdh_pub the login verified
#[test]
fn t27_rule1_owner_and_ecdh() {
    let mut other = entry(A, MemberState::Applied, None);
    other.owner_pub = pk(P);
    let rec = record(vec![other]);
    let (conn, mut node) = pair(A);
    assert_eq!(send(&mut node, conn, netrec::encode(&rec), false, Some(verified(A))).end, updflow::End::NotListed);
    let mut wrong = entry(A, MemberState::Applied, None);
    wrong.ecdh_pub = pk(0x48);
    let rec = record(vec![wrong]);
    let (conn, mut node) = pair(A);
    let s = send(&mut node, conn, netrec::encode(&rec), false, Some(verified(A)));
    assert_eq!((s.end, s.signs, node.got.len()), (updflow::End::NotListed, 0, 0));
}

/// v6.5 (code review r1 MAJOR): key 14 keeps who left; the real path approve -> remove -> come back
#[test]
fn t38_removed_before_on_the_real_path() {
    let v2 = removed(&team(), Target::Person(pk(P)));
    let d = v2.departed.clone().unwrap();
    assert_eq!(d.iter().map(|x| (x.dac_hash, x.owner_pub, x.name.clone())).collect::<Vec<_>>(), vec![(dac(B.dac), pk(P), "n57".to_string())]);
    // the same person with a brand-new node: asked, named
    let p = batman_proto::approve::previous_of(&v2, &[0xee; 32], &pk(P)).unwrap().expect("asked");
    assert_eq!((p.node, p.owner_name.as_deref(), p.owner_pub), (false, Some("n57"), Some(pk(P))));
    // the removed node itself (under anyone): asked, the previous owner named
    let p = batman_proto::approve::previous_of(&v2, &dac(B.dac), &pk(0x70)).unwrap().expect("asked");
    assert_eq!((p.node, p.owner_name.as_deref()), (true, Some("n57")));
    // an own node excluded: its name too
    let mut r = team();
    r.list.as_mut().unwrap().push(entry(A2, MemberState::Applied, None));
    let v2b = removed(&r, Target::Node(dac(A2.dac)));
    assert_eq!(v2b.last_listed(|m| m.dac_pub_hash == dac(A2.dac)).unwrap().map(|m| m.name), Some("n56".into()));
    // removed twice: one entry per node, the newest
    let mut back = v2.clone();
    back.list.as_mut().unwrap().push(entry(B, MemberState::Approved, Some(2)));
    let v3 = removed(&back, Target::Person(pk(P)));
    assert_eq!(v3.departed.unwrap().len(), 1);
    // negative control: an older app wrote the record back without key 14 -> the members lists only
    let mut old = v2.clone();
    old.departed = None;
    assert_eq!(batman_proto::approve::previous_of(&old, &[0xee; 32], &pk(P)).unwrap(), None);
    // key 14 survives the codec
    assert_eq!(netrec::decode(&netrec::encode(&v2)).unwrap().departed, v2.departed);
}

/// T10 (code review r1 F5): an older app write drops keys 13 / 14 / 10; the record still opens and the next update
/// starts from what is left
#[test]
fn t10_after_a_downgrade_and_upgrade() {
    let v2 = removed(&team(), Target::Person(pk(Q)));
    let mut old = v2.clone();
    old.versions = None;
    old.departed = None;
    old.list.as_mut().unwrap().iter_mut().for_each(|m| m.known = None);
    let back = netrec::decode(&netrec::encode(&old)).unwrap();
    assert_eq!(back.history().unwrap().iter().map(|x| x.version).collect::<Vec<_>>(), vec![2]);
    let r = rekey::recipients(&back, &pk(OWNER)).unwrap();
    assert!(r[0].unknown_before, "the unknown-before line");
    let hex = bundle(&back, P).unwrap();
    // P still at v1: the update has only v2 and imports (exactly one behind)
    assert_eq!(import(&p_mnet(B), &hex, &[B]).map(|r| r.0), Ok(Imp::Advanced(2)));
}

/// T24 negative control: a derived Debug over the same bytes would show them
#[test]
fn t24_a_derived_debug_would_leak() {
    #[derive(Debug)]
    #[allow(dead_code)]
    struct Leaky {
        net_root: [u8; 32],
    }
    let t = format!("{:?}", Leaky { net_root: [0xab; 32] });
    assert!(t.contains("171, 171"), "{t}");
    assert!(!format!("{:?}", team().base).contains("119, 119"), "the redacted Debug of the record (net_root 0x77)");
}

/// key 14 keeps "removed before" after the members lists that said so are gone (key 13 pruned past 32 versions):
/// mutation R37
#[test]
fn t38_key_14_outlives_the_pruned_versions() {
    let v2 = removed(&team(), Target::Person(pk(P)));
    let mut pruned = v2.clone();
    pruned.versions = None;
    pruned.base.members = members_v1(); // what is left lists nobody as removed
    assert!(pruned.removed_ever().unwrap().contains(&dac(B.dac)));
    pruned.departed = None;
    assert!(!pruned.removed_ever().unwrap().contains(&dac(B.dac)), "negative control: without key 14");
}
