//! A second (N-th) node joins the network this phone made (docs/design/254-app-join2.md v7.1 §3.3), sans-IO over an
//! owner session (loginflow::into_conn) of the node that joins:
//!   1 preconditions (nothing written or sent when one fails): a the record opens and is applied; b this login's
//!     node_cert was verified; c the record's netcfg lists this phone's admin key; d < 16 members not counting an
//!     older entry of the same node.
//!   2 net_secrets made afresh (every send): the netcfg's net_id / version, the record's SAE / net_root, ECDH-ES to the
//!     verified ecdh_pub, key 3 = SHA-256(verified DAC pub); admin Sign1. A signing failure stops before any write.
//!   3 country against the netcfg's key 5: settings/get. P2 (E_UNSUPPORTED {1: "settings/get"}, no reason) -> go on,
//!     "country not verified". Same -> go on. Different -> the user confirms -> the entry is written joining with
//!     prev_country first -> settings/set. Only reason 14 / 20 is an explicit refusal (the entry goes back to what it
//!     was); any other answer -> settings/get: the wanted country -> go on, else the entry and prev_country stay.
//!   4 PersistNet: the entry joining (replacing an older one of the same node, keeping its prev_country) lands
//!     before anything is sent. 5 op/nonce -> owner-op -> network/join {1: the record's signed netcfg as is,
//!     2: the record's members, 3: secrets}.
//!   6 the reply: 0 applied; 3 once more with new secrets; 4 / another network / not applied -> the country is put
//!     back first (the entry is deleted only when that worked); 5 / 7 / 11 / other -> info decides (`join_state`).
//! Every record write is a CAS from the generation the record was read at (the caller: Store::write_cas with
//! `expected_gen`; the next write of this flow uses the generation the last one made). Step 7 ("connected") is
//! flow::link_state, polled by the caller.
//!
//! Member mode (254-app-member-join §4 step 8): the record is the member phone's `mnet/<net_id>`; a = it opens and
//! has its own-node entry (key 7; applied is sent too, 5 -> info decides); c = its secrets' key 3 = this login's DAC
//! hash; d does not apply; the secrets are mnet key 5 as they are (never signed here); every write is PersistMnet
//! (never PersistNet); 3 -> the same request once more, 3 again -> TwiceRefused; 4 -> the country back first, then
//! key 7 dropped (the bridge says a new invite is needed). Country, prev_country, reply table, connected: as above.

use crate::cbor::{self, Value};
use crate::conn::Conn;
use crate::cose;
use crate::envelope::Outcome;
use crate::flow::{self, JoinState};
use crate::joinflow::join_body;
use crate::mrec::MNet;
use crate::netrec::{self, Member, MemberState, NetCfg, NetRec, MAX_MEMBERS};
use crate::nodecert::Verified;
use crate::sig;

/// error-detail reasons that refuse settings.set BEFORE the radio is touched (254-p3: 14 = in a network, 20 = legacy)
pub const REASON_IN_NETWORK: u64 = 14;
pub const REASON_LEGACY: u64 = 20;

pub struct Input {
    /// the opened net record and the generation it was read at (store_read_sealed)
    pub record_plain: Vec<u8>,
    pub record_gen: u64,
    /// the node_cert verified at this login; None = not verified (precondition b)
    pub node: Option<Verified>,
    pub node_name: String,
    /// this phone's keys
    pub owner_pub: [u8; 65],
    pub owner_enc_pub: [u8; 65],
    pub admin_pub: [u8; 65],
    /// member mode: `record_plain` is an mnet record (member-join §4 step 8); the keys above are unused then
    pub member: bool,
    /// remove-member §2.0 rule 2: the admin answered yes to "this node was removed before (lost / captured)"; without
    /// it such a node stops at the start (Pre::RemovedBefore: nothing written, nothing signed)
    pub removed_confirmed: bool,
    /// status key 8 of this node as the session last read it (254-app-team-status §4.2); written only from N+1
    pub mesh_addr: Option<[u8; 6]>,
}

