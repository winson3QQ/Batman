//! replayflow: a whole recovery attempt against a fake CLAIMED dev node that checks it as provd / the helper do:
//! NXpsk0 with psk_replay from its own ECDH side, the stored owner_pub on claim/begin, a single-use nonce_helper, the
//! CheckMac response over this session, and the owner-op ES256 signature (low-s) over the input we built.

use batman_proto::cbor::{self, Value as V};
use batman_proto::claimflow::Pending;
use batman_proto::envelope::Outcome;
use batman_proto::flow::ClaimReplay;
use batman_proto::replayflow::{Action, End, Replay};
use batman_proto::{claim, frame, kdf, nodecert, noise, sig};
use p256::ecdsa::signature::Signer;
use p256::elliptic_curve::sec1::ToSec1Point;
use serde_json::Value as J;
use std::path::PathBuf;

const FL: usize = 244;
const DEV_NODE_PRIV: &str = "1018ee07c7a494aa6b01e3afc3da234d5f664656dddcbd5f1022c0686f571769";
const NODE_ECDH_PRIV: &str = "5fc9a2c8dc0c10edeec4d50654765f2d4aee146880e072d036f584e55bbf3764";
const OWNER_SIGN_PRIV: [u8; 32] = [0x11; 32];
const OWNER_ENC_PRIV: [u8; 32] = [0x22; 32];

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
fn pub65(sk: &p256::SecretKey) -> [u8; 65] {
    sk.public_key().to_sec1_point(false).as_bytes().try_into().unwrap()
}
fn owner_sign() -> p256::ecdsa::SigningKey {
    p256::ecdsa::SigningKey::from_slice(&OWNER_SIGN_PRIV).unwrap()
}
fn owner_sign_pub() -> [u8; 65] {
    owner_sign().verifying_key().to_sec1_point(false).as_bytes().try_into().unwrap()
}
fn ecdh_x(priv32: &[u8], peer: &[u8]) -> [u8; 32] {
    let sk = p256::SecretKey::from_slice(priv32).unwrap();
    let pk = p256::PublicKey::from_sec1_bytes(peer).unwrap();
    p256::ecdh::diffie_hellman(sk.to_nonzero_scalar(), pk.as_affine()).raw_secret_bytes().as_slice().try_into().unwrap()
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
    nonce: Option<[u8; 32]>,
    helper: Option<[u8; 32]>,
    replay_code: Option<u64>,
    op_nonce_code: Option<u64>,
    got: Vec<String>,
}

