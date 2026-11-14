//! replayflow: whole recovery attempts (`Replay`, sans-IO) against the fake claimed node of support/replay_node.rs,
//! which checks them as provd / the helper do (NXpsk0 with psk_replay from its own ECDH side, the stored owner_pub,
//! single-use nonces, the CheckMac response over this session, the owner-op ES256 signature) and models the node
//! behaviours of 254-app-replay §0 (N-numbers in each test). The tests named n* check the fake node itself against
//! those facts, so the app-level tests built on it (bridge api::replay) stand on a node that behaves like the real one.

#[path = "support/replay_node.rs"]
mod replay_node;

use batman_proto::cbor::Value as V;
use batman_proto::envelope::Outcome;
use batman_proto::flow::ClaimReplay;
use batman_proto::replayflow::{Action, End, Replay};
use batman_proto::{frame, nodecert, sig};
use p256::ecdsa::signature::Signer;
use replay_node::*;

/// the platform: ECDH with `enc_priv`, signing with `sign` (DER, optionally turned high-s to check normalisation)
struct Platform {
    enc_priv: [u8; 32],
    sign: p256::ecdsa::SigningKey,
    high_s: bool,
    signed: Vec<Vec<u8>>,
}

fn platform() -> Platform {
    Platform { enc_priv: OWNER_ENC_PRIV, sign: owner_sign(), high_s: false, signed: vec![] }
}

/// the same signature as DER with s = n - s_low, i.e. ALWAYS high-s (p256 may return either form)
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

/// a replay whose claim/replay is in the node's helper, and its connection
struct InHelper(Replay, usize);

impl std::fmt::Debug for InHelper {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "InHelper(c{})", self.1)
    }
}
impl PartialEq for InHelper {
    fn eq(&self, _: &Self) -> bool {
        false
    }
}

#[derive(Debug, PartialEq)]
enum Out {
    End(End),
    /// the node dropped the connection without an answer
    Closed,
    /// the node only waits (no answer to what was written)
    Silent,
    /// claim/replay is in the helper (defer_helper)
    Pending(InHelper),
}

fn feed(r: &mut Replay, back: &[Vec<u8>]) -> Option<Action> {
    let mut next = None;
    for f in back {
        if let Some(x) = r.on_frame(f) {
            next = Some(x);
        }
    }
    next
}

/// One attempt on a new BLE connection (panics when the node does not advertise).
fn attempt(node: &mut FakeNode, p: batman_proto::claimflow::Pending, plat: &mut Platform) -> Out {
    let c = node.connect().expect("the node advertises");
    attempt_on(node, c, p, plat)
}

fn attempt_on(node: &mut FakeNode, c: usize, p: batman_proto::claimflow::Pending, plat: &mut Platform) -> Out {
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
                let der = if plat.high_s {
                    let d = high_s_der(&s);
                    let raw: [u8; 64] = p256::ecdsa::Signature::from_der(&d).map(|x| x.to_bytes().into()).unwrap_or_else(|_| {
                        // p256 refuses to parse a high-s DER on some versions: check the s integer directly
                        let mut r = [0u8; 64];
                        let sl = d[d.len() - 32..].to_vec();
                        r[32..].copy_from_slice(&sl);
                        r
                    });
                    assert!(!sig::is_low_s(&raw), "the platform hands over a high-s signature");
                    d
                } else {
                    s.to_der().as_bytes().to_vec()
                };
                r.signed(&der).unwrap()
            }
            Action::Write(frames) => match node.send(c, &frames) {
                Reply::Frames(back) => match feed(&mut r, &back) {
                    Some(x) => x,
                    None => return Out::Silent,
                },
                Reply::Nothing => return Out::Silent,
                Reply::Closed => return Out::Closed,
                Reply::Pending => return Out::Pending(InHelper(r, c)),
            },
            Action::Done(e) => {
                node.close(c); // the app disconnects after every attempt
                return Out::End(e);
            }
        };
    }
}

