//! Whole-team status (docs/design/254-app-team-status.md v2.4 FROZEN): status keys 8 / 9 of the phone's own node
//! matched against key 7 (the node's mesh address) of the member list. Pure functions; the names shown are advisory
//! (owner decision U5) and come only from the admin-signed list — plus, on the admin's own phone, the applied /
//! approved entries of its `net/` key 11 that this phone wrote itself (v2.4 §6) — never from a hostname or bat-hosts.
//!
//! Two-step rollout (§4.3): version N (this code) ACCEPTS key 7 in member lists and join requests but never writes it,
//! and does not show the team section; N+1 flips [`WRITE_MESH_ADDR`] (writing and the view together) after every
//! phone is on N or later (a manual gate on the install record).

use crate::cbor::Value;
use crate::netrec::{Member, MemberState};
use crate::statuspage::shown;

/// §4.3: false in version N (the `team-write` feature turns it on for tests only). N+1 makes it `true` in a one-line
/// PR that also deletes the T-A10 test pinning it.
pub const WRITE_MESH_ADDR: bool = cfg!(feature = "team-write");

// code review B-M1: `team-write` is for tests only — a release (or profile) build with it does not compile. N+1 flips
// the CONSTANT above to `true`; it never ships the feature.
#[cfg(all(feature = "team-write", not(debug_assertions)))]
compile_error!("the team-write feature is tests-only (254-app-team-status §4.3): N+1 sets WRITE_MESH_ADDR = true instead");

/// key 9 holds at most this many entries (§4.1)
pub const PEERS_MAX: usize = 32;
/// in line = seen within this many seconds (§6)
pub const ONLINE_SECS: u64 = 60;

/// A usable mesh address: 6 bytes, not all zero, unicast (§4.2).
pub fn addr_ok(b: &[u8]) -> Option<[u8; 6]> {
    let a: [u8; 6] = b.try_into().ok()?;
    if a == [0; 6] || a[0] & 1 == 1 {
        return None;
    }
    Some(a)
}

/// §4.2「多一次 status 讀」: E_RATE -> one retry (design: 重試一次), so at most this many status reads before a make-network / join / join request; E_RATE between
/// them waits this long (provd allows 1 status per second per connection)
pub const ADDR_READ_TRIES: u32 = 2;
pub const ADDR_RETRY_MS: u64 = 1100;

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum AddrRead {
    /// E_RATE and reads left: wait ADDR_RETRY_MS, read again
    Retry,
    /// go on with this address (None: E_BUSY, any other failure, no / bad key 8, or the reads used up — never abort)
    Done(Option<[u8; 6]>),
}

/// The answer to the `reads`-th status read (1 = the first) right before the object is built.
pub fn addr_read(answer: Result<&Value, u64>, reads: u32) -> AddrRead {
    match answer {
        Ok(v) => AddrRead::Done(own_addr(v)),
        Err(crate::flow::E_RATE) if reads < ADDR_READ_TRIES => AddrRead::Retry,
        Err(_) => AddrRead::Done(None),
    }
}

/// What a flow writes as key 7: nothing in version N (§4.3).
pub fn gate(a: Option<[u8; 6]>) -> Option<[u8; 6]> {
    if WRITE_MESH_ADDR {
        a.and_then(|a| addr_ok(&a))
    } else {
        None
    }
}