/// a precondition that failed (§3.3-1)
#[derive(Debug, PartialEq, Eq, Clone, Copy)]
pub enum Pre {
    /// a: the record does not decode
    Record,
    /// a: the record is not applied (confirm network first)
    NotApplied,
    /// b
    NotVerified,
    /// c
    NotAdmin,
    /// d
    Full,
    /// member a: the mnet has no own-node entry (dropped after a definite failure: a new invite is needed)
    NoEntry,
    /// member c: the mnet's secrets are for another node than this login's
    NotThisNode,
    /// remove-member §2.0 rule 2: the node is in some version's removed list and the admin has not confirmed
    RemovedBefore,
}

/// a definite failure of the join: the country is put back
#[derive(Debug, PartialEq, Eq, Clone)]
pub enum Fail {
    /// 4: the node did not accept the network config
    Rejected,
    /// info key 10 is another network
    OtherNetwork,
    /// info: not applied after this join reply code
    NotApplied(u64),
    /// op/nonce refused before network/join: nothing was sent (§3.3-3 "送出前放棄")
    NotSent(u64),
}

/// what happened to the country and the entry after a definite failure
#[derive(Debug, PartialEq, Eq, Clone)]
pub enum Revert {
    /// no prev_country (the country was never changed): the entry was deleted
    NoChange,
    /// the country is the original again (put back, or it already was): the entry was deleted
    Reverted { country: String },
    /// putting it back failed or could not be checked: the entry and prev_country stay
    NotReverted { now: String, was: String },
}

/// the join stays "joining" (prev_country kept): try again later on this node ("繼續加入")
#[derive(Debug, PartialEq, Eq, Clone)]
pub enum Keep {
    /// 7, then info not applied: the node may be in a trial boot / OTA, or the helper went away
    Unclear7,
    /// 5 without key 10, 11 / other in progress or unknown, info unreadable
    Unclear,
    /// settings.set gave no clear answer and settings/get does not show the wanted country
    CountryUnknown,
    /// 3 twice
    TwiceRefused,
    /// op/nonce refused before settings.set: nothing was sent, the entry is back to what it was before this flow
    NonceRefused(u64),
}

#[derive(Debug, PartialEq)]
pub enum End {
    Refused(Pre),
    Applied { country_unverified: bool, save_pending: bool },
    /// the user did not want the country changed: nothing written, nothing sent
    Declined { have: String, want: String },
    /// settings.set refused with reason 14 / 20 (before the radio was touched): the entry is as before
    CountryRefused { code: u64, reason: u64 },
    /// settings/get failed (not P2): nothing written
    SettingsError(Outcome),
    Joining(Keep),
    Failed(Fail, Revert),
    /// the admin key did not sign net_secrets (lost / invalidated): before any write, country change or send
    AdminSignFailed,
    /// a record write failed; `error` None = the record changed elsewhere (generation mismatch), else why;
    /// `applied`: the node had already applied
    PersistFailed { applied: bool, error: Option<String> },
    Broken(String),
}

#[derive(PartialEq)]
pub enum Action {
    /// the admin key over a COSE Sig_structure; feed the DER to `signed` (an empty DER = the platform failed)
    SignAdmin { tbs: Vec<u8> },
    /// the owner key over an owner-op input; feed the DER to `signed`
    SignOwner { input: Vec<u8> },
    Write(Vec<Vec<u8>>),
    /// seal `plain` with aad(net/<hex net_id>, expected_gen + 1) and Store::write_cas(.., expected_gen, ..), then
    /// `net_persisted` (or `persist_failed`). Holds SAE / net_root: never shown or logged.
    PersistNet { net_id: [u8; 16], plain: Vec<u8>, expected_gen: u64 },
    /// member mode's only write: the mnet record, sealed with aad(mnet/<hex net_id>, expected_gen + 1), write_cas
    PersistMnet { net_id: [u8; 16], plain: Vec<u8>, expected_gen: u64 },
    /// ask the user: change the node's country from `have` to `want`? -> `country_confirmed`
    ConfirmCountry { have: String, want: String },
    Done(End),
}

