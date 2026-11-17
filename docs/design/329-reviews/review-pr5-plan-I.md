# Review of #329 PR 5 plan v5 — reviewer I (round 5)

Scope: the whole v5 plan (`docs/design/329-pr5-plan.md`), only its new parts. Focus: consistency with the source and the baseline, and field behaviour (lifecycle, ownership, contracts, faithful moves, the §2.9 entry table). Every claim was checked against main 2e18de6 in `C:/src/Batman-329pr5` (read-only).

Result: **0 BLOCKER / 1 MAJOR / 9 MINOR**. Verdict: **APPROVE-WITH-CHANGES**.

## Closure of the round-4 MAJORs

| Item | Status | Evidence |
|---|---|---|
| G-M1 / H-M1 (hint computed after `done`, on a disposed session) | **Closed.** In v5 the hint is computed in the `answer` case, before `done`. `update_hint` is a sync FRB call (owner.rs:1097-1101), so it can't interleave with `dispose`. One claim is wrong but harmless; see m2. | prober.dart:122-127, :188-205 |
| H-M2 (`[REQ_FAIL]` counted as sent; marks not tied to a version) | **Closed in substance.** `[UPDATED]` covers exactly `Updated`, `Applying` and `AlreadyCurrent` (rekey.rs:451-453). Every other end is `[REQ_FAIL]` (rekey.rs:430-458). The "version" key, though, has no source in Dart; see m1. | rekey.rs:425-458 |
| Earlier MAJORs (A-M1…F-M1) | Still closed. I re-checked the §2.9 table against nodes.dart:1733-1770. Every member button is there: :1735 member branch, :1741, :1744 hint, :1745, :1750-1752, :1757-1760, :1763-1766, :1768, plus the "排除這台" from :1277-1283. "檢查網路" (:1737, `_confirmNetwork` :1240-1245) is net-only and belongs to PR 3, so it is correctly not listed. **Nothing is missing.** | nodes.dart:1733-1770 |

## MAJOR

### M1. 8.3 skips own nodes that NodeLink has not "seen". This misreads the old code and silently narrows the frozen §2.4 vouching / NodeNewer guard

- **Plan:** §2.6 item 9.1 (v5, G-m9) says: "只讀 NodeLink 這一輪看得到廣播的節點，照舊 nodes.dart:1363 只讀掃描看得到的（`_nodes.contains`）… 看不到的節點直接寫「讀不到（不檢查這台）」，不去登入".
- **Source:** `_nodes` is not the scan-visible set. It is `listNodes(records)`, i.e. every `node/` record on the phone: nodes.dart:77 and `_load` at :171-174. Its other uses agree: the node list at :1658-1659, and `_takeUpdate` at :1515, which the plan itself reads as "這支手機所有 node/ 紀錄" (2.6 item 14, A-m12). So the old `_remove` tried to log in to **every** own node that `remove_own_nodes` returned and that still had a record on the phone (nodes.dart:1361-1371). Only a node whose login failed was marked "讀不到（不檢查這台）". G-m9's premise (review-pr5-plan-G.md:157) was wrong, and v5 adopted it.
- **Why it matters in the field:** the reads feed `rekey::precheck` (batman-proto rekey.rs:118-136).
  - A reached node at a newer version than the phone's record → `NodeNewer`, and the removal refuses.
  - A reached node at a known version → the record is "vouched".
  - Fewer reads means:
    - `NodeNewer` is missed (silently, because the node was never asked);
    - the plan more often shows "⚠️ 沒有你的節點可以確認這支手機的紀錄是最新的" (rekey.rs:171) even when the leader is standing next to the nodes.