fn recovered(o: Out) -> String {
    match o {
        Out::End(End::Replayed(ClaimReplay::Recovered(c))) => {
            assert_eq!(c.owner_tag_key, TAG_KEY);
            c.root_password.clone()
        }
        o => panic!("not recovered: {o:?}"),
    }
}

// N9: every success rotates the root password; the node checked CheckMac and the owner-op on the way
#[test]
fn replay_recovers_and_every_success_is_a_new_password() {
    let v = vectors();
    let mut n = FakeNode::claimed(v.clone());
    let mut plat = platform();
    let pw1 = recovered(attempt(&mut n, pending(&v), &mut plat));
    assert_eq!(n.log, ["c0 msg1", "c0 claim/begin", "c0 op/nonce", "c0 claim/replay"]);
    assert_eq!(plat.signed.len(), 1, "one owner signature per attempt");
    let pw2 = recovered(attempt(&mut n, pending(&v), &mut plat));
    assert_ne!(pw1, pw2, "N9: each replay makes a new password");
    assert_eq!(pw2, n.password, "the answer carries the node's current password");
}

#[test]
fn keystore_high_s_is_normalised_before_sending() {
    let v = vectors();
    let mut n = FakeNode::claimed(v.clone());
    let mut plat = platform();
    plat.high_s = true;
    recovered(attempt(&mut n, pending(&v), &mut plat));
}

// N1 / N2: a psk that is not in the node's set -> a fake msg2 of the real length -> undecryptable; nothing more sent
#[test]
fn wrong_owner_enc_key_means_msg2_does_not_decrypt() {
    let v = vectors();
    let mut n = FakeNode::claimed(v.clone());
    let mut plat = platform();
    plat.enc_priv = [0x33; 32];
    assert_eq!(attempt(&mut n, pending(&v), &mut plat), Out::End(End::Msg2Undecryptable));
    assert_eq!(n.log, ["c0 msg1", "c0 fake-msg2"]);
}

// S2: a msg2 that decrypts with a DAC other than the pending's -> CertRejected, nothing sent after msg1
#[test]
fn another_dac_than_the_pending_is_refused() {
    let v = vectors();
    let mut n = FakeNode::claimed(v.clone());
    let mut p = pending(&v);
    p.dac_der = h(&v["keys"]["dac_cert_der"]);
    assert_eq!(attempt(&mut n, p, &mut platform()), Out::End(End::CertRejected(nodecert::Error::NotPinned)));
    assert_eq!(n.log, ["c0 msg1"], "nothing sent to a node whose DAC is not the pending's");
}

// N9: an owner-op by another key is a counted refusal (3)
#[test]
fn wrong_owner_signing_key_is_refused_and_counted() {
    let v = vectors();
    let mut n = FakeNode::claimed(v.clone());
    let mut plat = platform();
    plat.sign = p256::ecdsa::SigningKey::from_slice(&[0x44; 32]).unwrap();
    assert_eq!(attempt(&mut n, pending(&v), &mut plat), Out::End(End::Replayed(ClaimReplay::Refused)));
    assert_eq!(n.counted_failures(), 1);
}

// N2: the fake msg2 and the real one have the same length, cert + 96 (32 e + 48 s + cert + 16)
#[test]
fn n2_the_fake_msg2_has_the_real_length() {
    let v = vectors();
    let msg = |back: Reply| {
        let Reply::Frames(f) = back else { panic!("{back:?}") };
        let mut rx = frame::Reassembler::new(FL, 8192);
        let mut out = None;
        for x in &f {
            out = rx.push(x).unwrap().or(out);
        }
        out.unwrap().len()
    };
    let cert = dev_node_cert(&v).len();
    let mut n = FakeNode::claimed(v.clone());
    let p = pending(&v);
    let psk_msg1 = |enc: [u8; 32]| {
        let z = ecdh_x(&enc, &p.ecdh_pub);
        let psk = batman_proto::kdf::psk_replay(&z, &p.device_id);
        let mut ini = batman_proto::noise::Initiator::new(batman_proto::noise::Mode::NxPsk0, None, Some(&psk)).unwrap();
        frame::split(&ini.msg1().unwrap(), FL).unwrap()
    };
    let c = n.connect().unwrap();
    let real = msg(n.send(c, &psk_msg1(OWNER_ENC_PRIV)));
    n.close(c);
    let c = n.connect().unwrap();
    let fake = msg(n.send(c, &psk_msg1([0x33; 32])));
    assert!(n.log.contains(&format!("c{c} fake-msg2")));
    assert_eq!(real, cert + 96);
    assert_eq!(fake, real, "a fake msg2 cannot be told apart by its length");
}

