# Review U — #329 PR 5 plan v11 (round 11)

Reviewer U. Focus: consistency with source and baseline, field behaviour, lifecycle / ownership / contracts, faithful moves, the §2.12 entry table, internal contradictions. Worktree `C:/src/Batman-329pr5` @ main 2e18de6 (plus the uncommitted QrScanActivity.kt change the plan mentions). Read-only except this file.

## 1. Closure of appendix A MAJORs (checked against source)

| MAJOR | Status | Evidence |
|---|---|---|
| A-M1 / B-M1 (send entry) | closed | 2.10 「更多」, 8.4 own-node segment, 8.5; `request_send_update` has no `dev_gate` (owner.rs:1041) so T-S5 covers the Dart gate |
| A-M2 / C-M1 / D-M3 / C-M2 (always-there entries) | closed | R15 + §2.12 |
| A-M3 / B-M2 (QR size) | closed | R1 uses the encoder version; QrDecode.kt:18 `MAX_LEN = 4096` matches 3.2 |
| D-M1 / E-M1 / G-M1 / H-M1 (hint computed and shown) | closed in design | R7 computes before `done`; the session is disposed only in probe cleanup (prober.dart:188-205); `StatusView.net_id` is available (owner.rs:386-387); `update_hint` reads `page_info` from the same session (owner.rs:949-965, :1098-1101); card goes under `StatusHero` (node_page.dart:113-123), not in `_network` (:79-104) |
| D-M2 (fingerprint / same name) | closed | 8.1 / 8.2 / 8.3; `PersonView.same_name` (rekey.rs:55-98) |
| F-M1 / I-M1 / K-M1 (own nodes listed, read one by one, no skip) | closed | 8.3 matches nodes.dart:1360-1375; 8.4 lists every own node from `netPeople` |
| H-M2 / J-M1 / L-M1 / M-M1 (positive signal only) | closed | R14 + `rekeyEnd`; grep for 消失 / 已送出 / 只看 in §0–§8 returns nothing |
| O-M1 / P-M2 (paste always clears) | closed | R4 last bullet, matches nodes.dart:728-732 |
| P-M1 / R-M1 / T-M1 (member never ticks) | closed | R14 table, member row is "一律不打勾"; mupdate.rs:263-268 and :294-299 confirm that an old bundle is accepted |
| Q-M1 (7.8 / member branch rule stated once) | closed | only in 2.8 item 11 and R16 |
| T-M2 (NetRun auto send) | closed in design | net_run.dart:302 `starts('[UPDATED] ')` is named. The new row state for `applying` is not specified; see U-m3 |

## 2. §2.12 entry table against nodes.dart:1733-1770

Every member button maps to an entry: 1735, 1741, 1744 (hint part), 1745, 1750, 1751, 1752, 1757, 1758, 1759, 1760, 1766, 1768, the forget-dialog exclude (1277-1283), and add_pages.dart:124-130. The buttons that are not member buttons are 1737 「檢查網路」 (PR 3), 1744 「狀態頁」 itself (PR 4 node page) and 1769 「軟體更新」 (PR 4). The line numbers are correct. Nothing is missing.

One entry in the table does not follow its old behaviour. 「把新密碼送給節點」 → 「提示卡」 does not carry the old confirm. See U-M1.

## 3. Findings

### BLOCKER

None.

### MAJOR

**U-M1 — The hint card's 「把新密碼送給節點」 has no leader confirm. The leader can change their own node before the bundles are handed out.**

- **Scenario.** The leader removes a member. Their own node is now behind, and the node page shows the warn card 「這台還在舊密碼 — 把新密碼送給節點」 with its button. This happens exactly when bundles still have to be handed out. The leader taps the card. The node changes at once. Every member who has not yet imported a bundle loses the link to the leader's node, and in the field (no internet) the bundles have no channel left. The frozen baseline exists to prevent this order: remove-member :147 says 「② 包都交出去之後，再按…你的節點一換，就和還沒換的人斷線，之後很難再把包傳出去」.
- **Evidence.**
  - The old status-page button calls `_sendFromPage` → `_sendUpdateFor(r.$1, member: r.$2)` with the default `confirm = true` (nodes.dart:1138-1143). For the leader this shows the 「包都交給隊員了嗎？」 dialog (nodes.dart:1567-1572).
  - The plan specifies the confirm-outside-the-lease flow only for 「更多」 (2.10, the three steps under 「把新密碼送給節點」) and for 8.4 (item 10, 「送出」 step 1).
  - The card is described only as 「`button` 為真時，卡上有「把新密碼送給節點」」 (2.10). R14 lists it as a result location, but nothing defines its flow. R8 stores only `(id, hint)`, not which record or role, so the card cannot reuse the old `_hintRec` path either.
  - This is the same class of bug as R-M1 / Q-M1 / T-M2: a rule stated on one path and missing on another.
