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
    ("auth_owner", "tested"),
    ("claim_checkmac", "tested"),
    ("owner_enc", "tested"),
    ("owner_op", "tested"),
    ("op_nonce", "tested"),
    ("claim_replay", "tested"),
    ("cose", "tested (net_config, member_list, net_secrets; the invite / join-request / approval objects are not in S1)"),
    ("chunk_boundary", "tested"),
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

// ---- claim / signature inputs: built byte-exact; the vectors' signatures verify under the vector public keys over the
// bytes WE built (so the input really is what the owner key signs); low-s / DER handling for the Keystore's output
use batman_proto::{claim, sig};

fn a32(v: &J) -> [u8; 32] {
    h(v).try_into().unwrap()
}
fn a65(v: &J) -> [u8; 65] {
    h(v).try_into().unwrap()
}
fn sn() -> [u8; 9] {
    hex::decode(DEVICE_ID).unwrap().try_into().unwrap()
}
fn es256_ok(pub65: &[u8], msg: &[u8], sig64: &[u8]) -> bool {
    use p256::ecdsa::signature::Verifier;
    let vk = p256::ecdsa::VerifyingKey::from_sec1_bytes(pub65).unwrap();
    vk.verify(msg, &p256::ecdsa::Signature::from_slice(sig64).unwrap()).is_ok()
}

#[test]
fn claim_checkmac_vector() {
    let v = vectors();
    let c = &v["claim_checkmac"];
    let k: [u8; 32] = seed("claim_secret").try_into().unwrap();
    let hh = a32(&v["noise_nx"]["handshake_hash"]);
    let dac = h(&v["keys"]["dac_cert_der"]);
    let owner = a65(&v["keys"]["owner_sign_pub"]);
    let chal = claim::client_chal(&a32(&c["nonce"]), &hh, &dac, &owner);
    assert_eq!(chal.to_vec(), h(&c["client_chal"]));
    assert_eq!(claim::OTHER_DATA.to_vec(), h(&c["other_data"]));
    assert_eq!(claim::checkmac_input(&k, &chal, &sn()).to_vec(), h(&c["checkmac_input_88B"]));
    assert_eq!(claim::response(&k, &a32(&c["nonce"]), &hh, &dac, &owner, &sn()).to_vec(), h(&c["response"]));
    // negatives: another session's h, another K, another owner key -> another response
    let other_h = a32(&v["noise_nxpsk0_owner"]["handshake_hash"]);
    assert_ne!(claim::response(&k, &a32(&c["nonce"]), &other_h, &dac, &owner, &sn()).to_vec(), h(&c["response"]));
    let mut k2 = k;
    k2[0] ^= 1;
    assert_ne!(claim::response(&k2, &a32(&c["nonce"]), &hh, &dac, &owner, &sn()).to_vec(), h(&c["response"]));
    assert_ne!(
        claim::response(&k, &a32(&c["nonce"]), &hh, &dac, &a65(&v["keys"]["admin_pub"]), &sn()).to_vec(),
        h(&c["response"])
    );
}

#[test]
fn owner_enc_and_auth_owner_vectors() {
    let v = vectors();
    let owner = a65(&v["keys"]["owner_sign_pub"]);
    let enc_in = sig::owner_enc_input(&a65(&v["keys"]["owner_enc_pub"]));
    assert_eq!(enc_in, h(&v["owner_enc"]["sig_enc_input"]));
    assert!(es256_ok(&owner, &enc_in, &h(&v["owner_enc"]["sig_enc"])));
    let a = &v["auth_owner"];
    assert_eq!(sig::owner_key_id(&owner).to_vec(), h(&a["owner_key_id"]));
    let hh = a32(&v["noise_nxpsk0_owner"]["handshake_hash"]);
    let ai = sig::auth_owner_input(&hh, &owner);
    assert_eq!(ai, h(&a["input"]));
    assert!(es256_ok(&owner, &ai, &h(&a["sig"])));
    // the auth signature does not verify over another session's h (channel binding)
    let other = sig::auth_owner_input(&a32(&v["noise_nx"]["handshake_hash"]), &owner);
    assert!(!es256_ok(&owner, &other, &h(&a["sig"])));
}

