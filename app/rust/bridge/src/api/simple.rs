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
// member-join §3 (R20): a member phone's mpend / mnet are records too: they keep the keys from being regenerated
const RECORD_KINDS: [&str; 7] =
    ["node", "claim-pending", "net", "mnet", "mpend", crate::api::claim::FORGOTTEN_NODE, crate::api::claim::FORGOTTEN_PENDING];

/// The marker's content, or None when there is none.
pub fn store_read_marker(dir: String) -> Result<Option<String>, String> {
    let s = batman_proto::store::Store::new(dir);
    match s.read(MARKER).map_err(|e| format!("{e:?}"))? {
        None => Ok(None),
        Some(r) => String::from_utf8(r.sealed).map(Some).map_err(|_| "安裝紀錄不是文字\u{1E}marker is not UTF-8\u{1F}".to_string()),
    }
}

/// Whether any record exists (then keys are never deleted, even without a marker — design §4.1).
///
/// #329 PR 7 T14, three states: a kind's folder that does not exist = none of that kind (a first install); any other
/// error reading a kind's folder or one of its entries (the kind's path is a plain file: ENOTDIR; a permission or I/O
/// error) = Err, never "no record" — the caller (`_install`) then generates no key over records it could not see. A
/// record seen anywhere = true, even when another folder or entry erred (every kind is read before an error counts).
pub fn store_has_records(dir: String) -> Result<bool, String> {
    // (member-join M15 / #329 PR 7 T14: tests below)
    let root = std::path::Path::new(&dir);
    let mut err: Option<String> = None;
    for k in RECORD_KINDS {
        let entries = match std::fs::read_dir(root.join(k)) {
            Ok(d) => d,
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => continue,
            Err(e) => {
                err.get_or_insert(format!("{k}: {e}"));
                continue;
            }
        };
        for e in entries {
            match e {
                Ok(e) if !e.file_name().to_string_lossy().starts_with('.') => return Ok(true),
                Ok(_) => {}
                Err(e) => {
                    err.get_or_insert(format!("{k}/: {e}"));
                }
            }
        }
    }
    match err {
        None => Ok(false),
        Some(e) => Err(format!("讀不到手機裡的紀錄\u{1E}record store unreadable: {e}\u{1F}")),
    }
}

/// Write the marker (atomic, synced). Refused when one already exists.
pub fn store_write_marker(dir: String, content: String) -> Result<(), String> {
    let s = batman_proto::store::Store::new(dir);
    if s.read(MARKER).map_err(|e| format!("{e:?}"))?.is_some() {
        return Err("安裝紀錄已經存在\u{1E}marker already written\u{1F}".into());
    }
    s.write(MARKER, 1, content.as_bytes()).map_err(|e| format!("{e:?}"))
}

/// Remove left-over temp files of a write interrupted by a crash.
pub fn store_sweep(dir: String) -> Result<u32, String> {
    batman_proto::store::Store::new(dir).sweep_temps().map(|n| n as u32).map_err(|e| format!("{e:?}"))
}

/// The STATUS characteristic, decoded strictly (batman_proto::status; vectors `status_public`).
pub struct StatusInfo {
    pub state: String,
    pub trial: bool,
    pub id_last4: Option<String>,
    pub versions: Vec<u64>,
    pub transports: Vec<String>,
}

#[flutter_rust_bridge::frb(sync)]
pub fn decode_status(bytes: Vec<u8>) -> Result<StatusInfo, String> {
    let s = batman_proto::status::decode(&bytes).map_err(|e| format!("{e:?}"))?;
    Ok(StatusInfo {
        state: format!("{:?}", s.state).to_lowercase(),
        trial: s.trial,
        id_last4: s.id_last4,
        versions: s.versions,
        transports: s.transports,
    })
}

#[flutter_rust_bridge::frb(init)]
pub fn init_app() {
    flutter_rust_bridge::setup_default_user_utils();
}

#[cfg(test)]
mod tests {
    use super::*;

    /// M15 (member-join §3, R20): a phone holding only a member record (mnet / mpend) and no marker has records: its
    /// keys are never regenerated.
    #[test]
    fn m15_member_records_count_as_records() {
        // forgotten-*: copies kept by a re-claim (254-app-claim-noover R8)
        for kind in ["mnet", "mpend", "forgotten-node", "forgotten-pending"] {
            let d = std::env::temp_dir().join(format!("bm-kinds-{kind}-{}", std::process::id()));
            let _ = std::fs::remove_dir_all(&d);
            let dir = d.to_string_lossy().to_string();
            assert!(!store_has_records(dir.clone()).unwrap());
            batman_proto::store::Store::new(&d).write(&format!("{kind}/x"), 1, b"s").unwrap();
            assert!(store_has_records(dir).unwrap(), "{kind}");
            let _ = std::fs::remove_dir_all(d);
        }
    }

