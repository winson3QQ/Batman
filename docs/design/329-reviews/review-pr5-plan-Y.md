# Review Y — #329 PR 5 plan v13 (round 13)

Reviewer Y. Focus: consistency with source and baseline, field behaviour, lifecycle, ownership/contracts, faithful moves, §2.12, internal contradictions.
Worktree `C:/src/Batman-329pr5` @ 2e18de6 (read-only; this file is the only one written).

**Verdict: APPROVE-WITH-CHANGES** — 0 BLOCKER / 2 MAJOR / 9 MINOR.

## 1. Appendix A MAJORs, checked against source

| MAJOR | Closed in v13 body? | Evidence |
|---|---|---|
| A-M1/B-M1, D-M1, E-M1, G-M1/H-M1 (hint computed and shown) | Yes. R6–R8 compute the hint before `done`; the card sits under `StatusHero` | prober.dart:69-71, :122-127, :188-205 (cleanup/dispose only after `result.future`); owner.rs:1099-1101 (`update_hint` reads `page_info`, filled by `requestStatusPage` at owner.rs:950-965) |
| A-M2, C-M1/D-M3, C-M2 (standing entries) | Yes. R15 plus the §2.12 table | see §2 below |
| A-M3/B-M2 (QR size) | Yes. R1 uses the encoder's version | — |
| D-M2 (fingerprint/same name) | Yes. 8.1/8.2/8.3 | nodes.dart:1324-1338 |
| F-M1 (8.4 lists all own nodes) | Yes. "讀不到的也列" | — |
| H-M2, J-M1, L-M1, M-M1/N-M1 (positive signal only) | Yes. R14 `rekeyEnd` uses an anchored whole-sentence match | rekey.rs:445, :447, :451, :452 match the literals cited |
| I-M1, K-M1 (8.3 reads) | Yes. Nodes are read one by one, with no skip and no outer timer | nodes.dart:1353-1375 |
| O-M1/P-M2 (paste clears) | Yes. R4: only `clearClip`; a paste always clears | nodes.dart:728-732 |
| P-M1, T-M1, X-M1 (member cannot claim latest) | Yes. The member never gets a tick. The version line is in 8.5 and in `RekeyResult(member:true)` (see m-4 for its source) | mupdate.rs:263-268; rekey.rs:400 |
| Q-M1, R-M1, U-M1 (rule in one place / single send path) | Yes. R17 plus an allow-list source check | owner_console.dart:507 (`member` defaults to false — X-m2 handled) |
| T-M2 (NetRun "Applying") | Yes. R14 NetRun branch | net_run.dart:299-311 (today it uses the `[UPDATED] ` prefix) |
| V-M1 (version fields) | Yes. §0 and D11 | owner.rs:97-105 and member.rs:303-309 show neither field exists today, so the Rust change is real and must regenerate the bindings |

All earlier MAJORs are closed in the body. **However, the W-m6 fix (last4 case) was applied to one site only. This is the same "rule fixed in one place" class again (Y-M1).**

## 2. §2.12 against nodes.dart:1733-1770

Every button in the build at :1733-1770 is listed:
- 加入網路 :1735
- 忘記加入中的節點 :1741
- 狀態頁 :1744
- 把新密碼送給節點 :1745
- 隊員名單／移除 :1750
- 產生更新包 :1751
- 貼上更新包 :1752
- 邀請隊員 :1757
- 貼上隊員的申請 :1758
- 貼上邀請 :1759
- 貼上同意碼 :1760
- 申請加入 :1766
- 再顯示申請 :1768

Also mapped: the "排除這台" button in the forget dialog (:1277) and 3.6 (add_pages.dart:124-130, :147-151).

Two buttons are not member buttons and are rightly absent:
- 檢查網路 (:1737) belongs to PR 3;
- 軟體更新 (:1769) belongs to PR 4.

**No missing row.** The 加入網路 (member branch) row, however, leads into Y-M2.

## 3. Findings

### MAJOR

**Y-M1 — The last4 case trap (W-m6) is fixed only in `rekeyEnd`. R16's entry-node match and 8.4's candidate match use the same comparison and have no rule.**

