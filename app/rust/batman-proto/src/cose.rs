//! COSE objects for network/join (219-protocol.md §7; node cose/cose.go:36-211, node.go:960-1030, wtxn.go:126-152):
//! - COSE_Sign1 (tag 18): protected exactly {1: -7, 3: content type}, unprotected {}, external_aad = the type's label.
//!   This crate builds the Sig_structure the admin key signs (on the platform) and assembles the signed object.
//! - net_secrets: Sign1 over {1: net_id, 2: version, 3: SHA-256(DAC pub), 4: COSE_Encrypt}; the COSE_Encrypt (tag 96)
//!   is ECDH-ES (-25) to the node's sig_ecdh-verified ecdh_pub: an EPHEMERAL P-256 key generated here (design §2: the
//!   one private-key operation in Rust — ephemeral, never stored, zeroised), HKDF-SHA256 over the KDF context, then
//!   ChaCha20-Poly1305 (alg 24) with a random 12-byte IV.

use chacha20poly1305::aead::{Aead, KeyInit, Payload};
use chacha20poly1305::{ChaCha20Poly1305, Key, Nonce};
use p256::elliptic_curve::sec1::ToSec1Point;
use p256::{PublicKey, SecretKey};

use crate::cbor::{self, Value};
use crate::kdf::hkdf32;

pub const CT_NETCFG: &str = "batman/netcfg";
pub const CT_MEMBERS: &str = "batman/members";
pub const CT_SECRETS: &str = "batman/secrets";
pub const LABEL_NETCFG: &[u8] = b"batman-netcfg-v1";
pub const LABEL_MEMBERS: &[u8] = b"batman-members-v1";
pub const LABEL_SECRETS: &[u8] = b"batman-secrets-v1";
// remote invites (219 §7.4 / §7.6)
pub const CT_MSECRETS: &str = "batman/msecrets";
pub const CT_INVITE: &str = "batman/invite";
pub const CT_JOINREQ: &str = "batman/joinreq";
pub const LABEL_MSECRETS: &[u8] = b"batman-msecrets-v1";
pub const LABEL_INVITE: &[u8] = b"batman-invite-v1";
pub const LABEL_JOINREQ: &[u8] = b"batman-joinreq-v1";

