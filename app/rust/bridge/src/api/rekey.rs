//! Remove a member for Dart (docs/design/254-app-remove-member.md v6.4): the admin's removal and the updates for the
//! members (§3.1, §3.3), the member's import of an update (§3.4), and the texts of 「把新密碼送給節點」 (§3.2) and the
//! status page's line (§3.5). Records cross into Dart only to be sealed by Kotlin; no text carries a secret. Dev /
//! bench only (§3.6 build gate): every entry here but the texts refuses unless built with `dev-trust`.

use batman_proto::cbor::{self, Value};
use batman_proto::mrec::{self, MNet};
use batman_proto::mupdate::{self, OwnNode, Prepared};
use batman_proto::netrec::{self, MemberState, NetRec};
use batman_proto::nodecert::{self, hex_lower, Verified};
use batman_proto::rekey::{self, BundleAction, BundleEnd, BundleRefusal, NodeRead, Refusal, Rekey, Target, UpdateBundle};
use batman_proto::updflow;

use super::member::dev_gate;
use super::owner::{persist_at, OwnerKind, OwnerStep, STALE_RECORD};

const NET_DAMAGED: &str = "手機裡的網路資料損壞";

/// owner_pub fingerprint (§3.1): the first 8 hex digits of SHA-256(owner_pub)
pub(crate) fn fpr(owner_pub: &[u8; 65]) -> String {
    rekey::fingerprint(owner_pub)
}

fn last4(d: &str) -> String {
    d[d.len().saturating_sub(4)..].to_string()
}

fn key65(b: Vec<u8>, what: &str) -> Result<[u8; 65], String> {
    b.try_into().map_err(|_| format!("手機金鑰格式不對（{what} is not 65 bytes）"))
}

fn hexn<const N: usize>(s: &str) -> Result<[u8; N], String> {
    batman_proto::invite::from_hex(s).ok().and_then(|b| b.try_into().ok()).ok_or_else(|| "App 內部錯誤（not hex of the right length）".to_string())
}

fn target_of(person: &str, node: &str) -> Result<Target, String> {
    match (person.is_empty(), node.is_empty()) {
        (false, true) => Ok(Target::Person(hexn::<65>(person)?)),
        (true, false) => Ok(Target::Node(hexn::<32>(node)?)),
        _ => Err("App 內部錯誤（a person or a node, not both）".into()),
    }
}

// ---- §3.1 the member list by person ----

pub struct PersonNode {
    pub last4: String,
    pub dac_hash: String,
    /// joining / applied / approved
    pub state: String,
}

/// One person of key 11 (grouped by owner_pub, §3.1).
pub struct PersonView {
    /// owner_pub (hex): what `start_remove` / `start_bundle` name a person by
    pub owner: String,
    pub fpr: String,
    pub name: String,
    /// this phone's own nodes: 「排除這台」 per node instead of 「移除這個人」
    pub is_self: bool,
    pub nodes: Vec<PersonNode>,
    /// the fingerprints of other groups with the same name (B-m4)
    pub same_name: Vec<String>,
}

#[flutter_rust_bridge::frb(sync)]
pub fn net_people(record_plain: Vec<u8>, owner_pub: Vec<u8>) -> Result<Vec<PersonView>, String> {
    let me = key65(owner_pub, "owner_pub")?;
    let r = netrec::decode(&record_plain).map_err(|_| NET_DAMAGED.to_string())?;
    let list = r.members().map_err(|_| NET_DAMAGED.to_string())?;
    let mut out: Vec<PersonView> = vec![];
    for m in &list {
        let state = match m.state {
            MemberState::Joining => "joining",
            MemberState::Applied => "applied",
            MemberState::Approved => "approved",
        };
        let node = PersonNode { last4: m.device_id.as_deref().map(last4).unwrap_or_default(), dac_hash: hex_lower(&m.dac_pub_hash), state: state.into() };
        let owner = hex_lower(&m.owner_pub);
        match out.iter_mut().find(|p| p.owner == owner) {
            Some(p) => p.nodes.push(node),
            None => out.push(PersonView {
                owner,
                fpr: fpr(&m.owner_pub),
                name: batman_proto::invite::display_name(&m.name),
                is_self: m.owner_pub == me,
                nodes: vec![node],
                same_name: vec![],
            }),
        }
    }
    let names: Vec<(String, String)> = out.iter().map(|p| (p.name.clone(), p.fpr.clone())).collect();
    for p in out.iter_mut() {
        p.same_name = names.iter().filter(|(n, f)| *n == p.name && *f != p.fpr).map(|(_, f)| f.clone()).collect();
    }
    Ok(out)
}

