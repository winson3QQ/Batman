# #329 PR 5 code review, round 1, reviewer A

Scope: `git diff 2e18de6..HEAD -- app` on `feat/329-pr5` (HEAD c548c4e), against plan v16 (`docs/design/329-pr5-plan.md`,
R1–R19, §2.7–§2.12, §3, appendix B). Emphasis: plan conformance, ownership and contracts, lifecycle paths (page gone,
app killed, lease revoked at 60 s, retries), and whether each test fails without the code it guards.

What I ran (Windows host, no phone, no WSL):

```
$ dart analyze lib test
3 issues found.   (all `info`: unintended_html_in_doc_comment team_deps.dart:101, two unnecessary_* in tests)

$ flutter test --no-pub test/flows/offline_op_test.dart test/flows/rekey_send_test.dart test/flows/team_holds_test.dart \
    test/flows/owner_console_pr5_test.dart test/flows/net_index_test.dart test/flows/net_run_test.dart \
    test/nodelink/prober_hint_test.dart test/ui
00:24 +831: All tests passed!
```

Everything below is from reading the source; file:line refers to the worktree at c548c4e.

What holds (checked, not re-reported): R1/R2 (`qrDrawable`, `qrModulePx`, whole-pixel painter), R4/R5 paste always
clears first (code_view.dart:263-275), R6/R7 hint ordering before `done()`, the `cleaning`/`result.isCompleted` stop
check and the cancel-keeps-the-read change (prober.dart:110-167, 230), R8 `setHint` page guard and clear-on-leave
(node_link.dart:112-124, 153-158), R10 `OfflineOp` busy / failed / revoke shape and `runNetOp` (offline_op.dart:92-167),
R14 `rekeyEnd` anchored match and fail-closed default (rekey_send.dart:144-153) against update_text (bridge
rekey.rs:430-457), R17 two-session `sendNewKey` with the confirm outside the lease and `expectDac` / `expectNet`
(rekey_send.dart:210-271), the R17 allow-list source check (rekey_send_test.dart:159-174), R16 `mode` and the
"never 建網" fall-through (net_pages.dart:438-485), T-S5 gates on every new entry I found (settings_page, more_pages,
node_page `_hint` / `_team` / member branch, home row 6 `joinTeam` second button, add_pages 3.6), R19 re-read on
open / return / NetIndex notify for 8.1 and 8.4 (team_pages.dart:61-102, remove_pages.dart:226-250).

---

## MAJOR

### M1. 8.3 is stuck forever behind PopScope when a revoked removal never returns (R12 / W-m12)

**Scenario.** The leader presses 「移除並換密碼」. The Keystore `signAdmin` (or `seal`) hangs — exactly the case R12
exists for ("signAdmin 永遠不回來"). At 60 s `OfflineOp` revokes the lease and returns `OfflineUnknown`. The page then
waits on `settled`, which never completes, with `_running == true`.

**Evidence.**
- remove_pages.dart:119 `setState(() => _running = true);`
- remove_pages.dart:135-138 `OfflineUnknown(:final settled) => await _judge(settled), // R12`
- remove_pages.dart:157-158 `_judge` starts with `await settled;`
- remove_pages.dart:175-176 `PopScope(canPop: !_running, ...)`, and the button is disabled while `_running`
  (:192). `_line` is not set before the await, so the screen shows nothing new.
- offline_op.dart:110-113: `settled` completes only in the work's `finally`.

The plan says the opposite (R12, plan :263): "被收回的 `work` 一直不回來時，頁面停在「結果不明，等一下再查」，有「再查一次」；
`PopScope` 已經解除，可以離開". Here the leader cannot leave the page with Back and sees no reason; only killing the app
gets out. The home todo is there, but the leader is not on the home page.

No test covers it: there is no widget test of 8.3 with an `OfflineUnknown` (grep for `OfflineUnknown` / `結果不明` in
`test/ui` finds none for the team pages); offline_op_test.dart:109-139 checks `OfflineOp` alone.

**Fix (as the plan says).** On `OfflineUnknown`: set `_running = false` and show 「結果不明，等一下再查」 with 「再查一次」 at
once; run the judgement when `settled` completes (or when 「再查一次」 is pressed) without holding PopScope. Widget
test: a fake `OfflineDeps` whose work never ends, advance 60 s → Back pops the page and the line is shown; negative
control: the current `await _judge(settled)` → FAIL.

### M2. R12's post-revoke judgement table is mostly not implemented, and the gaps are not in appendix B

**Scenario A (the one that hurts).** Member imports an approval (7.10). The write of `mnet/` lands, the 60 s cap
revokes, the work goes on, and `w.remove(l, 'mpend/<id>')` is refused (`NoLease`) and swallowed
(join_pages.dart:402-404). The page says 「結果不明，請重新貼上同意碼確認」 (:418). Now `mnet/` and `mpend/` both exist:
- the home page shows 「你的加入申請還在等隊長同意」 for that network with no end (home_page.dart:259, 343-350: the todo
  is any `mpendIds` entry);
