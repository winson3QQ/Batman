//! Whole-team status, app side (docs/design/254-app-team-status.md v2.1 FROZEN §10.2): T-A1, T-A2, T-A5, T-A6(a)(b),
//! T-A7, T-A9 (address tails only on screen), T-A10. T-A3 / T-A4 are in tests/statuspage.rs; T-A6(c) in
//! tests/joinflow.rs, tests/join2flow.rs and tests/member.rs. Negative controls: mutants of src/teamview.rs (scratch
//! runner; the FAIL lines are in the commit report). The N+1 view is shown with `team_view_with(true, ..)`; version N's
//! own view stays hidden (T-A10).

use batman_proto::cbor::Value as V;
use batman_proto::cose;
use batman_proto::netrec;
use batman_proto::teamview::{self as tv, Peers};

const A: [u8; 6] = [0xa8, 0xdd, 0x9f, 0x4d, 0xc6, 0xd3];
const B: [u8; 6] = [0xa8, 0xdd, 0x9f, 0x4d, 0xc7, 0x60];
const C: [u8; 6] = [0xa8, 0xdd, 0x9f, 0x4d, 0xc8, 0x01];
const OWN: [u8; 6] = [0xa8, 0xdd, 0x9f, 0x4d, 0xc6, 0x10];

fn peer(a: [u8; 6], ago: u64, kbps: Option<u64>, signal: Option<i64>) -> V {
    let mut e = vec![(V::Uint(1), V::Bytes(a.to_vec())), (V::Uint(2), V::Uint(ago))];
    if let Some(k) = kbps {
        e.push((V::Uint(3), V::Uint(k)));
    }
    if let Some(s) = signal {
        e.push((V::Uint(4), if s < 0 { V::Nint((-1 - s) as u64) } else { V::Uint(s as u64) }));
    }
    V::Map(e)
}

/// a joined node's status answer with keys 8 / 9 (and a hostname-like key 15 `node` that must never become a name)
fn status(peers: Option<Vec<V>>) -> V {
    let mut m = vec![
        (V::Uint(1), V::Uint(2)),
        (V::Uint(2), V::Uint(0)),
        (V::Uint(8), V::Bytes(OWN.to_vec())),
        (V::Uint(15), V::Map(vec![(V::Text("node".into()), V::Text("BCM2711-c6d3_wlh0".into()))])),
    ];
    if let Some(p) = peers {
        m.push((V::Uint(9), V::Array(p)));
    }
    V::Map(m)
}

fn entry(dac: u8, name: &str, addr: Option<[u8; 6]>) -> V {
    let mut e = vec![
        (V::Uint(1), V::Bytes(vec![dac; 32])),
        (V::Uint(2), V::Bytes(vec![4; 65])),
        (V::Uint(3), V::Text(name.into())),
        (V::Uint(4), V::Bytes(vec![4; 65])),
        (V::Uint(5), V::Bytes(vec![4; 65])),
    ];
    if let Some(a) = addr {
        e.push((V::Uint(7), V::Bytes(a.to_vec())));
    }
    V::Map(e)
}

fn members(entries: Vec<V>) -> V {
    V::Map(vec![
        (V::Uint(1), V::Bytes(vec![0xab; 16])),
        (V::Uint(2), V::Uint(3)),
        (V::Uint(3), V::Bytes(vec![1; 32])),
        (V::Uint(4), V::Array(entries)),
        (V::Uint(5), V::Array(vec![])),
        (V::Uint(6), V::Array(vec![])),
        (V::Uint(7), V::Array(vec![])),
    ])
}

fn view(st: &V, m: &V) -> tv::TeamView {
    tv::team_view_with(true, Some(st), Some(m), Some(&[1; 32]))
}

// T-A1: names come from the signed list only; an unmatched address is 「不明節點」 with no name (never key 15 `node`)
#[test]
fn t_a1_names_only_from_the_signed_list() {
    let st = status(Some(vec![peer(A, 3, Some(14900), Some(-62)), peer(C, 10, Some(3200), None)]));
    let m = members(vec![entry(1, "我的節點", Some(OWN)), entry(2, "客廳", Some(A))]);
    let v = view(&st, &m);
    assert!(v.visible);
    assert_eq!(v.title, "全隊（僅供參考；由『我的節點』看到）");
    assert_eq!(v.cards, vec![
        "🟢 『客廳』 在線 · 連線 好（約 14.9 Mbit/s） · 直接連線".to_string(),
        format!("❔ 不明節點 · 在線 · 連線 普通（約 3.2 Mbit/s） · 經隊員轉送\n{}", tv::NEW_MEMBER_HINT),
    ]);
    let all = format!("{:?}", v);
    assert!(!all.contains("BCM2711"), "a hostname reached the screen: {all}");
}

