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

// ---- install marker (design v8.5.1 §3 / §4.1): `meta/install-v1` in the record store, plaintext (aliases + read-back
// levels, no secrets), display-only. Written once, after all four keys passed; before any record exists.
const MARKER: &str = "meta/install-v1";
const RECORD_KINDS: [&str; 3] = ["node", "claim-pending", "net"];

/// The marker's content, or None when there is none.
pub fn store_read_marker(dir: String) -> Result<Option<String>, String> {
    let s = batman_proto::store::Store::new(dir);
    match s.read(MARKER).map_err(|e| format!("{e:?}"))? {
        None => Ok(None),
        Some(r) => String::from_utf8(r.sealed).map(Some).map_err(|_| "marker is not UTF-8".to_string()),
    }
}

/// Whether any record exists (then keys are never deleted, even without a marker — design §4.1).
pub fn store_has_records(dir: String) -> bool {
    let root = std::path::Path::new(&dir);
    RECORD_KINDS.iter().any(|k| std::fs::read_dir(root.join(k)).map(|mut d| d.any(|e| e.is_ok_and(|e| !e.file_name().to_string_lossy().starts_with('.')))).unwrap_or(false))
}

/// Write the marker (atomic, synced). Refused when one already exists.
pub fn store_write_marker(dir: String, content: String) -> Result<(), String> {
    let s = batman_proto::store::Store::new(dir);
    if s.read(MARKER).map_err(|e| format!("{e:?}"))?.is_some() {
        return Err("marker already written".into());
    }
    s.write(MARKER, 1, content.as_bytes()).map_err(|e| format!("{e:?}"))
}

/// Remove left-over temp files of a write interrupted by a crash.
pub fn store_sweep(dir: String) -> Result<u32, String> {
    batman_proto::store::Store::new(dir).sweep_temps().map(|n| n as u32).map_err(|e| format!("{e:?}"))
}

#[flutter_rust_bridge::frb(init)]
pub fn init_app() {
    flutter_rust_bridge::setup_default_user_utils();
}