/// The record writes hold SAE / net_root: never formatted (remove-member §6).
impl std::fmt::Debug for Action {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Action::SignAdmin { tbs } => write!(f, "SignAdmin({} B)", tbs.len()),
            Action::SignOwner { input } => write!(f, "SignOwner({} B)", input.len()),
            Action::Write(fr) => write!(f, "Write({} frames)", fr.len()),
            Action::PersistNet { expected_gen, plain, .. } => write!(f, "PersistNet {{ plain: <{} B>, expected_gen: {expected_gen} }}", plain.len()),
            Action::PersistMnet { expected_gen, plain, .. } => write!(f, "PersistMnet {{ plain: <{} B>, expected_gen: {expected_gen} }}", plain.len()),
            Action::ConfirmCountry { have, want } => write!(f, "ConfirmCountry({have} -> {want})"),
            Action::Done(e) => write!(f, "Done({e:?})"),
        }
    }
}

enum Then {
    SetCountry,
    Join,
    Applied { save_pending: bool },
    End(End),
}

#[derive(Clone)]
enum Op {
    SetCountry,
    Join,
    Revert(Fail),
}

enum Get {
    Check,
    AfterSet,
    Revert(Fail),
}

enum InfoFor {
    After5,
    After7,
    Other(u64),
}

enum Step {
    Secrets { payload: Vec<u8>, resend: bool },
    Get(Get),
    Confirm { have: String },
    Persist(Then),
    Nonce(Op),
    Owner { op: Op, body: Value },
    Reply(Op),
    Info(InfoFor),
    Over,
}

/// The record a join works on: the admin's net record or a member's mnet record.
#[derive(Clone)]
enum Rec {
    Net(NetRec),
    M(MNet),
}

impl Rec {
    fn net_id(&self) -> [u8; 16] {
        match self {
            Rec::Net(r) => r.base.net_id,
            Rec::M(m) => m.net_id,
        }
    }
    fn netcfg(&self) -> &[u8] {
        match self {
            Rec::Net(r) => &r.base.netcfg,
            Rec::M(m) => &m.netcfg,
        }
    }
    fn members(&self) -> &[u8] {
        match self {
            Rec::Net(r) => &r.base.members,
            Rec::M(m) => &m.members,
        }
    }
    fn entry(&self, h: &[u8; 32]) -> Option<Member> {
        match self {
            Rec::Net(r) => r.list.as_ref()?.iter().find(|m| m.dac_pub_hash == *h).cloned(),
            Rec::M(m) => m.me.clone().filter(|x| x.dac_pub_hash == *h),
        }
    }
    /// this record with the node's entry replaced (in place), added, or removed
    fn with_entry(&self, h: &[u8; 32], e: Option<Member>) -> Rec {
        match self {
            Rec::Net(r) => {
                let mut r = r.clone();
                let l = r.list.get_or_insert_with(Vec::new);
                match (l.iter().position(|m| m.dac_pub_hash == *h), e) {
                    (Some(i), Some(e)) => l[i] = e,
                    (Some(i), None) => {
                        l.remove(i);
                    }
                    (None, Some(e)) => l.push(e),
                    (None, None) => {}
                }
                Rec::Net(r)
            }
            Rec::M(m) => Rec::M(MNet { me: e, ..m.clone() }),
        }
    }
}

pub struct Join2 {
    conn: Conn,
    /// the record as last written (or as read); its key 11 list is filled at the start
    rec: Option<Rec>,
    gen: u64,
    cfg: Option<NetCfg>,
    /// this node's entry (joining, no prev_country)
    me: Option<Member>,
    /// this node's entry when the flow started (an explicit country refusal puts it back)
    before: Option<Member>,
    secrets: Vec<u8>,
    pending: Option<Rec>,
    unverified: bool,
    resent: bool,
    /// info key 9 when the join ended applied through an info read (5 / 7 / other): the node may be behind (§3.5)
    node_version: Option<u64>,
    st: Step,
}

/// settings key 2: exactly two ASCII capital letters; anything else counts as unreadable (fail-closed)
fn country_of(b: &Value) -> Option<&str> {
    b.get(2).and_then(Value::as_text).filter(|c| c.len() == 2 && c.bytes().all(|x| x.is_ascii_uppercase()))
}