// T-A2: duplicates — the signing side drops the address from BOTH entries; the reading side counts it for neither;
// unusable addresses are not written
#[test]
fn t_a2_duplicate_and_bad_addresses() {
    let mut a = vec![Some(A), Some(B), Some(A), Some([0; 6]), Some([0x01, 2, 3, 4, 5, 6])];
    let lost = tv::dedup_for_signing(&mut a);
    assert_eq!(a, vec![None, Some(B), None, None, None]);
    assert_eq!(lost, vec![0, 2, 3, 4]);
    assert_eq!(tv::addr_ok(&[0xa8, 0xdd, 0x9f, 0x4d, 0xc6]), None, "5 bytes");
    assert_eq!(tv::addr_ok(&A), Some(A));
    let st = status(Some(vec![peer(A, 3, Some(14900), Some(-62))]));
    let m = members(vec![entry(2, "客廳", Some(A)), entry(3, "書房", Some(A)), entry(4, "車上", Some(B))]);
    let v = view(&st, &m);
    assert_eq!(v.cards, vec![
        "⚪ 『車上』 這台節點開機後還沒看到".to_string(),
        "⚪ 『客廳』 沒有登記網路位址，看不到狀態".to_string(),
        "⚪ 『書房』 沒有登記網路位址，看不到狀態".to_string(),
        format!("❔ 不明節點 · 在線 · 連線 好（約 14.9 Mbit/s） · 直接連線\n{}", tv::NEW_MEMBER_HINT),
    ]);
}

// T-A5: no key 7 -> not registered; the next list with key 7 -> the name; removed from the list -> 不明節點 + hint
#[test]
fn t_a5_list_updates() {
    let st = status(Some(vec![peer(A, 400, Some(900), None)]));
    let v1 = view(&st, &members(vec![entry(2, "客廳", None)]));
    assert_eq!(v1.cards[0], "⚪ 『客廳』 沒有登記網路位址，看不到狀態");
    let v2 = view(&st, &members(vec![entry(2, "客廳", Some(A))]));
    assert_eq!(v2.cards, vec!["⚪ 『客廳』 離線 · 最後看到 6 分鐘前".to_string()]);
    let v3 = view(&st, &members(vec![]));
    assert_eq!(v3.cards, vec![format!("❔ 不明節點 · 最後看到 6 分鐘前\n{}", tv::NEW_MEMBER_HINT)]);
    assert_eq!(v3.tech, vec!["不明節點 …c6d3：400 秒前".to_string()]);
}

// T-A3 (team side): key 9 absent / malformed -> the one sentence; not joined -> its sentence; failed read -> hidden
#[test]
fn t_a3_absent_or_bad_key9() {
    let m = members(vec![entry(2, "客廳", Some(A))]);
    let too_many: Vec<V> = (0..33u8).map(|i| peer([2, 0, 0, 0, 0, i], 1, None, None)).collect();
    let bad = [
        status(None),
        status(Some(too_many)),
        status(Some(vec![V::Map(vec![(V::Uint(1), V::Bytes(vec![1; 5])), (V::Uint(2), V::Uint(1))])])),
        status(Some(vec![V::Map(vec![(V::Uint(1), V::Bytes(A.to_vec())), (V::Uint(2), V::Text("1".into()))])])),
        status(Some(vec![V::Uint(1)])),
    ];
    for (i, st) in bad.iter().enumerate() {
        let v = view(st, &m);
        assert!(v.visible && v.cards.is_empty() && v.only == tv::ONLY_NONE, "case {i}: {v:?}");
    }
    assert_eq!(tv::peers_of(&bad[0]), Peers::Absent);
    assert_eq!(tv::peers_of(&bad[1]), Peers::Bad);
    // only key 3 / key 4 malformed: that field is dropped, the entry stays
    let st = status(Some(vec![V::Map(vec![(V::Uint(1), V::Bytes(A.to_vec())), (V::Uint(2), V::Uint(1)), (V::Uint(3), V::Text("x".into())), (V::Uint(4), V::Text("y".into()))])]));
    assert!(matches!(tv::peers_of(&st), Peers::List(l) if l.len() == 1 && l[0].kbps.is_none() && l[0].signal.is_none()));
    let mut nj = status(Some(vec![]));
    if let V::Map(e) = &mut nj {
        e.push((V::Uint(5), V::Map(vec![(V::Uint(1), V::Uint(7))])));
    }
    assert_eq!(view(&nj, &m).only, tv::ONLY_NOT_JOINED);
    assert!(!tv::team_view_with(true, None, Some(&m), None).visible, "a failed status read shows no team section");
}

