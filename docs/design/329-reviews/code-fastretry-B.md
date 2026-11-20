# Code review B: commit b9f210b (#329 fast retry, design v4.2)

Read-only review. Nothing in C:\src\Batman-fr was changed. No flutter, gradle or adb was run, so no unit test or
negative control was executed by me (⚠️). The parser was run read-only (`python3 -I`) on the baseline logs in
`Desktop/Batman/a4/`.

## Checked and found sound (evidence)

- Plugin event path. The Dart `connect` stream ends at the first `disconnected` (`flutter_reactive_ble-5.6.0/lib/src/device_connector.dart:57-64`). When its source is done, `Repeater` closes its broadcast controller, and that calls `onCancel: _blePlatform.disconnectDevice(id)` (`:74`, `rx_ext/repeater.dart:42-46,56-67`). So the plugin gets connector 1's `disconnectDevice` right at the failure, before the retry's `connectToDevice` (same method channel, in order). `activeConnections.getOrPut` therefore makes a fresh connector (`ReactiveBleClient.kt:136-138,291`), and the old failed one is never reused.
- Patch 3 (`DeviceConnector.kt:41-43,95-101,142-156`). The flag is set before the doOnNext that sends the failure's own updates, and it is read in the timer branch's `doFinally` before `disposeSubscriptions()`. A connector that is connected, or cancelled while still connecting, still sends DISCONNECTED. The gate's `_gone` never depends on the suppressed event: a failed connector always sends its own state DISCONNECTED plus two coded `ConnectionUpdateError`s (`DeviceConnector.kt:144-151`, `ReactiveBleClient.kt:111-117`). A link that is closing (`_open=false`) is marked down by any down. The baseline log shows both coded lines arriving together with the failure (`a4-t2.logcat:142416-142418`: two `fail=133` lines 1 ms before the attempt line). So no coded down from connector 1 can land after step 4.
- Kotlin tests (1)(2)(5) count only the updates after `disconnectDevice`, and each would see 1 without the skip. (3)=1 and (4)=2 pin the case where nothing is suppressed. The class is listed in `PLUGIN_MUST` (`kotlin-unit-tests.sh:28`), and the judge's `rsplit('.')` yields `DeviceConnectorTest$NoStaleDisconnectTest`.
- Guard (b) (`ble_gate.dart:89-93,170-176`). A connecting link's own connect stream is filtered from the same `connectedDeviceStream` as `linkStates` (`ble_backend.dart:31-46`). So no real down can reach only `linkStates` and then be followed by a `true`. Closing links and coded downs behave as before.
- `_connect` / `_run` / `_lfAttempt` (`node_link.dart:1136-1169,1059-1092,600-640`):
  - `onLink` moves `mine`, `_link` and `link` in the same synchronous step as the connect. `_link` is never null in the window.
  - Every exit closes the attempt's current link.
  - `Refused` on the second connect means `noResponse`.
  - A revoked token is refused by `gate._gate`, which fails closed.
  - `done` is set before the `Future.any` resumes, because its listener was registered first.
  - A second connect leaves no third connect, and `due` is not restarted.
  - No leak path was found.
- Hostile nearby device: at most 2 connects per attempt inside the same 8 s budget. `codelessDowns` is bounded (16×4) and is written only from our own connections' events. Trace lines carry only the last 2 / last 4 characters.

## Findings

### MAJOR

**M1. The device parser cannot see a stale down in exactly the window that matters.**

- Scenario: a code-less down lands on the retry between the second connect (+400..600 ms) and about +1000 ms after the first failure. This is the v1 B1 shape on a busy main thread, or any shape-(a) leak through patch 3. `fast-retry-stats.py:78-83` excuses a down when `abs(g - (t + d)) <= 1000` for any `fail=` gate line of the address. The first failure's own two `fail=133` lines sit at about `t` (baseline `a4-t2.logcat:142416-142418`, 0–1 ms before the failure). So every stale down with `d ≤ ~1000` is excused, and the run PASSES. The design §7 rule ("within ±1 s of it") has the same hole.
- There is also no fixture test for the parser, so it has no negative control at all.
- Fix:
  1. Excuse a down only with a gate line logged after the `second connect` line (g > time of that line), never with the first failure's own lines.
  2. Add a tiny synthetic-log self-test: a stale down at +700 must FAIL, and a down that comes with the retry's own `fail=` must PASS.
  3. Fix §7's wording to match.

