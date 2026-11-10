//! Remote invites for Dart (254-app-member-join v6.1 §4), the parts that need no node: the admin's invite / check /
//! approve on its net record, the joiner's invite reading and approval import. Dev / bench only (§5-5): every entry
//! the map lists refuses unless this library was built with `dev-trust` (§2 dev gate). Records cross into Dart only to
//! be sealed by Kotlin; nothing secret is ever part of a text.

use batman_proto::approve::{self, ApproveFlow, Prepared};
use batman_proto::invite::{self, Action, End, Error, InviteFlow};
use batman_proto::mrec::{self, MNet};
use batman_proto::netrec::{self, MemberState};
use batman_proto::nodecert::{self, hex_lower};

use super::owner::{persist_at, OwnerKind, OwnerStep, STALE_RECORD};

pub(crate) const DEV_ONLY: &str = "遠端邀請只限開發版";

/// §2 dev gate: the bridge entries of remote invites refuse in a library built without `dev-trust`.
pub(crate) fn dev_gate() -> Result<(), String> {
    if nodecert::DEV_TRUST {
        Ok(())
    } else {
        Err(DEV_ONLY.into())
    }
}

/// Why something of a remote invite stopped, in words (codes / reasons only, never a secret).
pub(crate) fn invite_err(e: &Error) -> String {
    match e {
        Error::Format(w) => format!("這不是正確的碼（{w}）"),
        Error::Invalid(w) => format!("內容驗證沒有通過（{w}）"),
        Error::NotApplied => "這個網路還沒確認建立完成，請先在建立網路的節點按「確認網路」".into(),
        Error::NotAdmin => "這個網路不是這支手機建立的（手機不是它的管理者）".into(),
        Error::Full => format!("這個網路已經有 {} 台節點（App 目前的上限）", netrec::MAX_MEMBERS),
        Error::Name => format!("名稱太長（最多 {} 個位元組）或含有不能顯示的字元", invite::NAME_MAX),
        Error::NodeCert(c) => format!("申請裡的節點身分沒有通過檢查（{c:?}）"),
        Error::NoNodeCert => "這次連線沒有驗證過節點身分，請重新連線".into(),
        Error::UnknownInvite => "這份申請不是回覆這個網路發出的邀請".into(),
        // remove-member §3.6: a removal makes every unused invite used too
        Error::InviteUsed => "這張邀請已用過或已作廢，請重新邀請".into(),
        Error::DuplicateInvite => "邀請重複了，請再按一次".into(),
        Error::AlreadyMember => "這台節點已經在這個網路的紀錄裡（屬於其他擁有者或已加入）".into(),
        Error::HashMismatch => "申請和剛才核對的不是同一份，請重新貼上".into(),
        Error::NeedsConfirm => "這台節點（或這個人）之前被移出過，要先確認才能同意".into(),
        // remove-member §3.4: an approval pasted after a newer update (its secrets are not the stored ones any more)
        Error::NoRequest => "找不到這個網路的申請（若你已匯入較新的更新包：這份同意已經過時）".into(),
        Error::TooOld => "這支手機的網路資料太舊".into(),
        Error::SameVersionDifferent => "同編號的不同網路（若這份同意在換密碼前產生：請網主重新邀請這台）".into(),
        Error::PreviousNode => "先完成或忘記前一台".into(),
        Error::Stale => "申請已換新，請重新貼上同意碼".into(),
        Error::SasMismatch => "確認碼不符，沒有匯入".into(),
        Error::Aead => "解不開（不是給這支手機的）".into(),
        Error::Broken(w) => format!("中斷（{w}）"),
    }
}

/// What a pasted invite says (§4 step 2).
pub struct InviteView {
    pub net_name: String,
    pub net_id_hex: String,
    pub invite_hash_hex: String,
}

#[flutter_rust_bridge::frb(sync)]
pub fn parse_invite(hex: String) -> Result<InviteView, String> {
    dev_gate()?;
    let o = invite::open_invite(&invite::qr_object(&hex, invite::QR_INVITE).map_err(|e| invite_err(&e))?).map_err(|e| invite_err(&e))?;
    Ok(InviteView { net_name: invite::display_name(&o.cfg.name), net_id_hex: hex_lower(&o.net_id), invite_hash_hex: hex_lower(&o.hash) })
}

