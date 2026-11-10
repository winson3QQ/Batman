//! The readable status page (docs/design/254-app-status-page.md v8.1 FROZEN, §2-§3): what ONE `status` answer of an
//! owner session means for a non-technical user — a colour, one sentence with what to do, a ⚠️ line, the membership and
//! version lines and the collapsed technical list. Pure functions; nothing here is a secret (the status answer carries
//! none) and every string the node sent is passed through `shown` (display_name + 64 characters) before display.
//!
//! The verdict rows are the design's §3 table, first match from the top; the row names keep the design's numbers in
//! their doc comments. `flow::link_state` (join2 v7.2 §3.3-7) reuses the same verdict.

use crate::cbor::Value;
use crate::invite::display_name;
use crate::status::duration_zh;

/// §2: every node string is cut to this many characters (after display_name)
pub const NODE_TEXT_MAX: usize = 64;
/// §3 row B: "just booted" below this uptime (the 202 JOINED budget, provisional)
pub const BOOT_GRACE_S: u64 = 240;
/// §3 row 3: SNR at or above this is good (provisional)
pub const SNR_GOOD_DB: i64 = 20;
/// §2: temp_c at or above this is "hot"
pub const TEMP_HOT_C: f64 = 80.0;
const E_UNSUPPORTED: u64 = 6;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Color {
    Grey,
    Green,
    Yellow,
    Red,
}

impl Color {
    pub fn name(self) -> &'static str {
        match self {
            Color::Grey => "grey",
            Color::Green => "green",
            Color::Yellow => "yellow",
            Color::Red => "red",
        }
    }
}

/// The §3 rows.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Row {
    /// 1: E_UNSUPPORTED
    Unsupported,
    /// 2: stale, undecodable, k1 / k15 / plinks missing
    Unknown,
    /// 2': any other error code
    Refused,
    /// 3: joined, plinks ≥ 1, snr ≥ 20
    Linked,
    /// 4: joined, plinks ≥ 1, snr < 20 or unknown
    LinkedWeak,
    /// B: just booted
    Booting,
    /// 5: codes 3 / 6
    RadioOff,
    /// 5″: code 2
    NoKey,
    /// 5': codes 4 / 5
    RadioFault,
    /// U: a code above 9
    UnknownCode,
    /// 6: code 8
    HeardNoLink,
    /// 7: code 7
    NothingHeard,
    /// 8a: code 0 with plinks ≥ 1
    Linking,
    /// 8: code 9, or plinks ≥ 1
    Lost,
    /// 9 (a): a member with code 1 (phone Wi-Fi unset)
    GuardedNotLinked,
    /// 9 (c): everything else
    NotLinked,
}

impl Row {
    /// the design's row label (for logs and tests)
    pub fn label(self) -> &'static str {
        match self {
            Row::Unsupported => "1",
            Row::Unknown => "2",
            Row::Refused => "2'",
            Row::Linked => "3",
            Row::LinkedWeak => "4",
            Row::Booting => "B",
            Row::RadioOff => "5",
            Row::NoKey => "5\u{2033}",
            Row::RadioFault => "5'",
            Row::UnknownCode => "U",
            Row::HeardNoLink => "6",
            Row::NothingHeard => "7",
            Row::Linking => "8a",
            Row::Lost => "8",
            Row::GuardedNotLinked => "9a",
            Row::NotLinked => "9c",
        }
    }
}

