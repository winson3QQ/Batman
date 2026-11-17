# #329 PR 5 code review, round 2, reviewer B

Scope: `git diff 2e18de6..HEAD -- app` on `feat/329-pr5` (HEAD 67b8b50), against plan v16 (§0–§6, appendix B incl.
B12–B14). The whole PR was reviewed again, not only the round-1 fixes. Emphasis: security and the field threat
model (removed member, malicious member, compromised own node, pasted / scanned codes, clipboard, screenshots, the
dev gate, logs, z, the lease), and R12's new second-lease judgement.

What I ran (Windows host, no phone, no WSL):

```
$ flutter test --no-pub test/flows/offline_op_test.dart test/flows/rekey_send_test.dart test/flows/team_holds_test.dart \
    test/flows/owner_console_pr5_test.dart test/flows/net_index_test.dart test/flows/net_run_test.dart \
    test/nodelink/prober_hint_test.dart test/ui
00:25 +845: All tests passed!

$ dart analyze lib test
3 issues found.   (all `info`: team_deps.dart:101 unintended_html_in_doc_comment, two unnecessary_* in tests)
```

Everything else is from reading the source; file:line is the worktree at 67b8b50. Findings marked "inferred" were
not reproduced by a test I ran (I was told not to edit other files, so I wrote no new test).

---

## Round-1 findings: are they fixed?

| A's finding | Status | Evidence |
|---|---|---|
| M1 8.3 stuck behind PopScope | fixed | remove_pages.dart:138-146 releases `_running` at once and shows `kUnknownWait`; r12_revoke_test.dart:62-69 asserts `canPop` while the work still hangs |
| M2 R12 table | fixed, one gap (m3 below) | removal remove_pages.dart:165-185; import join_pages.dart:470-499 (prepare with `pendPlain: null`, mpend removed in the judge lease); update :658-688; drop :287-303; busy -> 再查一次 in each; tests r12_revoke_test.dart:71-188 |
| M3 source checks R18 / R14 | fixed | rekey_send_test.dart:161-177 (asserts `uses > 3`, so an empty scan fails), :181-197 (asserts `results >= 4`) |
| m1 openNet key error clears hint | fixed | app_link.dart:100-106 now throws; prober.dart:270 keeps the old value |
| m2 setState after dispose | fixed where reported; same class remains elsewhere (m1 below) | remove_pages.dart:84, join_pages.dart:384 |
| m3 8.4 candidate loop | fixed | remove_pages.dart:323-333 |
| m4 refresh after send | fixed | send_key.dart:40 `widget.app.link.refresh()` |
| m5 clip warning after any copy | fixed | code_view.dart:224 |
| m6 stale-record sentence in 8.5 | fixed | join_pages.dart:540-543 `updateFailLine` |
| m7 hub back page | fixed | team_hub.dart:40 `back: nl.Page.other` |
| m8 same-fingerprint sentence | fixed (B12) | team_pages.dart:38 |
| m9 8.3 read lease name | fixed | remove_pages.dart:99 `'讀節點網路'` |

---

## Attacks tried, actor by actor (held, not reported)

**Removed member who must lose access (R9, R12, R14, R17, 8.4).**
- 8.4 lists every own node of the record read *now* (`netPeople(...).isSelf`, remove_pages.dart:285-288). Joining
  nodes are listed. Nodes without last four or without a phone record are listed with what to do next (:381-384).
  An excluded node is not in the self group any more, so it is never offered the new key.
- A send to the wrong node is stopped twice: `expectDac` before anything else (rekey_send.dart:97), and Rust's
  `NotListed` (batman-proto updflow.rs:166 matches `dac_pub_hash` **and** `owner_pub` in the record). So even a node
  that lies about its network in info gets nothing it is not already entitled to.
- `rekeyEnd` is anchored on both ends, the last four come from the phone's record (owner.rs:717), anything else is
  `failed` (rekey_send.dart:22-31). `NetRun` no longer counts 「正在套用」 as success, and the run's hero is warn while
  any row is applying (net_pages.dart diff around `_NetRunPageState` hero). The leader's rule text always says
  「沒看到這兩句…被移除的人仍可能連得上」 (rekey_result.dart:12-13), independent of `removedThisRun`.