### MINOR

**m1. A skipped retry leaves no trace and is silently dropped by the parser.**

- When the second `gate.connect` throws `Refused` (`node_link.dart:1162`, before the `second connect` trace), `c` stays null. The attempt line then has no ` retried` (`:1081-1085`).
- The same happens when the retry is skipped because `done || !still()` (`:1160`).
- The parser pops the pending retry and `continue`s (`:62-66`): it is neither counted nor flagged.
- Fix: trace `no second connect (<reason>)`. The parser should report skipped retries, and FAIL on any skip that has no cancel/abort reason.

**m2. Parser false FAIL: an attempt cut by cancel looks like a fast failure.**

- `:64` flags any `connected=-1 … after <1500` with no retry line. An attempt cut by a cancel (`a4cycle.sh` backgrounds every cycle; page change; Bluetooth off) before its first event matches too. Such an attempt takes the `e == -1` path and has no failure.
- In the 8 baseline logs all 20 flagged lines did have `fail=` gate lines, so this has not happened yet; the risk is latent.
- Fix: require a `fail=` gate line for the address within ±1 s, as the design's baseline table does.

**m3. Login path is not judged.**

- `loginFor` lines have no `connected=` and no `downs=` (`node_link.dart:637`). The parser therefore never flags a login fast failure without a retry, and never checks the stale signature on logins.
- The docstring says it judges flow logins. Either add `downs=` there or narrow the docstring. The design already marks the login path ⚠️.

**m4. The promised retry-failure class/status logging was not implemented.**

- Design §4 (review B m5) says "any retry failure's class / status is logged". The code adds nothing: only the gate's `fail=N` / `fail=?` appears.
- So the ⚠️ RxAndroidBle assumption (no `BleAlreadyConnectedException` on an immediate reconnect) has no device evidence path beyond a low read rate.
- Fix: log the second failure's `runtimeType`/code (no message), or amend the design.

**m5. Tests do not cover what design §5 claims.**

- (a) No test aborts during the second connect (Bluetooth off after step 4, or `acquire` without `forNode`) and asserts that link 2 is closed. This is the leak invariant `_abort` → `_link` = link 2.
- (b) There is no `acquire(forNode)` in-window test.
- (c) The `still()` checks have no discriminating test. In both call sites `_abort`, `revoked`, `released` and `dispose` all complete the cancel. T4/T5 pass on `done` alone, so deleting `still()` passes every test.
- (d) The stale-on-`linkStates` test exists only for `_run`; the design asks for `_lfAttempt` too.
- (e) `gate.links==0 && active==0` is not asserted in T3, T4-dispose, T5-lease or T6, although §5 says T1–T6.

**m6. Design/doc drift.**

- §2.1/§7 name `connect_fail_test.dart`, but the tests are in `fast_retry_test.dart`.
- §2.1 says Kotlin (4) asserts "exactly one" DISCONNECTED; the code asserts 2, with a correct explanation (the lazy `connectionStatusUpdates` `startWith` fires on dispose).
- §5 lists a "due during settle" T4 row that has no test. It cannot happen anyway: 1.5 s + 0.4 s is far below 8 s.

**m7. Misleading trace when a link is closed by someone else.**

- If a link is closed by someone other than the attempt, e.g. `gate.revoked` of NodeLink's token without `_abort`, `state.first` errors and returns 0. This is then traced as "link failed after N, connecting once more", although nothing failed.
- It stays safe: `still()` or the gate refuses the second connect. But it pollutes the device data (it combines with m1).

## Verdict

**APPROVE-WITH-CHANGES.**

- The app and plugin code are correct for the real-use paths I traced: the fast failure, retry and read; a page opening or Bluetooth going off in the window; the background; the lease going away; a hostile device. No leaked-link or retry-after-lease path was found.
- M1 must be fixed before the device run is taken as acceptance, because it can turn the very stale-event shape this design exists to prevent into a PASS. m1 and m2 should be fixed with it, since they decide whether the parser's counts can be trusted.

Not verified (⚠️): the Dart suite, `flutter analyze`, the Kotlin tests and every negative control. None of them were run here.
