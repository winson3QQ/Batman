//! joinflow: a whole first-node network/join against a fake node that checks the request on its own: the three admin
//! signatures over Sig_structures it rebuilds, net_secrets decrypted with the node's ECDH key and a KDF context it
//! builds itself, the net_config / members contents, and the owner-op signature.

use batman_proto::cbor::{self, Value as V};
use batman_proto::conn::Conn;
use batman_proto::envelope::Outcome;
use batman_proto::flow::JoinReply;
use batman_proto::joinflow::{self, Action, End, Input, Join, NetRecord};
use batman_proto::{frame, kdf, noise, sig};
use chacha20poly1305::aead::{Aead, KeyInit, Payload};
use p256::ecdsa::signature::{Signer, Verifier};
use serde_json::Value as J;
use sha2::{Digest, Sha256};
use std::path::PathBuf;

const FL: usize = 244;
const NODE_ECDH_PRIV: &str = "5fc9a2c8dc0c10edeec4d50654765f2d4aee146880e072d036f584e55bbf3764";

fn vectors() -> J {
    let p = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../../tests/vectors/219-protocol/vectors.json");
    serde_json::from_str(&std::fs::read_to_string(p).unwrap()).unwrap()
}
fn h(v: &J) -> Vec<u8> {
    hex::decode(v.as_str().unwrap()).unwrap()
}
fn m(pairs: Vec<(u64, V)>) -> V {
    V::Map(pairs.into_iter().map(|(k, v)| (V::Uint(k), v)).collect())
}
fn key(b: u8) -> p256::ecdsa::SigningKey {
    p256::ecdsa::SigningKey::from_slice(&[b; 32]).unwrap()
}
fn pub_of(k: &p256::ecdsa::SigningKey) -> [u8; 65] {
    k.verifying_key().to_sec1_point(false).as_bytes().try_into().unwrap()
}
fn nint(m: &V, n: u64) -> Option<&V> {
    let V::Map(e) = m else { return None };
    e.iter().find(|(k, _)| *k == V::Nint(n)).map(|(_, v)| v)
}

struct Node {
    t: snow::TransportState,
    hh: [u8; 32],
    rx: frame::Reassembler,
    helper: Option<[u8; 32]>,
    join_code: Option<u64>,
    nonce_code: Option<u64>,
    got: Vec<String>,
    /// what the node decrypted from net_secrets: (sae, net_root)
    secrets: Option<(String, Vec<u8>)>,
    netcfg: Option<V>,
    v: J,
}

/// an established session (the owner login is loginflow's business)
fn pair(v: &J) -> (Conn, Node) {
    let p: snow::params::NoiseParams = "Noise_NX_25519_ChaChaPoly_SHA256".parse().unwrap();
    let pro = noise::prologue(noise::Mode::Nx, Some("x"));
    let mut r = snow::Builder::new(p).prologue(&pro).unwrap().local_private_key(&h(&v["keys"]["s_node_priv"])).unwrap().build_responder().unwrap();
    let mut i = noise::Initiator::new(noise::Mode::Nx, Some("x"), None).unwrap();
    let mut buf = vec![0u8; 65535];
    r.read_message(&i.msg1().unwrap(), &mut buf).unwrap();
    let n = r.write_message(b"cert", &mut buf).unwrap();
    let (_, s) = i.read_msg2(&buf[..n]).unwrap();
    let hh: [u8; 32] = r.get_handshake_hash().try_into().unwrap();
    let node = Node {
        t: r.into_transport_mode().unwrap(),
        hh,
        rx: frame::Reassembler::new(FL, 8192),
        helper: None,
        join_code: None,
        nonce_code: None,
        got: vec![],
        secrets: None,
        netcfg: None,
        v: v.clone(),
    };
    (Conn::new(s, FL), node)
}

