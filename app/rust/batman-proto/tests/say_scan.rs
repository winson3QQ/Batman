//! #329 PR 6 D7a: the technical parts of this crate's sentences are wrapped in U+001E … U+001F.
//! (1) a scan of every string literal under src/; (2) the sentence functions' main parts; the shared split vectors.
#[path = "support/say_scan.rs"]
mod say_scan;
use say_scan::{assert_split, split_code, split_vectors, violations, Allow};

/// Literals the D7a (1) rule would flag that are right as they are, by category.
const ALLOW: &[Allow] = &[
    // technical fields only (swupd `Screen.tech`, statuspage `tech_lines`): the whole value is already technical
    Allow { file: "swupd.rs", has: "status：代碼 {code}", why: "Screen.tech" },
    Allow { file: "swupd.rs", has: "原因 {r}", why: "Screen.tech" },
    Allow { file: "swupd.rs", has: "原因 {x}", why: "Screen.tech" },
    Allow { file: "swupd.rs", has: "原因 15", why: "Screen.tech" },
    Allow { file: "swupd.rs", has: "原因 16", why: "Screen.tech" },
    Allow { file: "swupd.rs", has: "代碼 10", why: "Screen.tech" },
    Allow { file: "swupd.rs", has: "代碼 {code}", why: "Screen.tech (fn tech)" },
    Allow { file: "statuspage.rs", has: "健康等級（key 2）", why: "StatusView.tech (tech_lines)" },
    Allow { file: "statuspage.rs", has: "未入網代碼（key 5）", why: "StatusView.tech (tech_lines)" },
    // status::decode_owner: no longer on a screen (the status page replaced it; only the old answer text)
    Allow { file: "status.rs", has: "網路狀況代碼 {n}", why: "decode_owner, not on screen" },
    Allow { file: "status.rs", has: "還沒連上網路（代碼 {c}：{t}）", why: "decode_owner, not on screen" },
    Allow { file: "status.rs", has: "還沒連上網路（代碼 7：SEARCHING）", why: "decode_owner test" },
    // user information inside parentheses, kept in the main part: a link speed
    Allow { file: "teamview.rs", has: "Mbit/s）", why: "user value (link speed)" },
    // a name the user checks, kept in the main part (the reporting node's name, through display_name)
    Allow { file: "teamview.rs", has: "由『{title_name}』看到", why: "user value (node name)" },
];

#[test]
fn d7a_1_every_code_literal_is_wrapped() {
    let bad = violations(ALLOW);
    assert!(bad.is_empty(), "D7a (1): {} literal(s):\n{}", bad.len(), bad.join("\n"));
}

#[test]
fn d7_split_code_shared_vectors() {
    for (input, main, tech) in split_vectors() {
        assert_eq!(split_code(&input), (main.clone(), tech.clone()), "{input:?}");
    }
}

/// D7a (2) / T-C4c: flow.rs `Leave::text` (F5: 代碼 inside and after the parentheses): the main part keeps the useful
/// Chinese and the next step, the code is in the technical part.
#[test]
fn d7a_2_leave_text() {
    use batman_proto::flow::Leave;
    for out in [false, true] {
        let t = Leave::NotSentAuth { out }.text();
        assert_split(&t, &["代碼 3"]);
        assert!(split_code(&t).0.contains("這支手機的權限或連線有問題") && split_code(&t).0.contains("請重新連線"), "{t}");
        assert_eq!(split_code(&t).0.contains("不在隊伍網路裡"), out, "{t}");
        let t = Leave::NotSent { code: Some(12), out }.text();
        assert_split(&t, &["代碼 12"]);
        assert!(split_code(&t).0.contains("請再按一次"), "{t}");
    }
    for (l, c) in [(Leave::NotLeft, "代碼 11"), (Leave::NotLeftAuth, "代碼 3"), (Leave::NotLeftOther(9), "代碼 9")] {
        let t = l.text();
        assert_split(&t, &[c]);
        let m = split_code(&t).0;
        assert!(m.contains("節點仍在隊伍網路裡") && m.contains("請再按一次"), "{t}");
    }
}
