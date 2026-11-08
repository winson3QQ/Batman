//! claimflow: a whole claim attempt against a fake dev node (snow NX responder with the vector node static key, a
//! node_cert signed by the dev DAC fixture) that checks claim/begin and the CheckMac response as the node does.

#![cfg_attr(not(feature = "dev-trust"), allow(unused_imports, dead_code))]
use batman_proto::cbor::{self, Value as V};
use batman_proto::claimflow::{Action, Claim, End, Input};
use batman_proto::envelope::Outcome;
use batman_proto::flow::ClaimFinish;
use batman_proto::{claim, frame, nodecert, noise};
use serde_json::Value as J;
use std::path::PathBuf;

const FL: usize = 244;
const DEV_NODE_PRIV: &str = "1018ee07c7a494aa6b01e3afc3da234d5f664656dddcbd5f1022c0686f571769";

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

/// node_cert as a P2 bench node sends it (file keystore, self-signed dev: DAC)
fn dev_node_cert(v: &J) -> Vec<u8> {
    use p256::ecdsa::signature::Signer;
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

#[derive(Clone, Copy, PartialEq)]
enum Finish {
    /// check the CheckMac response like the node: right -> creds, wrong -> 9
    Check,
    Code(u64),
}

struct Node {
    v: J,
    hs: Option<snow::HandshakeState>,
    t: Option<snow::TransportState>,
    hh: [u8; 32],
    rx: frame::Reassembler,
    nonce: [u8; 32],
    begin_code: Option<u64>,
    finish: Finish,
    k: [u8; 32],
    owner_pub: Vec<u8>,
    got: Vec<String>,
}

impl Node {
    fn new(v: J, device_id: &str) -> Node {
        let pro = noise::prologue(noise::Mode::Nx, Some(device_id));
        let hs = snow::Builder::new("Noise_NX_25519_ChaChaPoly_SHA256".parse().unwrap())
            .prologue(&pro)
            .unwrap()
            .local_private_key(&h(&v["keys"]["s_node_priv"]))
            .unwrap()
            .build_responder()
            .unwrap();
        let k: [u8; 32] = h(&v["keys"]["claim_secret"]).try_into().unwrap();
        Node { v, hs: Some(hs), t: None, hh: [0; 32], rx: frame::Reassembler::new(FL, 8192), nonce: [0x4e; 32], begin_code: None, finish: Finish::Check, k, owner_pub: vec![], got: vec![] }
    }

    /// frames in -> frames out (empty when the message is not complete)
    fn on(&mut self, frames: &[Vec<u8>]) -> Vec<Vec<u8>> {
        let mut msg = None;
        for f in frames {
            msg = self.rx.push(f).unwrap();
        }
        let Some(msg) = msg else { return vec![] };
        let mut buf = vec![0u8; 65535];
        if let Some(mut hs) = self.hs.take() {
            hs.read_message(&msg, &mut buf).unwrap();
            let n = hs.write_message(&dev_node_cert(&self.v), &mut buf).unwrap();
            let out = frame::split(&buf[..n], FL).unwrap();
            self.hh = hs.get_handshake_hash().try_into().unwrap();
            self.t = Some(hs.into_transport_mode().unwrap());
            self.got.push("msg1".into());
            return out;
        }
        let t = self.t.as_mut().unwrap();
        let n = t.read_message(&msg, &mut buf).unwrap();
        let req = cbor::decode(&buf[..n]).unwrap();
        let id = req.get(1).and_then(|x| x.as_uint()).unwrap();
        let verb = req.get(2).and_then(|x| x.as_text()).unwrap().to_string();
        let body = req.get(3).unwrap().clone();
        self.got.push(verb.clone());
        let err = |c: u64| m(vec![(1, V::Uint(id)), (4, V::Uint(c)), (5, m(vec![]))]);
        let reply = match verb.as_str() {
            "claim/begin" => {
                self.owner_pub = body.get(1).and_then(|x| x.as_bytes()).unwrap().to_vec();
                assert_eq!(self.owner_pub.len(), 65);
                match self.begin_code {
                    Some(c) => err(c),
                    None => m(vec![(1, V::Uint(id)), (3, m(vec![(1, V::Bytes(self.nonce.to_vec()))])), (4, V::Uint(0))]),
                }
            }
            "claim/finish" => match self.finish {
                Finish::Code(c) => err(c),
                Finish::Check => {
                    let sn: [u8; 9] = h(&self.v["identity_file"]["sn"]).try_into().unwrap();
                    let want = claim::response(&self.k, &self.nonce, &self.hh, &h(&self.v["identity_file"]["dev_cert_der"]), &self.owner_pub.clone().try_into().unwrap(), &sn);
                    let got = body.get(1).and_then(|x| x.as_bytes()).unwrap();
                    if got == want {
                        m(vec![(1, V::Uint(id)), (3, m(vec![(1, V::Bytes(vec![1; 32])), (2, V::Bytes(vec![2; 32])), (3, V::Text("pw".into()))])), (4, V::Uint(0))])
                    } else {
                        err(9)
                    }
                }
            },
            _ => err(2),
        };
        let t = self.t.as_mut().unwrap();
        let n = t.write_message(&cbor::encode(&reply), &mut buf).unwrap();
        frame::split(&buf[..n], FL).unwrap()
    }
}

fn input(v: &J, device_id: &str, k: [u8; 32]) -> Input {
    Input {
        device_id: device_id.into(),
        k,
        owner_pub: h(&v["keys"]["owner_sign_pub"]).try_into().unwrap(),
        owner_enc_pub: h(&v["keys"]["owner_enc_pub"]).try_into().unwrap(),
        sig_enc: [0x51; 64],
        frame_limit: FL,
    }
}

/// drives the attempt to its end; returns the end, whether PersistPending came, and what the node received
fn run(node: &mut Node, inp: Input, persist: bool) -> (End, bool, Vec<String>) {
    let want_k = inp.k;
    let (mut c, mut a) = Claim::start(inp);
    let mut persisted = false;
    loop {
        a = match a {
            Action::Write(frames) => {
                let back = node.on(&frames);
                let mut next = None;
                for f in &back {
                    if let Some(x) = c.on_frame(f) {
                        next = Some(x);
                    }
                }
                next.expect("an action after the node's reply")
            }
            Action::PersistPending(p) => {
                assert_eq!(node.got.last().map(String::as_str), Some("msg1"), "nothing sent before the pending is on disk");
                assert_eq!(p.k, want_k, "the pending keeps the QR's K");
                assert_eq!(p.ecdh_pub.to_vec(), h(&node.v["keys"]["node_ecdh_pub"]), "the sig_ecdh-verified key");
                persisted = true;
                if !persist {
                    return (End::Broken("not persisted".into()), true, node.got.clone());
                }
                c.pending_persisted().expect("claim/begin after persist")
            }
            Action::Done(e) => return (e, persisted, node.got.clone()),
        };
    }
}

fn did(v: &J) -> String {
    v["identity_file"]["device_id"].as_str().unwrap().to_string()
}
fn k(v: &J) -> [u8; 32] {
    h(&v["keys"]["claim_secret"]).try_into().unwrap()
}

#[cfg(feature = "dev-trust")]
#[test]
fn claim_succeeds_and_the_node_accepts_our_checkmac() {
    let v = vectors();
    let mut n = Node::new(v.clone(), &did(&v));
    let (e, persisted, got) = run(&mut n, input(&v, &did(&v), k(&v)), true);
    assert!(persisted);
    assert_eq!(got, ["msg1", "claim/begin", "claim/finish"]);
    match e {
        End::Finished(ClaimFinish::Claimed(c)) => assert_eq!(c.root_password, "pw"),
        e => panic!("{e:?}"),
    }
    assert_eq!(n.owner_pub, h(&v["keys"]["owner_sign_pub"]));
}

#[cfg(feature = "dev-trust")]
#[test]
fn wrong_k_is_refused_by_the_node_and_means_try_replay() {
    let v = vectors();
    let mut n = Node::new(v.clone(), &did(&v));
    let mut bad = k(&v);
    bad[0] ^= 1;
    let (e, persisted, _) = run(&mut n, input(&v, &did(&v), bad), true);
    assert!(persisted, "the pending is written before finish, whatever comes after");
    assert_eq!(e, End::Finished(ClaimFinish::TryReplay));
}

#[cfg(feature = "dev-trust")]
#[test]
fn nothing_is_sent_until_the_pending_is_persisted() {
    let v = vectors();
    let mut n = Node::new(v.clone(), &did(&v));
    let (_, persisted, got) = run(&mut n, input(&v, &did(&v), k(&v)), false);
    assert!(persisted);
    assert_eq!(got, ["msg1"]);
}

#[cfg(feature = "dev-trust")]
#[test]
fn another_nodes_qr_does_not_decrypt() {
    // the phone binds the QR id in the NX prologue; the node uses its own: msg2 does not decrypt (§5.0 row 2)
    let v = vectors();
    let mut n = Node::new(v.clone(), &did(&v));
    let (e, persisted, _) = run(&mut n, input(&v, "0123a5f0c3e1b74def", k(&v)), true);
    assert_eq!(e, End::Msg2Undecryptable);
    assert!(!persisted);
}

#[cfg(not(feature = "dev-trust"))]
#[test]
fn field_build_refuses_a_dev_node_before_writing_anything() {
    let v = vectors();
    let mut n = Node::new(v.clone(), &did(&v));
    let (e, persisted, got) = run(&mut n, input(&v, &did(&v), k(&v)), true);
    assert_eq!(e, End::CertRejected(nodecert::Error::Untrusted));
    assert!(!persisted);
    assert_eq!(got, ["msg1"]);
}

#[cfg(feature = "dev-trust")]
#[test]
fn begin_refused_and_finish_codes() {
    let v = vectors();
    let mut n = Node::new(v.clone(), &did(&v));
    n.begin_code = Some(7);
    let (e, _, got) = run(&mut n, input(&v, &did(&v), k(&v)), true);
    assert!(matches!(e, End::BeginRefused(Outcome::Err { code: 7, .. })));
    assert_eq!(got, ["msg1", "claim/begin"], "no finish after a refused begin");
    for (code, want) in [(13, ClaimFinish::Committed), (3, ClaimFinish::BeginAgain), (7, ClaimFinish::Unknown)] {
        let mut n = Node::new(v.clone(), &did(&v));
        n.finish = Finish::Code(code);
        let (e, _, _) = run(&mut n, input(&v, &did(&v), k(&v)), true);
        assert_eq!(e, End::Finished(want), "finish code {code}");
    }
}