/// Status key 8 (this node's own mesh address), when well formed.
pub fn own_addr(status: &Value) -> Option<[u8; 6]> {
    status.get(8).and_then(Value::as_bytes).and_then(addr_ok)
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Peer {
    pub addr: [u8; 6],
    pub ago: u64,
    pub kbps: Option<u64>,
    pub signal: Option<i64>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Peers {
    /// key 9 absent: an older node, or no recent sample
    Absent,
    /// key 9 malformed: treated like absent on screen, the rest of the status page untouched (§4.1)
    Bad,
    List(Vec<Peer>),
}

/// Status key 9 parsed by the §4.1 rules: the list is all-or-nothing on its shape (array, ≤ 32, every entry a map
/// with a 6-byte key 1 and a uint key 2); a malformed key 3 / key 4 costs only that field.
pub fn peers_of(status: &Value) -> Peers {
    let Some(v) = status.get(9) else { return Peers::Absent };
    let Value::Array(a) = v else { return Peers::Bad };
    if a.len() > PEERS_MAX {
        return Peers::Bad;
    }
    let mut out = Vec::with_capacity(a.len());
    for e in a {
        if !matches!(e, Value::Map(_)) {
            return Peers::Bad;
        }
        let Some(addr) = e.get(1).and_then(Value::as_bytes).and_then(|b| <[u8; 6]>::try_from(b).ok()) else { return Peers::Bad };
        let Some(ago) = e.get(2).and_then(Value::as_uint) else { return Peers::Bad };
        let kbps = e.get(3).and_then(Value::as_uint);
        let signal = match e.get(4) {
            Some(Value::Uint(n)) => i64::try_from(*n).ok(),
            Some(Value::Nint(n)) => i64::try_from(*n).ok().map(|n| -1 - n),
            _ => None,
        };
        out.push(Peer { addr, ago, kbps, signal });
    }
    Peers::List(out)
}

/// One entry of the name source as the team view uses it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Listed {
    pub dac_pub_hash: [u8; 32],
    pub name: String,
    /// key 7 when present, well formed and not shared with another entry (§4.2: a duplicate counts for neither)
    pub addr: Option<[u8; 6]>,
    /// admin phone only (v2.4 §6): an applied / approved key 11 entry not in the current signed list — its name is
    /// shown with 「（名單下一版才正式列入）」
    pub next: bool,
}

/// §4.2 on the reading side: an address shared by two entries counts for neither.
fn drop_shared(out: &mut [Listed]) {
    let addrs: Vec<Option<[u8; 6]>> = out.iter().map(|l| l.addr).collect();
    for (i, l) in out.iter_mut().enumerate() {
        if let Some(a) = l.addr {
            if addrs.iter().enumerate().any(|(j, b)| j != i && *b == Some(a)) {
                l.addr = None;
            }
        }
    }
}

/// the entries of a members payload (key 4), before the duplicate rule
fn signed_entries(members_payload: &Value) -> Vec<Listed> {
    let Some(Value::Array(list)) = members_payload.get(4) else { return vec![] };
    list.iter()
        .filter_map(|m| {
            let dac_pub_hash: [u8; 32] = m.get(1).and_then(Value::as_bytes)?.try_into().ok()?;
            let name = m.get(3).and_then(Value::as_text)?.to_string();
            let addr = m.get(7).and_then(Value::as_bytes).and_then(addr_ok);
            Some(Listed { dac_pub_hash, name, addr, next: false })
        })
        .collect()
}

/// The entries of a members payload (key 4), with the duplicate rule applied on the reading side: a member phone's
/// name source (`mnet/` key 4, v2.4 §6).
pub fn listed(members_payload: &Value) -> Vec<Listed> {
    let mut out = signed_entries(members_payload);
    drop_shared(&mut out);
    out
}

/// An admin phone's name source (v2.4 §6, R5-1 / R6-5): the current signed list ∪ the applied / approved entries of
/// `NetRec::members()` (joining ones never — the set the next signed version takes, rekey.rs:303), one per
/// dac_pub_hash with the signed entry winning; key 7 through `addr_ok`, then the duplicate rule over the union.
pub fn admin_names(signed_payload: &Value, rec: &[Member]) -> Vec<Listed> {
    let mut out = signed_entries(signed_payload);
    for m in rec.iter().filter(|m| matches!(m.state, MemberState::Applied | MemberState::Approved)) {
        if out.iter().any(|l| l.dac_pub_hash == m.dac_pub_hash) {
            continue;
        }
        out.push(Listed { dac_pub_hash: m.dac_pub_hash, name: m.name.clone(), addr: m.mesh_addr.and_then(|a| addr_ok(&a)), next: true });
    }
    drop_shared(&mut out);
    out
}

/// §4.2 for the signing side: every address that appears twice is dropped from ALL its entries; returns the indexes
/// that lost theirs (for the 「兩台都沒有登記」 line).
pub fn dedup_for_signing(addrs: &mut [Option<[u8; 6]>]) -> Vec<usize> {
    let before = addrs.to_vec();
    let mut lost = vec![];
    for (i, a) in addrs.iter_mut().enumerate() {
        let Some(x) = *a else { continue };
        if addr_ok(&x).is_none() || before.iter().enumerate().any(|(j, b)| j != i && *b == Some(x)) {
            *a = None;
            lost.push(i);
        }
    }
    lost
}

/// §4.2 (B-M2): the line shown where a signing dropped a duplicated address from every entry that had it.
pub fn dup_hint(names: &[String]) -> String {
    let who: Vec<String> = names.iter().map(|n| format!("『{}』", shown(n))).collect();
    let count = if names.len() == 2 { "兩台" } else { "這幾台" };
    format!("{}的網路位址相同，{count}都沒有登記 — 全隊狀態會顯示「沒有登記網路位址」", who.join("和"))
}

/// 「最後看到 …」 for a seen-ago (§6): under 60 minutes in minutes, else in hours.
pub fn seen_text(ago: u64) -> String {
    if ago < 60 {
        "剛剛".into()
    } else if ago < 3600 {
        format!("{} 分鐘前", ago / 60)
    } else {
        format!("{} 小時前", ago / 3600)
    }
}

/// The link quality word from the throughput (kbit/s; thresholds provisional, §6).
pub fn quality(kbps: u64) -> &'static str {
    if kbps >= 4000 {
        "好"
    } else if kbps >= 1000 {
        "普通"
    } else {
        "差"
    }
}

