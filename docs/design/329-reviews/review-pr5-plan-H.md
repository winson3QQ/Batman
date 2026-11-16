# Review H — #329 PR 5 plan v4 (round 4)

Reviewer H. Focus: security and fail-safe behaviour of the new parts. I reviewed the whole v4 document. Every claim
below was checked read-only against the worktree `C:/src/Batman-329pr5` (main 2e18de6 plus the uncommitted
QrScanActivity change). The baseline (219 §7.4/§7.6, member-join v6.1, remove-member v6.5, 254-app-qr, the old
console functions, Rust entry points, PR 3/4 mechanisms) was used only as a reference. I did not re-review it.

Actors I attacked as: a remote attacker on the messaging app, a local unprivileged app (clipboard, screenshots,
accessibility), a compromised member or node, physical capture, and our own mistakes (the implementer following
the plan literally).

Summary: **0 BLOCKER / 2 MAJOR / 8 MINOR. Verdict: APPROVE-WITH-CHANGES.**

---

## MAJOR

### H-M1 — The update hint, as ordered in 2.3, runs after the prober has disposed the session, so it never appears in the field and the planned test cannot see this

**Scenario.** The plan says (2.3, "先交讀取結果、再算提示"): first call `done(Outcome(...StatusView...))`, then
compute the hint with `session.updateHint(...)`, wrapped in try/catch with a 2 s timeout. Any exception just means
"no hint this round".

In `SessionProber.probe`, `done` only completes the internal completer (prober.dart:69-71). Then:
- `probe` resumes at `await result.future` (prober.dart:188);
- it runs the cleanup: `answer?.cancel()`, `inbox.handle(null, null)`, `await sub?.cancel()`, and then
  `s?.dispose()` (prober.dart:190-203);
- it returns `o`, and NodeLink closes the link right away (node_link.dart:541-553).

The hint first needs `openNet` (a Keystore platform call that takes milliseconds), and only then calls
`session.updateHint`. By that time `s.dispose()` has nearly always run. `update_hint` is a method on the session
(owner.rs:1099-1101) that reads `self.page_info` and `self.node`, so on a disposed FRB opaque it throws. The planned
try/catch then swallows the error, so the result is **no hint, every round, silently**.

This is exactly D-M1 (fail-open: the node is behind on secrets and the UI says nothing) coming back through a
different door.

**Why the plan's tests miss it.** T-P5-H uses "假 session 回落後的 page_info". A Dart fake does not model
`dispose`, so it passes. The negative control (not calling `updateHint` → FAIL) does not catch this either.

There is also a contradiction. "先交讀取結果" (deliver the read result first) is impossible as written: NodeLink only
gets the outcome when `probe` *returns*, not when `done` runs. To deliver the result first and compute the hint
after, the session would have to outlive `probe`.

**Ownership finding.** Two users now share one resource, the `OwnerSession`: the prober cleanup, which disposes
it, and the hint computation, which uses it. The plan does not name an owner for the session's lifetime.

**Fix.** Pick one owner for the session, and write the choice into 2.3. Either:
- (a) compute the hint inside `probe`, after `result.future` and before `s?.dispose()`. Do this only when `o` is a
  `Res.body` StatusView with a `netId`, bounded by the 2 s, and accept that the outcome is up to 2 s later; or
- (b) for that case only, hand the session to a detached hint task that owns `dispose` (in its `finally`, also on
  timeout or cancel), and return `o` at once.

Either way, the test fake must refuse `updateHint` after `dispose` (throw like FRB does). Then add the negative
control: compute after dispose (the v4 text) → FAIL, the chosen design → PASS. Plan one test on the real device as
well: an S20 read of a node that is behind shows the card. Put this test next to the T7/T7b behaviour that 2.3
cites.

### H-M2 — In 8.4, what counts as "已送出" (sent) is undefined, and the state never resets on a second removal, so the "N 台節點沒換到新密碼" banner can hide a node the removed person can still use

The v4 own-node list (F-M1 fix) depends on one in-memory mark per node, "已送出 = 這次開 app 送成功過" (2.6 item 10).
The banner "還有 N 台節點沒換到新密碼，被移除的人仍連得上它們" counts every node that is not "已送出". That makes this
mark the only guard the leader sees against "a removed member keeps access unnoticed". Two parts of it are not
specified.