impl Node {
    fn on(&mut self, frames: &[Vec<u8>]) -> Vec<Vec<u8>> {
        let mut msg = None;
        for f in frames {
            msg = self.rx.push(f).unwrap();
        }
        let Some(msg) = msg else { return vec![] };
        let mut buf = vec![0u8; 65535];
        let n = self.t.read_message(&msg, &mut buf).unwrap();
        let req = cbor::decode(&buf[..n]).unwrap();
        let id = req.get(1).and_then(|x| x.as_uint()).unwrap();
        let verb = req.get(2).and_then(|x| x.as_text()).unwrap().to_string();
        let body = req.get(3).unwrap().clone();
        self.got.push(verb.clone());
        let err = |c: u64| m(vec![(1, V::Uint(id)), (4, V::Uint(c)), (5, m(vec![]))]);
        let ok = |b: V| m(vec![(1, V::Uint(id)), (3, b), (4, V::Uint(0))]);
        let reply = match verb.as_str() {
            "op/nonce" => match self.nonce_code {
                Some(c) => err(c),
                None => {
                    self.helper = Some([0x6d; 32]);
                    ok(m(vec![(1, V::Bytes(vec![0x6d; 32]))]))
                }
            },
            "network/join" => match self.check_join(&body) {
                Err(why) => panic!("the node would refuse the join: {why}"),
                Ok(()) => match self.join_code {
                    Some(c) => err(c),
                    None => ok(m(vec![(1, V::Uint(0))])),
                },
            },
            _ => err(2),
        };
        let n = self.t.write_message(&cbor::encode(&reply), &mut buf).unwrap();
        frame::split(&buf[..n], FL).unwrap()
    }

    /// Sign1 = tag 18 [protected, {}, payload, sig]: verify with `pk` over a Sig_structure built here
    fn sign1(&self, item: &V, label: &[u8], ct: &str) -> Result<V, String> {
        let V::Tag(18, a) = item else { return Err("not tag 18".into()) };
        let V::Array(a) = a.as_ref() else { return Err("not an array".into()) };
        let prot = a[0].as_bytes().ok_or("protected")?;
        if a[1] != m(vec![]) {
            return Err("unprotected header not empty".into());
        }
        let p = cbor::decode(prot).map_err(|e| format!("{e:?}"))?;
        if p.get(1) != Some(&V::Nint(6)) || p.get(3).and_then(|x| x.as_text()) != Some(ct) {
            return Err(format!("protected header {p:?}"));
        }
        let payload = a[2].as_bytes().ok_or("payload")?;
        let s = a[3].as_bytes().ok_or("sig")?;
        let tbs = cbor::encode(&V::Array(vec![V::Text("Signature1".into()), V::Bytes(prot.to_vec()), V::Bytes(label.to_vec()), V::Bytes(payload.to_vec())]));
        let vk = p256::ecdsa::VerifyingKey::from_sec1_bytes(&pub_of(&key(0x66))).unwrap();
        vk.verify(&tbs, &p256::ecdsa::Signature::from_slice(s).map_err(|e| e.to_string())?).map_err(|_| format!("{ct}: admin signature"))?;
        cbor::decode(payload).map_err(|e| format!("{e:?}"))
    }

