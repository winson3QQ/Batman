//! A fake CLAIMED dev node for claim/replay tests (254-app-replay §10), shared by batman-proto's tests/replayflow.rs
//! and the bridge's api::replay tests (included there with #[path]). One `FakeNode` = provd + the helper, with any
//! number of connections. Each behaviour below names the design fact it models (§0 N1-N16, read from
//! feed/batman-prov/src); the tests that rely on one say so.
//!
//! - N1  claimed: NXpsk0 with the PSK set (psk_replay only while exactly one owner); only a 48-byte msg1 can match.
//!       Unclaimed (or provd's cache still says so, N3): NX, only a 32-byte msg1; anything else gets a FAKE msg2.
//! - N2  the fake msg2 has the real one's length: 32 + 48 + node_cert + 16 (= cert + 96); then the node only waits.
//! - N3  `cached_unclaimed`: provd's cached state lags a committed claim -> psk_replay gets an UNDECRYPTABLE msg2
//!       (never "no msg2"), NX opens, and claim/finish answers 9 (the helper refuses: the node is not Unclaimed).
//! - N4  roles: reacquire = {info, claim/begin, op/nonce, claim/replay}; owner has none of claim/begin, claim/finish,
//!       claim/replay -> 3, not counted, the session stays.
//! - N5  claim/finish: OK makes the session owner; 9 only from the helper.
//! - N6  op/nonce (reacquire): OK, or 3 without a claim/begin or > 55 s after it; never counted.
//! - N7  claim/replay: both nonces are used up whatever the result; ops busy -> 7; OK / 13 -> owner + killOthers; a
//!       helper refusal (3) counts per connection: the third is answered, then the connection closes.
//! - N8  killOthers closes EVERY other session (unauthenticated, other phones, HTTP).
//! - N9  helper: >= 10 counted failures in the last hour -> 12, even for a correct replay; failures live in memory;
//!       owners != 1 / envelope / owner-op / CheckMac -> counted; every success makes a NEW root password; 13 (the
//!       password store failed) is not counted and the password may or may not have changed.
//! - N10 any open connection or a running helper -> the node does not advertise (no new BLE connection).
//! - N12 handshakes: 20 per minute for the whole node; the 21st msg1 gets NO msg2 (the connection is dropped).
//! - N13 the ops channel busy (another job, or a replay still in the helper) -> claim/begin and claim/replay 7 at
//!       once; an A/B trial slot -> claim/replay 7.
//! - N14 12 does not close the session.
//! - N16 6 (no usable record) and 11 (boot verdict unknown) are not counted; 11 from the envelope IS counted — the
//!       response inside the envelope body missing / not 32 bytes included (node.go:642, after the count check).
#![allow(dead_code)]

use batman_proto::cbor::{self, Value as V};
use batman_proto::{claim, frame, kdf, nodecert, noise, sig};
use p256::elliptic_curve::sec1::ToSec1Point;
use serde_json::Value as J;
use std::path::PathBuf;

pub const FL: usize = 244;
pub const DEV_NODE_PRIV: &str = "1018ee07c7a494aa6b01e3afc3da234d5f664656dddcbd5f1022c0686f571769";
pub const NODE_ECDH_PRIV: &str = "5fc9a2c8dc0c10edeec4d50654765f2d4aee146880e072d036f584e55bbf3764";
pub const OWNER_SIGN_PRIV: [u8; 32] = [0x11; 32];
pub const OWNER_ENC_PRIV: [u8; 32] = [0x22; 32];
pub const TAG_KEY: [u8; 32] = [1; 32];
pub const ADV_KEY: [u8; 32] = [2; 32];

