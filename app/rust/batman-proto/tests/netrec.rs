//! netrec / flow::link_state / Store::write_cas (docs/design/254-app-join2.md v7.2, tests T6, T9, T10, T11; T11 is the
//! status page design's T7, docs/design/254-app-status-page.md v8.1).

use batman_proto::cbor::{self, Value as V};
use batman_proto::flow::{self, JoinState, LinkState};
use batman_proto::netrec::{self, Confirm, Member, MemberState};
use batman_proto::{cose, store};

const NET_ID: [u8; 16] = [0x5a; 16];

fn m(pairs: Vec<(u64, V)>) -> V {
    V::Map(pairs.into_iter().map(|(k, v)| (V::Uint(k), v)).collect())
}
fn t(pairs: Vec<(&str, V)>) -> V {
    V::Map(pairs.into_iter().map(|(k, v)| (V::Text(k.into()), v)).collect())
}
fn p(b: u8) -> [u8; 65] {
    let mut x = [b; 65];
    x[0] = 4;
    x
}

/// A record exactly as 36e2f57's make-network wrote it (bridge owner.rs net_record_plain: keys 1-10, no key 11), with
/// a members v1 Sign1 (signature bytes are not checked when reading the phone's own record).
fn old_record_plain(state: &str) -> Vec<u8> {
    let netcfg = cose::sign1(cose::CT_NETCFG, &cose::net_config_payload(&NET_ID, 1, None, "home", "US", "bm-5a5a5a5a5a5a", 40, 4, &[p(6)]), &[1; 64]);
    let first = [0xa1; 32];
    let members = cose::sign1(
        cose::CT_MEMBERS,
        &cose::member_list_payload(&NET_ID, 1, None, &[cose::Member { dac_pub_hash: &first, ecdh_pub: &p(2), name: "node-0001", owner_pub: &p(4), owner_enc_pub: &p(5), mesh_addr: None }]),
        &[1; 64],
    );
    cbor::encode(&m(vec![
        (1, V::Bytes(NET_ID.to_vec())),
        (2, V::Text("bm-5a5a5a5a5a5a".into())),
        (3, V::Uint(40)),
        (4, V::Uint(4)),
        (5, V::Text("S".repeat(24))),
        (6, V::Bytes(vec![7; 32])),
        (7, V::Bytes(netcfg)),
        (8, V::Bytes(members)),
        (9, V::Bytes(vec![0xd2])),
        (10, V::Text(state.into())),
    ]))
}

// ---- T9 -----------------------------------------------------------------------------------------------------------

#[test]
fn t9_old_records_derive_the_first_node() {
    for (state, want) in [("pending", MemberState::Joining), ("applied", MemberState::Applied)] {
        let r = netrec::decode(&old_record_plain(state)).unwrap();
        assert!(r.list.is_none());
        let l = r.members().unwrap();
        assert_eq!(l.len(), 1, "{state}");
        assert_eq!(l[0].dac_pub_hash, [0xa1; 32]);
        assert_eq!((l[0].ecdh_pub, l[0].owner_pub, l[0].owner_enc_pub), (p(2), p(4), p(5)));
        assert_eq!(l[0].name, "node-0001");
        assert_eq!((l[0].device_id.clone(), l[0].prev_country.clone()), (None, None));
        assert_eq!(l[0].state, want, "{state}");
    }
}

#[test]
fn record_round_trip_with_a_member_list() {
    let mut r = netrec::decode(&old_record_plain("applied")).unwrap();
    let mut l = r.members().unwrap();
    l.push(Member {
        dac_pub_hash: [0xb2; 32],
        ecdh_pub: p(8),
        name: "node-2233".into(),
        owner_pub: p(4),
        owner_enc_pub: p(5),
        device_id: Some("aabb".into()),
        state: MemberState::Joining,
        prev_country: Some("JP".into()),
        known: None,
        mesh_addr: None,
    });
    r.list = Some(l);
    let back = netrec::decode(&netrec::encode(&r)).unwrap();
    assert!(back == r);
    assert_eq!(back.netcfg().unwrap().country, "US");
    assert_eq!(back.netcfg().unwrap().admins, vec![p(6)]);
    // keys 1-10 of the old layout are untouched by a re-encode without a list
    let old = netrec::decode(&old_record_plain("pending")).unwrap();
    assert_eq!(netrec::encode(&old), old_record_plain("pending"));
}

// ---- T6 -----------------------------------------------------------------------------------------------------------

fn info(id: &[u8], version: u64, txn: bool) -> V {
    m(vec![(9, V::Uint(version)), (10, V::Bytes(id.to_vec())), (11, V::Bool(txn))])
}

#[test]
fn t6_confirm_upgrades_pending() {
    let mut r = netrec::decode(&old_record_plain("pending")).unwrap();
    assert_eq!(netrec::confirm(&mut r, &info(&NET_ID, 1, false)).unwrap(), Confirm::Upgraded { save_pending: false });
    assert_eq!(r.state, "applied");
    assert_eq!(r.list.as_ref().unwrap()[0].state, MemberState::Applied, "the creator's entry too");
    // and stays so: a second confirm has nothing to write
    assert_eq!(netrec::confirm(&mut r, &info(&NET_ID, 1, false)).unwrap(), Confirm::Already { save_pending: false });
}