- re-pasting the approval runs `memberImportPrepare` with the mpend present, which goes to bind → `Ready`
  (W-m1 in the plan; member.rs:245-259), so the member is asked to check a SAS and import again instead of being told
  「已經匯入」.

The plan (R12 table row 「匯入同意」, plan :270 and §2.10 :553) is the designed answer to exactly this: re-run prepare
with `pendPlain: null`, and if `AlreadyImported`, delete the leftover mpend **in a new lease**. That is not done
anywhere.

**Scenario B.** Same for the other rows:
| R12 row | plan | code |
|---|---|---|
| 移除（人） / 排除自己的節點 | judge in a **new lease**; if not removed → 「結果不明」 + 「到換密碼檢查清單」 + 「到隊員名單確認」; lease busy → 「再查一次」 | `_judge` reads without a lease (remove_pages.dart:157-169); unknown → one line 「結果不明，請到隊員名單確認」 (:151), no buttons, no retry |
| 匯入同意 | prepare with `pendPlain: null`; AlreadyImported → 「已經匯入」 + delete mpend in the new lease; NeedsNewInvite → 「結果不明」 + `kNeedNewInvite` | 「結果不明，請重新貼上同意碼確認」 (join_pages.dart:418) |
| 匯入更新包 | re-run `memberUpdatePrepare` → AlreadyImported → 「已經匯入」 | 「結果不明，請重新貼上更新包確認」 (join_pages.dart:550) |
| 放棄申請 | mpend gone → 「已經放棄」 | `offlineLine` → 「結果不明，請再做一次」 (join_pages.dart:272, team_pages.dart:29) |

The contract row in §3.2 (`OfflineReply` … 「`retry`（拿不到佔用，加一顆「再查一次」）」) has no implementation:
`grep -rn "再查一次" lib` → nothing. Appendix B (B1–B11) lists none of this.

The plan's own §2.5 test list also has no implementation: 「寫入在收回之前已經落地 → 移除判斷為「已經移除」」 — no
test drives 8.3 (or any page) through `OfflineUnknown`.

**Fix.** Implement the table as written (one helper: wait for `settled`, acquire a new lease via `OfflineOp.run` with a
judge-only work, map busy → 「再查一次」), or, if some rows are deliberately cut, list each in appendix B with the reason
and what the user then sees. At minimum the 「匯入同意」 row must delete the leftover mpend, or the home todo lies. Tests:
for each row, a fake whose write lands and then the cap fires → the row's answer; negative control: drop the judge →
FAIL.

### M3. Three source checks the plan relies on as the structural guard are missing

The plan answers the repeated "rule changed in one place only" class (Y-M1 was the sixth time) with source checks.
Two of them, and one negative control, do not exist in the tests:

1. **R18** (plan :150): 「原始碼檢查：Rust 給的後四碼欄位，不能用 `==` 或 `last4()` 去比」. There is no such check;
   `grep -rn R18 test` hits only two comments. Today the code happens to be right (I checked every compare:
   remove_pages.dart:293/340, net_pages.dart:367-369, node_page.dart:89-91, rekey_send.dart:148), but nothing stops the
   next one. Note net_pages.dart:278 `x.entryLast4 == m.entryLast4` would be flagged by the rule as written (it is
   Rust-vs-Rust and harmless; the check needs an allow-list entry or `sameLast4`).
2. **R14** (plan :438, :464, §5 :699): 「`sendUpdateFor` 的結果只能交給 `rekeyEnd`」 and 「任一處繞過 `RekeyResult` 直接
   顯示原句 → 原始碼檢查 FAIL」. Only the `sendUpdateFor` call-site allow-list exists (rekey_send_test.dart:159-174);
   nothing checks that `RekeySent.line` / `RunRow.sendLine` reach the screen only through `RekeyResult`
   (send_key.dart:421 shows `s.line` directly for B8; that is the one case the check should allow).
3. The §5 negative-control list says these checks were each shown to FAIL once; there is no record of that for R18 /
   R14-bypass because the checks do not exist.

**Fix.** Add both checks to the existing source-check tests, each with "found something to check" asserted (as
offline_op_test.dart:172 does) and a recorded negative control.

---

## MINOR

### m1. A Keystore failure while working out the hint clears 「還在舊密碼」 (R8: 算失敗保留舊值)

app_link.dart:100-108: `openNet` turns a `PlatformException` into `null`. In `_hint` (prober.dart:262-269) two `null`s
mean "no record opens" and the hint is **cleared** (`onHint(id, empty)`). R8 (plan :226) says a round whose calculation
fails keeps the old value; R7 says exceptions are caught locally. Fix: let `openNet` rethrow (the `catch` in `_hint`
already logs the type only and keeps the old value), or return a distinct "failed" result. Test: `openNet` throws a
`PlatformException` after a hint was set → hint kept.

### m2. `setState` after dispose on two pages

- remove_pages.dart:82 `if (plain == null || !mounted) return setState(...)` — calls `setState` exactly when the page
  is gone.
