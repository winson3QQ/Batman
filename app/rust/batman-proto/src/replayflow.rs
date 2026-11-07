//! One recovery attempt with a claim-pending record (design §5.2 step 2), sans-IO. Two private-key operations happen
//! on the platform (Keystore) and are asked for as actions; their results are fed back:
//!   Ecdh{peer = pending.ecdh_pub (sig_ecdh-verified at claim)} -> z -> psk_replay = HKDF(z, device_id) ->
//!   NXpsk0 msg1 -> msg2: node_cert with the DAC pinned in the pending -> claim/begin {1: owner_pub} -> nonce ->
//!   op/nonce -> nonce_helper -> CheckMac response over THIS session's nonce and h ->
//!   Sign{owner-op input "batman-owner-op-v1" ‖ h ‖ nonce_helper ‖ "claim/replay" ‖ args_hash({1: response})} ->
//!   claim/replay {1: response, 31: {1: "claim/replay", 2: sig}} -> flow::claim_replay.
//! A msg2 that does not decrypt is the normal answer while provd's cached state is stale (§5.1: the caller waits
//! ≥ 15 s and retries, 3 times) — never a verdict.

use crate::cbor::Value;
use crate::claimflow::Pending;
use crate::conn::{self, Conn};
use crate::envelope::Outcome;
use crate::flow::{self, ClaimReplay};
use crate::frame::{self, Reassembler};
use crate::{claim, kdf, nodecert, noise, sig};

#[derive(Debug, PartialEq)]
pub enum End {
    Replayed(ClaimReplay),
    Msg2Undecryptable,
    CertRejected(nodecert::Error),
    /// claim/begin or op/nonce refused (nothing replayed)
    Refused { verb: &'static str, outcome: Outcome },
    Broken(String),
}

#[derive(Debug, PartialEq)]
pub enum Action {
    /// ECDH(owner_enc private key, peer) on the platform; feed the 32-byte x coordinate to `ecdh_done`
    Ecdh { peer: [u8; 65] },
    Write(Vec<Vec<u8>>),
    /// the owner signing key over `input` (prefix batman-owner-op-v1); feed the Keystore's DER signature to `signed`
    Sign { input: Vec<u8> },
    Done(End),
}

enum State {
    Ecdh,
    Hello { ini: noise::Initiator, rx: Reassembler },
    Begin { conn: Conn, sn: [u8; 9] },
    OpNonce { conn: Conn, sn: [u8; 9], nonce: [u8; 32] },
    Sign { conn: Conn, body: Value },
    Replay { conn: Conn },
    Over,
}

pub struct Replay {
    p: Pending,
    frame_limit: usize,
    st: State,
}

fn nonce_of(o: &Outcome) -> Option<[u8; 32]> {
    match o {
        Outcome::Ok(b) => b.get(1).and_then(Value::as_bytes).and_then(|n| n.try_into().ok()),
        Outcome::Err { .. } => None,
    }
}

impl Replay {
    pub fn start(p: Pending, frame_limit: usize) -> (Replay, Action) {
        let peer = p.ecdh_pub;
        (Replay { p, frame_limit, st: State::Ecdh }, Action::Ecdh { peer })
    }

    fn end(&mut self, e: End) -> Option<Action> {
        self.st = State::Over;
        Some(Action::Done(e))
    }

    pub fn ecdh_done(&mut self, mut z: [u8; 32]) -> Option<Action> {
        if !matches!(self.st, State::Ecdh) {
            return None;
        }
        let mut psk = kdf::psk_replay(&z, &self.p.device_id);
        z.iter_mut().for_each(|b| *b = 0);
        let r = noise::Initiator::new(noise::Mode::NxPsk0, None, Some(&psk)).and_then(|mut i| i.msg1().map(|m| (i, m)));
        psk.iter_mut().for_each(|b| *b = 0);
        let (ini, m1) = match r {
            Ok(x) => x,
            Err(e) => return self.end(End::Broken(format!("{e:?}"))),
        };
        match frame::split(&m1, self.frame_limit) {
            Ok(f) => {
                self.st = State::Hello { ini, rx: Reassembler::new(self.frame_limit, conn::MAX_MESSAGE) };
                Some(Action::Write(f))
            }
            Err(e) => self.end(End::Broken(format!("{e:?}"))),
        }
    }

    pub fn signed(&mut self, der: &[u8]) -> Option<Action> {
        match std::mem::replace(&mut self.st, State::Over) {
            State::Sign { mut conn, body } => {
                let s = match sig::der_to_raw_low_s(der) {
                    Ok(s) => s,
                    Err(e) => return self.end(End::Broken(format!("{e:?}"))),
                };
                let full = match sig::with_owner_op(&body, "claim/replay", &s) {
                    Ok(b) => b,
                    Err(e) => return self.end(End::Broken(format!("{e:?}"))),
                };
                match conn.request("claim/replay", full) {
                    Ok((_, f)) => {
                        self.st = State::Replay { conn };
                        Some(Action::Write(f))
                    }
                    Err(e) => self.end(End::Broken(format!("{e:?}"))),
                }
            }
            other => {
                self.st = other;
                None
            }
        }
    }

