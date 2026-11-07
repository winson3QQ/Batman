//! One claim attempt on one connection (design §5.1 steps 2-4), sans-IO: the caller writes the frames it is given,
//! feeds every received frame back, persists the claim-pending record when asked, and runs the timers (handshake 10 s,
//! idle 30 s, 55 s from begin to finish). No long-term private key is needed here: sig_enc (the owner key over
//! "batman-owner-enc-v1" || owner_enc_pub) is fixed per install, signed once by the platform, and passed in.
//!   msg1 -> msg2: verify node_cert (device_id == the QR's, the build's policy, sig_static over rs, sig_ecdh) ->
//!   PersistPending (the caller fsyncs it, then calls `pending_persisted`) -> claim/begin {1: owner_pub} -> nonce ->
//!   CheckMac response over this session's h -> claim/finish {1: response, 2: owner_enc_pub, 3: sig_enc} -> the reply's
//!   meaning (flow::claim_finish). Nothing is sent before the pending record is on disk.

use crate::cbor::Value;
use crate::conn::{self, Conn};
use crate::envelope::Outcome;
use crate::flow::{self, ClaimFinish};
use crate::frame::{self, Reassembler};
use crate::nodecert::{self, Policy};
use crate::{claim, noise};

pub struct Input {
    pub device_id: String,
    pub k: [u8; 32],
    pub owner_pub: [u8; 65],
    pub owner_enc_pub: [u8; 65],
    pub sig_enc: [u8; 64],
    pub policy: Policy,
    /// min(CTRL key 3, MTU - 3)
    pub frame_limit: usize,
}

/// The claim-pending record (design §3): written and synced BEFORE claim/finish can be sent.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Pending {
    pub device_id: String,
    pub k: [u8; 32],
    pub node_cert: Vec<u8>,
    pub dac_der: Vec<u8>,
    pub ecdh_pub: [u8; 65],
    pub owner_pub: [u8; 65],
    pub owner_enc_pub: [u8; 65],
}

#[derive(Debug, PartialEq)]
pub enum End {
    /// claim/finish answered: what it means (§5.1)
    Finished(ClaimFinish),
    /// msg2 did not decrypt (§5.0 row 2): disconnect, no conclusion
    Msg2Undecryptable,
    /// node_cert refused: disconnect, nothing written
    CertRejected(nodecert::Error),
    /// claim/begin refused: nothing was committed; the pending stays (§5.2 retries from NX)
    BeginRefused(Outcome),
    /// a malformed claim/begin answer, a frame or transport failure: the connection is gone; the pending stays and the
    /// outcome of a finish already sent is unknown (§5.1 "沒收到回應")
    Broken(String),
}

#[derive(Debug, PartialEq)]
pub enum Action {
    Write(Vec<Vec<u8>>),
    PersistPending(Pending),
    Done(End),
}

enum State {
    Hello { ini: noise::Initiator, rx: Reassembler },
    Persist { conn: Conn, pending: Pending, sn: [u8; 9] },
    Begin { conn: Conn, pending: Pending, sn: [u8; 9] },
    Finish { conn: Conn },
    Over,
}

pub struct Claim {
    input: Input,
    st: State,
}

impl Claim {
    /// The attempt and its first action: the msg1 frames.
    pub fn start(input: Input) -> (Claim, Action) {
        let ini = noise::Initiator::new(noise::Mode::Nx, Some(&input.device_id), None);
        let frames = ini.and_then(|mut i| i.msg1().map(|m| (i, m)));
        match frames {
            Ok((ini, m1)) => match frame::split(&m1, input.frame_limit) {
                Ok(f) => {
                    let rx = Reassembler::new(input.frame_limit, conn::MAX_MESSAGE);
                    (Claim { input, st: State::Hello { ini, rx } }, Action::Write(f))
                }
                Err(e) => (Claim { input, st: State::Over }, Action::Done(End::Broken(format!("{e:?}")))),
            },
            Err(e) => (Claim { input, st: State::Over }, Action::Done(End::Broken(format!("{e:?}")))),
        }
    }

