//! Claim proof (219-protocol.md §5.4; node proto/proto.go:47-69, node.go:519-524): the phone proves it holds K (from
//! the node's QR) with an ATECC608-style CheckMac response bound to this session and this DAC.
//!
//! ClientChal = SHA-256("batman-claim-v1" ‖ nonce ‖ h ‖ SHA-256(DAC DER) ‖ owner_pub)
//! response  = SHA-256(K ‖ ClientChal ‖ other_data[0..4] ‖ 00×8 ‖ other_data[4..7] ‖ sn[8] ‖ other_data[7..11] ‖
//!             sn[0..2] ‖ other_data[11..13]),  other_data = 08 00 00 00 ‖ 00×9 (13 B)
//! The same response is used in claim/finish (fresh claim, NX session) and claim/replay (recovery, psk_replay session,
//! with that session's own nonce and h and the owner_pub the node stored).

use sha2::{Digest, Sha256};

pub const LABEL_CLAIM: &[u8] = b"batman-claim-v1";
pub const OTHER_DATA: [u8; 13] = [0x08, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0];

pub fn client_chal(nonce: &[u8; 32], h: &[u8; 32], dac_der: &[u8], owner_pub: &[u8; 65]) -> [u8; 32] {
    let mut d = Sha256::new();
    d.update(LABEL_CLAIM);
    d.update(nonce);
    d.update(h);
    d.update(Sha256::digest(dac_der));
    d.update(owner_pub);
    d.finalize().into()
}

/// The 88-byte CheckMac input (exposed for the vector test).
pub fn checkmac_input(k: &[u8; 32], client_chal: &[u8; 32], sn: &[u8; 9]) -> [u8; 88] {
    let od = &OTHER_DATA;
    let mut v = Vec::with_capacity(88);
    v.extend_from_slice(k);
    v.extend_from_slice(client_chal);
    v.extend_from_slice(&od[0..4]);
    v.extend_from_slice(&[0u8; 8]);
    v.extend_from_slice(&od[4..7]);
    v.push(sn[8]);
    v.extend_from_slice(&od[7..11]);
    v.extend_from_slice(&sn[0..2]);
    v.extend_from_slice(&od[11..13]);
    v.try_into().expect("88 bytes by construction")
}

pub fn response(k: &[u8; 32], nonce: &[u8; 32], h: &[u8; 32], dac_der: &[u8], owner_pub: &[u8; 65], sn: &[u8; 9]) -> [u8; 32] {
    Sha256::digest(checkmac_input(k, &client_chal(nonce, h, dac_der, owner_pub), sn)).into()
}
