//! Software update, the app side (docs/design/254-app-update.md v0.4 FROZEN §8): T1 (manifest), T2 (the checks on
//! the phone), T3 (texts), T4 / T4b (the path; reason 16), T5 (§3.4), T6 (§3.3), T7 (after apply) over `swupd`.
//! Every node answer is a response the node's own Go code produced (tests/testdata/swupd, see SOURCE): node-helper.json
//! (the helper's replies) and provd-wire.json (those replies as the app receives them through a real provd session).
//! Where a row needs a reply the rigs do not produce (another owner's sha), the captured reply is changed in key 4 only
//! (`others`). The negative controls named by the design are mutants of src/swupd.rs (scratch runner, results in the
//! commit report).

use batman_proto::cbor::{self, Value as V};
use batman_proto::swupd::{self as su, Action, Button, Ctx, Flow, Picked, Put, Reply, Verb};
use serde_json::Value as J;
use std::collections::HashMap;

fn data(name: &str) -> J {
    let p = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("tests/testdata/swupd").join(name);
    serde_json::from_str(&std::fs::read_to_string(p).unwrap()).unwrap()
}

/// the node answers as the app receives them, by name
fn wire() -> HashMap<String, Reply> {
    let d = data("provd-wire.json");
    let mut m = HashMap::new();
    for c in d["cases"].as_array().unwrap() {
        let body = cbor::decode(&hex::decode(c["body"].as_str().unwrap()).unwrap()).unwrap();
        let st = c["status"].as_u64().unwrap();
        let r = if st == 0 { Reply::Ok(body) } else { Reply::Err { code: st, detail: body } };
        m.insert(c["name"].as_str().unwrap().to_string(), r);
    }
    assert!(m.len() >= 35, "the captured set is complete ({} cases)", m.len());
    m
}

fn w(name: &str) -> Reply {
    wire().remove(name).unwrap_or_else(|| panic!("no captured answer {name}"))
}

/// the captured manifest (signed by the node test signer for the captured payload) and the payload file as picked
fn files() -> (Vec<Picked>, Vec<u8>, u64) {
    let d = data("node-helper.json");
    let mf = hex::decode(d["manifest"].as_str().unwrap()).unwrap();
    let size = d["size"].as_u64().unwrap();
    let m = Picked { size: mf.len() as i64, head: mf[..2].to_vec(), data: mf.clone() };
    let p = Picked { size: size as i64, head: vec![0x1f, 0x8b], data: vec![] };
    (vec![m, p], mf, size)
}

fn sha() -> Vec<u8> {
    hex::decode(data("node-helper.json")["sha"].as_str().unwrap()).unwrap()
}

/// the same captured answer with another sha in key 4 (a row the rigs only produce for this phone)
fn others(r: Reply) -> Reply {
    let Reply::Ok(V::Map(mut e)) = r else { panic!("not an ok map") };
    for (k, v) in e.iter_mut() {
        if *k == V::Uint(4) {
            *v = V::Bytes(vec![0x77; 32]);
        }
    }
    Reply::Ok(V::Map(e))
}

fn m(kv: Vec<(u64, V)>) -> V {
    V::Map(kv.into_iter().map(|(k, v)| (V::Uint(k), v)).collect())
}

/// an owner status answer with key 15 (node status.go: text keys)
fn status15(trust: Option<&str>, extra: Vec<(&str, V)>) -> Reply {
    let mut k15: Vec<(V, V)> = extra.into_iter().map(|(k, v)| (V::Text(k.into()), v)).collect();
    if let Some(t) = trust {
        k15.push((V::Text("trust".into()), V::Text(t.into())));
    }
    Reply::Ok(m(vec![(1, V::Uint(2)), (15, V::Map(k15))]))
}

const TRUST: &str = "0123456789abcdef";
const PASS: &str = "ap-pass-1";

/// One flow and what it did: every verb sent, every text the screen got, every wait asked for
struct Run {
    f: Flow,
    now: u64,
    verbs: Vec<&'static str>,
    texts: Vec<String>,
    waits: Vec<u64>,
    sends: Vec<(Verb, u64)>,
}

impl Run {
    fn new(dev: bool) -> Run {
        Run { f: Flow::new(dev), now: 1_000, verbs: vec![], texts: vec![], waits: vec![], sends: vec![] }
    }
    fn see(&mut self, a: Action) -> Action {
        match &a {
            Action::Send { verb, wait_ms, note, .. } => {
                self.verbs.push(verb.wire());
                self.sends.push((*verb, *wait_ms));
                self.texts.push(note.clone());
            }
            Action::Wait { ms, note, .. } => {
                self.waits.push(*ms);
                self.texts.push(note.clone());
            }
            Action::Show(s) | Action::Done(s) => {
                self.texts.push(s.text.clone());
                self.texts.push(s.tech.clone());
            }
            Action::Upload { .. } => self.verbs.push("PUT"),
        }
        a
    }
    fn start(&mut self) -> Action {
        let a = self.f.start();
        self.see(a)
    }
    fn reply(&mut self, r: Reply) -> Action {
        let a = self.f.on_reply(r, self.now).expect("an action after the answer");
        self.see(a)
    }
    fn resume(&mut self) -> Action {
        let a = self.f.resume().expect("was waiting");
        self.see(a)
    }
    /// after a Wait: the time passes, then the flow goes on
    fn after(&mut self, a: &Action) -> Action {
        let Action::Wait { ms, .. } = a else { panic!("not a wait: {a:?}") };
        self.now += ms;
        self.resume()
    }
    fn press(&mut self, b: Button) -> Action {
        let a = self.f.press(b, self.now).expect("the button does something");
        self.see(a)
    }
    fn pick(&mut self, files: &[Picked]) -> Action {
        let a = self.f.picked(files).expect("a screen was up");
        self.see(a)
    }
    fn put(&mut self, r: Put) -> Action {
        let a = self.f.uploaded(r).expect("an upload was running");
        self.see(a)
    }
    /// entry: status (key 15) -> info -> update/status
    fn enter(&mut self, upd: Reply) -> Action {
        assert!(matches!(self.start(), Action::Send { verb: Verb::Status, .. }));
        assert!(matches!(self.reply(status15(Some(TRUST), vec![])), Action::Send { verb: Verb::Info, .. }));
        assert!(matches!(self.reply(Reply::Ok(m(vec![(4, V::Text("1.5.14-wsl.25+fbc01ae".into()))]))), Action::Send { verb: Verb::UpdStatus, .. }));
        self.reply(upd)
    }
    /// entry idle -> the two files -> check ok -> U3
    fn to_confirm(&mut self) -> Action {
        assert!(buttons(&self.enter(w("status-idle"))).contains(&Button::Pick));
        let (fs, _, _) = files();
        assert!(matches!(self.pick(&fs), Action::Send { verb: Verb::Check, .. }));
        self.reply(w("check-ok"))
    }
    /// ... -> Start -> bulk/open ok -> the Upload
    fn to_upload(&mut self) -> Action {
        assert_eq!(buttons(&self.to_confirm()), vec![Button::Start, Button::Cancel]);
        assert!(matches!(self.press(Button::Start), Action::Send { verb: Verb::BulkOpen, .. }));
        self.reply(w("bulk-open-ok"))
    }
    /// read the entry again (Refresh) with an idle node
    fn refresh_to(&mut self, upd: Reply) -> Action {
        self.press(Button::Refresh);
        self.reply(status15(Some(TRUST), vec![]));
        self.reply(Reply::Ok(m(vec![])));
        self.reply(upd)
    }
}

