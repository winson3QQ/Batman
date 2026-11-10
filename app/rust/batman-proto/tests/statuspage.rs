//! The readable status page (docs/design/254-app-status-page.md v8.1 FROZEN §5): T1-T6 over `statuspage`. T7 (the
//! join2 "connected" check reusing the verdict) is in tests/netrec.rs. Each negative control named by the design is a
//! mutant of src/statuspage.rs (scratch runner, results in the commit report); where the design names an OLD sentence,
//! the test also shows that the old sentence fails the same check.

use batman_proto::cbor::{self, Value as V};
use batman_proto::statuspage::{self as sp, Answer, Color, Row};

fn t(pairs: Vec<(&str, V)>) -> V {
    V::Map(pairs.into_iter().map(|(k, v)| (V::Text(k.into()), v)).collect())
}
fn s(x: &str) -> V {
    V::Text(x.into())
}

/// One owner `status` answer, shaped like the node's status.get (status.go:187-224).
#[derive(Clone)]
struct St {
    k1: u64,
    k2: Option<u64>,
    k3: Option<u64>,
    /// Some = key 5 present (not JOINED) with this reason code
    code: Option<u64>,
    plinks: Option<u64>,
    snr: &'static str,
    up: u64,
    throttled: &'static str,
    temp: &'static str,
}

impl St {
    /// a member, JOINED, one plink, good SNR, up 600 s, nothing else wrong
    fn joined() -> St {
        St { k1: 2, k2: Some(0), k3: None, code: None, plinks: Some(1), snr: "31", up: 600, throttled: "0x0", temp: "50" }
    }
    /// a member, not joined with `code`, plinks 0, up 600 s (k2 = 2: CRIT whenever plinks = 0)
    fn code(c: u64) -> St {
        St { code: Some(c), plinks: Some(0), k2: Some(2), ..St::joined() }
    }
    fn k1(mut self, k: u64) -> St {
        self.k1 = k;
        self
    }
    fn up(mut self, u: u64) -> St {
        self.up = u;
        self
    }
    fn plinks(mut self, p: u64) -> St {
        self.plinks = Some(p);
        self
    }
    fn v(&self) -> V {
        let mut m = vec![(V::Uint(1), V::Uint(self.k1))];
        if let Some(x) = self.k2 {
            m.push((V::Uint(2), V::Uint(x)));
        }
        if let Some(x) = self.k3 {
            m.push((V::Uint(3), V::Uint(x)));
        }
        if let Some(c) = self.code {
            m.push((V::Uint(5), V::Map(vec![(V::Uint(1), V::Uint(c)), (V::Uint(2), s("NOT_JOINED SEARCHING"))])));
        }
        let state = if self.code.is_some() { "NOT_JOINED" } else { "JOINED" };
        let mut j = vec![("state", s(state)), ("channel", s("40")), ("country", s("US")), ("snr_db", s(self.snr))];
        if let Some(p) = self.plinks {
            j.push(("plinks", V::Uint(p)));
        }
        let f = t(vec![
            ("node", s("BCM2711-6c89")),
            ("image", s("OpenMANET 1.8.0")),
            ("uptime_s", V::Uint(self.up)),
            ("temp_c", s(self.temp)),
            ("throttled", s(self.throttled)),
            ("age_s", V::Uint(5)),
            ("join", t(j)),
        ]);
        m.push((V::Uint(15), f));
        V::Map(m)
    }
}

fn verdict(x: &St) -> sp::Verdict {
    sp::link_verdict(Answer::Body(&x.v()))
}

const REBOOT: &str = "重新開機";
const COND_REBOOT: &str = "隊員就在旁邊仍然如此，請重新開機一次";
const NAME_CHECK: &str = "網路名稱和隊長的相同";

// ---- T1 -----------------------------------------------------------------------------------------------------------

/// §3 / §5 T1: 「重新開機」 appears iff the row is 2 (stale / undecodable), 5', a member's row 8 with code 1, 9 (a), or
/// a member's 9 (c). Stated over the inputs, independently of the code under test.
fn reboot_expected(row: Row, k1: Option<u64>, code: Option<u64>) -> bool {
    match row {
        Row::Unknown | Row::RadioFault | Row::GuardedNotLinked => true,
        Row::Lost => k1 == Some(2) && code == Some(1),
        Row::NotLinked => k1 != Some(1),
        _ => false,
    }
}