#[derive(Debug, PartialEq, Eq)]
pub enum Error {
    BadPublicKey,
    BadSecretKey,
    Random,
    Aead,
    /// not the exact shape §7.1 / §7.3 require (named)
    Malformed(&'static str),
    /// no listed key verifies the signature
    Signature,
}

fn protected(ctype: &str) -> Vec<u8> {
    cbor::encode(&Value::Map(vec![(Value::Uint(1), Value::Nint(6)), (Value::Uint(3), Value::Text(ctype.into()))]))
}

/// The Sig_structure the admin key signs: ["Signature1", protected, external_aad = label, payload].
pub fn sign1_tbs(ctype: &str, label: &[u8], payload: &[u8]) -> Vec<u8> {
    cbor::encode(&Value::Array(vec![
        Value::Text("Signature1".into()),
        Value::Bytes(protected(ctype)),
        Value::Bytes(label.to_vec()),
        Value::Bytes(payload.to_vec()),
    ]))
}

/// The signed object: tag 18 [protected, {}, payload, signature (raw low-s r‖s)].
pub fn sign1(ctype: &str, payload: &[u8], sig: &[u8; 64]) -> Vec<u8> {
    cbor::encode(&Value::Tag(
        18,
        Box::new(Value::Array(vec![
            Value::Bytes(protected(ctype)),
            Value::Map(vec![]),
            Value::Bytes(payload.to_vec()),
            Value::Bytes(sig.to_vec()),
        ])),
    ))
}

/// net_config v1 payload (CDDL net-config): {1: net_id, 2: version, 3: prev (null for v1), 4: name, 5: country,
/// 6: {1: mesh_id, 2: channel, 3: bandwidth MHz}, 8: [admin_pub]}.
pub fn net_config_payload(
    net_id: &[u8; 16],
    version: u32,
    prev_hash: Option<&[u8; 32]>,
    name: &str,
    country: &str,
    mesh_id: &str,
    channel: u64,
    bw_mhz: u64,
    admins: &[[u8; 65]],
) -> Vec<u8> {
    cbor::encode(&Value::Map(vec![
        (Value::Uint(1), Value::Bytes(net_id.to_vec())),
        (Value::Uint(2), Value::Uint(version as u64)),
        (Value::Uint(3), prev_hash.map_or(Value::Null, |p| Value::Bytes(p.to_vec()))),
        (Value::Uint(4), Value::Text(name.into())),
        (Value::Uint(5), Value::Text(country.into())),
        (
            Value::Uint(6),
            Value::Map(vec![
                (Value::Uint(1), Value::Text(mesh_id.into())),
                (Value::Uint(2), Value::Uint(channel)),
                (Value::Uint(3), Value::Uint(bw_mhz)),
            ]),
        ),
        (Value::Uint(8), Value::Array(admins.iter().map(|a| Value::Bytes(a.to_vec())).collect())),
    ]))
}

/// One member entry: {1: dac_pub_hash, 2: ecdh_pub, 3: name, 4: owner_pub, 5: owner_enc_pub}.
pub struct Member<'a> {
    pub dac_pub_hash: &'a [u8; 32],
    pub ecdh_pub: &'a [u8; 65],
    pub name: &'a str,
    pub owner_pub: &'a [u8; 65],
    pub owner_enc_pub: &'a [u8; 65],
    /// key 7 (254-app-team-status §4.2); callers pass `teamview::gate(..)`, so None in version N
    pub mesh_addr: Option<&'a [u8; 6]>,
}

/// member-list payload (CDDL member-list): {1: net_id, 2: version, 3: prev (null for v1), 4: [members], 5: [], 6: [],
/// 7: []} — keys 5-7 empty in S1 (no invites / removals yet).
pub fn member_list_payload(net_id: &[u8; 16], version: u32, prev_hash: Option<&[u8; 32]>, members: &[Member]) -> Vec<u8> {
    let ms = members
        .iter()
        .map(|m| {
            let mut e = vec![
                (Value::Uint(1), Value::Bytes(m.dac_pub_hash.to_vec())),
                (Value::Uint(2), Value::Bytes(m.ecdh_pub.to_vec())),
                (Value::Uint(3), Value::Text(m.name.into())),
                (Value::Uint(4), Value::Bytes(m.owner_pub.to_vec())),
                (Value::Uint(5), Value::Bytes(m.owner_enc_pub.to_vec())),
            ];
            if let Some(a) = m.mesh_addr {
                e.push((Value::Uint(7), Value::Bytes(a.to_vec())));
            }
            Value::Map(e)
        })
        .collect();
    cbor::encode(&Value::Map(vec![
        (Value::Uint(1), Value::Bytes(net_id.to_vec())),
        (Value::Uint(2), Value::Uint(version as u64)),
        (Value::Uint(3), prev_hash.map_or(Value::Null, |p| Value::Bytes(p.to_vec()))),
        (Value::Uint(4), Value::Array(ms)),
        (Value::Uint(5), Value::Array(vec![])),
        (Value::Uint(6), Value::Array(vec![])),
        (Value::Uint(7), Value::Array(vec![])),
    ]))
}

/// What a COSE_Encrypt produced; the intermediate values are kept for the vector tests.
pub struct Encrypted {
    pub object: Value,
    pub z: [u8; 32],
    pub kdf_context: Vec<u8>,
    pub cek: [u8; 32],
    pub enc_structure: Vec<u8>,
}

