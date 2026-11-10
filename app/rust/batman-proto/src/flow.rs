//! What each reply means for the next step (docs/design/254-app-s1.md §5.1, §5.2, §5.4). Pure functions over a parsed
//! response (`envelope::Outcome`) or an info body; the state machine that acts on them keeps the counters and timers.
//! No reply ever means "delete the claim-pending record" (§5.1): only a node record or the user does that.

use crate::cbor::Value;
use crate::envelope::Outcome;

// protocol codes, S/provd/session.go:39-50 (helper codes are mapped onto these, session.go:564-580)
pub const E_FORBIDDEN: u64 = 3;
pub const E_BAD_OBJECT: u64 = 4;
pub const E_UNSUPPORTED: u64 = 6;
pub const E_CLAIM_FAILED: u64 = 9;
pub const E_REJECTED: u64 = 11;
pub const E_RATE: u64 = 12;
pub const E_LOCK_INCOMPLETE: u64 = 13;
/// error-detail reason 10 with capability "claim": a legacy node without an SSH key
pub const REASON_LEGACY_NO_KEY: u64 = 10;

/// claim/finish and claim/replay success body {1: owner_tag_key, 2: adv_owner_key, 3: root_password} (cddl:178-183).
#[derive(Debug, PartialEq, Eq)]
pub struct Creds {
    pub owner_tag_key: [u8; 32],
    pub adv_owner_key: [u8; 32],
    pub root_password: String,
}

fn creds(body: &Value) -> Option<Creds> {
    Some(Creds {
        owner_tag_key: body.get(1)?.as_bytes()?.try_into().ok()?,
        adv_owner_key: body.get(2)?.as_bytes()?.try_into().ok()?,
        root_password: body.get(3)?.as_text().filter(|p| !p.is_empty())?.to_string(),
    })
}

#[derive(Debug, PartialEq, Eq)]
pub enum ClaimFinish {
    /// write the node record (with K), then delete the pending
    Claimed(Creds),
    /// committed without credentials (13, or a success whose body is unusable): keep the pending, no join -> §5.2 replay
    Committed,
    /// 6 {claim, 10}: a legacy node without an SSH key
    LegacyNoSshKey,
    /// 3: no / expired claim/begin, nothing committed -> claim/begin again with the same pending
    BeginAgain,
    /// 4: malformed request = an app bug -> stop, keep the pending
    AppBug,
    /// 9: K wrong, someone else first, or OUR earlier finish committed and provd's cached state is stale ->
    /// try psk_replay first (3 x 15 s), never a verdict
    TryReplay,
    /// 7, any other code, or no reply -> keep the pending -> §5.2
    Unknown,
}

pub fn claim_finish(o: &Outcome) -> ClaimFinish {
    match o {
        Outcome::Ok(b) => creds(b).map_or(ClaimFinish::Committed, ClaimFinish::Claimed),
        Outcome::Err { code: E_LOCK_INCOMPLETE, .. } => ClaimFinish::Committed,
        Outcome::Err { code: E_UNSUPPORTED, detail }
            if detail.get(1).and_then(Value::as_text) == Some("claim")
                && detail.get(2).and_then(Value::as_uint) == Some(REASON_LEGACY_NO_KEY) =>
        {
            ClaimFinish::LegacyNoSshKey
        }
        Outcome::Err { code: E_FORBIDDEN, .. } => ClaimFinish::BeginAgain,
        Outcome::Err { code: E_BAD_OBJECT, .. } => ClaimFinish::AppBug,
        Outcome::Err { code: E_CLAIM_FAILED, .. } => ClaimFinish::TryReplay,
        Outcome::Err { .. } => ClaimFinish::Unknown,
    }
}

#[derive(Debug, PartialEq, Eq)]
pub enum ClaimReplay {
    /// write the node record, overwriting root_password (every replay rotates it), then delete the pending
    Recovered(Creds),
    /// 13: this session already became owner and an owner may not replay -> disconnect, new connection, replay again;
    /// not counted against the node's failures nor the app's 3 / hour (the app's own cap: 5 in a row)
    Reconnect,
    /// 12: the node's hourly failure cap
    RateLimited,
    /// 3 (the helper's refusal passed through, session.go:653-657; 3 on one connection closes it) or 4: refused,
    /// counts toward the app's 3 per device_id per hour
    Refused,
    /// a success without usable credentials, any other code, or no reply: keep the pending, try later
    Unknown,
}