pub fn vectors() -> J {
    let p = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../../tests/vectors/219-protocol/vectors.json");
    serde_json::from_str(&std::fs::read_to_string(p).unwrap()).unwrap()
}
pub fn h(v: &J) -> Vec<u8> {
    hex::decode(v.as_str().unwrap()).unwrap()
}
pub fn m(pairs: Vec<(u64, V)>) -> V {
    V::Map(pairs.into_iter().map(|(k, v)| (V::Uint(k), v)).collect())
}
pub fn pub65(sk: &p256::SecretKey) -> [u8; 65] {
    sk.public_key().to_sec1_point(false).as_bytes().try_into().unwrap()
}
pub fn owner_sign() -> p256::ecdsa::SigningKey {
    p256::ecdsa::SigningKey::from_slice(&OWNER_SIGN_PRIV).unwrap()
}
pub fn owner_sign_pub() -> [u8; 65] {
    owner_sign().verifying_key().to_sec1_point(false).as_bytes().try_into().unwrap()
}
pub fn owner_enc_pub() -> [u8; 65] {
    pub65(&p256::SecretKey::from_slice(&OWNER_ENC_PRIV).unwrap())
}
pub fn ecdh_x(priv32: &[u8], peer: &[u8]) -> [u8; 32] {
    let sk = p256::SecretKey::from_slice(priv32).unwrap();
    let pk = p256::PublicKey::from_sec1_bytes(peer).unwrap();
    p256::ecdh::diffie_hellman(sk.to_nonzero_scalar(), pk.as_affine()).raw_secret_bytes().as_slice().try_into().unwrap()
}
pub fn device_id(v: &J) -> String {
    v["identity_file"]["device_id"].as_str().unwrap().to_string()
}

/// node_cert as a P2 bench node sends it (file keystore, self-signed dev: DAC)
pub fn dev_node_cert(v: &J) -> Vec<u8> {
    node_cert_with_static(v, h(&v["keys"]["s_node_pub"]))
}