    fn end(&mut self, e: End) -> Option<Action> {
        self.st = State::Over;
        Some(Action::Done(e))
    }

    /// The caller has synced the pending record: claim/begin goes out.
    pub fn pending_persisted(&mut self) -> Option<Action> {
        match std::mem::replace(&mut self.st, State::Over) {
            State::Persist { mut conn, pending, sn } => {
                let body = Value::Map(vec![(Value::Uint(1), Value::Bytes(self.input.owner_pub.to_vec()))]);
                match conn.request("claim/begin", body) {
                    Ok((_, f)) => {
                        self.st = State::Begin { conn, pending, sn };
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
            State::Begin { mut conn, pending, sn } => match conn.on_frame(f) {
                Ok(None) => {
                    self.st = State::Begin { conn, pending, sn };
                    None
                }
                Ok(Some(o)) => self.on_begin(conn, &pending, &sn, o),
                Err(e) => self.end(End::Broken(format!("{e:?}"))),
            },
            State::Finish { mut conn } => match conn.on_frame(f) {
                Ok(None) => {
                    self.st = State::Finish { conn };
                    None
                }
                Ok(Some(o)) => self.end(End::Finished(flow::claim_finish(&o))),
                Err(e) => self.end(End::Broken(format!("{e:?}"))),
            },
            // a frame while waiting for the pending to be persisted, or after the end: the attempt is over
            State::Persist { .. } => self.end(End::Broken("frame before claim/begin".into())),
            State::Over => None,
        }
    }

    fn on_msg2(&mut self, ini: noise::Initiator, m2: &[u8]) -> Option<Action> {
        let (cert, s) = match ini.read_msg2(m2) {
            Ok(x) => x,
            Err(noise::Error::Msg2NotDecryptable) => return self.end(End::Msg2Undecryptable),
            Err(e) => return self.end(End::Broken(format!("{e:?}"))),
        };
        let v = match nodecert::verify_first_contact(&cert, &s.rs, &self.input.device_id, self.input.policy) {
            Ok(v) => v,
            Err(e) => return self.end(End::CertRejected(e)),
        };
        let sn = v.sn;
        let pending = Pending {
            device_id: v.device_id,
            k: self.input.k,
            node_cert: cert,
            dac_der: v.dac_der,
            ecdh_pub: v.ecdh_pub,
            owner_pub: self.input.owner_pub,
            owner_enc_pub: self.input.owner_enc_pub,
        };
        let conn = Conn::new(s, self.input.frame_limit);
        self.st = State::Persist { conn, pending: pending.clone(), sn };
        Some(Action::PersistPending(pending))
    }

    fn on_begin(&mut self, mut conn: Conn, p: &Pending, sn: &[u8; 9], o: Outcome) -> Option<Action> {
        let nonce: [u8; 32] = match &o {
            Outcome::Ok(b) => match b.get(1).and_then(Value::as_bytes).and_then(|n| n.try_into().ok()) {
                Some(n) => n,
                None => return self.end(End::Broken("claim/begin answer without a 32-byte nonce".into())),
            },
            Outcome::Err { .. } => return self.end(End::BeginRefused(o)),
        };
        let response = claim::response(&p.k, &nonce, &conn.h(), &p.dac_der, &p.owner_pub, sn);
        let body = Value::Map(vec![
            (Value::Uint(1), Value::Bytes(response.to_vec())),
            (Value::Uint(2), Value::Bytes(p.owner_enc_pub.to_vec())),
            (Value::Uint(3), Value::Bytes(self.input.sig_enc.to_vec())),
        ]);
        match conn.request("claim/finish", body) {
            Ok((_, f)) => {
                self.st = State::Finish { conn };
                Some(Action::Write(f))
            }
            Err(e) => self.end(End::Broken(format!("{e:?}"))),
        }
    }
}