/// COSE_Encrypt of `plain` to `target_pub` (65 B, sig_ecdh-verified by the caller) with a fresh ephemeral key and IV.
pub fn encrypt_to(
    plain: &[u8],
    label: &[u8],
    target_pub: &[u8; 65],
    target_hash: &[u8; 32],
    net_id: &[u8; 16],
    version: u32,
) -> Result<Encrypted, Error> {
    let eph = random_secret()?;
    let mut iv = [0u8; 12];
    getrandom::fill(&mut iv).map_err(|_| Error::Random)?;
    encrypt_inner(plain, label, target_pub, target_hash, net_id, version, &eph, &iv)
}

/// Test vectors only: a fixed ephemeral private key and IV. Not compiled into a release build.
#[cfg(feature = "test-vectors")]
#[doc(hidden)]
#[allow(clippy::too_many_arguments)]
pub fn encrypt_with_fixed_for_vectors(
    plain: &[u8],
    label: &[u8],
    target_pub: &[u8; 65],
    target_hash: &[u8; 32],
    net_id: &[u8; 16],
    version: u32,
    eph_priv: &[u8; 32],
    iv: &[u8; 12],
) -> Result<Encrypted, Error> {
    let eph = SecretKey::from_slice(eph_priv).map_err(|_| Error::BadSecretKey)?;
    encrypt_inner(plain, label, target_pub, target_hash, net_id, version, &eph, iv)
}

fn random_secret() -> Result<SecretKey, Error> {
    for _ in 0..8 {
        let mut b = [0u8; 32];
        getrandom::fill(&mut b).map_err(|_| Error::Random)?;
        let k = SecretKey::from_slice(&b);
        b.iter_mut().for_each(|x| *x = 0);
        if let Ok(k) = k {
            return Ok(k); // SecretKey zeroises on drop
        }
    }
    Err(Error::Random)
}

#[allow(clippy::too_many_arguments)]
fn encrypt_inner(
    plain: &[u8],
    label: &[u8],
    target_pub: &[u8; 65],
    target_hash: &[u8; 32],
    net_id: &[u8; 16],
    version: u32,
    eph: &SecretKey,
    iv: &[u8; 12],
) -> Result<Encrypted, Error> {
    let target = PublicKey::from_sec1_bytes(target_pub).map_err(|_| Error::BadPublicKey)?;
    let shared = p256::ecdh::diffie_hellman(eph.to_nonzero_scalar(), target.as_affine());
    let z: [u8; 32] = shared.raw_secret_bytes().as_slice().try_into().expect("P-256 x coordinate is 32 B");
    let body_prot = cbor::encode(&Value::Map(vec![(Value::Uint(1), Value::Uint(24))]));
    let rec_prot = cbor::encode(&Value::Map(vec![(Value::Uint(1), Value::Nint(24))]));
    let mut party_v = net_id.to_vec();
    party_v.extend(version.to_be_bytes());
    let kdf_context = cbor::encode(&Value::Array(vec![
        Value::Uint(24),
        Value::Array(vec![Value::Null, Value::Null, Value::Null]),
        Value::Array(vec![Value::Bytes(target_hash.to_vec()), Value::Null, Value::Null]),
        Value::Array(vec![Value::Uint(256), Value::Bytes(rec_prot.clone()), Value::Bytes(party_v)]),
    ]));
    let cek = hkdf32(&z, &kdf_context);
    let enc_structure = cbor::encode(&Value::Array(vec![
        Value::Text("Encrypt".into()),
        Value::Bytes(body_prot.clone()),
        Value::Bytes(label.to_vec()),
    ]));
    let ct = ChaCha20Poly1305::new(Key::from_slice(&cek))
        .encrypt(Nonce::from_slice(iv), Payload { msg: plain, aad: &enc_structure })
        .map_err(|_| Error::Aead)?;
    let epk = eph.public_key().to_sec1_point(false);
    let epk = epk.as_bytes();
    let cose_key = Value::Map(vec![
        (Value::Uint(1), Value::Uint(2)),
        (Value::Nint(0), Value::Uint(1)),
        (Value::Nint(1), Value::Bytes(epk[1..33].to_vec())),
        (Value::Nint(2), Value::Bytes(epk[33..65].to_vec())),
    ]);
    let object = Value::Tag(
        96,
        Box::new(Value::Array(vec![
            Value::Bytes(body_prot),
            Value::Map(vec![(Value::Uint(5), Value::Bytes(iv.to_vec()))]),
            Value::Bytes(ct),
            Value::Array(vec![Value::Array(vec![
                Value::Bytes(rec_prot),
                Value::Map(vec![(Value::Nint(0), cose_key)]),
                Value::Bytes(vec![]),
            ])]),
        ])),
    );
    Ok(Encrypted { object, z, kdf_context, cek, enc_structure })
}