- R12 removal judgement: "removed" only when the whole owner is absent from the record, read in a new lease
  (remove_pages.dart:171-176); a record that does not open, or `netPeople` throwing, is "結果不明" (fail-closed).

**R12 second lease (the new judgement).**
- The judgement waits for the revoked work to really end (`judgeAfterRevoke` awaits `settled`, offline_op.dart:103-107;
  `settled` completes in the work's `finally`, :131) and then takes a lease of its own through `OfflineOp.run`
  (constant name `kJudgeName`, busy -> 再查一次, its own 60 s cap). Its only write, the leftover `mpend` removal, goes
  through `RecordWriter` under that lease (join_pages.dart:480).
- Could a stale or another record make the import judgement delete a legitimate request? `AlreadyImported` without a
  request requires the approval's per-node secrets to equal the stored mnet's secrets byte for byte and verify with
  the stored admins (approve.rs:470-474); the secrets carry the node's dac hash (approve.rs:386-388). So it means
  "exactly this approval was imported", not "some mnet exists". The only way to lose a newer request is a new
  `joinreq` for the same network created between the mnet write landing and the judgement, which needs the
  revoked work to be already past its write; the window is the time `w.remove` takes to throw `NoLease`. This is
  also what the old console accepted (nodes.dart:1024 「a request written meanwhile is removed too」).
- Meanwhile the user can leave, and another operation can take the radio: the revoked work's later writes are
  refused because `RecordWriter._check` runs before the store call (record_writer.dart:27-33, :40-41). A write
  already in flight at the cap may land; the judgement then sees it (r12_revoke_test.dart:146-188 covers this).
- The judgement after the page is gone: removal / update / drop return at `!mounted` before any `setState`; the
  import judgement may still remove the leftover mpend, which is the intended tidy-up.

**Malicious member forwarding an old genuine bundle (T-M1).** 8.5 shows Rust's prepare sentence verbatim
(join_pages.dart:625), warns on `AlreadyImported` (:612), and the member's `RekeyResult` never ticks
(rekey_result.dart:48) and always shows the version line and 「這台還沒換好…」 unless `current` (:57-58). The
version is read from the record step 3 handed to Rust, under the same lease (rekey_send.dart:141-142). The Rust
`version` field is the known gap (brief); until then the screen says 「版本讀不到」, which is fail-closed for the
read-aloud check.

**Compromised own node lying in info / status.**
- Hint: `v.netId` from the node only selects which of the phone's own records is opened (`netKnown` first,
  prober.dart:262); the hint is display only (R9). A node claiming `nodeState == 1` can clear its hint card — an
  accepted consequence of R8/R9, and the leader's rule text does not rely on the card.
- `current` relies on the node's own k9: §5 states this residual risk; nothing new.
- 8.5 `_list`: a node claiming this network is listed; sending to it is refused by Rust unless its dac is the
  member's own entry.

**Pasted / scanned codes (R1, R5).** Every code goes to Rust as is: `parseInvite`, `netCheckJoinreq`,
`approvalNetId` / `memberImportPrepare`, `updateNetId` / `memberUpdatePrepare`. Dart only upper-cases for the QR.
Rust error strings shown on screen are `invite_err` reasons (member.rs:25: never a secret). Paste > 300 000 is
refused before Rust (code_view.dart:275). Kotlin `qrMatrix` re-checks `[0-9A-F]{1,4096}` (QrMatrix.kt) and errors
carry fixed messages. Scanned text is not length-checked in Dart, but a QR cannot carry more than ~7 089
characters, so the bound is physical.

**Clipboard (R4).** Copy is user-initiated, lower-case hex, with the sensitive extra on API ≥ 31; paste always
clears (also when refused), except the case in m4. Leaving with a copied code gives one SnackBar.

**Screenshots (R3).** Every QR and both SAS views are inside a `SecureScreen`; `SecureScreen` is ref-counted
(secure_screen.dart:24, :40), so two on one page (7.9) cannot drop the flag early. The update bundle is never shown
as text or QR (`CodeView(qr: false)`, remove_pages.dart:363).

