//! Remove a member: 「把新密碼送給節點」 (docs/design/254-app-remove-member.md v6.4 §3.2), sans-IO over an owner
//! session (loginflow::into_conn, DAC pinned) of one of this phone's nodes; the admin's net record or a member's mnet.
//!   0 the target rule (§2.0): admin — the node's entry in key 11 with this phone's owner_pub (its ecdh_pub is the
//!     one used); member — mnet key 7 or key 10 holds its current-version secrets.
//!   1 info -> `join_state`: Unknown -> wait 2 s and read again (3 reads); InProgress / OtherNetwork / NotApplied /
//!     key 11 true -> stop with its line.
//!   2 key 4 must pass the version rule (`version_ok`, fail-closed); key 9 = the phone's version -> already; > -> warn.
//!   3 the chain (key 9, current] from the phone's versions + this node's current net_secrets (admin: made and signed
//!     now; member: as stored); the version after key 9 missing or more than 8 chunks -> too far behind.
//!   4 network/update {1: [{1 netcfg, 2 members}, …, {1, 2, 3 secrets}]} (no owner-op, 219 §5.3) -> whatever the
//!     answer, info again: key 9 = current -> changed; key 11 true -> applying; key 9 unchanged after
//!     E_REJECTED{2: 14} -> an app bug; else not changed.
//! Never sent automatically (§3.1 / §3.4): only from the button.

use crate::cbor::Value;
use crate::conn::{Conn, MAX_MESSAGE};
use crate::cose;
use crate::envelope::{self, Outcome};
use crate::flow::{self, JoinState};
use crate::mrec::MNet;
use crate::netrec::{self, Member, NetRec, Version};
use crate::nodecert::Verified;
use crate::rekey;
use crate::sig;

/// the node takes at most this many chunks of one request (provd MaxChunks, R13)
pub const MAX_CHUNKS: usize = 8;
/// the first DEV image with the F10 fix (R30)
pub const MIN_WSL: u64 = 25;
/// E_REJECTED's reason when the chain did not apply because the country changed (254-p3-impl D9)
pub const REASON_COUNTRY: u64 = 14;
const INFO_READS: u32 = 3;

/// §3.6 version rule over info key 4: the first `-wsl.` followed by digits; more than 9 digits, none, or < 25 ->
/// not passed (fail-closed).
pub fn version_ok(k4: Option<&str>) -> bool {
    let Some(s) = k4 else { return false };
    let Some(i) = s.find("-wsl.") else { return false };
    let d: String = s[i + 5..].chars().take_while(|c| c.is_ascii_digit()).collect();
    if d.is_empty() || d.len() > 9 {
        return false;
    }
    d.parse::<u64>().is_ok_and(|n| n >= MIN_WSL)
}

pub struct Input {
    pub record_plain: Vec<u8>,
    /// `record_plain` is a member's mnet
    pub member: bool,
    /// the node_cert verified at this login (None = not verified)
    pub node: Option<Verified>,
    pub owner_pub: [u8; 65],
    pub admin_pub: [u8; 65],
}

#[derive(Debug, PartialEq, Eq)]
pub enum End {
    Record,
    NotVerified,
    /// §2.0 rule 1: not in key 11 with this phone's owner_pub (excluded / forgotten), or its entry's ecdh_pub is not
    /// the one this login verified: leave only, or join to add back
    NotListed,
    /// the record's admins do not hold this phone's admin key
    NotAdmin,
    /// §2.0 rule 3: this phone has no current secrets for it: 「請網主重新產生你的更新包」
    NoSecrets,
    /// info unreadable 3 times
    Unknown,
    InProgress,
    OtherNetwork,
    /// not in a network: join instead; `rejoin` false = a member's non-key-7 node (the admin re-invites it)
    NotApplied { rejoin: bool },
    /// key 11 true
    Unfinished,
    /// key 4 does not pass the version rule
    NeedsSoftware,
    AlreadyCurrent,
    /// key 9 > the phone's version
    NodeNewer,
    /// the version after the node's is not kept here, or more than 8 chunks; `rejoin` as for NotApplied
    TooFar { rejoin: bool },
    Updated,
    Applying,
    /// key 9 unchanged after E_REJECTED{2: 14}
    AppBug,
    NotChanged,
    /// the admin key did not sign: nothing sent
    SignFailed,
    Broken(String),
}

#[derive(PartialEq)]
pub enum Action {
    Write(Vec<Vec<u8>>),
    SignAdmin { tbs: Vec<u8> },
    /// wait this long, then `resume`
    Wait { ms: u64 },
    Done(End),
}

impl std::fmt::Debug for Action {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Action::Write(fr) => write!(f, "Write({} frames)", fr.len()),
            Action::SignAdmin { tbs } => write!(f, "SignAdmin({} B)", tbs.len()),
            Action::Wait { ms } => write!(f, "Wait({ms} ms)"),
            Action::Done(e) => write!(f, "Done({e:?})"),
        }
    }
}

