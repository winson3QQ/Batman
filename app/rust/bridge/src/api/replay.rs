//! Claim recovery for Dart (docs/design/254-app-replay.md v5): one `ReplaySession` per recovery, one `begin` per
//! connection. Sans-IO like the claim: Dart moves the frames, Kotlin does the ECDH (once, before any connection) and
//! the owner signature; this file keeps z, psk_replay and K (zeroed on drop), decodes the pending strictly (§5), and
//! turns every end into what ClaimRecovery does next (§4 `replay_next`). Dev builds only (§8 / §11: the field build
//! has no `ecdh`): every entry refuses without `dev-trust`. No text carries z, K, a psk or a password.

use batman_proto::cbor::{self, Value};
use batman_proto::claimflow::Pending;
use batman_proto::envelope::Outcome;
use batman_proto::flow::{ClaimReplay, E_BUSY, E_FORBIDDEN, E_STORAGE};
use batman_proto::nodecert;
use batman_proto::replayflow::{Action, End, Replay};

use super::claim::{node_path, node_record, pending_path, TRY_REPLAY_TEXT};

/// §3-1: the field build cannot recover (no `ecdh`); the pending stays
pub(crate) const NOT_YET: &str = "這個版本的 app 還不能恢復中斷的認領（紀錄先保留）";
const CERT: &str = "節點身分與認領紀錄不符，已停止（紀錄先保留）";
const BAD_REPLY: &str = "節點回覆無法辨識，紀錄先保留";
/// s1 l.247, word for word
const RATE: &str = "恢復被擋 — 可能有人在附近干擾，請換地點或稍後再試";
const LOCK: &str = "節點上鎖尚未完成，請稍後再試";
const NOT_FOUND: &str = "找不到這台或還無法恢復：請把手機貼近節點、確認節點開機後再試（節點也可能已重燒或被他人認領）";
const STILL_FINISHING: &str = "節點可能還在收尾 — 請等幾分鐘再按一次";
/// §2 T3: added when a replay may have rotated the password of a node this phone still has a record for
const OLD_RECORD_PW: &str = "節點可能已更換密碼：「我的節點」仍可登入，但裡面存的 root 密碼可能已失效";
const RECOVERED: &str = "已恢復；root 密碼已更換，先前抄下的密碼失效";

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ReplayKind {
    /// write `frames` to RX in order
    Write,
    /// Kotlin signs `sign_input` with the owner key (owner-op prefix), then `signed(der)`
    Sign,
    /// this connection is over: `next` says what the recovery does now, `detail` why (shown when it stops)
    Ended,
    /// credentials: seal + write `record` at `path`, THEN remove `pending_path` (ClaimRecords.claimed)
    Recovered,
}

/// §4: what the recovery does after this connection
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ReplayNext {
    /// could not connect / time-out / no msg2 within 12 s -> the next device (T1: the next round)
    NoConnection,
    /// msg2 did not decrypt -> already disconnected at once; the next device (T1: the next round)
    Undecryptable,
    /// try this node again in the next round
    Again,
    /// 13: disconnect, 15 s, a NEW connection, replay again (not a round; at most 5 in a row)
    Reconnect,
    /// stop the whole recovery; `detail` says why; the pending stays
    Stop,
    /// the node record is in `record`
    Recovered,
}

pub struct ReplayStep {
    pub kind: ReplayKind,
    pub frames: Vec<Vec<u8>>,
    pub sign_input: Vec<u8>,
    pub next: ReplayNext,
    /// never a secret (shown, logged)
    pub detail: String,
    pub path: String,
    pub record: Vec<u8>,
    pub pending_path: String,
    /// Ended: claim/replay itself was refused (3, or 4) — T4 adds its "maybe not this node's last claim" warning (v6.1)
    pub replay_refused: bool,
}

impl ReplayStep {
    fn new(kind: ReplayKind) -> ReplayStep {
        ReplayStep { kind, frames: vec![], sign_input: vec![], next: ReplayNext::Stop, detail: String::new(), path: String::new(), record: vec![], pending_path: String::new(), replay_refused: false }
    }
    fn ended(next: ReplayNext, detail: String) -> ReplayStep {
        ReplayStep { next, detail, ..ReplayStep::new(ReplayKind::Ended) }
    }
}

fn dev_gate() -> Result<(), String> {
    if nodecert::DEV_TRUST {
        Ok(())
    } else {
        Err(NOT_YET.into())
    }
}