- **Scenario:**
  1. The leader opens the app.
  2. They go straight to Settings → 隊伍與邀請 → 隊員名單 → 8.3, before NodeLink has read the own nodes this round (`firstRounds`, a 2' node, a node read late in the round).
  3. Every own node is marked unreadable without a login.
  4. If the phone's net record is stale (the case the guard exists for), the rekey commits from the stale record: version v+1 with secrets that differ from what the nodes may already hold, and the team splits.
- In addition, "這一輪看得到廣播的" is not a concept NodeLink exposes per node id. Adverts map to ids only through reads (`isY`, core.dart:430-481), so the rule is not implementable as written.
- **Fix:** revert G-m9 to the faithful move.
  - For every own node from `remove_own_nodes` that has a `node/` record, run one `OpSession.once(info)` per node, with the "正在讀第 i / n 台…" progress and "略過這台".
  - Mark a node "讀不到（不檢查這台）" only after its login fails or the user skips it.
  - Correct the per-node limit: `loginFor` is 60 s from the start of the scan (node_link.dart:222-235), not "8 s + 20 s".
  - Specify how "略過這台" ends a running `once`. Today `once` checks `gone` only after the login (op_session.dart:89-131), so skipping needs a cancel path. It must not use `Lease.revoke()`, which would add the "上一個操作可能沒有存完" todo (lease.dart:360-369) for a read.
- **Negative control:** one own node is not in NodeLink's states but answers `loginFor` with a newer k9 → `removeCheck` must refuse with NodeNewer. With the v5 "skip if not seen" rule → FAIL.

## MINOR

- **m1. 8.4: Dart has no secrets version for the key "(netId, 紀錄版本)" or for the text "第 V 版".** `NetView` has no version (owner.rs:96-104). `PersonView` / `RecipientView` have none either (rekey.rs:47-63, :302-309). The Rust entries are frozen. The only sources are the store generation, or parsing the `[REKEY] 已換成第 {version} 版` text (rekey.rs:208).
  - If the generation is used, every approve or invite PersistNet resets all "已送出" marks. That is fail-safe (re-sending gives `AlreadyCurrent` → `[UPDATED]`), but noisy.
  - Entering 8.4 from "產生更新包" with no rekey in this run shows "還有 N 台節點沒換到第 V 版", although all nodes may already be current.
  - Fix: state the key explicitly (store generation is acceptable and fail-safe). Drop "第 V 版", or take V from the `[REKEY]` answer of this run only. Show the top line only when `removedThisRun`, or soften the wording ("還沒在這次確認").
- **m2. 2.3: the claim "清理一定在提示算完或逾時之後才發生" is false.** `result` can also complete from `cancelled` (a lease acquire → `_abort`, node_link.dart:567-575), from the 20 s `answer` timer (prober.dart:172) or from a frame error (:166-167). Any of these can happen while the hint awaits `openNet`. Cleanup then disposes the session, and `updateHint` throws and is caught. The result is harmless (no hint that round, outcome not changed), but the sentence and its test framing should say so. Also, `onHint` must not be called once `result.isCompleted`.
- **m3. Hint contract: a stale card after the node leaves.** "成功讀取、提示算完 → 取代（含空值）" is defined only for eligible reads. Suppose a later successful read has no `netId` (the node left), or the `NetIndex` entry is gone. If "not eligible" is not treated as "computed, empty", the old "這台還在舊密碼" card stays. Fix: every `Res.body` read writes `hints[id]`, and an ineligible read writes empty. Only a timeout or a hint error keeps the old value. Also say explicitly that the hint loop stops at the first record that **opens** (net, then mnet), even when its hint is empty, as nodes.dart:1166-1174 does with `break`.
- **m4. D10 vs NetFormPage "兩者都有 → 先問".** `joinChoice` is phone-wide (nodes.dart:1795-1800). On a phone with net and mnet, for a node that is not the mnet entry, the dialog still offers "隊長的網路（我是隊員）", which Rust refuses with `NotThisNode` (join2flow.rs:382-383). That contradicts D10's "新 UI 不給這個會失敗的選項". Fix: compute NetFormPage's `hasMnet` as "this node is the entry of some mnet whose `entry_state` is not empty".
- **m5. Home row 6 with an mnet, when the entry node is already applied.** Home row 6 appears for any node that is not in a network (home_logic.dart:88-97). Take a member with two nodes where only A was invited and has joined: B triggers "加入網路" → member mode on entry A (D10), which is already applied. Say what happens. Proposal: when the entry's state is `applied`, or no node not in a network is the entry, show "這台要另外向隊長要邀請" → 7.8, instead of running a 360 s join.
- **m6. 8.4's own-node list joins two views.** `PersonNode` has no `device_id` (rekey.rs:47-52). The full id comes from `NetView.members[].deviceId`, matched by `dac_hash` (owner.rs:83-88), so say so. In addition:
  - a node from before join2 has `device_id == ""` (owner.rs:82-83). It would show "這支手機沒有這台的紀錄 — 得在擁有它的手機上做", which is wrong. The node page's "更多 → 把新密碼送給節點" still works for it (info → infoNetId, no device id). Use a distinct line that points there.
  - an own node still `joining` is counted in N for ever. Show it as "加入中" and leave it out of N, or explain why it is included.
- **m7. `memberJoin`: the mnet record read is not placed.** G-m10 put the joinreq's mpend read inside the lease. For `memberJoin(mnetPlain, mnetGen)`, the old code read the mnet before `_ask`, outside any lease (nodes.dart:1049). Put the read in the join wait page's lease as well, so the CAS generation is read under the same lease as the write.
- **m8. The 60 s revoke vs the ops that produce a code.** For `makeInvite` / `approve`, the write can land after the cap while the hex never reaches the page. "版本變了 → 已經完成" then leaves the leader with no code to send. Fix the wording for those two: "已經完成，但碼沒有拿到：請再邀請一次 / 再按一次同意（會顯示重複同意的說明）". `showDupNote` exists for the approve case.
- **m9. Small source inaccuracies.**
  - `memberEntryOf` and the planned `entryLast4` match by the last four hex digits only (member_ui.dart:256; member.rs:322). Two own nodes with the same last4 would both pass the node-page condition (Rust still refuses the wrong one). Use the full device id if the summary can give it; otherwise note the limit.
  - 3.1 lists two writers for `RemoveTicks` (8.3 clear, 8.4 tick). It is one controller, so state that the controller's methods are the single owner.
  - D1: the approval size also grows with the leader's network name (up to 24 CJK characters, 72 bytes) and node names. The ~50-character margin is for the vector's names. The ⚠️ measurement in D1 should include a maximum-length network name.

## Checked and fine (evidence)

- `Lease.revoke()` as a one-line wrapper of `reg._revoke(this)`: same library (lease.dart:248-370). After the revoke, `_ended = true`, so the hold's cancel and OfflineOp's `release()` do nothing, and `RecordWriter._check` refuses later writes (record_writer.dart:397-403). The listeners get `revoked` and then `released(revoked: true)`, and NetIndex recomputes (net_index.dart:189).
- The prober's `statusView.netId` is independent of `hasNet` / `hasMnet` (owner.rs:1340-1343, :373-401). `update_hint_of` returns empty without `page_info` (rekey.rs:466-468). `request_send_update` has no `dev_gate` (owner.rs:1041-1059), so T-S5 on the Dart gate is required, as the plan says.
- `NetIndex` today holds no ids for mnet or mpend (net_index.dart:148-184). The planned fields are additive and need no lease.
- net_pages.dart:352-360 is the mnet / mpend dead end that the plan removes. home_page.dart:183-190 routes `joinNetwork` (mnet), `seeRequest` and `joinTeam` to the old console.
- No Kotlin key path shows a user-auth prompt (grep finds no `setUserAuthenticationRequired` / `BiometricPrompt`), so the 60 s cap does not cut a legitimate prompt.
- Security: secrets are not logged (`runtimeType` only), the clipboard handling is as in round 4, and the devTrust gate is fail-closed until it is read. I found no new fail-open path besides M1.

## Verdict

**APPROVE-WITH-CHANGES.** Fix M1 (revert to the faithful "try every own node" read, with a real skip path and the correct per-node limit). The MINORs can be folded in during implementation.
