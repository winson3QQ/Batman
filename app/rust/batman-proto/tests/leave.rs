//! 「離開網路」 (docs/design/254-app-leave.md v4.1 FROZEN §6): T1 — `flow::leave_outcome` and its texts, plus the S4
//! cross-doc parts (status page key 11 line, the leaving cut, the leave button). Negative controls: mutants of
//! src/flow.rs / src/statuspage.rs (scratch runner), and the v3 table's answers checked against the same assertions.

use batman_proto::cbor::Value as V;
use batman_proto::flow::{self, Leave};
use batman_proto::statuspage::{self as sp, Answer, JoinButton};

/// an owner info answer: key 7 (cached state), key 10 present or not, key 11 (None = missing)
fn info(k7: u64, k10: bool, k11: Option<bool>) -> V {
    let mut m = vec![(V::Uint(7), V::Uint(k7))];
    if k10 {
        m.push((V::Uint(9), V::Uint(1)));
        m.push((V::Uint(10), V::Bytes(vec![0x5a; 16])));
    }
    if let Some(b) = k11 {
        m.push((V::Uint(11), V::Bool(b)));
    }
    V::Map(m)
}

const REBOOT: &str = "重新開機";
const STILL_ON: &str = "還在隊伍網路上";

/// reboot ADVICE: the text without the 10-minute fallback and without 「不要在處理中重新開機」
fn advises_reboot(t: &str) -> bool {
    t.replace("超過 10 分鐘仍如此，重新開機一次", "").replace("不要在處理中重新開機", "").contains(REBOOT)
}

fn out(sent: bool, code: Option<u64>, i: Option<&V>) -> Leave {
    flow::leave_outcome(sent, code, i)
}

#[test]
fn t1_not_sent() {
    // op/nonce 7 + key 11 true: not sent, busy wording — never Unfinished, never reboot, never "still on the mesh"
    let l = out(false, Some(7), Some(&info(2, false, Some(true))));
    assert_eq!(l, Leave::NotSentBusy { out: false });
    let t = l.text();
    assert!(t.contains("沒有送出") && !advises_reboot(&t) && !t.contains(STILL_ON), "{t}");
    assert_ne!(l, Leave::Unfinished, "v3 table: op/nonce 7 fell to Unfinished");
    // op/nonce 3: re-connect, no reboot
    let t = out(false, Some(3), Some(&info(2, true, Some(false)))).text();
    assert!(t.contains("代碼 3") && t.contains("重新連線") && !advises_reboot(&t), "{t}");
    // other code / signature failure
    assert_eq!(out(false, Some(10), None), Leave::NotSent { code: Some(10), out: false });
    let t = out(false, None, Some(&info(2, true, Some(false)))).text();
    assert!(t.contains("手機簽章失敗") && !advises_reboot(&t), "{t}");
    // the info only picks the wording: not in a network -> the suffix
    assert_eq!(out(false, Some(7), Some(&info(1, false, Some(false)))), Leave::NotSentBusy { out: true });
    assert!(out(false, Some(7), Some(&info(1, false, Some(false)))).text().ends_with("（這台目前不在隊伍網路裡）"));
    assert_eq!(out(false, Some(7), None), Leave::NotSentBusy { out: false }, "info unreadable: no suffix");
}

