# Review AA: #329 PR 5 plan v14 (round 14)

Reviewer AA. Focus: consistency with source and baseline, field behaviour, lifecycle, ownership, contracts, faithful moves, §2.12, internal contradictions; especially every entry into `NetFormPage` and every last4 comparison (R18).
Source checked: worktree `C:/src/Batman-329pr5` at main 2e18de6 (only `QrScanActivity.kt` modified, plus untracked docs).

## Appendix A MAJORs: closure check against source

| MAJOR | Status | Evidence |
|---|---|---|
| Y-M1 (last4 case) | Closed. R18 is one rule with a source check. The three Rust sources keep the case: `member.rs:322` (slice, no case change), `rekey.rs:25-27` + `:79`, `owner.rs:717`. Dart `last4()` uppercases: `home_logic.dart:8`. `nodeDacHash` and `PersonNode.dac_hash` are both lowercase hex (`owner.rs:1033`, `rekey.rs:79` `hex_lower`), so `expectDac` needs no R18 equivalent. | as cited |
| Y-M2 (NetFormPage falls to 建立網路) | Closed for the case it names (no net). **But the fix is over-applied and opens AA-M1.** Today `:352` already catches `netFiles == 0 && records != none`, so `:362` is reached only with no records at all (`net_pages.dart:352-362`). | see AA-M1 |
| Z-M1 (member two things) | Closed. R14 shows "已換成這支手機的版本" only on `current`. | plan §2.9 |
| X-M1, V-M1 (version fields) | Closed (§0, 8.1, 8.4, 8.5, RekeyResult). | plan |
| U-M1 (confirm) | Closed. The confirm applies only when `!member`, as in `nodes.dart:1567-1569`. R17 step 2 says "隊長、而且 confirm 為真時", which matches. | nodes.dart:1567 |
| T-M2 (NetRun Applying) | Closed. `net_run.dart:299-311` is the prefix check that R14 replaces. | as cited |
| T-M1, earlier rounds | Closed; nothing reopened. | — |

## §2.12 check against nodes.dart:1733-1770

Every button maps to an entry. Lines verified: 1735, 1741, 1744, 1745, 1750, 1751, 1752, 1757, 1758, 1759, 1760, 1766, 1768. One problem: the row "加入網路，隊員那一支（:1735）→ 選 mnet → R16" ends in `NetFormPage`, and the R16 table has a defect there (AA-M1). Some entry points also never say which node gets ticked (AA-m1).

## MAJOR

### AA-M1: The R16 table blocks a leader from his own network when the phone also holds an mnet; the joinChoice baseline is lost

**Scenario.** A leader runs his own network N0 (`net/`). He has also joined a neighbouring team B as a member (7.8 → 7.10), so the phone holds `mnet/B` too. He then claims a new node 05 for N0.
- Home row 6 shows "05 還沒加入". `records == net`, because net wins (`net_index.dart:64-72`). It routes to `_form(makes:false, node: 05)` (`home_page.dart:186-191`).
- Under v14, `NetFormPage` applies the R16 table "不管從哪裡進來". The plan places the mnet branch "放在 `noneOpens` 檢查之前". `noneOpens` is `netFiles > 0 && nets.isEmpty` (`net_index.dart:78`), so that placement only makes sense if the branch also runs when `netFiles > 0`.
- 05 is not B's entry node, so the table row "手機有 mnet、但這台不是入口節點" gives `kNotEntryNode` with no start. The leader cannot add 05 to N0 from home row 6 or from 3.6 (`add_pages.dart:120-123` → `NetFormPage`).
- The node page is just as broken. R16 says that when both branches apply, `joinChoice` asks "這支手機建立的網路 / 隊長的網路". But `NetFormPage` has no mode parameter: `node_page.dart:96` passes only `ticked: {id}`. If the user picks "這支手機建立的網路" on B's entry node, the table still forces member mode.

**Baseline.** `joinChoice` (`nodes.dart:1777-1786`, "PR 2 review B-M2: neither path may vanish") maps `(true, true)` to `ask`. The plan's own R16 node-page bullet says the same. So the document contradicts itself (R16 node-page bullet vs. the NetFormPage table), and it regresses already-reviewed behaviour.

**Field impact.** The leader's join path disappears on any phone that holds both records. The screen tells him "請隊長再邀請一次" about his own network.

**Fix.**
- Give `NetFormPage` an explicit `member` mode, set by whoever decided it: `joinChoice` on the node page, the mnet entries (隊伍與邀請, 7.10), and home row 6 / 3.6 only when `records == mnet`.
- Apply the three-way table only in member mode, or when `netFiles == 0`.
- When `netFiles > 0` and no mode was given, keep the PR 3 leader form unchanged. If the ticked node is an mnet entry node, ask with `joinChoice` first.
- Tests:
  - net + mnet, non-entry node ticked → the leader form is shown;
  - net + mnet, entry node ticked → the `joinChoice` question appears;
  - negative control: apply the table without the mode → FAIL.

## MINOR

