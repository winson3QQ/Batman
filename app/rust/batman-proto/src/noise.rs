//! Noise handshakes, the phone as initiator (219-protocol.md §3; node: provd/noise.go):
//! - unclaimed / legacy node: `Noise_NX_25519_ChaChaPoly_SHA256`, prologue `"batman-prov/1\0ble\0" ‖ device_id`
//! - claimed / member node: `Noise_NXpsk0_25519_ChaChaPoly_SHA256`, prologue `"batman-prov/1\0ble\0"`, psk = psk_owner
//!   (owner login) or psk_replay (recovery).
//!
//! The phone has no static key (N): only an ephemeral, generated here per connection. msg1 carries an empty payload,
//! msg2 carries the node_cert (verified by the caller BEFORE anything is sent). The handshake hash `h` is the channel
//! binding used in ClientChal / owner-op / auth-owner inputs. Any decryption failure is fatal (no retry on the same
//! session): a wrong PSK or a mode mismatch yields the node's equal-length fake msg2, which does not decrypt.

use snow::{Builder, HandshakeState, TransportState};

pub const PROLOGUE_BASE: &[u8] = b"batman-prov/1\0ble\0";
/// largest Noise message (snow refuses more than 65535 B)
pub const MAX_MSG: usize = 65535;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Mode {
    /// unclaimed / legacy node; the prologue carries the full device id from the QR
    Nx,
    /// claimed / member node with a 32-byte PSK
    NxPsk0,
}

#[derive(Debug, PartialEq, Eq)]
pub enum Error {
    /// msg2 did not decrypt: wrong PSK, mode mismatch (the node's fake msg2), or a different node / prologue
    Msg2NotDecryptable,
    Protocol(String),
}

impl From<snow::Error> for Error {
    fn from(e: snow::Error) -> Self {
        Error::Protocol(e.to_string())
    }
}

fn params(mode: Mode) -> snow::params::NoiseParams {
    match mode {
        Mode::Nx => "Noise_NX_25519_ChaChaPoly_SHA256",
        Mode::NxPsk0 => "Noise_NXpsk0_25519_ChaChaPoly_SHA256",
    }
    .parse()
    .expect("static protocol name")
}

/// The prologue for `mode`: unclaimed nodes bind the full device id, claimed nodes an empty hint (server.go:680-702).
pub fn prologue(mode: Mode, device_id: Option<&str>) -> Vec<u8> {
    let mut p = PROLOGUE_BASE.to_vec();
    if mode == Mode::Nx {
        p.extend(device_id.unwrap_or("").as_bytes());
    }
    p
}

/// The initiator's handshake: `msg1()`, then `read_msg2()` -> (node_cert payload, handshake hash) and a transport.
pub struct Initiator {
    hs: HandshakeState,
}

/// The established session: encrypt requests, decrypt responses. `h` is the handshake hash; `rs` the node's static
/// key from msg2, which node_cert must bind (sig_static).
pub struct Session {
    pub h: [u8; 32],
    pub rs: [u8; 32],
    t: TransportState,
}

impl Initiator {
    /// A fresh ephemeral key per connection. `psk` is required for NXpsk0 and ignored for NX.
    pub fn new(mode: Mode, device_id: Option<&str>, psk: Option<&[u8; 32]>) -> Result<Self, Error> {
        Self::build(mode, device_id, psk, None)
    }

    /// Test vectors only: a fixed ephemeral private key so msg1 is byte-exact. Not compiled into a release build.
    #[cfg(feature = "test-vectors")]
    #[doc(hidden)]
    pub fn with_fixed_ephemeral_for_vectors(
        mode: Mode,
        device_id: Option<&str>,
        psk: Option<&[u8; 32]>,
        eph: &[u8; 32],
    ) -> Result<Self, Error> {
        Self::build(mode, device_id, psk, Some(eph))
    }

    fn build(mode: Mode, device_id: Option<&str>, psk: Option<&[u8; 32]>, _eph: Option<&[u8; 32]>) -> Result<Self, Error> {
        let pro = prologue(mode, device_id);
        let mut b = Builder::new(params(mode)).prologue(&pro)?;
        if mode == Mode::NxPsk0 {
            let k = psk.ok_or_else(|| Error::Protocol("NXpsk0 needs a psk".into()))?;
            b = b.psk(0, k)?;
        }
        #[cfg(feature = "test-vectors")]
        if let Some(e) = _eph {
            b = b.fixed_ephemeral_key_for_testing_only(e);
        }
        Ok(Initiator { hs: b.build_initiator()? })
    }

    /// msg1: the initiator's ephemeral (and, for NXpsk0, the psk-mixed empty payload tag): 32 B for NX, 48 B for NXpsk0.
    pub fn msg1(&mut self) -> Result<Vec<u8>, Error> {
        let mut buf = vec![0u8; MAX_MSG];
        let n = self.hs.write_message(&[], &mut buf)?;
        buf.truncate(n);
        Ok(buf)
    }

    /// Reads msg2; returns the payload (the node_cert, to be verified by the caller) and the established session.
    pub fn read_msg2(mut self, msg2: &[u8]) -> Result<(Vec<u8>, Session), Error> {
        let mut buf = vec![0u8; MAX_MSG];
        let n = self.hs.read_message(msg2, &mut buf).map_err(|_| Error::Msg2NotDecryptable)?;
        buf.truncate(n);
        if !self.hs.is_handshake_finished() {
            return Err(Error::Protocol("handshake not finished after msg2".into()));
        }
        let hh = self.hs.get_handshake_hash();
        let h: [u8; 32] = hh.try_into().map_err(|_| Error::Protocol("handshake hash is not 32 bytes".into()))?;
        let rs: [u8; 32] = self
            .hs
            .get_remote_static()
            .and_then(|r| r.try_into().ok())
            .ok_or_else(|| Error::Protocol("no 32-byte remote static after msg2".into()))?;
        Ok((buf, Session { h, rs, t: self.hs.into_transport_mode()? }))
    }
}

impl Session {
    pub fn encrypt(&mut self, plaintext: &[u8]) -> Result<Vec<u8>, Error> {
        let mut buf = vec![0u8; MAX_MSG];
        let n = self.t.write_message(plaintext, &mut buf)?;
        buf.truncate(n);
        Ok(buf)
    }

    /// A decryption failure ends the session (the node closes on any AEAD failure, session.go:312-322).
    pub fn decrypt(&mut self, ciphertext: &[u8]) -> Result<Vec<u8>, Error> {
        let mut buf = vec![0u8; MAX_MSG];
        let n = self.t.read_message(ciphertext, &mut buf)?;
        buf.truncate(n);
        Ok(buf)
    }
}
