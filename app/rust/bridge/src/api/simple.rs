//! The Dart-visible API (flutter_rust_bridge 2.13.0). First slice: build facts and an on-device self-test of the core.

use batman_proto::{cbor, kdf, nodecert};

/// What this native library was built with; Dart compares `dev_trust` with the flavor's BuildConfig at startup and
/// disables the app on a mismatch (design v8.5.1 §4.1).
pub struct BuildInfo {
    pub dev_trust: bool,
    pub crate_version: String,
}

#[flutter_rust_bridge::frb(sync)]
pub fn build_info() -> BuildInfo {
    BuildInfo { dev_trust: nodecert::DEV_TRUST, crate_version: env!("CARGO_PKG_VERSION").to_string() }
}

/// Runs a few core operations on the device and reports them: a strict CBOR round trip and an HKDF output prefix.
#[flutter_rust_bridge::frb(sync)]
pub fn selftest() -> String {
    let v = cbor::Value::Map(vec![(cbor::Value::Uint(2), cbor::Value::Text("info".into())), (cbor::Value::Uint(1), cbor::Value::Uint(7))]);
    let enc = cbor::encode(&v);
    let rt = cbor::decode(&enc).map(|d| cbor::encode(&d) == enc).unwrap_or(false);
    let k = kdf::psk_owner(&[0x5c; 32], "abcdef012345678901");
    format!("cbor_roundtrip={rt} cbor={} psk_owner[..4]={}", nodecert::hex_lower(&enc), nodecert::hex_lower(&k[..4]))
}

#[flutter_rust_bridge::frb(init)]
pub fn init_app() {
    flutter_rust_bridge::setup_default_user_utils();
}
