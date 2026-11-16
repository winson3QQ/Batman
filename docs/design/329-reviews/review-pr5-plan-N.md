# Review N: #329 PR 5 plan v7 (round 7)

Reviewer N. Focus: security and fail-safe behaviour of the new parts (the hint, 8.4 / 8.5, OfflineOp with revoke, the
QR limit, the SecureScreen fallback, the clipboard, the gates, logging). Worktree `C:/src/Batman-329pr5` at main 2e18de6
plus the uncommitted `QrScanActivity.kt` resolution change. Read-only, except for this file. The baseline in §0 is not
re-reviewed.

Summary: **0 BLOCKER / 1 MAJOR / 9 MINOR. Verdict: APPROVE-WITH-CHANGES.**

## What I verified and found sound (with evidence)

- **`cleaning` flag (2.3).** The probe cleanup runs `answer?.cancel()`, then `await sub?.cancel()`, then `s?.dispose()`
  (prober.dart:188-203). Dispose always comes after an `await`. If `cleaning` is set synchronously right after
  `await result.future` (prober.dart:188), a synchronous `updateHint` either runs before dispose or sees the flag. The
  claim in 2.3 holds. The flag must be set before the first `await` in the cleanup. Write that in the code comment.
- **Cancel / due while the hint is pending.** `done` from `cancelled` / `due` (prober.dart:80-83) completes the
  result, the cleanup starts, the flag is set, and `updateHint` is skipped. So `onHint` gets no value from a read that
  ended as noResponse. This is consistent with "失敗的一輪保留上一次的值".
- **Compromised node choosing the record.** `net_id` in the StatusView is kept only when key 10 is exactly 16 bytes,
  and it is lower-hex encoded (owner.rs:2262). Together with `netKnown`, a node can only make the phone open a record
  the phone already has, and the effect is display only. §5 is correct.
- **`Lease.revoke()`.** `_revoke` sets `_ended`, adds the todo, tells the listeners and releases (lease.dart:140-149).
  `RecordWriter._check` refuses any lease that is not `reg.current` or not valid (record_writer.dart:27-33), so later
  writes are refused (fail-closed). A late `release()` on the revoked lease is a no-op (lease.dart:86, :132). An
  in-flight `store.writeCas` that already passed `_check` can still land (record_writer.dart:40-41). The plan says so
  ("結果不明").
- **Gate consistency.** The app is disabled when the flavor and Rust disagree (main.dart:104-107), so a Dart-only gate
  can rely on `devTrust`. The 3.6 button is ungated on main (add_pages.dart:124-130, :147-148), and the plan gates it.
  `request_send_update` has no `dev_gate` (owner.rs:1041-1043), as §6-8 says. D9's reasoning holds: `startRemove` and
  the update import are dev-gated, so a field build never holds a record newer than its node.
- **Names.** Rust rejects control and format characters in names (invite.rs:111-116). The full-owner same-name check
  in 8.1 is a real improvement over `same_name` (rekey.rs:95, 8-char fpr). Homoglyph names are still possible, but that
  is baseline, and the fingerprint is shown.
- **QR limit.** The checks (version from `Encoder.encode`, `size == 17+4v`, length of `bits`, version ≤ 27) fail safe:
  no QR and copy still works. The code is not a secret.
- **SecureScreen fallback.** The default with no `fallback` is unchanged (secure_screen.dart:42-46), and an error on
  the channel maps to `false` (:30). That is acceptable.
- **2.9 table vs nodes.dart:1733-1770.** Every button has a new entry, including 狀態頁 :1744, 送新密碼 :1745, the
  three dev rows :1750-1752, the four remote-invite rows :1757-1760, 申請加入 :1763-1766 and 再顯示申請 :1768.
- **AlreadyCurrent is a real positive.** `on_info` returns AlreadyCurrent only after `join_state == Applied {
  save_pending: false }` for this net_id and `k9 == version` (updflow.rs:233-258). It neither signs nor writes, so
  repeating it is safe.

## MAJOR

### N-M1: the L-M1 fix is not carried to 8.5. The member is still told to trust a missing hint card.

- **Scenario.** The leader removes X and gives member Y the bundle. Y imports it in 8.5 and presses 送出.
  1. Y gets `Applying` ("[UPDATED] 節點 …x 正在套用新密碼，稍後再看狀態頁", rekey.rs update_text) or `NotChanged`.
  2. Following 8.5's text, Y opens the node page to "確認提示卡已經消失".
  3. The card is empty for any of the reasons 2.6-10 itself lists: just entered (no read with a hint yet), `cleaning`,
     a 2 s timeout, or the hint dropped because the page is not open.
  4. Y concludes the node is updated. It stays on the old key, and X keeps mesh access through Y's node unnoticed.