// ---- §2.4 / §3.1 before the confirmation ----

pub struct OwnNodeView {
    pub device_id: String,
    pub dac_hash: String,
}

/// The own nodes whose info Dart reads (login + `request_info`) before `remove_check` / `start_remove`.
#[flutter_rust_bridge::frb(sync)]
pub fn remove_own_nodes(record_plain: Vec<u8>, owner_pub: Vec<u8>, person: String, node: String) -> Result<Vec<OwnNodeView>, String> {
    dev_gate()?;
    let t = target_of(&person, &node)?;
    let me = key65(owner_pub, "owner_pub")?;
    let v = rekey::own_nodes(&record_plain, &me, &t).map_err(|e| refusal_text(&e))?;
    Ok(v.into_iter().map(|(d, id)| OwnNodeView { device_id: id, dac_hash: hex_lower(&d) }).collect())
}

/// One own node's info read (`info` empty = could not be read: not checked, §2.4).
pub struct NodeInfo {
    pub dac_hash: String,
    pub info: Vec<u8>,
}

fn reads_of(v: Vec<NodeInfo>) -> Result<Vec<NodeRead>, String> {
    v.into_iter()
        .map(|n| Ok(NodeRead { dac_hash: hexn::<32>(&n.dac_hash)?, info: if n.info.is_empty() { None } else { cbor::decode(&n.info).ok() } }))
        .collect()
}

fn refusal_text(e: &Refusal) -> String {
    match e {
        Refusal::Record => NET_DAMAGED.into(),
        Refusal::NotApplied => "這個網路還沒確認建立完成".into(),
        Refusal::NotSoleAdmin => "這個網路的管理者不只這支手機（或不是這支手機），不能移除成員".into(),
        Refusal::Joining(l) => format!("節點 …{l} 還在「加入中」：先讓它加入完成，或先忘記它"),
        Refusal::SelfPerson => "不能移除自己；要排除自己的某一台節點，請在那台按「排除這台」".into(),
        Refusal::NoTarget => "名單裡已經沒有這個對象".into(),
        Refusal::NodeNewer(l) => format!(
            "這支手機的紀錄比節點舊（可能還原了舊資料）：節點 {}。出路是重建網路（全隊重新加入）；若這些節點可能被抓、不在你身邊，關掉手機藍牙再開始",
            l.iter().map(|x| format!("…{x}")).collect::<Vec<_>>().join("、")
        ),
    }
}

/// What the confirmation dialog shows (§3.1): `ok` false = the refusal in `text`; else the dialog text.
pub struct RemovePlanView {
    pub ok: bool,
    pub text: String,
    pub unverified: bool,
    pub nodes: u32,
}