#[test]
fn t1_sent() {
    let i = |k10, k11| info(2, k10, k11);
    // 7: the leave may still run — only what is seen now, never 「沒有離開」, never reboot
    let l = out(true, Some(7), Some(&i(true, Some(false))));
    assert_eq!(l, Leave::BusyMember);
    assert!(!l.text().contains("沒有離開") && !advises_reboot(&l.text()), "{}", l.text());
    let l = out(true, Some(7), Some(&i(true, Some(true))));
    assert_eq!(l, Leave::BusyChanging);
    assert!(!advises_reboot(&l.text()) && l.text().contains("不要在處理中重新開機"));
    assert_eq!(out(true, Some(7), Some(&i(false, Some(true)))), Leave::BusyChanging);
    // 7 after a commit (key 10 gone, nothing unfinished): already out — not Busy, not Left
    assert_eq!(out(true, Some(7), Some(&i(false, Some(false)))), Leave::AlreadyOut);
    // 11 + key 11 true: forget / Finish failed — the one place with reboot advice besides NotLeft
    let l = out(true, Some(11), Some(&i(false, Some(true))));
    assert_eq!(l, Leave::Unfinished, "must not be NotLeft");
    assert!(advises_reboot(&l.text()) && l.text().contains("（加入中也會這樣）"));
    // other codes + key 11 true: Changing, reboot only after 10 minutes
    let l = out(true, Some(3), Some(&i(true, Some(true))));
    assert_eq!(l, Leave::Changing);
    assert!(!advises_reboot(&l.text()) && l.text().contains("超過 10 分鐘仍如此，重新開機一次"));
    // still a member, nothing unfinished: per code
    let l = out(true, Some(11), Some(&i(true, Some(false))));
    assert_eq!(l, Leave::NotLeft);
    assert!(advises_reboot(&l.text()), "11 = a bad boot verdict: reboot");
    let l = out(true, Some(3), Some(&i(true, Some(false))));
    assert_eq!(l, Leave::NotLeftAuth);
    assert!(l.text().contains("會重新取得授權") && !advises_reboot(&l.text()));
    let l = out(true, Some(10), Some(&i(true, Some(false))));
    assert_eq!(l, Leave::NotLeftOther(10));
    assert!(!advises_reboot(&l.text()) && l.text().contains("代碼 10"));
    // unknown: key 11 missing, info unreadable, key 10 malformed
    assert_eq!(out(true, Some(11), Some(&i(true, None))), Leave::Unknown);
    assert_eq!(out(true, Some(11), None), Leave::Unknown);
    let bad = V::Map(vec![(V::Uint(10), V::Text("x".into())), (V::Uint(11), V::Bool(false))]);
    assert_eq!(out(true, Some(11), Some(&bad)), Leave::Unknown);
    // key 7 (provd's 4 s cache) never decides: stale 2 with key 10 absent is still out
    assert_eq!(out(true, Some(11), Some(&info(2, false, Some(false)))), Leave::AlreadyOut);
    assert_eq!(out(true, Some(11), Some(&info(1, true, Some(false)))), Leave::NotLeft);
    assert_eq!(Leave::Left.text(), "[LEFT] 已離開隊伍網路");
}

/// §3: reboot ADVICE appears only in Unfinished and NotLeft; every other outcome is its negative control.
#[test]
fn t1_reboot_advice_only_where_designed() {
    let all = [
        Leave::Left,
        Leave::AlreadyOut,
        Leave::NotSentBusy { out: false },
        Leave::NotSentBusy { out: true },
        Leave::NotSentAuth { out: false },
        Leave::NotSent { code: Some(10), out: false },
        Leave::NotSent { code: None, out: true },
        Leave::BusyMember,
        Leave::BusyChanging,
        Leave::Unfinished,
        Leave::Changing,
        Leave::NotLeft,
        Leave::NotLeftAuth,
        Leave::NotLeftOther(10),
        Leave::Unknown,
    ];
    for l in &all {
        let t = l.text();
        assert_eq!(advises_reboot(&t), matches!(l, Leave::Unfinished | Leave::NotLeft), "{l:?}: {t}");
        assert!(t.starts_with('['), "a log marker first: {t}");
        let not_sent = matches!(l, Leave::NotSentBusy { .. } | Leave::NotSentAuth { .. } | Leave::NotSent { .. });
        if not_sent {
            assert!(!t.contains(STILL_ON), "{t}");
        }
        assert_eq!(t.starts_with("[LEFT] "), matches!(l, Leave::Left | Leave::AlreadyOut), "「已離開」 only on 0 or key 10 absent: {t}");
    }
}

#[test]
fn t3_confirm_text() {
    let (title, body) = flow::leave_confirm("2233", true, true, false);
    assert_eq!(title, "要讓節點 …2233 離開隊伍網路嗎？");
    for want in ["HaLow 無線電會關閉", "可能會斷線", "不會把這台從管理者的成員名單移除", "也不會撤銷任何東西", "#255", "手機裡的網路紀錄不會改變"] {
        assert!(body.contains(want), "{want}");
    }
    assert!(body.ends_with("之後可以按「加入網路／繼續加入」再加入。"));
    assert!(flow::leave_confirm("2233", true, false, true).1.ends_with("之後可以按「加入隊伍網路」再加入。"));
    assert!(flow::leave_confirm("2233", true, false, false).1.ends_with("需要向管理者要新的邀請。"));
    // key 10 unknown: neutral, never a promise
    let b = flow::leave_confirm("2233", false, true, true).1;
    assert!(b.ends_with("讀不到這台目前的網路，無法確認這支手機能不能再加入。") && !b.contains("再加入。之後"), "{b}");
    assert!(!b.contains("可以按"));
}

// ---- S4 cross-doc (254-app-status-page appendix A, leave v4.1 §2) ----------------------------------------------

