//! Owner login to one of this phone's nodes (design §5.3), sans-IO:
//!   psk_owner = HKDF(owner_tag_key, device_id) -> NXpsk0 (empty hint) -> msg2: node_cert with the DAC pinned in the
//!   node record (another DAC -> disconnect and warn) -> Sign{"batman-owner-auth-v1" ‖ h ‖ owner_key_id} on the
//!   platform -> auth/owner {1: owner_key_id, 2: sig} -> {} (P2 sends an empty body, facts §7) -> the connection, now
//!   an owner session, is handed back with `into_conn` for info / op/nonce / network/join.
//! A msg2 that does not decrypt means "not this node, or its PSK set not reloaded yet" (§5.3: right after a claim the
//! caller retries 3 times, 3 s apart) — never a verdict. The candidate loop and the handshake budget are the caller's.

use crate::conn::{self, Conn};
use crate::envelope::Outcome;
use crate::frame::{self, Reassembler};
use crate::{kdf, nodecert, noise, sig};

/// What login needs from the node record (design §3).
pub struct NodeRecord<'a> {
    pub device_id: &'a str,
    pub owner_tag_key: &'a [u8; 32],
    pub pinned_dac_der: &'a [u8],
    pub owner_pub: &'a [u8; 65],
}

#[derive(Debug, PartialEq)]
pub enum End {
    /// an owner session: take it with `into_conn`
    LoggedIn,
    Msg2Undecryptable,
    /// the PSK opened but the DAC is not the pinned one: disconnect and warn the user
    CertRejected(nodecert::Error),
    AuthRefused(Outcome),
    Broken(String),
}

#[derive(Debug, PartialEq)]
pub enum Action {
    Write(Vec<Vec<u8>>),
    /// the owner signing key over `input` (prefix batman-owner-auth-v1); feed the DER to `signed`
    Sign { input: Vec<u8> },
    Done(End),
}

enum State {
    Hello { ini: noise::Initiator, rx: Reassembler },
    Sign { conn: Conn },
    Auth { conn: Conn },
    LoggedIn { conn: Conn },
    Over,
}

pub struct Login {
    owner_pub: [u8; 65],
    pinned: Vec<u8>,
    frame_limit: usize,
    st: State,
    /// the node_cert verified against the pinned DAC in this handshake (§5.4: net_secrets go to its ecdh_pub)
    verified: Option<nodecert::Verified>,
    /// that node_cert's bytes, kept only once verify_pinned passed (a join request carries them, member-join §2)
    node_cert_raw: Option<Vec<u8>>,
}

impl Login {
    pub fn start(rec: &NodeRecord, frame_limit: usize) -> (Login, Action) {
        let mut psk = kdf::psk_owner(rec.owner_tag_key, rec.device_id);
        let r = noise::Initiator::new(noise::Mode::NxPsk0, None, Some(&psk)).and_then(|mut i| i.msg1().map(|m| (i, m)));
        psk.iter_mut().for_each(|b| *b = 0);
        let mut l =
            Login {
            owner_pub: *rec.owner_pub,
            pinned: rec.pinned_dac_der.to_vec(),
            frame_limit,
            st: State::Over,
            verified: None,
            node_cert_raw: None,
        };
        let a = match r.map_err(|e| format!("{e:?}")).and_then(|(i, m)| frame::split(&m, frame_limit).map(|f| (i, f)).map_err(|e| format!("{e:?}"))) {
            Ok((ini, f)) => {
                l.st = State::Hello { ini, rx: Reassembler::new(frame_limit, conn::MAX_MESSAGE) };
                Action::Write(f)
            }
            Err(e) => Action::Done(End::Broken(e)),
        };
        (l, a)
    }

    /// The owner session after `End::LoggedIn`.
    /// The node_cert verified in this handshake (pinned DAC, sig_ecdh): its dac_pub / ecdh_pub. None before msg2.
    pub fn verified(&self) -> Option<&nodecert::Verified> {
        self.verified.as_ref()
    }

    /// The raw node_cert of this handshake; None unless it verified against the pinned DAC.
    pub fn node_cert_raw(&self) -> Option<&[u8]> {
        self.node_cert_raw.as_deref()
    }

    pub fn into_conn(self) -> Option<Conn> {
        match self.st {
            State::LoggedIn { conn } => Some(conn),
            _ => None,
        }
    }

    fn end(&mut self, e: End) -> Option<Action> {
        self.st = State::Over;
        Some(Action::Done(e))
    }

    pub fn signed(&mut self, der: &[u8]) -> Option<Action> {
        match std::mem::replace(&mut self.st, State::Over) {
            State::Sign { mut conn } => {
                let s = match sig::der_to_raw_low_s(der) {
                    Ok(s) => s,
                    Err(e) => return self.end(End::Broken(format!("{e:?}"))),
                };
                match conn.request("auth/owner", sig::auth_owner_body(&self.owner_pub, &s)) {
                    Ok((_, f)) => {
                        self.st = State::Auth { conn };
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
            State::Auth { mut conn } => match conn.on_frame(f) {
                Ok(None) => {
                    self.st = State::Auth { conn };
                    None
                }
                Ok(Some(Outcome::Ok(_))) => {
                    self.st = State::LoggedIn { conn };
                    Some(Action::Done(End::LoggedIn))
                }
                Ok(Some(o)) => self.end(End::AuthRefused(o)),
                Err(e) => self.end(End::Broken(format!("{e:?}"))),
            },
            State::Sign { .. } => self.end(End::Broken("unexpected frame".into())),
            // after login the caller drives the connection itself; earlier ends ignore frames
            s @ (State::LoggedIn { .. } | State::Over) => {
                self.st = s;
                None
            }
        }
    }

    fn on_msg2(&mut self, ini: noise::Initiator, m2: &[u8]) -> Option<Action> {
        let (cert, s) = match ini.read_msg2(m2) {
            Ok(x) => x,
            Err(noise::Error::Msg2NotDecryptable) => return self.end(End::Msg2Undecryptable),
            Err(e) => return self.end(End::Broken(format!("{e:?}"))),
        };
        match nodecert::verify_pinned(&cert, &s.rs, &self.pinned) {
            Ok(v) => {
                self.verified = Some(v);
                self.node_cert_raw = Some(cert.clone());
            }
            Err(e) => return self.end(End::CertRejected(e)),
        }
        let conn = Conn::new(s, self.frame_limit);
        let input = sig::auth_owner_input(&conn.h(), &self.owner_pub);
        self.st = State::Sign { conn };
        Some(Action::Sign { input })
    }
}
