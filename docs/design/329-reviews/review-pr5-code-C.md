# #329 PR 5 code review, round 2, reviewer C

Scope: the whole of `git diff 2e18de6..HEAD -- app` on `feat/329-pr5` (HEAD 67b8b50), against plan v16
(`docs/design/329-pr5-plan.md`: R1–R19, §2.1–§2.12, §3, appendix B incl. B12–B14). Emphasis: correctness against the
frozen plan, ownership / contracts, lifecycle (page gone, app killed, 60 s revoke and the judgement after it, retries),
whether each round-1 finding of `review-pr5-code-A.md` is really fixed, and whether the tests fail without the code
they guard. Not reported (brief): the missing Rust side of R19, the uncommitted `rekey.rs` test module.

## What I ran (Windows host, no phone, no WSL)

```
$ cd C:/src/Batman-329pr5/app && flutter test --no-pub
00:42 +1383: All tests passed!

$ dart analyze lib test
   info - lib\ui\team_deps.dart:101:36 - ... unintended_html_in_doc_comment
   info - test\member_ui_test.dart:4:8 - ... unnecessary_import
   info - test\ui\team_pages_test.dart:165:47 - ... unnecessary_string_interpolations
3 issues found.
```

Mutation runs were done on a copy of `app/` in my scratchpad (the worktree was not touched). In that copy three
`wording_test` cases fail for a reason of the copy itself (no `rust/` and `android/` folders: `PathNotFoundException:
Directory listing failed, path = 'rust/bridge/src\*'`); they pass in the worktree run above, so they are excluded from the
mutant results below.

| Mutant (copy only) | Tests run | Result |
|---|---|---|
| 7.10 and 8.5 R12 unknown path: `_running = false; // R12 (W-m12)` -> `_running = true` (join_pages.dart:449, :634) | r12_revoke_test, join_pages_test | `+22: All tests passed!` — **survives** |
| 8.5 judgement: `done = r is OfflineDone<UpdateState>` (drop `&& r.value == alreadyImported`, join_pages.dart:677) plus 7.9 judgement: `(l, w) async => true` (join_pages.dart:292) | r12_revoke_test, join_pages_test, layout_test | `+479: All tests passed!` — **both survive** |

## Round-1 findings: are they fixed?

| A's finding | Status | Evidence |
|---|---|---|
| M1 8.3 stuck behind PopScope | ✅ fixed on 8.3, and the same release is applied on 7.9 / 7.10 / 8.5 | remove_pages.dart:138-146; join_pages.dart:272-279, :447-453, :632-640; test r12_revoke_test.dart:62-69 (8.3 only, see m1 below) |
| M2 R12 judgement table | ✅ every row implemented in a new lease via `judgeAfterRevoke` (offline_op.dart:103-107, B13); busy -> 「再查一次」, no queueing | removal / own node: remove_pages.dart:165-185 (whole owner; dac hash); 匯入同意: join_pages.dart:470-499 (`pendPlain: null`, leftover mpend removed in the new lease, NeedsNewInvite -> 結果不明 + `kNeedNewInvite`); 匯入更新包: :658-688; 放棄申請: :287-303; invite / approve / bundle -> 「結果不明，請再做一次」 (team_pages.dart:29, remove_pages.dart:313) |
| M3 source checks R18 / R14 | ✅ present, each asserts it found something | rekey_send_test.dart:159-197 (`uses > 3`, `results >= 4`) |
| m1 openNet key error clears the hint | ✅ code fixed (app_link.dart:100-105 now throws on); ⚠️ no test guards it (see m3) | |
| m2 setState after dispose | ⚠️ the two named places fixed (remove_pages.dart:84, join_pages.dart:385); the same pattern remains elsewhere (m5) | |
| m3 8.4 candidate loop | ✅ remove_pages.dart:323-333; test team_pages_test.dart:361 | |
| m4 refresh after a node-page send | ✅ send_key.dart:40 | |
| m5 clipboard warning after any copy | ✅ code_view.dart:224 | |
| m6 8.5 stale sentence | ✅ join_pages.dart:540-543 (Rust text `STALE_RECORD` owner.rs:65 equals `kStaleRecordLine`, B14) | |
| m7 hub member join back to Page.other | ✅ team_hub.dart:40 | |
| m8 same-fingerprint sentence | ✅ team_pages.dart:38, B12 | |
| m9 8.3 reads named 讀節點網路 | ✅ remove_pages.dart:99 | |

## R12's new judgement, attacked