impl Node {
    fn new(v: J) -> Node {
        // the node's psk_replay: ECDH(node ecdh priv, the stored owner_enc_pub)
        let owner_enc_pub = pub65(&p256::SecretKey::from_slice(&OWNER_ENC_PRIV).unwrap());
        let z = ecdh_x(&hex::decode(NODE_ECDH_PRIV).unwrap(), &owner_enc_pub);
        let did = v["identity_file"]["device_id"].as_str().unwrap().to_string();
        let psk = kdf::psk_replay(&z, &did);
        let hs = snow::Builder::new("Noise_NXpsk0_25519_ChaChaPoly_SHA256".parse().unwrap())
            .prologue(&noise::prologue(noise::Mode::NxPsk0, None))
            .unwrap()
            .local_private_key(&h(&v["keys"]["s_node_priv"]))
            .unwrap()
            .psk(0, &psk)
            .unwrap()
            .build_responder()
            .unwrap();
        Node { v, hs: Some(hs), t: None, hh: [0; 32], rx: frame::Reassembler::new(FL, 8192), nonce: None, helper: None, replay_code: None, op_nonce_code: None, got: vec![] }
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
                // provd answers a mismatched msg1 with an equal-length fake msg2
                return frame::split(&vec![0x42u8; 48 + 32 + 16 + dev_node_cert(&self.v).len() + 16], FL).unwrap();
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
            "claim/begin" => {
                assert_eq!(body.get(1).and_then(|x| x.as_bytes()).unwrap(), owner_sign_pub(), "begin carries the owner_pub");
                self.nonce = Some([0x4e; 32]);
                ok(m(vec![(1, V::Bytes(vec![0x4e; 32]))]))
            }
            "op/nonce" => match self.op_nonce_code {
                Some(c) => err(c),
                None => {
                    self.helper = Some([0x6d; 32]);
                    ok(m(vec![(1, V::Bytes(vec![0x6d; 32]))]))
                }
            },
            "claim/replay" => self.replay(&body, err, ok),
            _ => err(2),
        };
        let t = self.t.as_mut().unwrap();
        let n = t.write_message(&cbor::encode(&reply), &mut buf).unwrap();
        frame::split(&buf[..n], FL).unwrap()
    }

    fn replay(&mut self, body: &V, err: impl Fn(u64) -> V, ok: impl Fn(V) -> V) -> V {
        if let Some(c) = self.replay_code {
            return err(c);
        }
        // the helper: CheckMac with this session's nonce and h and the stored owner_pub; the owner-op signature
        let (Some(nonce), Some(helper)) = (self.nonce, self.helper.take()) else { return err(3) };
        let k: [u8; 32] = h(&self.v["keys"]["claim_secret"]).try_into().unwrap();
        let sn: [u8; 9] = h(&self.v["identity_file"]["sn"]).try_into().unwrap();
        let want = claim::response(&k, &nonce, &self.hh, &h(&self.v["identity_file"]["dev_cert_der"]), &owner_sign_pub(), &sn);
        if body.get(1).and_then(|x| x.as_bytes()) != Some(&want[..]) {
            return err(3);
        }
        let op = body.get(31).unwrap();
        assert_eq!(op.get(1).and_then(|x| x.as_text()), Some("claim/replay"));
        let s: [u8; 64] = op.get(2).and_then(|x| x.as_bytes()).unwrap().try_into().unwrap();
        if !sig::is_low_s(&s) {
            return err(3);
        }
        let wo = m(vec![(1, V::Bytes(want.to_vec()))]);
        let input = sig::owner_op_input(&self.hh, &helper, "claim/replay", &wo).unwrap();
        use p256::ecdsa::signature::Verifier;
        let vk = p256::ecdsa::VerifyingKey::from_sec1_bytes(&owner_sign_pub()).unwrap();
        let sg = p256::ecdsa::Signature::from_slice(&s).unwrap();
        if vk.verify(&input, &sg).is_err() {
            return err(3);
        }
        ok(m(vec![(1, V::Bytes(vec![1; 32])), (2, V::Bytes(vec![2; 32])), (3, V::Text("new-pw".into()))]))
    }
}

fn pending(v: &J) -> Pending {
    Pending {
        device_id: v["identity_file"]["device_id"].as_str().unwrap().into(),
        k: h(&v["keys"]["claim_secret"]).try_into().unwrap(),
        node_cert: dev_node_cert(v),
        dac_der: h(&v["identity_file"]["dev_cert_der"]),
        ecdh_pub: h(&v["keys"]["node_ecdh_pub"]).try_into().unwrap(),
        owner_pub: owner_sign_pub(),
        owner_enc_pub: pub65(&p256::SecretKey::from_slice(&OWNER_ENC_PRIV).unwrap()),
    }
}

/// the platform: ECDH with `enc_priv`, signing with `sign` (DER, optionally turned high-s to check normalisation)
struct Platform {
    enc_priv: [u8; 32],
    sign: p256::ecdsa::SigningKey,
    high_s: bool,
    signed: Vec<Vec<u8>>,
}