// N1: an unclaimed node answers the 48-byte psk msg1 with a fake msg2 (no conclusion, no side effect)
#[test]
fn n1_an_unclaimed_node_gives_a_fake_msg2() {
    let v = vectors();
    let mut n = FakeNode::unclaimed(v.clone());
    assert_eq!(attempt(&mut n, pending(&v), &mut platform()), Out::End(End::Msg2Undecryptable));
    assert_eq!(n.log, ["c0 msg1", "c0 fake-msg2"]);
    assert_eq!(n.counted_failures(), 0);
}

// N3: just after a claim committed provd still answers NX: psk_replay gets an UNDECRYPTABLE msg2 (not "no msg2");
// after provd's next poll the same replay recovers
#[test]
fn n3_the_cache_window_gives_an_undecryptable_msg2_then_recovers() {
    let v = vectors();
    let mut n = FakeNode::claimed(v.clone());
    n.cached_unclaimed = true;
    assert_eq!(attempt(&mut n, pending(&v), &mut platform()), Out::End(End::Msg2Undecryptable));
    assert!(n.log.contains(&"c0 fake-msg2".to_string()));
    n.refresh();
    recovered(attempt(&mut n, pending(&v), &mut platform()));
}

// N3 / N5: inside the cache window NX still opens, but claim/finish answers 9 (the helper refuses: not Unclaimed).
// This is the case where T1 follows a 9 (dev-trust: the dev DAC on first contact).
#[cfg(feature = "dev-trust")]
#[test]
fn n3_inside_the_cache_window_nx_opens_but_finish_is_9() {
    use batman_proto::claimflow::{Action as CA, Claim, End as CE, Input};
    use batman_proto::flow::ClaimFinish;
    let v = vectors();
    let mut n = FakeNode::claimed(v.clone());
    n.cached_unclaimed = true;
    let input = Input {
        device_id: device_id(&v),
        k: h(&v["keys"]["claim_secret"]).try_into().unwrap(),
        owner_pub: owner_sign_pub(),
        owner_enc_pub: owner_enc_pub(),
        sig_enc: [1; 64],
        frame_limit: FL,
    };
    let c = n.connect().unwrap();
    let (mut cl, mut a) = Claim::start(input);
    let end = loop {
        a = match a {
            CA::Write(f) => {
                let Reply::Frames(back) = n.send(c, &f) else { panic!("no answer") };
                let mut next = None;
                for x in &back {
                    next = cl.on_frame(x).or(next);
                }
                next.unwrap()
            }
            CA::PersistPending(_) => cl.pending_persisted().unwrap(),
            CA::Done(e) => break e,
        };
    };
    assert_eq!(end, CE::Finished(ClaimFinish::TryReplay));
    assert_eq!(n.log, ["c0 msg1", "c0 claim/begin", "c0 claim/finish"], "NX opened (no fake msg2)");
}