#[test]
fn op_nonce_vector() {
    let v = vectors();
    assert_eq!(sig::request(2, "op/nonce", cbor::Value::Map(vec![])), h(&v["op_nonce"]["request"]));
    let r = cbor::decode(&h(&v["op_nonce"]["response"])).unwrap();
    let nonce = r.get(3).and_then(|b| b.get(1)).and_then(|n| n.as_bytes()).unwrap();
    assert_eq!(nonce.to_vec(), h(&v["owner_op"]["nonce_helper"]));
}

#[test]
fn owner_op_network_join_vector() {
    let v = vectors();
    let o = &v["owner_op"];
    let req = cbor::decode(&h(&o["request_network_join"])).unwrap();
    assert_eq!(req.get(2).and_then(|t| t.as_text()), Some("network/join"));
    // the body without key 31, re-encoded deterministically, gives the vector's args_hash
    let body = req.get(3).unwrap();
    let cbor::Value::Map(entries) = body else { panic!("body is not a map") };
    let without: Vec<_> = entries.iter().filter(|(k, _)| *k != cbor::Value::Uint(31)).cloned().collect();
    let body_wo = cbor::Value::Map(without);
    assert_eq!(sig::args_hash(&body_wo).unwrap().to_vec(), h(&o["args_hash"]));
    let hh = a32(&v["noise_nxpsk0_owner"]["handshake_hash"]);
    let input = sig::owner_op_input(&hh, &a32(&o["nonce_helper"]), "network/join", &body_wo).unwrap();
    assert_eq!(input, h(&o["input"]));
    assert!(es256_ok(&h(&v["keys"]["owner_sign_pub"]), &input, &h(&o["sig"])));
    // the vector request's key 31 is exactly {1: verb, 2: sig}
    let op = body.get(31).unwrap();
    assert_eq!(op.get(1).and_then(|t| t.as_text()), Some("network/join"));
    assert_eq!(op.get(2).and_then(|s| s.as_bytes()).map(|s| s.to_vec()), Some(h(&o["sig"])));
    // the type-mismatch vector cannot be produced by owner_op_request: there, type != op verb
    let mm = cbor::decode(&h(&o["request_type_mismatch"])).unwrap();
    let mm_type = mm.get(2).and_then(|t| t.as_text()).unwrap();
    let mm_verb = mm.get(3).and_then(|b| b.get(31)).and_then(|op| op.get(1)).and_then(|t| t.as_text()).unwrap();
    assert_ne!(mm_type, mm_verb);
    // a body that already has key 31 is refused
    assert_eq!(sig::args_hash(body).err(), Some(sig::Error::BodyHasOwnerOp));
}

#[test]
fn claim_replay_vector_byte_exact() {
    let v = vectors();
    let c = &v["claim_replay"];
    let k: [u8; 32] = seed("claim_secret").try_into().unwrap();
    let hh = a32(&v["noise_nxpsk0_replay"]["handshake_hash"]);
    let dac = h(&v["keys"]["dac_cert_der"]);
    let owner = a65(&v["keys"]["owner_sign_pub"]);
    assert_eq!(claim::client_chal(&a32(&c["nonce"]), &hh, &dac, &owner).to_vec(), h(&c["client_chal"]));
    let resp = claim::response(&k, &a32(&c["nonce"]), &hh, &dac, &owner, &sn());
    assert_eq!(resp.to_vec(), h(&c["response"]));
    let body = cbor::Value::Map(vec![(cbor::Value::Uint(1), cbor::Value::Bytes(resp.to_vec()))]);
    let input = sig::owner_op_input(&hh, &a32(&c["nonce_helper"]), "claim/replay", &body).unwrap();
    assert_eq!(input, h(&c["owner_op_input"]));
    assert!(es256_ok(&owner, &input, &h(&c["owner_op_sig"])));
    let sig64: [u8; 64] = h(&c["owner_op_sig"]).try_into().unwrap();
    assert_eq!(sig::owner_op_request(4, "claim/replay", &body, &sig64).unwrap(), h(&c["request"]));
    // the response: {1: id, 3: {1: owner_tag_key, 2: adv_owner_key, 3: root_password}, 4: 0}
    let r = cbor::decode(&h(&c["response_envelope"])).unwrap();
    assert_eq!(r.get(4).and_then(|x| x.as_uint()), Some(0));
    assert_eq!(r.get(3).and_then(|b| b.get(1)).and_then(|x| x.as_bytes()).map(|x| x.to_vec()), Some(seed("owner_tag_key")));
}