#[flutter_rust_bridge::frb(sync)]
pub fn remove_check(record_plain: Vec<u8>, admin_pub: Vec<u8>, owner_pub: Vec<u8>, person: String, node: String, reads: Vec<NodeInfo>) -> Result<RemovePlanView, String> {
    dev_gate()?;
    let t = target_of(&person, &node)?;
    let rec = netrec::decode(&record_plain).map_err(|_| NET_DAMAGED.to_string())?;
    let r = reads_of(reads)?;
    Ok(match rekey::precheck(&rec, &key65(admin_pub, "admin_pub")?, &key65(owner_pub, "owner_pub")?, &t, &r) {
        Err(e) => RemovePlanView { ok: false, text: refusal_text(&e), unverified: false, nodes: 0 },
        Ok(p) => {
            let who = match &t {
                Target::Person(pk) => {
                    let name = p.excluded.first().map(|m| batman_proto::invite::display_name(&m.name)).unwrap_or_default();
                    format!("要把〈{name}〉（{}）的 {} 台節點移出隊伍網路嗎？全隊會換一組新密碼。", fpr(pk), p.excluded.len())
                }
                Target::Node(_) => {
                    let l = p.excluded.first().and_then(|m| m.device_id.as_deref()).map(last4).unwrap_or_default();
                    format!("要把你的節點 …{l} 排除在隊伍網路外嗎？全隊會換一組新密碼。")
                }
            };
            let order = "順序：① 這支手機先產生每位隊員的更新包，你把包交給他們（他們用自己的 App 匯入，他們的節點才會換）；② 包都交出去之後，再按「把新密碼送給節點」換你自己的節點 —— 你的節點一換，就和還沒換的人斷線，之後很難再把包傳出去。在大家都換好之前，隊伍會暫時分成兩邊。被移除的節點若是某些節點唯一的轉送路徑，換完後那些節點會斷線，直到附近有別的節點。被移除的人之後可以由你重新邀請（他的節點若在舊設定裡接不上，要先離開網路再加入）。所有還沒用的邀請會作廢。換完後請每位隊員把自己節點的手機 Wi-Fi 密碼改掉。";
            let unv = if p.unverified { "\n\n⚠️ 沒有你的節點可以確認這支手機的紀錄是最新的。" } else { "" };
            RemovePlanView { ok: true, text: format!("{who}\n\n{order}{unv}"), unverified: p.unverified, nodes: p.excluded.len() as u32 }
        }
    })
}

/// The box the user ticks (§3.1 precondition 5).
#[flutter_rust_bridge::frb(sync)]
pub fn remove_tick_text() -> String {
    "全隊的節點都已更新到新版軟體".into()
}

// ---- the operations ----

enum ROp {
    Rekey(Rekey),
    Bundle(UpdateBundle),
}

/// The removal (§3.1: SignAdmin x 2 -> PersistNet -> Answer) or one person's update (§3.3: SignAdmin x N+1 ->
/// Answer with the hex). Nothing is sent to any node.
#[flutter_rust_bridge::frb(opaque)]
pub struct RemoveOp {
    op: ROp,
}

fn rekey_step(a: Option<rekey::Action>) -> Option<OwnerStep> {
    use rekey::{Action as A, End as E};
    Some(match a? {
        A::SignAdmin { tbs } => OwnerStep { sign_input: tbs, ..OwnerStep::new(OwnerKind::SignAdmin) },
        A::Persist { rel, plain, expected_gen } => persist_at(OwnerKind::PersistNet, rel, plain, expected_gen),
        A::Done(E::Committed { version }) => OwnerStep::text(
            OwnerKind::Answer,
            format!("[REKEY] 已換成第 {version} 版的密碼（只在這支手機）。接著為每位隊員產生更新包；包都交出去之後，再把新密碼送給你自己的節點"),
        ),
        A::Done(E::Refused(r)) => OwnerStep::text(OwnerKind::Answer, format!("[REQ_FAIL] 沒有開始：{}", refusal_text(&r))),
        A::Done(E::SignFailed) => OwnerStep::text(OwnerKind::Answer, "[REQ_FAIL] 手機的管理者金鑰無法簽章，什麼都沒有改變".into()),
        A::Done(E::PersistFailed(e)) => {
            OwnerStep::text(OwnerKind::Answer, format!("[REQ_FAIL] {}（什麼都沒有改變）", e.map_or(STALE_RECORD.to_string(), |x| format!("手機儲存失敗（{x}）"))))
        }
        A::Done(E::Broken(e)) => OwnerStep::text(OwnerKind::Answer, format!("[REQ_FAIL] 中斷（{e}），什麼都沒有改變")),
    })
}

