//! loginflow: owner login against a fake claimed dev node: NXpsk0 with psk_owner, the pinned DAC, and auth/owner
//! checked as provd does (owner_key_id match + ES256 over "batman-owner-auth-v1" ‖ h ‖ kid; failure -> 3).

use batman_proto::cbor::{self, Value as V};
use batman_proto::envelope::Outcome;
use batman_proto::loginflow::{Action, End, Login, NodeRecord};
use batman_proto::{frame, kdf, nodecert, noise, sig};
use p256::ecdsa::signature::Signer;
use serde_json::Value as J;
use std::path::PathBuf;

const FL: usize = 244;
const DEV_NODE_PRIV: &str = "1018ee07c7a494aa6b01e3afc3da234d5f664656dddcbd5f1022c0686f571769";
const OWNER_SIGN_PRIV: [u8; 32] = [0x11; 32];
const TAG: [u8; 32] = [0x5c; 32];

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
fn owner_pub_of(k: &p256::ecdsa::SigningKey) -> [u8; 65] {
    k.verifying_key().to_sec1_point(false).as_bytes().try_into().unwrap()
}
fn owner() -> p256::ecdsa::SigningKey {
    p256::ecdsa::SigningKey::from_slice(&OWNER_SIGN_PRIV).unwrap()
}
fn did(v: &J) -> String {
    v["identity_file"]["device_id"].as_str().unwrap().into()
}

fn dev_node_cert(v: &J) -> Vec<u8> {
    let sk = p256::ecdsa::SigningKey::from_slice(&hex::decode(DEV_NODE_PRIV).unwrap()).unwrap();
    let s_node = h(&v["keys"]["s_node_pub"]);
    let boot_id = vec![7u8; 16];
    let ecdh_pub = h(&v["keys"]["node_ecdh_pub"]);
    let mut msg = nodecert::LABEL_STATIC.to_vec();
    msg.extend(&s_node);
    msg.extend(&boot_id);
    let sig_static: p256::ecdsa::Signature = sk.sign(&msg);
    let mut msg = nodecert::LABEL_ECDH.to_vec();
    msg.extend(&ecdh_pub);
    let sig_ecdh: p256::ecdsa::Signature = sk.sign(&msg);
    cbor::encode(&m(vec![
        (1, V::Array(vec![V::Bytes(h(&v["identity_file"]["dev_cert_der"]))])),
        (2, V::Bytes(s_node)),
        (3, V::Bytes(boot_id)),
        (4, V::Bytes(ecdh_pub)),
        (5, V::Bytes(sig_static.to_bytes().to_vec())),
        (6, V::Bytes(sig_ecdh.to_bytes().to_vec())),
        (7, V::Bytes(h(&v["identity_file"]["sn"]))),
    ]))
}

struct Node {
    v: J,
    hs: Option<snow::HandshakeState>,
    t: Option<snow::TransportState>,
    hh: [u8; 32],
    rx: frame::Reassembler,
    owner: bool,
    got: Vec<String>,
}

impl Node {
    fn new(v: J) -> Node {
        let psk = kdf::psk_owner(&TAG, &did(&v));
        let hs = snow::Builder::new("Noise_NXpsk0_25519_ChaChaPoly_SHA256".parse().unwrap())
            .prologue(&noise::prologue(noise::Mode::NxPsk0, None))
            .unwrap()
            .local_private_key(&h(&v["keys"]["s_node_priv"]))
            .unwrap()
            .psk(0, &psk)
            .unwrap()
            .build_responder()
            .unwrap();
        Node { v, hs: Some(hs), t: None, hh: [0; 32], rx: frame::Reassembler::new(FL, 8192), owner: false, got: vec![] }
    }

    fn on(&mut self, frames: &[Vec<u8>]) -> Vec<Vec<u8>> {
        let mut msg = None;
        for f in frames {
            msg = self.rx.push(f).unwrap();
        }
        let Some(msg) = msg else { return vec![] };
        let mut buf = vec![0u8; 65535];
        if let Some(mut hs) = self.hs.take() {
            self.got.push("msg1".into());
            if hs.read_message(&msg, &mut buf).is_err() {
                return frame::split(&[0x42u8; 600], FL).unwrap(); // the fake msg2
            }
            let n = hs.write_message(&dev_node_cert(&self.v), &mut buf).unwrap();
            self.hh = hs.get_handshake_hash().try_into().unwrap();
            self.t = Some(hs.into_transport_mode().unwrap());
            return frame::split(&buf[..n], FL).unwrap();
        }
        let t = self.t.as_mut().unwrap();
        let n = t.read_message(&msg, &mut buf).unwrap();
        let req = cbor::decode(&buf[..n]).unwrap();
        let id = req.get(1).and_then(|x| x.as_uint()).unwrap();
        let verb = req.get(2).and_then(|x| x.as_text()).unwrap().to_string();
        let body = req.get(3).unwrap().clone();
        self.got.push(verb.clone());
        let err = |c: u64| m(vec![(1, V::Uint(id)), (4, V::Uint(c)), (5, m(vec![]))]);
        let ok = |b: V| m(vec![(1, V::Uint(id)), (3, b), (4, V::Uint(0))]);
        let reply = match verb.as_str() {
            "auth/owner" => {
                let kid = body.get(1).and_then(|x| x.as_bytes()).unwrap().to_vec();
                let s = body.get(2).and_then(|x| x.as_bytes()).unwrap().to_vec();
                let stored = owner_pub_of(&owner());
                let mut input = b"batman-owner-auth-v1".to_vec();
                input.extend(self.hh);
                input.extend(&kid);
                use p256::ecdsa::signature::Verifier;
                let good = kid == sig::owner_key_id(&stored)
                    && s.len() == 64
                    && sig::is_low_s(&s.clone().try_into().unwrap())
                    && p256::ecdsa::VerifyingKey::from_sec1_bytes(&stored)
                        .unwrap()
                        .verify(&input, &p256::ecdsa::Signature::from_slice(&s).unwrap())
                        .is_ok();
                if good {
                    self.owner = true;
                    ok(m(vec![]))
                } else {
                    err(3)
                }
            }
            // info: 9 / 10 / 11 only for an owner session
            "info" if self.owner => ok(m(vec![(7, V::Uint(1)), (11, V::Bool(false))])),
            "info" => ok(m(vec![(7, V::Uint(1))])),
            _ => err(2),
        };
        let t = self.t.as_mut().unwrap();
        let n = t.write_message(&cbor::encode(&reply), &mut buf).unwrap();
        frame::split(&buf[..n], FL).unwrap()
    }
}