// T-A6 (a)(b): version N accepts key 7 in a members entry (6 bytes only); the N-1 rule refuses it
#[test]
fn t_a6_member_entry_key7() {
    let with = entry(2, "客廳", Some(A));
    assert!(netrec::member_entry_ok(&with));
    assert!(netrec::member_entry_ok(&entry(2, "客廳", None)));
    let mut five = entry(2, "客廳", None);
    if let V::Map(e) = &mut five {
        e.push((V::Uint(7), V::Bytes(vec![1; 5])));
    }
    assert!(!netrec::member_entry_ok(&five), "a 5-byte key 7 must refuse the list");
    let mut eight = entry(2, "客廳", Some(A));
    if let V::Map(e) = &mut eight {
        e.push((V::Uint(8), V::Uint(1)));
    }
    assert!(!netrec::member_entry_ok(&eight), "other unknown keys stay refused");
    // N-1 (approve.rs:311 / mupdate.rs:133 before this change): exact_keys(m, [1..5], [6]) -> the whole list refused
    assert!(cose::exact_keys(&with, &[1, 2, 3, 4, 5], &[6]).is_err());
    // a record keeps key 7 through decode / encode (netrec member encoding)
    let m = netrec::member_of(&{
        let mut x = with.clone();
        if let V::Map(e) = &mut x {
            e.push((V::Uint(8), V::Text("applied".into())));
        }
        x
    })
    .unwrap();
    assert_eq!(m.mesh_addr, Some(A));
    assert_eq!(netrec::member_value(&m).get(7).and_then(V::as_bytes), Some(&A[..]));
}

// T-A7: the wording boundaries
#[test]
fn t_a7_boundaries() {
    assert_eq!(tv::seen_text(59), "剛剛");
    assert_eq!(tv::seen_text(60), "1 分鐘前");
    assert_eq!(tv::seen_text(61), "1 分鐘前");
    assert_eq!(tv::seen_text(3599), "59 分鐘前");
    assert_eq!(tv::seen_text(3600), "1 小時前");
    assert_eq!([tv::quality(999), tv::quality(1000), tv::quality(3999), tv::quality(4000)], ["差", "普通", "普通", "好"]);
    let m = members(vec![entry(2, "客廳", Some(A))]);
    let at = |ago| view(&status(Some(vec![peer(A, ago, None, None)])), &m).cards[0].clone();
    assert_eq!(at(60), "🟢 『客廳』 在線 · 經隊員轉送");
    assert_eq!(at(61), "⚪ 『客廳』 離線 · 最後看到 1 分鐘前");
}

// T-A9 (screen part): no full address on the screen or in the technical lines — the tail only
#[test]
fn t_a9_no_full_address_shown() {
    let st = status(Some(vec![peer(A, 3, Some(14900), Some(-62)), peer(C, 9000, None, None)]));
    let v = view(&st, &members(vec![entry(2, "客廳", Some(A))]));
    let all = format!("{:?}", v).to_lowercase();
    for a in [A, C, OWN] {
        let colon = a.iter().map(|b| format!("{b:02x}")).collect::<Vec<_>>().join(":");
        let flat = a.iter().map(|b| format!("{b:02x}")).collect::<String>();
        assert!(!all.contains(&colon) && !all.contains(&flat), "{colon} on screen: {all}");
    }
    assert!(all.contains("…c801"), "the tail is the only trace: {all}");
}

// T-A10: version N ships with writing and the team section off (§4.3). N+1 deletes this test in its diff.
#[cfg(not(feature = "team-write"))]
#[test]
fn t_a10_version_n_keeps_the_gate_closed() {
    assert!(!tv::WRITE_MESH_ADDR, "WRITE_MESH_ADDR must be false in version N (254-app-team-status §4.3)");
    assert_eq!(tv::gate(Some(A)), None);
    let st = status(Some(vec![peer(A, 3, None, None)]));
    assert!(!tv::team_view(Some(&st), Some(&members(vec![])), None).visible, "N shows no team section");
}

// T-A8 (the decision): E_RATE -> read again once (design §4.2); E_BUSY / any error / reads used up ->
// go on WITHOUT an address (never abort); an answer -> its key 8 (or none)
#[test]
fn t_a8_addr_read_decision() {
    let st = status(None);
    assert_eq!(tv::addr_read(Ok(&st), 1), tv::AddrRead::Done(Some(OWN)));
    assert_eq!(tv::addr_read(Ok(&V::Map(vec![(V::Uint(1), V::Uint(2))])), 1), tv::AddrRead::Done(None));
    assert_eq!(tv::addr_read(Err(12), 1), tv::AddrRead::Retry);
    assert_eq!(tv::addr_read(Err(12), 2), tv::AddrRead::Done(None), "bounded: one retry (2 reads) at most");
    assert_eq!(tv::addr_read(Err(7), 1), tv::AddrRead::Done(None), "E_BUSY (7): go on without key 7");
    assert!(tv::ADDR_RETRY_MS >= 1000 && tv::ADDR_READ_TRIES == 2);
}