/// P2's answer to settings/get: E_UNSUPPORTED {1: "settings/get"} and no reason
fn is_p2(o: &Outcome) -> bool {
    matches!(o, Outcome::Err { code: flow::E_UNSUPPORTED, detail }
        if detail.get(1).and_then(Value::as_text) == Some("settings/get") && detail.get(2).is_none())
}

impl Join2 {
    pub fn start(conn: Conn, inp: Input) -> (Join2, Action) {
        let mut j = Join2 {
            conn,
            rec: None,
            gen: inp.record_gen,
            cfg: None,
            me: None,
            before: None,
            secrets: vec![],
            pending: None,
            unverified: false,
            resent: false,
            node_version: None,
            st: Step::Over,
        };
        let a = match j.begin(inp) {
            Ok(a) => a,
            Err(e) => Action::Done(e),
        };
        (j, a)
    }

    pub fn into_conn(self) -> Conn {
        self.conn
    }

    /// remove-member §3.5: the join ended applied but the node is at an older version than the record (it was
    /// already a member, reply 5): the caller sends the new secrets right away (updflow, the same session).
    pub fn node_behind(&self) -> bool {
        let cur = match self.rec.as_ref() {
            Some(Rec::Net(r)) => r.netcfg().ok().map(|c| c.version),
            Some(Rec::M(m)) => Some(m.version),
            None => None,
        };
        matches!((self.node_version, cur), (Some(n), Some(c)) if n < c as u64)
    }

    fn begin(&mut self, inp: Input) -> Result<Action, End> {
        if inp.member {
            return self.begin_member(inp);
        }
        let mut rec = netrec::decode(&inp.record_plain).map_err(|_| End::Refused(Pre::Record))?;
        let cfg = rec.netcfg().map_err(|_| End::Refused(Pre::Record))?;
        let list = rec.members().map_err(|_| End::Refused(Pre::Record))?;
        if rec.state != netrec::APPLIED {
            return Err(End::Refused(Pre::NotApplied));
        }
        let node = inp.node.ok_or(End::Refused(Pre::NotVerified))?;
        if !cfg.admins.contains(&inp.admin_pub) {
            return Err(End::Refused(Pre::NotAdmin));
        }
        let hash = netrec::dac_hash(&node.dac_pub);
        if list.iter().filter(|m| m.dac_pub_hash != hash).count() >= MAX_MEMBERS {
            return Err(End::Refused(Pre::Full));
        }
        // §2.0 rule 2: before the first SignAdmin and any write
        if !inp.removed_confirmed && rec.removed_ever().map_err(|_| End::Refused(Pre::Record))?.contains(&hash) {
            return Err(End::Refused(Pre::RemovedBefore));
        }
        self.before = list.iter().find(|m| m.dac_pub_hash == hash).cloned();
        self.me = Some(Member {
            dac_pub_hash: hash,
            ecdh_pub: node.ecdh_pub,
            name: inp.node_name,
            owner_pub: inp.owner_pub,
            owner_enc_pub: inp.owner_enc_pub,
            device_id: Some(node.device_id),
            state: MemberState::Joining,
            prev_country: None,
            known: None,
            mesh_addr: crate::teamview::gate(inp.mesh_addr),
        });
        rec.list = Some(list);
        self.rec = Some(Rec::Net(rec));
        self.cfg = Some(cfg);
        self.secrets_step(false)
    }