#[test]
fn t6_confirm_other_version_changes_nothing() {
    let mut r = netrec::decode(&old_record_plain("pending")).unwrap();
    let before = r.clone();
    assert_eq!(netrec::confirm(&mut r, &info(&NET_ID, 2, false)).unwrap(), Confirm::OtherVersion);
    assert!(r == before);
}

#[test]
fn t6_confirm_with_txn_still_present_upgrades_with_a_note() {
    let mut r = netrec::decode(&old_record_plain("pending")).unwrap();
    assert_eq!(netrec::confirm(&mut r, &info(&NET_ID, 1, true)).unwrap(), Confirm::Upgraded { save_pending: true });
    assert_eq!(r.state, "applied");
}

#[test]
fn t6_confirm_never_adds_or_upgrades_other_members() {
    let mut r = netrec::decode(&old_record_plain("pending")).unwrap();
    let mut l = r.members().unwrap();
    l.push(Member { dac_pub_hash: [0xb2; 32], ecdh_pub: p(8), name: "x".into(), owner_pub: p(4), owner_enc_pub: p(5), device_id: None, state: MemberState::Joining, prev_country: None, known: None, mesh_addr: None });
    r.list = Some(l);
    for (i, want) in [
        (m(vec![(11, V::Bool(false))]), JoinState::NotApplied),
        (m(vec![(11, V::Bool(true))]), JoinState::InProgress),
        (info(&[0x99; 16], 1, false), JoinState::OtherNetwork),
        (m(vec![]), JoinState::Unknown),
    ] {
        let before = r.clone();
        assert_eq!(netrec::confirm(&mut r, &i).unwrap(), Confirm::NoChange(want));
        assert!(r == before);
    }
    netrec::confirm(&mut r, &info(&NET_ID, 1, false)).unwrap();
    let l = r.list.unwrap();
    assert_eq!(l.len(), 2, "no entry added");
    assert_eq!(l[1].state, MemberState::Joining, "only the creator is upgraded");
}

// ---- T10 ----------------------------------------------------------------------------------------------------------