/// One `status` result: the answer body, or the protocol error code it was refused with.
#[derive(Debug, Clone, Copy)]
pub enum Answer<'a> {
    Body(&'a Value),
    Error(u64),
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Verdict {
    pub row: Row,
    pub color: Color,
    pub sentence: String,
    /// §2-1: rows 3 / 4 carry the lag small print
    pub lag_note: Option<&'static str>,
    /// §2-2: the first ⚠️ line that holds
    pub warning: Option<&'static str>,
}

pub const LAG_NOTE: &str = "隊員剛離開或關機時，這裡最多約 4 分鐘後才會改變";
pub const WARN_POWER: &str = "電源電壓不足 — 請檢查電池／電源線";
pub const WARN_HOT: &str = "節點過熱 — 請移到陰涼處";
pub const WARN_AP: &str = "這台給手機連的 Wi-Fi 還沒設定（或被關閉）— 可在「手機 Wi-Fi」設定，設好後這頁才看得到連不上的真正原因；設好仍然如此請找維修人員";
pub const WARN_JOINED_CRIT: &str = "節點回報異常（可能是手機 Wi-Fi 還沒設定）— 設好仍然如此請找維修人員";

const S1: &str = "這台節點看不到連線狀態（軟體太舊，或節點的設定紀錄讀不到）— 請找維修人員";
const S2: &str = "狀態未知 — 請按「重新整理」；一直如此請重新開機或找維修人員";
const S2P: &str = "狀態未知 — 請按「重新整理」；一直如此請找維修人員";
const S3: &str = "已連上隊伍網路";
const S4_WEAK: &str = "已連上，但訊號偏弱 — 可以靠近一點或換個位置";
const S4_UNKNOWN: &str = "已連上（訊號強度讀不到）";
const SB: &str = "剛開機，正在尋找其他節點 — 請等一分鐘再按「重新整理」";
const S5: &str = "這台的無線電設定被關掉了 — 請找維修人員";
const S5K: &str = "這台的網路金鑰沒有設定 — 請找維修人員（等待或重開機都沒用）";
const S5R: &str = "這台的無線電沒有正常運作 — 請重新開機；仍然如此請找維修人員";
const SU: &str = "還沒連上 — 請找維修人員";
const S6: &str = "有收到其他節點，但連不上 — 請對照下面「網路：」的名稱是否和隊長的相同；不同或仍然如此請找維修人員";
const S7: &str = "附近沒有收到其他節點的訊號 — 請確認隊員的節點已開機、在附近、網路名稱和隊長的相同；仍然如此請找維修人員";
const S8A: &str = "正在接上網路 — 請等一分鐘再按「重新整理」；一直如此請找維修人員";
const S8: &str = "之前連上的隊員現在收不到（可能走遠或關機），或還在連線中 — 請確認隊員在附近、已開機；等一分鐘按「重新整理」；仍然如此請找維修人員";
const S8_GUARDED: &str = "之前連上的隊員現在收不到（可能走遠或關機），或還在連線中 — 請確認隊員在附近、已開機；等一分鐘按「重新整理」；隊員就在旁邊仍然如此，請重新開機一次；仍然如此請找維修人員";
const S9A: &str = "還沒連上其他隊員 — 請確認隊員的節點已開機、在附近、網路名稱和隊長的相同（看下面「網路：」）；隊員就在旁邊仍然如此，請重新開機一次；仍然如此請找維修人員";
const S9C: &str = "還沒連上其他隊員 — 請確認隊員的節點已開機、在附近；等一分鐘再按「重新整理」，仍然如此請重新開機；仍然如此請找維修人員";
// k1 = 1 (claimed, not in the team network; legacy too): the action names the button this phone has (S20 fix 1)
const C34_HEAD: &str = "已連上附近的節點，但這台還沒加入隊伍網路 — ";
const C_JOIN_HEAD: &str = "這台還沒加入隊伍網路 — ";
const NO_RECORD: &str = "這支手機還沒有隊伍網路：可按「建立網路」，或向管理者要邀請";

/// Which "join" button this phone shows (My nodes): the k1 = 1 sentences name it.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum JoinButton {
    /// this phone holds a net/ record (it made a network): 「加入網路／繼續加入」
    Admin,
    /// only mnet/ records (an imported team network): 「加入隊伍網路」
    Member,
    /// neither
    NoRecord,
}

impl JoinButton {
    /// net/ wins over mnet/ (the admin's own button)
    pub fn of(has_net: bool, has_mnet: bool) -> JoinButton {
        match (has_net, has_mnet) {
            (true, _) => JoinButton::Admin,
            (false, true) => JoinButton::Member,
            (false, false) => JoinButton::NoRecord,
        }
    }