// N4: an owner session (after a success) is refused claim/begin and claim/replay with 3 — not counted, not closed
#[test]
fn n4_an_owner_session_gets_3_for_begin_and_replay() {
    let v = vectors();
    let mut n = FakeNode::claimed(v.clone());
    let mut r = Raw::open(&mut n).unwrap();
    assert!(matches!(r.replay(&mut n, None), Some(Outcome::Ok(_))));
    let before = n.password.clone();
    for verb in ["claim/replay", "claim/begin"] {
        let o = r.req(&mut n, verb, m(vec![(1, V::Bytes(owner_sign_pub().to_vec()))]));
        assert!(matches!(o, Some(Outcome::Err { code: 3, .. })), "{verb}: {o:?}");
    }
    assert!(n.is_open(r.c), "the role table's 3 does not close the session");
    assert_eq!(n.counted_failures(), 0);
    assert_eq!(n.password, before);
}

// N6: op/nonce without a claim/begin -> 3, not counted; N7: the nonces are used up by any claim/replay, and the third
// helper refusal on one connection is answered, then the connection closes
#[test]
fn n6_n7_single_use_nonces_and_the_third_refusal_closes() {
    let v = vectors();
    let mut n = FakeNode::claimed(v.clone());
    let mut r = Raw::open(&mut n).unwrap();
    assert!(matches!(r.req(&mut n, "op/nonce", m(vec![])), Some(Outcome::Err { code: 3, .. })));
    assert_eq!(n.counted_failures(), 0, "op/nonce's 3 is not counted");
    // wrong response, twice: counted, the connection stays
    for i in 1..=2 {
        assert!(matches!(r.replay(&mut n, Some(vec![9; 32])), Some(Outcome::Err { code: 3, .. })));
        assert_eq!(n.counted_failures(), i);
        assert!(n.is_open(r.c));
    }
    // a replay with no fresh begin: the nonces of the earlier one are gone -> refused (counted), and it is the third
    let o = r.req(&mut n, "claim/replay", m(vec![(1, V::Bytes(vec![0; 32])), (31, m(vec![(1, V::Text("claim/replay".into())), (2, V::Bytes(vec![1; 64]))]))]));
    assert!(matches!(o, Some(Outcome::Err { code: 3, .. })), "{o:?}");
    assert_eq!(n.counted_failures(), 3);
    assert!(!n.is_open(r.c), "the third refusal on one connection closes it");
}

// N9: ten counted failures in an hour -> 12 even for a CORRECT replay; N14: 12 does not close the session; the count
// lives in the node's memory and ages out after an hour
#[test]
fn n9_n14_ten_failures_block_a_correct_replay_with_12_and_the_session_stays() {
    let v = vectors();
    let mut n = FakeNode::claimed(v.clone());
    for _ in 0..10 {
        let mut r = Raw::open(&mut n).unwrap();
        assert!(matches!(r.replay(&mut n, Some(vec![9; 32])), Some(Outcome::Err { code: 3, .. })));
        n.close(r.c);
    }
    assert_eq!(n.counted_failures(), 10);
    n.now = 61; // the handshake budget (N12) is per minute
    let mut r = Raw::open(&mut n).unwrap();
    assert!(matches!(r.replay(&mut n, None), Some(Outcome::Err { code: 12, .. })), "a correct replay is blocked too");
    assert!(n.is_open(r.c), "N14: 12 does not close the session");
    assert!(matches!(r.req(&mut n, "claim/begin", m(vec![(1, V::Bytes(owner_sign_pub().to_vec()))])), Some(Outcome::Ok(_))));
    n.close(r.c);
    n.now = 3601;
    recovered(attempt(&mut n, pending(&v), &mut platform()));
}

// N12: 20 handshakes a minute for the whole node; the 21st gets NO msg2 (dropped), the next minute works again
#[test]
fn n12_the_handshake_budget_drops_the_21st_without_msg2() {
    let v = vectors();
    let mut n = FakeNode::claimed(v.clone());
    let mut plat = platform();
    plat.enc_priv = [0x33; 32]; // undecryptable: only the handshakes count here
    for _ in 0..20 {
        assert_eq!(attempt(&mut n, pending(&v), &mut plat), Out::End(End::Msg2Undecryptable));
    }
    assert_eq!(attempt(&mut n, pending(&v), &mut platform()), Out::Closed, "no msg2 at all");
    n.now = 60;
    recovered(attempt(&mut n, pending(&v), &mut platform()));
}

