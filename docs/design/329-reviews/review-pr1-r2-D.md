# #329 PR 1 code review, round 2: reviewer D (security / trust boundaries)

PR winson3QQ/Batman#339, branch feat/329-pr1 @ **e2292f0**. Code exported with `git archive e2292f0 app` into my
scratch folder (`scratchpad/core/pr1D`); the worktree was not touched. Every file of `lib/src/nodelink`, `lib/*.dart`
that I mutated was compared byte for byte with `git show e2292f0:` afterwards (no difference).

**Verdict: APPROVE-WITH-CHANGES** — 0 BLOCKER, 0 MAJOR, 10 MINOR.

No path found where a nearby device or another app can make the app use the radio twice at once, write a record
without the lease, or show a 「是 Y」 / an identity verdict from a login that did not verify the node. What remains is
memory hygiene, a deadline that a nearby device can stretch, a fail-open corner in `RawBusy`, test gaps (mechanisms
that survive mutation) and PR body / design text that says more than the code does.

## Baseline (✅ verified)

```
flutter test --no-pub test/nodelink   -> 00:07 +184: All tests passed!
flutter test --no-pub                 -> 00:20 +397: All tests passed!
```

## Negative controls I ran

Round-1 fixes, the author's mutations re-run by me (`mutate2.pl` over `test/nodelink`):

```
== M-A released: no guard for a lease taken meanwhile: killed   (RA-5 / RB-1)
== M-B nodeLinkToken = any current token: killed                (RA-5 / RB-1)
== M-C raw lease: no record diff: killed                        (RA-2 / A-M2)
== M-G next attempt while a link is closing: killed             (RB-3 / B-m1)
== M-J prober: deadline ignored: killed                         (RB-4 / RA-4, msg2 budget)
== M-M prober: session not disposed, record not zeroed: killed  (B-m2)
== M-P lease.hold does not count as busy: killed                (A-M1 x3)
== M-Y raw page idle after the pop keeps the hold: killed       (A-M1 widget)
SUMMARY killed=8 survived=0
```

