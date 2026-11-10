//! synth-joinreq — a synthetic third person for the bench (docs/design/254-app-remove-member.md v6.4 §7, T13).
//!
//! Reads a remote invite (qr-object kind 1, hex) on stdin and prints a join request (qr-object kind 2, hex) and its SAS:
//! a fresh self-signed `dev:` DAC (the dev TOFU rule: CN = "dev:<device_id>", device_id = hex(SHA-256(DAC pub)[:9]),
//! serialNumber = device_id, 2020-01-01 .. 2120-01-01), a fresh node ECDH key, a fresh owner key and owner_enc key.
//! Every private key lives in memory only and is dropped on exit: nobody can import the approval made for this person,
//! which is the point — it exists to be removed.
//!
//! The only gate is the app's: only a `dev-trust` build accepts a `dev:` DAC (nodecert.rs trust_gate). This tool is not
//! part of any app build and not in the bridge's Cargo workspace.

use std::io::Read;

use batman_proto::cbor::{self, Value};
use batman_proto::{cose, invite, nodecert, sig};
use p256::ecdsa::signature::Signer;
use p256::ecdsa::{Signature, SigningKey};
use sha2::{Digest, Sha256};

/// The tbsCertificate of the 219 vectors' dev DAC (identity_file.dev_cert_der): every field this tool changes has a
/// fixed length (the 18-character device id x 4, the 65-byte public key), so the template keeps its DER lengths.
const TBS_TEMPLATE: &str = "30820123a003020102020101300a06082a8648ce3d040302303e311f301d06035504030c166465763a383334323265653664356635383665643935311b3019060355040513123833343232656536643566353836656439353020170d3230303130313030303030305a180f32313230303130313030303030305a303e311f301d06035504030c166465763a383334323265653664356635383665643935311b3019060355040513123833343232656536643566353836656439353059301306072a8648ce3d020106082a8648ce3d030107034200047030d4bc2ed3b42293cbde7fa6576b95bc3d68ca367a05af7d8fe4f736b137ea162ccafc376c03f12e327db2caeee66d7c277ab2f68778160a68cbf21e501263a310300e300c0603551d130101ff04023000";
const TEMPLATE_ID: &str = "83422ee6d5f586ed95";
const TEMPLATE_PUB: &str = "047030d4bc2ed3b42293cbde7fa6576b95bc3d68ca367a05af7d8fe4f736b137ea162ccafc376c03f12e327db2caeee66d7c277ab2f68778160a68cbf21e501263";
/// AlgorithmIdentifier ecdsa-with-SHA256
const ALG: &str = "300a06082a8648ce3d040302";

fn unhex(s: &str) -> Vec<u8> {
    (0..s.len()).step_by(2).map(|i| u8::from_str_radix(&s[i..i + 2], 16).expect("hex")).collect()
}

fn key() -> SigningKey {
    loop {
        let mut b = [0u8; 32];
        getrandom::fill(&mut b).expect("getrandom");
        let k = SigningKey::from_slice(&b);
        b.iter_mut().for_each(|x| *x = 0);
        if let Ok(k) = k {
            return k;
        }
    }
}

fn pub65(k: &SigningKey) -> [u8; 65] {
    k.verifying_key().to_sec1_point(false).as_bytes().try_into().expect("65-byte point")
}

/// raw low-s r‖s of an ES256 signature over `msg`
fn raw(k: &SigningKey, msg: &[u8]) -> [u8; 64] {
    let s: Signature = k.sign(msg);
    sig::der_to_raw_low_s(s.to_der().as_bytes()).expect("a P-256 signature")
}

fn replace_all(hay: &[u8], from: &[u8], to: &[u8]) -> Vec<u8> {
    assert_eq!(from.len(), to.len(), "same length: the DER lengths stay");
    let mut out = hay.to_vec();
    let mut i = 0;
    while i + from.len() <= out.len() {
        if &out[i..i + from.len()] == from {
            out[i..i + from.len()].copy_from_slice(to);
            i += from.len();
        } else {
            i += 1;
        }
    }
    out
}

fn der_len(n: usize) -> Vec<u8> {
    match n {
        0..=0x7f => vec![n as u8],
        0x80..=0xff => vec![0x81, n as u8],
        _ => vec![0x82, (n >> 8) as u8, n as u8],
    }
}

/// A self-signed dev DAC for `k` and its device id.
fn dev_dac(k: &SigningKey) -> (Vec<u8>, String, [u8; 9]) {
    let p = pub65(k);
    let sn: [u8; 9] = Sha256::digest(p)[..9].try_into().expect("9 bytes");
    let id = nodecert::hex_lower(&sn);
    let tbs = replace_all(&unhex(TBS_TEMPLATE), TEMPLATE_ID.as_bytes(), id.as_bytes());
    let tbs = replace_all(&tbs, &unhex(TEMPLATE_PUB), &p);
    let s: Signature = k.sign(&tbs);
    let sig = s.to_der().as_bytes().to_vec();
    let mut bits = vec![0x03];
    bits.extend(der_len(sig.len() + 1));
    bits.push(0);
    bits.extend(&sig);
    let mut body = tbs;
    body.extend(unhex(ALG));
    body.extend(bits);
    let mut cert = vec![0x30];
    cert.extend(der_len(body.len()));
    cert.extend(body);
    (cert, id, sn)
}

fn main() {
    let mut input = String::new();
    std::io::stdin().read_to_string(&mut input).expect("stdin");
    let name = std::env::args().nth(1).unwrap_or_else(|| "synthetic".into());
    let (hex, line) = make(input.trim(), &name);
    println!("{hex}");
    eprintln!("{line}");
}