fn buttons(a: &Action) -> Vec<Button> {
    match a {
        Action::Show(s) | Action::Done(s) => s.buttons.clone(),
        _ => panic!("not a screen: {a:?}"),
    }
}

fn text(a: &Action) -> String {
    match a {
        Action::Show(s) | Action::Done(s) => s.text.clone(),
        _ => panic!("not a screen: {a:?}"),
    }
}

fn verb(a: &Action) -> Verb {
    match a {
        Action::Send { verb, .. } => *verb,
        _ => panic!("not a send: {a:?}"),
    }
}

// ---- T1: the manifest -------------------------------------------------------------------------------------------

/// a manifest map, encoded entry by entry (so an entry can be broken on purpose)
fn raw_manifest(entries: &[Vec<u8>]) -> Vec<u8> {
    let mut b = vec![0xa0 + entries.len() as u8];
    for e in entries {
        b.extend(e);
    }
    b
}
fn kv(k: u64, v: V) -> Vec<u8> {
    let mut b = cbor::encode(&V::Uint(k));
    b.extend(cbor::encode(&v));
    b
}
fn good_entries() -> Vec<Vec<u8>> {
    vec![
        kv(1, V::Text("1.5.14-wsl.30".into())),
        kv(2, V::Text("ekh-bcm2711".into())),
        kv(3, V::Uint(5000)),
        kv(4, V::Bytes(vec![9; 32])),
        kv(5, V::Bytes(vec![0x82, 0x40, 0x40])),
    ]
}

#[test]
fn t1_signrel_manifests_are_taken_and_sent_byte_for_byte() {
    let (_, mf, _) = files();
    let dir = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("tests/testdata/swupd");
    let mut seen = 0;
    for b in [std::fs::read(dir.join("plain.manifest")).unwrap(), std::fs::read(dir.join("ok.manifest")).unwrap(), mf] {
        let x = su::parse_manifest(&b).unwrap();
        // the check body carries the manifest as a map: re-encoded it is the same bytes the signer wrote (§5.2)
        assert_eq!(cbor::encode(&x.value), b);
        assert!(x.version.starts_with("1.5.14-wsl.30"), "{}", x.version);
        seen += 1;
    }
    assert_eq!(seen, 3);
    assert!(su::parse_manifest(&raw_manifest(&good_entries())).is_ok());
}

#[test]
fn t1_mutations_are_refused_or_filtered() {
    use su::ManifestError as E;
    let mut e = good_entries();
    e[2] = vec![0x03, 0x1a, 0x00, 0x00, 0x13, 0x88]; // 5000 in 4 bytes
    assert_eq!(su::parse_manifest(&raw_manifest(&e)), Err(E::NotCbor), "non-shortest");
    let mut e = good_entries();
    e.swap(0, 1);
    assert_eq!(su::parse_manifest(&raw_manifest(&e)), Err(E::NotCbor), "key order");
    let mut b = raw_manifest(&good_entries());
    b.push(0);
    assert_eq!(su::parse_manifest(&b), Err(E::NotCbor), "trailing bytes");
    let e = good_entries()[..4].to_vec();
    assert_eq!(su::parse_manifest(&raw_manifest(&e)), Err(E::Key(5)), "no key 5");
    let mut e = good_entries();
    e[3] = kv(4, V::Bytes(vec![9; 31]));
    assert_eq!(su::parse_manifest(&raw_manifest(&e)), Err(E::Key(4)), "key 4 of 31 bytes");
    let mut e = good_entries();
    e[0] = kv(1, V::Bytes(b"1.5".to_vec()));
    assert_eq!(su::parse_manifest(&raw_manifest(&e)), Err(E::Key(1)), "key 1 a bstr");
    let mut e = good_entries();
    e[1] = kv(2, V::Uint(2711));
    assert_eq!(su::parse_manifest(&raw_manifest(&e)), Err(E::Key(2)), "key 2 not text");
    let mut e = good_entries();
    e[2] = kv(3, V::Text("5000".into()));
    assert_eq!(su::parse_manifest(&raw_manifest(&e)), Err(E::Key(3)), "key 3 not uint");
    let mut e = good_entries();
    e[4] = kv(5, V::Text("x".into()));
    assert_eq!(su::parse_manifest(&raw_manifest(&e)), Err(E::Key(5)), "key 5 not bstr");
    assert_eq!(su::parse_manifest(&cbor::encode(&V::Array(vec![]))), Err(E::NotMap));
    // RLO in the version: shown with the bidi control replaced (display_name), never as is
    let mut e = good_entries();
    e[0] = kv(1, V::Text("1.5.14\u{202e}03.lsw".into()));
    let x = su::parse_manifest(&raw_manifest(&e)).unwrap();
    assert!(!x.version.contains('\u{202e}') && x.version.contains('\u{fffd}'), "{:?}", x.version);
    let mut e = good_entries();
    e[0] = kv(1, V::Text("v".repeat(200)));
    assert_eq!(su::parse_manifest(&raw_manifest(&e)).unwrap().version.chars().count(), 64, "at most 64 characters shown");
    // 64 KiB: the largest manifest is taken, one byte more is refused before decoding
    let pad = |n: usize| {
        let mut e = good_entries();
        e.push(kv(6, V::Bytes(vec![0; 300])));
        let base = raw_manifest(&e).len() - 300;
        let mut e = good_entries();
        e.push(kv(6, V::Bytes(vec![0; n - base])));
        raw_manifest(&e)
    };
    assert_eq!(pad(su::MANIFEST_MAX).len(), su::MANIFEST_MAX);
    assert!(su::parse_manifest(&pad(su::MANIFEST_MAX)).is_ok());
    assert_eq!(pad(su::MANIFEST_MAX + 1).len(), su::MANIFEST_MAX + 1);
    assert_eq!(su::parse_manifest(&pad(su::MANIFEST_MAX + 1)), Err(E::TooLarge));
}