    fn send(&mut self, mut conn: Conn, verb: &str, body: Value, next: impl FnOnce(Conn) -> State) -> Option<Action> {
        match conn.request(verb, body) {
            Ok((_, f)) => {
                self.st = next(conn);
                Some(Action::Write(f))
            }
            Err(e) => self.end(End::Broken(format!("{e:?}"))),
        }
    }

    pub fn on_frame(&mut self, f: &[u8]) -> Option<Action> {
        match std::mem::replace(&mut self.st, State::Over) {
            State::Hello { ini, mut rx } => match rx.push(f) {
                Ok(None) => {
                    self.st = State::Hello { ini, rx };
                    None
                }
                Ok(Some(m2)) => self.on_msg2(ini, &m2),
                Err(e) => self.end(End::Broken(format!("{e:?}"))),
            },
            State::Begin { conn, sn } => self.step(conn, f, move |c| State::Begin { conn: c, sn }, move |s, c, o| s.on_begin(c, sn, o)),
            State::OpNonce { conn, sn, nonce } => {
                self.step(conn, f, move |c| State::OpNonce { conn: c, sn, nonce }, move |s, c, o| s.on_op_nonce(c, sn, nonce, o))
            }
            State::Replay { conn } => {
                self.step(conn, f, |c| State::Replay { conn: c }, |s, _, o| s.end(End::Replayed(flow::claim_replay(&o))))
            }
            // a frame while a platform operation is pending
            State::Ecdh | State::Sign { .. } => self.end(End::Broken("unexpected frame".into())),
            State::Over => None,
        }
    }

    fn step(
        &mut self,
        mut conn: Conn,
        f: &[u8],
        keep: impl FnOnce(Conn) -> State,
        done: impl FnOnce(&mut Self, Conn, Outcome) -> Option<Action>,
    ) -> Option<Action> {
        match conn.on_frame(f) {
            Ok(None) => {
                self.st = keep(conn);
                None
            }
            Ok(Some(o)) => done(self, conn, o),
            Err(e) => self.end(End::Broken(format!("{e:?}"))),
        }
    }

    fn on_msg2(&mut self, ini: noise::Initiator, m2: &[u8]) -> Option<Action> {
        let (cert, s) = match ini.read_msg2(m2) {
            Ok(x) => x,
            Err(noise::Error::Msg2NotDecryptable) => return self.end(End::Msg2Undecryptable),
            Err(e) => return self.end(End::Broken(format!("{e:?}"))),
        };
        let v = match nodecert::verify_pinned(&cert, &s.rs, &self.p.dac_der) {
            Ok(v) => v,
            Err(e) => return self.end(End::CertRejected(e)),
        };
        let conn = Conn::new(s, self.frame_limit);
        let body = Value::Map(vec![(Value::Uint(1), Value::Bytes(self.p.owner_pub.to_vec()))]);
        let sn = v.sn;
        self.send(conn, "claim/begin", body, move |c| State::Begin { conn: c, sn })
    }

    fn on_begin(&mut self, conn: Conn, sn: [u8; 9], o: Outcome) -> Option<Action> {
        let Some(nonce) = nonce_of(&o) else {
            return match o {
                Outcome::Err { .. } => self.end(End::Refused { verb: "claim/begin", outcome: o }),
                Outcome::Ok(_) => self.end(End::Broken("claim/begin answer without a 32-byte nonce".into())),
            };
        };
        self.send(conn, "op/nonce", Value::Map(vec![]), move |c| State::OpNonce { conn: c, sn, nonce })
    }

    fn on_op_nonce(&mut self, conn: Conn, sn: [u8; 9], nonce: [u8; 32], o: Outcome) -> Option<Action> {
        let Some(nonce_helper) = nonce_of(&o) else {
            return match o {
                Outcome::Err { .. } => self.end(End::Refused { verb: "op/nonce", outcome: o }),
                Outcome::Ok(_) => self.end(End::Broken("op/nonce answer without a 32-byte nonce".into())),
            };
        };
        let h = conn.h();
        let response = claim::response(&self.p.k, &nonce, &h, &self.p.dac_der, &self.p.owner_pub, &sn);
        let body = Value::Map(vec![(Value::Uint(1), Value::Bytes(response.to_vec()))]);
        match sig::owner_op_input(&h, &nonce_helper, "claim/replay", &body) {
            Ok(input) => {
                self.st = State::Sign { conn, body };
                Some(Action::Sign { input })
            }
            Err(e) => self.end(End::Broken(format!("{e:?}"))),
        }
    }
}