fn link(p: &Peer) -> String {
    let mut s = String::new();
    if let Some(k) = p.kbps {
        s.push_str(&format!(" · 連線 {}（約 {}.{} Mbit/s）", quality(k), k / 1000, (k % 1000) / 100));
    }
    s.push_str(if p.signal.is_some() { " · 直接連線" } else { " · 經隊員轉送" });
    s
}

fn hex4(a: &[u8; 6]) -> String {
    format!("{:02x}{:02x}", a[4], a[5])
}

#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct TeamView {
    /// false in version N (§4.3) and when the status read itself failed
    pub visible: bool,
    pub title: String,
    /// the line above the cards: the one sentence when there are no cards (no key 9 / bad / not in a network / nobody
    /// seen), or — with cards — 「這台目前沒連上網路…」 (key 5, nobody online, §6 (b)); else ""
    pub only: String,
    /// one card per line, in the §6 order; a card's small second line after "\n"
    pub cards: Vec<String>,
    pub note: String,
    /// the technical lines (address tails only, §7)
    pub tech: Vec<String>,
}

/// Where the names come from (v2.4 §6).
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Names {
    /// info's network id is empty: the node is in no network this phone made or joined
    NoNet,
    /// a network id, but this phone holds no record of it (or one that does not decode: fail-closed, no names)
    NoList,
    /// the name source: an admin's [`admin_names`], a member's [`listed`]
    List(Vec<Listed>),
}

pub const ONLY_NONE: &str = "看不到全隊狀態（節點軟體太舊，或暫時讀不到 mesh 資料）— 請按「重新整理」；一直如此請找維修人員";
pub const ONLY_NOT_JOINED: &str = "這台還沒連上網路，看不到隊員";
/// key 5 with cards and none of them online (§6 (b))
pub const LEAD_NOT_JOINED: &str = "這台目前沒連上網路，下面是最後看到的狀態";
/// no key 5, no card (v2.4 R6-3 / R6-7)
pub const ONLY_NO_NET: &str = "這台不在你建立或加入的網路裡，看不到隊員";
pub const ONLY_NO_LIST: &str = "這支手機沒有這個網路的名單，看不到隊員名稱";
pub const ONLY_NOBODY: &str = "還沒看到其他隊員";
pub const NOTE: &str = "在線 = 這台節點最近 1 分鐘內收得到。離線不一定是關機，也可能是太遠或被擋住。節點重開後「最後看到」會歸零。名稱僅供參考：有網路密碼的人可以假冒別台。";
/// the unknown node's small line (v2.3 R5-3: the list is re-signed only at make-network and at a removal)
pub const NEW_MEMBER_HINT: &str = "不在你手機的名單裡（可能是新加入、網主還沒發新名單的隊員）";
pub const HINT_NO_NET: &str = "這台不在你建立或加入的網路裡";
pub const HINT_NO_LIST: &str = "這支手機沒有這個網路的名單";
/// after the name of an admin-phone entry that only key 11 holds (v2.4 §6)
pub const NEXT_MARK: &str = "（名單下一版才正式列入）";

/// The team section of the status page. `status`: the status answer (None = the read failed: hidden); `names`: the
/// name source; `own_dac`: this node; `own_name`: the title's name when the caller has a better source (a member
/// phone's `mnet/` key 7) — else this node's entry in `names`, else 「這台節點」 (v2.4 R6-2).
pub fn team_view(status: Option<&Value>, names: &Names, own_dac: Option<&[u8; 32]>, own_name: Option<&str>) -> TeamView {
    team_view_with(WRITE_MESH_ADDR, status, names, own_dac, own_name)
}

