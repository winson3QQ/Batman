# Review of #329 PR 5 plan v12 — reviewer W (round 12)

Scope: the plan's new parts (§0 items 1–10, §2–§7), checked against the baseline and the source on main 2e18de6
(worktree `C:/src/Batman-329pr5`). Focus: consistency with source/baseline, lifecycle, ownership, contracts,
faithful moves, the §2.12 table, internal contradictions, and whether R17 covers every send.

**Verdict: APPROVE-WITH-CHANGES — 0 BLOCKER / 0 MAJOR / 12 MINOR.**

## 1. Appendix A MAJORs closed? (checked against source)

| MAJOR | Closed? | Evidence |
|---|---|---|
| U-M1 (hint-card send without confirm) | Yes | R17 step 2 = old `_sendUpdateFor` `confirm && !member` (nodes.dart:1567-1572); old status-page button used the default `confirm = true` (nodes.dart:1141). |
| V-M1 (no version in Dart) | Yes, for the leader | NetCfg.version (netrec.rs:107) / MNet.version (mrec.rs:93) exist, so two read-only fields are feasible. See m7 on `MnetView.version` being unused and m10 on pinning the version's meaning. |
| T-M1 (member tick) | Yes | R14 table: member never ticks; 8.5 shows Rust's `更新到第 {to} 版` (rekey.rs:400). |
| T-M2 (NetRun prefix) | Yes in R14 | net_run.dart:301-302 is the code that changes. See m4 on R14 vs R16. |
| R-M1 (member text on 更多 / hint card) | Yes **only if** the `member` flag of `RekeyResult` comes from R17 step 1. The plan does not say so; see m3. |
| Q-M1, M-M1, O-M1/P-M2 (stale rules) | Yes | A grep of §0–§8 for 消失 / clearOwnClip / 只清自己 / 已送出 / 略過 finds only the explanatory lines (:9, :312). |
| P-M1 | Yes | `kMemberRekeyRule` is used and never ticks. |
| K-M1, I-M1 | Yes | 8.3 reads `removeOwnNodes ∩ phone records`, one node at a time, with no outer timer. This matches nodes.dart:1360-1375 (`_nodes.contains(o.deviceId)`). |
| L-M1, J-M1, H-M2 | Yes | Only the anchored positive sentences count (rekey.rs:447, :451). No "sent" bookkeeping is left. |
| G-M1 / H-M1 | Yes | R7 computes the hint before `done`. The cleanup and dispose are at prober.dart:188-205. `:83` is the cancel line the plan says to change. |
| E-M1, E-M2, F-M1, D-M1, D-M2, C-M1, C-M2, A-M1..3 | Yes | Hint card under StatusHero (node_page.dart:117-124 is where `_network` sits today). Member branch in R16. 8.4 lists unreadable own nodes. Fingerprint and same-name text in 8.1/8.2/8.3. The always-there entries in R15. |

## 2. R17 coverage: every send in the plan

I grepped the plan for 送出 / sendNewKey / sendUpdateFor / 送給節點 and the source for `sendUpdateFor` / `requestSendUpdate`.

| Send in the plan | Goes through | Old equivalent |
|---|---|---|
| 8.4 own-node 送出 (:332) | `sendNewKey` + expectDac (+ "infoNetId = this net", see m2) | `_sendUpdate` from the console, confirm (nodes.dart:1546-1561) |
| 8.5 送出 (:365) | `sendNewKey` | — (member, no confirm by the old `!member`) |
| Hint card (:471) | `sendNewKey` | `_sendFromPage` (nodes.dart:1138-1142) |
| 更多 (:475) | `sendNewKey` | `_sendUpdate` (nodes.dart:1745) |
| NetRun leader auto-send | NetRun direct | nodes.dart:668 `confirm: false`; net_run.dart:299-311 |
| R16 member auto-send (:447) | NetRun direct | nodes.dart:1059 `confirm: false` |

In source, the only send callers are net_run.dart:301 and owner_console.dart:507 (the definition), plus the old console (nodes.dart:668, :1059, :1141, :1558, :1580). member_ui.dart:480 is the old status page's button (`onSendUpdate` → `_sendFromPage`). No send entry is missing from R17. The gaps are in R17's contract (m1–m5), not its coverage.

## 3. §2.12 vs nodes.dart:1733-1770

The buttons at :1735, :1741, :1744, :1745, :1750-1752, :1757-1760, :1766 and :1768 all have a row. The exclude entry at :1277-1283 and 3.6 (add_pages.dart:147-151) are also listed. 建立網路 / 檢查網路 / 軟體更新 / Wi-Fi are not member buttons (PR 3/4). Nothing is missing. The only slip is cosmetic (m11).

## 4. Findings

### MINOR