#[test]
fn t1_reboot_appears_exactly_on_its_rows() {
    // (what, answer, expected row): every row of the table, each the others' negative control
    let stale = t(vec![("stale", V::Bool(true))]);
    let stale = V::Map(vec![(V::Uint(1), V::Uint(2)), (V::Uint(15), stale)]);
    let mut table: Vec<(String, V, Option<u64>, Row)> = vec![];
    let mut add = |what: &str, x: St, row: Row| table.push((what.into(), x.v(), x.code, row));
    add("JOINED, snr 31", St::joined(), Row::Linked);
    add("JOINED, snr 12", St { snr: "12", ..St::joined() }, Row::LinkedWeak);
    add("JOINED but plinks 0 (JOINED lags)", St::joined().plinks(0), Row::NotLinked);
    add("code 0, up 30", St::code(0).up(30), Row::Booting);
    add("member code 1, up 30", St::code(1).up(30), Row::Booting);
    add("member code 1, plinks 1, up 30", St::code(1).plinks(1).up(30), Row::Booting);
    add("code 4, up 30", St::code(4).up(30), Row::Booting);
    add("code 7, up 30", St::code(7).up(30), Row::Booting);
    add("code 8, up 30", St::code(8).up(30), Row::Booting);
    add("code 7, up 200", St::code(7).up(200), Row::Booting);
    add("code 3", St::code(3), Row::RadioOff);
    add("code 6", St::code(6), Row::RadioOff);
    add("code 2", St::code(2), Row::NoKey);
    add("code 2, up 30 (no boot grace)", St::code(2).up(30), Row::NoKey);
    add("code 4", St::code(4), Row::RadioFault);
    add("code 5", St::code(5), Row::RadioFault);
    add("k1 1, code 4", St::code(4).k1(1), Row::RadioFault);
    add("code 10", St::code(10), Row::UnknownCode);
    add("code 10, plinks 1", St::code(10).plinks(1), Row::UnknownCode);
    add("code 8", St::code(8), Row::HeardNoLink);
    add("code 8, plinks 1", St::code(8).plinks(1), Row::HeardNoLink);
    add("code 7, up 300", St::code(7).up(300), Row::NothingHeard);
    add("k3 1, plinks 0, code 7", St { k3: Some(1), ..St::code(7) }, Row::NothingHeard);
    add("code 0, plinks 1", St::code(0).plinks(1), Row::Linking);
    add("code 9, plinks 1", St::code(9).plinks(1), Row::Lost);
    add("code 9, plinks 0", St::code(9), Row::Lost);
    add("member code 1, plinks 1", St::code(1).plinks(1), Row::Lost);
    add("claimed code 1, plinks 1", St::code(1).plinks(1).k1(1), Row::Lost);
    add("S20: member code 1, plinks 0", St::code(1), Row::GuardedNotLinked);
    add("claimed code 1, plinks 0", St::code(1).k1(1), Row::NotLinked);
    add("claimed code 1, up 30 (no boot grace)", St::code(1).k1(1).up(30), Row::NotLinked);
    add("code 0, plinks 0", St::code(0), Row::NotLinked);
    add("claimed JOINED", St::joined().k1(1), Row::Linked);
    table.push(("stale".into(), stale, None, Row::Unknown));
    let mut n = 0;
    for (what, v, code, row) in &table {
        let got = sp::link_verdict(Answer::Body(v));
        assert_eq!(got.row, *row, "{what}: row {} != {}", got.row.label(), row.label());
        let k1 = v.get(1).and_then(V::as_uint);
        assert_eq!(got.sentence.contains(REBOOT), reboot_expected(*row, k1, *code), "{what}: {}", got.sentence);
        n += 1;
    }
    for (code, row) in [(6, Row::Unsupported), (3, Row::Refused), (11, Row::Refused), (12, Row::Refused)] {
        let got = sp::link_verdict(Answer::Error(code));
        assert_eq!(got.row, row);
        assert!(!got.sentence.contains(REBOOT), "error {code}: {}", got.sentence);
        n += 1;
    }
    assert!(n >= 37, "the table ran ({n} arms)");
}

