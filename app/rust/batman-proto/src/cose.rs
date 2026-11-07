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

#[derive(Debug, PartialEq, Eq)]
pub enum Error {
    BadPublicKey,
    BadSecretKey,
    Random,
    Aead,
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
}

/// member-list payload (CDDL member-list): {1: net_id, 2: version, 3: prev (null for v1), 4: [members], 5: [], 6: [],
/// 7: []} — keys 5-7 empty in S1 (no invites / removals yet).
pub fn member_list_payload(net_id: &[u8; 16], version: u32, prev_hash: Option<&[u8; 32]>, members: &[Member]) -> Vec<u8> {
    let ms = members
        .iter()
        .map(|m| {
            Value::Map(vec![
                (Value::Uint(1), Value::Bytes(m.dac_pub_hash.to_vec())),
                (Value::Uint(2), Value::Bytes(m.ecdh_pub.to_vec())),
                (Value::Uint(3), Value::Text(m.name.into())),
                (Value::Uint(4), Value::Bytes(m.owner_pub.to_vec())),
                (Value::Uint(5), Value::Bytes(m.owner_enc_pub.to_vec())),
            ])
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