    fn tail(self, c34: bool) -> String {
        match self {
            JoinButton::Admin if c34 => "要跟隊伍通訊請按「加入網路／繼續加入」".into(),
            JoinButton::Admin => "請按「加入網路／繼續加入」".into(),
            JoinButton::Member if c34 => "要跟隊伍通訊請按「加入隊伍網路」".into(),
            JoinButton::Member => "請按「加入隊伍網路」".into(),
            JoinButton::NoRecord => NO_RECORD.into(),
        }
    }
}
const C_B_TAIL: &str = "；還沒加入隊伍網路";

/// A node string for the screen: control / format characters replaced (display_name), then at most 64 characters.
pub fn shown(s: &str) -> String {
    display_name(s).chars().take(NODE_TEXT_MAX).collect()
}

/// The technical list's value for a node string: `shown`, or 「（讀不到）」 when the node sent "" (code review B-m2).
pub const UNREAD: &str = "（讀不到）";
fn value(s: &str) -> String {
    if s.trim().is_empty() {
        UNREAD.into()
    } else {
        shown(s)
    }
}

fn text_key<'a>(m: &'a Value, k: &str) -> Option<&'a Value> {
    match m {
        Value::Map(e) => e.iter().find(|(key, _)| matches!(key, Value::Text(t) if t == k)).map(|(_, v)| v),
        _ => None,
    }
}

fn text_of<'a>(m: &'a Value, k: &str) -> Option<&'a str> {
    text_key(m, k).and_then(Value::as_text)
}

/// The fields the verdict reads; None = row 2 (stale, undecodable, k1 / k15 / plinks missing, key 5 malformed).
struct Parsed<'a> {
    k1: u64,
    k2: Option<u64>,
    /// Some iff key 5 is present (the node is not JOINED): its reason code
    code: Option<u64>,
    plinks: u64,
    snr: Option<i64>,
    up: Option<u64>,
    f: &'a Value,
}

fn parse(v: &Value) -> Option<Parsed<'_>> {
    let Value::Map(_) = v else { return None };
    let k1 = v.get(1)?.as_uint()?;
    let f = v.get(15)?;
    let Value::Map(_) = f else { return None };
    if text_key(f, "stale") == Some(&Value::Bool(true)) {
        return None;
    }
    let join = text_key(f, "join")?;
    let plinks = text_key(join, "plinks")?.as_uint()?;
    let code = match v.get(5) {
        None => None,
        Some(j) => Some(j.get(1)?.as_uint()?),
    };
    let snr = text_of(join, "snr_db").and_then(|s| s.trim().parse::<i64>().ok());
    let up = text_key(f, "uptime_s").and_then(Value::as_uint);
    Some(Parsed { k1, k2: v.get(2).and_then(Value::as_uint), code, plinks, snr, up, f })
}

fn row_of(p: &Parsed) -> Row {
    let member_guarded = p.k1 == 2 && p.code == Some(1);
    let Some(c) = p.code else {
        return match (p.plinks >= 1, p.snr) {
            (true, Some(s)) if s >= SNR_GOOD_DB => Row::Linked,
            (true, _) => Row::LinkedWeak,
            // JOINED but no plink in this sample (JOINED lags)
            (false, _) => Row::NotLinked,
        };
    };
    if p.up.is_some_and(|u| u < BOOT_GRACE_S) && (matches!(c, 0 | 4 | 5 | 7 | 8 | 9) || member_guarded) {
        return Row::Booting;
    }
    match c {
        3 | 6 => Row::RadioOff,
        2 => Row::NoKey,
        4 | 5 => Row::RadioFault,
        c if c > 9 => Row::UnknownCode,
        8 => Row::HeardNoLink,
        7 => Row::NothingHeard,
        0 if p.plinks >= 1 => Row::Linking,
        c if c == 9 || p.plinks >= 1 => Row::Lost,
        _ if member_guarded => Row::GuardedNotLinked,
        _ => Row::NotLinked,
    }
}

fn color_of(r: Row) -> Color {
    match r {
        Row::Unsupported | Row::Unknown | Row::Refused => Color::Grey,
        Row::Linked => Color::Green,
        Row::LinkedWeak | Row::Booting | Row::Linking => Color::Yellow,
        _ => Color::Red,
    }
}