#[test]
fn t1_colours() {
    assert_eq!(verdict(&St::joined()).color, Color::Green);
    for x in [St { snr: "12", ..St::joined() }, St::code(7).up(30), St::code(0).plinks(1)] {
        assert_eq!(verdict(&x).color, Color::Yellow, "{:?}", verdict(&x).row);
    }
    for x in [St::code(3), St::code(2), St::code(4), St::code(10), St::code(8), St::code(7), St::code(9).plinks(1), St::code(1), St::code(0)] {
        assert_eq!(verdict(&x).color, Color::Red, "{:?}", verdict(&x).row);
    }
    assert_eq!(sp::link_verdict(Answer::Error(6)).color, Color::Grey);
    assert_eq!(sp::link_verdict(Answer::Error(3)).color, Color::Grey);
    // the colour never comes from key 2 or key 1 (v1-v3 negative controls): CRIT + JOINED is still green, a claimed
    // node's code 7 is still red
    assert_eq!(verdict(&St { k2: Some(2), ..St::joined() }).color, Color::Green);
    assert_eq!(verdict(&St::code(7).k1(1)).color, Color::Red);
    // key 3 (batman neighbours, stale entries included) never makes it green
    assert_eq!(verdict(&St { k3: Some(3), ..St::code(7) }).color, Color::Red);
}