/// net_secrets Sign1 payload: {1: net_id, 2: version, 3: SHA-256(DAC pub), 4: COSE_Encrypt}.
pub fn net_secrets_payload(net_id: &[u8; 16], version: u32, dac_pub_hash: &[u8; 32], encrypted: &Value) -> Vec<u8> {
    cbor::encode(&Value::Map(vec![
        (Value::Uint(1), Value::Bytes(net_id.to_vec())),
        (Value::Uint(2), Value::Uint(version as u64)),
        (Value::Uint(3), Value::Bytes(dac_pub_hash.to_vec())),
        (Value::Uint(4), encrypted.clone()),
    ]))
}

// ---- verification side (219 §7.1, §7.3; remote invites, 254-app-member-join §2) ----

/// A Sign1 that passed `verify_sign1`: its decoded payload, the key that verified it and its OBJECT_HASH.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Signed {
    pub payload: Value,
    pub signer: [u8; 65],
    pub hash: [u8; 32],
}

/// The label (external_aad) of a content type.
pub fn label_of(ctype: &str) -> Option<&'static [u8]> {
    Some(match ctype {
        CT_NETCFG => LABEL_NETCFG,
        CT_MEMBERS => LABEL_MEMBERS,
        CT_SECRETS => LABEL_SECRETS,
        CT_MSECRETS => LABEL_MSECRETS,
        CT_INVITE => LABEL_INVITE,
        CT_JOINREQ => LABEL_JOINREQ,
        _ => return None,
    })
}

type Parts = (Vec<u8>, Value, Vec<u8>, Vec<u8>);

/// tag 18 [protected bstr, unprotected, payload bstr, signature bstr] — the parts, nothing checked yet
fn sign1_parts(obj: &[u8]) -> Result<Parts, Error> {
    let v = cbor::decode(obj).map_err(|_| Error::Malformed("not deterministic CBOR"))?;
    let Value::Tag(18, a) = v else { return Err(Error::Malformed("not a tagged COSE_Sign1")) };
    let Value::Array(a) = *a else { return Err(Error::Malformed("COSE_Sign1 is not an array")) };
    let Ok([Value::Bytes(prot), unprot, Value::Bytes(payload), Value::Bytes(sig)]) = <[Value; 4]>::try_from(a) else {
        return Err(Error::Malformed("COSE_Sign1 is not [bstr, map, bstr, bstr]"));
    };
    Ok((prot, unprot, payload, sig))
}

/// OBJECT_HASH (§7.1) = SHA-256 of the Sig_structure: independent of the signature and the unprotected header (a
/// forwarder changing s to n−s or adding unprotected fields does not change it). The label follows the protected
/// content type.
pub fn object_hash(obj: &[u8]) -> Result<[u8; 32], Error> {
    use sha2::{Digest, Sha256};
    let (prot, _, payload, _) = sign1_parts(obj)?;
    let p = cbor::decode(&prot).map_err(|_| Error::Malformed("protected header"))?;
    let ctype = p.get(3).and_then(Value::as_text).ok_or(Error::Malformed("no content type"))?;
    let label = label_of(ctype).ok_or(Error::Malformed("unknown content type"))?;
    Ok(Sha256::digest(sign1_tbs(ctype, label, &payload)).into())
}