/// §5: the opened pending, strictly: exactly keys 1-7, each of its fixed type and length, and key 1 (the device id)
/// equal to the id of the path it was read from. Anything else = no replay (the pending is not touched).
pub(crate) fn decode_pending(plain: &[u8], path_id: &str) -> Result<Pending, String> {
    const BAD: &str = "手機裡的認領紀錄格式不對，這次不恢復（紀錄沒有改動）";
    let v = cbor::decode(plain).map_err(|_| BAD)?;
    let Value::Map(m) = &v else { return Err(BAD.into()) };
    let mut keys: Vec<u64> = m.iter().map(|(k, _)| match k {
        Value::Uint(k) => *k,
        _ => 0,
    }).collect();
    keys.sort_unstable();
    if keys != [1, 2, 3, 4, 5, 6, 7] {
        return Err(BAD.into());
    }
    let b = |k: u64| v.get(k).and_then(Value::as_bytes).ok_or(BAD);
    let fixed = |k: u64| -> Result<[u8; 65], String> { b(k)?.try_into().map_err(|_| BAD.to_string()) };
    let id = v.get(1).and_then(Value::as_text).ok_or(BAD)?;
    if id != path_id {
        return Err("手機裡的認領紀錄不是這台節點的，這次不恢復（紀錄沒有改動）".into());
    }
    let k: [u8; 32] = b(2)?.try_into().map_err(|_| BAD)?;
    let (cert, dac) = (b(3)?, b(4)?);
    if cert.is_empty() || dac.is_empty() {
        return Err(BAD.into());
    }
    Ok(Pending { device_id: id.to_string(), k, node_cert: cert.to_vec(), dac_der: dac.to_vec(), ecdh_pub: fixed(5)?, owner_pub: fixed(6)?, owner_enc_pub: fixed(7)? })
}

/// Where a connection ended, for `replay_next`
#[derive(Debug)]
pub(crate) enum Res<'a> {
    /// could not connect, timed out, or no msg2 (the 12 s wait, or the node dropped the link before msg2)
    NoConnection,
    /// the link went (or a wait ran out) after msg2, before claim/replay was written
    LostBeforeWrite,
    /// the link went, or the 90 s ran out, after claim/replay was written: no answer
    LostAfterWrite,
    /// the flow's own end; `written`: claim/replay had been written
    End { written: bool, end: &'a End },
}

/// §4, the whole table: (where it ended, what it was) -> what next. A row that is not listed stops.
pub(crate) fn replay_next(r: &Res) -> (ReplayNext, String) {
    use ReplayNext::*;
    let neutral = |what: &str, c: u64| format!("節點沒有接受這次恢復（{what}，代碼 {c}），已停止；紀錄先保留");
    match r {
        Res::NoConnection => (NoConnection, String::new()),
        Res::LostBeforeWrite => (Again, String::new()),
        Res::LostAfterWrite => (Again, String::new()),
        Res::End { end: End::Msg2Undecryptable, .. } => (Undecryptable, String::new()),
        Res::End { end: End::CertRejected(_), .. } => (Stop, CERT.into()),
        Res::End { end: End::Refused { verb, outcome: Outcome::Err { code, .. } }, .. } => match (*verb, *code) {
            (_, E_BUSY | E_STORAGE) => (Again, String::new()),
            ("op/nonce", E_FORBIDDEN) => (Again, String::new()),
            (v, c) => (Stop, neutral(v, c)),
        },
        Res::End { end: End::Refused { verb, .. }, .. } => (Stop, format!("節點沒有接受這次恢復（{verb}），已停止；紀錄先保留")),
        Res::End { written: false, end: End::Broken(_) } => (Again, String::new()),
        Res::End { written: true, end: End::Broken(_) } => (Stop, BAD_REPLY.into()),
        Res::End { end: End::Replayed(c), .. } => match c {
            ClaimReplay::Recovered(_) => (Recovered, RECOVERED.into()),
            ClaimReplay::Reconnect => (Reconnect, String::new()),
            ClaimReplay::RateLimited => (Stop, RATE.into()),
            ClaimReplay::Busy => (Again, String::new()),
            ClaimReplay::Refused => (Stop, "節點拒絕了這次恢復，已停止、不再重試；紀錄先保留".into()),
            ClaimReplay::Unknown => (Stop, BAD_REPLY.into()),
        },
    }
}

/// How a whole recovery ended without credentials (§4 end, §3-5)
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RecoveryEnd {
    /// 3 rounds or 300 s without a result
    Exhausted,
    /// 13 five times in a row
    LockIncomplete,
    /// stopped (the button, the page left, Bluetooth): only the added sentences (the caller says why it stopped)
    Stopped,
}