#[test]
fn t1_sentences() {
    // S20 (k1 2, k2 2, plinks 0, code 1, up 600) -> 9 (a): the name check and the conditional reboot, plus the AP line
    let v = verdict(&St::code(1));
    assert!(v.sentence.contains(NAME_CHECK) && v.sentence.contains("看下面「網路：」") && v.sentence.contains(COND_REBOOT), "{}", v.sentence);
    assert_eq!(v.warning, Some(sp::WARN_AP));
    // negative control: v6's 9 (a) sentence (no reboot) fails the same check
    let v6_9a = "還沒連上其他隊員 — 請確認隊員的節點已開機、在附近；等一分鐘再按「重新整理」；找維修";
    assert!(!v6_9a.contains(COND_REBOOT));
    // a member's row 8 with code 1: the conditional reboot; v7's row 8 sentence did not have it
    let v = verdict(&St::code(1).plinks(1));
    assert!(v.sentence.contains(COND_REBOOT) && v.sentence.starts_with("之前連上的隊員現在收不到"), "{}", v.sentence);
    let v7_8 = "之前連上的隊員現在收不到（可能走遠或關機），或還在連線中 — 請確認隊員在附近、已開機；等一分鐘按「重新整理」；找維修";
    assert!(!v7_8.contains(COND_REBOOT));
    // a claimed node's row 8 never gets the member clause
    let v = verdict(&St::code(1).plinks(1).k1(1));
    assert_eq!(v.sentence, "這台還沒加入隊伍網路 — 請按「加入隊伍網路」");
    // code 9 + plinks 1 (unguarded): red, no reboot (joinwatch decides at 1 h)
    let v = verdict(&St::code(9).plinks(1));
    assert!(v.color == Color::Red && !v.sentence.contains(REBOOT), "{}", v.sentence);
    // code 0 + plinks 1: 8a, yellow (v6 put it on row 8, red)
    let v = verdict(&St::code(0).plinks(1));
    assert_eq!((v.row, v.color), (Row::Linking, Color::Yellow));
    assert_eq!(v.sentence, "正在接上網路 — 請等一分鐘再按「重新整理」；一直如此請找維修人員");
    // code 2: the key is not set — no wait, no reboot step (v7's 9 (b) / 9 (c) asked to wait / reboot)
    let v = verdict(&St::code(2));
    assert!(v.sentence.starts_with("這台的網路金鑰沒有設定") && !v.sentence.contains(REBOOT) && !v.sentence.contains("等一分鐘"), "{}", v.sentence);
    for old in ["還沒連上其他隊員 — 請確認隊員的節點已開機、在附近；等一分鐘再按「重新整理」；找維修", "還沒連上其他隊員 — 請確認隊員的節點已開機、在附近；等一分鐘再按「重新整理」，仍然如此請重新開機；找維修"] {
        assert!(!old.starts_with("這台的網路金鑰沒有設定"));
    }
    // JOINED -> row 3: no number on the main screen
    let v = verdict(&St { plinks: Some(3), ..St::joined() });
    assert_eq!(v.sentence, "已連上隊伍網路");
    assert!(!v.sentence.chars().any(|c| c.is_ascii_digit()));
    // code 7: no reboot (a lone node is not a fault); v3's row-8 sentence asked a code 7 node to reboot
    let v = verdict(&St::code(7));
    assert!(!v.sentence.contains(REBOOT) && v.sentence.starts_with("附近沒有收到其他節點的訊號"), "{}", v.sentence);
    // a member's code 8: compare the network name, never "join the team network" (the node refuses: F1)
    let v = verdict(&St::code(8));
    assert!(!v.sentence.contains("加入隊伍網路") && v.sentence.contains("下面「網路：」"), "{}", v.sentence);
    // k1 = 1 wording
    assert_eq!(verdict(&St::code(1).k1(1)).sentence, "這台還沒加入隊伍網路 — 請按「加入隊伍網路」");
    assert_eq!(verdict(&St::joined().k1(1)).sentence, "已連上附近的節點，但這台還沒加入隊伍網路 — 要跟隊伍通訊請按「加入隊伍網路」");
    assert_eq!(verdict(&St::code(4).k1(1)).sentence, verdict(&St::code(4)).sentence, "5' keeps its own sentence");
    assert_eq!(verdict(&St::code(7).k1(1).up(30)).sentence, "剛開機，正在尋找其他節點 — 請等一分鐘再按「重新整理」；還沒加入隊伍網路");
    // U: a code the app does not know
    assert_eq!(verdict(&St::code(10)).sentence, "還沒連上 — 請找維修人員");
    // code 1 is never row 5 (v2 negative control): a claimed node's code 1 is "please join"
    assert_ne!(verdict(&St::code(1).k1(1)).row, Row::RadioOff);
    // lag small print on rows 3 / 4 only
    assert_eq!(verdict(&St::joined()).lag_note, Some(sp::LAG_NOTE));
    assert_eq!(verdict(&St { snr: "", ..St::joined() }).lag_note, Some(sp::LAG_NOTE));
    assert_eq!(verdict(&St::code(9).plinks(1)).lag_note, None);
}

// ---- T2 -----------------------------------------------------------------------------------------------------------

#[test]
fn t2_errors_and_unreadable_answers() {
    assert_eq!(sp::link_verdict(Answer::Error(6)).row, Row::Unsupported);
    assert!(sp::link_verdict(Answer::Error(6)).sentence.contains("設定紀錄讀不到"));
    let joined = St::joined().v();
    let drop_key = |k: u64| match &joined {
        V::Map(m) => V::Map(m.iter().filter(|(x, _)| *x != V::Uint(k)).cloned().collect()),
        _ => unreachable!(),
    };
    let unreadable = vec![
        ("not a map", V::Array(vec![])),
        ("k1 missing", drop_key(1)),
        ("k15 missing", drop_key(15)),
        ("plinks missing", St { plinks: None, ..St::joined() }.v()),
        ("stale", V::Map(vec![(V::Uint(1), V::Uint(2)), (V::Uint(15), t(vec![("stale", V::Bool(true))]))])),
        ("key 5 without a code", V::Map(vec![(V::Uint(1), V::Uint(2)), (V::Uint(5), V::Map(vec![])), (V::Uint(15), t(vec![("join", t(vec![("plinks", V::Uint(0))]))]))])),
    ];
    for (what, v) in &unreadable {
        let got = sp::link_verdict(Answer::Body(v));
        assert_eq!(got.row, Row::Unknown, "{what}");
        assert!(got.sentence.contains(REBOOT), "{what}: a reboot restarts halow-status / joinwatch");
        assert_eq!(got.warning, None, "{what}");
    }
    for code in [3, 11, 12, 4] {
        let got = sp::link_verdict(Answer::Error(code));
        assert_eq!(got.row, Row::Refused, "error {code}");
        assert_eq!(got.sentence, "狀態未知 — 請按「重新整理」；一直如此請找維修人員");
    }
}

