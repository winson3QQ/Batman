//! batman-proto against tests/vectors/219-protocol/vectors.json (docs/design/254-app-s1.md §8.1–8.3).
//! Every top-level vector group must be listed in COVERAGE (tested here, or pending with the module that will test
//! it): a group added to the vectors and not listed fails the run.

use batman_proto::{cbor, frame};
use serde_json::Value as J;
use std::path::PathBuf;

fn vectors() -> J {
    let p = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../../tests/vectors/219-protocol/vectors.json");
    serde_json::from_str(&std::fs::read_to_string(&p).unwrap_or_else(|e| panic!("{}: {e}", p.display()))).unwrap()
}

fn h(v: &J) -> Vec<u8> {
    hex::decode(v.as_str().unwrap_or_else(|| panic!("not a hex string: {v}"))).unwrap()
}

/// group -> "tested" or "pending: <module>"
const COVERAGE: &[(&str, &str)] = &[
    ("meta", "tested"),
    ("gatt_framing", "tested"),
    ("envelope", "tested"),
    ("chunking", "tested"),
    ("status_public", "tested"),
    ("legacy", "tested"),
    ("keys", "tested"),
    ("node_cert", "tested"),
    ("identity_file", "tested"),
    ("hkdf", "tested"),
    ("psk_replay", "tested"),
    ("noise_nx", "tested"),
    ("noise_nxpsk0_owner", "tested"),
    ("noise_nxpsk0_replay", "tested"),
    ("fake_msg2_rule", "tested"),
    ("auth_owner", "pending: sig-inputs"),
    ("claim_checkmac", "pending: claim"),
    ("owner_enc", "pending: sig-inputs"),
    ("owner_op", "pending: sig-inputs"),
    ("op_nonce", "pending: sig-inputs"),
    ("claim_replay", "pending: claim"),
    ("cose", "pending: cose"),
    ("chunk_boundary", "pending: envelope limits"),
    ("peers_challenge", "pending: not in S1 (P2 answers E_UNSUPPORTED; design §1)"),
    ("version_chain", "pending: not in S1 (network/update)"),
    ("sas", "pending: not in S1 (invites)"),
];

#[test]
fn every_vector_group_is_accounted_for() {
    let v = vectors();
    let groups: Vec<&String> = v.as_object().unwrap().keys().collect();
    for g in &groups {
        assert!(COVERAGE.iter().any(|(n, _)| n == g), "vector group {g} is not in COVERAGE");
    }
    for (n, _) in COVERAGE {
        assert!(groups.iter().any(|g| g == n), "COVERAGE lists {n}, which vectors.json no longer has");
    }
    let pending = COVERAGE.iter().filter(|(_, s)| s.starts_with("pending")).count();
    eprintln!("vector groups: {} tested, {} pending", COVERAGE.len() - pending, pending);
}

/// Every hex CBOR value under `group` decodes strictly and re-encodes to the same bytes.
fn roundtrip_group(v: &J, group: &str, keys: &[&str]) {
    for k in keys {
        let b = h(&v[group][*k]);
        let d = cbor::decode(&b).unwrap_or_else(|e| panic!("{group}.{k}: {e}"));
        assert_eq!(cbor::encode(&d), b, "{group}.{k}: re-encoding differs");
    }
}

#[test]
fn envelope_roundtrips_byte_exact() {
    let v = vectors();
    roundtrip_group(
        &v,
        "envelope",
        &[
            "request_info",
            "response_info",
            "response_error_unsupported",
            "request_reset",
            "negative_reset_with_idem",
            "response_error_reset_reflash",
            "response_error_lock_incomplete",
        ],
    );
    // the request envelope: {0: [1, 0], 1: id, 2: type, 3: body}
    let r = cbor::decode(&h(&v["envelope"]["request_info"])).unwrap();
    assert_eq!(r.get(2).and_then(|t| t.as_text()), Some("info"));
    assert_eq!(r.get(1).and_then(|t| t.as_uint()), Some(1));
    // an error response: {1: id, 4: code, 5: detail}, no key 3
    let e = cbor::decode(&h(&v["envelope"]["response_error_lock_incomplete"])).unwrap();
    assert_eq!(e.get(4).and_then(|c| c.as_uint()), Some(13));
    assert!(e.get(3).is_none());
}