**m1. R12 "匯入同意" cannot return `AlreadyImported` in the case it exists for, so the stale-mpend cleanup never runs.**
- Scenario: OfflineOp('匯入同意') writes mnet. Then either the 60 s revoke lands before `刪 mpend`, or the delete itself fails (the old code swallows that: nodes.dart:1023-1027, "a failed removal is harmless"). mpend is left behind. R12 "re-runs `memberImportPrepare` with the same code". With `pend_plain` present, `prepare_import` skips the `AlreadyImported` branch, which is reached only when `pend` is `None` (approve.rs:468-475). It goes through `bind` → `existing` (same netcfg → `Path::Same`) → `Prepared::Ready` (approve.rs:476-487).
- Result: the page says 「結果不明」. The mpend is never deleted. Since §2.10 (:467) dropped the "no newer mnet" condition and leans on this R12 row, the home todo 「你的加入申請還在等隊長同意」 stays forever for a member who has already imported. The no-revoke path (delete failed) has no R12 at all.
- It can be recovered (re-importing the same code gives `Ready` → import → delete). There is no security effect. That is why it is MINOR.
- Fix: R12 re-runs prepare with `pendPlain: null` (the "re-paste" path), and `AlreadyImported` → delete mpend in the new lease. 7.10 step 3 should also say what a failed mpend delete shows: say it, and offer the same cleanup. Test: write mnet, keep mpend → expect "已經匯入" and mpend gone. Negative control: pass the pend → FAIL.

**m2. R17's signature has no "expected network", but 8.4 and 8.5 depend on one.**
- 8.4 (:332) says "另外要求 `infoNetId` 等於這一頁的網路，否則不送". 8.5 (:366) says unreadable rows can be sent and "R17 會再檢查一次". `sendNewKey(nodeId, {confirm, expectDac})` (:371) checks neither. Once it is inside `sendNewKey`, the page cannot stop the send.
- From 8.5, an unreadable node that is actually in another network the phone holds would get that network's record sent. A leader `net/` record would also go through the leader confirm, and the result would then be shown under 8.5 with the member rule.
- Fix: add `expectNet` to R17 step 1 (and step 3). On a mismatch, don't send and show a fixed line. Test from 8.5 with a node in a second network.

**m3. R17 does not say where `RekeyResult`'s `member` flag comes from, and R-M1's closure depends on it.**
- 8.5 hard-codes `RekeyResult(member: true)` (:367). For 更多 and the hint card nothing is stated. If the page decides, a member phone using 更多 gets `kRekeyDoneRule` and a tick on `AlreadyCurrent`, which is the R-M1 regression.
- Fix: R17 step 4: `member` = the record kind found in step 1 (`mnet/` → true), never the page's. Test: a member phone, 更多 → `AlreadyCurrent` → no tick, `kMemberRekeyRule` shown.

**m4. NetRun appears in R17 and R14/R16 with conflicting instructions.**
- (a) R17 (:379) says NetRun does "第 3–4 步" on the held session. Step 3 is "re-read info and compare `infoNetId` with step 1", but NetRun has no step 1. The old code (nodes.dart:668, :1059) and net_run.dart:301 send right away. Read literally, this adds an info round-trip inside the 360 s join path. That would change baseline behaviour.
- (b) R14 (:389-392) says NetRun shows row states and notes. R16 (:447) says the member-mode result "用 `RekeyResult`". R14's own source check (:422) fails "any place that shows the raw sentence bypassing RekeyResult", yet NetRun shows `r.line = u.text` (net_run.dart:308).
- Fix: R17: NetRun does `sendUpdateFor(rel, member)` + `rekeyEnd` only (no info re-read). State once whether NetRun rows show `RekeyResult` or are an allowlisted exception. For member mode, show `kMemberRekeyRule` under the row (no tick).

**m5. The R17 / R14 source checks and tests do not lock what U-M1 was about.**
- `sendUpdateFor` is defined in owner_console.dart:507, and the old console's `_sendUpdateFor` (nodes.dart:668…1567) contains the substring. R17's check (:381) names neither exception; only R14 (:402) mentions nodes.dart.
- Nothing stops a later caller from passing `sendNewKey(x, confirm: false)`. Only the hint card has a confirm test (:384), but 8.4's own-node 送出 is the place a leader will press right after a removal.
- Fix: state the allowlist the same way in R17 and R14 (definition + `sendNewKey` + NetRun + nodes.dart until PR 6). Since NetRun never calls `sendNewKey`, either drop the `confirm` parameter or source-check that `confirm: false` appears nowhere. Add a confirm/cancel test for the 8.4 and 更多 entries too.

**m6. The `last4` used to build R14's anchored sentences is ambiguous, and the obvious Dart helper uppercases it.**
- Rust builds the sentence from the record's raw `device_id` tail (owner.rs:717; rekey.rs:447/451/452). `home_logic.dart:8` `last4()` returns `.toUpperCase()`. Device ids are lowercase hex (node_page.dart:84 lowercases again to match `node-xxxx`).
- If `rekeyEnd` uses `last4()`, every node whose last four characters contain a–f (about 85 %) never classifies as `current`. It fails closed: no tick, and NetRun goes to `_failed` on a real success.
- Fix: R14 names `OwnerSession.last4()` (owner.dart:100) or the raw id tail. Add a test with an id ending in letters, and a negative control with `last4()` → FAIL. The same care is needed for the 8.4 candidate match (`PersonNode.last4`) and the R16 entry match (`MnetView.device_last4`): compare case-insensitively, or say they share one source.