// ---- T3 -----------------------------------------------------------------------------------------------------------

#[test]
fn t3_snr_threshold_and_unknown() {
    let at = |snr: &'static str| verdict(&St { snr, ..St::joined() });
    assert_eq!(at("20").row, Row::Linked);
    assert_eq!(at("19").row, Row::LinkedWeak);
    assert_eq!(at("-3").row, Row::LinkedWeak);
    assert_eq!(at("19").sentence, "已連上，但訊號偏弱 — 可以靠近一點或換個位置");
    for unknown in ["", "abc"] {
        let v = at(unknown);
        assert_eq!(v.row, Row::LinkedWeak, "unknown is never good");
        assert_eq!(v.sentence, "已連上（訊號強度讀不到）");
        assert!(!v.sentence.contains("靠近一點"));
    }
    // negative control: v7's row 4 sentence for an unknown SNR told the user to move closer
    assert!("已連上，但訊號偏弱 — 可以靠近一點或換個位置".contains("靠近一點"));
}

// ---- T4 -----------------------------------------------------------------------------------------------------------

#[test]
fn t4_version_and_warning_line() {
    let info = V::Map(vec![(V::Uint(4), s("1.5.14-wsl.24"))]);
    assert_eq!(sp::version_line(Some(&info)), "1.5.14-wsl.24", "info key 4, never key 15 image");
    assert_eq!(sp::version_line(Some(&V::Map(vec![]))), "");
    assert_eq!(sp::version_line(None), "");
    let w = |x: St| verdict(&x).warning;
    let ok = St::joined();
    assert_eq!(w(St { throttled: "0x50005", ..ok.clone() }), Some(sp::WARN_POWER));
    assert_eq!(w(St { throttled: "0x50000", ..ok.clone() }), None);
    assert_eq!(w(St { throttled: "xyz", ..ok.clone() }), None);
    assert_eq!(w(St { temp: "79", ..ok.clone() }), None);
    assert_eq!(w(St { temp: "80", ..ok.clone() }), Some(sp::WARN_HOT));
    assert_eq!(w(St { temp: "", ..ok.clone() }), None);
    assert_eq!(w(St { temp: "80", throttled: "0x1", ..ok.clone() }), Some(sp::WARN_POWER), "the first line that holds");
    // JOINED + plinks 1 + k2 2 -> the neutral sentence (a legacy member's AP may be set)
    let neutral = w(St { k2: Some(2), ..ok.clone() }).unwrap();
    assert_eq!(neutral, "節點回報異常（可能是手機 Wi-Fi 還沒設定）— 設好仍然如此請找維修人員");
    assert_ne!(neutral, "這台給手機連的 Wi-Fi 可能還沒設定 — 可在「手機 Wi-Fi」設定；設好仍然如此請找維修人員", "v6's JOINED sentence");
    assert_eq!(w(St { k2: Some(2), ..ok.clone() }.plinks(0)), None, "JOINED with plinks 0: CRIT is the normal state");
    // a member's code 1 -> the AP line, which says setting it reveals the real cause
    let ap = w(St::code(1)).unwrap();
    assert!(ap.contains("設好後這頁才看得到連不上的真正原因") && ap.contains("「手機 Wi-Fi」"), "{ap}");
    for old in [
        "這台節點回報有其他問題，手機可能連不上它的 Wi-Fi — 請找維修人員（技術資訊有細節）",
        "這台給手機連的 Wi-Fi 還沒設定（或被關閉）— 可在「手機 Wi-Fi」設定；設好仍然如此請找維修人員",
    ] {
        assert!(!old.contains("設好後這頁才看得到連不上的真正原因"), "v5 / v6 sentence");
    }
    assert_eq!(w(St::code(1).k1(1)), None, "a claimed node's code 1 is normal (F6b)");
    for c in [7, 8] {
        for u in [30, 600] {
            assert_eq!(w(St::code(c).up(u)), None, "not joined: k2 = 2 is normal (code {c}, up {u})");
        }
    }
    assert_eq!(w(St { k2: Some(1), ..ok }), None);
}

