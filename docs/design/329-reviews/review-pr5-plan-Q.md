# Review Q — #329 PR 5 plan v9 (round 9)

Reviewer Q. Focus areas: consistency with the source and the baseline, field behaviour, lifecycle paths, ownership, contracts, faithful moves, the §2.9 entry table, and contradictions between sections.
Checked against: worktree `C:/src/Batman-329pr5` at main 2e18de6, with the plan in `docs/design/329-pr5-plan.md` (1010 lines). Read-only. The only file written is this one.

**Verdict: APPROVE-WITH-CHANGES** (0 BLOCKER / 1 MAJOR / 9 MINOR)

The one MAJOR has the same cause as the round-7 MAJOR: v9 changed two rules (O-m5, O-m6) in one place, and the old rule still stands elsewhere in the plan. Each fix is a text edit plus a test that locks the rule that is kept.

---

## What I verified as closed or correct (evidence)

- **§2.9 against nodes.dart:1733-1770.** I went through every member-related control in the old console's build():
  - :1735 加入網路
  - :1741 忘記加入中的節點
  - :1744 狀態頁
  - :1745 把新密碼送給節點
  - :1750 / :1751 / :1752 (the remove group)
  - :1757 / :1758 / :1759 / :1760 (the invite group)
  - :1762 the invite display
  - :1763-1766 申請加入
  - :1768 再顯示申請

  Each one has a row with a persistent entry. The dialog button 「排除這台（換密碼）」 (:1277) is covered by the row for 8.2. The 3.6 button (add_pages.dart:124-130, :151) is covered too. **Nothing is missing.** The non-member buttons 檢查網路, 建立網路, 軟體更新 and Wi-Fi correctly have no rows.
- **O-M1 / P-M2 (clipboard).**
  - `clearClip` (always clear, used after paste) and `clearOwnClip` (button and leave reminder) are now used consistently at plan :127-135, :159, :562 and §5 :633.
  - The old `_takeClipboard` (nodes.dart:728-732) clears unconditionally (`setData('')`), so the new paste path keeps that behaviour.
- **P-M1 (member's "已是新密碼" is relative to the phone's version).** The texts at :425-429 match the source:
  - `Prepared::AlreadyImported` → 「[UPDATE] 已經匯入過」 (rekey.rs:402);
  - `AlreadyCurrent` text (rekey.rs:447).

  The tick rule at :428 is sound. A residual issue is in m4.
- **2.3, the hint in the read round.**
  - `SessionProber`'s answer step is prober.dart:122-127, and the session is disposed only in cleanup (prober.dart:188-203). Computing the hint before `done` is therefore the only order that works, and the `cleaning` flag closes the cancel window.
  - The answer timer is local to `probe` (prober.dart:87, :172), so it can be cancelled at the answer step as the plan says.
  - `StatusView.net_id` exists (owner.rs:2258, lowercase hex, 16 bytes only).
  - `update_hint` reads `page_info`, which is set by the `info-page` answer (owner.rs:961-965) before the status-page Answer.
- **K-M1 (no "skip").** Only the appendix and the explanatory text mention 「略過」. The 8.3 rule (`removeOwnNodes` ∩ node records, one node at a time) matches nodes.dart:1357-1375 (`_nodes.contains(o.deviceId)`).
- **L-M1 / M-M1.** Every 「消失」 left in the body is either a negative-control description or a historical note. None of them is a live rule.
- **D10 citations.**
  - join2flow.rs:78 is `Pre::NotThisNode` and :383 is the refusal.
  - `memberEntryOf` (member_ui.dart:256) compares last4 only. This matches `mnet_summary` (member.rs:312-327).
- **OfflineOp / revoke.** `Lease.pageGone`'s deadline path calls `reg._revoke(this)` (lease.dart:80-82, :140-149). `_revoke` sets `_ended`, so a later `release()` from the stuck work is a no-op (lease.dart:86). `RecordWriter._check` refuses once `reg.current` is no longer that lease (record_writer.dart:27-33). The plan's fail-closed claim holds.
- **Rust has no `dev_gate` on `request_send_update`** (owner.rs:1041-1058). This is correct, so the Dart gate on that row is the only gate, and T-S5 must cover it, as §6 step 8 says.
- **Upper-case QR text.** `from_hex` accepts upper case and whitespace (invite.rs:75-81). The approval's binding is `object_hash` over decoded objects, not over the hex text (member.rs:107, invite.rs:434), so upper case does not change any hash.
- **Nested `SecureScreen`** (CodeView inside the 7.9 page) is safe: it is ref-counted (secure_screen.dart:21, :37).

---

## MAJOR