fn sentence(r: Row, p: Option<&Parsed>, join: JoinButton) -> String {
    let claimed = p.is_some_and(|p| p.k1 == 1);
    let guarded = p.is_some_and(|p| p.k1 == 2 && p.code == Some(1));
    let s = match r {
        Row::Unsupported => S1,
        Row::Unknown => S2,
        Row::Refused => S2P,
        Row::Linked | Row::LinkedWeak if claimed => return format!("{C34_HEAD}{}", join.tail(true)),
        Row::Linked => S3,
        Row::LinkedWeak if p.and_then(|p| p.snr).is_some() => S4_WEAK,
        Row::LinkedWeak => S4_UNKNOWN,
        Row::Booting if claimed => return format!("{SB}{C_B_TAIL}"),
        Row::Booting => SB,
        Row::RadioOff => S5,
        Row::NoKey => S5K,
        Row::RadioFault => S5R,
        Row::UnknownCode => SU,
        Row::HeardNoLink | Row::NothingHeard | Row::Linking | Row::Lost | Row::GuardedNotLinked | Row::NotLinked if claimed => return format!("{C_JOIN_HEAD}{}", join.tail(false)),
        Row::HeardNoLink => S6,
        Row::NothingHeard => S7,
        Row::Linking => S8A,
        Row::Lost if guarded => S8_GUARDED,
        Row::Lost => S8,
        Row::GuardedNotLinked => S9A,
        Row::NotLinked => S9C,
    };
    s.into()
}

/// §2-2: the first ⚠️ line that holds (unparseable throttled / temp_c → none).
fn warning(p: &Parsed) -> Option<&'static str> {
    let thr = text_of(p.f, "throttled").and_then(|t| {
        let t = t.trim();
        match t.strip_prefix("0x").or_else(|| t.strip_prefix("0X")) {
            Some(h) => u64::from_str_radix(h, 16).ok(),
            None => t.parse::<u64>().ok(),
        }
    });
    if thr.is_some_and(|x| x & 1 == 1) {
        return Some(WARN_POWER);
    }
    let temp = text_of(p.f, "temp_c").and_then(|t| t.trim().parse::<f64>().ok()).filter(|t| t.is_finite());
    if temp.is_some_and(|t| t >= TEMP_HOT_C) {
        return Some(WARN_HOT);
    }
    if p.k1 == 2 && p.code == Some(1) {
        return Some(WARN_AP);
    }
    if p.code.is_none() && p.plinks >= 1 && p.k2 == Some(2) {
        return Some(WARN_JOINED_CRIT);
    }
    None
}

/// §3: the verdict of one status result.
pub fn link_verdict(a: Answer) -> Verdict {
    link_verdict_for(a, JoinButton::Member)
}

/// §3 with the k1 = 1 sentences naming `join`, the button this phone shows.
pub fn link_verdict_for(a: Answer, join: JoinButton) -> Verdict {
    let (row, p) = match a {
        Answer::Error(E_UNSUPPORTED) => (Row::Unsupported, None),
        Answer::Error(_) => (Row::Refused, None),
        Answer::Body(v) => match parse(v) {
            None => (Row::Unknown, None),
            Some(p) => (row_of(&p), Some(p)),
        },
    };
    Verdict {
        row,
        color: color_of(row),
        sentence: sentence(row, p.as_ref(), join),
        lag_note: matches!(row, Row::Linked | Row::LinkedWeak).then_some(LAG_NOTE),
        warning: p.as_ref().and_then(warning),
    }
}

/// status key 1 when the answer has one.
pub fn node_state(a: Answer) -> Option<u64> {
    match a {
        Answer::Body(v) => v.get(1).and_then(Value::as_uint),
        Answer::Error(_) => None,
    }
}

/// §2-3: the membership line. `net_id_known`: info key 10 was read; `name`: the netcfg name of this phone's record
/// for it (net/ or mnet/), None when no record matches. "" = no line.
pub fn membership_line(k1: Option<u64>, net_id_known: bool, name: Option<&str>) -> String {
    match k1 {
        Some(2) => match (net_id_known, name) {
            (false, _) => "網路：（讀不到名稱）".into(),
            (true, Some(n)) => format!("網路：{}（已是成員）", shown(n)),
            (true, None) => "網路：別支手機建立的網路".into(),
        },
        Some(1) => "已認領，還沒加入網路".into(),
        _ => String::new(),
    }
}