fn bundle_refusal_text(r: &BundleRefusal) -> String {
    match r {
        BundleRefusal::Record => NET_DAMAGED.into(),
        BundleRefusal::NotApplied => "這個網路還沒確認建立完成".into(),
        BundleRefusal::NotAdmin => "這支手機不是這個網路的管理者".into(),
        BundleRefusal::NotRecipient => "這個人已不在名單裡（或是你自己），不產生更新包".into(),
        BundleRefusal::Inconsistent => "這位隊員的資料不一致 —— 請先移除這個人，再重新邀請".into(),
        BundleRefusal::Current => "這個人已經有目前的版本，不需要更新包".into(),
        BundleRefusal::TooLarge => "更新包太大，無法產生（請讓他的節點離開網路、再重新邀請）".into(),
    }
}

fn bundle_step(a: Option<BundleAction>) -> Option<OwnerStep> {
    Some(match a? {
        BundleAction::SignAdmin { tbs } => OwnerStep { sign_input: tbs, ..OwnerStep::new(OwnerKind::SignAdmin) },
        BundleAction::Done(BundleEnd::Out { hex }) => OwnerStep {
            hex,
            ..OwnerStep::text(
                OwnerKind::Answer,
                "[UPDATE] 更新包已複製到剪貼簿。已複製 ≠ 已換好：對方要在他的 App 匯入，他的節點才會換；這支手機看不到對方節點的狀態。包都交出去之後，再到狀態頁把你自己的節點換成新密碼。請把你節點的手機 Wi-Fi 密碼改掉（換密碼不會換手機 Wi-Fi）。本次沒有換：手機 Wi-Fi 密碼、Meshtastic / LoRa 頻道金鑰、TAK（OTS）憑證。".into(),
            )
        },
        BundleAction::Done(BundleEnd::Refused(r)) => OwnerStep::text(OwnerKind::Answer, format!("[REQ_FAIL] 沒有產生更新包：{}", bundle_refusal_text(&r))),
        BundleAction::Done(BundleEnd::SignFailed) => OwnerStep::text(OwnerKind::Answer, "[REQ_FAIL] 手機的管理者金鑰無法簽章，沒有產生更新包".into()),
        BundleAction::Done(BundleEnd::Broken(e)) => OwnerStep::text(OwnerKind::Answer, format!("[REQ_FAIL] 沒有產生更新包（{e}）")),
    })
}

impl RemoveOp {
    /// §3.1: remove a person (`person` = owner_pub hex, `node` "") or exclude one of this phone's nodes (`node` =
    /// dac_hash hex, `person` ""); `reads` = the own nodes' info reads; `ticked` = the user ticked
    /// `remove_tick_text` (precondition 5).
    #[flutter_rust_bridge::frb(sync)]
    #[allow(clippy::too_many_arguments)]
    pub fn start_remove(record_plain: Vec<u8>, record_gen: u64, admin_pub: Vec<u8>, owner_pub: Vec<u8>, person: String, node: String, reads: Vec<NodeInfo>, ticked: bool) -> Result<(RemoveOp, OwnerStep), String> {
        dev_gate()?;
        if !ticked {
            return Err(format!("請先確認「{}」", remove_tick_text()));
        }
        let t = target_of(&person, &node)?;
        let (f, a) = Rekey::start(&record_plain, record_gen, &key65(admin_pub, "admin_pub")?, &key65(owner_pub, "owner_pub")?, &t, &reads_of(reads)?);
        let st = rekey_step(Some(a)).ok_or("App 內部錯誤（no first step）")?;
        Ok((RemoveOp { op: ROp::Rekey(f) }, st))
    }

    /// §3.3: one person's update from the record read when the button was pressed (§2.3 recipient contract).
    #[flutter_rust_bridge::frb(sync)]
    pub fn start_bundle(record_plain: Vec<u8>, admin_pub: Vec<u8>, owner_pub: Vec<u8>, person: String) -> Result<(RemoveOp, OwnerStep), String> {
        dev_gate()?;
        let (f, a) = UpdateBundle::start(&record_plain, &key65(admin_pub, "admin_pub")?, &key65(owner_pub, "owner_pub")?, &hexn::<65>(&person)?);
        let st = bundle_step(Some(a)).ok_or("App 內部錯誤（no first step）")?;
        Ok((RemoveOp { op: ROp::Bundle(f) }, st))
    }