#[test]
fn chunking_roundtrips_and_reassembles() {
    let v = vectors();
    let body = h(&v["chunking"]["body"]);
    let c1 = cbor::decode(&h(&v["chunking"]["chunk1"])).unwrap();
    let c2 = cbor::decode(&h(&v["chunking"]["chunk2"])).unwrap();
    assert_eq!(cbor::encode(&c1), h(&v["chunking"]["chunk1"]));
    assert_eq!(cbor::encode(&c2), h(&v["chunking"]["chunk2"]));
    // chunks share id; key 3 = bstr slice of the encoded body; key 6 = {1: n, 2: total}
    assert_eq!(c1.get(1), c2.get(1));
    let mut joined = c1.get(3).and_then(|x| x.as_bytes()).unwrap().to_vec();
    joined.extend(c2.get(3).and_then(|x| x.as_bytes()).unwrap());
    assert_eq!(joined, body);
    for (c, n) in [(&c1, 1), (&c2, 2)] {
        let m = c.get(6).unwrap();
        assert_eq!(m.get(1).and_then(|x| x.as_uint()), Some(n));
        assert_eq!(m.get(2).and_then(|x| x.as_uint()), Some(2));
    }
}

#[test]
fn status_public_and_legacy_roundtrip() {
    let v = vectors();
    for g in ["status_public", "legacy"] {
        let keys: Vec<String> = v[g].as_object().unwrap().keys().cloned().collect();
        let keys: Vec<&str> = keys.iter().map(|s| s.as_str()).collect();
        roundtrip_group(&v, g, &keys);
    }
}

#[test]
fn gatt_framing_split_and_reassemble() {
    let v = vectors();
    let g = &v["gatt_framing"];
    // the input names another vector, e.g. "noise_nx.msg1"
    let path = g["input"].as_str().unwrap();
    let (grp, key) = path.split_once('.').unwrap();
    let msg = h(&v[grp][key]);
    let limit = g["frame_limit"].as_u64().unwrap() as usize;
    assert_eq!(g["data_per_frame"].as_u64().unwrap() as usize, limit - frame::HEADER);
    let want: Vec<Vec<u8>> = g["frames"].as_array().unwrap().iter().map(h).collect();
    assert_eq!(frame::split(&msg, limit).unwrap(), want, "split differs from the vector frames");
    let mut r = frame::Reassembler::new(limit, 65535);
    let mut got = None;
    for f in &want {
        got = r.push(f).unwrap();
    }
    assert_eq!(got.as_deref(), Some(&msg[..]));
}

#[test]
fn gatt_framing_invalid_cases_abort() {
    let v = vectors();
    let cases: Vec<String> = v["gatt_framing"]["invalid_cases"].as_array().unwrap().iter().map(|c| c.as_str().unwrap().to_string()).collect();
    assert_eq!(cases.len(), 3, "the vectors list 3 invalid framing cases: {cases:?}");
    // "seq jumps (0, 2): abort connection"
    let mut r = frame::Reassembler::new(20, 65535);
    assert_eq!(r.push(&[0x01, 0, 0, 0xaa]), Ok(None));
    assert_eq!(r.push(&[0x02, 0, 2, 0xbb]), Err(frame::Error::SeqJump { want: 1, got: 2 }));
    // "reassembled length > 65535: abort connection"
    let mut r = frame::Reassembler::new(65535 + 3, 65535);
    let mut big = vec![0x01, 0, 0];
    big.extend(vec![0u8; 65535]);
    assert_eq!(r.push(&big), Ok(None));
    assert_eq!(r.push(&[0x02, 0, 1, 0]), Err(frame::Error::MessageTooLong));
    // "frame without start flag while idle: abort connection"
    let mut r = frame::Reassembler::new(20, 65535);
    assert_eq!(r.push(&[0x02, 0, 0, 0xaa]), Err(frame::Error::NoStartFlag));
}