enum Who {
    Admin { rec: NetRec, entry: Member },
    Member { secrets: Option<Vec<u8>>, k7: bool },
}

enum Step {
    Info { reads: u32 },
    Sign { chain: Vec<Version>, payload: Vec<u8>, before: u64 },
    Reply { before: u64 },
    After { before: u64, reply: Outcome },
    Over,
}

pub struct SendUpdate {
    conn: Conn,
    who: Option<Who>,
    net_id: [u8; 16],
    version: u32,
    history: Vec<Version>,
    st: Step,
}

impl SendUpdate {
    pub fn start(conn: Conn, inp: Input) -> (SendUpdate, Action) {
        let mut u = SendUpdate { conn, who: None, net_id: [0; 16], version: 0, history: vec![], st: Step::Over };
        let a = match u.begin(inp) {
            Ok(a) => a,
            Err(e) => Action::Done(e),
        };
        (u, a)
    }

    pub fn into_conn(self) -> Conn {
        self.conn
    }

    fn begin(&mut self, inp: Input) -> Result<Action, End> {
        let node = inp.node.ok_or(End::NotVerified)?;
        let h = netrec::dac_hash(&node.dac_pub);
        if inp.member {
            let m = MNet::decode(&inp.record_plain).map_err(|_| End::Record)?;
            let k7 = m.me.as_ref().is_some_and(|e| e.dac_pub_hash == h);
            let secrets = m.secrets_for(&h);
            if !k7 && secrets.is_none() {
                return Err(End::NoSecrets);
            }
            self.net_id = m.net_id;
            self.version = m.version;
            self.history = m.history();
            self.who = Some(Who::Member { secrets, k7 });
        } else {
            let rec = netrec::decode(&inp.record_plain).map_err(|_| End::Record)?;
            let cfg = rec.netcfg().map_err(|_| End::Record)?;
            let list = rec.members().map_err(|_| End::Record)?;
            let entry = list.into_iter().find(|m| m.dac_pub_hash == h && m.owner_pub == inp.owner_pub).ok_or(End::NotListed)?;
            // the secrets go to the entry's ecdh_pub (§2.0 rule 1): it must be the key this login's node_cert proved
            if entry.ecdh_pub != node.ecdh_pub {
                return Err(End::NotListed);
            }
            if !cfg.admins.contains(&inp.admin_pub) {
                return Err(End::NotAdmin);
            }
            self.net_id = rec.base.net_id;
            self.version = cfg.version;
            self.history = rec.history().map_err(|_| End::Record)?;
            self.who = Some(Who::Admin { rec, entry });
        }
        self.request("info", Value::Map(vec![]), Step::Info { reads: 1 }).ok_or(End::Broken("info".into()))
    }

    fn rejoin(&self) -> bool {
        !matches!(self.who, Some(Who::Member { k7: false, .. }))
    }

    fn end(&mut self, e: End) -> Option<Action> {
        self.st = Step::Over;
        Some(Action::Done(e))
    }

    fn request(&mut self, verb: &str, body: Value, next: Step) -> Option<Action> {
        match self.conn.request(verb, body) {
            Ok((_, f)) => {
                self.st = next;
                Some(Action::Write(f))
            }
            Err(e) => self.end(End::Broken(format!("{e:?}"))),
        }
    }

    /// After a Wait: read info again.
    pub fn resume(&mut self) -> Option<Action> {
        let Step::Info { reads } = self.st else { return None };
        self.request("info", Value::Map(vec![]), Step::Info { reads: reads + 1 })
    }

    pub fn on_frame(&mut self, f: &[u8]) -> Option<Action> {
        if !matches!(self.st, Step::Info { .. } | Step::Reply { .. } | Step::After { .. }) {
            return match self.st {
                Step::Over => None,
                _ => self.end(End::Broken("unexpected frame".into())),
            };
        }
        let o = match self.conn.on_frame(f) {
            Ok(None) => return None,
            Ok(Some(o)) => o,
            Err(e) => return self.end(End::Broken(format!("{e:?}"))),
        };
        match std::mem::replace(&mut self.st, Step::Over) {
            Step::Info { reads } => self.on_info(reads, o),
            Step::Reply { before } => self.request("info", Value::Map(vec![]), Step::After { before, reply: o }),
            Step::After { before, reply } => self.on_after(before, reply, o),
            _ => None,
        }
    }