**(a) Success criterion.** `sendUpdateFor` returns a `ConsoleReply` of kind `answer` for **failures** as well. Rust
sends `[REQ_FAIL] …` texts as `OwnerKind::Answer`: `update_text`, owner.rs:1090, with the cases listed at
rekey.rs:430-458 (`Unfinished`, `NotChanged`, `NeedsSoftware`, `TooFar`, `NodeNewer`, `SignFailed`, `Broken`, …).

An implementation that marks "已送出" on `kind == answer` (the obvious reading of "送成功") would therefore mark a
node whose update was refused as sent. The banner drops it, and the removed person keeps using that node with the
old PSK.

The success test must be `r.starts('[UPDATED]')`, using the `ConsoleReply.starts` helper (owner_console.dart:123).
`[UPDATED]` covers `Updated`, `AlreadyCurrent` and `Applying`. `unclear` (the 360 s timeout, `sendUnclearLine`) and
`notSent` must stay "還沒送" or "結果不明".

**(b) Invalidation.** The mark is not keyed by record version, and the ownership table (3.1) does not list it at
all. Here is a field scenario the plan itself creates: 8.2 says a same-name second identity "要一起移除得各按一次"
(each one needs its own removal).
1. The leader removes group 1 (version v+1).
2. The leader hands out bundles and sends v+1 to the own nodes, which are now "已送出".
3. The leader removes group 2 (version v+2).
4. The 8.4 page for v+2 shows every own node as "已送出", and the banner reads N = 0.
5. In fact every own node is on v+1, which group 2 still holds, so group 2 keeps access unnoticed.

`RemoveTicks` is cleared on a new removal (2.5), but nothing says the same for the per-node sent marks.

**Fix.**
- Define the mark as `(netId, recordVersion) → Set<dacHash>`, set only on a reply that `starts('[UPDATED]')`, and
  show "已送出" only when the stored version equals the record's current version. Alternatively, clear the mark in
  the same place `RemoveTicks` is cleared, and on any new record version.
- Add the mark to the 3.1 ownership table, with its single writer (8.4 or the node page's send, after an
  `[UPDATED]` reply) and its readers.
- Negative controls:
  - a fake send that answers `[REQ_FAIL] 沒有換成功，可再試` → the row stays "還沒送" and N is unchanged; counting on
    `kind == answer` → FAIL;
  - two removals in one run → after the second, every own node is "還沒送"; without the reset → FAIL.

---

## MINOR

### H-m1 — The 60 s OfflineOp cap: release versus revoke, and a write already under way

When the cap fires, 2.4 says "放掉佔用" (release the lease) and shows "沒有完成，請再試一次" (not finished, try
again).
- `Lease.release()` (lease.dart:305-310) notifies listeners with `revoked: false` and adds no
  `unsavedTodos` entry. Only `_revoke` adds "上一個操作可能沒有存完：…" (lease.dart:360-369).
- `RecordWriter._check` runs *before* the store call (record_writer.dart:397-414). A `writeCas` that passed the
  check and is waiting on the store when the cap fires still lands.

For "移除隊員" (remove a member) that means the record is rekeyed, the page says "not finished", and
`removedThisRun` stays false, so 8.4 is not entered. If the leader retries, Rust answers `NoTarget` (the person is
already gone, rekey.rs:111-113). Nothing then leads the leader to send the new secrets to the own nodes. This is
rare (the store would have to hang for about 60 s), but the outcome is the H-M2 class.

**Fix.**
- Use revoke semantics, so the home-page todo appears.
- Word the line "可能沒有完成" (may not have finished).
- After a capped remove, re-read the record. If its version moved, treat it as removed: set `removedThisRun` and go
  to 8.4.

The stated test (a signAdmin that never returns) is fine as a negative control for the refused write.

### H-m2 — The `hints` map on a transient failure

2.3 says that an exception or timeout means "這一輪沒有提示" (no hint this round). It does not say whether that
*clears* an earlier hint.
- If it clears, one slow Keystore call (or the 2 s timeout) wipes the warning card for a node that is still
  behind.
