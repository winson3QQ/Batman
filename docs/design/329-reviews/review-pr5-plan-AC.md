# Review AC — #329 PR 5 plan v15 (round 15)

Reviewer AC. Focus: consistency with source and baseline, field behaviour, lifecycle paths, ownership, contracts, faithful moves, the §2.12 entry table, contradictions inside the document. Special focus: every entry into `NetFormPage` and its mode, and every place that shows a version number (R19).

Source: worktree `C:/src/Batman-329pr5` at main 2e18de6 (read-only). Plan: `docs/design/329-pr5-plan.md` v15 (1129 lines).

## Summary

| Severity | Count |
|---|---|
| BLOCKER | 0 |
| MAJOR | 2 |
| MINOR | 8 |

**Verdict: APPROVE-WITH-CHANGES.** Both MAJORs need only small text changes.

## Closure of the round-14 MAJORs, checked against source

- **AA-M1 (closed).** `NetFormPage` today has no mode. Its only member handling is the old-console branch at net_pages.dart:353-360, followed by `_makes = true` at :362. v15 adds an explicit `mode`, restores `joinChoice` when both kinds are present (nodes.dart:1065-1094, :1777-1786), and rewrites :352-360. The leader form is unchanged. The test "net + mnet, pick own network → leader form; negative control: the three-case table" covers the regression.
- **AB-M1 (partly closed, see M-1).** R19 removes the `NetIndex` snapshot as a source, and the 8.3 → 8.4 hand-over uses the record that was just written. But R19's re-read triggers only cover "page opened" and "this page's own writes", so 8.1 still shows a stale number after a removal.
- **Earlier MAJORs.** I spot-checked these against source and found them closed:
  - R17's allow-list for `sendUpdateFor`: the only caller outside the old console is net_run.dart:301; the default `member = false` is at owner_console.dart:507.
  - R18: the casing of the last four characters, member.rs:322 vs home_logic.dart:8.
  - R14: the fix for the `[UPDATED] ` prefix, net_run.dart:301-311.
  - Y-M2: the only fall-through is net_pages.dart:362.
  - The cancel line at prober.dart:83.
  - The fact that the version `MnetView` should show is `MNet.version`: mrec.rs:93, which updflow.rs:159 compares.

## §2.12 entry table

I compared it against nodes.dart:1733-1770. Every member button has a new entry:

| Old button | Line |
|---|---|
| 加入網路 | :1735 |
| 狀態頁 | :1744 |
| 把新密碼送給節點 | :1745 |
| 隊員名單 | :1750 |
| 產生更新包 | :1751 |
| 貼上更新包 | :1752 |
| 邀請隊員 | :1757 |
| 貼上隊員的申請 | :1758 |
| 貼上邀請 | :1759 |
| 貼上同意碼 | :1760 |
| 申請加入 | :1766 |
| 再顯示申請 | :1768 |
| 忘記加入中的節點 | :1741 |

The non-member buttons are out of scope:
- 建立網路 and 檢查網路 belong to PR 3;
- 軟體更新 (:1769) belongs to PR 4.

The line numbers in the table are correct. The only gaps are in which mode the shortcut entries use (m-1, m-2).

---

## MAJOR

### M-1 — 8.1 "目前是第 N 版" goes stale after a removal made from the pages stacked on top of it (AB-M1 is still open there)