// N8: a successful replay (and a 13) closes every other session, an unauthenticated one included
#[test]
fn n8_success_and_13_close_every_other_session() {
    let v = vectors();
    for set in [SetPassword::Ok, SetPassword::Fails { changed: true }] {
        let mut n = FakeNode::claimed(v.clone());
        n.set_password = set;
        let other = n.connect_other(); // e.g. a teammate over Wi-Fi, never authenticated
        let mine = n.connect_other();
        let out = attempt_on(&mut n, mine, pending(&v), &mut platform());
        assert!(matches!(out, Out::End(End::Replayed(ClaimReplay::Recovered(_) | ClaimReplay::Reconnect))), "{out:?}");
        assert!(!n.is_open(other), "{set:?}: killOthers");
    }
}

// N13: the ops channel busy -> claim/begin 7 at once (nothing else sent); an A/B trial slot -> claim/replay 7 (Busy)
#[test]
fn n13_ops_busy_and_the_trial_slot_answer_7() {
    let v = vectors();
    let mut n = FakeNode::claimed(v.clone());
    n.ops_busy = true;
    let out = attempt(&mut n, pending(&v), &mut platform());
    assert!(matches!(out, Out::End(End::Refused { verb: "claim/begin", outcome: Outcome::Err { code: 7, .. } })), "{out:?}");
    assert_eq!(n.log, ["c0 msg1", "c0 claim/begin"]);
    let mut n = FakeNode::claimed(v.clone());
    n.trial_slot = true;
    assert_eq!(attempt(&mut n, pending(&v), &mut platform()), Out::End(End::Replayed(ClaimReplay::Busy)));
    assert_eq!(n.counted_failures(), 0);
}

// N10 / N13 / N8: while claim/replay runs in the helper the node does not advertise, another session's claim/begin
// gets 7, and when the helper is done the answer comes and every other session goes
#[test]
fn n10_a_replay_in_the_helper_hides_the_node_and_busies_others() {
    let v = vectors();
    let mut n = FakeNode::claimed(v.clone());
    n.defer_helper = true;
    let Out::Pending(InHelper(_, c)) = attempt(&mut n, pending(&v), &mut platform()) else { panic!("pending") };
    n.close(c); // the phone gave up waiting
    assert!(!n.advertising(), "a replay in the helper: no advertising");
    assert_eq!(n.connect(), None);
    let mut other = Raw::open(&mut n).unwrap();
    let o = other.req(&mut n, "claim/begin", m(vec![(1, V::Bytes(owner_sign_pub().to_vec()))]));
    assert!(matches!(o, Some(Outcome::Err { code: 7, .. })), "{o:?}");
    let (_, rep) = n.finish_helper();
    assert_eq!(rep, Reply::Closed, "its connection is gone: the new password is only on the node");
    assert_eq!(n.password, "pw-1");
    assert!(!n.is_open(other.c), "killOthers");
    // and a phone that waited gets the answer
    let mut n = FakeNode::claimed(v.clone());
    n.defer_helper = true;
    let Out::Pending(InHelper(mut r, c)) = attempt(&mut n, pending(&v), &mut platform()) else { panic!("pending") };
    let (cc, Reply::Frames(back)) = n.finish_helper() else { panic!("an answer") };
    assert_eq!(cc, c);
    match feed(&mut r, &back) {
        Some(Action::Done(End::Replayed(ClaimReplay::Recovered(cr)))) => assert_eq!(cr.root_password, "pw-1"),
        x => panic!("{x:?}"),
    }
}