/// n - s for a 32-byte big-endian s (the high-s twin of a low-s signature)
fn n_minus(s: &[u8]) -> [u8; 32] {
    let n = hex::decode("ffffffff00000000ffffffffffffffffbce6faada7179e84f3b9cac2fc632551").unwrap();
    let mut out = [0u8; 32];
    let mut borrow = 0i16;
    for i in (0..32).rev() {
        let d = n[i] as i16 - s[i] as i16 - borrow;
        borrow = if d < 0 { 1 } else { 0 };
        out[i] = (d + 256 * borrow) as u8;
    }
    out
}

#[test]
fn low_s_and_der_handling() {
    let v = vectors();
    let low: [u8; 64] = h(&v["auth_owner"]["sig"]).try_into().unwrap();
    assert!(sig::is_low_s(&low), "the vector signature is low-s");
    let mut high = low;
    high[32..].copy_from_slice(&n_minus(&low[32..]));
    assert!(!sig::is_low_s(&high));
    assert_eq!(sig::normalize_raw(&high).unwrap(), low);
    // a DER signature (what Keystore returns), in both forms, comes out as the same raw low-s
    for raw in [low, high] {
        let der = p256::ecdsa::Signature::from_slice(&raw).unwrap().to_der();
        assert_eq!(sig::der_to_raw_low_s(der.as_bytes()).unwrap(), low);
    }
    assert_eq!(sig::der_to_raw_low_s(&[0x30, 0x02, 0x02, 0x00]).err(), Some(sig::Error::BadDer));
}

// ---- cose: payloads built here from gen.py's inputs equal the vector payloads; the Sig_structure we build verifies with
// the vector signature under admin_pub; the assembled Sign1 is byte-exact; net_secrets' ECDH-ES with the fixed ephemeral
// / IV gives the vector z, KDF context, CEK and Enc_structure; the random path decrypts with the node's ECDH key.
use batman_proto::cose;

/// gen.py fixtures (int(seed) mod (n-1) + 1), checked against the vector public keys / z below
const COSE_EPH_PRIV: &str = "9c6f293ecdd80a1d07769a04ee80140c13f73d0c874a0463670881cc1da442ff";
const NODE_ECDH_PRIV: &str = "5fc9a2c8dc0c10edeec4d50654765f2d4aee146880e072d036f584e55bbf3764";

/// the signature inside a vector Sign1 (tag 18 [prot, {}, payload, sig])
fn sign1_sig(raw: &[u8]) -> [u8; 64] {
    match cbor::decode(raw).unwrap() {
        cbor::Value::Tag(18, a) => match *a {
            cbor::Value::Array(x) => x[3].as_bytes().unwrap().try_into().unwrap(),
            _ => panic!("Sign1 is not an array"),
        },
        _ => panic!("not tag 18"),
    }
}

fn net_id() -> [u8; 16] {
    seed("net_id")[..16].try_into().unwrap()
}

