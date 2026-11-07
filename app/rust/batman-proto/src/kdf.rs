//! Key derivation (219-protocol.md §6; node: proto/proto.go:157-173): HKDF-SHA256, empty salt, L = 32,
//! info = label ‖ fields. The device id enters as its ASCII text (18 lowercase hex characters).

use hkdf::Hkdf;
use sha2::Sha256;

pub const LABEL_PSK_OWNER: &[u8] = b"batman-psk-owner-v1";
pub const LABEL_PSK_REPLAY: &[u8] = b"batman-psk-replay-v1";
pub const LABEL_PSK_MEMBER: &[u8] = b"batman-psk-member-v1";
pub const LABEL_ADV_OWNER: &[u8] = b"batman-adv-owner-v1";
pub const LABEL_ADV_MEMBER: &[u8] = b"batman-adv-member-v1";

/// HKDF-SHA256 with an empty salt, 32 bytes out.
pub fn hkdf32(ikm: &[u8], info: &[u8]) -> [u8; 32] {
    let mut out = [0u8; 32];
    Hkdf::<Sha256>::new(None, ikm).expand(info, &mut out).expect("32 <= 255 * 32");
    out
}

fn cat(a: &[u8], b: &[u8]) -> Vec<u8> {
    let mut v = Vec::with_capacity(a.len() + b.len());
    v.extend_from_slice(a);
    v.extend_from_slice(b);
    v
}

/// psk_owner = HKDF(owner_tag_key, "batman-psk-owner-v1" ‖ device_id)
pub fn psk_owner(owner_tag_key: &[u8], device_id: &str) -> [u8; 32] {
    hkdf32(owner_tag_key, &cat(LABEL_PSK_OWNER, device_id.as_bytes()))
}

/// psk_replay = HKDF(z, "batman-psk-replay-v1" ‖ device_id), z = x coordinate of ECDH(owner_enc, node ecdh_pub)
/// (computed by the platform's Keystore; this crate only derives from it)
pub fn psk_replay(z: &[u8; 32], device_id: &str) -> [u8; 32] {
    hkdf32(z, &cat(LABEL_PSK_REPLAY, device_id.as_bytes()))
}

/// psk_member = HKDF(net_root, "batman-psk-member-v1" ‖ net_id ‖ u32be(version))
pub fn psk_member(net_root: &[u8], net_id: &[u8; 16], version: u32) -> [u8; 32] {
    hkdf32(net_root, &cat(&cat(LABEL_PSK_MEMBER, net_id), &version.to_be_bytes()))
}

/// adv_owner = HKDF(adv_owner_key, "batman-adv-owner-v1" ‖ device_id)
pub fn adv_owner(adv_owner_key: &[u8], device_id: &str) -> [u8; 32] {
    hkdf32(adv_owner_key, &cat(LABEL_ADV_OWNER, device_id.as_bytes()))
}

/// adv_member = HKDF(net_root, "batman-adv-member-v1" ‖ net_id ‖ u32be(version))
pub fn adv_member(net_root: &[u8], net_id: &[u8; 16], version: u32) -> [u8; 32] {
    hkdf32(net_root, &cat(&cat(LABEL_ADV_MEMBER, net_id), &version.to_be_bytes()))
}