// ---- T2: the checks on the phone --------------------------------------------------------------------------------

#[test]
fn t2_only_a_matching_pair_is_sent() {
    use su::PickError as E;
    let (fs, mf, size) = files();
    let (p, mm) = su::pick(&fs).unwrap();
    assert_eq!((p, mm.size, mm.bytes.clone()), (1, size, mf.clone()));
    let swapped = vec![fs[1].clone(), fs[0].clone()];
    assert_eq!(su::pick(&swapped).unwrap().0, 0, "told apart by content, not by order");
    let with = |f: &dyn Fn(&mut Vec<Picked>)| {
        let mut x = fs.clone();
        f(&mut x);
        x
    };
    assert_eq!(su::pick(&with(&|x| x[1].size += 1)), Err(E::Size), "size");
    assert_eq!(su::pick(&with(&|x| x[1].head = b"PK".to_vec())), Err(E::NotGzip), "not gzip");
    assert_eq!(su::pick(&[fs[0].clone(), fs[0].clone()]), Err(E::BothManifest), "two manifests");
    assert_eq!(su::pick(&[fs[1].clone(), fs[1].clone()]), Err(E::NoManifest), "two payloads");
    assert_eq!(su::pick(&with(&|x| x[1].size = -1)), Err(E::SizeUnknown), "statSize -1");
    assert_eq!(su::pick(&with(&|x| x[0].size = -1)), Err(E::SizeUnknown), "statSize -1 (manifest)");
    assert_eq!(su::pick(&fs[..1]), Err(E::Count));
    assert_eq!(su::pick(&with(&|x| x[0].size = su::MANIFEST_MAX as i64 + 1)), Err(E::Manifest(su::ManifestError::TooLarge)));
    // none of them sends anything: the flow shows the text and stays
    for bad in [with(&|x| x[1].size += 1), with(&|x| x[1].head = b"PK".to_vec()), with(&|x| x[1].size = -1), vec![fs[0].clone(), fs[0].clone()]] {
        let mut r = Run::new(true);
        r.enter(w("status-idle"));
        let a = r.pick(&bad);
        assert!(text(&a).starts_with("檔案不對:"), "{a:?}");
        assert!(!r.verbs.contains(&"update/check"), "a bad pair was sent: {:?}", r.verbs);
    }
}

// ---- T3: texts --------------------------------------------------------------------------------------------------

#[test]
fn t3_every_row_of_section_4() {
    let c = Ctx { status: false, written: false, manifest: false };
    let st = Ctx { status: true, ..c };
    let after = Ctx { written: true, ..c };
    let mf = Ctx { manifest: true, ..c };
    let rows: Vec<(u64, Ctx, &str)> = vec![
        (1, c, "節點正在試用新版,等它確認(約 5 分鐘)後再更新"),
        (2, c, "節點的設定還沒存好,不能更新 — 請重開節點;仍然如此請找維修人員"),
        (3, c, "這個更新檔是給別種板子的"),
        (4, c, "要先裝中間版本才能更新到這版"),
        (5, c, "這版需要重燒卡,不能經 App 更新"),
        (6, c, "不允許降回這個版本"),
        (8, c, "節點的記憶體不夠放這個更新檔 — 請重開節點再試"),
        (11, c, "更新檔內容與簽章不符 — 檔案可能不是同一份(請確認 manifest 和更新檔是一起產生的),或傳輸中被換掉;請重新選檔或重新上傳"),
        (12, c, "節點有一個沒完成的網路變更 — 請等一下再試"),
        (15, c, "這個更新不是這支手機開始的,或已超過 30 分鐘 — 請重新開始更新"),
        (15, st, "上傳不完整,請重新上傳"),
        (16, c, "節點給手機連的 Wi-Fi 還沒設定(或被關閉),要先設定才能傳更新檔"),
        (17, c, "節點的設定沒有存到最新 — 請重開節點後再試"),
        (18, c, "新版沒有完成試用,節點已回到原本的版本"),
        (21, c, "節點現在無法寫入,請稍後再試"),
        (21, after, "這次寫入失敗,舊版本的退路可能已失效,請再更新一次"),
        (22, c, "上次寫入沒有完成,退路已失效,請再更新一次"),
        (23, mf, "新版已寫入但沒有啟用(節點重開過),請重新更新"),
        (23, c, "請重新選 manifest 檔;若節點重開過,要整個重新更新"),
        (24, c, "這台節點的軟體不能經 App 更新,請用電腦(ssh)更新或重燒卡"),
        (99, c, "更新沒有成功 — 請再試一次;一直如此請找維修人員"),
    ];
    for (r, x, want) in &rows {
        assert_eq!(su::reason_text(*r, *x), *want, "reason {r} {x:?}");
    }
    let none = V::Map(vec![]);
    assert_eq!(su::error_text(7, &none, c), "節點正在處理另一個更新(可能是另一支擁有者手機)— 請稍後再試");
    assert_eq!(su::error_text(10, &none, c), "節點的儲存區寫不進去,這次沒有開始 — 請重開節點後再試");
    assert_eq!(su::error_text(12, &none, c), "太快了,請稍等 10 秒再按");
    assert_eq!(su::error_text(6, &none, c), "這台節點的軟體太舊,不能經 App 更新");
    assert_eq!(su::error_text(11, &m(vec![(2, V::Uint(16))]), c), su::T_AP_OFF);
    assert_eq!(su::error_text(99, &none, c), su::OTHER_TEXT);
    // 6 (a refusal) and the phase 6 rows are three different texts
    assert_ne!(su::reason_text(6, c), su::T_REVERTED);
    assert_ne!(su::T_REVERTED, su::T_REVERTED_18);
    // §3.1: trust and the bound port
    let gate = |r: Reply, dev: bool| match r {
        Reply::Ok(b) => su::gate(&b, dev),
        _ => unreachable!(),
    };
    assert_eq!(gate(status15(None, vec![]), true), Err(su::T_TRUST_NONE.into()));
    assert_eq!(gate(status15(Some("none"), vec![]), true), Err(su::T_TRUST_NONE.into()));
    assert_eq!(gate(status15(Some("bad"), vec![]), true), Err(su::T_TRUST_BAD.into()));
    assert_eq!(gate(status15(Some("0123456789ABCDEF"), vec![]), true), Err(su::T_TRUST_BAD.into()), "not lowercase hex");
    assert_eq!(gate(status15(Some(TRUST), vec![]), true), Ok(format!("測試信任:{TRUST}")));
    assert_eq!(gate(status15(Some(TRUST), vec![]), false), Err(su::T_TRUST_FIELD.into()), "D13: a field build before #255");
    assert_eq!(gate(status15(Some(TRUST), vec![("http_bind_failed", V::Bool(true))]), true), Err(su::T_BIND_FAILED.into()));
}