#[test]
fn t4_membership_line() {
    assert_eq!(sp::membership_line(Some(2), true, Some("家裡網路")), "網路：家裡網路（已是成員）");
    assert_eq!(sp::membership_line(Some(2), true, None), "網路：別支手機建立的網路");
    assert_eq!(sp::membership_line(Some(2), false, None), "網路：（讀不到名稱）");
    assert_eq!(sp::membership_line(Some(1), false, None), "已認領，還沒加入網路");
    for k in [None, Some(0), Some(3)] {
        assert_eq!(sp::membership_line(k, true, Some("x")), "", "{k:?}: no line");
    }
}

// ---- T5 -----------------------------------------------------------------------------------------------------------

/// status.get (status.go:187-224, full = true) over a `halow-status json` document; no p5 (key 4), no uci_staged.
fn status_get(js: &serde_json::Value, state: u64) -> V {
    let st = |p: &str| js.pointer(p).and_then(|x| x.as_str()).unwrap_or("").to_string();
    let mut m = vec![(V::Uint(1), V::Uint(state))];
    if let Some(l) = match js.pointer("/health/level").and_then(|x| x.as_str()) {
        Some("OK") => Some(0),
        Some("WARN") => Some(1),
        Some("CRIT") => Some(2),
        _ => None,
    } {
        m.push((V::Uint(2), V::Uint(l)));
    }
    if let Some(n) = js.pointer("/join/batman_neighbours").and_then(|x| x.as_u64()) {
        m.push((V::Uint(3), V::Uint(n)));
    }
    if st("/join/state") != "JOINED" {
        let rc = js.pointer("/join/reason_code").and_then(|x| x.as_u64()).unwrap_or(0);
        m.push((V::Uint(5), V::Map(vec![(V::Uint(1), V::Uint(rc)), (V::Uint(2), V::Text(format!("{} {}", st("/join/state"), st("/join/detail")).trim().into()))])));
    }
    let mut j = vec![("state", s(&st("/join/state"))), ("channel", s(&st("/join/channel"))), ("country", s(&st("/join/country"))), ("snr_db", s(&st("/join/snr_db")))];
    if let Some(p) = js.pointer("/join/plinks").and_then(|x| x.as_u64()) {
        j.push(("plinks", V::Uint(p)));
    }
    let f = t(vec![
        ("node", s(&st("/node"))),
        ("image", s(&st("/image"))),
        ("uptime_s", V::Uint(js.pointer("/uptime_s").and_then(|x| x.as_u64()).unwrap())),
        ("last_boot_reason", s(&st("/last_boot_reason"))),
        ("last_ota", s(&st("/last_ota"))),
        ("temp_c", s(&st("/temp_c"))),
        ("throttled", s(&st("/throttled"))),
        ("tenants", s(&st("/tenants"))),
        ("age_s", V::Uint(4)),
        ("join", t(j)),
    ]);
    m.push((V::Uint(15), f));
    V::Map(m)
}