**Scenario.**
1. The leader opens 8.1 (from 「隊伍與邀請」 or the node page's 「隊員」 group). R19 reads `net/<id>`: version N−1.
2. The leader taps a member → 8.2 → 8.3 → 「移除並換密碼」. `startRemove` writes version N. The app goes to 8.4, which shows N (correct, R19 second bullet).
3. The leader presses back from 8.4. 8.3 and 8.2 pop, and 8.1 is shown again. It is still mounted with the value it read at step 1, so it shows **第 N−1 版**.
4. 8.1 is exactly the page the plan tells the leader to compare against: "隊員唸版本號時，隊長對照這一行" (§2.7 item 1). A member who never got the new bundle reads "這支手機是第 N−1 版", the numbers match, and the leader counts them as done. Their nodes stay on the key the removed person knows. This is the AB-M1 failure, on a different page.

**Evidence.**
- R19 says the leader side reads 「頁面打開時，以及這一頁每次寫入之後」 (plan §2.9.1). 8.1 does no writes; the write happens on 8.3.
- The navigation from 8.3 to 8.4 is not specified, so 8.1 stays in the route stack under 8.2/8.3/8.4.
- The node page path is the same: 「隊員」 group → 8.1 → …

**Fix.** R19 for 8.1 and 8.4: read again whenever the page becomes visible again (route resume / `didPopNext`) and whenever `NetIndex` notifies a recompute. The `NetIndex` notice is used only as a trigger to re-read the record, never as the value. While the re-read runs, show 「正在讀取版本」, never the old number. Add a negative control: open 8.1, remove via 8.2/8.3, pop back to 8.1. It must show N; showing N−1 is a FAIL.

### M-2 — The §3.3 reconcile row "7.9 / 7.10 打開時對帳 … 重跑 prepare" cannot be implemented without the approval code, and its test would delete a legitimate re-invite request

**Scenario.**
1. A member was removed and then re-invited. This flow is explicitly supported: 7.8 lists every node, per remove-member :147 / :186.
2. Their phone still has the old `mnet/<id>` and now also a new `mpend/<id>` for the same net id. This is the normal state while they wait for the leader's approval.
3. They tap the home todo 「你的加入申請還在等隊長同意」 → 7.9.

The §3.3 row says that when 7.9 or 7.10 opens and the same id already has an mnet, the app re-runs prepare with `pendPlain: null`, and on `AlreadyImported` it deletes the mpend. Its test is 「mnet 加 mpend 時點待辦 → mpend 被刪」.

**Evidence.**
- `prepare_import(hex, …)` needs the approval hex (approve.rs:462-476: `bundle(hex)?`, then it compares `b.secrets == x.secrets`).
- When 7.9 opens, the approval code is not on the phone. 7.10's input lives only in page memory, and the §3.3 row itself is about the app having been killed. So the check cannot run when the page opens.
- The test as written has no code in it, so the only way to make it pass is "mnet + mpend → delete the mpend". That deletes the legitimate request in the re-invite case. The later import then fails with 「找不到申請」 (member-join :66), and the member has to apply again and get a new SAS check.
- The baseline already settles this residue: member-join :65 「刪失敗 → 留著無害」 and :78 「mpend 寫入後被殺 → 重做申請 / 『再顯示申請』」.
- If the member pastes the same approval again in 7.10 while the mpend is present, the prepare/import path handles it (`bind` with the mpend → `Ready`, approve.rs:477-489), and the import removes the mpend.

**Fix.** Remove the "on open" reconcile and its test. State the baseline behaviour instead: a leftover mpend is harmless, and the member clears it either by pasting the approval again in 7.10 (which imports and removes it) or with 「放棄申請」. R12's 「匯入同意」 row, where the code is still in memory, stays as it is. If any reconcile is kept, it must run only after the code has been pasted, and the test must include a re-invite case where mnet and mpend are both present and the mpend survives (negative control).

---

## MINOR

### m-1 — Home row 6 and 3.6 contradict R16's "both kinds → `joinChoice`"

R16 says that when the phone has both net and mnet, the user picks with `joinChoice`. But:
- Home row 6 is described as 「T-N2 的分流不變，只換目的地」. Today, `records == net` whenever `netFiles > 0` (net_index.dart:64-73), and home_page.dart:187 goes straight to `_form(makes: false)`. That is leader mode with no choice.
- 3.6 says 「加入網路照 R16」, which means asking.

So the same phone state behaves differently from the two entries. Either list home row 6 in R16 as asking `joinChoice` when `anyMnet`, or say explicitly that row 6 is leader-only and the member path goes through the node page and 「隊伍與邀請」.

Also, `joinChoice` lives in nodes.dart:1780, which PR 6 deletes. Say that it moves, or that the new UI keeps importing it.

### m-2 — Entry → mode list is incomplete; the page still overrides the mode

R16 lists these entries: only net, only mnet, both, 「隊伍與邀請」, and 7.10. It does not list:
- home `makeNetwork`;
- the home `JoinTodo` (`_form(todo:)`);
- node_page.dart:73 (`makes: true` after `goMake`);
- 3.6 make.

All of these should be `leader`, and the plan should say so, or say what the default is.

The plan also keeps a second decision point: net_pages.dart:352-360 becomes 「只有 mnet → member 模式」 inside the page. That means the page overrides the mode the entry passed, which is two writers on one value. Say that the page re-checks only when the entry's snapshot was `computing` / `unknown` (home_logic `records == unknown`), and that this re-check is the only override.

### m-3 — Member mode has no row for "no mnet at all" and no name disambiguation

「隊伍與邀請」 → 「讓我的節點加入隊長的網路」 is always present (R15), so it can be opened with no mnet, or with only an mpend. The old `_pickMnet` said 「手機裡沒有匯入過的隊伍網路（先貼上同意碼）」 (nodes.dart:1107-1109). R16's table has no such row, and :352-360 only covers mpend → 7.9. Add a row: no mnet → that line, with buttons to 7.10 / 7.8.

`_pickMnet` lists only `netName` (nodes.dart:1116). Two team networks with the same name need R13's date and last-4 suffix too.

From 7.10, pass the netId that was just imported, so the member does not have to pick again.

### m-4 — Member mode with a last-4 collision has no defined "try the other node"

R16 says that on `NotThisNode` the user should 「改試另一台」, but member mode 「不看勾選的節點」 and picks the entry by last 4. If two of the phone's nodes share the last 4:
- the node page shows the member branch on both;
- member mode may run on the one the user did not tap.

Fix: from the node page, start member mode on the tapped node when it matches with `sameLast4`. Otherwise list the candidates, the same way 8.4 does.

### m-5 — R19 member side names the wrong source for 8.5 and for `NetRun`

R19 says the member number comes from 「R17 第 1 步判斷出的那一筆 mnet」. That source does not exist in two places:
- **8.5's top line** is shown before any send. Its source is the mnet chosen by `updateNetId` of the pasted bundle. Before the paste, say which number is shown, or show none.
- **`RekeyResult(member: true)` after the member-mode join** (R16 step 2 / R17 `NetRun`) does not run R17 step 1 at all. Its source is the mnet picked in member mode.

Spell out both sources.

### m-6 — R19 "8.4 uses `startRemove`'s record" vs R10 "`work` does not return record plaintext"

Two statements conflict:
- R10: `work` returns only display strings and hex.
- R19: 8.4 uses the record that `startRemove` just wrote.

Say that `work` returns the version number, which is an integer and not plaintext. Also say what 8.4 does when it is reached through the R12 revoked path (「到換密碼檢查清單」 after 「已經移除」), where there is no returned value: it reads the record on open.

### m-7 — `NetIndex.mnets.version` (2.11) is a snapshot version with no stated reader

2.11 stores `version` per mnet in the snapshot, while R19 forbids showing snapshot versions. No reader is named. Either drop the field, or state that it is never displayed and add it to the R19 source check: no `mnets[...].version` in a widget.

### m-8 — `kNeedNewInvite` for "mnet does not open"

AB-m2 routes 「mnet 打不開」 to 「需要隊長的新邀請」. A transient Keystore or `PlatformException` failure would then send the member to ask for a new invite, which overwrites the mpend and costs a new SAS round. That is harmless but misleading. Use the existing 「手機的金鑰無法使用：〈代碼〉」 line (R10) when the failure is a platform exception, and keep `kNeedNewInvite` for "the entry data is gone" (empty last 4 / `NoEntry`).

---

## Other checks (no finding)

- **Ownership (§3.1).**
  - `RemoveTicks` changes only through its own methods.
  - `InviteHolds` has a single writer (7.8).
  - Hints have a single writer (`NodeLink`).
  - `unsavedTodos` has two writers with disjoint actions (inherited from PR 1).
  - The only new two-writer case is the mode (m-2).
- **Contracts.**
  - `Option<u32>` version with 「版本讀不到」. This is consistent with `net_summary`, which today defaults the netcfg fields (owner.rs:111).
  - `rekeyEnd` is anchored and fail-closed.
- **Lifecycle.**
  - Kill or Activity rebuild: memory controllers are dropped and records kept.
  - Downgrade to PR 4: the record format is unchanged.
  - Field build: there is no entry, and `openNet` is never called.
  - The only lifecycle-row problem is M-2.
- **Security.** I found no new fail-open beyond the ones listed:
  - `current` is trusted only for the anchored sentence;
  - the member side never ticks;
  - the clipboard is cleared after every paste.