fn high_s_der(s: &p256::ecdsa::Signature) -> Vec<u8> {
    let n = hex::decode("ffffffff00000000ffffffffffffffffbce6faada7179e84f3b9cac2fc632551").unwrap();
    let s = s.normalize_s();
    let b = s.to_bytes();
    let (r, lo) = (b[..32].to_vec(), &b[32..]);
    let mut hi = [0u8; 32];
    let mut borrow = 0i16;
    for i in (0..32).rev() {
        let d = n[i] as i16 - lo[i] as i16 - borrow;
        hi[i] = d.rem_euclid(256) as u8;
        borrow = if d < 0 { 1 } else { 0 };
    }
    let int = |x: &[u8]| {
        let mut x = x.to_vec();
        while x.len() > 1 && x[0] == 0 && x[1] < 0x80 {
            x.remove(0);
        }
        if x[0] >= 0x80 {
            x.insert(0, 0);
        }
        let mut o = vec![0x02, x.len() as u8];
        o.extend(x);
        o
    };
    let mut body = int(&r);
    body.extend(int(&hi));
    let mut o = vec![0x30, body.len() as u8];
    o.extend(body);
    o
}

/// drives the login; on success sends one info over the handed-back connection
fn run(node: &mut Node, tag: [u8; 32], pinned: Vec<u8>, sign: p256::ecdsa::SigningKey, high_s: bool) -> (End, Option<Outcome>) {
    let v = node.v.clone();
    let d = did(&v);
    let op = owner_pub_of(&owner());
    let rec = NodeRecord { device_id: &d, owner_tag_key: &tag, pinned_dac_der: &pinned, owner_pub: &op };
    let (mut l, mut a) = Login::start(&rec, FL);
    let end = loop {
        a = match a {
            Action::Sign { input } => {
                assert!(input.starts_with(b"batman-owner-auth-v1"));
                let s: p256::ecdsa::Signature = sign.sign(&input);
                let der = if high_s { high_s_der(&s) } else { s.to_der().as_bytes().to_vec() };
                l.signed(&der).unwrap()
            }
            Action::Write(frames) => {
                let back = node.on(&frames);
                let mut next = None;
                for f in &back {
                    next = l.on_frame(f).or(next);
                }
                next.expect("an action after the node's reply")
            }
            Action::Done(e) => break e,
        };
    };
    if end != End::LoggedIn {
        assert!(l.into_conn().is_none());
        return (end, None);
    }
    let mut c = l.into_conn().expect("the owner session");
    let (_, f) = c.request("info", m(vec![])).unwrap();
    let back = node.on(&f);
    let mut out = None;
    for x in &back {
        out = c.on_frame(x).unwrap().or(out);
    }
    (end, out)
}

#[test]
fn login_then_info_as_owner() {
    let v = vectors();
    let mut n = Node::new(v.clone());
    let (e, info) = run(&mut n, TAG, h(&v["identity_file"]["dev_cert_der"]), owner(), false);
    assert_eq!(e, End::LoggedIn);
    assert_eq!(n.got, ["msg1", "auth/owner", "info"]);
    // the owner-only key 11 is there: the session really is an owner session
    match info {
        Some(Outcome::Ok(b)) => assert_eq!(b.get(11), Some(&V::Bool(false))),
        o => panic!("{o:?}"),
    }
}

#[test]
fn high_s_from_the_keystore_is_normalised() {
    let v = vectors();
    let mut n = Node::new(v.clone());
    assert_eq!(run(&mut n, TAG, h(&v["identity_file"]["dev_cert_der"]), owner(), true).0, End::LoggedIn);
}

#[test]
fn another_owner_tag_key_does_not_decrypt() {
    let v = vectors();
    let mut n = Node::new(v.clone());
    assert_eq!(run(&mut n, [0x5d; 32], h(&v["identity_file"]["dev_cert_der"]), owner(), false).0, End::Msg2Undecryptable);
    assert_eq!(n.got, ["msg1"]);
}

#[test]
fn another_dac_is_refused_before_signing() {
    let v = vectors();
    let mut n = Node::new(v.clone());
    let (e, _) = run(&mut n, TAG, h(&v["keys"]["dac_cert_der"]), owner(), false);
    assert_eq!(e, End::CertRejected(nodecert::Error::NotPinned));
    assert_eq!(n.got, ["msg1"], "no auth/owner to a node whose DAC is not pinned");
}

#[test]
fn another_owner_key_is_refused() {
    let v = vectors();
    let mut n = Node::new(v.clone());
    let other = p256::ecdsa::SigningKey::from_slice(&[0x44; 32]).unwrap();
    let (e, _) = run(&mut n, TAG, h(&v["identity_file"]["dev_cert_der"]), other, false);
    assert!(matches!(e, End::AuthRefused(Outcome::Err { code: 3, .. })));
}