pub fn claim_replay(o: &Outcome) -> ClaimReplay {
    match o {
        Outcome::Ok(b) => creds(b).map_or(ClaimReplay::Unknown, ClaimReplay::Recovered),
        Outcome::Err { code: E_LOCK_INCOMPLETE, .. } => ClaimReplay::Reconnect,
        Outcome::Err { code: E_RATE, .. } => ClaimReplay::RateLimited,
        Outcome::Err { code: E_FORBIDDEN | E_BAD_OBJECT, .. } => ClaimReplay::Refused,
        Outcome::Err { .. } => ClaimReplay::Unknown,
    }
}

#[derive(Debug, PartialEq, Eq)]
pub enum JoinReply {
    Applied,
    /// 4: malformed = an app bug; the next attempt uses a new net_id
    Rejected,
    /// 3: nonce / signature -> a new op/nonce, the same net_id once more
    NewNonce,
    /// 11, any other code, a lost reply -> reconnect (auth/owner) and read info, then `join_state`
    ReadInfo,
}

pub fn network_join(o: &Outcome) -> JoinReply {
    match o {
        Outcome::Ok(_) => JoinReply::Applied,
        Outcome::Err { code: E_BAD_OBJECT, .. } => JoinReply::Rejected,
        Outcome::Err { code: E_FORBIDDEN, .. } => JoinReply::NewNonce,
        Outcome::Err { .. } => JoinReply::ReadInfo,
    }
}

#[derive(Debug, PartialEq, Eq)]
pub enum JoinState {
    /// 10 == our net_id; `save_pending` when 11 == true ("saved at the node's next boot")
    Applied { save_pending: bool },
    /// 10 absent, 11 == true: in progress -> poll (≤ 960 s)
    InProgress,
    /// 10 absent, 11 == false: not applied or rolled back -> the same net_id may be sent again
    NotApplied,
    /// 10 present and not ours: the node is in another network -> stop and warn
    OtherNetwork,
    /// 9 / 10 / 11 all absent (info.net hit E_RATE), or malformed -> poll (≤ 960 s)
    Unknown,
}

/// §5.4's table over an info body read in an owner / member session.
pub fn join_state(info: &Value, our_net_id: &[u8; 16]) -> JoinState {
    let unfinished = match info.get(11) {
        None => None,
        Some(Value::Bool(b)) => Some(*b),
        Some(_) => return JoinState::Unknown,
    };
    match info.get(10) {
        Some(v) => match v.as_bytes() {
            Some(id) if id == our_net_id => JoinState::Applied { save_pending: unfinished == Some(true) },
            Some(id) if id.len() == 16 => JoinState::OtherNetwork,
            _ => JoinState::Unknown,
        },
        None => match unfinished {
            Some(true) => JoinState::InProgress,
            Some(false) => JoinState::NotApplied,
            None => JoinState::Unknown,
        },
    }
}

/// "Connected" after a join (254-app-join2 v7.2 §3.3-7), from ONE `status` answer of the owner session.
#[derive(Debug, PartialEq, Eq)]
pub enum LinkState {
    /// key 15 fresh, sampled after the join reply, and the status page's rows 3 / 4: the node's own JOINED (key 5
    /// absent) with plinks > 0
    Connected { plinks: u64 },
    /// the status is usable but shows no other member yet (any other row, or sampled before the join)
    NotYet,
    /// stale, key 15 / age_s missing, or the status page's rows 1-2: the link state is unknown
    Unknown,
}

fn text_key<'a>(m: &'a Value, k: &str) -> Option<&'a Value> {
    match m {
        Value::Map(e) => e.iter().find(|(key, _)| matches!(key, Value::Text(t) if t == k)).map(|(_, v)| v),
        _ => None,
    }
}

/// `secs_since_join`: seconds from the network/join reply to this status request. The halow-status cache behind the
/// answer must be younger than the join (key 15 age_s); then the verdict is the status page's (statuspage §3): rows
/// 1-2 unknown, rows 3-4 connected, any other row not yet. key 3 is not read (all hardifs, stale entries included).
pub fn link_state(status: &Value, secs_since_join: u64) -> LinkState {
    let Some(f) = status.get(15) else { return LinkState::Unknown };
    if text_key(f, "stale") == Some(&Value::Bool(true)) {
        return LinkState::Unknown;
    }
    let Some(age) = text_key(f, "age_s").and_then(Value::as_uint) else { return LinkState::Unknown };
    if age >= secs_since_join {
        return LinkState::NotYet;
    }
    use crate::statuspage::{self as sp, Row};
    match sp::link_verdict(sp::Answer::Body(status)).row {
        Row::Unsupported | Row::Unknown | Row::Refused => LinkState::Unknown,
        Row::Linked | Row::LinkedWeak => {
            let plinks = text_key(f, "join").and_then(|j| text_key(j, "plinks")).and_then(Value::as_uint).unwrap_or(0);
            LinkState::Connected { plinks }
        }
        _ => LinkState::NotYet,
    }
}