    fn check_join(&mut self, body: &V) -> Result<(), String> {
        // owner-op over the body without key 31
        let V::Map(e) = body else { return Err("body".into()) };
        let wo = V::Map(e.iter().filter(|(k, _)| *k != V::Uint(31)).cloned().collect());
        let op = body.get(31).ok_or("no owner-op")?;
        if op.get(1).and_then(|x| x.as_text()) != Some("network/join") {
            return Err("owner-op verb".into());
        }
        let s: [u8; 64] = op.get(2).and_then(|x| x.as_bytes()).ok_or("sig")?.try_into().map_err(|_| "sig len")?;
        if !sig::is_low_s(&s) {
            return Err("high-s".into());
        }
        let helper = self.helper.take().ok_or("nonce_helper used twice / never issued")?;
        let input = sig::owner_op_input(&self.hh, &helper, "network/join", &wo).unwrap();
        p256::ecdsa::VerifyingKey::from_sec1_bytes(&pub_of(&key(0x11)))
            .unwrap()
            .verify(&input, &p256::ecdsa::Signature::from_slice(&s).unwrap())
            .map_err(|_| "owner-op signature")?;
        // the three Sign1 objects
        let cfg = self.sign1(body.get(1).ok_or("1")?, b"batman-netcfg-v1", "batman/netcfg")?;
        let mem = self.sign1(body.get(2).ok_or("2")?, b"batman-members-v1", "batman/members")?;
        let sec = self.sign1(body.get(3).ok_or("3")?, b"batman-secrets-v1", "batman/secrets")?;
        let net_id = cfg.get(1).and_then(|x| x.as_bytes()).ok_or("net_id")?.to_vec();
        for (name, x) in [("members", &mem), ("secrets", &sec)] {
            if x.get(1).and_then(|y| y.as_bytes()) != Some(&net_id[..]) {
                return Err(format!("{name}: another net_id"));
            }
        }
        // net_secrets: key 3 = SHA-256(DAC pub), key 4 = COSE_Encrypt to the node's ECDH key
        let dac_hash: Vec<u8> = Sha256::digest(h(&self.v["keys"]["dac_pub"])).to_vec();
        if sec.get(3).and_then(|x| x.as_bytes()) != Some(&dac_hash[..]) {
            return Err("secrets: target hash".into());
        }
        let V::Tag(96, enc) = sec.get(4).ok_or("4")? else { return Err("not tag 96".into()) };
        let V::Array(a) = enc.as_ref() else { return Err("enc".into()) };
        let iv = a[1].get(5).and_then(|x| x.as_bytes()).ok_or("iv")?.to_vec();
        let ct = a[2].as_bytes().ok_or("ct")?.to_vec();
        let V::Array(rec) = &a[3] else { return Err("recipients".into()) };
        let V::Array(r0) = &rec[0] else { return Err("r0".into()) };
        let ck = nint(&r0[1], 0).ok_or("ephemeral key")?;
        let mut epk = vec![4u8];
        epk.extend(nint(ck, 1).and_then(|x| x.as_bytes()).ok_or("x")?);
        epk.extend(nint(ck, 2).and_then(|x| x.as_bytes()).ok_or("y")?);
        let node_priv = p256::SecretKey::from_slice(&hex::decode(NODE_ECDH_PRIV).unwrap()).unwrap();
        let z = p256::ecdh::diffie_hellman(node_priv.to_nonzero_scalar(), p256::PublicKey::from_sec1_bytes(&epk).unwrap().as_affine());
        let mut party_v = net_id.clone();
        party_v.extend(1u32.to_be_bytes());
        let rec_prot = cbor::encode(&V::Map(vec![(V::Uint(1), V::Nint(24))]));
        let ctx = cbor::encode(&V::Array(vec![
            V::Uint(24),
            V::Array(vec![V::Null, V::Null, V::Null]),
            V::Array(vec![V::Bytes(dac_hash.clone()), V::Null, V::Null]),
            V::Array(vec![V::Uint(256), V::Bytes(rec_prot), V::Bytes(party_v)]),
        ]));
        let cek = kdf::hkdf32(z.raw_secret_bytes().as_slice(), &ctx);
        let aad = cbor::encode(&V::Array(vec![
            V::Text("Encrypt".into()),
            V::Bytes(cbor::encode(&V::Map(vec![(V::Uint(1), V::Uint(24))]))),
            V::Bytes(b"batman-secrets-v1".to_vec()),
        ]));
        let pt = chacha20poly1305::ChaCha20Poly1305::new(chacha20poly1305::Key::from_slice(&cek))
            .decrypt(chacha20poly1305::Nonce::from_slice(&iv), Payload { msg: &ct, aad: &aad })
            .map_err(|_| "net_secrets does not decrypt at the node")?;
        let plain = cbor::decode(&pt).map_err(|e| format!("{e:?}"))?;
        let sae = plain.get(1).and_then(|x| x.as_text()).ok_or("sae")?.to_string();
        let root = plain.get(2).and_then(|x| x.as_bytes()).ok_or("net_root")?.to_vec();
        self.secrets = Some((sae, root));
        self.netcfg = Some(cfg);
        Ok(())
    }
}

fn input(v: &J, channel: u64) -> Input {
    Input {
        net_name: "home".into(),
        channel,
        node_name: "node-a".into(),
        dac_pub: h(&v["keys"]["dac_pub"]).try_into().unwrap(),
        ecdh_pub: h(&v["keys"]["node_ecdh_pub"]).try_into().unwrap(),
        owner_pub: pub_of(&key(0x11)),
        owner_enc_pub: pub_of(&key(0x22)),
        admin_pub: pub_of(&key(0x66)),
        // 254-app-team-status T-A6(c): an address is offered; version N must not write it
        mesh_addr: Some([0x02, 0x11, 0x22, 0x33, 0x44, 0x55]),
    }
}