#[test]
fn t3_screens_use_the_texts() {
    // trust none: the entry stops before update/status, with no file picker
    let mut r = Run::new(true);
    r.start();
    r.reply(status15(Some("none"), vec![]));
    let a = r.reply(Reply::Ok(m(vec![])));
    assert_eq!((text(&a), buttons(&a)), (su::T_TRUST_NONE.to_string(), vec![Button::Refresh]));
    assert!(!r.verbs.contains(&"update/status"));
    assert!(r.f.picked(&files().0).is_none(), "no picking on a blocked node");
    // a field build: blocked the same way; the dev build shows its trust line
    let mut r = Run::new(false);
    r.start();
    r.reply(status15(Some(TRUST), vec![]));
    assert_eq!(text(&r.reply(Reply::Ok(m(vec![])))), su::T_TRUST_FIELD);
    let mut r = Run::new(true);
    let Action::Show(s) = r.enter(w("status-idle")) else { panic!() };
    assert_eq!(s.tech, format!("測試信任:{TRUST}"));
    // check refusals: their texts
    for (x, want) in [("check-refused-nokey", su::reason_text(24, Ctx { status: false, written: false, manifest: true })), ("check-refused-board", "這個更新檔是給別種板子的".into()), ("check-refused-downgrade", "不允許降回這個版本".into())] {
        let mut r = Run::new(true);
        r.enter(w("status-idle"));
        r.pick(&files().0);
        assert_eq!(text(&r.reply(w(x))), want, "{x}");
    }
}

// ---- T4: the path -----------------------------------------------------------------------------------------------

#[test]
fn t4_the_whole_path_in_order_with_its_waits_and_no_secret_in_any_text() {
    let mut r = Run::new(true);
    let a = r.to_upload();
    let Action::Upload { ip, port, bearer, size, payload } = &a else { panic!("{a:?}") };
    let (_, _, want_size) = files();
    assert_eq!((ip.as_str(), *port, *size, *payload), ("10.41.80.13", 8095, want_size, 1));
    let bearer = *bearer;
    assert!(r.f.uploading());
    assert_eq!(r.f.ap_credentials(), Some(("batman-ap".to_string(), PASS.to_string())));
    // U6: a keepalive read while the PUT runs; its answer changes nothing
    let k = r.f.keepalive().unwrap();
    r.see(k);
    assert!(r.f.keepalive().is_none(), "one keepalive at a time");
    assert!(r.f.on_reply(w("status-receiving"), r.now).is_none());
    // U7: 200 -> prepare -> U8 -> written
    assert_eq!(verb(&r.put(Put::Ok200)), Verb::Prepare);
    let a = r.reply(w("prepare-ok"));
    assert!(matches!(a, Action::Wait { ms: 5000, percent: Some(0), .. }), "{a:?}");
    assert!(!r.f.uploading(), "the upload phase ends at U8");
    assert_eq!(r.f.ap_credentials(), None, "the window secrets are dropped");
    r.after(&a);
    let a = r.reply(w("status-working"));
    assert!(matches!(a, Action::Wait { percent: Some(50), .. }), "{a:?}");
    r.after(&a);
    let a = r.reply(w("status-written"));
    assert_eq!(buttons(&a), vec![Button::Apply, Button::Refresh]);
    assert_eq!(verb(&r.press(Button::Apply)), Verb::Apply);
    // U10: apply -> reboot (no link) -> trial -> committed
    let a = r.reply(w("apply-ok"));
    r.after(&a);
    let a = r.reply(Reply::NoLink);
    r.after(&a);
    let a = r.reply(w("status-trial"));
    assert!(matches!(a, Action::Wait { ms: 30000, .. }));
    r.after(&a);
    let a = r.reply(w("status-committed"));
    assert_eq!(text(&a), "更新完成:1.5.14-wsl.30+abcdef1.fw0123456");
    assert!(matches!(a, Action::Done(_)));
    assert_eq!(
        r.verbs,
        [
            "status", "info", "update/status", "update/check", "bulk/open", "PUT", "update/status", "update/prepare", "update/status",
            "update/status", "update/apply", "update/status", "update/status", "update/status"
        ]
    );
    // D14: check and apply wait at least 340 s; the others 15 s
    for (v, ms) in &r.sends {
        let want = if matches!(v, Verb::Check | Verb::Apply) { 340_000 } else { 15_000 };
        assert_eq!(*ms, want, "{v:?} waits {ms} ms");
    }
    // no text ever carries the passphrase or the bearer (raw, hex, upper hex)
    let hexb = hex::encode(bearer);
    assert!(!r.texts.is_empty());
    for t in &r.texts {
        assert!(!t.contains(PASS) && !t.contains(&hexb) && !t.contains(&hexb.to_uppercase()), "a secret in {t:?}");
        assert!(!t.as_bytes().windows(16).any(|x| x == bearer), "raw bearer in {t:?}");
    }
}

#[test]
fn t4_a_bulk_open_answer_missing_a_key_stops_and_closes() {
    let Reply::Ok(V::Map(full)) = w("bulk-open-ok") else { panic!() };
    for k in 1..=6u64 {
        let mut r = Run::new(true);
        r.to_confirm();
        r.press(Button::Start);
        let cut: Vec<(V, V)> = full.iter().filter(|(x, _)| *x != V::Uint(k)).cloned().collect();
        let a = r.reply(Reply::Ok(V::Map(cut)));
        assert_eq!(verb(&a), Verb::BulkClose, "key {k} missing");
        let a = r.reply(w("bulk-close-ok"));
        assert_eq!(text(&a), su::T_BAD_WINDOW, "key {k}");
        assert!(!r.verbs.contains(&"PUT"));
    }
    for (k, v) in [(4u64, V::Uint(0)), (4, V::Uint(70000)), (3, V::Text("node.local".into())), (6, V::Bytes(vec![1; 15]))] {
        let mut r = Run::new(true);
        r.to_confirm();
        r.press(Button::Start);
        let bad: Vec<(V, V)> = full.iter().map(|(x, y)| if *x == V::Uint(k) { (x.clone(), v.clone()) } else { (x.clone(), y.clone()) }).collect();
        assert_eq!(verb(&r.reply(Reply::Ok(V::Map(bad)))), Verb::BulkClose, "key {k} = {v:?}");
    }
}

