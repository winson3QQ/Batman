//! s1 design §8 item 5 ("PR-H1 對手交握"): the Rust core does a LIVE Noise NX / NXpsk0 handshake on the host against
//! another implementation — tests/tools/peer/noise_responder.py (dissononce, the library of verify.py) — with fresh
//! ephemerals on both sides, so nothing here is a byte comparison with vectors.json. Host only: no node, no owner client.
//!
//! The peer gets its key material in argv, which any local process can read: only public test values go there — the
//! node static key published in tests/vectors/219-protocol/vectors.json and a PSK made from a constant of this test.
//!
//! Ignored by default because it needs a Python with tests/vectors/219-protocol/requirements.txt installed:
//!   PEER_PY=~/venv-219/bin/python cargo test --test noise_live -- --ignored
//! Run that way it FAILS when the interpreter or the peer is missing (it never passes without a handshake).

use batman_proto::{kdf, noise};
use std::io::{BufRead, BufReader, Write};
use std::path::PathBuf;
use std::process::{Child, ChildStdin, ChildStdout, Command, Stdio};

const TAG: [u8; 32] = [0x5c; 32];
const PAYLOAD: &[u8] = b"a node_cert would be here; the noise layer hands it over unverified";

fn repo(rel: &str) -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../..").join(rel)
}
fn vectors() -> serde_json::Value {
    serde_json::from_str(&std::fs::read_to_string(repo("tests/vectors/219-protocol/vectors.json")).unwrap()).unwrap()
}
fn did(v: &serde_json::Value) -> String {
    v["identity_file"]["device_id"].as_str().unwrap().into()
}

struct Peer {
    child: Child,
    tx: ChildStdin,
    rx: BufReader<ChildStdout>,
}

impl Peer {
    fn start(mode: &str, prologue: &[u8], psk: Option<&[u8; 32]>, static_priv: &str) -> Peer {
        let py = std::env::var("PEER_PY").expect("PEER_PY = a Python with tests/vectors/219-protocol/requirements.txt");
        let mut child = Command::new(py)
            .arg(repo("tests/tools/peer/noise_responder.py"))
            .args([mode, &hex::encode(prologue), &psk.map(hex::encode).unwrap_or("-".into()), static_priv, &hex::encode(PAYLOAD)])
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .spawn()
            .expect("the peer starts");
        let (tx, rx) = (child.stdin.take().unwrap(), BufReader::new(child.stdout.take().unwrap()));
        Peer { child, tx, rx }
    }
    fn send(&mut self, b: &[u8]) {
        writeln!(self.tx, "{}", hex::encode(b)).unwrap();
        self.tx.flush().unwrap();
    }
    fn line(&mut self) -> String {
        let mut s = String::new();
        self.rx.read_line(&mut s).unwrap();
        assert!(!s.trim().is_empty(), "the peer said nothing (did it start? is dissononce installed for PEER_PY?)");
        s.trim().to_string()
    }
    fn bytes(&mut self) -> Vec<u8> {
        let s = self.line();
        hex::decode(&s).unwrap_or_else(|_| panic!("the peer answered: {s}"))
    }
}

impl Drop for Peer {
    fn drop(&mut self) {
        let _ = self.child.kill();
        let _ = self.child.wait();
    }
}

fn handshake(mode: noise::Mode, device_id: Option<&str>, psk: Option<[u8; 32]>) {
    let v = vectors();
    let name = if mode == noise::Mode::Nx { "nx" } else { "nxpsk0" };
    // the prologue the peer uses is spelled out here (219 §3), not taken from the code under test
    let mut pro = b"batman-prov/1\0ble\0".to_vec();
    if mode == noise::Mode::Nx {
        pro.extend(device_id.unwrap().as_bytes());
    }
    let mut p = Peer::start(name, &pro, psk.as_ref(), v["keys"]["s_node_priv"].as_str().unwrap());
    let mut ini = noise::Initiator::new(mode, device_id, psk.as_ref()).unwrap();
    p.send(&ini.msg1().unwrap());
    let msg2 = p.bytes();
    let (payload, mut s) = ini.read_msg2(&msg2).expect("the msg2 of the peer decrypts");
    assert_eq!(payload, PAYLOAD, "{name}: msg2 payload");
    assert_eq!(s.h.to_vec(), p.bytes(), "{name}: the same handshake hash on both sides");
    assert_eq!(hex::encode(s.rs), v["keys"]["s_node_pub"].as_str().unwrap(), "{name}: the static key of the peer");
    // one message each way over the transport keys
    p.send(&s.encrypt(b"ping from the rust core").unwrap());
    assert_eq!(p.bytes(), b"ping from the rust core", "{name}: the peer decrypts ours");
    let back = p.bytes();
    assert_eq!(s.decrypt(&back).unwrap(), b"pong:ping from the rust core", "{name}: we decrypt the answer");
}

#[test]
#[ignore = "needs PEER_PY (a Python with dissononce); see the file header"]
fn live_nx_handshake_with_the_python_peer() {
    let d = did(&vectors());
    handshake(noise::Mode::Nx, Some(&d), None);
}

#[test]
#[ignore = "needs PEER_PY (a Python with dissononce); see the file header"]
fn live_nxpsk0_handshake_with_the_python_peer() {
    let d = did(&vectors());
    handshake(noise::Mode::NxPsk0, None, Some(kdf::psk_owner(&TAG, &d)));
}

/// the peer holds another PSK / another device id in its prologue: no session on either side
#[test]
#[ignore = "needs PEER_PY (a Python with dissononce); see the file header"]
fn live_handshake_with_another_psk_or_prologue_fails() {
    let v = vectors();
    let (d, sk) = (did(&v), v["keys"]["s_node_priv"].as_str().unwrap().to_string());
    // NXpsk0: msg1 already carries a tag under the PSK -> the peer refuses msg1
    let psk = kdf::psk_owner(&TAG, &d);
    let mut p = Peer::start("nxpsk0", b"batman-prov/1\0ble\0", Some(&kdf::psk_owner(&[0x5d; 32], &d)), &sk);
    let mut ini = noise::Initiator::new(noise::Mode::NxPsk0, None, Some(&psk)).unwrap();
    p.send(&ini.msg1().unwrap());
    assert!(p.line().starts_with("ERR msg1"), "the peer accepted a msg1 made with another PSK");
    // NX: msg1 is only an ephemeral; the prologue difference shows when msg2 does not decrypt
    let mut p = Peer::start("nx", b"batman-prov/1\0ble\0some-other-device", None, &sk);
    let mut ini = noise::Initiator::new(noise::Mode::Nx, Some(&d), None).unwrap();
    p.send(&ini.msg1().unwrap());
    let msg2 = p.bytes();
    assert_eq!(ini.read_msg2(&msg2).err(), Some(noise::Error::Msg2NotDecryptable));
}
