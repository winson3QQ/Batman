//! nodecert::verify_offline's trust gate in BOTH builds (254-app-member-join M4): a join request's node_cert with a
//! non-dev DAC is Untrusted (no production root yet); a dev: DAC passes only a dev-trust build.

use batman_proto::cbor::{self, Value as V};
use batman_proto::{nodecert, sig};
use p256::ecdsa::signature::Signer;
use serde_json::Value as J;
use std::path::PathBuf;

const DEV_NODE_PRIV: &str = "1018ee07c7a494aa6b01e3afc3da234d5f664656dddcbd5f1022c0686f571769";

fn vectors() -> J {
    let p = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../../tests/vectors/219-protocol/vectors.json");
    serde_json::from_str(&std::fs::read_to_string(p).unwrap()).unwrap()
}
fn h(v: &J) -> Vec<u8> {
    hex::decode(v.as_str().unwrap()).unwrap()
}

fn dev_node_cert(v: &J) -> Vec<u8> {
    let k = p256::ecdsa::SigningKey::from_slice(&hex::decode(DEV_NODE_PRIV).unwrap()).unwrap();
    let raw = |m: &[u8]| -> Vec<u8> {
        let s: p256::ecdsa::Signature = k.sign(m);
        sig::der_to_raw_low_s(s.to_der().as_bytes()).unwrap().to_vec()
    };
    let s_node = h(&v["keys"]["s_node_pub"]);
    let boot_id = vec![7u8; 16];
    let ecdh_pub = h(&v["keys"]["node_ecdh_pub"]);
    let mut a = nodecert::LABEL_STATIC.to_vec();
    a.extend(&s_node);
    a.extend(&boot_id);
    let mut b = nodecert::LABEL_ECDH.to_vec();
    b.extend(&ecdh_pub);
    let m = |pairs: Vec<(u64, V)>| V::Map(pairs.into_iter().map(|(k, v)| (V::Uint(k), v)).collect());
    cbor::encode(&m(vec![
        (1, V::Array(vec![V::Bytes(h(&v["identity_file"]["dev_cert_der"]))])),
        (2, V::Bytes(s_node)),
        (3, V::Bytes(boot_id)),
        (4, V::Bytes(ecdh_pub)),
        (5, V::Bytes(raw(&a))),
        (6, V::Bytes(raw(&b))),
        (7, V::Bytes(h(&v["identity_file"]["sn"]))),
    ]))
}

#[test]
fn verify_offline_trust_gate_in_this_build() {
    let v = vectors();
    assert_eq!(nodecert::verify_offline(&h(&v["node_cert"]["cbor"])), Err(nodecert::Error::Untrusted), "a test-root DAC");
    let r = nodecert::verify_offline(&dev_node_cert(&v));
    if nodecert::DEV_TRUST {
        assert_eq!(r.unwrap().device_id, v["identity_file"]["device_id"].as_str().unwrap());
    } else {
        assert_eq!(r, Err(nodecert::Error::Untrusted), "a field build refuses every dev: DAC");
    }
}
