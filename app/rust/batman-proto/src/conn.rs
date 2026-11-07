//! One established connection after the handshake (219-protocol.md §4; node S/provd/session.go, frame.go):
//! a request goes out as envelope -> Noise transport message(s) -> GATT frames; frames come back -> one Noise message ->
//! the response to the ONE outstanding request. Ids increase from 1 (session.go:440-501). Every error closes the
//! connection for good (fail-closed, as the node does: session.go:199-225, 312-322); the caller opens a new one.

use crate::cbor::Value;
use crate::envelope::{self, Outcome};
use crate::frame::{self, Reassembler};
use crate::noise;

/// The largest Noise message either side sends (CTRL key 4 = 8192, S/provd/server.go:556-559).
pub const MAX_MESSAGE: usize = 8192;
/// The node closes a session after 2^20 messages (session.go:312-322); the phone stops before.
pub const MAX_MESSAGES: u64 = 1 << 20;

#[derive(Debug, PartialEq, Eq)]
pub enum Error {
    Frame(frame::Error),
    Noise(noise::Error),
    Envelope(envelope::Error),
    /// a request while another one is outstanding (S1 sends one at a time); the connection stays usable
    Busy,
    /// a message from the node with no request outstanding
    Unsolicited,
    /// the connection was closed by an earlier error
    Closed,
    MessageLimit,
}

pub struct Conn {
    s: noise::Session,
    frame_limit: usize,
    rx: Reassembler,
    next_id: u64,
    outstanding: Option<u64>,
    sent: u64,
    closed: bool,
}

impl Conn {
    /// `frame_limit`: min(CTRL key 3, MTU - 3) as negotiated (bluez.go:384-391).
    pub fn new(s: noise::Session, frame_limit: usize) -> Self {
        Conn { s, frame_limit, rx: Reassembler::new(frame_limit, MAX_MESSAGE), next_id: 1, outstanding: None, sent: 0, closed: false }
    }

    /// The handshake hash: the channel binding for ClientChal / owner-op / auth-owner inputs.
    pub fn h(&self) -> [u8; 32] {
        self.s.h
    }

    pub fn is_closed(&self) -> bool {
        self.closed
    }

    fn fail<T>(&mut self, e: Error) -> Result<T, Error> {
        self.closed = true;
        Err(e)
    }

    /// The frames to write for `verb` / `body`, and the request's id.
    pub fn request(&mut self, verb: &str, body: Value) -> Result<(u64, Vec<Vec<u8>>), Error> {
        if self.closed {
            return Err(Error::Closed);
        }
        if self.outstanding.is_some() {
            return Err(Error::Busy);
        }
        let id = self.next_id;
        let msgs = match envelope::split_request(id, verb, body, MAX_MESSAGE) {
            Ok(m) => m,
            Err(e) => return self.fail(Error::Envelope(e)),
        };
        if self.sent + msgs.len() as u64 > MAX_MESSAGES {
            return self.fail(Error::MessageLimit);
        }
        let mut frames = Vec::new();
        for m in &msgs {
            let ct = match self.s.encrypt(m) {
                Ok(c) => c,
                Err(e) => return self.fail(Error::Noise(e)),
            };
            match frame::split(&ct, self.frame_limit) {
                Ok(f) => frames.extend(f),
                Err(e) => return self.fail(Error::Frame(e)),
            }
        }
        self.sent += msgs.len() as u64;
        self.next_id += 1;
        self.outstanding = Some(id);
        Ok((id, frames))
    }

    /// Feed one received frame; Some(outcome) when it completes the response to the outstanding request.
    pub fn on_frame(&mut self, f: &[u8]) -> Result<Option<Outcome>, Error> {
        if self.closed {
            return Err(Error::Closed);
        }
        let msg = match self.rx.push(f) {
            Ok(Some(m)) => m,
            Ok(None) => return Ok(None),
            Err(e) => return self.fail(Error::Frame(e)),
        };
        let Some(id) = self.outstanding else { return self.fail(Error::Unsolicited) };
        let pt = match self.s.decrypt(&msg) {
            Ok(p) => p,
            Err(e) => return self.fail(Error::Noise(e)),
        };
        match envelope::parse_response(&pt, id) {
            Ok(o) => {
                self.outstanding = None;
                Ok(Some(o))
            }
            Err(e) => self.fail(Error::Envelope(e)),
        }
    }
}