/// What a pasted join request says, after every check (§4 step 5); `joinreq_hash` binds the approval to it.
pub struct JoinReqView {
    pub sas: String,
    pub name: String,
    /// the device id's last 6
    pub device_suffix: String,
    pub replaces_approved: bool,
    pub joinreq_hash: String,
    /// remove-member §3.6: "" or the question to confirm before approving (removed before) — `approve` then needs
    /// `previous_confirmed`
    pub previous: String,
    /// the person still lacks a version: 「請他先貼更新包，再貼這份同意」
    pub update_first: bool,
}

#[flutter_rust_bridge::frb(sync)]
pub fn net_check_joinreq(record_plain: Vec<u8>, hex: String) -> Result<JoinReqView, String> {
    dev_gate()?;
    let rec = netrec::decode(&record_plain).map_err(|_| "手機裡的網路資料損壞".to_string())?;
    let jr = invite::qr_object(&hex, invite::QR_JOINREQ).map_err(|e| invite_err(&e))?;
    let c = approve::check_joinreq(&rec, &jr).map_err(|e| invite_err(&e))?;
    let d = &c.jr.node.device_id;
    let previous = match &c.previous {
        None => String::new(),
        Some(p) => {
            let who = match (&p.owner_name, &p.owner_pub) {
                (Some(n), Some(o)) => format!("{}（{}）", invite::display_name(n), super::rekey::fpr(o)),
                _ => "不明".into(),
            };
            let what = if p.node { format!("這台節點（…{}）之前被排除（遺失 / 被抓）", &d[d.len().saturating_sub(4)..]) } else { "申請的人之前被移出過這個網路（換了一台節點來申請）".into() };
            format!("{what}，確定要讓它回來嗎？之前的擁有者：{who}")
        }
    };
    Ok(JoinReqView {
        sas: c.sas,
        name: c.jr.name,
        device_suffix: d[d.len().saturating_sub(6)..].to_string(),
        replaces_approved: c.replaces_approved,
        joinreq_hash: hex_lower(&c.jr.hash),
        previous,
        update_first: c.update_first,
    })
}

fn hash32(s: &str) -> Result<[u8; 32], String> {
    invite::from_hex(s).ok().and_then(|b| b.try_into().ok()).ok_or_else(|| "App 內部錯誤（hash is not 32 bytes of hex）".to_string())
}

fn key65(b: Vec<u8>) -> Result<[u8; 65], String> {
    b.try_into().map_err(|_| "手機金鑰格式不對（not 65 bytes）".to_string())
}

enum Op {
    Invite(InviteFlow),
    Approve(ApproveFlow),
}

/// An admin operation on a net record (§4 steps 1 and 6): SignAdmin -> PersistNet -> the hex. Only a landed record
/// write gives the hex.
#[flutter_rust_bridge::frb(opaque)]
pub struct NetOp {
    op: Op,
}

fn op_step(a: Option<Action>, what: &str) -> Option<OwnerStep> {
    Some(match a? {
        Action::SignAdmin { tbs } => OwnerStep { sign_input: tbs, ..OwnerStep::new(OwnerKind::SignAdmin) },
        Action::SignOwner { input } => OwnerStep { sign_input: input, ..OwnerStep::new(OwnerKind::Sign) },
        Action::Persist { rel, plain, expected_gen } => persist_at(OwnerKind::PersistNet, rel, plain, expected_gen),
        Action::Done(End::Out { hex, .. }) => {
            let t = match what {
                "invite" => "[INVITE] 邀請已建立，已複製到剪貼簿，請傳給隊員",
                _ => "[APPROVED] 已同意，同意碼已複製到剪貼簿，請傳回給隊員",
            };
            OwnerStep { hex, ..OwnerStep::text(OwnerKind::Answer, t.into()) }
        }
        Action::Done(End::Refused(e)) => OwnerStep::text(OwnerKind::Answer, format!("[REQ_FAIL] {}沒有成功：{}", if what == "invite" { "邀請" } else { "同意" }, invite_err(&e))),
        Action::Done(End::PersistFailed(e)) => {
            let why = e.map_or(STALE_RECORD.to_string(), |x| format!("手機儲存失敗（{x}）"));
            OwnerStep::text(OwnerKind::Answer, format!("[REQ_FAIL] {why}（沒有產生任何碼）"))
        }
    })
}