#[test]
fn t5_real_status_of_04() {
    // tests/testdata/halow-status-04-wsl22.json: copied verbatim from Batman-p3 e5c89a1
    // feed/batman-prov/src/node/testdata/halow-status-04-wsl22.json (04 on wsl.22: JOINED, the only CRIT is keyguard on
    // the phone AP)
    let raw = include_str!("testdata/halow-status-04-wsl22.json");
    let js: serde_json::Value = serde_json::from_str(raw).unwrap();
    let v = status_get(&js, 2);
    // through the wire encoding, as the bridge sees it
    let v = cbor::decode(&cbor::encode(&v)).unwrap();
    let got = sp::link_verdict(Answer::Body(&v));
    assert_eq!((got.row, got.color), (Row::Linked, Color::Green), "JOINED, plinks 1, SNR 49");
    assert_eq!(got.warning, Some(sp::WARN_JOINED_CRIT), "CRIT from keyguard while joined: the neutral line");
    assert_eq!(got.lag_note, Some(sp::LAG_NOTE));
    let tech = sp::tech_lines(Answer::Body(&v));
    for want in ["健康等級（key 2）：2（CRIT）", "batman 鄰居數（key 3，含過期）：1", "上游映像（image）：OpenMANET 1.8.0", "SNR：49 dB", "直接連到的站台數 P（plinks）：1", "頻道：40", "國家：US", "開機時間（uptime_s）：6 分 42 秒", "溫度（temp_c）：56", "throttled：0x0"] {
        assert!(tech.iter().any(|l| l == want), "{want} in {tech:?}");
    }
    assert!(!tech.iter().any(|l| l.starts_with("未入網代碼")), "JOINED: no key 5");
    assert!(!got.sentence.contains("OpenMANET"), "the main screen never shows image");
}

// ---- T6 -----------------------------------------------------------------------------------------------------------

#[test]
fn t6_node_strings_are_filtered_and_cut() {
    let evil = format!("a\u{202E}b\nc{}", "龘".repeat(80));
    let info = V::Map(vec![(V::Uint(4), V::Text(evil.clone()))]);
    let ver = sp::version_line(Some(&info));
    let ok = |x: &str| !x.contains('\u{202E}') && !x.contains('\n') && x.chars().count() <= sp::NODE_TEXT_MAX;
    assert!(ok(&ver) && ver.chars().count() == sp::NODE_TEXT_MAX, "{ver}");
    let name = sp::membership_line(Some(2), true, Some(&evil));
    assert!(!name.contains('\u{202E}') && !name.contains('\n'), "{name}");
    let mut x = St::code(7).v();
    let V::Map(m) = &mut x else { unreachable!() };
    for (k, v) in m.iter_mut() {
        if *k == V::Uint(5) {
            *v = V::Map(vec![(V::Uint(1), V::Uint(7)), (V::Uint(2), V::Text(evil.clone()))]);
        }
        if *k == V::Uint(15) {
            let V::Map(f) = v else { unreachable!() };
            for (fk, fv) in f.iter_mut() {
                if matches!(fk, V::Text(t) if t == "image" || t == "temp_c" || t == "throttled") {
                    *fv = V::Text(evil.clone());
                }
            }
            f.push((V::Text("uci_staged".into()), V::Array(vec![V::Text(evil.clone()), V::Text(format!("\u{202E}{evil}"))])));
            f.push((V::Text("settings_restore".into()), V::Text(evil.clone())));
        }
    }
    let tech = sp::tech_lines(Answer::Body(&x));
    let staged: Vec<_> = tech.iter().filter(|l| l.starts_with("未套用的設定")).collect();
    assert_eq!(staged.len(), 2, "every uci_staged item");
    for l in &tech {
        assert!(!l.contains('\u{202E}') && !l.contains('\n'), "{l:?}");
        // each node string is cut to 64 characters: no line holds 65 of the repeated character
        assert!(!l.contains(&"龘".repeat(sp::NODE_TEXT_MAX)), "{l:?}");
    }
    let v = sp::link_verdict(Answer::Body(&x));
    assert!(!v.sentence.contains('\u{202E}') && !v.sentence.contains("龘"), "no node string in the sentence");
}

