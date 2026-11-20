# Code review A: commit b9f210b (fix/329-fast-retry) against 329-fast-retry.md v4.2

Read-only review: source read with `git show b9f210b:...`. Nothing was run: no flutter or gradle runs, as instructed. I also read the flutter_reactive_ble 5.6.0 Dart `DeviceConnectorImpl.connect` in the pub cache.

## What checks out (with evidence)

- **§2 steps 1–5, in order** (`node_link.dart` `_connect`, ~1136–1169):
  - Fast-failure test: `e != 0 || done || now()-t0 >= fastMax` returns early.
  - Step 1: the trace line, then `await link.close()`.
  - Step 2: `after(settle)` raced against due and cancel; `stop()` always runs.
  - Step 3: `done || !still()`.
  - Step 4: `gate.connect`, then `onLink`, in one synchronous block (no await between step 3 and step 4).
  - Step 5: one `first()` with the same `due`. There is no path to a third connect.
- **Links are closed on every exit.**
  - `onLink` moves `mine`/`_link` (`_run`) and `link` (`_lfAttempt`) at each connect.
  - `close()` is idempotent (`ble_gate.dart` `close() => _closing ??= _close()`), so the extra closes (`_abort` on the first link in the window, `mine?.close()` after a Refused second connect) are harmless.
  - The first link is down when `first()` gives 0 through `_on(false)` (connect stream onError/onDone also map to `_on(false)`), so step 1 does not wait.
- **`_link` is never null in the window.** `_run` nulls it only after the end (`if (identical(_link, mine)) _link = null`).
- **A Refused from either connect** goes to the caller's `on Refused` and becomes noResponse. The first link is already off the table.
- **Guard (b)** (`ble_gate.dart` listener): `f == null && l._open && !l._first` skips the down.
  - A closing link (`_open = false`) still completes `_gone`; the gate-only test "close ends on the cancel's own down" pins this.
  - `_first` is set in `_on`.
  - It matters only in the asyncExpand window: flutter_reactive_ble `connect()` builds the link's own stream from the same global stream, filtered by `deviceId`, after the `connectToDevice` call returns. This matches the design's shape (b).
- **Kotlin patch 3.**
  - `@Volatile failed` is set in a `doOnNext` placed before the side-effect `doOnNext`, and in `doOnError`.
  - `isFailed()` is checked in both branches. In the timer branch it is checked inside `doFinally`, before `disposeSubscriptions()`, so `.value` is still readable.
  - It fails safe: a connector that is not failed sends the DISCONNECTED as before.
- **Kotlin tests.**
  - (1), (2) and (5) count only the updates after `disconnectDevice`. Without the skip they would see 1 DISCONNECTED, because `connectionStatusUpdates` was already initialised on the failure, so they discriminate.
  - The outer `@BeforeEach`/`@AfterEach` also run around the nested class; harmless.
  - `PLUGIN_MUST` is single-quoted, so the `$` survives.
- **Security.**
  - Every new trace line goes through `mask`. The gate lines print only the last 2 characters of the address.
  - `codelessDowns` keeps full addresses in memory only, bounded to 4 times × 16 addresses.
  - No secrets.

## Findings

### MAJOR-1: the parser's stale-event check is masked by the first failure's own `fail=` line, so it can pass a bad run

- **Scenario.** The target event is the first connector's late code-less DISCONNECTED, landing just after the second connect. Its offset `d` is in (second ≈ 400, ~1000] ms from the first failure.
  - `fast-retry-stats.py:80-81`: `at = r['t'] + d`, excused when any gate `fail=` line for the address is within ±1000 ms of `at`.
  - The first failure's own `fail=133` line sits at ≈ `r['t']` (the gate list holds every gate line, `:43`), so `|g - at| ≈ d ≤ 1000` and the event is excused.
  - So the signature is invisible in exactly the range it targets, in both shapes (`connected=-1` and `connected>=0 … noResponse`).
  - The design §7 wording ("within ±1 s") has the same hole; the parser implements it literally.
- **Second gap.** The parser has no test of its own: nothing shows that a bad log FAILs and a good one PASSes.
- **Fix.**
  - Excuse a down only with a `fail=` line that comes after the second connect: `g > r['t'] + r['second']` and `|g - at| <= 1000`. Or attribute each gate line to at most one down.
  - Add a small self-test with synthetic logcat lines:
    - stale down at +500 with the first failure's `fail=133` at +5 → FAIL;
    - the second failure's own down with its `fail=133` → PASS;
    - no retries → FAIL.
  - Correct the §7 wording to match.

### MINOR-2: the parser misses lost retries and flags non-failures