#[test]
fn t4b_reason_16_waits_for_the_ap_then_goes_on() {
    let mut r = Run::new(true);
    r.to_confirm();
    r.press(Button::Start);
    let a = r.reply(w("bulk-open-16"));
    assert_eq!(text(&a), su::T_AP_OFF);
    assert_eq!(buttons(&a), vec![Button::SetAp, Button::ApDone, Button::Cancel]);
    assert!(r.f.press(Button::SetAp, r.now).is_none(), "SetAp is the page: the flow waits");
    // the AP was set: 21 twice (the AP and the firewall check come up), then the window
    assert_eq!(verb(&r.press(Button::ApDone)), Verb::BulkOpen);
    let a = r.reply(w("bulk-open-21"));
    assert!(matches!(a, Action::Wait { ms: 5000, .. }));
    r.after(&a);
    let a = r.reply(w("bulk-open-21"));
    r.after(&a);
    assert!(matches!(r.reply(w("bulk-open-ok")), Action::Upload { .. }));
    // still 16 after 30 s: the text, no more tries
    let mut r = Run::new(true);
    r.to_confirm();
    r.press(Button::Start);
    r.reply(w("bulk-open-16"));
    r.press(Button::ApDone);
    let mut n = 0;
    let mut guard = 0;
    let end = loop {
        guard += 1;
        assert!(guard < 500, "the flow never ended");
        let a = r.reply(w("bulk-open-16"));
        match a {
            Action::Wait { .. } => {
                n += 1;
                r.after(&a);
            }
            a => break a,
        }
    };
    assert_eq!((n, text(&end)), (6, su::T_AP_OFF.to_string()), "every 5 s for 30 s");
    assert!(buttons(&end).contains(&Button::Refresh));
    // 15 (the pending expired meanwhile) -> U2; cancel on the 16 screen sends nothing
    let mut r = Run::new(true);
    r.to_confirm();
    r.press(Button::Start);
    r.reply(w("bulk-open-16"));
    r.press(Button::ApDone);
    assert_eq!(verb(&r.reply(w("bulk-open-15"))), Verb::Check);
    let mut r = Run::new(true);
    r.to_confirm();
    r.press(Button::Start);
    r.reply(w("bulk-open-16"));
    let n = r.verbs.len();
    assert!(buttons(&r.press(Button::Cancel)).contains(&Button::Pick));
    assert_eq!(r.verbs.len(), n, "cancel = nothing sent");
}

// ---- T5: §3.4 ---------------------------------------------------------------------------------------------------

#[test]
fn t5_prepare_outcome_unknown_reads_status_and_never_prepares_again() {
    for x in [w("update-prepare-outcome-unknown"), w("prepare-busy"), Reply::Lost] {
        let mut r = Run::new(true);
        r.to_upload();
        r.put(Put::Ok200);
        assert_eq!(verb(&r.reply(x)), Verb::UpdStatus);
        assert!(matches!(r.reply(w("status-working")), Action::Wait { ms: 5000, .. }));
        assert_eq!(r.verbs.iter().filter(|v| **v == "update/prepare").count(), 1);
    }
}

#[test]
fn t5_every_put_is_preceded_by_bulk_open_and_waits_31_s_after_a_failure() {
    let mut r = Run::new(true);
    r.to_upload();
    for _ in 0..2 {
        let a = r.put(Put::Other);
        assert!(matches!(a, Action::Wait { ms: 31000, .. }), "{a:?}");
        assert!(r.f.uploading(), "the Specifier network is kept between tries (not requested again)");
        let a = r.after(&a);
        assert_eq!(verb(&a), Verb::UpdStatus, "the status is read after the wait (D15)");
        assert_eq!(verb(&r.reply(w("status-receiving"))), Verb::BulkOpen);
        assert!(r.f.uploading());
        assert!(matches!(r.reply(w("bulk-open-ok")), Action::Upload { .. }));
    }
    assert_eq!(verb(&r.put(Put::Ok200)), Verb::Prepare);
    let puts: Vec<usize> = r.verbs.iter().enumerate().filter(|(_, v)| **v == "PUT").map(|(i, _)| i).collect();
    assert_eq!(puts.len(), 3);
    for i in puts {
        assert_eq!(r.verbs[i - 1], "bulk/open", "a PUT without a bulk/open right before it: {:?}", r.verbs);
    }
    // three PUTs that are not 200 -> the text; the 31 s waits came before the second and the third
    let mut r = Run::new(true);
    r.to_upload();
    for _ in 0..2 {
        let a = r.put(Put::Other);
        r.after(&a);
        r.reply(w("status-idle"));
        r.reply(w("bulk-open-ok"));
    }
    assert_eq!(text(&r.put(Put::Other)), su::T_PUT_FAILED);
    assert_eq!(r.waits.iter().filter(|ms| **ms == 31_000).count(), 2);
    assert!(!r.f.uploading(), "3 failures end the upload phase");
    // a PUT failure, then status 2 (it did land): U8
    let mut r = Run::new(true);
    r.to_upload();
    let a = r.put(Put::Other);
    r.after(&a);
    assert!(matches!(r.reply(w("status-working")), Action::Wait { ms: 5000, .. }));
}

#[test]
fn t5_prepare_15_counts_only_for_our_upload() {
    // 15 with our phase 1: counted, wait 31 s, bulk/open + PUT again; the third in a row: P3 :517
    let mut r = Run::new(true);
    r.to_upload();
    for i in 0..3 {
        r.put(Put::Ok200);
        assert_eq!(verb(&r.reply(w("prepare-15-incomplete"))), Verb::UpdStatus);
        let a = r.reply(w("status-receiving"));
        if i == 2 {
            assert_eq!(text(&a), su::T_REJECTED_UPLOAD);
            break;
        }
        assert!(matches!(a, Action::Wait { ms: 31000, .. }));
        assert_eq!(verb(&r.after(&a)), Verb::BulkOpen);
        r.reply(w("bulk-open-ok"));
    }
    // 15 with anything else: bulk/open at once, never counted
    let mut r = Run::new(true);
    r.to_upload();
    for _ in 0..5 {
        r.put(Put::Ok200);
        r.reply(w("prepare-15-not-holder"));
        assert_eq!(verb(&r.reply(w("status-idle"))), Verb::BulkOpen);
        assert!(matches!(r.reply(w("bulk-open-ok")), Action::Upload { .. }));
    }
    // and bulk/open answering 15 there -> U2
    r.put(Put::Ok200);
    r.reply(w("prepare-15-not-holder"));
    r.reply(w("status-idle"));
    assert_eq!(verb(&r.reply(w("bulk-open-15"))), Verb::Check);
}