### Q-M1 — Two v9 rule changes left the old rule in force elsewhere; one reading strands a member in the field

The same kind of slip as M-M1: O-m5 and O-m6 were applied in one section only.

**(a) 7.8: which nodes may request a join**
- §2.6 item 11 (:404) still says: 「選節點：這支手機有 `node/` 紀錄、**沒加入任何網路**的節點。只有一台時直接用。」
- §2.7.1 (:488-492, v9 O-m5) says the opposite: list every `node/` node, do not filter by state, and label the ones already in a network.

Field scenario:
1. The leader removes a member and later re-invites them.
2. The member's node is still in the old network config. The frozen baseline expects exactly this: remove-member :147, 「被移除的人之後可以由你重新邀請(他的節點若在舊設定裡接不上,要先離開網路再加入)」.
3. `request_joinreq` itself does not check node state (owner.rs:1283-1305 → `fresh_addr_then`, :1362-1369).

If the implementer follows :404, 7.8 shows no node. 7.8 is the **only** place a join request is made (§2.9 row :523), so this member can never rejoin. There is no fallback path.

**(b) The member branch of 「加入網路」: is nodeState checked or not?**
- :451 (v9 O-m6) says the member branch on the entry node 「不看 nodeState」.
- Three places still require `nodeState == 1`:
  - :448, home row 6;
  - :473, the node-page condition `nodeState == 1 && (netFiles > 0 || 入口節點)`, which the negative control at :481 locks in;
  - :480, which claims 「結果不明（`_joinUnclear`）之後，節點還是 nodeState == 1」.

  The :480 claim does not hold: a join can go unclear after the node has applied it. `_joinUnclear` is a timeout or lost link after the request went out (nodes.dart:49, owner_console.dart:349-353).
- Rust sends the user to this node's button in three cases:
  - `PersistFailed{applied:true}` → 「請在這台按「加入網路」補上紀錄」 (owner.rs:568-573);
  - `_joinUnclear` → 「稍後在這台按「加入網路」」;
  - the frozen R22 path (remove-member :186; owner.rs:1477-1479 `send_update = applied && behind`), where member-mode join is a defined path on a node that is **already** a member.

  In all three, nodeState ≠ 1. Under :448 / :473 the button does not appear on the node page or on home row 6. The old console showed 加入網路 to any logged-in node (nodes.dart:1733-1735).

  The persistent entry 「隊伍與邀請 → 讓我的節點加入隊長的網路」 (:526) still works, which is why (b) alone would be MINOR. But the node page is exactly where Rust's sentence sends the user.

**Fix**
1. Delete the "沒加入任何網路" filter and "只有一台時直接用" at :404, and point to 2.7.1.
2. Rewrite :448, :473 and :480 so that the member branch on the entry node needs only 「是這筆 mnet 的入口節點」. The leader branch keeps PR 3's `nodeState == 1`.
3. Change the test at :481 to:
   - entry node with nodeState ≠ 1 and an mnet → member 「加入網路」 present → PASS;
   - put nodeState back into the member branch → FAIL.
4. Add a 7.8 test: a node already in a network is listed with the 「已在網路「…」」 label; filter it out → FAIL.
5. Grep the whole plan for 「nodeState == 1」 and 「沒加入任何網路」 afterwards.

---

## MINOR

### Q-m1 — The revoke todo text: two rules in one paragraph, and the banner body stays wrong

- :272 says both:
  - "由 `revoke(todo:)` 直接帶入整句 … `unsavedTodos` 是 `List<String>`，沒有種類欄位";
  - "home_page.dart:304 加一個依種類選句子的分支" (left over from K-m9).

  These contradict each other.
- More concretely, the banner body is a fixed string: home_page.dart:305-306 「這個操作沒有在時間內結束… 請到那台節點的頁面看目前的狀態」. Changing only the title (the `m` string) still tells the user to open a node page for an offline operation, which the plan itself says is wrong.

**Fix:** either `revoke(todo:)` carries title and body, or the body becomes neutral (「請重新打開那一頁確認，需要的話再做一次」). Delete the "依種類選句子的分支" clause.

### Q-m2 — "Always present" contradicted in two places

2.8.1 (:506) and T-P5-E (:534) say every row of 「隊伍與邀請」 is always present and does not depend on records. Two places say otherwise:
- §2.6 item 14 (:435): 「入口：「隊伍與邀請」的「貼上隊長給的新密碼」，以及節點頁「更多」。都要手機有 mnet 紀錄、而且是 devTrust 才出現」. This makes the settings row depend on records.
- §3.3 row 1 (:571): 「沒有紀錄時入口不出現」.