    #[flutter_rust_bridge::frb(sync)]
    pub fn signed(&mut self, der: Vec<u8>) -> Option<OwnerStep> {
        match &mut self.op {
            ROp::Rekey(f) => rekey_step(f.signed(&der)),
            ROp::Bundle(f) => bundle_step(f.signed(&der)),
        }
    }

    #[flutter_rust_bridge::frb(sync)]
    pub fn net_persisted(&mut self) -> Option<OwnerStep> {
        match &mut self.op {
            ROp::Rekey(f) => rekey_step(f.persisted()),
            ROp::Bundle(_) => None,
        }
    }

    #[flutter_rust_bridge::frb(sync)]
    pub fn persist_failed(&mut self, error: String) -> Option<OwnerStep> {
        let e = (error != STALE_RECORD).then_some(error);
        match &mut self.op {
            ROp::Rekey(f) => rekey_step(f.persist_failed(e)),
            ROp::Bundle(_) => None,
        }
    }
}

// ---- §3.3 the people who may still need an update ----

pub struct RecipientView {
    pub owner: String,
    pub fpr: String,
    pub name: String,
    pub nodes: Vec<String>,
    /// the lines under the person ("" = none)
    pub note: String,
}

#[flutter_rust_bridge::frb(sync)]
pub fn net_recipients(record_plain: Vec<u8>, owner_pub: Vec<u8>) -> Result<Vec<RecipientView>, String> {
    dev_gate()?;
    let rec: NetRec = netrec::decode(&record_plain).map_err(|_| NET_DAMAGED.to_string())?;
    let r = rekey::recipients(&rec, &key65(owner_pub, "owner_pub")?).map_err(|_| NET_DAMAGED.to_string())?;
    Ok(r.into_iter()
        .map(|x| {
            let mut note = vec![];
            if x.unknown_before {
                note.push("升級前的版本不明 —— 若他匯入失敗，請讓他的節點離開網路、再重新邀請");
            }
            if x.old_approval {
                note.push("他手上若有換密碼前的同意包，請先貼同意包、再貼更新包；順序反了就要重新邀請那台");
            }
            RecipientView { owner: hex_lower(&x.owner_pub), fpr: fpr(&x.owner_pub), name: batman_proto::invite::display_name(&x.name), nodes: x.nodes, note: note.join("\n") }
        })
        .collect())
}

// ---- §3.4 the member's import ----

/// The net_id an update names (parsed only: it picks mnet/<id> to read).
#[flutter_rust_bridge::frb(sync)]
pub fn update_net_id(hex: String) -> Result<String, String> {
    dev_gate()?;
    mupdate::update_net_id(&hex).map_err(|e| mupdate_text(&e))
}

fn mupdate_text(e: &mupdate::Refusal) -> String {
    use mupdate::Refusal as R;
    match e {
        R::Format(w) => format!("這不是正確的更新包（{w}）"),
        R::NoNetwork => "請先匯入網主的同意".into(),
        R::Fork => "⚠️ 這份更新包和你手機裡的網路紀錄不一致（另一份歷史），沒有匯入；請向網主確認".into(),
        R::TooOld => "你的資料太舊，請網主讓你的節點離開網路、再重新邀請你".into(),
        R::Older => "這份更新包比你的紀錄舊，已忽略".into(),
        R::Invalid(w) => format!("內容驗證沒有通過（{w}）"),
        R::NotForMe => "這份更新包裡沒有你任何一台節點的新密碼".into(),
        R::MissingOwn(l) => format!("這份更新包沒有你節點 …{l} 的新密碼，請網主重新產生你的更新包"),
        R::NotForThisPhone => "這份更新包不是給這支手機的".into(),
        R::Removed(l) => format!("你這台節點（…{l}）已不在這個網路，請向網主確認"),
        R::Stale => "請網主再複製一次你的包，再貼上".into(),
        R::Aead => "解不開（不是給這支手機的）".into(),
    }
}