#[test]
fn cose_net_config_vector() {
    let v = vectors();
    let c = &v["cose"]["net_config"];
    let admin = a65(&v["keys"]["admin_pub"]);
    let p = cose::net_config_payload(&net_id(), 1, None, "家裡網路", "TW", "batman-test", 40, 4, &[admin]);
    assert_eq!(p, h(&c["payload"]));
    let tbs = cose::sign1_tbs(cose::CT_NETCFG, cose::LABEL_NETCFG, &p);
    assert_eq!(tbs, h(&c["sig_structure"]));
    let s = sign1_sig(&h(&c["sign1"]));
    assert!(es256_ok(&admin, &tbs, &s), "the vector signature verifies over our Sig_structure under admin_pub");
    assert_eq!(cose::sign1(cose::CT_NETCFG, &p, &s), h(&c["sign1"]));
    // another content type / label is another Sig_structure (the admin signature does not carry over)
    assert!(!es256_ok(&admin, &cose::sign1_tbs(cose::CT_MEMBERS, cose::LABEL_MEMBERS, &p), &s));
}

#[test]
fn cose_member_list_vector() {
    let v = vectors();
    let c = &v["cose"]["member_list"];
    let m = cose::Member {
        dac_pub_hash: &a32(&v["keys"]["dac_pub_hash"]),
        ecdh_pub: &a65(&v["keys"]["node_ecdh_pub"]),
        name: "客廳",
        owner_pub: &a65(&v["keys"]["owner_sign_pub"]),
        owner_enc_pub: &a65(&v["keys"]["owner_enc_pub"]),
    };
    let p = cose::member_list_payload(&net_id(), 1, None, &[m]);
    assert_eq!(p, h(&c["payload"]));
    let tbs = cose::sign1_tbs(cose::CT_MEMBERS, cose::LABEL_MEMBERS, &p);
    assert_eq!(tbs, h(&c["sig_structure"]));
    let s = sign1_sig(&h(&c["sign1"]));
    assert!(es256_ok(&h(&v["keys"]["admin_pub"]), &tbs, &s));
    assert_eq!(cose::sign1(cose::CT_MEMBERS, &p, &s), h(&c["sign1"]));
}

#[test]
fn cose_net_secrets_vector() {
    let v = vectors();
    let c = &v["cose"]["net_secrets"];
    let node_ecdh = a65(&v["keys"]["node_ecdh_pub"]);
    let dac_hash = a32(&v["keys"]["dac_pub_hash"]);
    let eph: [u8; 32] = hex::decode(COSE_EPH_PRIV).unwrap().try_into().unwrap();
    let iv: [u8; 12] = seed("iv-secrets")[..12].try_into().unwrap();
    let e = cose::encrypt_with_fixed_for_vectors(&h(&c["plaintext"]), cose::LABEL_SECRETS, &node_ecdh, &dac_hash, &net_id(), 1, &eph, &iv)
        .unwrap();
    assert_eq!(e.z.to_vec(), h(&c["ecdh_z"]), "ECDH z (also checks the ephemeral fixture)");
    assert_eq!(e.kdf_context, h(&c["kdf_context"]));
    assert_eq!(e.cek.to_vec(), h(&c["cek"]));
    assert_eq!(e.enc_structure, h(&c["enc_structure"]));
    let p = cose::net_secrets_payload(&net_id(), 1, &dac_hash, &e.object);
    let s = sign1_sig(&h(&c["sign1"]));
    let tbs = cose::sign1_tbs(cose::CT_SECRETS, cose::LABEL_SECRETS, &p);
    assert!(es256_ok(&h(&v["keys"]["admin_pub"]), &tbs, &s));
    assert_eq!(cose::sign1(cose::CT_SECRETS, &p, &s), h(&c["sign1"]), "net_secrets Sign1 byte-exact");
    // another target hash -> another KDF context -> another CEK
    let mut other = dac_hash;
    other[0] ^= 1;
    let e2 = cose::encrypt_with_fixed_for_vectors(&h(&c["plaintext"]), cose::LABEL_SECRETS, &node_ecdh, &other, &net_id(), 1, &eph, &iv)
        .unwrap();
    assert_ne!(e2.cek.to_vec(), h(&c["cek"]));
}