/// §7.1 strictly: tagged 18; protected exactly {1: -7, 3: ctype}; unprotected {}; a 64-byte low-s signature that one
/// of `keys` verifies over ["Signature1", protected, label, payload]; the payload deterministic CBOR (strict decode).
/// Unknown payload keys are each object's parser's to reject (nested objects included).
pub fn verify_sign1(obj: &[u8], ctype: &str, label: &[u8], keys: &[[u8; 65]]) -> Result<Signed, Error> {
    use p256::ecdsa::signature::Verifier;
    use sha2::{Digest, Sha256};
    let (prot, unprot, payload, sig) = sign1_parts(obj)?;
    if prot != protected(ctype) {
        return Err(Error::Malformed("protected header is not {1: -7, 3: content type}"));
    }
    if unprot != Value::Map(vec![]) {
        return Err(Error::Malformed("unprotected header is not empty"));
    }
    let sig: [u8; 64] = sig.try_into().map_err(|_| Error::Malformed("signature is not 64 bytes"))?;
    if !crate::sig::is_low_s(&sig) {
        return Err(Error::Malformed("high-s signature"));
    }
    let decoded = cbor::decode(&payload).map_err(|_| Error::Malformed("payload is not deterministic CBOR"))?;
    let tbs = sign1_tbs(ctype, label, &payload);
    let s = p256::ecdsa::Signature::from_slice(&sig).map_err(|_| Error::Malformed("signature"))?;
    let signer = keys
        .iter()
        .find(|k| p256::ecdsa::VerifyingKey::from_sec1_bytes(&k[..]).is_ok_and(|vk| vk.verify(&tbs, &s).is_ok()))
        .ok_or(Error::Signature)?;
    Ok(Signed { payload: decoded, signer: *signer, hash: Sha256::digest(&tbs).into() })
}

/// Only these integer keys (`required` all present, `optional` may be): signed objects reject unknown keys (§5.6).
pub fn exact_keys(m: &Value, required: &[u64], optional: &[u64]) -> Result<(), Error> {
    let Value::Map(e) = m else { return Err(Error::Malformed("not a map")) };
    for (k, _) in e {
        match k {
            Value::Uint(k) if required.contains(k) || optional.contains(k) => {}
            _ => return Err(Error::Malformed("unknown key")),
        }
    }
    if required.iter().all(|k| m.get(*k).is_some()) {
        Ok(())
    } else {
        Err(Error::Malformed("missing key"))
    }
}

fn neg(m: &Value, n: u64) -> Option<&Value> {
    let Value::Map(e) = m else { return None };
    e.iter().find(|(k, _)| *k == Value::Nint(n)).map(|(_, v)| v)
}

