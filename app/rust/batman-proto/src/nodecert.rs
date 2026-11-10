//! node_cert verification, done on msg2's payload BEFORE any request is sent (219-protocol.md §3.3, design
//! 254-app-s1 §5.1 / §6; reference: tests/tools/peer/nodecert.py).
//!
//! node_cert = {1: [DAC DER, ...], 2: s_node_pub (32), 3: boot_id, 4: ecdh_pub (65), 5: sig_static (64), 6: sig_ecdh (64),
//! 7: sn (9)} (provd server.go:291).
//!
//! Common checks: cert[2] == the handshake's remote static; sig_static = ES256_DAC("batman-node-static-v1" ‖ s_node ‖
//! boot_id); sig_ecdh = ES256_DAC("batman-node-ecdh-v1" ‖ ecdh_pub) (the ecdh_pub is later used for psk_replay and to
//! encrypt the network secrets — design §5.1 step 2); sn == the DAC subject serialNumber; device_id = hex(sn).
//! Then either the DAC equals the one pinned at claim time (a claimed node), or — first contact — device_id equals the
//! QR's and the DAC is accepted by the build's trust policy: today only the dev TOFU rule (CN "dev:<id>", id =
//! SHA-256(DAC pub)[:9], self-signed); a field build has no production root yet and rejects every dev certificate.

use crate::cbor::{self, Value};
use der::{Decode, Encode};
use p256::ecdsa::{signature::Verifier, Signature, VerifyingKey};
use sha2::{Digest, Sha256};
use x509_cert::Certificate;