/// §2-4: info key 4 (BATMAN_VERSION); "" when missing.
pub fn version_line(info: Option<&Value>) -> String {
    info.and_then(|i| i.get(4)).and_then(Value::as_text).filter(|t| !t.is_empty()).map(shown).unwrap_or_default()
}

pub const TECH_NOTES: [&str; 3] = [
    "SNR 門檻暫定；SNR 是最強那個站台的訊號（不一定是隊員，也可能是已離開的站台），雜訊讀不到時可能偏高",
    "隊員離開或關機後，『已連上』最多還會維持約 4 分鐘（節點約 200 秒才移除鄰居，再加上判定與快取）；站台數可能包含已離開的隊員",
    "joinwatch 停掉時節點會留著最後的狀態（少見），判定可能停在 🟢 或「之前連上的隊員現在收不到」",
];

/// §2-6: the collapsed technical list (every node string through `shown`), then the three notes.
pub fn tech_lines(a: Answer) -> Vec<String> {
    let mut out = vec![];
    match a {
        Answer::Error(c) => out.push(format!("錯誤碼：{c}")),
        Answer::Body(v) => {
            if let Some(n) = v.get(2).and_then(Value::as_uint) {
                let w = match n {
                    0 => "OK",
                    1 => "WARN",
                    2 => "CRIT",
                    _ => "?",
                };
                out.push(format!("健康等級（key 2）：{n}（{w}）"));
            }
            if let Some(n) = v.get(3).and_then(Value::as_uint) {
                out.push(format!("batman 鄰居數（key 3，含過期）：{n}"));
            }
            if let Some(j) = v.get(5) {
                let c = j.get(1).and_then(Value::as_uint).map(|c| c.to_string()).unwrap_or_else(|| "?".into());
                out.push(format!("未入網代碼（key 5）：{c} {}", shown(j.get(2).and_then(Value::as_text).unwrap_or(""))));
            }
            if let Some(f) = v.get(15) {
                if text_key(f, "stale") == Some(&Value::Bool(true)) {
                    out.push("節點的狀態資料過期（stale）".into());
                }
                let txt = |k: &str| text_of(f, k).map(value);
                let jn = text_key(f, "join");
                let jt = |k: &str| jn.and_then(|j| text_of(j, k)).map(value);
                if let Some(s) = txt("image") {
                    out.push(format!("上游映像（image）：{s}"));
                }
                if let Some(s) = jt("snr_db") {
                    out.push(if s == UNREAD { format!("SNR：{s}") } else { format!("SNR：{s} dB") });
                }
                if let Some(n) = jn.and_then(|j| text_key(j, "plinks")).and_then(Value::as_uint) {
                    out.push(format!("直接連到的站台數 P（plinks）：{n}"));
                }
                if let Some(s) = jt("channel") {
                    out.push(format!("頻道：{s}"));
                }
                if let Some(s) = jt("country") {
                    out.push(format!("國家：{s}"));
                }
                if let Some(n) = text_key(f, "age_s").and_then(Value::as_uint) {
                    out.push(format!("資料年齡（age_s）：{n} 秒"));
                }
                if let Some(n) = text_key(f, "uptime_s").and_then(Value::as_uint) {
                    out.push(format!("開機時間（uptime_s）：{}", duration_zh(n)));
                }
                if let Some(s) = txt("temp_c") {
                    out.push(format!("溫度（temp_c）：{s}"));
                }
                if let Some(s) = txt("throttled") {
                    out.push(format!("throttled：{s}"));
                }
                if let Some(Value::Array(a)) = text_key(f, "uci_staged") {
                    for x in a {
                        out.push(format!("未套用的設定（uci_staged）：{}", value(x.as_text().unwrap_or(""))));
                    }
                }
                if text_key(f, "ssid_unsaved") == Some(&Value::Bool(true)) {
                    out.push("手機 Wi-Fi 名稱尚未存檔（ssid_unsaved）".into());
                }
                if let Some(s) = txt("settings_restore") {
                    out.push(format!("設定還原（settings_restore）：{s}"));
                }
            }
        }
    }
    out.extend(TECH_NOTES.iter().map(|s| s.to_string()));
    out
}