    /// member mode preconditions; then straight to the country step (the secrets are the approval's)
    fn begin_member(&mut self, inp: Input) -> Result<Action, End> {
        let m = MNet::decode(&inp.record_plain).map_err(|_| End::Refused(Pre::Record))?;
        let cfg = m.netcfg().map_err(|_| End::Refused(Pre::Record))?;
        let entry = m.me.clone().ok_or(End::Refused(Pre::NoEntry))?;
        let node = inp.node.ok_or(End::Refused(Pre::NotVerified))?;
        let hash = netrec::dac_hash(&node.dac_pub);
        let target = netrec::sign1_payload(&m.secrets).ok().and_then(|p| p.get(3).and_then(Value::as_bytes).map(<[u8]>::to_vec));
        if target.as_deref() != Some(&hash[..]) || entry.dac_pub_hash != hash {
            return Err(End::Refused(Pre::NotThisNode));
        }
        self.before = Some(entry.clone());
        self.me = Some(Member { state: MemberState::Joining, prev_country: None, ..entry });
        self.secrets = m.secrets.clone();
        self.rec = Some(Rec::M(m));
        self.cfg = Some(cfg);
        let r = self.request("settings/get", Value::Map(vec![]), Step::Get(Get::Check));
        r.ok_or_else(|| End::Broken("settings/get".into()))
    }

    fn member(&self) -> bool {
        matches!(self.rec, Some(Rec::M(_)))
    }

    /// step 2: net_secrets for THIS node, made afresh
    fn secrets_step(&mut self, resend: bool) -> Result<Action, End> {
        let (Some(Rec::Net(rec)), Some(cfg), Some(me)) = (&self.rec, &self.cfg, &self.me) else { return Err(End::Broken("no record".into())) };
        let mut plain = cbor::encode(&Value::Map(vec![
            (Value::Uint(1), Value::Text(rec.base.sae.clone())),
            (Value::Uint(2), Value::Bytes(rec.base.net_root.to_vec())),
        ]));
        let enc = cose::encrypt_to(&plain, cose::LABEL_SECRETS, &me.ecdh_pub, &me.dac_pub_hash, &cfg.net_id, cfg.version);
        plain.iter_mut().for_each(|b| *b = 0);
        let enc = enc.map_err(|e| End::Broken(format!("{e:?}")))?;
        let payload = cose::net_secrets_payload(&cfg.net_id, cfg.version, &me.dac_pub_hash, &enc.object);
        let tbs = cose::sign1_tbs(cose::CT_SECRETS, cose::LABEL_SECRETS, &payload);
        self.st = Step::Secrets { payload, resend };
        Ok(Action::SignAdmin { tbs })
    }

    fn end(&mut self, e: End) -> Option<Action> {
        self.st = Step::Over;
        Some(Action::Done(e))
    }

    fn done(&mut self, r: Result<Action, End>) -> Option<Action> {
        match r {
            Ok(a) => Some(a),
            Err(e) => self.end(e),
        }
    }

    fn want(&self) -> String {
        self.cfg.as_ref().map(|c| c.country.clone()).unwrap_or_default()
    }

    /// this node's entry in the record as last written
    fn entry(&self) -> Option<Member> {
        let h = self.me.as_ref()?.dac_pub_hash;
        self.rec.as_ref()?.entry(&h)
    }

    /// the record with this node's entry replaced (in place), added, or removed
    fn with_entry(&self, e: Option<Member>) -> Option<Rec> {
        let h = self.me.as_ref()?.dac_pub_hash;
        Some(self.rec.as_ref()?.with_entry(&h, e))
    }

    fn persist(&mut self, rec: Option<Rec>, then: Then) -> Option<Action> {
        let Some(rec) = rec else { return self.end(End::Broken("no record".into())) };
        let a = match &rec {
            Rec::Net(r) => Action::PersistNet { net_id: r.base.net_id, plain: netrec::encode(r), expected_gen: self.gen },
            Rec::M(m) => Action::PersistMnet { net_id: m.net_id, plain: m.encode(), expected_gen: self.gen },
        };
        self.pending = Some(rec);
        self.st = Step::Persist(then);
        Some(a)
    }