fn tmp(name: &str) -> std::path::PathBuf {
    let d = std::env::temp_dir().join(format!("bp-netrec-{name}-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&d);
    d
}

#[test]
fn t10_write_cas_needs_the_generation_it_was_read_at() {
    let s = store::Store::new(tmp("cas"));
    let rel = "net/5a5a";
    // a new record: expected 0
    assert_eq!(s.write_cas(rel, 0, b"one").unwrap(), 1);
    assert!(matches!(s.write_cas(rel, 0, b"again"), Err(store::Error::Stale { expected: 0, found: 1 })));
    // read at 1, written elsewhere (2), then our write from 1 -> stale, the other write stays
    let read_at = s.read(rel).unwrap().unwrap().generation;
    assert_eq!(s.write_cas(rel, read_at, b"elsewhere").unwrap(), 2);
    assert!(matches!(s.write_cas(rel, read_at, b"ours"), Err(store::Error::Stale { expected: 1, found: 2 })));
    assert_eq!(s.read(rel).unwrap().unwrap(), store::Sealed { generation: 2, sealed: b"elsewhere".to_vec() });
    // from the right generation: written at expected + 1, the generation the AAD was made for
    assert_eq!(s.write_cas(rel, 2, b"three").unwrap(), 3);
    assert_eq!(s.read(rel).unwrap().unwrap().generation, 3);
}

#[test]
fn t10_forget_joining_removes_the_entry() {
    let mut r = netrec::decode(&old_record_plain("applied")).unwrap();
    let mut l = r.members().unwrap();
    l.push(Member { dac_pub_hash: [0xb2; 32], ecdh_pub: p(8), name: "x".into(), owner_pub: p(4), owner_enc_pub: p(5), device_id: None, state: MemberState::Joining, prev_country: Some("JP".into()), known: None, mesh_addr: None });
    r.list = Some(l);
    let s = store::Store::new(tmp("forget"));
    let rel = "net/5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a";
    s.write_cas(rel, 0, &netrec::encode(&r)).unwrap();
    let read = s.read(rel).unwrap().unwrap();
    let mut back = netrec::decode(&read.sealed).unwrap();
    assert_eq!(netrec::forget_joining(&mut back, &[0xb2; 32]).unwrap().prev_country, Some("JP".into()));
    assert_eq!(s.write_cas(rel, read.generation, &netrec::encode(&back)).unwrap(), read.generation + 1);
    let after = netrec::decode(&s.read(rel).unwrap().unwrap().sealed).unwrap();
    assert_eq!(after.members().unwrap().len(), 1);
    // an applied member (the creator) is never "forgotten"
    assert!(netrec::forget_joining(&mut back, &[0xa1; 32]).is_err());
}

// ---- T11 ----------------------------------------------------------------------------------------------------------

/// key 3 = n3, key 15 age_s / join.plinks, key 5 {1: code} when `code` is Some (not JOINED)
fn status_c(n3: Option<u64>, age: Option<u64>, plinks: Option<u64>, stale: bool, code: Option<u64>) -> V {
    let V::Map(mut e) = status(n3, age, plinks, stale) else { unreachable!() };
    if let Some(c) = code {
        e.insert(1, (V::Uint(5), m(vec![(1, V::Uint(c)), (2, V::Text("NOT_JOINED".into()))])));
    }
    V::Map(e)
}

fn status(n3: Option<u64>, age: Option<u64>, plinks: Option<u64>, stale: bool) -> V {
    let mut f = vec![];
    if stale {
        f.push(("stale", V::Bool(true)));
    }
    if let Some(a) = age {
        f.push(("age_s", V::Uint(a)));
    }
    let mut j = vec![("state", V::Text("JOINED".into()))];
    if let Some(p) = plinks {
        j.push(("plinks", V::Uint(p)));
    }
    f.push(("join", t(j)));
    let mut s = vec![(1, V::Uint(2))];
    if let Some(n) = n3 {
        s.push((3, V::Uint(n)));
    }
    s.push((15, t(f)));
    m(s)
}

#[test]
fn t11_connected_is_the_nodes_own_joined_with_plinks_in_a_fresh_sample() {
    // JOINED (key 5 absent) + plinks >= 1 in a sample younger than the join -> connected {plinks}; key 3 is not read
    assert_eq!(flow::link_state(&status(Some(1), Some(5), Some(1), false), 30), LinkState::Connected { plinks: 1 });
    assert_eq!(flow::link_state(&status(None, Some(5), Some(2), false), 30), LinkState::Connected { plinks: 2 }, "key 3 missing counts");
    assert_eq!(flow::link_state(&status(Some(0), Some(5), Some(1), false), 30), LinkState::Connected { plinks: 1 }, "key 3 = 0 counts");
    // each missing / false part
    assert_eq!(flow::link_state(&status(Some(1), Some(5), Some(1), true), 30), LinkState::Unknown, "stale");
    assert_eq!(flow::link_state(&m(vec![(1, V::Uint(2)), (3, V::Uint(1)), (15, t(vec![("stale", V::Bool(true))]))]), 30), LinkState::Unknown);
    assert_eq!(flow::link_state(&status(Some(1), Some(31), Some(1), false), 30), LinkState::NotYet, "sampled before the join");
    assert_eq!(flow::link_state(&status(Some(1), Some(30), Some(1), false), 30), LinkState::NotYet, "sampled at the join");
    assert_eq!(flow::link_state(&status(Some(1), Some(5), None, false), 30), LinkState::Unknown, "plinks missing (row 2)");
    assert_eq!(flow::link_state(&status(Some(1), Some(5), Some(0), false), 30), LinkState::NotYet, "plinks 0 (JOINED lags)");
    assert_eq!(flow::link_state(&status(Some(1), None, Some(1), false), 30), LinkState::Unknown, "age_s missing");
    assert_eq!(flow::link_state(&m(vec![(1, V::Uint(2)), (3, V::Uint(1))]), 30), LinkState::Unknown, "no key 15 (P2 / member)");
    // key 5 present: never connected, whatever key 3 / plinks say (code 9 = plink but no batman neighbour on wlh0)
    assert_eq!(flow::link_state(&status_c(Some(3), Some(5), Some(1), false, Some(9)), 30), LinkState::NotYet, "code 9 + k3 + plinks");
    assert_eq!(flow::link_state(&status_c(Some(1), Some(5), Some(1), false, Some(0)), 30), LinkState::NotYet, "code 0 + plinks (8a)");
    assert_eq!(flow::link_state(&status_c(Some(1), Some(5), Some(0), false, Some(7)), 30), LinkState::NotYet);
}

#[test]
fn records_carry_no_secret_outside_keys_5_6_9() {
    // the member list never holds net_secrets (design §3.1): only keys 1-6, 8, 9 per entry
    let mut r = netrec::decode(&old_record_plain("applied")).unwrap();
    r.list = Some(r.members().unwrap());
    let v = cbor::decode(&netrec::encode(&r)).unwrap();
    let V::Array(l) = v.get(11).unwrap() else { panic!() };
    let V::Map(e) = &l[0] else { panic!() };
    let keys: Vec<V> = e.iter().map(|(k, _)| k.clone()).collect();
    assert_eq!(keys, [1, 2, 3, 4, 5, 8].map(V::Uint));
}

#[test]
fn t10_forget_never_the_creator() {
    // a pending record derives its creator as joining: forgetting it would leave an applied record without it
    let mut r = netrec::decode(&old_record_plain("pending")).unwrap();
    assert_eq!(r.members().unwrap()[0].state, MemberState::Joining);
    assert!(netrec::forget_joining(&mut r, &[0xa1; 32]).is_err());
    assert!(r.list.is_none(), "nothing changed");
}