- **Fix.**
  - Make it one rule (say R17): every 「把新密碼送給節點」 entry (更多, hint card, 8.4) runs the same flow. First a `once` reads `info` → `infoNetId`. Then, for a net record, the confirm comes outside the lease, followed by a second `once` that sends. For an mnet record, it sends in the same `once`.
  - The card's button and 「更多」 call the same function.
  - Test: tapping the card on a leader's node shows the confirm, and 「取消」 sends nothing. Negative control: remove the confirm from the card path → FAIL.

### MINOR

**U-m1 — D11 (the mpend todo) and the R12 rechecks for 「匯入同意 / 匯入更新包」 need versions that no existing Rust entry gives.** This conflicts with 「Rust 入口全部不改」.
- **The gap.**
  - `MnetView` has `net_id / net_name / entry_state / device_last4` and no version (member.rs:303-327).
  - `list_pends` only lists file names (member.rs:331-338).
  - `member_pend_view` gives hex / sas / name only (member.rs:294-300).
  - `NetView` has no version either (owner.dart:305-312).
  - So 「沒有同一個 id、版本比它新的 mnet」 (2.10) and 「mnet 的網路與版本符合這次的碼」 (R12) cannot be computed with the stated tools. An implementer will either add a Rust entry, which is outside the reviewed scope, or quietly simplify the rule.
- **Fix.** Say how each one is computed with existing entries.
  - Imported approval: call `memberImportPrepare(pend: null, mnet)` → `AlreadyImported` (approve.rs:468-474).
  - Imported update: `memberUpdatePrepare` → `AlreadyImported` (mupdate.rs:298-299).
  - Removal: use the record generation from `readRecord` plus `netPeople`, instead of a "version".
  - D11: either drop it (show the todo whenever an mpend exists, as the old `_join` did at nodes.dart:1076-1083), or name the mechanism.

**U-m2 — The R12 recheck for 「移除」 does not fit 「排除這台」.** 「對象已不在名單」 is about a person. When the leader excludes their own node, the leader stays in the list, so the check always gives 「結果不明」 even when the exclusion landed. This fails safe (the 8.4 button is offered), but the table should have a node row: the excluded `dac_hash` is no longer in the leader's group, and the generation went up.

**U-m3 — D12 does not say what `RowState` a NetRun row gets for `applying`.**
- Today the `!starts('[UPDATED] ')` branch calls `_failed` (net_run.dart:302-310). That asks 「繼續下一台 / 先停在這裡」, and `canRetry` (net_run.dart:84-85) then offers 「再試這一台」, which re-runs the whole join on a node that already joined.
- **Fix.** For `applying` and for the member `current` case, set `RowState.ok` with the note, and do not call `_failed`. Test: an `Applying` reply → the row is not 「已加入」 and no askGoOn dialog appears.

**U-m4 — `rekeyEnd` is underspecified.**
- `sendUnclearLine` itself starts with `[REQ_FAIL]` (owner_console.dart:53), so the `unclear` match must come before the `[REQ_FAIL]` → `failed` rule.
- `unfinished` is a listed result, but no rule produces it. The `Unfinished` sentence starts with `[REQ_FAIL]` (rekey.rs:445).
- Rust refusals that come back as `ReplyKind.refused` have no prefix, for example 「還沒連線到節點（或上一個操作還沒結束）」 (owner.rs:1047-1050).
- **Fix.** Fix the order (exact `sendUnclearLine` → exact `Unfinished` sentence → the two success sentences → other `[UPDATED]` → everything else = `failed`). The default is `failed` (fail-closed). Extend the pinned-literal test to cover `Unfinished` and one prefixless refusal.

**U-m5 — R16's "ends with 「需要新的邀請」" rule misses `NoEntry`.** The NoEntry sentence is 「…需要新的邀請（手機裡已沒有這台節點的加入資料）」 (owner.rs:584), which ends with 「）」. Only the definite-failure lines end with 「；需要新的邀請」 (owner.rs:586-590, tested at :2585). So the plan's own example (NoEntry, :584) does not get the button. **Fix:** match the two cases explicitly, or use `contains`, and add a test with the NoEntry literal.

**U-m6 — 「R16 的那句話」 is used for two different situations.** R16 defines it for "the entry data is gone" (`entry_state == ""`). Home row 6 (2.10) shows it when 「入口節點不在手機上」. That also happens when the entry still exists but the node record was forgotten on this phone, and then 「加入資料已經沒有了」 is false. **Fix:** use a separate line for "entry node not on this phone" (for example, add the node back, or ask for a new invite). Say which `MnetView` field selects which line.

