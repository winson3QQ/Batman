//! store: atomic replace, versioned header, AAD binding, path validation, crash leftovers.

use batman_proto::store::{self, Error, Sealed, Store};
use std::fs;
use std::path::PathBuf;

fn tmpdir(name: &str) -> PathBuf {
    let d = std::env::temp_dir().join(format!("bp-store-{name}-{}", std::process::id()));
    let _ = fs::remove_dir_all(&d);
    fs::create_dir_all(&d).unwrap();
    d
}

#[test]
fn write_read_replace_and_generations() {
    let s = Store::new(tmpdir("rw"));
    assert_eq!(s.read("node/abc123").unwrap(), None);
    assert_eq!(s.next_generation("node/abc123").unwrap(), 1);
    s.write("node/abc123", 1, b"sealed-one").unwrap();
    assert_eq!(s.read("node/abc123").unwrap(), Some(Sealed { generation: 1, sealed: b"sealed-one".to_vec() }));
    assert_eq!(s.next_generation("node/abc123").unwrap(), 2);
    s.write("node/abc123", 2, b"sealed-two").unwrap();
    assert_eq!(s.read("node/abc123").unwrap().unwrap().sealed, b"sealed-two");
    // no temp file left after a completed write
    assert_eq!(s.sweep_temps().unwrap(), 0);
    s.remove("node/abc123").unwrap();
    assert_eq!(s.read("node/abc123").unwrap(), None);
    s.remove("node/abc123").unwrap(); // removing a missing record is fine
}

#[test]
fn aad_binds_path_and_generation() {
    assert_ne!(store::aad("node/a", 1), store::aad("node/b", 1));
    assert_ne!(store::aad("node/a", 1), store::aad("node/a", 2));
    assert_ne!(store::aad("node/ab", 1), store::aad("node/a", 0x6201)); // no ambiguity across the separator
    assert!(store::aad("node/a", 1).starts_with(b"batman-record-v1\0node/a\0"));
}

#[test]
fn paths_are_validated() {
    let s = Store::new(tmpdir("path"));
    for bad in ["../x/y", "/etc/passwd", "node", "node/a/b", "node/", "/node", "node/A", "node/.x", "node/a.b", "node/a b", ""] {
        assert!(matches!(s.write(bad, 1, b"x"), Err(Error::BadPath)), "{bad:?}");
        assert!(matches!(s.read(bad), Err(Error::BadPath)), "{bad:?}");
    }
    assert!(store::valid_path("claim-pending/0123abcd"));
    assert!(store::valid_path("net/a5faaf84_1"));
}

#[test]
fn unknown_version_is_neither_read_nor_overwritten() {
    let root = tmpdir("ver");
    let s = Store::new(&root);
    s.write("node/x1", 1, b"v1").unwrap();
    let p = root.join("node/x1");
    let mut b = fs::read(&p).unwrap();
    b[3] = 2; // a future version
    fs::write(&p, &b).unwrap();
    assert!(matches!(s.read("node/x1"), Err(Error::UnknownVersion(2))));
    assert!(matches!(s.write("node/x1", 2, b"new"), Err(Error::UnknownVersion(2))));
    assert_eq!(fs::read(&p).unwrap(), b, "the unknown-version file is untouched");
    fs::write(&p, b"garbage").unwrap();
    assert!(matches!(s.read("node/x1"), Err(Error::NotARecord)));
    assert!(matches!(s.write("node/x1", 2, b"new"), Err(Error::NotARecord)));
}

#[test]
fn a_crash_mid_write_leaves_the_old_record_and_a_swept_temp() {
    let root = tmpdir("crash");
    let s = Store::new(&root);
    s.write("node/c1", 1, b"old").unwrap();
    // what a crash between create and rename leaves: a temp file next to the record
    fs::write(root.join("node/.c1.tmp-deadbeef00000000"), b"BMR\x01partial").unwrap();
    assert_eq!(s.read("node/c1").unwrap().unwrap().sealed, b"old");
    assert_eq!(s.sweep_temps().unwrap(), 1);
    assert_eq!(s.sweep_temps().unwrap(), 0);
    assert_eq!(fs::read_dir(root.join("node")).unwrap().count(), 1);
    // the temp name is not a valid record path either
    assert!(matches!(s.read("node/.c1.tmp-deadbeef00000000"), Err(Error::BadPath)));
}

// design 254-app-claim-noover T2 (R8): copy_aside keeps the original where it is, the copy is the whole file (header
// and generation: it opens again once moved back), names count up and never replace anything — a dangling symlink at
// -1 counts as taken; an unwritable target directory is an error with nothing changed. Run on ext4 (WSL /tmp).
#[cfg(unix)]
#[test]
fn t2_copy_aside_keeps_the_original_and_never_replaces_a_name() {
    use std::os::unix::fs::PermissionsExt;
    let root = tmpdir("aside");
    let s = Store::new(&root);
    let id = "node/e61551410cfd538e24";
    assert_eq!(s.copy_aside(id, "forgotten-node").unwrap(), None, "nothing to copy");
    s.write(id, 3, b"old").unwrap();
    let before = fs::read(root.join(id)).unwrap();
    std::os::unix::fs::symlink(root.join("nowhere"), {
        fs::create_dir_all(root.join("forgotten-node")).unwrap();
        root.join("forgotten-node/e61551410cfd538e24-1")
    })
    .unwrap();
    assert_eq!(s.copy_aside(id, "forgotten-node").unwrap().as_deref(), Some("forgotten-node/e61551410cfd538e24-2"), "a dangling symlink is taken");
    assert!(fs::symlink_metadata(root.join("forgotten-node/e61551410cfd538e24-1")).unwrap().file_type().is_symlink(), "the symlink is untouched");
    assert_eq!(fs::read(root.join(id)).unwrap(), before, "the original is still there, unchanged");
    assert_eq!(fs::read(root.join("forgotten-node/e61551410cfd538e24-2")).unwrap(), before, "the copy is the whole file");
    assert_eq!(s.copy_aside(id, "forgotten-node").unwrap().as_deref(), Some("forgotten-node/e61551410cfd538e24-3"));
    assert_eq!(s.read("forgotten-node/e61551410cfd538e24-2").unwrap().unwrap().sealed, b"old", "-2 not replaced");
    assert_eq!(s.sweep_temps().unwrap(), 0, "no temp left");
    // moved back over the original path, the copy is the same record at the same generation
    fs::rename(root.join("forgotten-node/e61551410cfd538e24-3"), root.join(id)).unwrap();
    assert_eq!(s.read(id).unwrap(), Some(Sealed { generation: 3, sealed: b"old".to_vec() }));
    // an unwritable target directory: an error, the original and the copies unchanged
    fs::set_permissions(root.join("forgotten-node"), fs::Permissions::from_mode(0o000)).unwrap();
    let r = s.copy_aside(id, "forgotten-node");
    fs::set_permissions(root.join("forgotten-node"), fs::Permissions::from_mode(0o755)).unwrap();
    assert!(r.is_err(), "{r:?}");
    assert_eq!(fs::read(root.join(id)).unwrap(), before);
    assert_eq!(fs::read_dir(root.join("forgotten-node")).unwrap().count(), 2, "-1 (symlink) and -2 only");
    fs::write(root.join(id), b"garbage").unwrap();
    assert!(matches!(s.copy_aside(id, "forgotten-node"), Err(Error::NotARecord)));
    assert!(matches!(s.copy_aside("node/../x", "forgotten-node"), Err(Error::BadPath)));
}