impl NetOp {
    /// §4 step 1: a remote invite from this (applied) net record; `admin_pub` = this phone's admin key.
    #[flutter_rust_bridge::frb(sync)]
    pub fn make_invite(record_plain: Vec<u8>, record_gen: u64, admin_pub: Vec<u8>) -> Result<(NetOp, OwnerStep), String> {
        dev_gate()?;
        let (f, a) = InviteFlow::start(&record_plain, record_gen, &key65(admin_pub)?);
        let st = op_step(Some(a), "invite").ok_or("App 內部錯誤（no first step）")?;
        Ok((NetOp { op: Op::Invite(f) }, st))
    }

    /// §4 step 6: approve the join request the admin checked (`joinreq_hash` from net_check_joinreq);
    /// `previous_confirmed`: the user answered yes to JoinReqView.previous (remove-member §3.6).
    #[flutter_rust_bridge::frb(sync)]
    pub fn approve(record_plain: Vec<u8>, record_gen: u64, hex: String, joinreq_hash: String, admin_pub: Vec<u8>, previous_confirmed: bool) -> Result<(NetOp, OwnerStep), String> {
        dev_gate()?;
        let (f, a) = ApproveFlow::start(&record_plain, record_gen, &hex, &hash32(&joinreq_hash)?, &key65(admin_pub)?, previous_confirmed);
        let st = op_step(Some(a), "approve").ok_or("App 內部錯誤（no first step）")?;
        Ok((NetOp { op: Op::Approve(f) }, st))
    }

    fn what(&self) -> &'static str {
        match self.op {
            Op::Invite(_) => "invite",
            Op::Approve(_) => "approve",
        }
    }

    #[flutter_rust_bridge::frb(sync)]
    pub fn signed(&mut self, der: Vec<u8>) -> Option<OwnerStep> {
        let w = self.what();
        let a = match &mut self.op {
            Op::Invite(f) => f.signed(&der),
            Op::Approve(f) => f.signed(&der),
        };
        op_step(a, w)
    }

    /// The record (store_write_cas) landed: the hex is handed out.
    #[flutter_rust_bridge::frb(sync)]
    pub fn net_persisted(&mut self) -> Option<OwnerStep> {
        let w = self.what();
        let a = match &mut self.op {
            Op::Invite(f) => f.persisted(),
            Op::Approve(f) => f.persisted(),
        };
        op_step(a, w)
    }

    /// The record write failed (`error` = store_write_cas's text): no hex.
    #[flutter_rust_bridge::frb(sync)]
    pub fn persist_failed(&mut self, error: String) -> Option<OwnerStep> {
        let w = self.what();
        let e = (error != STALE_RECORD).then_some(error);
        let a = match &mut self.op {
            Op::Invite(f) => f.persist_failed(e),
            Op::Approve(f) => f.persist_failed(e),
        };
        op_step(a, w)
    }
}