/// The closing words. `after_9`: T1 after claim/finish answered 9; `unanswered`: a claim/replay was written and no
/// answer came; `old_record`: this phone has a node record of it (T3 was asked) and a replay may have rotated the
/// password (`unanswered`, or a 13).
#[flutter_rust_bridge::frb(sync)]
pub fn recovery_end_text(end: RecoveryEnd, after_9: bool, unanswered: bool, old_record: bool) -> String {
    let mut parts: Vec<&str> = match end {
        RecoveryEnd::Exhausted if after_9 => vec![TRY_REPLAY_TEXT],
        RecoveryEnd::Exhausted => vec![NOT_FOUND],
        RecoveryEnd::LockIncomplete => vec![LOCK],
        RecoveryEnd::Stopped => vec![],
    };
    if unanswered && end != RecoveryEnd::LockIncomplete {
        parts.push(STILL_FINISHING);
    }
    if old_record && (unanswered || end == RecoveryEnd::LockIncomplete) {
        parts.push(OLD_RECORD_PW);
    }
    parts.join("。")
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Stage {
    /// no connection yet (or between connections)
    Idle,
    /// msg1 written, waiting for msg2
    Hello,
    /// msg2 decrypted with the pinned DAC: claim/begin, op/nonce
    Requests,
    /// waiting for the owner signature
    Signing,
    /// claim/replay written
    Written,
    Over,
}

#[flutter_rust_bridge::frb(opaque)]
pub struct ReplaySession {
    pending: Pending,
    link: [u8; 32],
    z: Option<[u8; 32]>,
    flow: Option<Replay>,
    stage: Stage,
    decrypted: bool,
    dev_soft_enc: bool,
}

impl Drop for ReplaySession {
    fn drop(&mut self) {
        if let Some(z) = &mut self.z {
            z.iter_mut().for_each(|b| *b = 0);
        }
        self.pending.k.iter_mut().for_each(|b| *b = 0);
    }
}

impl ReplaySession {
    /// §3-1 / §5: the opened pending of `device_id` (read from `claim-pending/{device_id}`) -> the session and the
    /// peer for Kotlin's ECDH (the pending's sig_ecdh-verified ecdh_pub). `dev_soft_enc`: the live key level (the
    /// node record gets the same mark a claim gives it, s1 §4.1).
    #[flutter_rust_bridge::frb(sync)]
    pub fn prepare(pending_plain: Vec<u8>, device_id: String, dev_soft_enc: bool) -> Result<(ReplaySession, Vec<u8>), String> {
        let mut pending_plain = pending_plain;
        let r = dev_gate().and_then(|_| decode_pending(&pending_plain, &device_id)).map(|pending| {
            let peer = pending.ecdh_pub.to_vec();
            let link = batman_proto::claimflow::pending_link(&pending_plain);
            (ReplaySession { pending, link, z: None, flow: None, stage: Stage::Idle, decrypted: false, dev_soft_enc }, peer)
        });
        pending_plain.fill(0); // the plaintext carries K (review B-m4)
        r
    }

    /// Kotlin's ECDH result (32 bytes), once, before any connection; Dart zeroes its copy right after.
    #[flutter_rust_bridge::frb(sync)]
    pub fn set_z(&mut self, z: Vec<u8>) -> Result<(), String> {
        dev_gate()?;
        let mut z = z;
        let r = <[u8; 32]>::try_from(&z[..]).map_err(|_| "金鑰交換的結果格式不對（not 32 bytes）".to_string());
        z.iter_mut().for_each(|b| *b = 0);
        self.z = Some(r?);
        Ok(())
    }

    /// A new connection is up: its msg1 frames. Every earlier connection's state is dropped.
    #[flutter_rust_bridge::frb(sync)]
    pub fn begin(&mut self, frame_limit: u32) -> Result<ReplayStep, String> {
        dev_gate()?;
        let z = self.z.ok_or("App 內部錯誤（no ECDH result）")?;
        let (mut flow, a) = Replay::start(self.pending.clone(), frame_limit as usize);
        let a = match a {
            Action::Ecdh { .. } => flow.ecdh_done(z),
            other => Some(other),
        };
        self.flow = Some(flow);
        self.stage = Stage::Idle; // the msg1 Write moves it to Hello
        self.decrypted = false;
        self.step(a).ok_or_else(|| "App 內部錯誤（no msg1）".to_string())
    }

    /// A frame received on TX; None = keep reading.
    #[flutter_rust_bridge::frb(sync)]
    pub fn on_frame(&mut self, frame: Vec<u8>) -> Option<ReplayStep> {
        let a = self.flow.as_mut()?.on_frame(&frame);
        self.step(a)
    }

    /// Kotlin's DER signature over `sign_input`.
    #[flutter_rust_bridge::frb(sync)]
    pub fn signed(&mut self, der: Vec<u8>) -> Option<ReplayStep> {
        let a = self.flow.as_mut()?.signed(&der);
        self.step(a)
    }

    /// The link went, or one of §3-2's waits ran out, on this connection (or no connection came up at all).
    #[flutter_rust_bridge::frb(sync)]
    pub fn lost(&mut self) -> ReplayStep {
        let r = match self.stage {
            Stage::Idle | Stage::Hello => Res::NoConnection,
            Stage::Requests | Stage::Signing => Res::LostBeforeWrite,
            Stage::Written => Res::LostAfterWrite,
            Stage::Over => Res::NoConnection,
        };
        self.flow = None;
        self.stage = Stage::Over;
        let (next, detail) = replay_next(&r);
        ReplayStep::ended(next, detail)
    }

    /// §7 `written`: the claim/replay frames of THIS connection have been handed to Dart.
    #[flutter_rust_bridge::frb(sync)]
    pub fn written(&self) -> bool {
        self.stage == Stage::Written
    }

    /// msg2 of THIS connection decrypted and carried the pinned DAC: this device is the node (§3-4).
    #[flutter_rust_bridge::frb(sync)]
    pub fn decrypted(&self) -> bool {
        self.decrypted
    }

    fn step(&mut self, a: Option<Action>) -> Option<ReplayStep> {
        Some(match a? {
            Action::Ecdh { .. } => ReplayStep::ended(ReplayNext::Stop, "App 內部錯誤（ECDH asked twice）".into()),
            Action::Write(frames) => {
                self.stage = match self.stage {
                    Stage::Idle => Stage::Hello,
                    // the Write after msg1 is claim/begin: only a msg2 that decrypted with the pinned DAC leads here
                    Stage::Hello => {
                        self.decrypted = true;
                        Stage::Requests
                    }
                    // §7: the claim/replay frames are handed over -> `written`
                    Stage::Signing => Stage::Written,
                    s => s,
                };
                ReplayStep { frames, ..ReplayStep::new(ReplayKind::Write) }
            }
            Action::Sign { input } => {
                self.stage = Stage::Signing;
                ReplayStep { sign_input: input, ..ReplayStep::new(ReplayKind::Sign) }
            }
            Action::Done(e) => {
                let written = self.stage == Stage::Written;
                self.stage = Stage::Over;
                self.flow = None;
                let (next, detail) = replay_next(&Res::End { written, end: &e });
                match e {
                    End::Replayed(ClaimReplay::Recovered(c)) => {
                        let p = &self.pending;
                        ReplayStep {
                            next,
                            detail: format!("{detail}（節點 …{}）", &p.device_id[p.device_id.len() - 4..]),
                            path: node_path(&p.device_id),
                            record: node_record(p, &c, self.link, self.dev_soft_enc),
                            pending_path: pending_path(&p.device_id),
                            ..ReplayStep::new(ReplayKind::Recovered)
                        }
                    }
                    End::Replayed(ClaimReplay::Refused) => ReplayStep { replay_refused: true, ..ReplayStep::ended(next, detail) },
                    _ => ReplayStep::ended(next, detail),
                }
            }
        })
    }
}

#[cfg(test)]
#[cfg_attr(not(feature = "dev-trust"), allow(dead_code, unused_imports))]
mod tests {
    use super::*;
    use crate::replay_node::*;
    use batman_proto::cbor::Value as V;

    fn pending_plain(v: &serde_json::Value) -> Vec<u8> {
        crate::api::claim::pending_record(&pending(v))
    }

    fn der(input: &[u8]) -> Vec<u8> {
        use p256::ecdsa::signature::Signer;
        let s: p256::ecdsa::Signature = owner_sign().sign(input);
        s.to_der().as_bytes().to_vec()
    }

    /// a session as ClaimRecovery makes it: prepare -> Kotlin's ECDH -> set_z
    fn session(v: &serde_json::Value) -> ReplaySession {
        let (mut s, peer) = ReplaySession::prepare(pending_plain(v), device_id(v), false).unwrap();
        s.set_z(ecdh_x(&OWNER_ENC_PRIV, &peer).to_vec()).unwrap();
        s
    }

    /// One connection the way ClaimRecovery runs it; `wrote` = claim/replay was written on it. A node that does not
    /// answer (closed, silent, the helper still busy) = §3-2's wait running out -> `lost()`.
    fn attempt(n: &mut FakeNode, s: &mut ReplaySession, texts: &mut Vec<String>) -> (ReplayStep, bool) {
        let Some(c) = n.connect() else { return (s.lost(), false) };
        let mut st = s.begin(FL as u32).unwrap();
        let mut wrote = false;
        loop {
            texts.push(st.detail.clone());
            match st.kind {
                ReplayKind::Write => {
                    let back = match n.send(c, &st.frames) {
                        Reply::Frames(b) => b,
                        _ => vec![],
                    };
                    wrote |= s.written();
                    let mut next = None;
                    for f in &back {
                        if let Some(x) = s.on_frame(f.clone()) {
                            next = Some(x);
                        }
                    }
                    match next {
                        Some(x) => st = x,
                        None => {
                            n.close(c);
                            let l = s.lost();
                            texts.push(l.detail.clone());
                            return (l, wrote);
                        }
                    }
                }
                ReplayKind::Sign => st = s.signed(der(&st.sign_input)).unwrap(),
                ReplayKind::Ended | ReplayKind::Recovered => {
                    n.close(c);
                    return (st, wrote);
                }
            }
        }
    }

    // R3 (§5): only keys 1-7, each of its type and length, and the id of the path; the claim's own pending record
    // decodes back to the same fields (round trip; app up- / downgrade keeps the format). Negative control: the id
    // check removed -> another node's pending is accepted.
    #[test]
    fn r3_pending_decode_is_strict_and_round_trips() {
        let v = vectors();
        let p = pending(&v);
        let plain = pending_plain(&v);
        let id = device_id(&v);
        assert_eq!(decode_pending(&plain, &id).unwrap(), p, "round trip of claim.rs pending_record()");
        assert!(decode_pending(&plain, "e61551410cfd538e25").is_err(), "another node's id on the path");
        let edit = |f: &dyn Fn(&mut Vec<(V, V)>)| {
            let mut m = match cbor::decode(&plain).unwrap() {
                V::Map(m) => m,
                _ => unreachable!(),
            };
            f(&mut m);
            cbor::encode(&V::Map(m))
        };
        let bad = [
            ("key 8 added", edit(&|m| m.push((V::Uint(8), V::Uint(1))))),
            ("key 7 missing", edit(&|m| m.retain(|(k, _)| k != &V::Uint(7)))),
            ("K 31 bytes", edit(&|m| m[1].1 = V::Bytes(vec![7; 31]))),
            ("ecdh_pub 64 bytes", edit(&|m| m[4].1 = V::Bytes(vec![4; 64]))),
            ("owner_pub as text", edit(&|m| m[5].1 = V::Text("x".into()))),
            ("empty node_cert", edit(&|m| m[2].1 = V::Bytes(vec![]))),
            ("id as bytes", edit(&|m| m[0].1 = V::Bytes(id.as_bytes().to_vec()))),
        ];
        for (what, b) in bad {
            assert!(decode_pending(&b, &id).is_err(), "{what}");
        }
        assert!(decode_pending(b"\xff", &id).is_err());
    }

    // R2: §4's whole table, row by row, and every row not listed stops. Negative controls: the default changed to a
    // retry -> the unknown codes FAIL; Busy mapped to stop -> the 7 rows FAIL.
    #[test]
    fn r2_replay_next_whole_table() {
        use batman_proto::flow::Creds;
        use ReplayNext::*;
        let err = |code: u64| Outcome::Err { code, detail: V::Map(vec![]) };
        let next = |r: Res| replay_next(&r).0;
        let end = |written: bool, e: End| next(Res::End { written, end: &e });
        assert_eq!(next(Res::NoConnection), NoConnection);
        assert_eq!(end(false, End::Msg2Undecryptable), Undecryptable);
        assert_eq!(end(false, End::CertRejected(nodecert::Error::NotPinned)), Stop);
        for verb in ["claim/begin", "op/nonce"] {
            assert_eq!(end(false, End::Refused { verb, outcome: err(7) }), Again, "{verb} 7");
            assert_eq!(end(false, End::Refused { verb, outcome: err(10) }), Again, "{verb} 10");
            for c in [4, 6, 11, 1, 2, 12, 13, 99] {
                assert_eq!(end(false, End::Refused { verb, outcome: err(c) }), Stop, "{verb} {c}");
            }
        }
        assert_eq!(end(false, End::Refused { verb: "op/nonce", outcome: err(3) }), Again, "op/nonce 3 (N6)");
        assert_eq!(end(false, End::Refused { verb: "claim/begin", outcome: err(3) }), Stop, "claim/begin 3");
        assert_eq!(end(false, End::Broken("x".into())), Again, "Broken before claim/replay was written");
        assert_eq!(next(Res::LostBeforeWrite), Again);
        assert_eq!(next(Res::LostAfterWrite), Again, "written, no answer: next round");
        assert_eq!(end(true, End::Broken("x".into())), Stop, "a broken answer after the write stops (D15)");
        let creds = Creds { owner_tag_key: [1; 32], adv_owner_key: [2; 32], root_password: "p".into() };
        assert_eq!(end(true, End::Replayed(ClaimReplay::Recovered(creds))), Recovered);
        assert_eq!(end(true, End::Replayed(ClaimReplay::Reconnect)), Reconnect);
        assert_eq!(end(true, End::Replayed(ClaimReplay::RateLimited)), Stop);
        assert_eq!(replay_next(&Res::End { written: true, end: &End::Replayed(ClaimReplay::RateLimited) }).1, RATE);
        assert_eq!(end(true, End::Replayed(ClaimReplay::Refused)), Stop);
        assert_eq!(end(true, End::Replayed(ClaimReplay::Unknown)), Stop, "OK without credentials / 6 / 11 / unknown codes");
        // the replay codes as the flow maps them: 7 / 10 -> next round, 13 -> reconnect, every other code -> stop
        for c in 1..=40u64 {
            let r = batman_proto::flow::claim_replay(&err(c));
            let want = match c {
                7 | 10 => Again,
                13 => Reconnect,
                _ => Stop,
            };
            assert_eq!(end(true, End::Replayed(r)), want, "claim/replay code {c}");
        }
    }

    // R4 (N3): the node committed but provd's cache lags: round 1 msg2 does not decrypt (an answer, not "no msg2"), the
    // cache catches up, round 2 recovers. Negative control: Undecryptable mapped to Stop -> the recovery ends at round 1.
    #[cfg(feature = "dev-trust")]
    #[test]
    fn r4_the_cache_window_round_1_undecryptable_round_2_recovered() {
        let v = vectors();
        let mut n = FakeNode::claimed(v.clone());
        n.cached_unclaimed = true;
        let mut s = session(&v);
        let mut texts = vec![];
        let mut last = None;
        for round in 1..=3 {
            let (st, _) = attempt(&mut n, &mut s, &mut texts);
            match st.next {
                ReplayNext::Undecryptable | ReplayNext::NoConnection | ReplayNext::Again => {
                    assert_eq!(round, 1, "only round 1 is inside the window");
                    n.now += 15;
                    n.refresh(); // provd's next poll
                }
                _ => {
                    last = Some((round, st));
                    break;
                }
            }
        }
        let (round, st) = last.expect("an end");
        assert_eq!((round, st.next), (2, ReplayNext::Recovered), "{}", st.detail);
        assert_eq!(n.log.iter().filter(|l| l.ends_with("fake-msg2")).count(), 1, "round 1 got a (fake) msg2");
    }

    // D3, the Rust half: the symptom of §0 (the node claimed, the phone holds only the pending) -> the node record a
    // recovery writes logs in to the node (owner session reads it, its tag key is the node's) and holds the node's
    // LATEST password (a replay whose answer was lost rotated it once more), key 9 links the pending it came from.
    #[cfg(feature = "dev-trust")]
    #[test]
    fn d3_the_recovered_record_logs_in_with_the_latest_password() {
        let v = vectors();
        let mut n = FakeNode::claimed(v.clone());
        n.password = "pw-claim".into();
        n.defer_helper = true; // the first replay's answer never reaches the phone
        let mut s = session(&v);
        let mut texts = vec![];
        let (st, wrote) = attempt(&mut n, &mut s, &mut texts);
        assert!(wrote);
        assert_eq!(st.next, ReplayNext::Again, "written, no answer -> next round");
        n.finish_helper(); // the node rotated the password anyway
        n.defer_helper = false;
        n.now += 15;
        let (st, _) = attempt(&mut n, &mut s, &mut texts);
        assert_eq!(st.kind, ReplayKind::Recovered, "{}", st.detail);
        assert_eq!(st.path, format!("node/{}", device_id(&v)));
        assert_eq!(st.pending_path, format!("claim-pending/{}", device_id(&v)));
        let rec = cbor::decode(&st.record).unwrap();
        assert_eq!(n.password, "pw-2");
        assert_eq!(rec.get(7).and_then(V::as_text), Some(n.password.as_str()), "the latest password");
        assert_eq!(rec.get(5).and_then(V::as_bytes), Some(&TAG_KEY[..]));
        assert_eq!(rec.get(2).and_then(V::as_bytes), Some(&pending(&v).k[..]), "K kept");
        assert_eq!(rec.get(9).and_then(V::as_bytes), Some(&batman_proto::claimflow::pending_link(&pending_plain(&v))[..]));
        assert_eq!(rec.get(10), None, "a hardware owner_enc: no dev mark");
        assert!(crate::api::owner::OwnerSession::start(st.record.clone(), owner_sign_pub().to_vec(), FL as u32).is_ok(), "login reads it");
        assert_eq!(crate::api::rekey::own_of(std::slice::from_ref(&st.record)).len(), 1, "the own-node list reads it");
    }

    // D15 (Rust): an answer after claim/replay was written that does not decrypt -> Stop with 「節點回覆無法辨識」,
    // never a retry. Negative control: that row of replay_next mapped to Again -> FAIL.
    #[cfg(feature = "dev-trust")]
    #[test]
    fn d15_a_broken_answer_after_the_write_stops() {
        let v = vectors();
        let mut n = FakeNode::claimed(v.clone());
        let mut s = session(&v);
        let c = n.connect().unwrap();
        let mut st = s.begin(FL as u32).unwrap();
        let end = loop {
            match st.kind {
                ReplayKind::Write => {
                    let Reply::Frames(mut back) = n.send(c, &st.frames) else { panic!("no answer") };
                    if s.written() {
                        // the node's answer to claim/replay, mangled on the way
                        let last = back.len() - 1;
                        let l = back[last].len() - 1;
                        back[last][l] ^= 0x55;
                    }
                    let mut out = None;
                    for f in &back {
                        out = s.on_frame(f.clone()).or(out);
                    }
                    st = out.unwrap();
                    if st.kind == ReplayKind::Ended {
                        break st;
                    }
                }
                ReplayKind::Sign => st = s.signed(der(&st.sign_input)).unwrap(),
                _ => break st,
            }
        };
        assert_eq!(n.password, "pw-1", "the node did rotate");
        assert_eq!((end.kind, end.next, end.detail.as_str()), (ReplayKind::Ended, ReplayNext::Stop, BAD_REPLY));
    }

    // §4 / N13 / N16 through a real session: ops busy -> claim/begin 7 -> Again; A/B trial slot -> Again; 6 / 11 ->
    // Stop; 13 -> Reconnect; the cache window -> Undecryptable; 12 -> Stop with s1's words; no msg2 (N12) -> no
    // connection; another DAC -> Stop (S2).
    #[cfg(feature = "dev-trust")]
    #[test]
    fn codes_through_the_session() {
        let v = vectors();
        let run = |set: &dyn Fn(&mut FakeNode)| {
            let mut n = FakeNode::claimed(v.clone());
            set(&mut n);
            let mut s = session(&v);
            let (st, _) = attempt(&mut n, &mut s, &mut vec![]);
            (st.next, st.detail)
        };
        assert_eq!(run(&|n| n.ops_busy = true).0, ReplayNext::Again);
        assert_eq!(run(&|n| n.trial_slot = true).0, ReplayNext::Again);
        assert_eq!(run(&|n| n.no_record = true).0, ReplayNext::Stop);
        assert_eq!(run(&|n| n.verdict_unknown = true).0, ReplayNext::Stop);
        assert_eq!(run(&|n| n.cached_unclaimed = true).0, ReplayNext::Undecryptable);
        assert_eq!(run(&|n| n.set_password = SetPassword::Fails { changed: false }).0, ReplayNext::Reconnect);
        let (nx, d) = run(&|n| {
            for _ in 0..10 {
                let mut r = Raw::open(n).unwrap();
                r.replay(n, Some(vec![9; 32]));
                n.close(r.c);
            }
            n.now = 61;
        });
        assert_eq!((nx, d.as_str()), (ReplayNext::Stop, RATE));
        let (nx, _) = run(&|n| {
            for _ in 0..20 {
                let c = n.connect().unwrap();
                let mut ini = batman_proto::noise::Initiator::new(batman_proto::noise::Mode::NxPsk0, None, Some(&[0; 32])).unwrap();
                n.send(c, &batman_proto::frame::split(&ini.msg1().unwrap(), FL).unwrap());
                n.close(c);
            }
        });
        assert_eq!(nx, ReplayNext::NoConnection, "the 21st handshake gets no msg2");
        let mut n = FakeNode::claimed(v.clone());
        let mut p = pending(&v);
        p.dac_der = h(&v["keys"]["dac_cert_der"]);
        let (mut s, peer) = ReplaySession::prepare(crate::api::claim::pending_record(&p), device_id(&v), false).unwrap();
        s.set_z(ecdh_x(&OWNER_ENC_PRIV, &peer).to_vec()).unwrap();
        let (st, _) = attempt(&mut n, &mut s, &mut vec![]);
        assert_eq!((st.next, st.detail.as_str()), (ReplayNext::Stop, CERT));
        assert_eq!(n.log, ["c0 msg1"], "nothing after msg1");
    }


    // v6.1 §19.2-6: a refused claim/replay (3: here the owner signature is not the stored owner's) is marked
    // `replay_refused` (T4 adds its warning); any other end is not. Negative control: the flag never set -> FAIL.
    #[cfg(feature = "dev-trust")]
    #[test]
    fn a_refused_replay_is_marked() {
        use p256::ecdsa::signature::Signer;
        let v = vectors();
        let mut n = FakeNode::claimed(v.clone());
        let mut s = session(&v);
        let c = n.connect().unwrap();
        let mut st = s.begin(FL as u32).unwrap();
        let end = loop {
            match st.kind {
                ReplayKind::Write => {
                    let Reply::Frames(back) = n.send(c, &st.frames) else { panic!("no answer") };
                    let mut out = None;
                    for f in &back {
                        out = s.on_frame(f.clone()).or(out);
                    }
                    st = out.unwrap();
                }
                ReplayKind::Sign => {
                    let other = p256::ecdsa::SigningKey::from_slice(&[0x44; 32]).unwrap();
                    let sg: p256::ecdsa::Signature = other.sign(&st.sign_input);
                    st = s.signed(sg.to_der().as_bytes().to_vec()).unwrap();
                }
                _ => break st,
            }
        };
        assert_eq!((end.next, end.replay_refused), (ReplayNext::Stop, true));
        assert_eq!(n.counted_failures(), 1);
        let mut busy = FakeNode::claimed(v.clone());
        busy.ops_busy = true;
        let (other_end, _) = attempt(&mut busy, &mut session(&v), &mut vec![]);
        assert!(!other_end.replay_refused, "a 7 is not a refusal");
    }
    // §3-2 / §4: `written` is set exactly when the claim/replay frames are handed over, and `lost()` after it is
    // "next round" with the write known to the caller (the 「請等幾分鐘」 words); before it, also next round.
    #[cfg(feature = "dev-trust")]
    #[test]
    fn written_flag_and_lost() {
        let v = vectors();
        let mut n = FakeNode::claimed(v.clone());
        let mut s = session(&v);
        assert_eq!(s.lost().next, ReplayNext::NoConnection, "no connection came up");
        let c = n.connect().unwrap();
        s.begin(FL as u32).unwrap();
        assert!(!s.written() && !s.decrypted());
        assert_eq!(s.lost().next, ReplayNext::NoConnection, "no msg2 yet");
        n.close(c);
        let c = n.connect().unwrap();
        let mut st = s.begin(FL as u32).unwrap();
        let mut seen_written_on = None;
        for i in 0..6 {
            match st.kind {
                ReplayKind::Write => {
                    if s.written() {
                        seen_written_on = Some(i);
                        break;
                    }
                    let Reply::Frames(back) = n.send(c, &st.frames) else { panic!() };
                    let mut out = None;
                    for f in &back {
                        out = s.on_frame(f.clone()).or(out);
                    }
                    st = out.unwrap();
                    assert!(s.decrypted(), "after msg2");
                }
                ReplayKind::Sign => {
                    assert!(!s.written(), "not before the signature");
                    st = s.signed(der(&st.sign_input)).unwrap();
                }
                _ => panic!("{}", st.detail),
            }
        }
        assert!(seen_written_on.is_some() && s.written());
        assert_eq!(s.lost().next, ReplayNext::Again);
        assert!(!s.written(), "a new connection starts unwritten");
    }

    // §2 / §4: the closing words — after a 9 s1 §5.1's, else s1 §5.2's; + 「請等幾分鐘」 when a replay went unanswered;
    // + the T3 sentence when this phone has a record of the node and its password may have changed
    #[test]
    fn closing_words() {
        assert_eq!(recovery_end_text(RecoveryEnd::Exhausted, true, false, false), TRY_REPLAY_TEXT);
        assert_eq!(recovery_end_text(RecoveryEnd::Exhausted, false, false, false), NOT_FOUND);
        assert_eq!(recovery_end_text(RecoveryEnd::Exhausted, false, true, false), format!("{NOT_FOUND}。{STILL_FINISHING}"));
        assert_eq!(recovery_end_text(RecoveryEnd::Exhausted, false, true, true), format!("{NOT_FOUND}。{STILL_FINISHING}。{OLD_RECORD_PW}"));
        assert_eq!(recovery_end_text(RecoveryEnd::Exhausted, false, false, true), NOT_FOUND, "nothing sent: the old password is fine");
        assert_eq!(recovery_end_text(RecoveryEnd::LockIncomplete, false, false, true), format!("{LOCK}。{OLD_RECORD_PW}"));
        assert_eq!(recovery_end_text(RecoveryEnd::LockIncomplete, false, false, false), LOCK);
        // review A-m1: a stop after an unanswered replay adds the same sentences (the caller says why it stopped)
        assert_eq!(recovery_end_text(RecoveryEnd::Stopped, false, false, true), "");
        assert_eq!(recovery_end_text(RecoveryEnd::Stopped, false, true, false), STILL_FINISHING);
        assert_eq!(recovery_end_text(RecoveryEnd::Stopped, false, true, true), format!("{STILL_FINISHING}。{OLD_RECORD_PW}"));
    }

    // S3: no text of a recovery (every step's detail, every end text, prepare's errors) carries K, z, psk_replay or a
    // password, in hex or as text. Negative control: the password put into the Recovered detail -> FAIL.
    #[cfg(feature = "dev-trust")]
    #[test]
    fn s3_no_secret_in_any_text() {
        let v = vectors();
        let p = pending(&v);
        let z = ecdh_x(&OWNER_ENC_PRIV, &p.ecdh_pub);
        let psk = batman_proto::kdf::psk_replay(&z, &p.device_id);
        let mut texts: Vec<String> = vec![];
        let mut pws = vec![];
        let sets: [&dyn Fn(&mut FakeNode); 6] = [
            &|_| {},
            &|n| n.cached_unclaimed = true,
            &|n| n.ops_busy = true,
            &|n| n.no_record = true,
            &|n| n.set_password = SetPassword::Fails { changed: true },
            &|n| n.defer_helper = true,
        ];
        for set in sets {
            let mut n = FakeNode::claimed(v.clone());
            set(&mut n);
            let mut s = session(&v);
            let (st, _) = attempt(&mut n, &mut s, &mut texts);
            texts.push(st.detail.clone());
            if n.defer_helper {
                n.finish_helper();
            }
            pws.push(n.password.clone());
        }
        for e in [RecoveryEnd::Exhausted, RecoveryEnd::LockIncomplete, RecoveryEnd::Stopped] {
            for (a, b, c) in [(false, false, false), (true, true, true), (false, true, true)] {
                texts.push(recovery_end_text(e, a, b, c));
            }
        }
        let mut bad = pending_plain(&v);
        bad.push(0);
        texts.extend(ReplaySession::prepare(bad, device_id(&v), false).err());
        texts.extend(ReplaySession::prepare(pending_plain(&v), "e61551410cfd538e25".into(), false).err());
        assert!(texts.iter().any(|t| t.contains("已恢復")), "the success text was looked at");
        assert!(pws.iter().any(|p| p == "pw-1"), "a password was made");
        let mut secrets: Vec<String> = vec![];
        for s in [p.k.to_vec(), z.to_vec(), psk.to_vec()] {
            secrets.push(hex::encode(&s));
            secrets.push(hex::encode_upper(&s));
            secrets.push(format!("{s:?}"));
        }
        secrets.extend(pws.iter().filter(|p| !p.is_empty()).cloned());
        for t in &texts {
            for s in &secrets {
                assert!(!t.contains(s.as_str()), "a secret in {t:?}");
            }
        }
    }

    // §8 field: built without dev-trust every entry refuses before doing anything, with §3-1's words (D7, Rust half)
    #[cfg(not(feature = "dev-trust"))]
    #[test]
    fn field_build_refuses_replay() {
        let v = vectors();
        assert_eq!(ReplaySession::prepare(pending_plain(&v), device_id(&v), false).err().as_deref(), Some(NOT_YET));
    }

    #[cfg(feature = "dev-trust")]
    #[test]
    fn dev_build_prepares_and_set_z_checks_its_length() {
        let v = vectors();
        let (mut s, peer) = ReplaySession::prepare(pending_plain(&v), device_id(&v), false).unwrap();
        assert_eq!(peer, pending(&v).ecdh_pub.to_vec());
        assert!(s.begin(FL as u32).is_err(), "no z yet: no msg1");
        assert!(s.set_z(vec![1; 31]).is_err());
        assert!(s.set_z(vec![1; 32]).is_ok());
    }
}