- join_pages.dart:348-367 (`_got` of 7.10): after the two awaited `readRecord`s, the `catch` at :364 and the replace
  answer at :358 call `setState` without a `mounted` check (the `!mounted ||` at :357 then still reaches `setState` at
  :358).

Fix: check `mounted` first and return without `setState`.

### m3. 8.4 candidate loop stops at an unreachable first candidate (X-m1)

remove_pages.dart:296-299 tries the next candidate only when the line is `notThisNodeLine`. If the first candidate with
the same last four is out of range (`notReached`), the second, which may be the right node, is never tried, and the row
shows the unreachable one's line. Plan X-m1: 「`expectDac` 對不上的那一台自動換下一個候選，全部都對不上才顯示錯誤」. Fix:
also continue on `notReached` and keep the best result (a reached one over an unreached one).

### m4. R17 step 5 (refresh after a send from the node page) not done, not in appendix B

send_key.dart:397-405 does not call `NodeLink.refresh`. In practice the released-lease round (node_link.dart:426-433,
"a round 6 s later") re-reads the node, so the card does update. Record it in appendix B with that reason, or call
`refresh` as the plan says.

### m5. Android 12: the clipboard warning is not always shown (§5 / T-m8)

Plan §5 :673: 「剪貼簿警告在 Android 12 一律顯示，因為那裡的 sensitive 旗標效果沒有查證」. code_view.dart:189-196 shows the
warning only for text-only codes and in the FLAG_SECURE fallback; a QR code on an Android 12 phone that can set
FLAG_SECURE gets no warning after 「複製文字」. Fix: show the warning after a copy whenever SDK < 33 (the SDK level can come
back from `copyCode`), or always after a copy.

### m6. 8.5 lost the old console's stale-record sentence

nodes.dart:1534 maps `staleRecordLine` to 「請隊長再複製一次你的包，再貼上」. join_pages.dart:536 / offline_op.dart:83
show the raw 「紀錄已被別處更新，請重新開啟再試」 (owner.rs:65). The plan says the old code's sentences are kept (§0, R10
S-m8). Fix: map it in 8.5's failed line.

### m7. 「讓我的節點加入隊長的網路」 from the hub turns reads back on under the settings page

team_hub.dart:39 opens `NetFormPage` without `back`. NetFormPage sets `Page.home` on open (net_pages.dart:182) and on
dispose sets `widget.back`, default `Page.home` (:200). The user comes back to the hub inside settings, where
home_page.dart:292 had set `Page.other` (T-L8: no reads while settings are on screen). From then on reads run under the
settings page. Fix: pass `back: nl.Page.other` from the hub.

### m8. The same-fingerprint sentence asks for something the app cannot show (appendix B question)

team_pages.dart:38 「指紋也相同，請用加入時間分辨」 — no page shows a join time (appendix B says so). Same 8-character
fingerprint with a different owner is the grinding case a malicious member would build. An instruction the leader
cannot follow is worse than none. Suggest replacing it with an action that works with what is on screen, e.g.
「指紋也相同：兩組都移除，再重新邀請要留的那位」, without new mechanism.

### m9. 8.3's reads use the same lease name as the removal

remove_pages.dart:96 names each info read 「移除隊員」, the same constant as the `OfflineOp` at :120. If a read's lease is
taken back by the 420 s `pageGone` cap, the home todo title is 「上一個操作可能沒有存完：移除隊員」 (lease.dart:152) for a
read that wrote nothing, and if an offline-op todo with the same title is still listed, `unsavedText` gives the read
the offline-op sentence (home_page.dart:315-320, keyed by title). Fix: name the reads like 8.5 does (「讀節點網路」,
join_pages.dart:564).

---

## Ownership / contracts summary (checked)

| Resource | Writers found | Verdict |
|---|---|---|
| net / mnet / mpend records | `RecordWriter` under an `OfflineOp` lease or `OwnerConsole` step loop only (grep for `storeWriteCas` / `storeRemove` in lib/ui: none) | one writer ✅ |
| `NodeLink.hints` | `NodeLink.setHint` / `setPage` only | ✅ |
| `AppLink.devTrust` | main.dart:154 only (B3) | ✅ |
| `InviteHolds` | 7.8 only (`take` / `drop`) | ✅ |
| `RemoveTicks` | own methods, called from 8.3 (`removed`) and 8.4 (`tick`) | ✅ |
| `unsavedTodos` / `unsavedText` | registry adds, home page removes (both maps together) | ✅ (see m9 for the title-key collision) |
| clipboard | copy / clear buttons, paste-then-clear | ✅ |
| UiState | no team write (T-U6) | ✅ |

## Verdict

0 BLOCKER / 3 MAJOR / 9 MINOR. **APPROVE-WITH-CHANGES** — no change to the design is needed: M1 and M2 implement R12
as the frozen plan already wrote it (or list each cut row in appendix B with its reason), and M3 adds the two source
checks the plan already names.