/// §4 step 7a, first move: which network an approval names (parsed only, never trusted: it only picks the files
/// `mpend/<id>` and `mnet/<id>` to read; lowercase hex).
#[flutter_rust_bridge::frb(sync)]
pub fn approval_net_id(hex: String) -> Result<String, String> {
    approve::approval_net_id(&hex).map_err(|e| invite_err(&e))
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ImportState {
    /// show `sas` (and the R22 line) and wait for the user; then Kotlin ecdh(eph_pub) and member_import_approval
    Ready,
    AlreadyImported,
    NeedsNewInvite,
    /// remove-member §3.6-2: ask `detail` (replace the stored network?); yes = member_import_prepare again with
    /// `replace`
    Replace,
}

pub struct ImportPrep {
    pub state: ImportState,
    pub sas: String,
    pub eph_pub: Vec<u8>,
    pub pend_gen: u64,
    pub detail: String,
}

/// §4 step 7a: the approval checked against this network's pending request (mpend, read at `pend_gen`) and its
/// stored network (mnet), everything but the ECDH / AEAD.
#[flutter_rust_bridge::frb(sync)]
pub fn member_import_prepare(hex: String, pend_gen: u64, pend_plain: Option<Vec<u8>>, mnet_plain: Option<Vec<u8>>, replace: bool) -> Result<ImportPrep, String> {
    dev_gate()?;
    let r = approve::prepare_import(&hex, pend_plain.as_deref().map(|p| (pend_gen, p)), mnet_plain.as_deref(), replace).map_err(|e| invite_err(&e))?;
    Ok(match r {
        Prepared::Replace { stored } => ImportPrep {
            state: ImportState::Replace,
            sas: String::new(),
            eph_pub: vec![],
            pend_gen,
            detail: format!("這支手機有這個網路的舊紀錄（v{stored}），要換成新的嗎？（若你手上還有網主給的更新包，先貼更新包）"),
        },
        Prepared::Ready { sas, eph_pub, pend_gen } => ImportPrep { state: ImportState::Ready, sas, eph_pub: eph_pub.to_vec(), pend_gen, detail: String::new() },
        Prepared::AlreadyImported => ImportPrep { state: ImportState::AlreadyImported, sas: String::new(), eph_pub: vec![], pend_gen, detail: "[IMPORT] 已匯入過了".into() },
        Prepared::NeedsNewInvite => ImportPrep { state: ImportState::NeedsNewInvite, sas: String::new(), eph_pub: vec![], pend_gen, detail: "[IMPORT] 需要新的邀請".into() },
    })
}

/// §4 step 7c: after the user pressed the confirm button on the SAS screen (`confirmed_sas` = the string shown),
/// with Kotlin's ECDH `z`: everything again (the mpend generation must still be `expected_pend_gen`), then the new
/// mnet as a PersistMnet step (write_cas from the mnet generation read; then remove mpend). `detail` = the line to
/// show once written. z is cleared here; it never reaches a text.
#[flutter_rust_bridge::frb(sync)]
#[allow(clippy::too_many_arguments)]
pub fn member_import_approval(
    hex: String,
    pend_gen: u64,
    pend_plain: Vec<u8>,
    expected_pend_gen: u64,
    mnet_plain: Option<Vec<u8>>,
    mnet_gen: u64,
    mut z: Vec<u8>,
    confirmed_sas: String,
    replace: bool,
) -> Result<OwnerStep, String> {
    dev_gate()?;
    let zz: Option<[u8; 32]> = z.as_slice().try_into().ok();
    z.iter_mut().for_each(|b| *b = 0);
    let mut zz = zz.ok_or("App 內部錯誤（z is not 32 bytes）")?;
    let r = approve::import(&hex, (pend_gen, &pend_plain), expected_pend_gen, mnet_plain.as_deref().map(|p| (p, mnet_gen)), &zz, &confirmed_sas, replace);
    zz.iter_mut().for_each(|b| *b = 0);
    let (plain, net_id, expected) = r.map_err(|e| invite_err(&e))?;
    let name = MNet::decode(&plain).ok().and_then(|m| m.netcfg().ok()).map(|c| invite::display_name(&c.name)).unwrap_or_default();
    let mut st = persist_at(OwnerKind::PersistMnet, mrec::mnet_path(&net_id), plain, expected);
    st.detail = format!("[IMPORT] 已匯入網路「{name}」，可以登入自己的節點按「加入隊伍網路」");
    Ok(st)
}

/// "Show the request again" (§3): the hex and SAS from the pending request (Answer with hex / sas).
#[flutter_rust_bridge::frb(sync)]
pub fn member_pend_view(pend_plain: Vec<u8>) -> Result<OwnerStep, String> {
    dev_gate()?;
    match invite::pend_view(&pend_plain).map_err(|e| invite_err(&e))? {
        End::Out { hex, sas, name, .. } => Ok(OwnerStep { hex, sas, ..OwnerStep::text(OwnerKind::Answer, format!("[JOINREQ] 申請（名稱「{name}」）")) }),
        _ => Err("App 內部錯誤".into()),
    }
}

/// A member's stored network, for the screen (no secret).
pub struct MnetView {
    pub net_id: String,
    pub net_name: String,
    /// "" = no own-node entry (a new invite is needed), else joining / applied
    pub entry_state: String,
    pub device_last4: String,
}

#[flutter_rust_bridge::frb(sync)]
pub fn mnet_summary(mnet_plain: Vec<u8>) -> Result<MnetView, String> {
    let m = MNet::decode(&mnet_plain).map_err(|_| "手機裡的網路資料損壞".to_string())?;
    let name = m.netcfg().map(|c| c.name).unwrap_or_default();
    let (state, last4) = match &m.me {
        Some(e) => (
            match e.state {
                MemberState::Joining => "joining",
                MemberState::Applied => "applied",
                MemberState::Approved => "approved",
            },
            e.device_id.as_deref().map(|d| d[d.len().saturating_sub(4)..].to_string()).unwrap_or_default(),
        ),
        None => ("", String::new()),
    };
    Ok(MnetView { net_id: hex_lower(&m.net_id), net_name: invite::display_name(&name), entry_state: state.into(), device_last4: last4 })
}

/// The member phone's pending join requests (file names under mpend/: the net ids; no record opened), for "show
/// the request again" after a restart.
pub fn list_pends(dir: String) -> Vec<String> {
    let mut v: Vec<String> = std::fs::read_dir(std::path::Path::new(&dir).join("mpend"))
        .map(|d| d.filter_map(|e| e.ok()).map(|e| e.file_name().to_string_lossy().to_string()).filter(|n| !n.starts_with('.')).collect())
        .unwrap_or_default();
    v.sort();
    v
}

/// The member phone's stored networks (file names under mnet/; no record opened).
pub fn list_mnets(dir: String) -> Vec<String> {
    let mut v: Vec<String> = std::fs::read_dir(std::path::Path::new(&dir).join("mnet"))
        .map(|d| d.filter_map(|e| e.ok()).map(|e| e.file_name().to_string_lossy().to_string()).filter(|n| !n.starts_with('.')).collect())
        .unwrap_or_default();
    v.sort();
    v
}

#[cfg(test)]
mod tests {
    use super::*;

    /// M14: built without `dev-trust`, every remote-invite entry of §2 refuses before doing anything (no file).
    #[cfg(not(feature = "dev-trust"))]
    #[test]
    fn m14_every_entry_refuses_without_dev_trust() {
        use crate::api::owner::OwnerSession;
        let refused = |r: Result<(), String>, what: &str| assert_eq!(r, Err(DEV_ONLY.to_string()), "{what}");
        refused(parse_invite("a201".into()).map(|_| ()), "parse_invite");
        refused(net_check_joinreq(vec![0xa0], "a2".into()).map(|_| ()), "net_check_joinreq");
        refused(NetOp::make_invite(vec![0xa0], 1, vec![4; 65]).map(|_| ()), "net_make_invite");
        refused(NetOp::approve(vec![0xa0], 1, "a2".into(), "00".repeat(32), vec![4; 65], false).map(|_| ()), "net_approve");
        refused(member_import_prepare("a2".into(), 1, Some(vec![0xa0]), None, false).map(|_| ()), "member_import_prepare");
        refused(member_import_approval("a2".into(), 1, vec![0xa0], 1, None, 0, vec![0; 32], "000000".into(), false).map(|_| ()), "member_import_approval");
        refused(member_pend_view(vec![0xa0]).map(|_| ()), "member_pend_view");
        // the session entries: a session that has not even logged in still answers the gate first
        let rec = batman_proto::cbor::encode(&batman_proto::cbor::Value::Map(vec![
            (batman_proto::cbor::Value::Uint(1), batman_proto::cbor::Value::Text("e61551410cfd538e24".into())),
            (batman_proto::cbor::Value::Uint(4), batman_proto::cbor::Value::Bytes(vec![8; 5])),
            (batman_proto::cbor::Value::Uint(5), batman_proto::cbor::Value::Bytes(vec![5; 32])),
        ]));
        let (mut s, _) = OwnerSession::start(rec, vec![4; 65], 244).unwrap();
        refused(s.request_joinreq("a2".into(), "x".into(), 0, None, vec![4; 65]).map(|_| ()), "request_joinreq");
        refused(s.request_member_join(vec![0xa0], 1).map(|_| ()), "request_member_join");
    }

    #[cfg(feature = "dev-trust")]
    #[test]
    fn entries_work_past_the_gate_in_a_dev_build() {
        // past the gate: the answer is about the input, not the build
        assert!(parse_invite("zz".into()).err().unwrap().starts_with("這不是正確的碼"));
        assert_eq!(member_import_prepare("a2".into(), 1, None, None, false).err().map(|e| e.starts_with("這不是正確的碼")), Some(true));
    }

    #[test]
    fn every_refusal_has_words() {
        for e in [Error::Format("x"), Error::Invalid("x"), Error::NotApplied, Error::NotAdmin, Error::Full, Error::Name, Error::NoNodeCert, Error::UnknownInvite, Error::InviteUsed, Error::DuplicateInvite, Error::AlreadyMember, Error::HashMismatch, Error::NeedsConfirm, Error::NoRequest, Error::TooOld, Error::SameVersionDifferent, Error::PreviousNode, Error::Stale, Error::SasMismatch, Error::Aead] {
            assert!(!invite_err(&e).is_empty());
        }
        assert_eq!(invite_err(&Error::TooOld), "這支手機的網路資料太舊");
        assert!(invite_err(&Error::SameVersionDifferent).starts_with("同編號的不同網路"));
        assert_eq!(invite_err(&Error::PreviousNode), "先完成或忘記前一台");
    }

    #[test]
    fn mnet_summary_shows_no_secret() {
        let m = MNet { net_id: [0xab; 16], version: 1, netcfg: vec![], members: vec![], secrets: vec![], net_root: [0x5e; 32], me: None, invite_hash: [0; 32], versions: None, node_secrets: vec![] };
        let v = mnet_summary(m.encode()).unwrap();
        assert_eq!((v.net_id.as_str(), v.entry_state.as_str()), ("ab".repeat(16).as_str(), ""));
        assert!(!format!("{} {} {}", v.net_id, v.net_name, v.device_last4).contains(&"5e".repeat(32)));
    }
}

#[cfg(test)]
mod review_tests {
    use super::*;

    #[test]
    fn pending_requests_are_listed_after_a_restart() {
        let d = std::env::temp_dir().join(format!("bm-pends-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&d);
        let dir = d.to_string_lossy().to_string();
        assert!(list_pends(dir.clone()).is_empty());
        batman_proto::store::Store::new(&d).write("mpend/ab", 1, b"s").unwrap();
        batman_proto::store::Store::new(&d).write("mnet/cd", 1, b"s").unwrap();
        assert_eq!(list_pends(dir.clone()), vec!["ab".to_string()]);
        assert_eq!(list_mnets(dir), vec!["cd".to_string()]);
        let _ = std::fs::remove_dir_all(d);
    }

    #[cfg(feature = "dev-trust")]
    #[test]
    fn non_ascii_paste_is_an_error_not_a_panic() {
        for t in ["aéb", "a201é0"] {
            assert!(parse_invite(t.into()).err().unwrap().starts_with("這不是正確的碼"), "{t}");
            assert!(approval_net_id(t.into()).is_err(), "{t}");
        }
    }
}

#[cfg(test)]
mod review2_tests {
    use super::*;

    #[test]
    fn network_names_are_shown_filtered() {
        use batman_proto::cose;
        let cfg = cose::sign1(cose::CT_NETCFG, &cose::net_config_payload(&[0xab; 16], 1, None, "家\u{202E}裡\n網", "US", "m", 40, 4, &[[4; 65]]), &[1; 64]);
        let m = MNet { net_id: [0xab; 16], version: 1, netcfg: cfg, members: vec![], secrets: vec![], net_root: [0; 32], me: None, invite_hash: [0; 32], versions: None, node_secrets: vec![] };
        assert_eq!(mnet_summary(m.encode()).unwrap().net_name, "家\u{FFFD}裡\u{FFFD}網");
        assert_eq!(invite::display_name("ok 名稱"), "ok 名稱");
    }
}


#[cfg(test)]
mod review3_tests {
    #[test]
    fn separators_are_filtered_in_shown_names() {
        assert_eq!(batman_proto::invite::display_name("家\u{2028}裡\u{2029}網"), "家\u{FFFD}裡\u{FFFD}網");
    }
}