My own mutations (not in the author's list):

```
== D4  record diff ignores mtime (ids only): killed             (RA-2)
== D7  gate: revoked closes nothing: killed                     (ble_gate_test x2)
== D8  run: cancel not checked after connect: SURVIVED          -> equivalent (cancel is already in the Future.any race; the prober then sees a completed `cancelled`). Not a finding.
== D9  prober: Broken login end = broken (plants Y): killed     (prober_test x3)
== D11 hold cancel not idempotent: SURVIVED                     -> MINOR-8
== D14 gate: GATT allowed on a link the stack reported down: SURVIVED -> MINOR-8
== D16 released: written ids of a release that met a new lease are lost: SURVIVED -> MINOR-7
== D17 gate: scan onDone not handled: SURVIVED                  -> MINOR-8
== D19 revoke: no todo: killed                                  (lease_test, review_pr1_test)
== D20 RecordWriter: no lease check: killed                     (lease_test x2)
== D21 prober: answer timer (20 s after msg2) not started: SURVIVED -> MINOR-8
== D22 rawIdle does not release the hold: killed                (A-M1 widget)
== D23 pump: background does not stop the scan: killed          (node_link_test)
== D24 pageGone idle does not release: killed                   (lease_test, RA-2)
SUMMARY killed=8 survived=6
```

Two extra black-box tests I wrote against `SessionProber` (a copy of `prober_test.dart` plus the two tests; removed
afterwards). Both FAIL on e2292f0:

```
D-1: a record opened after the budget is zeroed too [E]
  Expected: every element(<0>)
    Actual: [7, 7, 7, 7, 7, 7, 7, 7]
  plain record left in memory
D-2: one fragment (not msg2) within the budget, then silence: ends at the 8 s budget? [E]
  Expected: a value less than <1000>
    Actual: <2004>
  held until answerMax: 2004 ms     (msg2 budget 100 ms, answerMax 2 s in the test)
```

## Trust boundary checks that hold (✅ verified in source)

- **No 「是 Y」 / identity verdict from an unverified login.** `CertRejected` and `AuthRefused` are only reachable
  after msg2 decrypts under NXpsk0 with `psk_owner = HKDF(owner_tag_key, device_id)` (batman-proto
  `loginflow.rs:1-7`, `on_msg2` `loginflow.rs:160-176`: decrypt fails → `Msg2Undecryptable`; cert checked with
  `verify_pinned` → `CertRejected`; only then `Sign`). A nearby device without the per-device PSK can only produce
  `Msg2Undecryptable` / `Broken`; `prober.dart:95-102` maps `Broken` and anything before the Dart-side `loggedIn` to
  `noResponse`, and `failed()` (`prober.dart:50`) gives `broken` only after `loggedIn`. D9 shows the tests catch a
  wrong mapping.
- **Owner signature only after node verification**: the `Sign` action is emitted after `verify_pinned`
  (`loginflow.rs:170-176`), so a fake node cannot get the owner key to sign anything.
- **A read writes nothing**: `prober.dart:104-108` gives up on any persist / ask step (tested).
- **Gate token**: `nodeLinkToken` is null while any lease is held (`lease.dart:156`), every GATT op checks the
  token (`ble_gate.dart:238-240`), the scan-slot wait re-checks it (`ble_gate.dart:341-344`). M-B / M-V / M-W / D7
  are caught.
- **Secrets in logs**: the prober logs only `st.kind.name` (`prober.dart:106`); `core._log` keeps `addr×id` and the
  colour in memory only; nothing in `lib/src/nodelink` prints a record, a signature or a status body
  (`git grep debugPrint` → only the lifecycle name and the startup error).
- **Record diff (A-M2)**: `_changedIds` compares (id, mtime) of `records/node/<id>` (`node_link.dart:163-170`,
  mtime from `app_link.dart:64-69`). The files are in app-private storage, so no other app can touch the times;
  a spurious difference only drops memos (one more search), never keeps a stale 「是 Y」. A write that leaves the
  same mtime would need a sub-millisecond rewrite on ext4/f2fs — not a realistic path. No finding.
- **The 420 s revoke for older pages** (acknowledged in the PR body): I bounded every busy path that can outlive a
  pop. NodesPage: `_ask` waits at most `joinWait` 360 s (`member_ui.dart:231`), and `dispose` drops the link
  (`nodes.dart:146-148`) so later chained steps fail at `setState` (no live session); `_login` ≤ 60 s scan + 15 s
  connect; `_watchLink` stops on `!mounted` (`nodes.dart:686`). ClaimPage: find 60 s + 20 s connect + 90 s answer
  (`claim.dart:430`); the T1 recovery is skipped when unmounted (`claim.dart:454`); a running recovery is cancelled by
  `dispose` (`claim.dart:94`) and then waits ≤ 90 s (`claim_recovery.dart:218-222`). None reaches 420 s except a
  platform call that never returns. ⚠️ inferred from source, not run on a phone.
- **ClaimPage without `PopScope`** (deliberate choice): judged acceptable for radio safety. The hold keeps NodeLink
  out until the claim ends (bounded above, < 420 s), and a second page gets 「另一個操作還在進行：新增節點」
  (`main.dart` `_open`). The cost — the claim's result is said to a page that is gone (pre-existing F41) — is a UX
  loss, not a radio or record conflict. See MINOR-9 for the design text.

## Findings

### MINOR-1 — a record opened after the budget is never zeroed (B-m2 fix incomplete)

- **Scenario**: Keystore `open` is slow (StrongBox, a busy TEE, a phone under load) and returns after the 8 s budget
  or after the round was cancelled. `probe` has already returned and run its `finally` with `record == null`; then
  `work()` resumes, sets `record = r` and returns on `result.isCompleted` (`prober.dart:116-123`). The plain node
  record (owner tag key, pinned DAC) stays in the Dart heap until GC.
- **Evidence**: test D-1 above: `Actual: [7, 7, 7, 7, 7, 7, 7, 7]`.
- **Fix**: in `work()`, after `openRecord` returns: `if (result.isCompleted) { r.fillRange(0, r.length, 0); return; }`
  (and the same after `ownerPub` if a record is held). Add D-1 as a regression test.

### MINOR-2 — the 8 s msg2 budget ends at the first fragment, not at msg2; a nearby device stretches each attempt to 28 s

- **Scenario**: a nearby device advertising the provd service accepts the connection and sends one valid-looking
  fragment within 8 s, then nothing. `gotFrame` is set on any TX notification (`prober.dart:133-137`), so the `due`
  handler does nothing (`prober.dart:55-57`) and the attempt runs to `answerMax` 20 s → 28 s per attempt instead of
  8 s. `OwnerSession.on_frame` returns `None` while msg2 is still being reassembled (`owner.rs:824-826`,
  `login_step` `a?`), so a single fragment is enough. With a few fake addresses this uses up a round's time faster
  (3.5× per attempt); the user's nodes then show 「手機連不到節點…」 although they are in range.
- **Evidence**: test D-2 above (held 2004 ms with a 100 ms budget, i.e. until `answerMax`).
- **Fix**: treat msg2 as arrived only when `onFrame` returns a non-null step (sign / login end) — set `gotFrame` (and
  start the 20 s) there, not on the first notification. D-2 is the negative control.

### MINOR-3 — `RawBusy` is fail-open when the lease is gone

- **Scenario**: `rawBusy = true` on a lease that was already released swallows the `StateError` and lets the work
  go on with no hold (`raw_use.dart:27-32`). The lease can be gone while the page is still mounted during the exit
  animation (the push future completes at pop, `main.dart` `_open` calls `pageGone()` then, before `dispose`).
  Concrete path: NodesPage `_ask` retry branch — `setState(() => _busy = false)` (`nodes.dart:548`) releases the hold
  → `pageGone` already ran → the lease is released → `_login` (`nodes.dart:360-361`) sets busy again on a dead lease
  and scans / connects for up to 60 s with no lease, while NodeLink starts a round 6 s after the release. Same for a
  join answer landing in that window followed by `_sendUpdateFor` (`nodes.dart:519`: `if (mounted)`), which would
  also write records without a lease. The window is the ~300 ms exit animation, so rare, but it is exactly the
  fail-open the design forbids (§8 fail-secure).
- **Evidence**: source as cited; the test 「hold on a lease that was taken back throws (the page then holds
  nothing)」 documents the swallow as intended.
- **Fix**: on a failed hold, throw from the setter (or set a `rawDead` flag that the pages check before each BLE /
  record step) so the work stops; a test: release the lease, set `rawBusy = true` on a mounted page, expect the work
  not to start.

### MINOR-4 — X26 key error: only Kotlin's `keyLevel` refusal counts, and 2.4 never clears in-process

- **Scenario**: `keyError` sets `keyOk: false` only when `KeyAbilities.refusedBy(e) != null`
  (`app_link.dart:55-57`), i.e. `PlatformException(code: 'keyLevel')` (`key_abilities.dart:96-97`). Any other
  Keystore failure (an invalidated key, a TEE error) leaves `keyOk` true and each attempt ends `noResponse` → the
  node shows 「手機連不到節點」, the wrong reason. Design X26 says NodeLink asks `KeyGate` to re-check. And once false,
  nothing sets it back: the startup block runs only when `_app == null` (`main.dart` `_run`), so 「再試一次」 or a
  return to the foreground never re-checks.
- **Evidence**: source as cited; design `329-app-uiux.md:508`.
- **Fix**: on any key-use error call `KeyAbilities.read` (the live gate) and pass `keyOk: able.login`; re-check on
  `resumed` while `keyOk` is false.

### MINOR-5 — PR body overclaims: the 420 s todo is not shown anywhere in PR 1; `readWall` is unused

- **Scenario**: the PR body says the revoked lease is 「收回並在首頁列待辦」. `LeaseRegistry.unsavedTodos` is
  filled (`lease.dart:180`) but no widget reads it (`git grep unsavedTodos` → lease.dart only). Likewise A-m8
  `NodeLink.readWall` is written (`node_link.dart:263`) but never read (`node_list.dart` uses the monotonic
  「上次讀取 N 秒前」).
- **Fix**: say in the PR body that the todo and the wall-clock time are shown from PR 2; or show the todo line in the
  minimal list now.

### MINOR-6 — revoke of a raw lease is advisory only (acknowledged); make it visible in code

- **Scenario**: after 420 s `BleGate.revoked` closes only gate-owned scans / links (`ble_gate.dart:383-390`); an older
  page's own `FlutterReactiveBle` link and its direct `storeWriteCas` / `storeRemove` go on, and NodeLink resumes.
  The PR body lists it; my bound above says no current flow reaches it. Still, `raw_use.dart:1-4` says "then the
  registry takes it back" as if that stopped the page.
- **Fix**: one line in `raw_use.dart` that a revoke does not stop the page's own BLE / writes until PR 3 / 6; keep
  the bound argument in the PR body.

### MINOR-7 — "written ids wait" (A-M5 / B-M2) has no test that can fail

- **Scenario**: a raw lease L1 re-writes a node record; its release's record read lands after L2 was acquired. The
  ids go into `_writtenWaiting` (`node_link.dart:154`) so L2's release drops their memos. Remove that line and every
  test still passes (D16) — the re-claimed node would keep 身分不符 after L2. pr1-changes.md names RA-5 / RB-1 as
  the guard, but RA-5 only checks that NodeLink stays out.
- **Fix**: extend RA-5: L1 rewrites Y1 (new mtime, `certRejected` before), L2 acquired before the read lands, L2
  released → Y1 read (`Kind.read`).

### MINOR-8 — four rules have no test that can fail

- D11: `hold()`'s once-only guard (`lease.dart:110`); the test line 「end(); // a second call does nothing」 cannot
  fail because the lease has already ended. A real test: two holds, end the first twice, the lease must stay.
- D14: GATT refused on a link the stack reported down (`ble_gate.dart:239` `_down`).
- D17: a scan stream that completes without an error → `ended` (`ble_gate.dart:353` `onDone`); only `onError` is
  covered by RA-3. Without it NodeLink keeps a dead `_scan` and never retries (all nodes 「連不到」).
- D21: the 20 s after msg2 (`prober.dart:136`); without it an attempt that got msg2 and then silence waits for the
  core to cut it.
- **Fix**: one small test each (the mutations above are the negative controls).

### MINOR-9 — design text still requires `PopScope` and in-page `lease.run`

- **Scenario**: §4.4 row 「原始佔用的頁面」 (`329-app-uiux.md:577`), §5 claim (`:720`) and T-G3(d) (`:910`) still say
  ClaimPage gets `PopScope` and that pages wrap work in `lease.run`; the code does neither (hold + no PopScope). A
  later PR that follows the design would add the PopScope back or test for it.
- **Fix**: update those three places to the hold model and replace T-G3(d) with 「認領中按返回 → 佔用留到認領結束;
  另一個頁面拿不到佔用」 (already the review_pr1 A-M1 tests).

### MINOR-10 — `pageGone` runs at pop, before `dispose`; the idle-page case releases while the page's link is still up

- **Scenario**: NodesPage idle with a logged-in session; pop → `_open` calls `lease.pageGone()` as soon as the push
  future completes (pop time) → idle → released at once; the page's `dispose` → `_drop()` cancels its connection
  ~300 ms later. NodeLink waits `afterLease` 6 s (`core.dart:19`, `:253`), so there is no overlap today, but the
  only thing preventing two BLE users here is that 6 s constant, and the gate does not see the page's link
  (`gate.links == 0`).
- **Fix**: call `pageGone()` from the page's `dispose` (RawBusy can do it: `@override dispose` →
  `rawUse?.lease.pageGone()`), or note the dependency on `afterLease` next to the constant.

## Lifecycle notes (no finding)

- Background / foreground / inactive: `NodeLink.lifecycle` (T20, M-Q caught). App killed: no persistent lease state.
- Bluetooth off mid-attempt: link stream ends → `up` false or the prober's GATT fails → `noResponse`; the
  `statusStream` overlay (M-S caught). Location services off (Android ≤ 11): scan ends, retried every 2 s, bounded
  by the gate's 4 / 30 s; the nodes show 「連不到」 rather than a location reason — listed in the PR body.
- Late results after a cut: `_run` closes only its own link and drops a result whose attempt was aborted
  (`node_link.dart:256-260`, M-H / RA-1 caught).
- NodeLink start failure: `started` stays false so lifecycle / status events start nothing (`core.dart:161`); the
  older pages then run without leases and without NodeLink — no overlap.