/// drives a Join; returns the end and the persisted record
fn drive(node: &mut Node, mut j: Join, mut a: Action) -> (End, Option<NetRecord>) {
    let mut rec = None;
    loop {
        a = match a {
            Action::SignAdmin { tbs } => {
                assert_eq!(tbs[0], 0x84, "a COSE Sig_structure");
                assert!(node.got.is_empty() || rec.is_some(), "admin signatures come before anything is sent");
                let s: p256::ecdsa::Signature = key(0x66).sign(&tbs);
                j.signed(s.to_der().as_bytes()).unwrap()
            }
            Action::SignOwner { input } => {
                assert!(input.starts_with(b"batman-owner-op-v1"));
                let s: p256::ecdsa::Signature = key(0x11).sign(&input);
                j.signed(s.to_der().as_bytes()).unwrap()
            }
            Action::PersistNet(r) => {
                assert!(node.got.is_empty(), "nothing sent before the net record is on disk");
                rec = Some(r);
                j.net_persisted().unwrap()
            }
            Action::Write(f) => {
                let back = node.on(&f);
                let mut next = None;
                for x in &back {
                    next = j.on_frame(x).or(next);
                }
                next.expect("an action after the node's reply")
            }
            Action::Done(e) => return (e, rec),
        };
    }
}

#[test]
fn first_network_is_accepted_by_the_node() {
    let v = vectors();
    let (c, mut n) = pair(&v);
    let (j, a) = Join::start(c, input(&v, 40));
    let (e, rec) = drive(&mut n, j, a);
    assert_eq!(e, End::Replied(JoinReply::Applied));
    assert_eq!(n.got, ["op/nonce", "network/join"]);
    let rec = rec.unwrap();
    // what the node decrypted is what the app stored
    assert_eq!(n.secrets, Some((rec.sae.clone(), rec.net_root.to_vec())));
    assert_eq!(rec.sae.len(), 24);
    assert!(rec.sae.bytes().all(|b| b.is_ascii_alphanumeric()));
    // net_config v1: {1 net_id, 2: 1, 3: null, 4 name, 5 "US", 6 {mesh_id, 40, 4}, 8 [admin]}
    let cfg = n.netcfg.unwrap();
    assert_eq!(cfg.get(1).and_then(|x| x.as_bytes()), Some(&rec.net_id[..]));
    assert_eq!(cfg.get(2).and_then(|x| x.as_uint()), Some(1));
    assert_eq!(cfg.get(3), Some(&V::Null));
    assert_eq!(cfg.get(5).and_then(|x| x.as_text()), Some("US"));
    let halow = cfg.get(6).unwrap();
    assert_eq!(halow.get(1).and_then(|x| x.as_text()), Some(rec.mesh_id.as_str()));
    assert_eq!(rec.mesh_id, format!("bm-{}", hex::encode(&rec.net_id[..6])));
    assert_eq!(halow.get(2).and_then(|x| x.as_uint()), Some(40));
    assert_eq!(halow.get(3).and_then(|x| x.as_uint()), Some(4), "bw follows the channel: ch 40 = 4 MHz");
}

#[test]
fn every_network_draws_its_own_values() {
    let v = vectors();
    let mut seen = vec![];
    for _ in 0..2 {
        let (c, mut n) = pair(&v);
        let (j, a) = Join::start(c, input(&v, 42));
        let (_, rec) = drive(&mut n, j, a);
        let rec = rec.unwrap();
        assert_eq!(rec.bw, 2);
        seen.push(rec);
    }
    assert_ne!(seen[0].net_id, seen[1].net_id);
    assert_ne!(seen[0].sae, seen[1].sae);
    assert_ne!(seen[0].net_root, seen[1].net_root);
}

#[test]
fn a_channel_outside_the_table_is_refused_before_anything() {
    let v = vectors();
    let (c, _n) = pair(&v);
    let (_, a) = Join::start(c, input(&v, 41));
    assert_eq!(a, Action::Done(End::BadChannel));
}

#[test]
fn resend_uses_the_same_record() {
    let v = vectors();
    let (c, mut n) = pair(&v);
    n.join_code = Some(11);
    let (j, a) = Join::start(c, input(&v, 40));
    let (e, rec) = drive(&mut n, j, a);
    assert_eq!(e, End::Replied(JoinReply::ReadInfo));
    let rec = rec.unwrap();
    let first = n.secrets.clone();
    // same net_id, same signed objects, a new op/nonce and owner-op
    let (c2, mut n2) = pair(&v);
    let (j2, a2) = Join::resend(c2, rec.clone());
    let (e2, again) = drive(&mut n2, j2, a2);
    assert_eq!(e2, End::Replied(JoinReply::Applied));
    assert!(again.is_none(), "nothing new to persist");
    assert_eq!(n2.got, ["op/nonce", "network/join"]);
    assert_eq!(n2.secrets, first);
    assert_eq!(n2.netcfg.unwrap().get(1).and_then(|x| x.as_bytes()), Some(&rec.net_id[..]));
}