**m7. `MnetView.version` is added but used nowhere, and :467 still says Dart cannot get a version.**
- §0 (:41) adds the Rust field. No section reads it (grep: only :41 and :534). :467 justifies dropping the mpend condition with "要用到 Dart 拿不到的版本號". That line is stale after v12, although the real blocker remains: mpend has no version.
- A use that would help T-M1: `kMemberRekeyRule` asks the member to read out the import-time line. A member who sends later from 更多 or the hint card no longer has that line. Showing 「這支手機是第 N 版」 (MnetView.version) in `RekeyResult(member: true)` and on 8.5's `AlreadyImported` warning would give the leader something to compare at send time.
- Fix: use it there, or drop the field. Correct :467 either way.

**m8. Faithful move: the old auto-retry of `joinreq` and of `_sendUpdate`'s info read is dropped without saying so.**
- Old `_requestJoin` and `_sendUpdate` use `_ask`'s default `retry: true` (nodes.dart:512-514, :887-889, :1549). On a write failure they log in again and send once more (nodes.dart:553-566).
- OwnerConsole has no retry branch. Its header comment (owner_console.dart:7-9) justifies that only because "none of these five requests reaches it". Adding `joinreq` / `info` (2.3, R17 step 1) breaks that premise. The 2.3 table promises "wait / unclear 照舊" but is silent on retry.
- Fix: list this as a deviation (the user presses again; a joinreq resend is CAS-guarded by `pendGen`), and update the header comment.

**m9. R16's NetFormPage sentence contradicts itself and leaves the home-row-6 path unspecified.**
- :444 says "member 模式一律在入口節點上跑：NetFormPage 從哪一台進來都一樣，那台不是入口節點時，就不出現 member 分支". The first clause says the entry node is used whatever node came in. The second says the branch disappears when the ticked node is not the entry.
- NetFormPage is opened with `ticked: {?node}` from home (home_page.dart:202-204, possibly empty) and with the just-claimed node from 3.6 (add_pages.dart:120), which is usually not the entry. :460 says home row 6 does the join when the entry node is on the phone.
- Fix: say once that member mode always targets the entry node looked up from `NetIndex.mnets` regardless of `ticked`, and that `kNotEntryNode` shows only when no phone record matches. Add a test from home with no ticked node.

**m10. Pin what `NetView.version` means.**
- T-M1's check compares the member's 「更新到第 {to} 版」 with the leader's 「目前是第 N 版」. `to` is `c.cur` = the newest netcfg version (mupdate.rs:231, :302). The net record has several version numbers (key 13 `Version.version` per entry, netrec.rs:84; `NetCfg.version`, :107).
- Fix: `NetView.version` = the current netcfg's version (the same number info k9 and `update_text` use). Add a Rust test: after one removal, the bundle's prepare line number == `NetView.version`.

**m11. §2.12 row `:1745` omits 8.5 as a shortcut.**
- It lists 「節點頁「更多」、提示卡、8.4」, but 8.5's 送出 is also a send entry (R17 :378).

**m12. R12 does not say what the page shows while a revoked `work` never returns.**
- "等 `work` 真的結束之後…重讀" (:246). With signAdmin or ECDH hung forever, the reread never happens. `PopScope` is released at revoke (:230). The page's state for that wait (and when the user leaves) is unspecified.
- Fix: after the revoke, show 「結果不明，等一下再查」 with 「再查一次」 at once (the same as the `retry` reply), and do the judgement when it is pressed or when `work` ends. R17 also does not restate the old failure lines for an empty `infoNetId` or a missing record (nodes.dart:1550-1553, :1561). Name them so the move stays faithful.

## 5. Ownership / contracts / lifecycle (no new findings beyond the above)
- §3.1: every resource has one writer. The second `unsavedTodos` writer is the existing PR 1 split. `RemoveTicks.removed` from the R12 reread is still 8.3's call.
- §3.2: the OfflineReply / revoke / version contracts are coherent, apart from m1, m2 and m12.
- §3.3 missing-path check:
  - power loss mid-write: CAS + fsync, with residue in m1;
  - BLE off between R17's two `once`s: step 3 fails → `rekeyEnd` failed, fail-closed;
  - app backgrounded during the R17 confirm: no lease is held, fine;
  - Keystore without user auth (no `setUserAuthenticationRequired` in android/), so the 60 s limit cannot fire on a biometric prompt;
  - downgrade to PR 4: no record format change. The OK rows are verified.
- Security: no new fail-open path. R14 is anchored and fails closed (subject to m6). Hint paths are only for display (owner.rs:2260 path check, R9). Logging: owner_console logs only kinds and rel prefixes (owner_console.dart:225, :291, :305, :373).