- Fail-safe would be: a failed or timed-out computation keeps the last hint. Only a successful computation
  replaces it (an empty result clears it). Forget or record removal deletes it, as written.

Add a widget or unit test: hint shown, then the next round's `openNet` throws → the card is still there.

### H-m3 — The E-M1 fix is not carried through the document

v4 moved the hint and the 8.5 entry out of the 「網路」 group (2.7 :366-372). Three places still use the old wording:
- 2.6 item 14 (:346): "入口：節點頁網路分組常駐一列「貼上隊長給的新密碼」";
- 2.9 row :1752: 其他捷徑 "節點頁網路分組（手機有 mnet 時）";
- 2.9 row :1744: "節點頁網路分組的提示行（2.7）".

`_network` returns null for a joined node unless a pending network exists (node_page.dart:79-87). An implementer
who follows 2.6 item 14 would place the entry where it is never drawn. Make all three say 「更多」 or the
StatusHero card.

### H-m4 — 8.4 matches nodes by last4 + dacHash, but the data source is not given

2.6 item 10 matches a `PersonNode` to a `node/` record by "device_id 後四碼一樣、而且讀回的 dacHash 也對得上".
- The "還沒送" and "這支手機沒有這台的紀錄" rows are needed *before* any read.
- `PersonNode` carries the full `dac_hash` (bridge rekey.rs:47-52).
- `remove_own_nodes` returns the full `device_id` + `dac_hash` (rekey.rs:109-116), but it needs a target, so it
  cannot be used from the 「產生更新包」 entry, where there is none.

State where the pre-read mapping comes from: the node record's DAC, or the full device id kept in `NodeLink`'s node
list. State what happens when two own nodes share last4: they show as "這支手機沒有這台的紀錄" or ambiguous, and are
never merged. A wrong merge would mark one node's success on the other.

### H-m5 — 8.4 opened without a removal shows an alarm that is false

2.9 says 「產生更新包」 → 8.4, with "only the bundle and own-node sections". 2.6 item 10 then shows the fixed line
"還有 N 台節點沒換到新密碼，被移除的人仍連得上它們" for every node that is not "已送出" in this run.

Opened for a plain re-issue, every own node counts and the line names a removed person who may not exist. After an
app restart, the same thing happens even after a real removal. Leaders learn to ignore it.

Show the "被移除的人" wording only when `removedThisRun`. Otherwise, state per node what is known: the current hint
(H-m2) or "還沒讀到".

### H-m6 — Large bundles on the clipboard and the Binder limit

The maximum bundle is 262 144 hex characters (2.2). As a `ClipData` that is about 512 KiB of UTF-16, plus parcel
overhead, through a Binder transaction. That is near the 1 MiB per-process buffer, so it can fail with
`TransactionTooLargeException`.

§7 already marks this ⚠️. Add two things:
- the size a realistic worst case produces: Rust test, N members × 16 versions;
- `copyCode` catches the exception and shows "複製失敗" with a hint that the bundle is too large. It must not
  crash the page while a lease or `z` is around (the copy runs after `OfflineOp`, so the lease is already free: good).

### H-m7 — Logging and key-error routing of the new hint path

2.4 restricts `OfflineOp` logs to `runtimeType`. The new prober hint path has no rule of its own, and the existing
prober log lines print `$e` (prober.dart:166, :175, :185).

Specify for the hint path:
- logs contain only `runtimeType`;
- an `openNet` failure goes to `keyCheck` the same way as `openRecord` (prober.dart:143-147), or explicitly does
  not, with the reason.

Otherwise a broken Keystore shows up as "no hint" instead of X26. T-P5-L should also capture the `NodeLink` trace
during a read round with a hint.

### H-m8 — Net-record plaintext opened on every read round

With 2.3, every devTrust read of every node in a known network opens `net/<id>` (net_root, SAE) into the Dart heap.
The prober header notes this heap cannot be zeroed (prober.dart:2-4). NetIndex already opens these records, so this
is not a new class of exposure, but the frequency is new.