**U-m7 — NetFormPage member mode (from 3.6 or home row 6) does not say which node it runs on.**
- NetFormPage is opened with `ticked: {widget.id}`, the newly claimed node (add_pages.dart:118-120). R16 / D10 say a member join runs only on the entry node.
- Either NetFormPage retargets to the entry node (by last4), or it runs on the ticked node and shows Rust's `NotThisNode` line. It also does not say what happens with several ticked nodes.
- **Fix:** member mode is one node, the entry node, whatever was ticked. Add a test.

**U-m8 — A dangling reference to "R22".** R16 says 「Rust 在 `PersistFailed{applied:true}`、`_joinUnclear` 與 R22 之後…」. This plan defines only R1–R16. In the baseline, R22 is the SAS-channel rule (254-app-member-join.md:34), which has nothing to do with joining. Because the plan's own rule numbers look the same, this is the kind of reference that misleads. Replace it with the actual Rust case (for example the `[JOIN_STATE]` / `PersistFailed` lines, owner.rs:567-573).

**U-m9 — The §0 list of changes to PR 1–4 code is still incomplete** (S-m10 claimed it is complete).
- `NetIndex` (2.11, net_index.dart) is missing.
- The home banner text change (home_page.dart:308-310, the fixed text 「請到那台節點的頁面…」 goes away under R12) is only implied.
- So are `node_page.dart` (`_network` gets the member branch, the card, the group), `add_pages.dart` and `settings_page`.
- Add them, so the review scope and the PR diff agree.

**U-m10 — R12: the recheck needs a lease of its own, and the plan does not say what happens when that lease is busy.** 「在新的佔用裡重讀」 can find another operation holding the lease. In that case show 「結果不明」 with the same buttons. Do not wait or retry silently.

**U-m11 — 3.2 does not cover the result kinds that R12 produces.** `OfflineReply` lists `done / busy / failed / unknown`, but R12's results (「已經移除」, 「已經匯入」, 「已經放棄」, 「結果不明」 with buttons) are not in the contract. Give the shape of these post-revoke results, with an `op` value for each one.

**U-m12 — 2.10 「更多」 for the leader: the second `once` should check `infoNetId` again** before `sendUpdateFor`, as 8.4 does (2.7 item 10, step 2). Without that check, a node that left or changed network between the two sessions gets the record picked by the first read. The risk is low: Rust's updflow refuses `OtherNetwork` / `NotApplied` (rekey.rs:439-442). Writing the step the same way on both paths keeps them consistent.

## 4. Other checks (no finding)

- **Facts.** P9, P10, P13, P14, P19–P26: the line references are correct (spot-checked owner.rs:584, :949-965, :1041, :1098-1101; prober.dart:69-71, :83, :172, :185, :188-205; lease.dart:140-149; record_writer.dart:27-33; nodes.dart:728-732, :789, :899, :1441, :1056-1060; member.rs:17-23, :303-327; join2flow.rs:78, :383; rekey.rs:430-458).
- **Faithful moves.** `sendUpdateFor` already reads the record again itself (owner_console.dart:507-513), so 「memberJoin 之後重讀 mnet」 holds. The `joinreqLostLine` text is reused (member_ui.dart:168). The `_pendSaved` model matches the old `_saved` (nodes.dart:102, :223, :263). The 7.10 order (ecdh → re-read → import → write → delete mpend) matches nodes.dart:1001-1037. 8.5 calls ecdh only on `advance` (nodes.dart:1524).
- **Ownership.** No two-writer resource found beyond the acknowledged `unsavedTodos` split. `RemoveTicks` is also written from the R12 recheck path, but through its own `removed()` method, which fits 3.1.
- **Security.** Keystore keys have no user-auth requirement (no `setUserAuthenticationRequired` in android/), so the 60 s R12 cap cannot be hit by a prompt. `OpSession.once` logs only the constant name and the type (op_session.dart:124). The SAS screens already carry `sasRule` (member_ui.dart:35, :74, :97), so the extra line in 7.9 is redundant but harmless.
- **Lifecycle.**
  - The matrix covers kill and rebuild, revoke, FLAG_SECURE, field and downgrade.
  - A kill between the mnet write and the mpend delete in 7.10 leaves a residual mpend. That is what D11 is for; it ties to U-m1.
  - The scanner resolution also affects the claim QR, which is retested in §7.

## 5. Verdict

**APPROVE-WITH-CHANGES.** 0 BLOCKER / 1 MAJOR / 12 MINOR.

U-M1 is a one-rule fix: one 「把新密碼送給節點」 flow for every entry, with a test and a negative control. The MINORs are spec gaps. U-m1 and U-m4 need to be settled before implementation, so that no Rust entry is added and no default fails open.