/// a node_cert whose s_node (key 2, signed by sig_static) is [s_node]: another static than the handshake's = review B-m4 case
pub fn node_cert_with_static(v: &J, s_node: Vec<u8>) -> Vec<u8> {
    use p256::ecdsa::signature::Signer;
    let sk = p256::ecdsa::SigningKey::from_slice(&hex::decode(DEV_NODE_PRIV).unwrap()).unwrap();
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

/// The pending record fields a claim of this node left (claimflow::Pending's order)
pub fn pending(v: &J) -> batman_proto::claimflow::Pending {
    batman_proto::claimflow::Pending {
        device_id: device_id(v),
        k: h(&v["keys"]["claim_secret"]).try_into().unwrap(),
        node_cert: dev_node_cert(v),
        dac_der: h(&v["identity_file"]["dev_cert_der"]),
        ecdh_pub: h(&v["keys"]["node_ecdh_pub"]).try_into().unwrap(),
        owner_pub: owner_sign_pub(),
        owner_enc_pub: owner_enc_pub(),
    }
}

#[derive(Debug, Clone, Copy, PartialEq)]
pub enum SetPassword {
    Ok,
    /// the password store failed -> 13; `changed`: the new password stuck anyway (N9)
    Fails { changed: bool },
}

#[derive(Debug, Clone, Copy, PartialEq)]
enum Role {
    /// before / during the handshake, or after a fake msg2 (no transport ever)
    None,
    /// NX on an (apparently) unclaimed node: claim/begin, claim/finish
    Nx,
    Reacquire,
    Owner,
}

struct Sess {
    /// msg1 seen
    hello: bool,
    t: Option<snow::TransportState>,
    hh: [u8; 32],
    rx: frame::Reassembler,
    role: Role,
    begin: Option<([u8; 32], u64)>,
    begin_owner: Vec<u8>,
    helper_nonce: Option<[u8; 32]>,
    refusals: u32,
}

#[derive(Debug, PartialEq)]
pub enum Reply {
    Frames(Vec<Vec<u8>>),
    /// incomplete message, or a session that only waits (after a fake msg2)
    Nothing,
    /// the node dropped the connection without an answer
    Closed,
    /// claim/replay handed to the helper (`defer_helper`): the answer comes with `finish_helper`
    Pending,
}

struct Deferred {
    conn: usize,
    id: u64,
    body: V,
    hh: [u8; 32],
    nonce: Option<[u8; 32]>,
    helper_nonce: Option<[u8; 32]>,
    owner_pub: Vec<u8>,
}

pub struct FakeNode {
    pub v: J,
    pub claimed: bool,
    pub owners: usize,
    pub cached_unclaimed: bool,
    pub ops_busy: bool,
    pub trial_slot: bool,
    pub no_record: bool,
    pub verdict_unknown: bool,
    pub set_password: SetPassword,
    pub defer_helper: bool,
    /// the node_cert names another static key than the one in the handshake (sig_static valid over it)
    pub cert_wrong_static: bool,
    /// seconds, driven by the test
    pub now: u64,
    pub password: String,
    pub generation: u32,
    fails: Vec<u64>,
    hs_times: Vec<u64>,
    sessions: Vec<Option<Sess>>,
    deferred: Option<Deferred>,
    /// what reached the node: "c<conn> msg1", "c<conn> claim/begin", ...; "c<conn> fake-msg2"
    pub log: Vec<String>,
    ctr: u8,
}

impl FakeNode {
    /// A node claimed by OWNER_SIGN / OWNER_ENC with password "pw-0".
    pub fn claimed(v: J) -> FakeNode {
        FakeNode {
            v,
            claimed: true,
            owners: 1,
            cached_unclaimed: false,
            ops_busy: false,
            trial_slot: false,
            no_record: false,
            verdict_unknown: false,
            set_password: SetPassword::Ok,
            defer_helper: false,
            cert_wrong_static: false,
            now: 0,
            password: "pw-0".into(),
            generation: 0,
            fails: vec![],
            hs_times: vec![],
            sessions: vec![],
            deferred: None,
            log: vec![],
            ctr: 0x40,
        }
    }

    /// An unclaimed node (NX only).
    pub fn unclaimed(v: J) -> FakeNode {
        FakeNode { claimed: false, owners: 0, password: String::new(), ..FakeNode::claimed(v) }
    }

    /// provd's next poll: the cached state catches up with the store (N3)
    pub fn refresh(&mut self) {
        self.cached_unclaimed = false;
    }

    fn open(&self) -> usize {
        self.sessions.iter().filter(|s| s.is_some()).count()
    }

    /// N10: advertising only while nothing is connected and no replay runs in the helper
    pub fn advertising(&self) -> bool {
        self.open() == 0 && self.deferred.is_none()
    }

    fn new_sess(&mut self) -> usize {
        self.sessions.push(Some(Sess {
            hello: false,
            t: None,
            hh: [0; 32],
            rx: frame::Reassembler::new(FL, 8192),
            role: Role::None,
            begin: None,
            begin_owner: vec![],
            helper_nonce: None,
            refusals: 0,
        }));
        self.sessions.len() - 1
    }

    /// A BLE connection: only while advertising (N10)
    pub fn connect(&mut self) -> Option<usize> {
        if !self.advertising() {
            return None;
        }
        Some(self.new_sess())
    }

    /// A session that does not need the advertisement (HTTP over Wi-Fi, or a phone that connected just before)
    pub fn connect_other(&mut self) -> usize {
        self.new_sess()
    }

    pub fn is_open(&self, c: usize) -> bool {
        self.sessions.get(c).map(|s| s.is_some()).unwrap_or(false)
    }

    pub fn close(&mut self, c: usize) {
        if let Some(s) = self.sessions.get_mut(c) {
            *s = None;
        }
    }

    /// N8
    fn kill_others(&mut self, keep: usize) {
        for (i, s) in self.sessions.iter_mut().enumerate() {
            if i != keep {
                *s = None;
            }
        }
    }

    pub fn counted_failures(&self) -> usize {
        self.fails.iter().filter(|t| self.now.saturating_sub(**t) < 3600).count()
    }

    fn fresh(&mut self) -> [u8; 32] {
        self.ctr = self.ctr.wrapping_add(1);
        [self.ctr; 32]
    }

    fn presents_unclaimed(&self) -> bool {
        !self.claimed || self.cached_unclaimed
    }

    fn psk_replay(&self) -> [u8; 32] {
        let z = ecdh_x(&hex::decode(NODE_ECDH_PRIV).unwrap(), &owner_enc_pub());
        kdf::psk_replay(&z, &device_id(&self.v))
    }

    /// The length the real node's msg2 has (N2): e 32 + s 32+16 + node_cert + 16
    pub fn msg2_len(&self) -> usize {
        32 + 48 + dev_node_cert(&self.v).len() + 16
    }

    /// frames from the phone on connection `c` -> the node's answer
    pub fn send(&mut self, c: usize, frames: &[Vec<u8>]) -> Reply {
        if !self.is_open(c) {
            return Reply::Closed;
        }
        let mut msg = None;
        for f in frames {
            match self.sessions[c].as_mut().unwrap().rx.push(f) {
                Ok(x) => msg = x,
                Err(_) => {
                    self.close(c);
                    return Reply::Closed;
                }
            }
        }
        let Some(msg) = msg else { return Reply::Nothing };
        let s = self.sessions[c].as_mut().unwrap();
        if s.t.is_none() {
            if !s.hello {
                s.hello = true;
                return self.on_msg1(c, &msg);
            }
            // after a fake msg2 the node only waits for the 10 s handshake time-out (N2)
            return Reply::Nothing;
        }
        self.on_request(c, &msg)
    }

    fn on_msg1(&mut self, c: usize, msg1: &[u8]) -> Reply {
        self.log.push(format!("c{c} msg1"));
        // N12: one budget for the whole node, 20 handshakes a minute; the 21st gets no msg2
        let now = self.now;
        self.hs_times.retain(|t| now.saturating_sub(*t) < 60);
        if self.hs_times.len() >= 20 {
            self.close(c);
            return Reply::Closed;
        }
        self.hs_times.push(now);
        let cert = if self.cert_wrong_static { node_cert_with_static(&self.v, vec![9; 32]) } else { dev_node_cert(&self.v) };
        let mut buf = vec![0u8; 65535];
        let (hs, role) = if self.presents_unclaimed() {
            if msg1.len() != 32 {
                return self.fake_msg2(c);
            }
            let did = device_id(&self.v);
            let hs = snow::Builder::new("Noise_NX_25519_ChaChaPoly_SHA256".parse().unwrap())
                .prologue(&noise::prologue(noise::Mode::Nx, Some(&did)))
                .unwrap()
                .local_private_key(&h(&self.v["keys"]["s_node_priv"]))
                .unwrap()
                .build_responder()
                .unwrap();
            (hs, Role::Nx)
        } else {
            // N1 / N3: psk_replay is in the set only with exactly one owner; only a 48-byte msg1 can match
            if msg1.len() != 48 || self.owners != 1 {
                return self.fake_msg2(c);
            }
            let hs = snow::Builder::new("Noise_NXpsk0_25519_ChaChaPoly_SHA256".parse().unwrap())
                .prologue(&noise::prologue(noise::Mode::NxPsk0, None))
                .unwrap()
                .local_private_key(&h(&self.v["keys"]["s_node_priv"]))
                .unwrap()
                .psk(0, &self.psk_replay())
                .unwrap()
                .build_responder()
                .unwrap();
            (hs, Role::Reacquire)
        };
        let mut hs = hs;
        if hs.read_message(msg1, &mut buf).is_err() {
            return self.fake_msg2(c);
        }
        let n = hs.write_message(&cert, &mut buf).unwrap();
        let s = self.sessions[c].as_mut().unwrap();
        s.hh = hs.get_handshake_hash().try_into().unwrap();
        s.t = Some(hs.into_transport_mode().unwrap());
        s.role = role;
        assert_eq!(n, self.msg2_len(), "the real msg2's length (N2)");
        Reply::Frames(frame::split(&buf[..n], FL).unwrap())
    }

    fn fake_msg2(&mut self, c: usize) -> Reply {
        self.log.push(format!("c{c} fake-msg2"));
        let len = self.msg2_len();
        let fake: Vec<u8> = (0..len).map(|i| (i as u8).wrapping_mul(31).wrapping_add(7)).collect();
        Reply::Frames(frame::split(&fake, FL).unwrap())
    }

    fn encode(&mut self, c: usize, reply: &V) -> Vec<Vec<u8>> {
        let mut buf = vec![0u8; 65535];
        let t = self.sessions[c].as_mut().unwrap().t.as_mut().unwrap();
        let n = t.write_message(&cbor::encode(reply), &mut buf).unwrap();
        frame::split(&buf[..n], FL).unwrap()
    }

    fn on_request(&mut self, c: usize, msg: &[u8]) -> Reply {
        let mut buf = vec![0u8; 65535];
        let t = self.sessions[c].as_mut().unwrap().t.as_mut().unwrap();
        let Ok(n) = t.read_message(msg, &mut buf) else {
            self.close(c);
            return Reply::Closed;
        };
        let req = cbor::decode(&buf[..n]).unwrap();
        let id = req.get(1).and_then(|x| x.as_uint()).unwrap();
        let verb = req.get(2).and_then(|x| x.as_text()).unwrap().to_string();
        let body = req.get(3).unwrap().clone();
        self.log.push(format!("c{c} {verb}"));
        let err = |code: u64| m(vec![(1, V::Uint(id)), (4, V::Uint(code)), (5, m(vec![]))]);
        let ok = |b: V| m(vec![(1, V::Uint(id)), (3, b), (4, V::Uint(0))]);
        let role = self.sessions[c].as_ref().unwrap().role;
        // N4: the role table (session.go:75-84) answers 3 before anything else: not counted, the session stays
        let allowed = match role {
            Role::Nx => matches!(verb.as_str(), "info" | "claim/begin" | "claim/finish"),
            Role::Reacquire => matches!(verb.as_str(), "info" | "claim/begin" | "op/nonce" | "claim/replay"),
            Role::Owner => !matches!(verb.as_str(), "claim/begin" | "claim/finish" | "claim/replay"),
            Role::None => false,
        };
        if !allowed {
            let f = self.encode(c, &err(3));
            return Reply::Frames(f);
        }
        let reply = match verb.as_str() {
            "claim/begin" => {
                // N13: claim/begin takes its nonce through the ops channel: busy -> 7 at once
                if self.ops_busy || self.deferred.is_some() {
                    err(7)
                } else {
                    match body.get(1).and_then(|x| x.as_bytes()) {
                        Some(p) if p.len() == 65 => {
                            let n = self.fresh();
                            let now = self.now;
                            let s = self.sessions[c].as_mut().unwrap();
                            s.begin = Some((n, now));
                            s.begin_owner = p.to_vec();
                            ok(m(vec![(1, V::Bytes(n.to_vec()))]))
                        }
                        _ => err(4),
                    }
                }
            }
            "op/nonce" => {
                // N6: no helper, only OK or 3
                let now = self.now;
                let fresh = self.fresh();
                let s = self.sessions[c].as_mut().unwrap();
                match s.begin {
                    Some((_, at)) if now.saturating_sub(at) <= 55 => {
                        s.helper_nonce = Some(fresh);
                        ok(m(vec![(1, V::Bytes(fresh.to_vec()))]))
                    }
                    _ => err(3),
                }
            }
            "claim/finish" => self.claim_finish(c, &body, err, ok),
            "claim/replay" => {
                // N7: the nonces are gone whatever happens next
                let s = self.sessions[c].as_mut().unwrap();
                let nonce = s.begin.take().map(|b| b.0);
                let helper_nonce = s.helper_nonce.take();
                let owner_pub = s.begin_owner.clone();
                let hh = s.hh;
                // N13: ops busy / A/B trial slot -> 7
                if self.ops_busy || self.deferred.is_some() || self.trial_slot {
                    err(7)
                } else {
                    let d = Deferred { conn: c, id, body, hh, nonce, helper_nonce, owner_pub };
                    if self.defer_helper {
                        self.deferred = Some(d);
                        return Reply::Pending;
                    }
                    return self.replay_done(d);
                }
            }
            "info" => ok(m(vec![(1, V::Text(device_id(&self.v)))])),
            _ => err(2),
        };
        let f = self.encode(c, &reply);
        Reply::Frames(f)
    }

    /// The replay handed to the helper finishes now: (its connection, its answer); killOthers on OK / 13.
    pub fn finish_helper(&mut self) -> (usize, Reply) {
        let d = self.deferred.take().expect("a replay in the helper");
        let c = d.conn;
        (c, self.replay_done(d))
    }

    fn replay_done(&mut self, d: Deferred) -> Reply {
        let c = d.conn;
        let (code, creds) = self.helper_replay(&d);
        if creds.is_some() || code == 13 {
            // N8: after the helper's OK / 13 every other session goes, whether or not this one is still there
            self.kill_others(c);
        }
        if !self.is_open(c) {
            return Reply::Closed;
        }
        let reply = match &creds {
            Some(b) => m(vec![(1, V::Uint(d.id)), (3, b.clone()), (4, V::Uint(0))]),
            None => m(vec![(1, V::Uint(d.id)), (4, V::Uint(code)), (5, m(vec![]))]),
        };
        let f = self.encode(c, &reply);
        match (code, creds.is_some()) {
            // N7 / N8: OK or 13 -> owner, every other session goes
            (_, true) | (13, _) => self.sessions[c].as_mut().unwrap().role = Role::Owner,
            (3, _) => {
                let s = self.sessions[c].as_mut().unwrap();
                s.refusals += 1;
                if s.refusals >= 3 {
                    // N7: the third refusal on one connection is answered, then the connection closes
                    self.close(c);
                }
            }
            _ => {}
        }
        Reply::Frames(f)
    }

    /// node.go claimReplay (+ the dispatch's verdict / record checks): (code, Some(creds body) on success)
    fn helper_replay(&mut self, d: &Deferred) -> (u64, Option<V>) {
        // N16: no usable record (6), boot verdict unknown (11): before the count, not counted
        if self.no_record {
            return (6, None);
        }
        if self.verdict_unknown {
            return (11, None);
        }
        // N9: >= 10 counted failures in the last hour -> 12, even for a correct replay
        if self.counted_failures() >= 10 {
            return (12, None);
        }
        let now = self.now;
        let fail = |n: &mut FakeNode, code: u64| {
            n.fails.push(now);
            (code, None)
        };
        if self.owners != 1 {
            return fail(self, 3);
        }
        // N16 (node.go:642): the response inside the envelope body, 32 bytes, else 11 — counted
        let resp = match d.body.get(1).and_then(|x| x.as_bytes()) {
            Some(r) if r.len() == 32 => r.to_vec(),
            _ => return fail(self, 11),
        };
        let Some(op) = d.body.get(31) else { return fail(self, 11) };
        if op.get(1).and_then(|x| x.as_text()) != Some("claim/replay") {
            return fail(self, 3);
        }
        let Some(s) = op.get(2).and_then(|x| x.as_bytes()).and_then(|s| <[u8; 64]>::try_from(s).ok()) else {
            return fail(self, 11);
        };
        // owner-op: low-s, over h ‖ nonce_helper ‖ verb ‖ args_hash, by the stored owner key
        let Some(helper) = d.helper_nonce else { return fail(self, 3) };
        let wo = m(vec![(1, V::Bytes(resp.clone()))]);
        let input = sig::owner_op_input(&d.hh, &helper, "claim/replay", &wo).unwrap();
        use p256::ecdsa::signature::Verifier;
        let vk = p256::ecdsa::VerifyingKey::from_sec1_bytes(&owner_sign_pub()).unwrap();
        let good_sig = sig::is_low_s(&s) && p256::ecdsa::Signature::from_slice(&s).map(|sg| vk.verify(&input, &sg).is_ok()).unwrap_or(false);
        if !good_sig {
            return fail(self, 3);
        }
        // CheckMac over this session's nonce and h, with the STORED owner_pub
        let Some(nonce) = d.nonce else { return fail(self, 3) };
        let k: [u8; 32] = h(&self.v["keys"]["claim_secret"]).try_into().unwrap();
        let sn: [u8; 9] = h(&self.v["identity_file"]["sn"]).try_into().unwrap();
        let want = claim::response(&k, &nonce, &d.hh, &h(&self.v["identity_file"]["dev_cert_der"]), &owner_sign_pub(), &sn);
        if resp != want || d.owner_pub[..] != owner_sign_pub()[..] {
            return fail(self, 3);
        }
        // N9: every success is a new password; 13 = the store failed (not counted; changed or not)
        match self.set_password {
            SetPassword::Fails { changed } => {
                if changed {
                    self.rotate();
                }
                (13, None)
            }
            SetPassword::Ok => {
                self.rotate();
                (0, Some(m(vec![(1, V::Bytes(TAG_KEY.to_vec())), (2, V::Bytes(ADV_KEY.to_vec())), (3, V::Text(self.password.clone()))])))
            }
        }
    }

    fn rotate(&mut self) {
        self.generation += 1;
        self.password = format!("pw-{}", self.generation);
    }

    /// claim/finish on an NX session (N3 / N5): a node that is already claimed (provd's cache lagging) -> 9; an
    /// unclaimed one checks K and commits: claimed, one owner, and provd keeps answering NX until `refresh` (N3).
    fn claim_finish(&mut self, c: usize, body: &V, err: impl Fn(u64) -> V, ok: impl Fn(V) -> V) -> V {
        if self.ops_busy {
            return err(7);
        }
        let s = self.sessions[c].as_mut().unwrap();
        let Some((nonce, _)) = s.begin.take() else { return err(3) };
        if self.claimed {
            return err(9);
        }
        let k: [u8; 32] = h(&self.v["keys"]["claim_secret"]).try_into().unwrap();
        let sn: [u8; 9] = h(&self.v["identity_file"]["sn"]).try_into().unwrap();
        let op: [u8; 65] = s.begin_owner.clone().try_into().unwrap();
        let want = claim::response(&k, &nonce, &s.hh, &h(&self.v["identity_file"]["dev_cert_der"]), &op, &sn);
        if body.get(1).and_then(|x| x.as_bytes()) != Some(&want[..]) {
            return err(9);
        }
        s.role = Role::Owner;
        self.claimed = true;
        self.owners = 1;
        self.cached_unclaimed = true;
        self.rotate();
        self.kill_others(c);
        ok(m(vec![(1, V::Bytes(TAG_KEY.to_vec())), (2, V::Bytes(ADV_KEY.to_vec())), (3, V::Text(self.password.clone()))]))
    }
}

/// A raw psk_replay session from the test itself (not the app's flow): to send what the app never sends.
pub struct Raw {
    pub c: usize,
    pub conn: batman_proto::conn::Conn,
    pub sn: [u8; 9],
}

impl Raw {
    /// handshake with psk_replay; None = no msg2 / a msg2 that does not decrypt
    pub fn open(n: &mut FakeNode) -> Option<Raw> {
        let c = n.connect_other();
        let z = ecdh_x(&OWNER_ENC_PRIV, &h(&n.v["keys"]["node_ecdh_pub"]));
        let psk = kdf::psk_replay(&z, &device_id(&n.v));
        let mut ini = noise::Initiator::new(noise::Mode::NxPsk0, None, Some(&psk)).unwrap();
        let m1 = ini.msg1().unwrap();
        let Reply::Frames(back) = n.send(c, &frame::split(&m1, FL).unwrap()) else { return None };
        let mut rx = frame::Reassembler::new(FL, 8192);
        let mut m2 = None;
        for f in &back {
            m2 = rx.push(f).unwrap().or(m2);
        }
        let (_, s) = ini.read_msg2(&m2.unwrap()).ok()?;
        let sn = h(&n.v["identity_file"]["sn"]).try_into().unwrap();
        Some(Raw { c, conn: batman_proto::conn::Conn::new(s, FL), sn })
    }

    /// one request -> its outcome; None = no answer (closed / pending)
    pub fn req(&mut self, n: &mut FakeNode, verb: &str, body: V) -> Option<batman_proto::envelope::Outcome> {
        let (_, f) = self.conn.request(verb, body).unwrap();
        match n.send(self.c, &f) {
            Reply::Frames(back) => {
                let mut out = None;
                for x in &back {
                    out = self.conn.on_frame(x).unwrap().or(out);
                }
                out
            }
            _ => None,
        }
    }

    /// claim/begin -> op/nonce -> a correctly signed claim/replay (response over this session); `resp` overrides the
    /// response bytes inside the body (to send a malformed one)
    pub fn replay(&mut self, n: &mut FakeNode, resp: Option<Vec<u8>>) -> Option<batman_proto::envelope::Outcome> {
        use batman_proto::envelope::Outcome;
        let nonce = match self.req(n, "claim/begin", m(vec![(1, V::Bytes(owner_sign_pub().to_vec()))]))? {
            Outcome::Ok(b) => <[u8; 32]>::try_from(b.get(1)?.as_bytes()?).ok()?,
            e => return Some(e),
        };
        let helper = match self.req(n, "op/nonce", m(vec![]))? {
            Outcome::Ok(b) => <[u8; 32]>::try_from(b.get(1)?.as_bytes()?).ok()?,
            e => return Some(e),
        };
        let k: [u8; 32] = h(&n.v["keys"]["claim_secret"]).try_into().unwrap();
        let hh = self.conn.h();
        let r = resp.unwrap_or_else(|| claim::response(&k, &nonce, &hh, &h(&n.v["identity_file"]["dev_cert_der"]), &owner_sign_pub(), &self.sn).to_vec());
        let body = m(vec![(1, V::Bytes(r))]);
        let input = sig::owner_op_input(&hh, &helper, "claim/replay", &body).unwrap();
        use p256::ecdsa::signature::Signer;
        let s: p256::ecdsa::Signature = owner_sign().sign(&input);
        let raw: [u8; 64] = s.normalize_s().to_bytes().into();
        let full = sig::with_owner_op(&body, "claim/replay", &raw).unwrap();
        self.req(n, "claim/replay", full)
    }
}