// ---- kdf: inputs recomputed here from gen.py's fixed inputs (seed(name) = SHA-256("batman-test-vector/" + name);
// device_id = hex(sn) = "0123a5f0c3e1b74dee"; net_id = seed("net_id")[:16], version 1), never read from the vectors
const DEVICE_ID: &str = "0123a5f0c3e1b74dee";

fn seed(name: &str) -> Vec<u8> {
    use sha2::{Digest, Sha256};
    Sha256::digest(format!("batman-test-vector/{name}").as_bytes()).to_vec()
}

#[test]
fn hkdf_vectors() {
    use batman_proto::kdf;
    let v = vectors();
    let net_id: [u8; 16] = seed("net_id")[..16].try_into().unwrap();
    let net_root = seed("net_root");
    assert_eq!(kdf::psk_owner(&seed("owner_tag_key"), DEVICE_ID).to_vec(), h(&v["hkdf"]["psk_owner"]));
    assert_eq!(kdf::adv_owner(&seed("adv_owner_key"), DEVICE_ID).to_vec(), h(&v["hkdf"]["adv_owner"]));
    assert_eq!(kdf::psk_member(&net_root, &net_id, 1).to_vec(), h(&v["hkdf"]["psk_member"]));
    assert_eq!(kdf::adv_member(&net_root, &net_id, 1).to_vec(), h(&v["hkdf"]["adv_member"]));
    // negative: the owner label on the member inputs (or the wrong device id) must NOT give the vector
    assert_ne!(kdf::hkdf32(&net_root, b"batman-psk-owner-v1").to_vec(), h(&v["hkdf"]["psk_member"]));
    assert_ne!(kdf::psk_owner(&seed("owner_tag_key"), "0123a5f0c3e1b74def").to_vec(), h(&v["hkdf"]["psk_owner"]));
}

#[test]
fn psk_replay_vector() {
    use batman_proto::kdf;
    let v = vectors();
    let z: [u8; 32] = h(&v["psk_replay"]["ecdh_z"]).try_into().unwrap();
    // the vector's info is label ‖ device_id: check our construction gives the same bytes
    let mut info = kdf::LABEL_PSK_REPLAY.to_vec();
    info.extend(DEVICE_ID.as_bytes());
    assert_eq!(info, h(&v["psk_replay"]["info"]));
    assert_eq!(kdf::psk_replay(&z, DEVICE_ID).to_vec(), h(&v["psk_replay"]["psk_replay"]));
    let mut z2 = z;
    z2[31] ^= 1;
    assert_ne!(kdf::psk_replay(&z2, DEVICE_ID).to_vec(), h(&v["psk_replay"]["psk_replay"]));
}

// ---- noise: the phone's ephemeral from keys.phone_ephemeral_priv; msg1 byte-exact, msg2 from the node decrypts to the
// node_cert, the handshake hash and the first transport message match
fn eph(v: &J) -> [u8; 32] {
    h(&v["keys"]["phone_ephemeral_priv"]).try_into().unwrap()
}

/// resolves "group.key" references the vectors use for psk / payload fields
fn by_ref(v: &J, r: &str) -> Vec<u8> {
    let (g, k) = r.split_once('.').unwrap();
    h(&v[g][k])
}

