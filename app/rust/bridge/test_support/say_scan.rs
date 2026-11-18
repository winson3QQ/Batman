//! #329 PR 6 D7a (1): the technical parts of this crate's sentences are wrapped in U+001E … U+001F (a scan of every
//! string literal under src/), and the shared split vectors. Included by src/lib.rs (the crate is not an rlib, so this
//! is not an integration test).
use crate::say_scan::{split_code, split_vectors, violations, Allow};

/// Literals the D7a (1) rule would flag that are right as they are, by category.
const ALLOW: &[Allow] = &[
    // user values inside parentheses, kept in the main part (plan D7: identity fingerprint, last four, country, MHz, a
    // limit, a version, a name the user checks)
    Allow { file: "api/member.rs", has: "名稱太長（最多 {} 個位元組）", why: "user value (limit)" },
    Allow { file: "api/member.rs", has: "{}（{}）", why: "identity: name + fingerprint" },
    Allow { file: "api/member.rs", has: "這台節點（…{}）之前被排除", why: "last four" },
    Allow { file: "api/member.rs", has: "舊紀錄（v{stored}）", why: "user value (record version)" },
    Allow { file: "api/member.rs", has: "申請（名稱「{name}」）", why: "user value (request name)" },
    Allow { file: "api/owner.rs", has: "申請（名稱「{name}」）", why: "user value (request name)" },
    Allow { file: "api/owner.rs", has: "（原本是 {}）", why: "country (through display_name)" },
    Allow { file: "api/owner.rs", has: "（這個網路用 {}）", why: "country (through display_name)" },
    Allow { file: "api/owner.rs", has: "（{} MHz）", why: "MHz" },
    Allow { file: "api/owner.rs", has: "（{c} MHz）", why: "MHz" },
    Allow { file: "api/rekey.rs", has: "要把〈{name}〉（{}）", why: "identity: name + fingerprint" },
    Allow { file: "api/rekey.rs", has: "{}（{}）", why: "identity: name + fingerprint" },
    Allow { file: "api/rekey.rs", has: "你這台節點（…{l}）", why: "last four" },
    Allow { file: "api/rekey.rs", has: "這台（…{last4}）", why: "last four" },
    Allow { file: "api/replay.rs", has: "（節點 …{}）", why: "last four" },
    // a fragment only ever inserted into a technical part (I MINOR-2 (c)): owner.rs join2_text SettingsError, error_text
    Allow { file: "api/owner.rs", has: "，原因 {r}", why: "fragment of a technical part" },
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

/// D7a (2) / T6-6 (D8): the English internal words of F6 / E-M1 are in the technical part only.
#[test]
fn d7a_2_member_invite_err() {
    use crate::api::member::invite_err;
    use crate::say_scan::assert_split;
    use batman_proto::invite::Error;
    assert_split(&invite_err(&Error::Invalid("record netcfg")), &["invalid: record netcfg"]);
    assert_split(&invite_err(&Error::NodeCert(batman_proto::nodecert::Error::NotPinned)), &["NotPinned"]);
    assert_split(&invite_err(&Error::Broken("lost".into())), &["lost"]);
    assert!(split_code(&invite_err(&Error::Invalid("x"))).0.contains("內容驗證沒有通過"));
}

#[test]
fn d7a_2_claim_qr_and_link_errors() {
    use crate::api::claim::{frame_limit, parse_claim_qr};
    use crate::say_scan::assert_split;
    for bad in ["zz", "a0", "f6"] {
        let e = parse_claim_qr(bad.into()).err().expect(bad);
        assert!(crate::say_scan::main_ascii_words(&e).is_empty(), "{bad}: {e}");
    }
    assert_split(&parse_claim_qr("a0".into()).err().unwrap(), &[]);
    assert_split(&parse_claim_qr("f6".into()).err().unwrap(), &["not a map"]);
    assert_split(&frame_limit(vec![0xa0], 100).err().unwrap(), &["CTRL key 3 missing"]);
    assert_split(&frame_limit(vec![0xa1, 0x03, 0x05], 100).err().unwrap(), &["CTRL 5", "MTU 100"]);
}

/// T-C4c: replay.rs:133 (F5 / G-M1): the code and the node's verb are technical; the words stay in the main part.
#[test]
fn d7a_2_replay_neutral() {
    use crate::api::replay::{replay_next, Res};
    use crate::say_scan::assert_split;
    use batman_proto::cbor::Value;
    use batman_proto::envelope::Outcome;
    use batman_proto::replayflow::End;
    let end = End::Refused { verb: "claim/replay", outcome: Outcome::Err { code: 3, detail: Value::Map(vec![]) } };
    let (_, t) = replay_next(&Res::End { written: true, end: &end });
    assert_split(&t, &["claim/replay，代碼 3"]);
    assert_eq!(split_code(&t).0, "節點沒有接受這次恢復，已停止；紀錄先保留");
    let end = End::Refused { verb: "claim/replay", outcome: Outcome::Ok(Value::Map(vec![])) };
    let (_, t) = replay_next(&Res::End { written: true, end: &end });
    assert_split(&t, &["claim/replay"]);
}