Compute at most once per round per (netId, record generation, node k9). Drop the reference before any further
await.

---

## Checked and holding (no finding)

- **QR limit.**
  - The input is checked twice: `[0-9A-F]`, length 1–4096.
  - The version comes from `Encoder.encode`. Dart checks `size == 17 + 4v` and the bits length, and draws only when
    v ≤ 27.
  - Anything over the limit, or an error, leaves "複製文字" only. This fails safe: the code still travels.
  - The scanner stays at 4096 characters, which is above the v27 capacity, so the two limits agree.
  - D1's ⚠️ margin of about 50 characters is acknowledged. Two maximum-length names (32 bytes each) may already push
    the first approval past v27. That only falls back to copy text, so it is a usability issue, already marked ⚠️.
- **SecureScreen.**
  - It is reference-counted (`_held`, secure_screen.dart:21-39), so the nested SecureScreens in 7.9 (CodeView + SAS)
    and the page-over-page cases keep the flag on.
  - The default `fallback` leaves the Wi-Fi page unchanged, and the new "cannot set" test locks that.
  - The SAS shown in the fallback is not secret (D6).
  - The QR is a `CustomPaint` and the hex is not on screen, so an accessibility service reading the tree gets
    nothing beyond the SAS.
- **Clipboard.**
  - minSdk is 31 (build.gradle.kts:39), so background apps cannot read the clipboard (Android 10+). The IME and the
    focused app still can, and the plan states the keyboard-history limit.
  - `EXTRA_IS_SENSITIVE` takes effect on 13+.
  - Pasting clears the clipboard with `clearClip`, and copying happens only on a press (no auto-copy).
  - The bundle and the approval are encrypted to the member's ECDH key (`z` in `member_update_import` /
    `member_import_approval`), so a clipboard leak does not expose secrets.
- **Remote attacker on the messaging app.** An invite captured in the chat only lets an attacker file a joinreq.
  SAS by voice plus "不要用傳邀請的同一個聊天室核對" covers this, as in the baseline. 7.7 honestly says the invite
  is not revoked (D7).
- **Compromised member.**
  - Same-name twins are compared on the full owner in Dart (F-m5). This matters because bridge `same_name` compares
    the 32-bit fpr (rekey.rs:93-95), which can be ground.
  - A huge joinreq or name only makes the approval copy-text only.
- **Compromised node.** An authenticated own node can only steer which of the phone's own records is opened for a
  read-only hint. `update_hint_of` compares k10 with the record's net_id (rekey.rs:471-489), so a wrong netId
  gives no hint or NOT_LISTED, never a send.
- **Gates.**
  - `main.dart:104-105` reads devTrust as `== true`, which fails closed on a channel error. `AppLink.devTrust` should
    keep that.
  - `request_send_update` has no `dev_gate` (owner.rs:1041), so the Dart gate on 「更多 → 把新密碼送給節點」 is the
    only one. T-S5 covers it (§6 step 8).
  - In a field build no net record is ever opened for hints.
- **OfflineOp fail-closed.** After release or revoke, `Lease.valid` is false and `RecordWriter._check` refuses the
  write (record_writer.dart:397-402, lease.dart:263). A second operation's lease has a different token, so a late
  write from the first one is refused too. The only gap is the write already under way (H-m1).
- **§2.9 table.** I compared it with nodes.dart:1733-1770: 加入網路, 檢查網路, 忘記加入中的節點, 狀態頁,
  把新密碼送給節點, 隊員名單／移除, 產生更新包, 貼上更新包, 邀請隊員, 貼上隊員的申請, 貼上邀請, 貼上同意碼, 申請加入,
  再顯示申請, and 軟體更新, which is not a member button. Every member button has a row. The only problems are the
  stale "網路分組" wording (H-m3).
- **E-M2.** The condition at node_page.dart:81 and the mnet/mpend branch at net_pages.dart:352-360 are as the plan
  describes, and the planned change addresses them.

## Verdict

**APPROVE-WITH-CHANGES.** H-M1 and H-M2 are both small changes to the text, but each one is the guard that stops a
removed person from silently keeping access. Each needs the stated negative control before implementation starts.