**Dev gate (T-S5).** Every new entry I found is behind `devTrust`: settings row, hub, node page hint / 隊員 /
member join branch, 更多 rows, home row 6 second button, the mpend todo, 3.6, `NetFormPage`'s `joinChoice`
(`hasMnet: anyMnet && devTrust`). Every new Rust entry used has `dev_gate` except `request_send_update` /
`request_info` / `mnet_summary` / `net_people` / `approval_net_id`, which are reached only through gated pages.
`devTrust` is false until main sets it (app_link.dart:63, main.dart:154). See m5 for one ungated route that is
unreachable today.

**Logs, todos, UiState, URLs (T-P5-L, T-U6).** New log lines carry constant operation names and `runtimeType`
only (offline_op.dart:119, :128; prober.dart:271; net_index mnet id cut to 8). `RecordWriter` has no logger wired
(app_link.dart:152-160). Todo sentences are built from constant names (offline_op.dart:79). No team page writes
`UiState` (log_pr5_test.dart:118-120 asserts 0 writes / 0 removes). No URL is built.

**z.** ECDH output copied (`ownCopy`) and zeroed in the work's `finally` in 7.10 and 8.5 (join_pages.dart:420-444,
:602-628), the same as the old `_ownCopy` (nodes.dart:726, :1036). The platform's own buffer is not zeroed —
baseline.

**Lease (R10/R11).** No new code calls the store directly (grep `storeWriteCas|storeRemove|storeWriteSealed` in lib/ui
and lib/src/flows: none). Every work re-reads its record under the lease. `Lease.revoke` is only called by
`OfflineOp` (offline_op_test.dart:156).

---

## BLOCKER

None.

## MAJOR

None.

## MINOR

### m1. A double tap (or a page closed during the first awaits) releases PopScope while the operation runs

**Scenario.** On 8.3 the leader taps 「移除並換密碼」 twice quickly (gloves, a jolt in a vehicle). `_commit` awaits
`publicKeys()` before it sets `_running`, so the second tap starts a second `_commit`. The first takes the lease; the
second gets `OfflineBusy` and sets `_running = false` with 「另一個操作還在進行：移除隊員」 — while the first is still
signing and writing. Back now works; if the leader leaves, the first removal still lands but `if (!mounted) return`
(remove_pages.dart:137) skips `ticks.removed` and the push to 8.4, and the leader last saw a "busy" line. The removed
member keeps access until the leader finds the rekey through 8.1's fixed line or the hint card (lifecycle row
「移除寫好、還沒進 8.4」 covers the recovery, so this is not worse than the app being killed).

**Evidence (inferred from source, no test run).**
- remove_pages.dart:119-122 `final keys = await teamDeps(a).publicKeys(); setState(() => _running = true);`
  and :219 `onPressed: _ticked && !_running ? _commit : null`.
- Same pattern: remove_pages.dart:296-299 (`_bundle`), join_pages.dart:593-601 (8.5 `_got`: four awaits, then
  `setState(() => _running = true)`).