pub const LABEL_STATIC: &[u8] = b"batman-node-static-v1";
pub const LABEL_ECDH: &[u8] = b"batman-node-ecdh-v1";
const OID_CN: &str = "2.5.4.3";
const OID_SERIAL_NUMBER: &str = "2.5.4.5";

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Error {
    Malformed(&'static str),
    StaticMismatch,
    SigStatic,
    SigEcdh,
    SnMismatch,
    DeviceIdMismatch,
    NotPinned,
    /// the dev TOFU rule failed (CN, id hash, or not self-signed) — e.g. a forged self-signed certificate
    DevRule(&'static str),
    /// this build accepts no such certificate (a field build and a dev certificate, or a production DAC without a root)
    Untrusted,
}

/// Whether this build accepts a self-signed `dev:` DAC on first contact: the `dev-trust` Cargo feature, fixed at
/// compile time (design §4.1 / §6: no runtime switch, nothing a caller across the Dart bridge can pass).
pub const DEV_TRUST: bool = cfg!(feature = "dev-trust");

/// The parts of a verified node_cert the caller keeps.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Verified {
    pub device_id: String,
    pub dac_der: Vec<u8>,
    pub dac_pub: [u8; 65],
    pub ecdh_pub: [u8; 65],
    pub sn: [u8; 9],
}

fn bytes<'a>(m: &'a Value, k: u64, what: &'static str) -> Result<&'a [u8], Error> {
    m.get(k).and_then(|v| v.as_bytes()).ok_or(Error::Malformed(what))
}

fn es256_verify(pub65: &[u8], msg: &[u8], sig64: &[u8]) -> bool {
    let (Ok(vk), Ok(sig)) = (VerifyingKey::from_sec1_bytes(pub65), Signature::from_slice(sig64)) else {
        return false;
    };
    vk.verify(msg, &sig).is_ok()
}

fn subject_attr(c: &Certificate, oid: &str) -> Option<String> {
    // x509-cert 0.3: Name::iter() yields every AttributeTypeAndValue of every RDN
    for atv in c.tbs_certificate().subject().iter() {
        if atv.oid.to_string() == oid {
            // PrintableString / UTF8String / IA5String: the content octets are the text
            return std::str::from_utf8(atv.value.value()).ok().map(str::to_owned);
        }
    }
    None
}

fn dac_pub65(c: &Certificate) -> Result<[u8; 65], Error> {
    let pk = c.tbs_certificate().subject_public_key_info().subject_public_key.raw_bytes();
    pk.try_into().map_err(|_| Error::Malformed("DAC public key is not a 65-byte P-256 point"))
}

/// Common checks; `remote_static` is the handshake's rs (32 B), None offline (verify_offline: no handshake, so only
/// freshness is lost).
fn common(node_cert: &[u8], remote_static: Option<&[u8; 32]>) -> Result<(Verified, Certificate), Error> {
    let m = cbor::decode(node_cert).map_err(|_| Error::Malformed("node_cert is not deterministic CBOR"))?;
    let chain = match m.get(1) {
        Some(Value::Array(a)) if !a.is_empty() => a,
        _ => return Err(Error::Malformed("no DAC chain")),
    };
    let dac_der = chain[0].as_bytes().ok_or(Error::Malformed("DAC is not a byte string"))?.to_vec();
    let c = Certificate::from_der(&dac_der).map_err(|_| Error::Malformed("DAC is not X.509 DER"))?;
    let dac_pub = dac_pub65(&c)?;
    let s_node = bytes(&m, 2, "s_node")?;
    let boot_id = bytes(&m, 3, "boot_id")?;
    let ecdh_pub: [u8; 65] = bytes(&m, 4, "ecdh_pub")?.try_into().map_err(|_| Error::Malformed("ecdh_pub is not 65 B"))?;
    let sig_static = bytes(&m, 5, "sig_static")?;
    let sig_ecdh = bytes(&m, 6, "sig_ecdh")?;
    let sn: [u8; 9] = bytes(&m, 7, "sn")?.try_into().map_err(|_| Error::Malformed("sn is not 9 B"))?;
    if remote_static.is_some_and(|rs| s_node != rs) {
        return Err(Error::StaticMismatch);
    }
    let mut msg = LABEL_STATIC.to_vec();
    msg.extend(s_node);
    msg.extend(boot_id);
    if !es256_verify(&dac_pub, &msg, sig_static) {
        return Err(Error::SigStatic);
    }
    let mut msg = LABEL_ECDH.to_vec();
    msg.extend(ecdh_pub);
    if !es256_verify(&dac_pub, &msg, sig_ecdh) {
        return Err(Error::SigEcdh);
    }
    let device_id = hex_lower(&sn);
    if subject_attr(&c, OID_SERIAL_NUMBER).as_deref() != Some(device_id.as_str()) {
        return Err(Error::SnMismatch);
    }
    Ok((Verified { device_id, dac_der, dac_pub, ecdh_pub, sn }, c))
}

/// A claimed node: the common checks and the DAC equal to the one pinned at claim time.
pub fn verify_pinned(node_cert: &[u8], remote_static: &[u8; 32], pinned_dac_der: &[u8]) -> Result<Verified, Error> {
    let (v, _) = common(node_cert, Some(remote_static))?;
    if v.dac_der != pinned_dac_der {
        return Err(Error::NotPinned);
    }
    Ok(v)
}

/// First contact (claim): the common checks, device_id == the QR's, and the build's trust policy (`DEV_TRUST`).
pub fn verify_first_contact(node_cert: &[u8], remote_static: &[u8; 32], qr_device_id: &str) -> Result<Verified, Error> {
    let (v, c) = common(node_cert, Some(remote_static))?;
    if v.device_id != qr_device_id {
        return Err(Error::DeviceIdMismatch);
    }
    trust_gate(&c, &v)?;
    Ok(v)
}

/// The build's trust policy on a DAC, shared by first contact and offline checks: a non-`dev:` DAC needs the
/// production root (none yet: Untrusted); a `dev:` DAC only in a dev-trust build, then the dev TOFU rule.
fn trust_gate(c: &Certificate, v: &Verified) -> Result<(), Error> {
    let cn = subject_attr(c, OID_CN).unwrap_or_default();
    if !cn.starts_with("dev:") {
        // a production DAC needs the production root, which does not exist yet (keystore.go:266-267)
        return Err(Error::Untrusted);
    }
    if !DEV_TRUST {
        return Err(Error::Untrusted);
    }
    dev_rule(c, &v.dac_pub, &v.device_id)
}

/// A node_cert met outside a handshake (a join request, 254-app-member-join §2): parsed strictly (unknown keys
/// refused, §5.6 signed-object rule for an embedded node_cert), sig_static / sig_ecdh / sn checked, and the same trust
/// gate as first contact. Only s_node == rs cannot be checked (freshness).
pub fn verify_offline(node_cert: &[u8]) -> Result<Verified, Error> {
    let m = cbor::decode(node_cert).map_err(|_| Error::Malformed("node_cert is not deterministic CBOR"))?;
    let Value::Map(e) = &m else { return Err(Error::Malformed("node_cert is not a map")) };
    if e.len() != 7 || !(1..=7).all(|k| m.get(k).is_some()) {
        return Err(Error::Malformed("node_cert keys are not exactly 1-7"));
    }
    let (v, c) = common(node_cert, None)?;
    trust_gate(&c, &v)?;
    Ok(v)
}

/// The dev TOFU rule on a DAC: CN == "dev:<device_id>", device_id == hex(SHA-256(DAC pub)[:9]), self-signed.
pub fn dev_rule(c: &Certificate, dac_pub: &[u8; 65], device_id: &str) -> Result<(), Error> {
    if subject_attr(c, OID_CN).as_deref() != Some(format!("dev:{device_id}").as_str()) {
        return Err(Error::DevRule("CN is not dev:<device_id>"));
    }
    if hex_lower(&Sha256::digest(dac_pub)[..9]) != device_id {
        return Err(Error::DevRule("device_id is not SHA-256(DAC pub)[:9]"));
    }
    let tbs = c.tbs_certificate().to_der().map_err(|_| Error::Malformed("tbsCertificate"))?;
    let sig = Signature::from_der(c.signature().raw_bytes()).map_err(|_| Error::DevRule("signature is not ECDSA DER"))?;
    let vk = VerifyingKey::from_sec1_bytes(dac_pub).map_err(|_| Error::Malformed("DAC public key"))?;
    vk.verify(&tbs, &sig).map_err(|_| Error::DevRule("not self-signed"))
}

/// Parses a DER certificate (for callers that hold one outside a node_cert, e.g. a pinned DAC or a test fixture).
pub fn parse(der: &[u8]) -> Result<Certificate, Error> {
    Certificate::from_der(der).map_err(|_| Error::Malformed("not X.509 DER"))
}

pub fn hex_lower(b: &[u8]) -> String {
    b.iter().map(|x| format!("{x:02x}")).collect()
}