    /// #329 §4.6 T-U4: `ui/state-v1` is display memory, not a key record: a phone holding only it has no records (so
    /// the keys are made again and the old ui record is just unreadable), it is not listed as a node, and the sweep
    /// leaves it alone.
    #[test]
    fn t_u4_ui_is_not_a_record() {
        let d = std::env::temp_dir().join(format!("bm-ui-only-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&d);
        let dir = d.to_string_lossy().to_string();
        batman_proto::store::Store::new(&d).write("ui/state-v1", 1, b"s").unwrap();
        assert!(!store_has_records(dir.clone()).unwrap());
        assert!(crate::api::owner::list_nodes(dir.clone()).is_empty());
        assert_eq!(store_sweep(dir.clone()).unwrap(), 0);
        assert!(batman_proto::store::Store::new(&d).read("ui/state-v1").unwrap().is_some());
        batman_proto::store::Store::new(&d).write("node/x", 1, b"s").unwrap();
        assert!(store_has_records(dir).unwrap());
        let _ = std::fs::remove_dir_all(d);
    }

    fn fresh(name: &str) -> (std::path::PathBuf, String) {
        let d = std::env::temp_dir().join(format!("bm-t14-{name}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&d);
        let s = d.to_string_lossy().to_string();
        (d, s)
    }

    /// The Rust error's shape (a Rust sentence: Chinese main part, technical part in U+001E … U+001F) and its kind.
    fn assert_unreadable(r: Result<bool, String>, kind: &str) {
        let e = r.expect_err("an unreadable record folder must be an error, never \"no record\"");
        assert!(e.starts_with("讀不到手機裡的紀錄\u{1E}record store unreadable: "), "{e}");
        assert!(e.ends_with('\u{1F}'), "{e}");
        assert!(e.contains(kind), "{kind} in {e}");
    }

    /// #329 PR 7 T14: the folder of the records does not exist (a first install) -> no record; a record -> true.
    #[test]
    fn t14_absent_is_none_a_record_is_true() {
        let (d, dir) = fresh("absent");
        assert_eq!(store_has_records(dir.clone()), Ok(false), "no records folder at all");
        std::fs::create_dir_all(d.join("node")).unwrap();
        assert_eq!(store_has_records(dir.clone()), Ok(false), "an empty kind folder");
        batman_proto::store::Store::new(&d).write("node/x", 1, b"s").unwrap();
        assert_eq!(store_has_records(dir), Ok(true));
        let _ = std::fs::remove_dir_all(d);
    }

    /// #329 PR 7 T14 (review pr7 E / F: what the old `unwrap_or(false)` read as "no record"): a kind's path that is a
    /// plain file (ENOTDIR; store_sweep skips it, store.rs:213) -> Err, so `_install` generates no key.
    /// Negative control: `unwrap_or(false)` back -> FAIL.
    #[test]
    fn t14_kind_path_not_a_folder_is_an_error() {
        for kind in RECORD_KINDS {
            let (d, dir) = fresh(&format!("enotdir-{kind}"));
            std::fs::create_dir_all(&d).unwrap();
            std::fs::write(d.join(kind), b"not a folder").unwrap();
            assert_unreadable(store_has_records(dir), kind);
            let _ = std::fs::remove_dir_all(d);
        }
    }

    /// #329 PR 7 T14: a kind folder that cannot be read (mode 000) -> Err. Run as a normal user: root reads it anyway,
    /// and then this test FAILs (it found nothing to check) instead of passing.
    #[cfg(unix)]
    #[test]
    fn t14_permission_denied_folder_is_an_error() {
        use std::os::unix::fs::PermissionsExt;
        let (d, dir) = fresh("eacces");
        batman_proto::store::Store::new(&d).write("net/abc", 1, b"s").unwrap();
        let net = d.join("net");
        std::fs::set_permissions(&net, std::fs::Permissions::from_mode(0o000)).unwrap();
        let readable = std::fs::read_dir(&net).is_ok();
        let r = store_has_records(dir);
        std::fs::set_permissions(&net, std::fs::Permissions::from_mode(0o700)).unwrap();
        let _ = std::fs::remove_dir_all(&d);
        assert!(!readable, "the mode-000 folder was still readable (root?): this test checked nothing");
        assert_unreadable(r, "net");
    }

    /// #329 PR 7 T14: a record seen in any kind -> true, even when another kind cannot be read (before or after it in
    /// RECORD_KINDS order): every kind is read before an error counts.
    #[test]
    fn t14_a_record_beside_an_error_is_true() {
        for (bad, good) in [("node", "mpend"), ("forgotten-pending", "node"), ("net", "claim-pending")] {
            let (d, dir) = fresh(&format!("mixed-{bad}"));
            batman_proto::store::Store::new(&d).write(&format!("{good}/x"), 1, b"s").unwrap();
            std::fs::write(d.join(bad), b"not a folder").unwrap();
            assert_eq!(store_has_records(dir.clone()), Ok(true), "{bad} unreadable, {good}/x there");
            std::fs::remove_file(d.join(good).join("x")).unwrap();
            assert_unreadable(store_has_records(dir), bad);
            let _ = std::fs::remove_dir_all(d);
        }
    }
}