/// (the join request hex, a line naming the synthetic node and the SAS)
fn make(invite_hex: &str, name: &str) -> (String, String) {
    let inv = invite::open_invite(&invite::qr_object(invite_hex, invite::QR_INVITE).expect("an invite (qr-object kind 1)")).expect("the invite verifies");
    // the node: its DAC, its ECDH key, a node_cert (offline-verifiable: sig_static / sig_ecdh / sn)
    let dac = key();
    let ecdh = key();
    let (dac_der, device_id, sn) = dev_dac(&dac);
    let mut s_node = [0u8; 32];
    let mut boot_id = [0u8; 16];
    getrandom::fill(&mut s_node).expect("getrandom");
    getrandom::fill(&mut boot_id).expect("getrandom");
    let mut a = nodecert::LABEL_STATIC.to_vec();
    a.extend(s_node);
    a.extend(boot_id);
    let mut b = nodecert::LABEL_ECDH.to_vec();
    b.extend(pub65(&ecdh));
    let m = |pairs: Vec<(u64, Value)>| Value::Map(pairs.into_iter().map(|(k, v)| (Value::Uint(k), v)).collect());
    let node_cert = m(vec![
        (1, Value::Array(vec![Value::Bytes(dac_der)])),
        (2, Value::Bytes(s_node.to_vec())),
        (3, Value::Bytes(boot_id.to_vec())),
        (4, Value::Bytes(pub65(&ecdh).to_vec())),
        (5, Value::Bytes(raw(&dac, &a).to_vec())),
        (6, Value::Bytes(raw(&dac, &b).to_vec())),
        (7, Value::Bytes(sn.to_vec())),
    ]);
    // the same checks the admin's app runs on it
    nodecert::verify_offline(&cbor::encode(&node_cert)).expect("the synthetic node_cert passes offline (dev-trust)");
    // the person: an owner key and an owner_enc key
    let owner = key();
    let enc = key();
    let sig_enc = raw(&owner, &sig::owner_enc_input(&pub65(&enc)));
    let payload = invite::joinreq_payload(&inv.hash, node_cert, &pub65(&owner), &pub65(&enc), &sig_enc, name);
    let joinreq = cose::sign1(cose::CT_JOINREQ, &payload, &raw(&owner, &cose::sign1_tbs(cose::CT_JOINREQ, cose::LABEL_JOINREQ, &payload)));
    let jr_hash = cose::object_hash(&joinreq).expect("hash");
    batman_proto::approve::open_joinreq(&joinreq).expect("the join request opens");
    let line = format!("synthetic person: name {name}, node …{}, SAS {}", &device_id[device_id.len() - 4..], invite::sas(&inv.hash, &jr_hash));
    (invite::qr_hex(invite::QR_JOINREQ, &joinreq), line)
}

#[cfg(test)]
mod tests {
    use super::*;
    use batman_proto::invite::{Action, End, InviteFlow};
    use batman_proto::joinflow::NetRecord;
    use batman_proto::netrec::{self, NetRec};

    /// an admin's applied record and an invite from it (admin key 0x66)
    fn invite_hex() -> (NetRec, String) {
        let admin = SigningKey::from_slice(&[0x66; 32]).unwrap();
        let id = [0x5a; 16];
        let p = cose::net_config_payload(&id, 1, None, "t", "US", "bm-5a5a5a5a5a5a", 40, 4, &[pub65(&admin)]);
        let netcfg = cose::sign1(cose::CT_NETCFG, &p, &raw(&admin, &cose::sign1_tbs(cose::CT_NETCFG, cose::LABEL_NETCFG, &p)));
        let mp = cose::member_list_payload(&id, 1, None, &[]);
        let members = cose::sign1(cose::CT_MEMBERS, &mp, &raw(&admin, &cose::sign1_tbs(cose::CT_MEMBERS, cose::LABEL_MEMBERS, &mp)));
        let base = NetRecord { net_id: id, mesh_id: "bm-5a5a5a5a5a5a".into(), channel: 40, bw: 4, sae: "S".repeat(24), net_root: [7; 32], netcfg, members, secrets: vec![] };
        let rec = NetRec { base, state: "applied".into(), list: Some(vec![]), invites: None, versions: None };
        let (mut f, a) = InviteFlow::start(&netrec::encode(&rec), 1, &pub65(&admin));
        let Action::SignAdmin { tbs } = a else { panic!() };
        let s: Signature = admin.sign(&tbs);
        let Some(Action::Persist { plain, .. }) = f.signed(s.to_der().as_bytes()) else { panic!() };
        let Some(Action::Done(End::Out { hex, .. })) = f.persisted() else { panic!() };
        (netrec::decode(&plain).unwrap(), hex)
    }

    #[test]
    fn the_admin_app_accepts_the_synthetic_request_and_each_run_is_another_node() {
        let (rec, inv) = invite_hex();
        let (a, _) = make(&inv, "第三人");
        let (b, _) = make(&inv, "第三人");
        let ca = batman_proto::approve::check_joinreq(&rec, &invite::qr_object(&a, invite::QR_JOINREQ).unwrap()).unwrap();
        let cb = batman_proto::approve::check_joinreq(&rec, &invite::qr_object(&b, invite::QR_JOINREQ).unwrap()).unwrap();
        assert_ne!(ca.jr.node.dac_pub, cb.jr.node.dac_pub, "fresh keys each run");
        assert_ne!(ca.jr.owner_pub, cb.jr.owner_pub);
        assert_eq!(ca.jr.name, "第三人");
    }
}