/// S20 fix 1: a claimed node's sentence names the join button this phone really has.
#[test]
fn claimed_wording_names_this_phones_button() {
    use sp::JoinButton as J;
    let s = |x: &St, j| sp::link_verdict_for(Answer::Body(&x.v()), j).sentence;
    let claimed = St::code(1).k1(1);
    let joined = St::joined().k1(1);
    assert_eq!(s(&claimed, J::Admin), "這台還沒加入隊伍網路 — 請按「加入網路／繼續加入」", "the admin phone");
    assert_eq!(s(&joined, J::Admin), "已連上附近的節點，但這台還沒加入隊伍網路 — 要跟隊伍通訊請按「加入網路／繼續加入」");
    assert_eq!(s(&claimed, J::Member), "這台還沒加入隊伍網路 — 請按「加入隊伍網路」", "the member phone");
    assert_eq!(s(&joined, J::Member), "已連上附近的節點，但這台還沒加入隊伍網路 — 要跟隊伍通訊請按「加入隊伍網路」");
    assert_eq!(s(&claimed, J::NoRecord), "這台還沒加入隊伍網路 — 這支手機還沒有隊伍網路：可按「建立網路」，或向管理者要邀請");
    assert!(!s(&claimed, J::Admin).contains("「加入隊伍網路」"), "never the member's button on the admin phone");
    // net/ wins: a phone that made a network shows the admin button
    assert_eq!(J::of(true, true), J::Admin);
    assert_eq!(J::of(false, true), J::Member);
    assert_eq!(J::of(false, false), J::NoRecord);
    // a member (k1 = 2) never gets a join sentence, whatever the phone holds
    for j in [J::Admin, J::Member, J::NoRecord] {
        assert!(!s(&St::code(8), j).contains("請按「加入"), "{j:?}");
    }
}

#[test]
fn tech_lines_list_every_field() {
    let mut x = St::code(7).v();
    let V::Map(m) = &mut x else { unreachable!() };
    let (_, f) = m.iter_mut().find(|(k, _)| *k == V::Uint(15)).unwrap();
    let V::Map(f) = f else { unreachable!() };
    f.push((V::Text("ssid_unsaved".into()), V::Bool(true)));
    f.push((V::Text("uci_staged".into()), V::Array(vec![V::Text("wireless".into())])));
    f.push((V::Text("settings_restore".into()), V::Text("not verified".into())));
    let tech = sp::tech_lines(Answer::Body(&x));
    for want in ["未入網代碼（key 5）：7 NOT_JOINED SEARCHING", "資料年齡（age_s）：5 秒", "手機 Wi-Fi 名稱尚未存檔（ssid_unsaved）", "未套用的設定（uci_staged）：wireless", "設定還原（settings_restore）：not verified"] {
        assert!(tech.iter().any(|l| l == want), "{want} in {tech:?}");
    }
    for n in sp::TECH_NOTES {
        assert!(tech.iter().any(|l| l == n));
        // S20 fix 2: no design-internal row ids on the screen
        assert!(!n.contains("列 ") && !n.contains("row "), "{n}");
    }
    assert!(sp::TECH_NOTES[2].ends_with("判定可能停在 🟢 或「之前連上的隊員現在收不到」"));
    assert_eq!(sp::tech_lines(Answer::Error(12))[0], "錯誤碼：12");
}

/// code review B-m2: a node string the node sent as "" is 「（讀不到）」, never a bare label like 「SNR： dB」.
#[test]
fn tech_lines_say_unread_for_empty_node_strings() {
    let x = St { snr: "", temp: "", throttled: "", ..St::joined() }.v();
    let mut x = x;
    let V::Map(m) = &mut x else { unreachable!() };
    let (_, f) = m.iter_mut().find(|(k, _)| *k == V::Uint(15)).unwrap();
    let V::Map(f) = f else { unreachable!() };
    for (k, v) in f.iter_mut() {
        if *k == V::Text("join".into()) {
            *v = t(vec![("state", s("JOINED")), ("channel", s("")), ("country", s(" ")), ("snr_db", s("")), ("plinks", V::Uint(1))]);
        }
    }
    let tech = sp::tech_lines(Answer::Body(&x));
    for want in ["SNR：（讀不到）", "頻道：（讀不到）", "國家：（讀不到）", "溫度（temp_c）：（讀不到）", "throttled：（讀不到）"] {
        assert!(tech.iter().any(|l| l == want), "{want} in {tech:?}");
    }
    for l in &tech {
        assert!(!l.ends_with('：') && !l.contains("： ") && !l.contains("SNR： dB"), "a bare label: {l:?}");
    }
    // a value that is there is shown as is
    let tech = sp::tech_lines(Answer::Body(&St::joined().v()));
    assert!(tech.iter().any(|l| l == "SNR：31 dB") && tech.iter().any(|l| l == "頻道：40"), "{tech:?}");
}
