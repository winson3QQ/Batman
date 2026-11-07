//! Signature inputs the platform (Android Keystore) signs, and the signature format the node accepts
//! (219-protocol.md §5, §7.1; node proto/proto.go:21-116). This crate never holds a long-term private key: it builds
//! the exact bytes to sign (each starting with its domain label — the Kotlin side's allow-list keys on these prefixes,
//! design 254-app-s1 §2) and turns the Keystore's DER signature into the raw low-s r‖s the node requires.

use p256::ecdsa::Signature;
use sha2::{Digest, Sha256};

use crate::cbor::{self, Value};

pub const LABEL_OWNER_ENC: &[u8] = b"batman-owner-enc-v1";
pub const LABEL_OWNER_AUTH: &[u8] = b"batman-owner-auth-v1";
pub const LABEL_OWNER_OP: &[u8] = b"batman-owner-op-v1";
/// envelope key for the owner-op inside a request body
pub const OWNER_OP_KEY: u64 = 31;

#[derive(Debug, PartialEq, Eq)]
pub enum Error {
    BadDer,
    VerbLength,
    BodyNotMap,
    BodyHasOwnerOp,
}

/// sig_enc input: "batman-owner-enc-v1" ‖ owner_enc_pub (65 B), signed with the owner key at claim/finish.
pub fn owner_enc_input(owner_enc_pub: &[u8; 65]) -> Vec<u8> {
    cat(&[LABEL_OWNER_ENC, owner_enc_pub])
}

/// owner_key_id = SHA-256(owner_pub 65 B).
pub fn owner_key_id(owner_pub: &[u8; 65]) -> [u8; 32] {
    Sha256::digest(owner_pub).into()
}

/// auth/owner input: "batman-owner-auth-v1" ‖ h ‖ owner_key_id.
pub fn auth_owner_input(h: &[u8; 32], owner_pub: &[u8; 65]) -> Vec<u8> {
    cat(&[LABEL_OWNER_AUTH, h, &owner_key_id(owner_pub)])
}

/// auth/owner request body: {1: owner_key_id, 2: sig}.
pub fn auth_owner_body(owner_pub: &[u8; 65], sig: &[u8; 64]) -> Value {
    Value::Map(vec![
        (Value::Uint(1), Value::Bytes(owner_key_id(owner_pub).to_vec())),
        (Value::Uint(2), Value::Bytes(sig.to_vec())),
    ])
}

/// args_hash = SHA-256(deterministic CBOR of the request body without key 31).
pub fn args_hash(body_without_op: &Value) -> Result<[u8; 32], Error> {
    match body_without_op {
        Value::Map(m) if m.iter().any(|(k, _)| *k == Value::Uint(OWNER_OP_KEY)) => Err(Error::BodyHasOwnerOp),
        Value::Map(_) => Ok(Sha256::digest(cbor::encode(body_without_op)).into()),
        _ => Err(Error::BodyNotMap),
    }
}

/// owner-op input: "batman-owner-op-v1" ‖ h ‖ nonce_helper ‖ u8(len(verb)) ‖ verb ‖ args_hash; the verb must equal the
/// envelope's type (node.go:665).
pub fn owner_op_input(h: &[u8; 32], nonce_helper: &[u8; 32], verb: &str, body_without_op: &Value) -> Result<Vec<u8>, Error> {
    let vb = verb.as_bytes();
    if vb.is_empty() || vb.len() > 255 {
        return Err(Error::VerbLength);
    }
    let ah = args_hash(body_without_op)?;
    Ok(cat(&[LABEL_OWNER_OP, h, nonce_helper, &[vb.len() as u8], vb, &ah]))
}

/// The body with key 31 = {1: verb, 2: sig} added.
pub fn with_owner_op(body_without_op: &Value, verb: &str, sig: &[u8; 64]) -> Result<Value, Error> {
    let Value::Map(m) = body_without_op else { return Err(Error::BodyNotMap) };
    if m.iter().any(|(k, _)| *k == Value::Uint(OWNER_OP_KEY)) {
        return Err(Error::BodyHasOwnerOp);
    }
    let mut m = m.clone();
    m.push((
        Value::Uint(OWNER_OP_KEY),
        Value::Map(vec![(Value::Uint(1), Value::Text(verb.into())), (Value::Uint(2), Value::Bytes(sig.to_vec()))]),
    ));
    Ok(Value::Map(m))
}

/// A request envelope {0: [1, 0], 1: id, 2: type, 3: body}. No key 7 (idempotency): P2 refuses it (session.go:614-619).
pub fn request(id: u64, verb: &str, body: Value) -> Vec<u8> {
    cbor::encode(&Value::Map(vec![
        (Value::Uint(0), Value::Array(vec![Value::Uint(1), Value::Uint(0)])),
        (Value::Uint(1), Value::Uint(id)),
        (Value::Uint(2), Value::Text(verb.into())),
        (Value::Uint(3), body),
    ]))
}

/// An owner-op request: the envelope type and the owner-op verb are the same `verb` by construction (the node refuses
/// a mismatch, node.go:665; vector owner_op.request_type_mismatch).
pub fn owner_op_request(id: u64, verb: &str, body_without_op: &Value, sig: &[u8; 64]) -> Result<Vec<u8>, Error> {
    Ok(request(id, verb, with_owner_op(body_without_op, verb, sig)?))
}

/// The Keystore's ECDSA output (ASN.1 DER) as the raw 64-byte r‖s the node requires, normalised to low-s
/// (s > n/2 -> n - s; the node refuses high-s, proto.go:116). r and s are left-padded to 32 bytes.
pub fn der_to_raw_low_s(der: &[u8]) -> Result<[u8; 64], Error> {
    let sig = Signature::from_der(der).map_err(|_| Error::BadDer)?;
    Ok(raw_low_s(&sig))
}

/// A raw r‖s (possibly high-s) normalised to low-s.
pub fn normalize_raw(raw: &[u8; 64]) -> Result<[u8; 64], Error> {
    let sig = Signature::from_slice(raw).map_err(|_| Error::BadDer)?;
    Ok(raw_low_s(&sig))
}

fn raw_low_s(sig: &Signature) -> [u8; 64] {
    let s = sig.normalize_s();
    let mut out = [0u8; 64];
    out.copy_from_slice(&s.to_bytes());
    out
}

/// true when s <= n/2 (the form the node accepts)
pub fn is_low_s(raw: &[u8; 64]) -> bool {
    match Signature::from_slice(raw) {
        Ok(sig) => sig.normalize_s() == sig,
        Err(_) => false,
    }
}

fn cat(parts: &[&[u8]]) -> Vec<u8> {
    parts.iter().flat_map(|p| p.iter().copied()).collect()
}