/// [`team_view`] with the version gate as a parameter (tests show the N+1 view without flipping the constant).
pub fn team_view_with(enabled: bool, status: Option<&Value>, names: &Names, own_dac: Option<&[u8; 32]>, own_name: Option<&str>) -> TeamView {
    let Some(st) = status.filter(|_| enabled) else { return TeamView::default() };
    let list: &[Listed] = match names {
        Names::List(l) => l,
        Names::NoNet | Names::NoList => &[],
    };
    let title_name = match own_name {
        Some(n) => shown(n),
        None => own_dac.and_then(|d| list.iter().find(|l| &l.dac_pub_hash == d)).map(|l| shown(&l.name)).unwrap_or_else(|| "這台節點".into()),
    };
    let mut v = TeamView { visible: true, title: format!("全隊（僅供參考；由『{title_name}』看到）"), note: NOTE.into(), ..Default::default() };
    let not_joined = st.get(5).is_some();
    let peers = match peers_of(st) {
        Peers::List(p) => p,
        Peers::Absent | Peers::Bad => {
            // §6 (a): key 5 (booting, radio off, a reload: no key 9) keeps the v2.1 sentence (R5-2)
            v.only = if not_joined { ONLY_NOT_JOINED } else { ONLY_NONE }.into();
            return v;
        }
    };
    let own = own_addr(st);
    let peers: Vec<&Peer> = peers.iter().filter(|p| Some(p.addr) != own).collect();
    let hint = match names {
        Names::NoNet => HINT_NO_NET,
        Names::NoList => HINT_NO_LIST,
        Names::List(_) => NEW_MEMBER_HINT,
    };
    // (order class, sort key, text); class 0 online, 1 offline, 2 not seen since boot, 3 no address, 4 unknown
    let mut cards: Vec<(u8, (u64, String), String)> = vec![];
    let mut online = false;
    for l in list.iter().filter(|l| Some(&l.dac_pub_hash) != own_dac) {
        let plain = shown(&l.name);
        let name = if l.next { format!("『{plain}』{NEXT_MARK}") } else { format!("『{plain}』") };
        let Some(a) = l.addr else {
            cards.push((3, (0, plain), format!("⚪ {name} 沒有登記網路位址，看不到狀態")));
            continue;
        };
        match peers.iter().find(|p| p.addr == a) {
            Some(p) if p.ago <= ONLINE_SECS => {
                online = true;
                cards.push((0, (0, plain), format!("🟢 {name} 在線{}", link(p))))
            }
            Some(p) => cards.push((1, (p.ago, plain), format!("⚪ {name} 離線 · 最後看到 {}", seen_text(p.ago)))),
            None => cards.push((2, (0, plain), format!("⚪ {name} 這台節點開機後還沒看到"))),
        }
    }
    let listed_addrs: Vec<[u8; 6]> = list.iter().filter_map(|l| l.addr).collect();
    for p in peers.iter().filter(|p| !listed_addrs.contains(&p.addr)) {
        let state = if p.ago <= ONLINE_SECS {
            online = true; // an online unknown node counts (v2.4 R6-6)
            format!("在線{}", link(p))
        } else {
            format!("最後看到 {}", seen_text(p.ago))
        };
        cards.push((4, (p.ago, hex4(&p.addr)), format!("❔ 不明節點 · {state}\n{hint}")));
        v.tech.push(format!("不明節點 …{}：{} 秒前{}", hex4(&p.addr), p.ago, p.signal.map(|s| format!("，訊號 {s} dBm")).unwrap_or_default()));
    }
    let seen = cards.iter().any(|c| matches!(c.0, 0 | 1 | 4));
    if not_joined {
        if !seen {
            // §6 (c): only 「not seen since boot」 / 「no address」 cards, or none
            v.only = ONLY_NOT_JOINED.into();
            return v;
        }
        if !online {
            v.only = LEAD_NOT_JOINED.into(); // §6 (b); with an online card the JOINED verdict merely lags: no line
        }
    } else if cards.is_empty() {
        v.only = match names {
            Names::NoNet => ONLY_NO_NET,
            Names::NoList => ONLY_NO_LIST,
            Names::List(_) => ONLY_NOBODY,
        }
        .into();
    }
    cards.sort_by(|a, b| a.0.cmp(&b.0).then_with(|| a.1.cmp(&b.1)));
    v.cards = cards.into_iter().map(|c| c.2).collect();
    v
}