#[test]
fn t5_status_0_15_and_0_11_count_and_a_success_resets() {
    let written = |r: &mut Run| {
        r.put(Put::Ok200);
        let a = r.reply(w("prepare-ok"));
        r.after(&a);
    };
    let mut r = Run::new(true);
    r.to_upload();
    for (i, x) in ["status-0-15", "status-0-11", "status-0-15"].iter().enumerate() {
        written(&mut r);
        let a = r.reply(w(x));
        if i == 2 {
            assert_eq!(text(&a), su::T_REJECTED_UPLOAD);
            assert!(buttons(&a).contains(&Button::Pick));
        } else {
            assert_eq!(verb(&a), Verb::BulkOpen, "U4 with the same files");
            r.reply(w("bulk-open-ok"));
        }
    }
    // two, then a written update, then two more: never three in a row
    let mut r = Run::new(true);
    r.to_upload();
    for x in ["status-0-15", "status-0-11"] {
        written(&mut r);
        r.reply(w(x));
        r.reply(w("bulk-open-ok"));
    }
    written(&mut r);
    assert_eq!(buttons(&r.reply(w("status-written"))), vec![Button::Apply, Button::Refresh]);
    r.refresh_to(w("status-idle"));
    r.pick(&files().0);
    r.reply(w("check-ok"));
    r.press(Button::Start);
    r.reply(w("bulk-open-ok"));
    written(&mut r);
    r.reply(w("status-0-15"));
    r.reply(w("bulk-open-ok"));
    written(&mut r);
    assert_eq!(verb(&r.reply(w("status-0-11"))), Verb::BulkOpen, "a fresh pick starts the count again");
    // the 0-15 of another update is not ours: its text, not counted
    let mut r = Run::new(true);
    r.to_upload();
    written(&mut r);
    assert_eq!(text(&r.reply(others(w("status-0-15")))), "上傳不完整,請重新上傳");
}

#[test]
fn t5_cancel_closes_the_window_and_a_gone_node_says_so() {
    let mut r = Run::new(true);
    r.to_upload();
    assert_eq!(verb(&r.press(Button::Cancel)), Verb::BulkClose);
    assert!(!r.f.uploading());
    let a = r.reply(w("bulk-close-ok"));
    assert_eq!((text(&a), matches!(a, Action::Done(_))), (su::T_CANCELLED.to_string(), true));
    assert!(r.f.uploaded(Put::Ok200).is_none(), "the PUT result after the cancel means nothing");
    // cancel while waiting the 31 s after a failed PUT
    let mut r = Run::new(true);
    r.to_upload();
    r.put(Put::Other);
    assert_eq!(verb(&r.press(Button::Cancel)), Verb::BulkClose);
    // the node rebooted meanwhile: no BLE -> 「節點還沒回來」
    let mut r = Run::new(true);
    r.to_upload();
    let a = r.put(Put::Other);
    r.after(&a);
    assert_eq!(text(&r.reply(Reply::NoLink)), su::T_NOT_BACK);
    let mut r = Run::new(true);
    r.to_confirm();
    r.press(Button::Start);
    assert_eq!(text(&r.reply(Reply::NoLink)), su::T_NOT_BACK);
    // U5: the Wi-Fi was not reached -> the text; cancel there closes the open window
    let mut r = Run::new(true);
    r.to_upload();
    let a = r.put(Put::NoNetwork);
    assert_eq!((text(&a), buttons(&a)), (su::T_NO_WIFI.to_string(), vec![Button::WifiPanel, Button::Retry, Button::Cancel]));
    assert_eq!(verb(&r.press(Button::Cancel)), Verb::BulkClose);
    let mut r = Run::new(true);
    r.to_upload();
    r.put(Put::Denied);
    assert_eq!(verb(&r.press(Button::Retry)), Verb::BulkOpen, "U5 again: bulk/open before the PUT");
}

#[test]
fn t5_busy_or_lost_verbs_read_status_then_retry_after_10_s_three_times() {
    let mut r = Run::new(true);
    r.enter(w("status-idle"));
    r.pick(&files().0);
    assert_eq!(verb(&r.reply(w("check-busy"))), Verb::UpdStatus);
    let a = r.reply(w("status-idle"));
    assert!(matches!(a, Action::Wait { ms: 10000, .. }));
    assert_eq!(verb(&r.after(&a)), Verb::Check);
    r.reply(Reply::Lost);
    let a = r.reply(w("status-idle"));
    assert_eq!(verb(&r.after(&a)), Verb::Check);
    r.reply(w("update-check-outcome-unknown"));
    assert_eq!(text(&r.reply(w("status-idle"))), su::E_BUSY_TEXT, "the third send: no more");
    assert_eq!(r.verbs.iter().filter(|v| **v == "update/check").count(), 3);
    // E_RATE: once more after 10 s, the second one is the text
    let mut r = Run::new(true);
    r.enter(w("status-idle"));
    r.pick(&files().0);
    let a = r.reply(w("check-rate"));
    assert!(matches!(a, Action::Wait { ms: 10000, .. }));
    r.after(&a);
    assert_eq!(text(&r.reply(w("check-rate-connection"))), su::E_RATE_TEXT);
    // a check whose status read shows another update: no resend, §3.3 instead
    let mut r = Run::new(true);
    r.enter(w("status-idle"));
    r.pick(&files().0);
    r.reply(w("check-busy-other-owner"));
    assert_eq!(buttons(&r.reply(others(w("status-receiving")))), vec![Button::Abandon, Button::Refresh]);
    // bulk/open E_BUSY (another owner's window) -> status -> 1 not ours -> §3.3
    let mut r = Run::new(true);
    r.to_confirm();
    r.press(Button::Start);
    assert_eq!(verb(&r.reply(w("bulk-open-busy"))), Verb::UpdStatus);
    assert_eq!(buttons(&r.reply(others(w("status-receiving")))), vec![Button::Abandon, Button::Refresh]);
}

// ---- T6: §3.3 ---------------------------------------------------------------------------------------------------