fn run_noise(v: &J, group: &str, mode: noise::Mode, device_id: Option<&str>) {
    let g = &v[group];
    let psk: Option<[u8; 32]> = g.get("psk").map(|r| by_ref(v, r.as_str().unwrap()).try_into().unwrap());
    assert_eq!(noise::prologue(mode, device_id), h(&g["prologue"]), "{group}: prologue");
    let mut ini = noise::Initiator::with_fixed_ephemeral_for_vectors(mode, device_id, psk.as_ref(), &eph(v)).unwrap();
    assert_eq!(ini.msg1().unwrap(), h(&g["msg1"]), "{group}: msg1");
    let (payload, mut s) = ini.read_msg2(&h(&g["msg2"])).unwrap();
    assert_eq!(payload, h(&v["node_cert"]["cbor"]), "{group}: msg2 payload = node_cert");
    assert_eq!(s.h.to_vec(), h(&g["handshake_hash"]), "{group}: handshake hash");
    let req = h(&v["noise_nx"]["first_transport_plaintext"]);
    assert_eq!(s.encrypt(&req).unwrap(), h(&g["first_transport_message"]), "{group}: first transport message");
}

use batman_proto::noise;

#[test]
fn noise_nx_vector() {
    run_noise(&vectors(), "noise_nx", noise::Mode::Nx, Some(DEVICE_ID));
}

#[test]
fn noise_nxpsk0_owner_vector() {
    run_noise(&vectors(), "noise_nxpsk0_owner", noise::Mode::NxPsk0, None);
}

#[test]
fn noise_nxpsk0_replay_vector() {
    run_noise(&vectors(), "noise_nxpsk0_replay", noise::Mode::NxPsk0, None);
}

/// Negatives (design §5.0): a wrong PSK, a mode mismatch or a different device id in the prologue leaves msg2
/// undecryptable — the phone sees Msg2NotDecryptable, never a payload.
#[test]
fn noise_mismatches_do_not_decrypt() {
    let v = vectors();
    let e = eph(&v);
    let owner_psk: [u8; 32] = by_ref(&v, "hkdf.psk_owner").try_into().unwrap();
    let replay_psk: [u8; 32] = by_ref(&v, "psk_replay.psk_replay").try_into().unwrap();
    // owner msg2 read with the replay PSK
    let mut i = noise::Initiator::with_fixed_ephemeral_for_vectors(noise::Mode::NxPsk0, None, Some(&replay_psk), &e).unwrap();
    i.msg1().unwrap();
    assert_eq!(i.read_msg2(&h(&v["noise_nxpsk0_owner"]["msg2"])).err(), Some(noise::Error::Msg2NotDecryptable));
    // NX msg2 read as NXpsk0 (mode mismatch)
    let mut i = noise::Initiator::with_fixed_ephemeral_for_vectors(noise::Mode::NxPsk0, None, Some(&owner_psk), &e).unwrap();
    i.msg1().unwrap();
    assert_eq!(i.read_msg2(&h(&v["noise_nx"]["msg2"])).err(), Some(noise::Error::Msg2NotDecryptable));
    // NX with another device id in the prologue (a neighbour's unclaimed node answers with a real msg2 we cannot read)
    let mut i = noise::Initiator::with_fixed_ephemeral_for_vectors(noise::Mode::Nx, Some("0123a5f0c3e1b74def"), None, &e).unwrap();
    i.msg1().unwrap();
    assert_eq!(i.read_msg2(&h(&v["noise_nx"]["msg2"])).err(), Some(noise::Error::Msg2NotDecryptable));
    // fake msg2 (§fake_msg2_rule): same length as the real one, fresh ephemeral + random bytes -> does not decrypt
    let rule = &v["fake_msg2_rule"];
    let len = rule["length_equals_real_msg2"].as_u64().unwrap() as usize;
    assert_eq!(h(&v["noise_nxpsk0_owner"]["msg2"]).len(), len);
    let mut fake = h(&rule["fake_e_pub"]);
    fake.extend((0..len - fake.len()).map(|i| (i * 31 % 251) as u8));
    let mut i = noise::Initiator::with_fixed_ephemeral_for_vectors(noise::Mode::NxPsk0, None, Some(&owner_psk), &e).unwrap();
    i.msg1().unwrap();
    assert_eq!(i.read_msg2(&fake).err(), Some(noise::Error::Msg2NotDecryptable));
    // msg1 lengths: 32 B NX, 48 B NXpsk0 (what the node's length check keys on, noise.go:84)
    assert_eq!(h(&v["noise_nx"]["msg1"]).len(), 32);
    assert_eq!(h(&v["noise_nxpsk0_owner"]["msg1"]).len(), 48);
}