- **Second lease.** `judgeAfterRevoke` waits for `settled` (completed in the work's `finally`, offline_op.dart:130-133,
  i.e. after the revoked work's last write attempt returned), then runs a normal `OfflineOp` named 「確認結果」. A
  revoked lease's later writes are refused by `RecordWriter._check` (record_writer.dart:27-33) because `_revoke` sets
  `_ended` and swaps the token (lease.dart:148-159). A write that had passed `_check` before the cap lands before
  `settled` completes, so the judgement sees it. Dropping `await settled` is killed by the busy test
  (r12_revoke_test.dart:88-102). ✅
- **What the user can do meanwhile.** The registry is free after the revoke, so any other operation may start; the old
  work can no longer write, and a judgement that meets it answers busy -> 「再查一次」 (no queueing). The 「移除並換密碼」
  button is hidden once `_settled` is set (remove_pages.dart:218), so a second removal cannot be started from the same
  page while the first is unknown. While the revoked work never ends, 「再查一次」 is shown but disabled (`_judging`);
  Back works. That matches R12 / W-m12 in substance.
- **Malicious or stale record.** The judged records are the phone's own sealed records, read in the new lease; a record
  that does not open -> `false` / Rust error -> 「結果不明」, never 「已經移除」 (fail-closed). The removal is judged by the
  whole owner key (AB-m3) and an own node by its dac hash (AA-m5), so a same-name or same-fingerprint group cannot fake
  it. 7.10's 「已經匯入」 needs `prepare_import` without the request to verify the pasted approval's secrets against the
  stored admins and equal the stored mnet with its entry (approve.rs:468-476); with no mnet it is `NoRequest` ->
  「結果不明」, so a hung ECDH before any write is never told to fetch a new invite. 8.5's 「已經匯入」 is `!adds` over the
  stored mnet (mupdate.rs:299), reachable only if the write landed, since the original prepare was Advance / AddSecrets.
  No finding here beyond m2 / m4 below.

No BLOCKER or MAJOR found. Everything else in R1–R19 and §2.7–§2.10 I checked against the source and found as written
or listed in appendix B; the MINOR findings follow.

---

## MINOR

### m1. The W-m12 release (PopScope) is tested on 8.3 only; on 7.10 and 8.5 a mutant keeping the page locked survives

**Scenario.** Round 1's M1 was exactly this bug class. The fix was applied on four pages, but only 8.3 has a test
(r12_revoke_test.dart:62-69 checks `PopScope.canPop`). On 7.10 / 8.5 / 7.9 nothing asserts that Back works after the cap.

**Evidence.** Mutant `_running = true` at join_pages.dart:449 and :634 -> r12_revoke_test + join_pages_test
`+22: All tests passed!` (table above).

**Fix.** In the three page tests of r12_revoke_test, after the cap assert `canPop` is true (as the 8.3 test does);
record the mutant as the negative control.

### m2. Two R12 rows have only their positive branch tested (8.5 「結果不明」, 7.9 「結果不明」)

**Scenario.** The 8.5 test is named "AlreadyImported ... -> 已經匯入 ...; else 結果不明" but only drives AlreadyImported
(r12_revoke_test.dart:135-144). 7.9 tests only "mpend gone" (:146-188). A judgement that always says done would ship.

**Evidence.** Mutants `done = r is OfflineDone<UpdateState>` (join_pages.dart:677) and `(l, w) async => true`
(join_pages.dart:292) -> `+479: All tests passed!`.

**Fix.** Add the negative row of each: 8.5 with `updateState = advance` after the cap -> 「結果不明」, no node list, the
paste input back; 7.9 with mpend still present -> 「結果不明」, not 「已經放棄」.

### m3. Round-1 m1 (openNet throws on a key error) has no test

**Scenario.** app_link.dart:100-105 now lets a `PlatformException` from `open` propagate so `_hint` keeps the last hint
(R8). Putting the old `try { … } on PlatformException { return null; }` back passes every test: the prober tests fake
`openNet` (prober_hint_test.dart:135 throws a `StateError` from the fake, not through AppLink's closure), and the commit
message lists tests "for m2-m5, m7-m9" only.

**Fix.** Either extract `openNet` from the `AppLink` factory into a function taking the store read and the platform
call (so a test can feed a throwing `open` and assert it rethrows), or add a prober test whose fake mirrors the real
contract: a previous hint set, then `openNet` throws `PlatformException` -> `got` stays empty (hint kept). The current
:135 test asserts "no hint" for a first round only, which the old code also satisfied.

### m4. A judgement can take the radio after its page is gone, and its todo names a page that does not exist

**Scenario.** The user leaves 7.10 / 8.3 / 8.5 / 7.9 while the revoked work hangs (allowed by W-m12). Minutes later
the Keystore call returns, `settled` completes, and the still-pending `_judge…` runs `OfflineOp.run(..., '確認結果', ...)`
with no page (join_pages.dart:476, remove_pages.dart:171): whatever the user is starting at that moment gets
「另一個操作還在進行：確認結果」. If that judgement itself hits the 60 s cap, the home todo reads
「請重新打開「確認結果」那一頁看結果」 (offline_op.dart:79, :99) — no page has that name.

**Evidence.** offline_op.dart:103-107 (no page check); `_judge` / `_judgeImport` / `_judgeUpdate` / `_judgeDrop` check
`mounted` only after the judgement.

**Fix.** Pass `gone: () => !mounted` (or check `mounted` after `await settled` in the page) and skip the judgement when
the page is gone, except for 7.10's leftover-mpend tidy-up which R12 wants (keep that one). For the judgement's own
todo use the operation's name, e.g. pass the original name to `judgeAfterRevoke` for the todo text.

### m5. setState after dispose: the m2 class remains on three press handlers

**Scenario.** A press awaits Keystore / store calls before setting `_running` (so PopScope is still open), the user
presses Back meanwhile, then `setState` runs on a disposed State: remove_pages.dart:121-122 (`_commit`: `await
publicKeys()` then `setState`), remove_pages.dart:298-299 (`_bundle`), join_pages.dart:593-601 (8.5 `_got`: public keys,
every node record read, then `setState`). In 8.5 the window is the longest (one store read + Keystore open per node).

**Fix.** Set `_running` before the first await (as InvitePage / ApprovePage do, team_pages.dart:193-197, :355-359), or
add `if (!mounted) return;` before the `setState`.

### m6. 7.10 after a judged 「結果不明」 leaves a pressed SasCheck and no input

**Scenario.** On the unknown path `_tries` is not incremented (join_pages.dart:447-453), and after the judgement
`_prep` stays set (:484-498), so the same `SasCheck` (key `ValueKey(_tries)`) is shown with its button already pressed
and the `CodeInput` hidden (:509-519). The member can only leave and re-open the page from the hub to paste again.

**Fix.** On a judged 「結果不明」 (not busy) clear `_prep` so the input is shown again (re-pasting runs prepare with the
mpend, the old path), or bump `_tries`.

### m7. 8.2 is stale after a removal or an exclusion

**Scenario.** 8.1 -> 8.2 (`push`) -> 8.3 (`push`) -> success -> `pushReplacement` 8.4 (remove_pages.dart:158-159). Back
from 8.4 lands on the old 8.2, which still offers 「移除小明，全隊換密碼」 (or 「排除 …xxxx」 for the node just excluded,
team_pages.dart:159-170). Pressing it reads nodes again and ends in a Rust refusal. Not unsafe (Rust refuses), but it
shows a removed person as removable, and 8.1's R19 reread only happens after the user also leaves 8.2.

**Fix.** From 8.3's success go to 8.4 replacing the 8.2 route too (e.g. `popUntil` the 8.1 route, then push 8.4), so
Back returns to 8.1, which re-reads (team_pages.dart:99-102).

### m8. R2: the QR origin is aligned to device pixels only relative to its own box

**Scenario.** code_view.dart:200-216 snaps the module size and the left inset relative to the `LayoutBuilder` box; the
box's own global offset (page padding, card padding 12 in 8.4) is not checked. On a phone whose device-pixel ratio makes
that offset fractional (for example 12 × 2.625 = 31.5), modules land on half pixels; with anti-aliasing off they are
snapped to 1-px-uneven widths. Plan R2: 「原點也對齊實體像素」. The widget test reads back from a box at an integral offset,
so it cannot see this. ⚠️ Effect on scanning not measured (only S20 was measured, P15).

**Fix.** Offset the painting by the fractional part of the box's global origin in device pixels (from
`localToGlobal`), or note in appendix B that only the S20's ratio was checked.

### m9. The commit message says "analyze clean"; it is 3 infos

`dart analyze lib test` -> 3 issues (all `info`, same three as round 1). Fix them or say "3 infos" (overclaim rule).

---

## Ownership / contracts (re-checked at 67b8b50)

| Resource | Writers found | Verdict |
|---|---|---|
| net / mnet / mpend records | `RecordWriter` under an `OfflineOp` lease (incl. the 「確認結果」 judgement removing mpend) or the `OwnerConsole` step loop; no `storeWriteCas` / `storeRemove` in `lib/ui` | one writer ✅ |
| the lease | `OfflineOp` (acquire, release, `revoke` — only caller, source check offline_op_test:156) | ✅ |
| `unsavedTodos` / `unsavedText` | registry adds; home page removes both (home_page.dart:318-322) | ✅ (m4: a misleading title) |
| `NodeLink.hints` | `setHint` / `setPage` only (node_link.dart:112-158) | ✅ |
| `AppLink.devTrust` | main.dart:154 only | ✅ |
| `InviteHolds` / `RemoveTicks` | 7.8 / 8.3 + 8.4 through their own methods | ✅ |
| clipboard | copy / clear buttons; paste always clears first (code_view.dart:270-271) | ✅ |
| `OfflineReply` contract | `retry` is `OfflineBusy` from the judgement; `unknown` carries `settled` | ✅ |

## Verdict

0 BLOCKER / 0 MAJOR / 9 MINOR. **APPROVE-WITH-CHANGES.** The three round-1 MAJORs are fixed as the plan wrote them, and
R12's new judgement holds against a second lease, a concurrent operation and a stale or unopenable record (fail-closed
to 「結果不明」). The MINORs are test gaps on the very class round 1 found (m1–m3), small lifecycle leftovers (m4–m7),
one plan detail (m8) and one overclaim (m9); none needs a design change.
