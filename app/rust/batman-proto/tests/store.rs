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

// design §5.1 (re-claim): the old node record moves aside unchanged, to the first free name; it opens again (same AAD)
// only once it is back at its path; nothing at the path -> None; a file that is not a record stays where it is.
#[test]
fn move_aside_keeps_the_bytes_and_picks_a_free_name() {
    let root = tmpdir("aside");
    let s = Store::new(&root);
    assert_eq!(s.move_aside("node/e61551410cfd538e24", "forgotten-node").unwrap(), None);
    s.write("node/e61551410cfd538e24", 3, b"old").unwrap();
    let before = fs::read(root.join("node/e61551410cfd538e24")).unwrap();
    assert_eq!(s.move_aside("node/e61551410cfd538e24", "forgotten-node").unwrap().as_deref(), Some("forgotten-node/e61551410cfd538e24-1"));
    assert_eq!(s.read("node/e61551410cfd538e24").unwrap(), None, "gone from node/");
    assert_eq!(fs::read(root.join("forgotten-node/e61551410cfd538e24-1")).unwrap(), before, "bytes unchanged");
    s.write("node/e61551410cfd538e24", 1, b"newer").unwrap();
    assert_eq!(s.move_aside("node/e61551410cfd538e24", "forgotten-node").unwrap().as_deref(), Some("forgotten-node/e61551410cfd538e24-2"));
    assert_eq!(s.read("forgotten-node/e61551410cfd538e24-1").unwrap().unwrap().sealed, b"old", "the first one is not overwritten");
    // moved back, it is the same record at the same generation: aad(node/<id>, 3) opens it again
    fs::rename(root.join("forgotten-node/e61551410cfd538e24-1"), root.join("node/e61551410cfd538e24")).unwrap();
    assert_eq!(s.read("node/e61551410cfd538e24").unwrap(), Some(Sealed { generation: 3, sealed: b"old".to_vec() }));
    fs::write(root.join("node/e61551410cfd538e24"), b"garbage").unwrap();
    assert!(matches!(s.move_aside("node/e61551410cfd538e24", "forgotten-node"), Err(Error::NotARecord)));
    assert!(root.join("node/e61551410cfd538e24").exists());
    assert!(matches!(s.move_aside("node/../x", "forgotten-node"), Err(Error::BadPath)));
}