#[test]
fn t6_each_row_of_section_3_3() {
    // 0, nothing seen: idle
    let mut r = Run::new(true);
    assert_eq!(buttons(&r.enter(w("status-idle"))), vec![Button::Pick, Button::Refresh]);
    // 1, not ours (no files picked): offer to abandon; bulk/close ok -> idle; 15 -> not this phone
    let mut r = Run::new(true);
    let a = r.enter(w("status-receiving"));
    assert!(text(&a).starts_with("節點上有一個上傳中的更新(1.5.14-wsl.30"), "{a:?}");
    assert_eq!(verb(&r.press(Button::Abandon)), Verb::BulkClose);
    assert_eq!(buttons(&r.reply(w("bulk-close-ok"))), vec![Button::Pick, Button::Refresh]);
    let mut r = Run::new(true);
    r.enter(w("status-receiving"));
    r.press(Button::Abandon);
    assert_eq!(text(&r.reply(w("bulk-close-15"))), su::T_NOT_MINE);
    assert!(!r.verbs.contains(&"update/check"), "no check before the window was closed");
    // 1, ours (the files picked, then the entry read again): wait 31 s, then bulk/open
    let mut r = Run::new(true);
    r.to_confirm();
    r.press(Button::Cancel);
    let a = r.refresh_to(w("status-receiving"));
    assert!(matches!(a, Action::Wait { ms: 31000, .. }));
    assert_eq!(verb(&r.after(&a)), Verb::BulkOpen);
    // 2 -> U8; 3 -> apply; 4 -> trial; 5 / 6 -> 「上一次更新:」
    let mut r = Run::new(true);
    assert!(matches!(r.enter(w("status-working")), Action::Wait { ms: 5000, .. }));
    let mut r = Run::new(true);
    assert_eq!(buttons(&r.enter(w("status-written"))), vec![Button::Apply, Button::Refresh]);
    let mut r = Run::new(true);
    assert!(matches!(r.enter(w("status-trial")), Action::Wait { ms: 30000, .. }));
    let mut r = Run::new(true);
    assert_eq!(text(&r.enter(w("status-committed"))), "上一次更新:更新完成:1.5.14-wsl.30+abcdef1.fw0123456");
    let mut r = Run::new(true);
    assert_eq!(text(&r.enter(w("status-reverted"))), format!("上一次更新:{}", su::T_REVERTED));
    let mut r = Run::new(true);
    assert_eq!(text(&r.enter(w("status-reverted-18"))), format!("上一次更新:{}", su::T_REVERTED_18));
    // 0 + reason without files: its §4 text (status context)
    for (x, want) in [("status-0-15", "上傳不完整,請重新上傳"), ("status-0-22", "上次寫入沒有完成,退路已失效,請再更新一次"), ("status-0-21", "節點現在無法寫入,請稍後再試"), ("status-0-11", su::reason_text(11, Ctx { status: true, written: false, manifest: false }).leak())] {
        let mut r = Run::new(true);
        assert_eq!(text(&r.enter(w(x))), want, "{x}");
    }
    let mut r = Run::new(true);
    assert_eq!(text(&r.enter(w("status-0-23"))), "請重新選 manifest 檔;若節點重開過,要整個重新更新");
    // 0 + 23 with the manifest at hand: check again once
    let mut r = Run::new(true);
    r.to_confirm();
    r.press(Button::Cancel);
    assert_eq!(verb(&r.refresh_to(w("status-0-23"))), Verb::Check);
    assert_eq!(verb(&r.reply(w("check-ok"))), Verb::UpdStatus);
    assert_eq!(text(&r.reply(w("status-0-23"))), "新版已寫入但沒有啟用(節點重開過),請重新更新");
    // another owner has written one (3); apply answers 15 -> no manifest here: pick it again
    let mut r = Run::new(true);
    r.enter(others(w("status-written")));
    r.press(Button::Apply);
    assert_eq!(text(&r.reply(w("apply-15"))), su::T_REPICK);
    // 21 after the writing began: the other text
    let mut r = Run::new(true);
    r.to_upload();
    r.put(Put::Ok200);
    let a = r.reply(w("prepare-ok"));
    r.after(&a);
    assert_eq!(text(&r.reply(w("status-0-21"))), "這次寫入失敗,舊版本的退路可能已失效,請再更新一次");
}

#[test]
fn t6_zero_without_a_reason_after_2_is_unsure_for_two_minutes() {
    let mut r = Run::new(true);
    let a = r.enter(w("status-working"));
    r.after(&a);
    let mut a = r.reply(w("status-idle"));
    assert_eq!(a, Action::Wait { ms: 30000, note: su::T_UNSURE.into(), percent: None });
    let mut reads = 0;
    let mut guard = 0;
    let end = loop {
        guard += 1;
        assert!(guard < 500, "the flow never ended");
        r.after(&a);
        reads += 1;
        a = r.reply(w("status-idle"));
        if !matches!(a, Action::Wait { .. }) {
            break a;
        }
    };
    assert_eq!((reads, text(&end)), (4, su::T_NOT_DONE.to_string()), "every 30 s for 2 minutes");
    // a change during the wait is read as usual
    let mut r = Run::new(true);
    let a = r.enter(w("status-working"));
    r.after(&a);
    let a = r.reply(w("status-idle"));
    r.after(&a);
    assert_eq!(buttons(&r.reply(w("status-written"))), vec![Button::Apply, Button::Refresh]);
}

// ---- T7: after apply ----------------------------------------------------------------------------------------------

fn applied() -> (Run, Action) {
    let mut r = Run::new(true);
    r.enter(w("status-written"));
    r.press(Button::Apply);
    let a = r.reply(w("apply-ok"));
    (r, a)
}

#[test]
fn t7_after_apply_trial_done_reverted_and_time_limits() {
    for (x, want) in [("status-committed", "更新完成:1.5.14-wsl.30+abcdef1.fw0123456"), ("status-reverted", su::T_REVERTED), ("status-reverted-18", su::T_REVERTED_18)] {
        let (mut r, a) = applied();
        r.after(&a);
        let a = r.reply(w(x));
        assert_eq!((text(&a), matches!(a, Action::Done(_))), (want.to_string(), true), "{x}");
    }
    // the node does not come back in 5 minutes
    let (mut r, mut a) = applied();
    let mut tries = 0;
    let mut guard = 0;
    let end = loop {
        guard += 1;
        assert!(guard < 500, "the flow never ended");
        r.after(&a);
        tries += 1;
        a = r.reply(Reply::NoLink);
        if !matches!(a, Action::Wait { .. }) {
            break a;
        }
    };
    assert_eq!(text(&end), su::T_LATER);
    assert!((29..=31).contains(&tries), "every 10 s for 5 minutes: {tries}");
    // the trial does not end in 15 minutes
    let (mut r, a) = applied();
    r.after(&a);
    let mut a = r.reply(w("status-trial"));
    let mut reads = 0;
    let mut guard = 0;
    let end = loop {
        guard += 1;
        assert!(guard < 500, "the flow never ended");
        r.after(&a);
        reads += 1;
        a = r.reply(w("status-trial"));
        if !matches!(a, Action::Wait { .. }) {
            break a;
        }
    };
    assert_eq!((reads, text(&end)), (30, su::T_LATER.to_string()), "every 30 s for 15 minutes");
    // the trial reverted: the node reboots again (no link a while), then 6
    let (mut r, a) = applied();
    r.after(&a);
    let a = r.reply(w("status-trial"));
    r.after(&a);
    let a = r.reply(Reply::NoLink);
    assert!(matches!(a, Action::Wait { ms: 10000, .. }), "a second reboot: log in again");
    r.after(&a);
    let a = r.reply(Reply::Lost);
    r.after(&a);
    assert_eq!(text(&r.reply(w("status-reverted"))), su::T_REVERTED);
}