**Fix:** make :435's condition apply to the node-page shortcut only. Change :571 to "捷徑不出現；「隊伍與邀請」各列都在".

### Q-m3 — Stale entry names

- :585 still says 「設定頁的「隊員」仍進得去」. That row was merged into 「隊伍與邀請 → 隊員名單」 (2.8.1, :505).
- :399 lists the member-side entries without 「隊伍與邀請」.

### Q-m4 — `kMemberRekeyRule`'s 「第 N 版」 has no source in two of its cases

:427 takes N from 「Rust 的匯入原句（rekey.rs:400 的「更新到第 {to} 版」）」. That text is the *prepare* detail of `Advance` only:
- `AddSecrets` says 「補上另一台節點的新密碼」 (rekey.rs:401), with no number;
- the import's own detail has no version (rekey.rs:420);
- a member who sends from the node page's 「更多」 without importing on this page has no N at all.

This is also UI-text parsing of a Rust string.

**Fix:** when N is unknown, use the sentence without the number. Parse with an anchored regex and fall back on no match. Add a widget test for `AddSecrets` and for the 「更多」 send.

A related stale line is §5 :642: 「8.4 / 8.5 只認「已是新密碼」這個正向信號」. Since P-M1, 8.5 ticks only after a fresh import. Reword it to match :428.

### Q-m5 — The 2 s hint wait can now discard a good read

Before v5, the answer step called `done(body)` at once. Now, during the wait for `openNet`, a `cancelled` event completes the attempt as `noResponse` (prober.dart:83) even though `statusView` was already computed. Examples of such events:
- `setPage` (leaving the node page);
- `acquire` for an operation started from the node page;
- going to the background.

So a read that succeeded is lost exactly when the user taps an operation on the node page.

⚠️ Not verified whether core uses a cancelled attempt's outcome at all. If it drops it anyway, this is moot.

**Fix (if it matters):** on cancel or `cleaning` during the hint wait, complete with the already computed body outcome and skip only the hint. Alternatively, state that the loss is accepted.

### Q-m6 — `clearOwnClip` has to read clipboard content

To compare the SHA-256, Kotlin must call `getPrimaryClip()`. On Android 12 and later, that raises the system 「已貼上剪貼簿內容」 toast every time the user presses 「清除剪貼簿」 or leaves the page.

⚠️ Unverified alternative: mark our clip with a unique `ClipDescription` label (with a nonce) and compare via `getPrimaryClipDescription()`, which does not access the content. This is cosmetic, but it confuses users about who read the clipboard.

### Q-m7 — The member's 「更多 → 把新密碼送給節點」 flow is ambiguous

:463-467 says the first `once` reads `info` / `infoNetId` and then **ends**. 「如果是隊長」 gets the dialog and then a second `once`. The member case is not stated: does it continue in the first `once`, or does it also need a second one?

**Fix:** state it. The simplest version: the member sends in the first `once`, because there is no dialog.

### Q-m8 — The entry node is chosen by last4, with no retry on collision

7.10 step 5, home row 6, and 2.9 :526 ("直接用它的入口節點") pick one `node/` record whose device_id ends in `device_last4`. If two of the phone's records share last4, a wrong pick gets `NotThisNode` (join2flow.rs:383), and the user has no way to try the other one.

8.4 already solves the same problem: try each candidate and compare `nodeDacHash()` after login. Use the same rule here: compare `nodeDacHash()` with the mnet's entry before `memberJoin`, which only needs the console's `nodeDacHash()` (owner_console.dart:217).

### Q-m9 — 2.5 and 3.1 describe `AppLink.devTrust` differently

- 2.5 (:290): `AppLink` receives the value main.dart already read.
- 3.1 (:549): 「啟動時讀一次；讀到之前是 false」.

They describe different lifecycles. Pick one. The constructor value is the right one, and with it a "before read" state does not exist.

---

## Lifecycle / ownership / contracts notes (no finding)

- **Ownership (3.1):** each resource has one writer. `hints` (NodeLink), `RemoveTicks` (the object), `InviteHolds` (7.8), and records through `RecordWriter` under the current lease all check out against lease.dart and record_writer.dart.
- **Crash during an `OfflineOp`:** the lease is memory only, and writes are CAS, so a re-open re-reads. Same as the old console.
- **Bluetooth off during 8.3 reads:** each `once` ends with a login precondition. The node counts as "not checked", the same as old `_remove` for unreachable nodes. Baseline, not new.
- **Downgrade to PR 4:** no record format change. NetIndex's new fields are computed from existing files, so nothing needs migration.
- **Platform:** Android only. The resolution change was measured on the S20 only (⚠️, already stated in §7).