/// This phone's own nodes from their opened node records (key 1 device id, key 4 DAC DER).
fn own_of(node_records: &[Vec<u8>]) -> Vec<OwnNode> {
    node_records
        .iter()
        .filter_map(|p| {
            let v = cbor::decode(p).ok()?;
            let id = v.get(1).and_then(Value::as_text)?.to_string();
            let pubk = nodecert::dac_pub_of_der(v.get(4).and_then(Value::as_bytes)?).ok()?;
            Some(OwnNode { dac_hash: netrec::dac_hash(&pubk), device_id: id })
        })
        .collect()
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum UpdateState {
    /// Kotlin ecdh(OWNER_ENC, eph_pub), then member_update_import with z
    Advance,
    /// member_update_import without z
    AddSecrets,
    AlreadyImported,
}

pub struct UpdatePrep {
    pub state: UpdateState,
    pub eph_pub: Vec<u8>,
    pub mnet_gen: u64,
    pub detail: String,
}

/// §3.4 first part: `mnet_plain` / `mnet_gen` = mnet/<id> as read; `node_records` = this phone's opened node records.
#[flutter_rust_bridge::frb(sync)]
pub fn member_update_prepare(hex: String, mnet_plain: Option<Vec<u8>>, mnet_gen: u64, node_records: Vec<Vec<u8>>, owner_enc_pub: Vec<u8>) -> Result<UpdatePrep, String> {
    dev_gate()?;
    let r = mupdate::prepare(&hex, mnet_plain.as_deref(), mnet_gen, &own_of(&node_records), &key65(owner_enc_pub, "owner_enc_pub")?).map_err(|e| mupdate_text(&e))?;
    Ok(match r {
        Prepared::Advance { to, eph_pub, mnet_gen } => UpdatePrep { state: UpdateState::Advance, eph_pub: eph_pub.to_vec(), mnet_gen, detail: format!("[UPDATE] 更新到第 {to} 版") },
        Prepared::AddSecrets { mnet_gen } => UpdatePrep { state: UpdateState::AddSecrets, eph_pub: vec![], mnet_gen, detail: "[UPDATE] 補上另一台節點的新密碼".into() },
        Prepared::AlreadyImported => UpdatePrep { state: UpdateState::AlreadyImported, eph_pub: vec![], mnet_gen, detail: "[UPDATE] 已經匯入過".into() },
    })
}

/// §3.4 second part: everything again with mnet read now (`mnet_gen`; must still be `expected_gen`), then the new mnet
/// as a PersistMnet step. `z`: Kotlin's ECDH (empty for AddSecrets); cleared here.
#[flutter_rust_bridge::frb(sync)]
#[allow(clippy::too_many_arguments)]
pub fn member_update_import(hex: String, mnet_plain: Option<Vec<u8>>, mnet_gen: u64, expected_gen: u64, node_records: Vec<Vec<u8>>, owner_enc_pub: Vec<u8>, mut z: Vec<u8>) -> Result<OwnerStep, String> {
    dev_gate()?;
    let zz: Option<[u8; 32]> = z.as_slice().try_into().ok();
    z.iter_mut().for_each(|b| *b = 0);
    let mut zz = zz;
    let r = mupdate::import(&hex, mnet_plain.as_deref(), mnet_gen, expected_gen, &own_of(&node_records), &key65(owner_enc_pub, "owner_enc_pub")?, zz.as_ref());
    if let Some(x) = zz.as_mut() {
        x.iter_mut().for_each(|b| *b = 0);
    }
    let (plain, net_id, g) = r.map_err(|e| mupdate_text(&e))?;
    let mut st = persist_at(OwnerKind::PersistMnet, mrec::mnet_path(&net_id), plain, g);
    st.detail = "[UPDATE] 已收到新密碼。等網主說大家都拿到更新包了，再到狀態頁按「把新密碼送給節點」。請把你節點的手機 Wi-Fi 密碼改掉（換密碼不會換手機 Wi-Fi）。如果你的節點在這次換密碼期間還是舊軟體（wsl.24 以前），更新軟體後請讓它離開網路再重新加入。".into();
    Ok(st)
}

// ---- §3.2 / §3.5 texts (all builds) ----

pub(crate) const NOT_LISTED: &str = "這台不在隊伍網路的成員名單裡（被排除或被忘記），只能「離開網路」；要加回請用「加入網路」";
const NO_SECRETS: &str = "這台的新密碼不在這支手機，請網主重新產生你的更新包";

pub(crate) fn update_text(e: &updflow::End, member: bool, last4: &str) -> String {
    use updflow::End as E;
    let fail = "[REQ_FAIL] 沒有送出：";
    match e {
        E::Record => format!("{fail}{NET_DAMAGED}"),
        E::NotVerified => format!("{fail}這次連線沒有驗證過節點身分，請重新連線"),
        E::NotListed => format!("{fail}{NOT_LISTED}"),
        E::NoSecrets => format!("{fail}{NO_SECRETS}"),
        E::Unknown => format!("{fail}讀不到節點的網路狀態，稍後再試"),
        E::InProgress => format!("{fail}節點正在加入，稍後再按"),
        E::OtherNetwork => format!("{fail}這台在別的隊伍網路"),
        E::NotApplied { rejoin: true } if member => format!("{fail}這台不在網路裡，請按「加入隊伍網路」（用手機目前的版本加入）"),
        E::NotApplied { rejoin: true } => format!("{fail}這台不在網路裡，請按「加入網路」（用手機目前的版本加入）"),
        E::NotApplied { rejoin: false } => format!("{fail}這台要請網主重新邀請"),
        E::Unfinished => format!("{fail}節點還有沒完成的變更，等一下再按；超過 10 分鐘仍如此，重新開機一次"),
        E::NeedsSoftware => format!("{fail}這台要先更新軟體"),
        E::AlreadyCurrent => format!("[UPDATED] 節點 …{last4} 已是新密碼"),
        E::NodeNewer => format!("{fail}⚠️ 節點比這支手機新（這支手機的紀錄可能被還原過）"),
        E::TooFar { rejoin: true } => format!("{fail}這台落後太多版，請讓它離開網路再重新加入"),
        E::TooFar { rejoin: false } => format!("{fail}這台落後太多版，請網主重新邀請這台"),
        E::Updated => format!("[UPDATED] 節點 …{last4} 已換成新密碼"),
        E::Applying => format!("[UPDATED] 節點 …{last4} 正在套用新密碼，稍後再看狀態頁"),
        E::AppBug => "[REQ_FAIL] ⚠️ 節點沒有接受（代碼 11，原因 14：App 的問題，請回報）".into(),
        E::NotChanged => "[REQ_FAIL] 沒有換成功，可再試".into(),
        E::SignFailed => format!("{fail}手機的管理者金鑰無法簽章"),
        E::Broken(w) => format!("[REQ_FAIL] 中斷（{w}）"),
    }
}

/// The status page's line about this node's secrets (§3.5).
pub struct UpdateHint {
    pub line: String,
    pub button: bool,
}

pub(crate) fn update_hint_of(info: Option<&Value>, node: Option<&Verified>, owner_pub: &[u8; 65], record_plain: &[u8], member: bool) -> UpdateHint {
    let none = || UpdateHint { line: String::new(), button: false };
    let (Some(info), Some(node)) = (info, node) else { return none() };
    let h = netrec::dac_hash(&node.dac_pub);
    let k9 = info.get(9).and_then(Value::as_uint);
    let k10 = info.get(10).and_then(Value::as_bytes);
    let behind = |cur: u32| k9.is_some_and(|n| n < cur as u64);
    let old = UpdateHint { line: "這台還在舊密碼 — 把新密碼送給節點".into(), button: true };
    if member {
        let Ok(m) = MNet::decode(record_plain) else { return none() };
        if k10 != Some(&m.net_id[..]) || !behind(m.version) {
            return none();
        }
        let mine = m.me.as_ref().is_some_and(|e| e.dac_pub_hash == h) || m.secrets_for(&h).is_some();
        if mine {
            old
        } else {
            UpdateHint { line: "這台還在舊密碼，這支手機沒有它的新密碼 — 請網主重新產生你的更新包".into(), button: false }
        }
    } else {
        let Ok(r) = netrec::decode(record_plain) else { return none() };
        if k10 != Some(&r.base.net_id[..]) {
            return none();
        }
        let listed = r.members().ok().is_some_and(|l| l.iter().any(|m| m.dac_pub_hash == h && m.owner_pub == *owner_pub));
        if !listed {
            return UpdateHint { line: NOT_LISTED.into(), button: false };
        }
        match r.netcfg() {
            Ok(c) if behind(c.version) => old,
            _ => none(),
        }
    }
}

/// §2.0 rule 2's question for this node (None-like "" when it was never removed).
pub(crate) fn removed_question(record_plain: &[u8], node: Option<&Verified>, last4: &str) -> String {
    let (Ok(r), Some(n)) = (netrec::decode(record_plain), node) else { return String::new() };
    let h = netrec::dac_hash(&n.dac_pub);
    if !r.removed_ever().is_ok_and(|v| v.contains(&h)) {
        return String::new();
    }
    let prev = match r.last_listed(|m| m.dac_pub_hash == h) {
        Ok(Some(m)) => format!("{}（{}）", batman_proto::invite::display_name(&m.name), fpr(&m.owner_pub)),
        _ => "不明".into(),
    };
    format!("[REMOVED_BEFORE] 這台（…{last4}）之前被排除（遺失 / 被抓），確定它回到你手上、而且沒被動過嗎？之前的擁有者：{prev}")
}

#[cfg(test)]
mod tests {
    use super::*;

    /// T25 / T36: built without dev-trust, the removal, the updates and the import refuse before anything
    #[cfg(not(feature = "dev-trust"))]
    #[test]
    fn t25_every_entry_refuses_without_dev_trust() {
        let no = |r: Result<(), String>, w: &str| assert_eq!(r, Err(super::super::member::DEV_ONLY.to_string()), "{w}");
        no(remove_own_nodes(vec![0xa0], vec![4; 65], "a".into(), "".into()).map(|_| ()), "remove_own_nodes");
        no(remove_check(vec![0xa0], vec![4; 65], vec![4; 65], "a".into(), "".into(), vec![]).map(|_| ()), "remove_check");
        no(RemoveOp::start_remove(vec![0xa0], 1, vec![4; 65], vec![4; 65], "a".into(), "".into(), vec![], true).map(|_| ()), "start_remove");
        no(RemoveOp::start_bundle(vec![0xa0], vec![4; 65], vec![4; 65], "a".into()).map(|_| ()), "start_bundle");
        no(net_recipients(vec![0xa0], vec![4; 65]).map(|_| ()), "net_recipients");
        no(update_net_id("a2".into()).map(|_| ()), "update_net_id");
        no(member_update_prepare("a2".into(), None, 0, vec![], vec![4; 65]).map(|_| ()), "member_update_prepare");
        no(member_update_import("a2".into(), None, 0, 0, vec![], vec![4; 65], vec![]).map(|_| ()), "member_update_import");
    }

    #[cfg(feature = "dev-trust")]
    #[test]
    fn t25_past_the_gate_in_a_dev_build() {
        assert!(update_net_id("zz".into()).unwrap_err().starts_with("這不是正確的更新包"));
    }

    #[test]
    fn every_update_end_has_words_and_no_hex() {
        use updflow::End as E;
        for e in [
            E::Record, E::NotVerified, E::NotListed, E::NoSecrets, E::Unknown, E::InProgress, E::OtherNetwork,
            E::NotApplied { rejoin: true }, E::NotApplied { rejoin: false }, E::Unfinished, E::NeedsSoftware, E::AlreadyCurrent,
            E::NodeNewer, E::TooFar { rejoin: true }, E::TooFar { rejoin: false }, E::Updated, E::Applying, E::AppBug, E::NotChanged,
            E::SignFailed,
        ] {
            for member in [false, true] {
                assert!(!update_text(&e, member, "2233").is_empty());
            }
        }
        assert_eq!(update_text(&E::NotListed, false, "x"), format!("[REQ_FAIL] 沒有送出：{NOT_LISTED}"));
    }
}