- The same awaits without a `mounted` check before `setState` (A's m2 class, not covered by the round-1 fix):
  join_pages.dart:601 (8.5 `_got`), remove_pages.dart:122 and :299, team_pages.dart:275 (7.4 `_got` after
  `askYesNo`).

**Fix (no new mechanism).** Set `_running = true` (or a local re-entry flag) before the first await, as
`ApprovePage._approve` (team_pages.dart:355) and 7.10 `_import` (join_pages.dart:418) already do; check `mounted`
after each await. Test: tap twice before `publicKeys` completes -> one `OfflineOp`, `canPop` false until it ends;
negative control: today's order -> second busy line and `canPop` true.

### m2. The judgement's own todo points at a page that does not exist

**Scenario.** The judgement itself runs past 60 s (a Keystore that hangs again). The home todo then reads
「…請重新打開「確認結果」那一頁看結果…」 — there is no page named 確認結果.

**Evidence.** offline_op.dart:79 builds the todo from the operation name; :99 `kJudgeName = '確認結果'`; :106 the
judgement runs as `OfflineOp.run(d, kJudgeName, judge)`.

**Fix.** Either name the judgement after the operation it judges (the same constant, so the todo sends the user to
the right page), or give `kJudgeName` its own todo sentence through the existing `todo:` parameter. Test: judge
revoked at 60 s -> the todo names a real page.

### m3. 7.10 after a 「結果不明」 judgement: no way to try again on the page, and no 「收隊長的邀請」 for NeedsNewInvite

**Scenario.** The approval import is revoked and judged 「結果不明」 (e.g. the import never landed: prepare without
the request gives `NoRequest`). `_settled` is cleared, so 再查一次 disappears; `SasCheck` keeps its old key
(`_tries` is not incremented on this path), so its button stays pressed; `CodeInput` is hidden because `_prep` is
set. The member must leave and paste again. For `NeedsNewInvite` the page says 「結果不明」 + `kNeedNewInvite`
but has no 「收隊長的邀請」 button, while R16 / S-m2 attach that button to the same sentence everywhere else
(net_pages.dart `_member`, NetRunPage).

**Evidence.** join_pages.dart:484-498 (no `_tries++`, `_settled = null`), :509-510 (`CodeInput` only when
`prep == null`), :513-518 (`SasCheck(key: ValueKey(_tries))`), :491-492 (NeedsNewInvite line without a button).

**Fix.** On a non-busy 「結果不明」, clear `_prep` (show `CodeInput` again, as 8.5 does by clearing `_imported`,
join_pages.dart:681); on NeedsNewInvite add the same 「收隊長的邀請」 button. Test: revoke + NoRequest -> CodeInput
visible; NeedsNewInvite -> the button opens 7.8.

### m4. A clipboard read that throws leaves the clipboard uncleared (R4 「貼上之後一律清」)

**Scenario.** `Clipboard.getData` throws (a PlatformException on some OEM builds, or a clip the platform cannot
coerce to text). `_paste` throws before `_p.clear()`; the code stays on the clipboard and the user sees nothing.

**Evidence.** code_view.dart:270-271 `final text = await _p.read() ?? ''; final cleared = await _p.clear();` — no
try/finally. The R4 tests cover a refused paste (too long, empty), not a failed read.

**Fix.** Clear in a `finally` around the read; on a read error show 「讀不到剪貼簿」. Test: `read` throws ->
`clear` called once; negative control: today's code -> not called.

### m5. Two new destinations have no devTrust check of their own (unreachable in the field build today)

**Scenario.** Home row 6's primary button with `records == mpend` (home_logic.dart:94) routes to `PickPendPage` →
`MyRequestPage` (home_page.dart:189-190) without a `devTrust` check; `MyRequestPage._drop` would remove an `mpend`
record. Today a field build cannot have an `mpend`: it has its own applicationId and record folder
(build.gradle.kts:53-75) and `request_joinreq` is `dev_gate`d (owner.rs:1284). So it is not reachable, but T-S5
says 「所有新入口在 field 版都不存在」 and before this PR the same row went to the old console, whose buttons were
gated. The gate now depends on a property of a different layer.

**Evidence.** home_page.dart:189-190 vs the gated second button at :308 and the gated todo at :259.

**Fix.** `case HomeAction.seeRequest when widget.devTrust` (and the same condition on the primary button's text),
covered by the existing T-S5 test with an mpend record in a field-mode test.

---

## Ownership / contracts (checked)

| Resource | Writers found | Verdict |
|---|---|---|
| net / mnet / mpend records | `RecordWriter` under an `OfflineOp` lease (work or judgement) or the `OwnerConsole` step loop | one writer at a time ✅ |
| lease | `OfflineOp` acquire / release / revoke; judgement only after `settled` | ✅ |
| `NodeLink.hints` | `setHint` (page-guarded), `setPage` clears | ✅ |
| `AppLink.devTrust` | main.dart:154 only; false until then (fail-closed) | ✅ |
| `InviteHolds` / `RemoveTicks` | 7.8 / 8.3 (incl. its judgement) and 8.4 through their methods | ✅ |
| `unsavedTodos` / `unsavedText` | registry adds, home removes both | ✅ (m2: one wrong sentence) |
| clipboard | copy, 清除, paste-then-clear | ✅ (m4: a failed read) |
| UiState | no team write (log_pr5_test asserts 0/0) | ✅ |

## Verdict

0 BLOCKER / 0 MAJOR / 5 MINOR. **APPROVE-WITH-CHANGES.** The round-1 MAJORs are really fixed, and the R12
judgement is sound against a stale or foreign record (its `AlreadyImported` is bound to this approval's own
secrets). The MINORs are small fixes in the existing style (set the busy flag before the first await, a todo
sentence, re-show the input after 結果不明, clear in `finally`, one more `devTrust` condition). None needs a design
change.