// ---- nodecert (design §5.1 step 2, §6, §8.2): the vector node_cert (DAC signed by the test root) through the common
// checks and pinning; one mutation per check must be refused with that check's error; the dev TOFU rule on
// identity_file (accepted) and its forged certificate (refused); first contact under both build policies.
use batman_proto::nodecert;

fn rs(v: &J) -> [u8; 32] {
    h(&v["keys"]["s_node_pub"]).try_into().unwrap()
}

/// node_cert with field `k` replaced (re-encoded deterministically)
fn with_field(v: &J, k: u64, val: cbor::Value) -> Vec<u8> {
    let mut m = cbor::decode(&h(&v["node_cert"]["cbor"])).unwrap();
    if let cbor::Value::Map(entries) = &mut m {
        for (key, value) in entries.iter_mut() {
            if *key == cbor::Value::Uint(k) {
                *value = val.clone();
            }
        }
    }
    cbor::encode(&m)
}

fn flip(mut b: Vec<u8>, i: usize) -> Vec<u8> {
    b[i] ^= 1;
    b
}

#[test]
fn node_cert_pinned_and_mutations() {
    let v = vectors();
    let cert = h(&v["node_cert"]["cbor"]);
    let dac = h(&v["keys"]["dac_cert_der"]);
    let got = nodecert::verify_pinned(&cert, &rs(&v), &dac).expect("vector node_cert verifies against its pinned DAC");
    assert_eq!(got.device_id, DEVICE_ID);
    assert_eq!(got.ecdh_pub.to_vec(), h(&v["keys"]["node_ecdh_pub"]));
    assert_eq!(got.dac_pub.to_vec(), h(&v["keys"]["dac_pub"]));
    // one negative per check
    let mut other_rs = rs(&v);
    other_rs[0] ^= 1;
    assert_eq!(nodecert::verify_pinned(&cert, &other_rs, &dac).err(), Some(nodecert::Error::StaticMismatch));
    let sig_static = h(&v["node_cert"]["sig_static"]);
    let c = with_field(&v, 5, cbor::Value::Bytes(flip(sig_static, 10)));
    assert_eq!(nodecert::verify_pinned(&c, &rs(&v), &dac).err(), Some(nodecert::Error::SigStatic));
    let c = with_field(&v, 3, cbor::Value::Bytes(vec![0u8; 16])); // another boot_id: sig_static no longer covers it
    assert_eq!(nodecert::verify_pinned(&c, &rs(&v), &dac).err(), Some(nodecert::Error::SigStatic));
    let sig_ecdh = h(&v["node_cert"]["sig_ecdh"]);
    let c = with_field(&v, 6, cbor::Value::Bytes(flip(sig_ecdh, 10)));
    assert_eq!(nodecert::verify_pinned(&c, &rs(&v), &dac).err(), Some(nodecert::Error::SigEcdh));
    let c = with_field(&v, 4, cbor::Value::Bytes(h(&v["keys"]["owner_enc_pub"]))); // a substituted ECDH key
    assert_eq!(nodecert::verify_pinned(&c, &rs(&v), &dac).err(), Some(nodecert::Error::SigEcdh));
    let c = with_field(&v, 7, cbor::Value::Bytes(flip(hex::decode(DEVICE_ID).unwrap(), 8)));
    assert_eq!(nodecert::verify_pinned(&c, &rs(&v), &dac).err(), Some(nodecert::Error::SnMismatch));
    // not the pinned DAC (e.g. the root certificate pinned instead)
    assert_eq!(
        nodecert::verify_pinned(&cert, &rs(&v), &h(&v["keys"]["root_ca_cert_der"])).err(),
        Some(nodecert::Error::NotPinned)
    );
}