- **Evidence.**
  - Plan :399: 8.5 "加同一段固定文字，請隊員到節點頁確認提示卡已經消失". This contradicts :363-366, where v7 says the
    missing card is not proof, and only "已是新密碼" from a repeat send counts.
  - Two more v6 leftovers say the same thing:
    - :362 "有沒有換好，只看基準的機制：那台下一次被讀到時的換密碼提示卡";
    - §5 :596, where the compromised-node analysis relies on "8.4 的固定文字已經提醒隊長到節點頁確認".
  - The member path reaches AlreadyCurrent in the same way (updflow.rs:252-254 run before the `Who::Member` branch), so
    the positive signal is available to 8.5.
  - The test in 2.6-10 asserts only 8.4's text. No 8.5 test exists, so nothing catches the contradiction.
- **Fix.**
  - 8.5 uses the exact same constant as 8.4 ("每台都要看到『已是新密碼』才算換好：送出後再按一次『送出』確認…").
  - Delete "確認提示卡已經消失" at :399, reword :362, and change §5 :596 to "8.4 / 8.5 的固定文字要求看到『已是新密碼』".
  - Add the 8.4 text test to 8.5: assert the constant, assert that `Applying` / `[REQ_FAIL]` show no "完成" mark, and
    use as the negative control the text changed back to "提示卡消失" → FAIL.

## MINOR

### N-m1: after a revoke, "版本變了 → 已經完成" has no stated predicate. A false "已經移除" combines with 8.4 into a fully silent fail-open.

- **Scenario.**
  1. `startRemove`'s work hangs past 60 s (rare; a local sign) and is revoked.
  2. `PopScope` is released (:261). The leader leaves and starts another write on the same net, for example 邀請隊員
     → PersistNet, which changes the store generation.
  3. The removal work then fails at `_check`.
  4. If "版本" means the store generation, the re-read shows "已經移除" and goes to 8.4 (:270).
  5. X is still in the record, so the netcfg version did not move. Every own node then answers AlreadyCurrent,
     "已是新密碼" (updflow.rs:252-254).
  6. The leader sees every positive signal, and X keeps full access.

  Related: if the leader left before the work ended, a removal that did land shows nowhere as "now go to 8.4".
- **Fix.** Define the predicate per operation.
  - Removal = the target owner is absent from the re-read `netPeople` and the netcfg version is the old one + 1.
  - Invite / approve = their own evidence, or "結果不明".
  - When the re-read cannot get a lease (busy), say "結果不明".
  - Give the revoke todo for 移除隊員 a pointer to 隊伍與邀請 → 8.1 / 產生更新包.
  - Test: an unrelated write between the revoke and the end of work → no "已經移除".

### N-m2: crash or kill after the removal commit and before 8.4 leaves no reminder apart from a node-page card that is computed only while that page is open.

- **Gap.** The lifecycle row "app 被殺" (:534) lists only `RemoveTicks`. After a restart, `removedThisRun` is false and
  8.1 shows nothing. The home page shows the own nodes as normal. The hint is computed only for an open node page
  (J-m2). The old console had the same weakness (status page only), so this is baseline-equivalent. However, the new
  home page is now the main surface.
- **Fix.** At minimum, add the row to 3.3 as a known limitation. Better: 隊伍與邀請 / 8.1 always shows the line "移除或排除之後，
  要到「產生更新包」把新密碼送到每台節點". It is static, reads nothing, and adds no new mechanism.

### N-m3: `Updated` is as strong a signal as `AlreadyCurrent`, but the fixed text names only one of them.

`on_after` returns Updated only for `Applied{save_pending:false}` with `k9 == version` (updflow.rs:322-323), the same
check as AlreadyCurrent. Requiring a second press is safe: AlreadyCurrent does not sign. But it costs one more login
and one more "包都交給隊員了嗎？" dialog per node. Suggested text: "看到『已換成新密碼』或『已是新密碼』才算換好". This is
optional. Keep the current text if a single string is preferred.

### N-m4: the screen must not give `Applying` a success look.