#[test]
fn join_and_nonce_codes() {
    let v = vectors();
    for (code, want) in [(4, JoinReply::Rejected), (3, JoinReply::NewNonce), (5, JoinReply::ReadInfo), (10, JoinReply::ReadInfo)] {
        let (c, mut n) = pair(&v);
        n.join_code = Some(code);
        let (j, a) = Join::start(c, input(&v, 40));
        assert_eq!(drive(&mut n, j, a).0, End::Replied(want), "join code {code}");
    }
    let (c, mut n) = pair(&v);
    n.nonce_code = Some(7);
    let (j, a) = Join::start(c, input(&v, 40));
    let (e, rec) = drive(&mut n, j, a);
    assert!(matches!(e, End::NonceRefused(Outcome::Err { code: 7, .. })));
    assert!(rec.is_some(), "the record was persisted before op/nonce");
}

#[test]
fn join_body_matches_the_vector() {
    let v = vectors();
    let req = cbor::decode(&h(&v["owner_op"]["request_network_join"])).unwrap();
    let V::Map(e) = req.get(3).unwrap() else { panic!() };
    let want = V::Map(e.iter().filter(|(k, _)| *k != V::Uint(31)).cloned().collect());
    let get = |k: u64| cbor::encode(want.get(k).unwrap());
    let got = joinflow::join_body(&get(1), &get(2), &get(3)).unwrap();
    assert_eq!(cbor::encode(&got), cbor::encode(&want));
    // and the vector's objects are the cose vectors' Sign1s, so the body is built from what joinflow signs
    assert_eq!(get(1), h(&v["cose"]["net_config"]["sign1"]));
    assert_eq!(get(2), h(&v["cose"]["member_list"]["sign1"]));
    assert_eq!(get(3), h(&v["cose"]["net_secrets"]["sign1"]));
}

#[test]
fn sae_is_uniform_over_62_characters() {
    // 2000 passwords = 48000 characters; without the rejection step b % 62 over 0..=255 makes the first 8 characters
    // 25 % more likely (5/256 vs 4/256): their mean count would be ~937 against ~750 for the rest
    let mut count = [0u32; 128];
    for _ in 0..2000 {
        let s = joinflow::sae().unwrap();
        assert_eq!(s.len(), 24);
        for b in s.bytes() {
            assert!(b.is_ascii_alphanumeric());
            count[b as usize] += 1;
        }
    }
    let first: f64 = b"ABCDEFGH".iter().map(|&c| count[c as usize] as f64).sum::<f64>() / 8.0;
    let rest: Vec<u8> = (b'I'..=b'Z').chain(b'a'..=b'z').chain(b'0'..=b'9').collect();
    let others: f64 = rest.iter().map(|&c| count[c as usize] as f64).sum::<f64>() / rest.len() as f64;
    assert!((first / others - 1.0).abs() < 0.10, "first-8 mean {first:.0} vs others {others:.0}");
    assert!(rest.iter().all(|&c| count[c as usize] > 0));
}

/// 254-app-team-status T-A6(c): the session offers this node's mesh address (input key mesh_addr), but version N
/// signs members v1 WITHOUT key 7 (teamview::WRITE_MESH_ADDR = false). Negative control: the constant flipped -> FAIL.
#[test]
fn t_a6c_version_n_writes_no_mesh_address() {
    let v = vectors();
    let (c, mut n) = pair(&v);
    let inp = input(&v, 40);
    assert!(inp.mesh_addr.is_some(), "the test must offer an address");
    let (j, a) = Join::start(c, inp);
    let (e, rec) = drive(&mut n, j, a);
    assert_eq!(e, End::Replied(JoinReply::Applied));
    let p = batman_proto::netrec::sign1_payload(&rec.unwrap().members).unwrap();
    let Some(V::Array(list)) = p.get(4) else { panic!("no members") };
    assert!(list.iter().all(|m| m.get(7).is_none()), "version N wrote key 7: {list:?}");
}