    /// steps 3 / 4: the entry joining, its prev_country kept (or `prev` when there is none yet)
    fn persist_joining(&mut self, prev: Option<String>, then: Then) -> Option<Action> {
        let mut e = self.me.clone()?;
        e.prev_country = self.entry().and_then(|x| x.prev_country).or(prev);
        let r = self.with_entry(Some(e));
        self.persist(r, then)
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

    fn ask_nonce(&mut self, op: Op) -> Option<Action> {
        self.request("op/nonce", Value::Map(vec![]), Step::Nonce(op))
    }

    fn info(&mut self, why: InfoFor) -> Option<Action> {
        self.request("info", Value::Map(vec![]), Step::Info(why))
    }

    fn op_body(&self, op: &Op) -> Result<(&'static str, Value), String> {
        Ok(match op {
            Op::SetCountry => ("settings/set", Value::Map(vec![(Value::Uint(2), Value::Text(self.want()))])),
            Op::Revert(_) => {
                let was = self.entry().and_then(|e| e.prev_country).ok_or("no prev_country")?;
                ("settings/set", Value::Map(vec![(Value::Uint(2), Value::Text(was))]))
            }
            Op::Join => {
                let rec = self.rec.as_ref().ok_or("no record")?;
                ("network/join", join_body(rec.netcfg(), rec.members(), &self.secrets).map_err(|e| format!("{e:?}"))?)
            }
        })
    }

    /// a definite failure (4 / another network / not applied / not sent): put the country back first; the entry goes
    /// only when that worked (or there was nothing to put back)
    fn fail(&mut self, f: Fail) -> Option<Action> {
        match self.entry().and_then(|e| e.prev_country) {
            Some(_) => self.request("settings/get", Value::Map(vec![]), Step::Get(Get::Revert(f))),
            None => {
                let r = self.with_entry(self.after_fail(&f));
                self.persist(r, Then::End(End::Failed(f, Revert::NoChange)))
            }
        }
    }

    /// this node's entry after a definite failure whose country is the original: none — except when network/join
    /// was never sent (NotSent): then the entry this flow replaced (e.g. an applied one) comes back
    fn after_fail(&self, f: &Fail) -> Option<Member> {
        match f {
            Fail::NotSent(_) => self.before.clone().map(|mut b| {
                b.prev_country = None;
                b
            }),
            _ => None,
        }
    }

    fn not_reverted(&self, f: Fail) -> End {
        let was = self.entry().and_then(|e| e.prev_country).unwrap_or_default();
        End::Failed(f, Revert::NotReverted { now: self.want(), was })
    }

    fn reverted(&mut self, f: Fail) -> Option<Action> {
        let country = self.entry().and_then(|e| e.prev_country).unwrap_or_default();
        let r = self.with_entry(self.after_fail(&f));
        self.persist(r, Then::End(End::Failed(f, Revert::Reverted { country })))
    }

    fn applied(&mut self, save_pending: bool) -> Option<Action> {
        let mut e = self.me.clone()?;
        e.state = MemberState::Applied;
        let r = self.with_entry(Some(e));
        self.persist(r, Then::Applied { save_pending })
    }

    /// The platform's DER signature for the last SignAdmin / SignOwner (empty or bad = it failed: stop).
    pub fn signed(&mut self, der: &[u8]) -> Option<Action> {
        if !matches!(self.st, Step::Secrets { .. } | Step::Owner { .. }) {
            return None;
        }
        let s = match sig::der_to_raw_low_s(der) {
            Ok(s) => s,
            Err(_) if matches!(self.st, Step::Secrets { resend: false, .. }) => return self.end(End::AdminSignFailed),
            // the resend after 3: the entry (and maybe the country) changed already -> unclear, keep joining
            Err(_) if matches!(self.st, Step::Secrets { resend: true, .. }) => return self.end(End::Joining(Keep::Unclear)),
            // an owner-op signature failed (settings.set / network/join / put back not sent): the entry and its
            // prev_country stay as written -> unclear, "繼續加入"
            Err(_) if matches!(self.st, Step::Owner { .. }) => return self.end(End::Joining(Keep::Unclear)),
            Err(e) => return self.end(End::Broken(format!("{e:?}"))),
        };
        match std::mem::replace(&mut self.st, Step::Over) {
            Step::Secrets { payload, resend } => {
                self.secrets = cose::sign1(cose::CT_SECRETS, &payload, &s);
                if resend {
                    self.ask_nonce(Op::Join)
                } else {
                    self.request("settings/get", Value::Map(vec![]), Step::Get(Get::Check))
                }
            }
            Step::Owner { op, body } => {
                let verb = match op {
                    Op::Join => "network/join",
                    _ => "settings/set",
                };
                match sig::with_owner_op(&body, verb, &s) {
                    Ok(full) => self.request(verb, full, Step::Reply(op)),
                    Err(e) => self.end(End::Broken(format!("{e:?}"))),
                }
            }
            _ => None,
        }
    }

    /// The user's answer to ConfirmCountry.
    pub fn country_confirmed(&mut self, yes: bool) -> Option<Action> {
        let Step::Confirm { have } = std::mem::replace(&mut self.st, Step::Over) else { return None };
        if !yes {
            let want = self.want();
            return self.end(End::Declined { have, want });
        }
        self.persist_joining(Some(have), Then::SetCountry)
    }

    /// The caller wrote the last PersistNet (write_cas succeeded).
    pub fn net_persisted(&mut self) -> Option<Action> {
        let Step::Persist(then) = std::mem::replace(&mut self.st, Step::Over) else { return None };
        self.rec = self.pending.take();
        self.gen += 1;
        match then {
            Then::SetCountry => self.ask_nonce(Op::SetCountry),
            Then::Join => self.ask_nonce(Op::Join),
            Then::Applied { save_pending } => {
                let u = self.unverified;
                self.end(End::Applied { country_unverified: u, save_pending })
            }
            Then::End(e) => self.end(e),
        }
    }

    /// The last PersistNet's write failed: stop, nothing more is sent. `error` None = write_cas found another
    /// generation (the record changed elsewhere); Some = any other failure (sealing, storage), for the text.
    pub fn persist_failed(&mut self, error: Option<String>) -> Option<Action> {
        let Step::Persist(then) = std::mem::replace(&mut self.st, Step::Over) else { return None };
        self.pending = None;
        self.end(End::PersistFailed { applied: matches!(then, Then::Applied { .. }), error })
    }

    pub fn on_frame(&mut self, f: &[u8]) -> Option<Action> {
        if !matches!(self.st, Step::Get(_) | Step::Nonce(_) | Step::Reply(_) | Step::Info(_)) {
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
            Step::Get(g) => self.on_get(g, o),
            Step::Nonce(op) => self.on_nonce(op, o),
            Step::Reply(op) => self.on_reply(op, o),
            Step::Info(why) => self.on_info(why, o),
            _ => None,
        }
    }

    fn on_get(&mut self, g: Get, o: Outcome) -> Option<Action> {
        let want = self.want();
        let have = match &o {
            Outcome::Ok(b) => country_of(b).map(str::to_string),
            Outcome::Err { .. } => None,
        };
        match g {
            Get::Check => match (have, is_p2(&o)) {
                (Some(c), _) if c == want => self.persist_joining(None, Then::Join),
                (Some(c), _) => {
                    self.st = Step::Confirm { have: c.clone() };
                    Some(Action::ConfirmCountry { have: c, want })
                }
                (None, true) => {
                    self.unverified = true;
                    self.persist_joining(None, Then::Join)
                }
                (None, false) => self.end(End::SettingsError(o)),
            },
            Get::AfterSet => match have {
                Some(c) if c == want => self.persist_joining(None, Then::Join),
                _ => self.end(End::Joining(Keep::CountryUnknown)),
            },
            Get::Revert(f) => {
                let was = self.entry().and_then(|e| e.prev_country);
                match have {
                    Some(c) if Some(&c) == was.as_ref() => self.reverted(f),
                    Some(_) => self.ask_nonce(Op::Revert(f)),
                    None => {
                        let e = self.not_reverted(f);
                        self.end(e)
                    }
                }
            }
        }
    }

    fn on_nonce(&mut self, op: Op, o: Outcome) -> Option<Action> {
        let helper: Option<[u8; 32]> = match &o {
            Outcome::Ok(b) => b.get(1).and_then(Value::as_bytes).and_then(|n| n.try_into().ok()),
            Outcome::Err { code, .. } => {
                // nothing went out: the operation was not sent
                return match op {
                    // settings.set never went out: the entry goes back to what it was (as for reason 14 / 20)
                    Op::SetCountry => {
                        let b = self.before.clone();
                        let rec = self.with_entry(b);
                        self.persist(rec, Then::End(End::Joining(Keep::NonceRefused(*code))))
                    }
                    // 7 = busy (provd still waiting for a previous helper call, possibly our earlier join): the outcome
                    // is unknown -> keep the entry and prev_country (§3.3-6)
                    Op::Join if *code == 7 => self.end(End::Joining(Keep::Unclear7)),
                    // network/join never went out: a definite failure, the country goes back
                    Op::Join => self.fail(Fail::NotSent(*code)),
                    Op::Revert(f) => {
                        let e = self.not_reverted(f);
                        self.end(e)
                    }
                };
            }
        };
        let Some(helper) = helper else { return self.end(End::Broken("op/nonce without a 32-byte nonce".into())) };
        let (verb, body) = match self.op_body(&op) {
            Ok(x) => x,
            Err(e) => return self.end(End::Broken(e)),
        };
        match sig::owner_op_input(&self.conn.h(), &helper, verb, &body) {
            Ok(input) => {
                self.st = Step::Owner { op, body };
                Some(Action::SignOwner { input })
            }
            Err(e) => self.end(End::Broken(format!("{e:?}"))),
        }
    }

    fn on_reply(&mut self, op: Op, o: Outcome) -> Option<Action> {
        match (op, o) {
            (Op::SetCountry, Outcome::Ok(_)) => self.persist_joining(None, Then::Join),
            (Op::SetCountry, Outcome::Err { code, detail }) => match detail.get(2).and_then(Value::as_uint) {
                // refused before the radio was touched: the entry goes back to what it was before this flow wrote it
                Some(r @ (REASON_IN_NETWORK | REASON_LEGACY)) => {
                    let b = self.before.clone();
                    let rec = self.with_entry(b);
                    self.persist(rec, Then::End(End::CountryRefused { code, reason: r }))
                }
                // anything else may have changed the radio: read what it is now
                _ => self.request("settings/get", Value::Map(vec![]), Step::Get(Get::AfterSet)),
            },
            (Op::Revert(f), Outcome::Ok(_)) => self.reverted(f),
            (Op::Revert(f), Outcome::Err { .. }) => {
                let e = self.not_reverted(f);
                self.end(e)
            }
            (Op::Join, Outcome::Ok(_)) => self.applied(false),
            (Op::Join, Outcome::Err { code, .. }) => match code {
                // member mode: the same secrets once more (they are the approval's); admin: made afresh
                flow::E_FORBIDDEN if !self.resent && self.member() => {
                    self.resent = true;
                    self.ask_nonce(Op::Join)
                }
                flow::E_FORBIDDEN if !self.resent => {
                    self.resent = true;
                    let r = self.secrets_step(true);
                    self.done(r)
                }
                flow::E_FORBIDDEN => self.end(End::Joining(Keep::TwiceRefused)),
                flow::E_BAD_OBJECT => self.fail(Fail::Rejected),
                5 => self.info(InfoFor::After5),
                7 => self.info(InfoFor::After7),
                c => self.info(InfoFor::Other(c)),
            },
        }
    }

    fn on_info(&mut self, why: InfoFor, o: Outcome) -> Option<Action> {
        let net_id = self.rec.as_ref()?.net_id();
        let s = match &o {
            Outcome::Ok(b) => flow::join_state(b, &net_id),
            Outcome::Err { .. } => JoinState::Unknown,
        };
        if let (JoinState::Applied { .. }, Outcome::Ok(b)) = (&s, &o) {
            self.node_version = b.get(9).and_then(Value::as_uint);
        }
        match (s, why) {
            (JoinState::Applied { save_pending }, _) => self.applied(save_pending),
            (_, InfoFor::After7) => self.end(End::Joining(Keep::Unclear7)),
            (JoinState::OtherNetwork, _) => self.fail(Fail::OtherNetwork),
            (JoinState::NotApplied, InfoFor::Other(c)) => self.fail(Fail::NotApplied(c)),
            _ => self.end(End::Joining(Keep::Unclear)),
        }
    }
}