// N16: 6 (no record) and 11 (verdict unknown) are not counted; an envelope whose response is missing / not 32 bytes
// is 11 AND counted (node.go:642, after the count check)
#[test]
fn n16_6_and_11_uncounted_but_a_bad_response_is_11_counted() {
    let v = vectors();
    for flag in ["no_record", "verdict"] {
        let mut n = FakeNode::claimed(v.clone());
        if flag == "no_record" {
            n.no_record = true;
        } else {
            n.verdict_unknown = true;
        }
        assert_eq!(attempt(&mut n, pending(&v), &mut platform()), Out::End(End::Replayed(ClaimReplay::Unknown)), "{flag}");
        assert_eq!(n.counted_failures(), 0, "{flag}: not counted");
    }
    let mut n = FakeNode::claimed(v.clone());
    let mut r = Raw::open(&mut n).unwrap();
    assert!(matches!(r.replay(&mut n, Some(vec![9; 31])), Some(Outcome::Err { code: 11, .. })));
    assert_eq!(n.counted_failures(), 1, "the envelope's 11 counts");
}

// N9: 13 = the password store failed: not counted; the password may be unchanged; a new connection then recovers
#[test]
fn n9_13_leaves_the_password_unchanged_and_is_not_counted() {
    let v = vectors();
    let mut n = FakeNode::claimed(v.clone());
    n.set_password = SetPassword::Fails { changed: false };
    assert_eq!(attempt(&mut n, pending(&v), &mut platform()), Out::End(End::Replayed(ClaimReplay::Reconnect)));
    assert_eq!(n.password, "pw-0", "unchanged");
    assert_eq!(n.counted_failures(), 0);
    n.set_password = SetPassword::Ok;
    assert_eq!(recovered(attempt(&mut n, pending(&v), &mut platform())), "pw-1");
}

// 12 through Replay: RateLimited
#[test]
fn rate_limited_through_the_flow() {
    let v = vectors();
    let mut n = FakeNode::claimed(v.clone());
    for _ in 0..10 {
        let mut r = Raw::open(&mut n).unwrap();
        r.replay(&mut n, Some(vec![9; 32]));
        n.close(r.c);
    }
    n.now = 61;
    assert_eq!(attempt(&mut n, pending(&v), &mut platform()), Out::End(End::Replayed(ClaimReplay::RateLimited)));
}

// review B-m4 (S2): a msg2 that decrypts with psk_replay but whose node_cert names another static key than the
// handshake's (sig_static valid over that other key) -> CertRejected(StaticMismatch), nothing after msg1.
// Negative control: verify_pinned not given the handshake's static -> accepted.
#[test]
fn a_node_cert_for_another_static_is_refused() {
    let v = vectors();
    let mut n = FakeNode::claimed(v.clone());
    n.cert_wrong_static = true;
    assert_eq!(attempt(&mut n, pending(&v), &mut platform()), Out::End(End::CertRejected(nodecert::Error::StaticMismatch)));
    assert_eq!(n.log, ["c0 msg1"], "nothing sent after msg1");
}

// review B-m4: Debug of a pending, of credentials and of the ends that carry them shows no K, no key, no password.
// Negative control: `#[derive(Debug)]` back on Pending / Creds -> FAIL.
#[test]
fn debug_shows_no_k_key_or_password() {
    use batman_proto::flow::Creds;
    let v = vectors();
    let p = pending(&v);
    let k = p.k;
    let c = Creds { owner_tag_key: TAG_KEY, adv_owner_key: [0x3c; 32], root_password: "pw-secret-77".into() };
    let text = format!("{p:?} {:?} {:?}", End::Replayed(ClaimReplay::Recovered(c)), Some(p.clone()));
    assert!(text.contains(&device_id(&v)), "the id is shown: {text}");
    for s in [format!("{:?}", k), format!("{:?}", &k[..8]), hex::encode(k), format!("{:?}", TAG_KEY), format!("{:?}", [0x3c_u8; 32]), "pw-secret-77".into()] {
        assert!(!text.contains(&s), "a secret in Debug: {s}");
    }
}