### AA-m1: In member mode, "勾選的那一台" is undefined for several entry points
- `NetFormPage` is a multi-select form. `_tickOnce` auto-ticks every unjoined node (`net_pages.dart:206-224`), not only the node passed in. If the entry node and another node are both ticked, the plan doesn't say which one the table uses. NetRun would also loop `memberJoin` over all ticked nodes, and every non-entry node would get `NotThisNode` → `_failed` → "繼續 / 停".
- Home row 6 passes `notIn.first.id` (`home_logic.dart:93-104`). On an mnet-only phone with two unjoined nodes, the first can be the non-entry one. The user then gets `kNotEntryNode` ("請隊長再邀請一次") while the entry node sits on the phone, unjoined.
- From 隊伍與邀請 → 選 mnet, and from 7.10's "讓這台加入隊長的網路", no node is passed at all. The plan doesn't say how the entry node is picked: by `sameLast4` against `node/` records, and with several candidates if the last4 collides.
- Fix: member mode is single-node. Pre-select the entry node (its `sameLast4` candidates; on a collision the user picks one, and `NotThisNode` moves to the next). No auto-tick. From row 6, prefer the entry node among `notIn`.

### AA-m2: NetFormPage's devTrust source
`node_page.dart:73` and `:96` build `NetFormPage` without `devTrust` (default false, `net_pages.dart:134`); only home passes it (`home_page.dart:191`). If the member branch reads `widget.devTrust`, it never appears from the node page. State that the member branch (and the old-console button it replaces, `:357`) reads `AppLink.devTrust` (2.6).

### AA-m3: The new NetIndex fields during recompute, and the start-time comparison
- `recompute()` builds the "computing" snapshot by copying named fields (`net_index.dart:131-138`). The new `mpendIds` / `mnets` will be dropped unless they are added there. While it computes, the node page's member branch, the mpend todo and `RekeyResult`'s version ("版本讀不到") would flicker. Say so in 2.11.
- `_key` (`net_pages.dart:224`) compares only `nets` and `netFiles` at 開始. An mnet change between the form and 開始 is not detected. Rust still refuses (`NoEntry`, `NotThisNode`), so this is cosmetic, but add `mnets` to the key in member mode.

### AA-m4: 8.3 leaves out parts of the old `_remove` it says it moves unchanged
- Old code: `!plan.ok` → "沒有開始：{plan.text}" and stop (`nodes.dart:1384-1387`). On success the dialog shows `plan.text`, which carries the order instructions and the "⚠️ 沒有你的節點可以確認…" unverified line (`rekey.rs:166-172`; `nodes.dart:1397`). Plan 8.3 lists only "跑 removeCheck", the tick, and name / fpr / same-name. It never mentions showing `plan.text` or the refusal.
- Old code adds a `NodeInfo` for **every** own node, with empty `info` for nodes not on this phone (`nodes.dart:1361-1374`). The plan's wording "要讀的節點…交集" is about logins only. State that `reads` still carries every `removeOwnNodes` entry, so `remove_check` / `start_remove` get the same input as before.

### AA-m5: R12's "排除自己的節點" check needs a key
"那台已不在自己那一組" doesn't say what it compares. `start_remove` takes the node as its dac hash (`rekey.rs:254`, `PersonNode.dac_hash`). If an implementer compares last4, two own nodes with the same last4 give a wrong "已經排除". Say "by `dac_hash`". The R18 list of use sites should state that it is not a last4 comparison.

### AA-m6: Lifecycle gap: killed between PersistMnet and the mpend delete
- 7.10's `work` writes mnet, then deletes mpend (`member.rs:283-289`, "then remove mpend"). If the app is killed between the two (not a 60 s revoke), mpend stays. The new PR 5 home todo "你的加入申請還在等隊長同意" then shows indefinitely, next to a working mnet. R12's cleanup runs only on the revoke path.
- The same applies to the R16 table: mnet + mpend for the same net, with a non-entry node, gives `kNotEntryNode` instead of 7.9.
- Add a lifecycle row. Suggested handling: 7.9 (and the todo) detects `mnet/<id>` for the same id and offers to delete the stale mpend under a lease.

### AA-m7: 8.5's send list vs. the Rust import line
The import's `detail` says "等隊長說大家都拿到更新包了，再到狀態頁按「把新密碼送給節點」" (`rekey.rs:425`). 8.5 lists a "送出" for each node right away, and member sends have no confirm (`nodes.dart:1567-1569`). Show the Rust detail above the list, and repeat the "wait for the leader" caution next to the 送出 buttons. Otherwise a member sends early and cuts himself off from peers that haven't changed yet. This is baseline T30, so it is wording only.

## Things checked and found consistent
- R17's single path: `sendUpdateFor` is called only at `net_run.dart:301` outside `nodes.dart`. `owner_console.dart:507` reads the record itself. The member default is false (X-m2 is correct).
- R12 "匯入同意" with `pendPlain: null`: `approve.rs:468-475` gives `AlreadyImported` when `me` is set, `NeedsNewInvite` when it is not, and `NoRequest` (→ 結果不明) when mnet is missing.
- `update_hint` member branch: when the hint has `button: false`, the line is still non-empty ("…請隊長重新產生你的更新包", `rekey.rs:476-482`). R8 stores it and shows the card without the button, which is correct.
- CheckNet `goMake` cannot fire for a member-only phone: `pending` is empty, so the result is `nothingToCheck` (`net_run.dart:373-374`).
- `AddSecrets` (`rekey.rs:401`) with an empty `z` matches 8.5's "ecdh 只在 Advance".

## Verdict

**APPROVE-WITH-CHANGES.** 0 BLOCKER / 1 MAJOR / 7 MINOR. AA-M1 must be fixed: scope the R16 table to member mode or no-net, and keep `joinChoice` for phones that hold both net and mnet. Then re-check the whole R16 / §2.10 / §2.12 text for the mode wording.