#[test]
fn node_cert_first_contact_production_dac_is_untrusted_today() {
    // the vector DAC is root-signed (not dev:): no production root exists in the app yet -> both policies refuse it
    let v = vectors();
    let cert = h(&v["node_cert"]["cbor"]);
    for p in [nodecert::Policy::DevTofu, nodecert::Policy::Field] {
        assert_eq!(nodecert::verify_first_contact(&cert, &rs(&v), DEVICE_ID, p).err(), Some(nodecert::Error::Untrusted));
    }
    assert_eq!(
        nodecert::verify_first_contact(&cert, &rs(&v), "0123a5f0c3e1b74def", nodecert::Policy::DevTofu).err(),
        Some(nodecert::Error::DeviceIdMismatch)
    );
}

/// gen.py: dev_key = p256("dev-node"), d = int(seed) mod (n - 1) + 1 (computed with plain integer arithmetic; the test
/// checks it reproduces identity_file.dac_pub, so a wrong constant fails here, not silently)
const DEV_NODE_PRIV: &str = "1018ee07c7a494aa6b01e3afc3da234d5f664656dddcbd5f1022c0686f571769";

fn dev_signing_key(v: &J) -> p256::ecdsa::SigningKey {
    let sk = p256::ecdsa::SigningKey::from_slice(&hex::decode(DEV_NODE_PRIV).unwrap()).unwrap();
    let pub65 = sk.verifying_key().to_sec1_point(false).as_bytes().to_vec(); // ecdsa 0.17: uncompressed SEC1
    assert_eq!(pub65, h(&v["identity_file"]["dac_pub"]), "the dev fixture key does not match identity_file.dac_pub");
    sk
}

/// a node_cert signed by the dev DAC (the shape a P2 bench node sends: file keystore, self-signed dev: DAC)
fn dev_node_cert(v: &J) -> Vec<u8> {
    use p256::ecdsa::signature::Signer;
    let sk = dev_signing_key(v);
    let s_node = rs(v);
    let boot_id = vec![7u8; 16];
    let ecdh_pub = h(&v["keys"]["node_ecdh_pub"]);
    let mut m = nodecert::LABEL_STATIC.to_vec();
    m.extend(s_node);
    m.extend(&boot_id);
    let sig_static: p256::ecdsa::Signature = sk.sign(&m);
    let mut m = nodecert::LABEL_ECDH.to_vec();
    m.extend(&ecdh_pub);
    let sig_ecdh: p256::ecdsa::Signature = sk.sign(&m);
    use cbor::Value as V;
    cbor::encode(&V::Map(vec![
        (V::Uint(1), V::Array(vec![V::Bytes(h(&v["identity_file"]["dev_cert_der"]))])),
        (V::Uint(2), V::Bytes(s_node.to_vec())),
        (V::Uint(3), V::Bytes(boot_id)),
        (V::Uint(4), V::Bytes(ecdh_pub)),
        (V::Uint(5), V::Bytes(sig_static.to_bytes().to_vec())),
        (V::Uint(6), V::Bytes(sig_ecdh.to_bytes().to_vec())),
        (V::Uint(7), V::Bytes(h(&v["identity_file"]["sn"]))),
    ]))
}