#[test]
fn t7_a_lost_apply_answer_and_a_pending_that_expired() {
    // the answer was lost: status 3 -> apply can be pressed again; 4 -> it went through
    let mut r = Run::new(true);
    r.enter(w("status-written"));
    r.press(Button::Apply);
    assert_eq!(verb(&r.reply(Reply::Lost)), Verb::UpdStatus);
    assert_eq!(buttons(&r.reply(w("status-written"))), vec![Button::Apply, Button::Refresh]);
    for x in [w("update-apply-outcome-unknown"), w("apply-busy")] {
        let mut r = Run::new(true);
        r.enter(w("status-written"));
        r.press(Button::Apply);
        r.reply(x);
        assert!(matches!(r.reply(w("status-trial")), Action::Wait { ms: 30000, .. }));
    }
    // the link went with the apply (the node rebooted): read on as a reboot
    let mut r = Run::new(true);
    r.enter(w("status-written"));
    r.press(Button::Apply);
    r.reply(Reply::NoLink);
    assert!(matches!(r.reply(Reply::NoLink), Action::Wait { ms: 10000, .. }));
    // the worker ended 31 minutes ago (pending gone): apply 15 -> check (the manifest at hand) -> 3 -> apply, never
    // a new upload
    let to_written = |r: &mut Run| {
        r.to_upload();
        r.put(Put::Ok200);
        let a = r.reply(w("prepare-ok"));
        r.after(&a);
        r.reply(w("status-written"));
        r.press(Button::Apply);
    };
    let mut r = Run::new(true);
    to_written(&mut r);
    assert_eq!(verb(&r.reply(w("apply-15"))), Verb::Check);
    assert_eq!(verb(&r.reply(w("check-ok"))), Verb::UpdStatus);
    assert_eq!(buttons(&r.reply(w("status-written"))), vec![Button::Apply, Button::Refresh]);
    assert_eq!(verb(&r.press(Button::Apply)), Verb::Apply);
    assert!(matches!(r.reply(w("apply-ok")), Action::Wait { .. }));
    assert_eq!(r.verbs.iter().filter(|v| **v == "bulk/open").count(), 1, "no new upload");
    assert_eq!(r.verbs.iter().filter(|v| **v == "PUT").count(), 1);
    // a second 15 after that check: not this phone
    let mut r = Run::new(true);
    to_written(&mut r);
    r.reply(w("apply-15"));
    r.reply(w("check-ok"));
    r.reply(w("status-written"));
    r.press(Button::Apply);
    assert_eq!(text(&r.reply(w("apply-15"))), su::T_NOT_MINE);
}

#[test]
fn t7_tak_is_asked_before_apply() {
    let mut r = Run::new(true);
    r.start();
    r.reply(status15(Some(TRUST), vec![("tenants", V::Text("ots_eud_gateway:Up 5 minutes opentakserver:Up 5 minutes ".into()))]));
    r.reply(Reply::Ok(m(vec![])));
    r.reply(w("status-written"));
    let a = r.press(Button::Apply);
    assert_eq!((text(&a), buttons(&a)), (su::T_TAK.to_string(), vec![Button::ApplyAnyway, Button::Cancel]));
    assert_eq!(buttons(&r.press(Button::Cancel)), vec![Button::Apply, Button::Refresh], "cancel goes back, nothing sent");
    assert!(!r.verbs.contains(&"update/apply"));
    r.press(Button::Apply);
    assert_eq!(verb(&r.press(Button::ApplyAnyway)), Verb::Apply);
    // no TAK: apply goes out at once
    let mut r = Run::new(true);
    r.enter(w("status-written"));
    assert_eq!(verb(&r.press(Button::Apply)), Verb::Apply);
}

#[test]
fn the_bodies_are_the_cddl_shapes() {
    let mut r = Run::new(true);
    r.enter(w("status-idle"));
    let (fs, mf, _) = files();
    let Action::Send { body, .. } = r.pick(&fs) else { panic!() };
    // update-check-req {1: update-manifest}: the manifest bytes as they were picked
    let enc = cbor::encode(&body);
    assert_eq!(enc[..2], [0xa1, 0x01]);
    assert_eq!(&enc[2..], &mf[..]);
    r.reply(w("check-ok"));
    let Action::Send { body, verb, .. } = r.press(Button::Start) else { panic!() };
    assert!(verb.owner_op());
    assert_eq!(body, m(vec![(1, V::Uint(0)), (2, V::Bytes(sha()))]));
    r.reply(w("bulk-open-ok"));
    let Action::Send { body, verb, .. } = r.put(Put::Ok200) else { panic!() };
    assert_eq!((verb.wire(), body), ("update/prepare", m(vec![(1, V::Bytes(sha()))])));
    assert!(Verb::Prepare.owner_op() && Verb::Apply.owner_op() && Verb::BulkClose.owner_op() && !Verb::Check.owner_op() && !Verb::UpdStatus.owner_op());
}

#[test]
fn t5_a_written_update_resets_the_count() {
    // two in a row, then the update is written (3: a success), then one more: not three in a row
    let mut r = Run::new(true);
    r.to_upload();
    for x in ["status-0-15", "status-0-11"] {
        r.put(Put::Ok200);
        let a = r.reply(w("prepare-ok"));
        r.after(&a);
        assert_eq!(verb(&r.reply(w(x))), Verb::BulkOpen);
        r.reply(w("bulk-open-ok"));
    }
    r.put(Put::Ok200);
    let a = r.reply(w("prepare-ok"));
    r.after(&a);
    r.reply(w("status-written"));
    r.press(Button::Apply);
    // the apply answer is lost; the status read then shows our upload refused (0 + 15)
    assert_eq!(verb(&r.reply(Reply::Lost)), Verb::UpdStatus);
    let a = r.reply(w("status-0-15"));
    assert_eq!(verb(&a), Verb::BulkOpen, "counted from 0 again after the written update: {a:?}");
}