fn status(k1: u64, code: Option<u64>, plinks: u64) -> V {
    let t = |p: Vec<(&str, V)>| V::Map(p.into_iter().map(|(k, v)| (V::Text(k.into()), v)).collect());
    let mut m = vec![(V::Uint(1), V::Uint(k1)), (V::Uint(2), V::Uint(2))];
    if let Some(c) = code {
        m.push((V::Uint(5), V::Map(vec![(V::Uint(1), V::Uint(c)), (V::Uint(2), V::Text("NOT_JOINED".into()))])));
    }
    let j = t(vec![("snr_db", V::Text("31".into())), ("plinks", V::Uint(plinks))]);
    m.push((V::Uint(15), t(vec![("uptime_s", V::Uint(600)), ("join", j)])));
    V::Map(m)
}

#[test]
fn s4_unfinished_line_and_button() {
    let none = info(2, true, Some(false));
    assert_eq!(sp::unfinished_line(Some(&none)), None);
    assert_eq!(sp::unfinished_line(None), None);
    let (l, under) = sp::unfinished_line(Some(&info(2, true, Some(true)))).unwrap();
    assert!(!under && l.ends_with("超過 10 分鐘仍如此，重新開機一次；仍然如此請找維修人員") && !l.contains("離開網路"), "{l}");
    let (l, under) = sp::unfinished_line(Some(&info(1, false, Some(true)))).unwrap();
    assert!(under && l.contains("可以再按「離開網路」") && l.ends_with("超過 10 分鐘仍如此，重新開機一次；仍然如此請找維修人員"), "{l}");
    // the button: key 10, or k1 = 2, or key 11 true
    assert!(sp::can_leave(Some(1), Some(&info(2, true, Some(false)))));
    assert!(sp::can_leave(Some(2), None));
    assert!(sp::can_leave(Some(1), Some(&info(1, false, Some(true)))), "a leave committed but not finished: press again");
    assert!(!sp::can_leave(Some(1), Some(&info(1, false, Some(false)))));
    assert!(!sp::can_leave(Some(1), None));
}

/// S4 §3 / T1 (A-m1): the reboot property is about the verdict sentence only — key 11 does not change it (row 6 here).
#[test]
fn s4_reboot_property_is_on_the_verdict_sentence() {
    let v = sp::link_verdict_for(Answer::Body(&status(2, Some(8), 0)), JoinButton::Admin);
    assert_eq!(v.row.label(), "6");
    assert!(!v.sentence.contains(REBOOT), "{}", v.sentence);
    // the line that goes with key 11 is separate
    assert!(sp::unfinished_line(Some(&info(2, true, Some(true)))).unwrap().0.contains(REBOOT));
}

/// leave v4.1 §2 (A-m2): leaving cuts EVERY k1 = 1 join sentence at the dash.
#[test]
fn s4_leaving_cuts_every_claimed_join_sentence() {
    let cases = [
        (status(1, None, 1), "已連上附近的節點，但這台還沒加入隊伍網路"), // rows 3 / 4
        (status(1, Some(8), 0), "這台還沒加入隊伍網路"),                   // row 6
        (status(1, Some(7), 0), "這台還沒加入隊伍網路"),                   // row 7
        (status(1, Some(0), 1), "這台還沒加入隊伍網路"),                   // row 8a
        (status(1, Some(9), 1), "這台還沒加入隊伍網路"),                   // row 8
        (status(1, Some(1), 0), "這台還沒加入隊伍網路"),                   // row 9
    ];
    for (st, want) in &cases {
        let cut = sp::link_verdict_for(Answer::Body(st), JoinButton::Leaving).sentence;
        assert_eq!(&cut, want);
        for j in [JoinButton::Admin, JoinButton::Member, JoinButton::NoRecord] {
            let full = sp::link_verdict_for(Answer::Body(st), j).sentence;
            assert!(full.starts_with(want) && full.len() > want.len(), "{j:?}: {full}");
        }
    }
    // not a join sentence: rows 5' / B keep theirs
    let r5 = sp::link_verdict_for(Answer::Body(&status(1, Some(4), 0)), JoinButton::Leaving).sentence;
    assert!(r5.contains("請重新開機"), "{r5}");
    // a member's sentences are not touched
    let m = sp::link_verdict_for(Answer::Body(&status(2, Some(8), 0)), JoinButton::Leaving).sentence;
    assert_eq!(m, sp::link_verdict_for(Answer::Body(&status(2, Some(8), 0)), JoinButton::Admin).sentence);
}