#[test]
fn identity_file_dev_rule() {
    let v = vectors();
    let id = v["identity_file"]["device_id"].as_str().unwrap();
    let pub65: [u8; 65] = h(&v["identity_file"]["dac_pub"]).try_into().unwrap();
    let good = nodecert::parse(&h(&v["identity_file"]["dev_cert_der"])).unwrap();
    assert_eq!(nodecert::dev_rule(&good, &pub65, id), Ok(()));
    // the forged certificate: same CN / serialNumber, the stranger's own key -> its key does not hash to the id
    let forged = nodecert::parse(&h(&v["identity_file"]["forged_dev_cert_der"])).unwrap();
    let forged_pub: [u8; 65] = forged
        .tbs_certificate()
        .subject_public_key_info()
        .subject_public_key
        .raw_bytes()
        .try_into()
        .unwrap();
    assert!(matches!(nodecert::dev_rule(&forged, &forged_pub, id), Err(nodecert::Error::DevRule(_))));
    // the right key but the forged certificate's signature (not self-signed by that key)
    assert!(matches!(nodecert::dev_rule(&forged, &pub65, id), Err(nodecert::Error::DevRule(_))));
}

#[test]
fn first_contact_dev_tofu_accepts_and_field_refuses() {
    let v = vectors();
    let id = v["identity_file"]["device_id"].as_str().unwrap();
    let cert = dev_node_cert(&v);
    let ok = nodecert::verify_first_contact(&cert, &rs(&v), id, nodecert::Policy::DevTofu).expect("dev TOFU accepts");
    assert_eq!(ok.device_id, id);
    // the field build refuses every dev certificate (design §6; 219-protocol.md :396)
    assert_eq!(
        nodecert::verify_first_contact(&cert, &rs(&v), id, nodecert::Policy::Field).err(),
        Some(nodecert::Error::Untrusted)
    );
    // dev TOFU with the forged certificate in the chain (same id, stranger's key): its signatures do not verify under
    // the DAC it presents unless the stranger signed them — here the node's signatures were made with the real key
    let mut m = cbor::decode(&cert).unwrap();
    if let cbor::Value::Map(entries) = &mut m {
        entries[0].1 = cbor::Value::Array(vec![cbor::Value::Bytes(h(&v["identity_file"]["forged_dev_cert_der"]))]);
    }
    let forged = cbor::encode(&m);
    assert_eq!(
        nodecert::verify_first_contact(&forged, &rs(&v), id, nodecert::Policy::DevTofu).err(),
        Some(nodecert::Error::SigStatic)
    );
    // the wrong QR
    assert_eq!(
        nodecert::verify_first_contact(&cert, &rs(&v), DEVICE_ID, nodecert::Policy::DevTofu).err(),
        Some(nodecert::Error::DeviceIdMismatch)
    );
}

/// Negative controls (design §8.2 / §8.3): mutated vector encodings must be rejected by the strict decoder.
#[test]
fn mutated_envelopes_are_rejected() {
    let v = vectors();
    let good = h(&v["envelope"]["request_info"]); // a4 00 ... : a 4-entry map
    // non-shortest map head (0xb8 0x04 instead of 0xa4)
    let mut m = vec![0xb8, 0x04];
    m.extend(&good[1..]);
    assert_eq!(cbor::decode(&m), Err(cbor::Error::NotShortest));
    // swap the first two map entries -> unsorted keys: {1: 1, 0: [1, 0], ...}
    let d = cbor::decode(&good).unwrap();
    if let cbor::Value::Map(entries) = d {
        let mut raw = vec![0xa4];
        let enc: Vec<(Vec<u8>, Vec<u8>)> = entries.iter().map(|(k, v)| (cbor::encode(k), cbor::encode(v))).collect();
        for i in [1usize, 0, 2, 3] {
            raw.extend(&enc[i].0);
            raw.extend(&enc[i].1);
        }
        assert_eq!(cbor::decode(&raw), Err(cbor::Error::UnsortedOrDuplicateKey));
    } else {
        panic!("request_info is not a map");
    }
    // trailing byte
    let mut t = good.clone();
    t.push(0x00);
    assert_eq!(cbor::decode(&t), Err(cbor::Error::TrailingBytes));
}