    fn on_info(&mut self, reads: u32, o: Outcome) -> Option<Action> {
        let s = match &o {
            Outcome::Ok(b) => flow::join_state(b, &self.net_id),
            Outcome::Err { .. } => JoinState::Unknown,
        };
        let b = match (s, o) {
            (JoinState::Unknown, _) if reads < INFO_READS => {
                self.st = Step::Info { reads };
                return Some(Action::Wait { ms: 2000 });
            }
            (JoinState::Unknown, _) => return self.end(End::Unknown),
            (JoinState::InProgress, _) => return self.end(End::InProgress),
            (JoinState::OtherNetwork, _) => return self.end(End::OtherNetwork),
            (JoinState::NotApplied, _) => {
                let rejoin = self.rejoin();
                return self.end(End::NotApplied { rejoin });
            }
            (JoinState::Applied { save_pending: true }, _) => return self.end(End::Unfinished),
            (JoinState::Applied { .. }, Outcome::Ok(b)) => b,
            (JoinState::Applied { .. }, Outcome::Err { .. }) => return self.end(End::Unknown),
        };
        if !version_ok(b.get(4).and_then(Value::as_text)) {
            return self.end(End::NeedsSoftware);
        }
        let Some(k9) = b.get(9).and_then(Value::as_uint) else { return self.end(End::Unknown) };
        let cur = self.version as u64;
        if k9 == cur {
            return self.end(End::AlreadyCurrent);
        }
        if k9 > cur {
            return self.end(End::NodeNewer);
        }
        let chain: Vec<Version> = self.history.iter().filter(|x| x.version as u64 > k9).cloned().collect();
        if chain.first().map(|x| x.version as u64) != Some(k9 + 1) {
            let rejoin = self.rejoin();
            return self.end(End::TooFar { rejoin });
        }
        match self.who.as_ref() {
            Some(Who::Admin { rec, entry }) => match rekey::secrets_payload(rec, self.version, &entry.ecdh_pub, &entry.dac_pub_hash, false) {
                Ok(payload) => {
                    let tbs = cose::sign1_tbs(cose::CT_SECRETS, cose::LABEL_SECRETS, &payload);
                    self.st = Step::Sign { chain, payload, before: k9 };
                    Some(Action::SignAdmin { tbs })
                }
                Err(e) => self.end(End::Broken(e)),
            },
            Some(Who::Member { secrets: Some(s), .. }) => {
                let s = s.clone();
                self.send(chain, &s, k9)
            }
            Some(Who::Member { secrets: None, .. }) => self.end(End::NoSecrets),
            None => self.end(End::Broken("no record".into())),
        }
    }

    /// The platform's DER signature for the admin's fresh net_secrets (empty / bad = it failed: nothing sent).
    pub fn signed(&mut self, der: &[u8]) -> Option<Action> {
        let Step::Sign { .. } = self.st else { return None };
        let Step::Sign { chain, payload, before } = std::mem::replace(&mut self.st, Step::Over) else { return None };
        let Ok(s) = sig::der_to_raw_low_s(der) else { return self.end(End::SignFailed) };
        let secrets = cose::sign1(cose::CT_SECRETS, &payload, &s);
        self.send(chain, &secrets, before)
    }

    fn send(&mut self, chain: Vec<Version>, secrets: &[u8], before: u64) -> Option<Action> {
        let body = match body(&chain, secrets) {
            Ok(b) => b,
            Err(e) => return self.end(End::Broken(e)),
        };
        // R13: the app's chunker against the node's 8 (the largest id: the count never grows with the real one)
        match envelope::split_request(u32::MAX as u64, "network/update", body.clone(), MAX_MESSAGE) {
            Ok(m) if m.len() <= MAX_CHUNKS => {}
            _ => {
                let rejoin = self.rejoin();
                return self.end(End::TooFar { rejoin });
            }
        }
        self.request("network/update", body, Step::Reply { before })
    }

    fn on_after(&mut self, before: u64, reply: Outcome, o: Outcome) -> Option<Action> {
        let Outcome::Ok(b) = o else { return self.end(End::Unknown) };
        let state = flow::join_state(&b, &self.net_id);
        let k9 = b.get(9).and_then(Value::as_uint);
        let e = match state {
            JoinState::Applied { save_pending: true } => End::Applying,
            JoinState::Applied { .. } if k9 == Some(self.version as u64) => End::Updated,
            JoinState::Applied { .. } if k9 == Some(before) => match reply {
                Outcome::Err { code: flow::E_REJECTED, detail } if detail.get(2).and_then(Value::as_uint) == Some(REASON_COUNTRY) => End::AppBug,
                _ => End::NotChanged,
            },
            JoinState::Unknown => End::Unknown,
            _ => End::NotChanged,
        };
        self.end(e)
    }
}

/// {1: [{1 netcfg, 2 members}, …, {1, 2, 3 secrets}]} (219-protocol.cddl update-step: secrets in the last step only)
pub fn body(chain: &[Version], secrets: &[u8]) -> Result<Value, String> {
    let item = |b: &[u8]| crate::cbor::decode(b).map_err(|e| format!("{e:?}"));
    let n = chain.len();
    let steps = chain
        .iter()
        .enumerate()
        .map(|(i, x)| {
            let mut s = vec![(Value::Uint(1), item(&x.netcfg)?), (Value::Uint(2), item(&x.members)?)];
            if i + 1 == n {
                s.push((Value::Uint(3), item(secrets)?));
            }
            Ok(Value::Map(s))
        })
        .collect::<Result<Vec<_>, String>>()?;
    Ok(Value::Map(vec![(Value::Uint(1), Value::Array(steps))]))
}