- **Scenario.** A member phone holds an mnet whose entry node is `bm-a5faaf844ee7`.
  - `mnet_summary` returns `device_last4 = "4ee7"`, keeping the original case (member.rs:322).
  - R16 says "入口節點用後四碼找（P21）". The node page and NetFormPage naturally use the UI helper `last4()`, which upper-cases (home_logic.dart:8) and gives `"4EE7"`.
  - The two never match, so the member branch never appears on the real entry node. Home row 6 and 「隊伍與邀請」 then fall to `kNotEntryNode` ("請隊長再邀請一次").
  - The member is told to get a new invite for a node that could join right now.
- **Scale.** Device ids are lowercase hex. With a uniform last 4, 1 − (10/16)^4 ≈ 85 % of nodes contain a letter there.
- **8.4 has the same trap.** It compares `PersonNode.last4` (rekey.rs:25-27, :79, original case) with phone records by last4. A mismatch gives "這支手機從這裡送不了" for the leader's own nodes, so the 8.4 送出 path is lost. The failure is closed but is a real field failure: the leader must find another entry.
- **Fix.** State the rule once, for example as an R18 or as part of P21: every last4 comparison against Rust-supplied last4 (`device_last4`, `PersonNode.last4`, `OwnerSession.last4`) uses the Rust form (`device_id`'s last 4 chars, original case) and never `last4()`. Reference it from R14, R16 and 8.4. Add a test that uses a lowercase hex id with letters at R16 and 8.4. Negative control: use `last4()` → FAIL.

**Y-M2 — R16 does not say what NetFormPage shows when the phone has only mnet and the ticked node is not the entry node. A literal implementation falls through to "建立網路". Home row 6's description also contradicts R16.**

- **Evidence.**
  - net_pages.dart:352-360 is today's mnet/mpend branch.
  - net_pages.dart:362 `if (!_makes && s.netFiles == 0) _makes = true;` switches the page into make-network mode.
  - R16 says the member branch exists only when the ticked node is the entry node, "不是的話就沒有". It names no replacement for that case.
- **How you get there.**
  - Home row 6 passes `node: notIn.first.id` (home_page.dart:181, :202-203). That is any node not in a network, not necessarily the entry node.
  - 3.6 passes the node just claimed, which is never the entry node of an existing mnet.
- **Field result.** A member with a second node, or one who re-claimed a node, taps 加入網路 and lands on a 建立網路 page. Pressing 開始 makes a separate network, so the team is split.
- **Contradiction.** For row 6, "其他入口" says "入口節點在手機上就做". That reads as "run on the entry node", which is not the row's node. If the entry node is already in the network, that runs a 360 s member join on a working node while the row-6 node stays out.
- **Fix.** Define the NetFormPage member decision as a three-way choice on the ticked node, in R16 only:
  1. ticked node is the entry node → member mode;
  2. mnet exists, the ticked node is not the entry node, and the entry node is on the phone → `kNotEntryNode` (its text already says "這台不是…");
  3. no entry data → `kNeedNewInvite`.

  Never fall through to `_makes` while `anyMnet`. Rename the "入口節點不在手機上" condition to match the sentence. Make home row 6 always pass `h.node` and say so. Tests:
  - mnet only, non-entry node → `kNotEntryNode`, not 建立網路;
  - negative control: drop the guard → the make page appears → FAIL.

### MINOR

**Y-m1 — The R17 / 2.3 "retry: true" claim does not fit OwnerConsole.** owner_console.dart:6-9 says the re-login-and-resend branch was deliberately not copied, and `_ask` has no `retry` parameter (owner_console.dart:391-397). R17 asks for "照舊用 retry: true（nodes.dart:512、:553-566）", which in the old code means log in again and resend. Either drop the claim and keep PR 3's no-resend rule (a failed info read shows its line and the user presses again, which is harmless), or list it as a PR 1–4 change. Today it is neither. 8.3's old `_remove` used `retry: false` (nodes.dart:1366), so the two callers also differ.

**Y-m2 — R8's "info 沒有 k9 時保留舊值" cannot be implemented as written.**
- Dart never sees k9. `update_hint` returns "" both for "not behind" and for "info unread" (rekey.rs:466-470).
- What Dart can see is `StatusView.netId`, which is empty when `page_info` is None or k10 is absent (owner.rs:2260). Use that: if `netId` is empty, keep the old value.
- Then also say what happens when the node really left the network: k10 is absent for good, so the old "還在舊密碼" card stays until the page is left. Either clear it when the status says "not in network" (nodeState 1), or accept it as a stated residual.

**Y-m3 — R6 `netKnown` does not say whether it includes mnet ids.** NetIndex today knows only opened `net/` ids (net_index.dart:150-160). If `netKnown` checks only `nets`, the member-side hint (rekey.rs:474-485) is never computed. State it as `nets ∪ mnets` (opened). Add a test: mnet only, node behind → the hint appears.

**Y-m4 — The source of N in `RekeyResult(member:true)` is not given.**
- `NetIndex.mnets` (2.11) has no version field, so the node page 更多, the hint card and NetRun have no stated source for "這支手機是第 N 版".
- Specify N = `mnetSummary(...).version` of the mnet record that `sendUpdateFor` actually read for this send, carried through R17 step 3 or NetRun. Otherwise add `version` to `NetIndex.mnets` and name it as the one source.
- The first option ties the number to the record that was sent, which is what T-M1 needs.

**Y-m5 — The `NetView.version` contract (§3.2) is wrong for one case.** `net_summary` swallows a netcfg decode failure with `unwrap_or_default()` (owner.rs:111). With the same pattern, version would be 0 and 8.1/8.4 would show "目前是第 0 版", which misleads the member/leader comparison. Say what happens: a netcfg failure gives −1 or `None`, and the line becomes "版本讀不到".

**Y-m6 — The §0 list of PR 1–4 changes is incomplete again (S-m10 class).** It omits:
- `home_page.dart` `_act` (row 6 destinations, :186-190);
- `add_pages.dart` `_memberJoin` / button gate (:124-130, :147-151);
- `settings_page.dart` (the 「隊伍與邀請」 row);
- `main.dart` → `AppLink` constructor.

**Y-m7 — `runNetOp` appears only in §6 step 3 and appendix C-m13.** It is defined nowhere in §2. Either define it, as what P8's `lease.run(writer…)` pattern is called inside `OfflineOp`, or drop the name.

**Y-m8 — 7.10 "接著做隊員的加入，見 R16" does not say whether the 360 s join starts automatically or behind a button.**
- The old code stopped after the import (nodes.dart:1033) and the user pressed 加入網路 later.
- An automatic join changes the node's state without a press. It also runs right after the member may have walked away from the node.
- State it as a button "現在讓節點 …xxxx 加入", which matches the baseline's order, and give its entry-node rule (Y-M1).

**Y-m9 — Small inconsistencies.**
- §0 says "共 10 項"; the brief says 1–9. One of them is wrong.
- R1's `bits` length `size × ⌈size/8⌉` is in bytes, with each row padded to a byte. 2.1 says "每格一個位元" without the padding. Say "bytes, rows byte-padded" in both places.
- R12's "匯入同意" re-check: `prepare_import` can also return `NeedsNewInvite` (approve.rs:470-472) when `pendPlain` is null. Map it to "已經匯入，但需要新的邀請" instead of "結果不明".

## 4. Lifecycle / ownership / security spot checks (no further findings)

- **Ownership.**
  - Records are written only through `RecordWriter` under the current lease (record_writer.dart:27-33). Revoke ends the token (lease.dart:140-149), so a late write by a revoked `work` is refused.
  - The old console writes only under its own raw lease, so there is no second writer.
  - `unsavedTodos` has two writers, which the plan states. Removal by value (home_page.dart:307) is fine.
- **SecureScreen nesting.** 7.9 has two `SecureScreen`s on one page. This is safe because `_held` is counted (secure_screen.dart:21, :37-39).
- **R7 ordering.** It is sound. Dispose only happens after `result.future` (prober.dart:188-205), so `cleaning` plus a synchronous `updateHint` closes the race.
- **R17 confirm.** Only for the leader (`!member`), as in the old code (nodes.dart:1568-1572).
- **R14 anchors.** They match rekey.rs:445, :447, :451 and :452 exactly, and `last4` comes from the login record (owner.rs:717).
- **D9 / T-S5.**
  - `request_send_update` and `request_info` have no `dev_gate` (owner.rs:1027, :1041), so the Dart gate test is required, as the plan says.
  - All member/rekey bridge functions are `dev_gate`d (rekey.rs:110…411; member.rs:64…295).
- **Compromised node.** k10 selects only `net/`/`mnet/` hex paths (owner.rs:2260 filters to 16 bytes). Its only effect is the display; it is never used as a "done" signal.