`Applying` starts with `[UPDATED] ` (rekey.rs update_text). The PR 3 join path treats any `[UPDATED] ` as success
(net_run.dart:302), and the member-mode join reuses it. `screenText` strips the marker (say.dart:5-8). However, any
page that picks its colour or icon from the marker will show 正在套用 as green.
- **Fix.** On 8.4 / 8.5 / the node page 送出, the look comes from the end kind and never from the marker. Extend the
  test from "no 完成 text" to "no ok look".
- For the member join (baseline PR 3 behaviour), note that `Applying` counts as ok there. The node catches up and
  nobody is removed, so it is not a finding.

### N-m5: operation and lease names reach logs and todos, so they must be constants.

- **Evidence.** `debugPrint('BMAPP op $name failed: …')` (op_session.dart:121) and `unsavedTodos.add('…${l.name}')`
  (lease.dart:144). The busy message also shows the name.
- **Risk.** If a page builds a name such as `'移除$名字'` or `'送新密碼 …$last4 $netName'`, a member or network name
  reaches logcat. That is the B-m10 rule.
- **Fix.** Make all `OfflineOp` / `OpSession` names compile-time constants. Make T-P5-L also run a failing
  `OpSession` and a revoked `OfflineOp` with a fake name present.

### N-m6: PlatformException text from the new Kotlin methods must be static.

The source check (§5, J-m8) blocks `Log.` in `QrMatrix.kt`. It does not cover `result.error("qr", e.message, …)`,
which goes to Dart. Any Dart `log('… $e')` of a PlatformException prints that message. ZXing's messages carry no
content today, but that is unverified for every path, and `TransactionTooLargeException`'s message has only a size.
- **Fix.** Use the error code with a fixed message. Dart logs `e.code` only. Add one line to T-P5-L: a fake `qr` error
  whose message contains the fake code → the code is not in the log.

### N-m7: `EXTRA_IS_SENSITIVE` below Android 13 (⚠️ unverified)

The plan says the flag "更舊的版本沒有作用". Android's clipboard guidance suggests putting the literal extra
`"android.content.extra.IS_SENSITIVE"` on API < 33, which some keyboards honour for their clipboard history. Keyboard
history is the leak the plan admits it cannot clear. I did not verify this against the current docs. Check it, and use
the literal key on all versions if it holds. This is cheap, and the codes are not secrets, so it is MINOR.

### N-m8: `clearClip` clears whatever is on the clipboard.

After copying, the user may copy something else, such as an address in the messaging app, before pressing
清除剪貼簿 or seeing the leave reminder. `clearPrimaryClip()` then wipes the user's own content.
- **Fix.** Only clear when the primary clip still carries our label or text. Reading it in the foreground is allowed.
  Otherwise just hide the button.

### N-m9: the 8.4 / 8.5 test should include the failure case the fixed text is about.

2.6-10 asserts the text and the absence of "完成". Add a black-box case that drives the real misleading path:
1. a first send returns `Applying`;
2. the node page has no hint (just entered);
3. a second send returns AlreadyCurrent;
4. assert that only after step 3 does the screen show "已是新密碼".

This turns L-M1 / N-M1 from a text assertion into a behaviour test.

## Actor walk (summary)

- **Remote attacker (intercepts a code).** No change from baseline. The codes are not secret, and SAS plus
  `SasConfirmView` are moved unchanged. 7.7 does not claim the invite is void (D7).
- **Local app on the phone.**
  - Clipboard: clear after paste, opt-in clear after copy, the sensitive flag (N-m7, N-m8).
  - Screenshots: FLAG_SECURE for every code page. The fallback hides the QR, and the SAS is shown (D6, accepted).
- **Compromised node.** It can pick only known records for the hint, and the effect is display only (owner.rs:2262).
  It can fake AlreadyCurrent, but a node that holds the keys is already out of the threat model for rekeying.
- **Malicious member.** Same-name detection uses the full owner. Control and format characters are rejected in Rust.
  Homoglyphs are baseline, and the fingerprint is shown.
- **Physical capture.** No new surface. All new entries are behind the existing app gates.
- **Our own mistakes.** N-M1 (stale text in 8.5 / :362 / :596), N-m1 (undefined re-read predicate) and N-m5 (dynamic
  names into logs) are the places where an implementer following the plan literally would ship a fail-open or a leak.

## Verdict

**APPROVE-WITH-CHANGES.** N-M1 is a text and test change in three places, and it needs no new mechanism. The MINORs
can be folded into implementation.