fn high_s_der(s: &p256::ecdsa::Signature) -> Vec<u8> {
    let n = hex::decode("ffffffff00000000ffffffffffffffffbce6faada7179e84f3b9cac2fc632551").unwrap();
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

fn run(node: &mut Node, p: Pending, plat: &mut Platform) -> End {
    let (mut r, mut a) = Replay::start(p.clone(), FL);
    loop {
        a = match a {
            Action::Ecdh { peer } => {
                assert_eq!(peer, p.ecdh_pub, "ECDH only with the sig_ecdh-verified key from the pending");
                r.ecdh_done(ecdh_x(&plat.enc_priv, &peer)).unwrap()
            }
            Action::Sign { input } => {
                assert!(input.starts_with(b"batman-owner-op-v1"), "the owner key signs only allow-listed prefixes");
                plat.signed.push(input.clone());
                let s: p256::ecdsa::Signature = plat.sign.sign(&input);
                let der = if plat.high_s { high_s_der(&s) } else { s.to_der().as_bytes().to_vec() };
                r.signed(&der).unwrap()
            }
            Action::Write(frames) => {
                let back = node.on(&frames);
                let mut next = None;
                for f in &back {
                    if let Some(x) = r.on_frame(f) {
                        next = Some(x);
                    }
                }
                next.expect("an action after the node's reply")
            }
            Action::Done(e) => return e,
        };
    }
}

fn platform() -> Platform {
    Platform { enc_priv: OWNER_ENC_PRIV, sign: owner_sign(), high_s: false, signed: vec![] }
}

#[test]
fn replay_recovers_and_the_node_accepts_checkmac_and_owner_op() {
    let v = vectors();
    let mut n = Node::new(v.clone());
    let mut plat = platform();
    let e = run(&mut n, pending(&v), &mut plat);
    match e {
        End::Replayed(ClaimReplay::Recovered(c)) => assert_eq!(c.root_password, "new-pw"),
        e => panic!("{e:?}"),
    }
    assert_eq!(n.got, ["msg1", "claim/begin", "op/nonce", "claim/replay"]);
    assert_eq!(plat.signed.len(), 1, "one owner signature per attempt");
}

#[test]
fn keystore_high_s_is_normalised_before_sending() {
    let v = vectors();
    let mut n = Node::new(v.clone());
    let mut plat = platform();
    plat.high_s = true;
    assert!(matches!(run(&mut n, pending(&v), &mut plat), End::Replayed(ClaimReplay::Recovered(_))));
}

#[test]
fn wrong_owner_enc_key_means_msg2_does_not_decrypt() {
    let v = vectors();
    let mut n = Node::new(v.clone());
    let mut plat = platform();
    plat.enc_priv = [0x33; 32];
    assert_eq!(run(&mut n, pending(&v), &mut plat), End::Msg2Undecryptable);
    assert_eq!(n.got, ["msg1"]);
}

#[test]
fn another_dac_than_the_pending_is_refused() {
    let v = vectors();
    let mut n = Node::new(v.clone());
    let mut p = pending(&v);
    p.dac_der = h(&v["keys"]["dac_cert_der"]);
    let (mut r, a) = Replay::start(p, FL);
    let Action::Ecdh { peer } = a else { panic!() };
    let Some(Action::Write(f)) = r.ecdh_done(ecdh_x(&OWNER_ENC_PRIV, &peer)) else { panic!() };
    let back = n.on(&f);
    let mut out = None;
    for x in &back {
        out = r.on_frame(x).or(out);
    }
    assert_eq!(out, Some(Action::Done(End::CertRejected(nodecert::Error::NotPinned))));
    assert_eq!(n.got, ["msg1"], "nothing sent to a node whose DAC is not the pending's");
}

#[test]
fn wrong_owner_signing_key_is_refused_by_the_node() {
    let v = vectors();
    let mut n = Node::new(v.clone());
    let mut plat = platform();
    plat.sign = p256::ecdsa::SigningKey::from_slice(&[0x44; 32]).unwrap();
    assert_eq!(run(&mut n, pending(&v), &mut plat), End::Replayed(ClaimReplay::Refused));
}

#[test]
fn replay_codes_and_refused_steps() {
    let v = vectors();
    for (code, want) in [(13, ClaimReplay::Reconnect), (12, ClaimReplay::RateLimited), (7, ClaimReplay::Unknown)] {
        let mut n = Node::new(v.clone());
        n.replay_code = Some(code);
        assert_eq!(run(&mut n, pending(&v), &mut platform()), End::Replayed(want), "replay code {code}");
    }
    let mut n = Node::new(v.clone());
    n.op_nonce_code = Some(7);
    let e = run(&mut n, pending(&v), &mut platform());
    assert!(matches!(e, End::Refused { verb: "op/nonce", outcome: Outcome::Err { code: 7, .. } }));
    assert_eq!(n.got, ["msg1", "claim/begin", "op/nonce"]);
}