/// The release path (fresh ephemeral + IV): two encryptions differ, and the node's ECDH key decrypts both to the
/// plaintext — the recipient side recomputed here independently of encrypt_inner's code path.
#[test]
fn cose_random_path_decrypts_at_the_node() {
    use chacha20poly1305::aead::{Aead, KeyInit, Payload};
    let v = vectors();
    let node_ecdh = a65(&v["keys"]["node_ecdh_pub"]);
    let node_priv = p256::SecretKey::from_slice(&hex::decode(NODE_ECDH_PRIV).unwrap()).unwrap();
    {
        use p256::elliptic_curve::sec1::ToSec1Point;
        assert_eq!(node_priv.public_key().to_sec1_point(false).as_bytes().to_vec(), node_ecdh.to_vec(), "node-ecdh fixture");
    }
    let dac_hash = a32(&v["keys"]["dac_pub_hash"]);
    let plain = b"{1: sae, 2: net_root} stand-in";
    let mut cts = vec![];
    for _ in 0..2 {
        let e = cose::encrypt_to(plain, cose::LABEL_SECRETS, &node_ecdh, &dac_hash, &net_id(), 1).unwrap();
        let cbor::Value::Tag(96, arr) = &e.object else { panic!("not tag 96") };
        let cbor::Value::Array(a) = arr.as_ref() else { panic!() };
        let iv = a[1].get(5).unwrap().as_bytes().unwrap().to_vec();
        let ct = a[2].as_bytes().unwrap().to_vec();
        // recipient: rebuild the ephemeral public key from the COSE_Key and do ECDH with the node's key
        let cbor::Value::Array(rec) = &a[3] else { panic!() };
        let cbor::Value::Array(r0) = &rec[0] else { panic!() };
        let ck = r0[1].get(0).or_else(|| {
            // the unprotected header key is -1 (Nint(0)); get() only looks up uint keys
            if let cbor::Value::Map(m) = &r0[1] { m.iter().find(|(k, _)| *k == cbor::Value::Nint(0)).map(|(_, v)| v) } else { None }
        });
        let cbor::Value::Map(ckm) = ck.unwrap() else { panic!() };
        let coord = |n: u64| ckm.iter().find(|(k, _)| *k == cbor::Value::Nint(n)).unwrap().1.as_bytes().unwrap().to_vec();
        let mut epk = vec![4u8];
        epk.extend(coord(1));
        epk.extend(coord(2));
        let eph_pub = p256::PublicKey::from_sec1_bytes(&epk).unwrap();
        let z = p256::ecdh::diffie_hellman(node_priv.to_nonzero_scalar(), eph_pub.as_affine());
        assert_eq!(z.raw_secret_bytes().as_slice(), &e.z[..]);
        let cek = batman_proto::kdf::hkdf32(&e.z, &e.kdf_context);
        let pt = chacha20poly1305::ChaCha20Poly1305::new(chacha20poly1305::Key::from_slice(&cek))
            .decrypt(chacha20poly1305::Nonce::from_slice(&iv), Payload { msg: &ct, aad: &e.enc_structure })
            .expect("the node decrypts the release-path ciphertext");
        assert_eq!(pt, plain);
        cts.push((iv, ct));
    }
    assert_ne!(cts[0].1, cts[1].1, "fresh ephemeral each time (different ciphertext)");
    // the IV itself must be fresh too (design §2): a fixed IV would hide behind the fresh ephemeral above
    assert_ne!(cts[0].0, cts[1].0, "fresh IV each time");
    assert_ne!(cts[0].0, vec![0u8; 12]);
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

// ---- envelope: chunk_boundary, chunk building, response reader ------------------------------------------------------
use batman_proto::envelope::{self, Outcome, ResponseReader};

#[test]
fn chunk_boundary_vector() {
    let v = vectors();
    let c = &v["chunk_boundary"];
    let limit = c["limit_plaintext"].as_u64().unwrap() as usize;
    assert_eq!(limit, c["max_msg"].as_u64().unwrap() as usize - 16);
    // worst case: id 2^32-1, part 65535/65535, an idem key, type network/update
    let (id, verb, idem) = (u32::MAX as u64, "network/update", [0xa5u8; 16]);
    let s = envelope::max_slice(limit, id, verb, Some(&idem), 65535, 65535).unwrap();
    assert_eq!(s as u64, c["max_body_slice"].as_u64().unwrap());
    let at = envelope::chunk_request(id, verb, Some(&idem), &vec![0u8; s], 65535, 65535);
    let over = envelope::chunk_request(id, verb, Some(&idem), &vec![0u8; s + 1], 65535, 65535);
    assert_eq!(at.len() as u64, c["envelope_len_at_max"].as_u64().unwrap());
    assert_eq!(over.len() as u64, c["envelope_len_at_max_plus_1"].as_u64().unwrap());
}

#[test]
fn chunking_vector_rebuilt_byte_exact() {
    let v = vectors();
    for k in ["chunk1", "chunk2"] {
        let b = h(&v["chunking"][k]);
        let c = cbor::decode(&b).unwrap();
        let idem: Option<[u8; 16]> = c.get(7).map(|x| x.as_bytes().unwrap().try_into().unwrap());
        let part = c.get(6).unwrap();
        let rebuilt = envelope::chunk_request(
            c.get(1).and_then(|x| x.as_uint()).unwrap(),
            c.get(2).and_then(|x| x.as_text()).unwrap(),
            idem.as_ref(),
            c.get(3).and_then(|x| x.as_bytes()).unwrap(),
            part.get(1).and_then(|x| x.as_uint()).unwrap(),
            part.get(2).and_then(|x| x.as_uint()).unwrap(),
        );
        assert_eq!(rebuilt, b, "{k}");
    }
}

#[test]
fn split_request_whole_or_chunks_within_limit() {
    let v = vectors();
    let body = cbor::decode(&h(&v["chunking"]["body"])).unwrap();
    let enc = h(&v["chunking"]["body"]);
    // fits: one whole envelope, the same bytes as sig::request
    let one = envelope::split_request(9, "network/join", body.clone(), 65535).unwrap();
    assert_eq!(one, vec![batman_proto::sig::request(9, "network/join", body.clone())]);
    // does not fit: every chunk within max_msg - 16, same id, n = 1..total, the slices join to the encoded body
    for max_msg in [200usize, 256, 300, 512, 700] {
        let cs = envelope::split_request(9, "network/join", body.clone(), max_msg).unwrap();
        assert!(cs.len() >= 2, "{max_msg}");
        let mut joined: Vec<u8> = Vec::new();
        for (i, c) in cs.iter().enumerate() {
            assert!(c.len() <= max_msg - 16, "{max_msg}: chunk {} is {} B", i + 1, c.len());
            let d = cbor::decode(c).unwrap();
            assert_eq!(d.get(1).and_then(|x| x.as_uint()), Some(9));
            assert_eq!(d.get(6).unwrap().get(1).and_then(|x| x.as_uint()), Some(i as u64 + 1));
            assert_eq!(d.get(6).unwrap().get(2).and_then(|x| x.as_uint()), Some(cs.len() as u64));
            assert!(d.get(7).is_none(), "no idem key on P2");
            joined.extend(d.get(3).and_then(|x| x.as_bytes()).unwrap());
        }
        assert_eq!(joined, enc, "{max_msg}");
    }
    assert_eq!(envelope::split_request(9, "network/join", body, 40), Err(envelope::Error::LimitTooSmall));
}

fn resp(pairs: Vec<(u64, cbor::Value)>) -> Vec<u8> {
    cbor::encode(&cbor::Value::Map(pairs.into_iter().map(|(k, v)| (cbor::Value::Uint(k), v)).collect()))
}
fn part(n: u64, t: u64) -> cbor::Value {
    cbor::Value::Map(vec![(cbor::Value::Uint(1), cbor::Value::Uint(n)), (cbor::Value::Uint(2), cbor::Value::Uint(t))])
}

#[test]
fn response_reader_vectors_and_negatives() {
    use cbor::Value as V;
    let v = vectors();
    let ok = h(&v["envelope"]["response_info"]);
    let id = cbor::decode(&ok).unwrap().get(1).and_then(|x| x.as_uint()).unwrap();
    match ResponseReader::new(id).push(&ok).unwrap() {
        Some(Outcome::Ok(V::Map(_))) => {}
        o => panic!("response_info: {o:?}"),
    }
    let er = h(&v["envelope"]["response_error_lock_incomplete"]);
    let eid = cbor::decode(&er).unwrap().get(1).and_then(|x| x.as_uint()).unwrap();
    assert!(matches!(ResponseReader::new(eid).push(&er).unwrap(), Some(Outcome::Err { code: 13, .. })));
    // the response to another request
    assert_eq!(ResponseReader::new(id + 1).push(&ok), Err(envelope::Error::WrongId { want: id + 1, got: id }));
    // a request-shaped message (key 0) is not a response
    assert_eq!(ResponseReader::new(1).push(&h(&v["envelope"]["request_info"])), Err(envelope::Error::UnknownKey(0)));
    // an error with a body / a success with an error detail / a non-map body
    let det = V::Map(vec![(V::Uint(2), V::Uint(1))]);
    let empty = V::Map(vec![]);
    assert_eq!(ResponseReader::new(1).push(&resp(vec![(1, V::Uint(1)), (3, empty.clone()), (4, V::Uint(5)), (5, det.clone())])), Err(envelope::Error::BadStatus));
    assert_eq!(ResponseReader::new(1).push(&resp(vec![(1, V::Uint(1)), (3, empty.clone()), (4, V::Uint(0)), (5, det)])), Err(envelope::Error::BadStatus));
    assert_eq!(ResponseReader::new(1).push(&resp(vec![(1, V::Uint(1)), (3, V::Bytes(vec![0xa0])), (4, V::Uint(0))])), Err(envelope::Error::BadStatus));

    // a chunked response: in order, out of order, and the refusals
    let body = h(&v["chunking"]["body"]);
    let (a, b) = body.split_at(body.len() / 2);
    let c = |n: u64, t: u64, s: &[u8]| resp(vec![(1, V::Uint(7)), (3, V::Bytes(s.to_vec())), (4, V::Uint(0)), (6, part(n, t))]);
    let want = cbor::decode(&body).unwrap();
    for order in [[1u64, 2], [2, 1]] {
        let mut r = ResponseReader::new(7);
        let mut out = None;
        for n in order {
            out = r.push(&c(n, 2, if n == 1 { a } else { b })).unwrap();
            if n == order[0] {
                assert!(out.is_none());
            }
        }
        assert_eq!(out, Some(Outcome::Ok(want.clone())));
    }
    let mut r = ResponseReader::new(7);
    r.push(&c(1, 2, a)).unwrap();
    assert_eq!(r.push(&c(1, 2, a)), Err(envelope::Error::DuplicatePart(1)));
    let mut r = ResponseReader::new(7);
    r.push(&c(1, 2, a)).unwrap();
    assert_eq!(r.push(&c(2, 3, b)), Err(envelope::Error::PartTotalChanged));
    let mut r = ResponseReader::new(7);
    r.push(&c(1, 2, a)).unwrap();
    assert_eq!(r.push(&ok_with_id(&ok, 7)), Err(envelope::Error::BadPart), "a whole response in the middle of a chunked one");
    for (n, t) in [(0u64, 2u64), (3, 2), (1, 1)] {
        assert_eq!(ResponseReader::new(7).push(&c(n, t, a)), Err(envelope::Error::BadPart), "part {n}/{t}");
    }
    // the reassembled size cap
    let mut r = ResponseReader::new(7);
    let big = vec![0u8; envelope::MAX_REASSEMBLED / 2 + 1];
    r.push(&c(1, 3, &big)).unwrap();
    assert_eq!(r.push(&c(2, 3, &big)), Err(envelope::Error::TooLarge));
}

fn ok_with_id(ok: &[u8], id: u64) -> Vec<u8> {
    let cbor::Value::Map(mut m) = cbor::decode(ok).unwrap() else { panic!() };
    for (k, v) in m.iter_mut() {
        if *k == cbor::Value::Uint(1) {
            *v = cbor::Value::Uint(id);
        }
    }
    cbor::encode(&cbor::Value::Map(m))
}