- **Lost retries pass.** A `link failed … connecting once more` line followed by an attempt line without ` retried` is ignored silently (`stats.py:62-66`; the pending entry is popped, then `continue`). A second connect that was Refused, or skipped for any reason, passes unseen. Design §7 says "every fast failure … has a retry line".
  - Fix: count or list these. FAIL unless a cancel or abort explains them.
- **The fast-failure test is a heuristic.** `conn == -1 and after < 1500` also matches:
  - a first-connect cancel (page leave, BT off, round cancel within 1.5 s);
  - a Refused, or an exception.

  These FAIL a good run.
  - Fix: require a `fail=` gate line for the address near the attempt end.
- **loginFor is never checked for missed retries.** Its line has no `connected=`, so `conn` is None. The login path is ⚠️ anyway; state it in the output.

### MINOR-3: `done` depends on microtask order, not on the completers' state (`node_link.dart` `_connect`)

- **Scenario (`_lfAttempt`).** Between the settle wait's `Future.any` completing and the `await` resuming, another microtask completes `cancel` (`_lfStop`, `revoked`, `stopBudget`).
  - The `done = true` listener is queued after the resumption, so the step-3 check sees `done == false`.
  - `still()` (lease checks) can still be true, so a second connect is made for a login already cancelled.
  - The link is closed within a microtask (`cancel.then(-1)`) and costs one radio connect.
- `_run` is safe: `_abort` clears `_attempt` before completing cancel, so `still()` is false.
- **Fix.** Pass `bool Function() stopped` from the callers, reading `due.isCompleted || cancel.isCompleted` directly, and test it at both checks.

### MINOR-4: a Refused second connect leaves no trace

- `gate.connect` throws before the `second connect` trace. `c` stays null, so the attempt line has no ` retried` and no `downs=` (`node_link.dart` ~1162 and ~1080; `_lfAttempt` ~624).
- Together with MINOR-2, the device run cannot see it.
- **Fix.** Catch Refused in `_connect` around step 4, trace `'$what $a second connect refused'`, then rethrow or return `up=false, retried=true`.

### MINOR-5: Dart test coverage against §5 and §7, and the negative controls

- **§5 rows without a test:**
  - `acquire(forNode)` in the window;
  - cancel or `_abort` after step 4, with an assert that the second link is closed and `gate.links == 0` (the `_abort` path closes `_link` = the second link);
  - "BT off, radio status before the failure", and "the retry starts, then `radio()` aborts it".
- **The stale-on-linkStates test runs on `_run` only.** §2.1 says both `_run` and `_lfAttempt`.
- **Missing `gate.links == 0` asserts.**
  - `_lfAttempt` has no second-failure test with this assert (the `link` re-pointing in `_lfAttempt` is unguarded by any failing test).
  - T4 dispose and T6 do not assert `gate.links == 0` (§5: "every case").
- **Negative control (2), `settle = 0` → "T1 fails (stale false)":**
  - `RetryRadio` models patch 3: no DISCONNECTED on cancel after a failure, so T1 has no stale false.
  - With settle = 0, T1 would fail only on the `1000..1100` timing assert.
  - Either restate the control, or add a fake mode without patch 3.
- **Negative controls cannot be verified here.** The manual negative controls (Dart 1–4 and Kotlin "skip removed → (1), (2) fail") are not in the commit. The PR must carry their output.
- **`connected=` is never asserted.** It should be measured from the second connect (`k.t`).

### MINOR-6: Kotlin test (4) asserts 2 DISCONNECTEDs; design §2.1 says "exactly one in that span"

- The extra one is the `startWith` of `connectionStatusUpdates`, first touched in `disposeSubscriptions`. The test comment explains it, but the design text is now wrong.
- It also couples the test to upstream's lazy-init detail.
- **Fix.** Update §2.1, or assert `>= 1`. The negative-control value is in (1), (2) and (5) anyway.

### MINOR-7: the retry failure's class and status are not logged

- §4 ⚠️ and §6 say "any retry failure's class / status is logged without the message", to check for `BleAlreadyConnectedException` on the device.
- Only the gate's `fail=` code exists. A message without a status shows only as `fail=?`, with no class.
- **Fix.** Log it at the gate (the `failure` runtime type or kind only), or drop the claim from the design.

## Verdict

**APPROVE-WITH-CHANGES.**

- The app and plugin code does what v4.2 says: step order, invariants, no await between steps 3 and 4, idempotent closes, timers cancelled, both Kotlin branches.
- MAJOR-1 must be fixed before the device acceptance run: as written, the parser can pass the very failure it exists to catch. It needs a self-test with a bad log that FAILs.
- MINOR-2 through MINOR-7 can be folded into the same revision.