/// The parts of a COSE_Encrypt with the §7.3 fixed parameters (anything else is refused): IV, ciphertext, ephemeral key.
fn encrypt_parts(enc: &Value) -> Result<([u8; 12], Vec<u8>, [u8; 65]), Error> {
    let Value::Tag(96, a) = enc else { return Err(Error::Malformed("not a tagged COSE_Encrypt")) };
    let Value::Array(a) = a.as_ref() else { return Err(Error::Malformed("COSE_Encrypt is not an array")) };
    let [Value::Bytes(body_prot), unprot, Value::Bytes(ct), Value::Array(recs)] = &a[..] else {
        return Err(Error::Malformed("COSE_Encrypt items"));
    };
    if *body_prot != cbor::encode(&Value::Map(vec![(Value::Uint(1), Value::Uint(24))])) {
        return Err(Error::Malformed("body protected is not {1: 24}"));
    }
    exact_keys(unprot, &[5], &[])?;
    let iv: [u8; 12] = unprot.get(5).and_then(Value::as_bytes).and_then(|b| b.try_into().ok()).ok_or(Error::Malformed("IV"))?;
    let [Value::Array(r)] = &recs[..] else { return Err(Error::Malformed("not one recipient")) };
    let [Value::Bytes(rp), ru, Value::Bytes(rct)] = &r[..] else { return Err(Error::Malformed("recipient items")) };
    if *rp != cbor::encode(&Value::Map(vec![(Value::Uint(1), Value::Nint(24))])) || !rct.is_empty() {
        return Err(Error::Malformed("recipient is not ECDH-ES {1: -25}"));
    }
    let Value::Map(rue) = ru else { return Err(Error::Malformed("recipient unprotected")) };
    let k = neg(ru, 0).filter(|_| rue.len() == 1).ok_or(Error::Malformed("recipient unprotected is not {-1: key}"))?;
    let Value::Map(ke) = k else { return Err(Error::Malformed("ephemeral key")) };
    if ke.len() != 4 || k.get(1) != Some(&Value::Uint(2)) || neg(k, 0) != Some(&Value::Uint(1)) {
        return Err(Error::Malformed("ephemeral key is not EC2 P-256"));
    }
    let x = neg(k, 1).and_then(Value::as_bytes).filter(|b| b.len() == 32).ok_or(Error::Malformed("ephemeral x"))?;
    let y = neg(k, 2).and_then(Value::as_bytes).filter(|b| b.len() == 32).ok_or(Error::Malformed("ephemeral y"))?;
    let mut epk = [0u8; 65];
    epk[0] = 4;
    epk[1..33].copy_from_slice(x);
    epk[33..].copy_from_slice(y);
    Ok((iv, ct.clone(), epk))
}

/// The ephemeral public key of a COSE_Encrypt (the peer of the receiver's ECDH), output only when it is a point on
/// P-256. Call it only on an object inside a Sign1 that passed `verify_sign1`.
pub fn recipient_eph(enc: &Value) -> Result<[u8; 65], Error> {
    let (_, _, epk) = encrypt_parts(enc)?;
    PublicKey::from_sec1_bytes(&epk).map_err(|_| Error::BadPublicKey)?;
    Ok(epk)
}

/// Decrypt a §7.3 COSE_Encrypt with the receiver's ECDH x coordinate `z`: CEK = HKDF(z, KDF context(target_hash,
/// net_id ‖ u32BE(version))), ChaCha20-Poly1305 with Enc_structure("Encrypt", body protected, label).
pub fn decrypt(enc: &Value, label: &[u8], target_hash: &[u8; 32], net_id: &[u8; 16], version: u32, z: &[u8; 32]) -> Result<Vec<u8>, Error> {
    let (iv, ct, epk) = encrypt_parts(enc)?;
    PublicKey::from_sec1_bytes(&epk).map_err(|_| Error::BadPublicKey)?;
    let rec_prot = cbor::encode(&Value::Map(vec![(Value::Uint(1), Value::Nint(24))]));
    let mut party_v = net_id.to_vec();
    party_v.extend(version.to_be_bytes());
    let kdf_context = cbor::encode(&Value::Array(vec![
        Value::Uint(24),
        Value::Array(vec![Value::Null, Value::Null, Value::Null]),
        Value::Array(vec![Value::Bytes(target_hash.to_vec()), Value::Null, Value::Null]),
        Value::Array(vec![Value::Uint(256), Value::Bytes(rec_prot), Value::Bytes(party_v)]),
    ]));
    let mut cek = hkdf32(z, &kdf_context);
    let aad = cbor::encode(&Value::Array(vec![
        Value::Text("Encrypt".into()),
        Value::Bytes(cbor::encode(&Value::Map(vec![(Value::Uint(1), Value::Uint(24))]))),
        Value::Bytes(label.to_vec()),
    ]));
    let r = ChaCha20Poly1305::new(Key::from_slice(&cek)).decrypt(Nonce::from_slice(&iv), Payload { msg: &ct, aad: &aad });
    cek.iter_mut().for_each(|b| *b = 0);
    r.map_err(|_| Error::Aead)
}
