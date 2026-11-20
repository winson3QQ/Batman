# Review B, round 2: 329-fast-retry.md design v2

Reviewer: independent, read-only. I re-read the whole v2 and checked it against the worktree, the vendored plugin, the pub-cache flutter_reactive_ble 5.6.0 and the a4 logcats.

**Verdict: APPROVE-WITH-CHANGES.**
- M2 and M1 from v1 are closed.
- B1 is closed for the normal timing but **not provably**. §2's argument for 400 ms contains two factual errors (R2-M1). On a stalled Android main thread the stale DISCONNECTED can still reach the second link, by two routes, and one of them escapes the §7 check (R2-M2).
- The damage is bounded: a wasted retry ends `noResponse`, the same as today. So these are MAJOR, not BLOCKER. Fix both before implementing.

## v1 findings: status

| v1 | Status | Evidence |
|---|---|---|
| B1 stale DISCONNECTED | ⚠️ mostly closed (see R2-M1, R2-M2) | `settle` 400 ms covers the timer branch of `DeviceConnector.kt:81-86` when the native disconnect is handled quickly |
| M1 device criterion | ✅ closed, small gaps in R2-m1 | ≥ 10 fast failures, ≥ 8/10, signature check, parser in the repo, FAIL on zero lines. With p=0.6 the pass chance is 0.17; with p=0.94 it is about 0.98 |
| M2 link leak | ✅ closed | §2 step 4 moves `mine` / `_link` / `link` in the same synchronous step; §4 invariant; `gate.links == 0` / `active == 0` asserted in T1–T6; negative control (3). `_lfAttempt`'s end `link?.close()` and `_run`'s `mine?.close()` then hit the second link |
| m1–m5 | ✅ addressed in text | §3 worst case and radio time, §1 who feels it, §2 `after`, §5 both Bluetooth-off orders, §4 RxAndroidBle checked on device |

## Findings

**R2-M1 MAJOR: §2's timing argument for 400 ms is wrong in two places.**

- **"At most 200 ms after the failure" is false.**
  - `DeviceConnector.disconnectDevice` (`DeviceConnector.kt:74-91`) sends the update at `max(timestampEstablishConnection + 200, t_native_disconnect)`.
  - The `else` branch (lines 87-89) sends it **immediately when the native call arrives ≥ 200 ms after the failure**.
  - So the bound depends on when the Android main thread handles `disconnectFromDevice`. Nothing on the Dart side bounds that:
    - `GateLink.close()` does not wait for it. A broadcast controller's `onCancel` future is not awaited, and the Repeater's `detach` issues the call asynchronously.
    - Method calls are handled on the Android main thread (`PluginController.kt:30-32`). Updates are delivered with `.observeOn(AndroidSchedulers.mainThread())` (`DeviceConnectionHandler.kt:50`).
  - `a4cycle.sh` connects right after an app relaunch, which is exactly when the main thread is busiest.
- **"It is not sent in every case" is false.** Both branches call `sendDisconnectedUpdate` (lines 84 and 88). It is sent whenever the connector still exists. So v2's reason for rejecting "wait for the event" does not hold.
- **When Dart issues the disconnect is not shown.** It is inferred, not measured:
  - The GateLink subscription is normally already done when step 1 runs (the failure `disconnected` ends the per-connect stream through `takeWhile`), so `_sub.cancel()` there is a no-op.
  - The native disconnect then comes only from the Repeater's done → `onCancel` → `detach` path.
  - That it happens at all is proven: otherwise `getOrPut` would hand the next connect the old connector, which replays the failure, and 15/16 later connects would not have read.
  - That it happens within 400 ms is not proven. The logs contain no plugin lines (0 `RxBle` lines) and no code-less gate lines; `ble_gate.dart` traces only `f != null`.
- **Fix.**
  - Correct the text.
  - Replace the bare timer with: after step 1 returns, wait until the gate has seen a code-less `disconnected` for `a.addr` **arriving after step 1**, with a minimum of 0 and a cap (for example 1000 ms, inside `due`; on the cap: no retry, `noResponse`, fail-closed).
  - It is always sent (above). It always arrives after step 1: the timer branch sends it ≥ ~190 ms after the failure, and the immediate branch only after the native call that Dart issues during or before step 1. So "after step 1" also skips any code-less down sent at the failure itself (for example the old connector's `connectionStatusUpdates.startWith(...)`, emitted in `doOnNext` before the coded error).
  - This is exact, and usually faster than 400 ms (about 200 ms).
  - Alternatively, keep 400 ms and add the plugin guard (option (c) of v1: send only if `activeConnections[deviceId] === this`, with a Kotlin test).
  - Either way the gate owns this new contract: write it in §4 (writer: plugin; reader: gate; missing → cap → fail-closed).

**R2-M2 MAJOR: two stale-event outcomes on a stalled main thread; §7 detects only one.**

- **Scenario.** The main thread stalls for more than ~400 ms after the failure. The `disconnectFromDevice` call and the retry's `connectToDevice` are both queued, in order. The disconnect runs and its update is posted to the *end* of the main looper (`observeOn`), behind `connectToDevice`. Dart then receives the stale `false` after step 4. One of two things follows:
  - (a) The second link's per-connect stream is already subscribed and gets `false` first. This is the code-less fast failure that §7's signature check catches.
  - (b) The update arrives after `gate.connect` added the link but before the plugin stream subscribed. Only `linkStates` sees it, and `_downNow()` marks the new link down. The link then reports `true`, `probe` → `requestMtu` → `_usable` throws `Refused`, and the attempt line reads `connected=NNNms result=noResponse retried`. §7's B1 check ("code-less, < 300 ms failure") does not catch this, so it would be read as a radio failure.
- **Fix.**
  - R2-M1's event-wait removes both routes.
  - In addition, trace every code-less down for the address while an attempt is retrying. Add one gate trace line with no code (`link …XX down`); it is masked and costs one line per close.
  - In §7, FAIL any retry that reads `connected ≥ 0` with `noResponse` and has a code-less down after its connect.
  - Report, per retry, the time from the failure to the code-less down. That directly measures the plugin's delay on the device and replaces the inference above.
  - Unit test: `staleFalse` delivered to `linkStates` only, after step 4. It must fail with a bare timer and `settle` = 0, and pass with the event-wait.

**R2-m1 MINOR: in §7, "a second connect 400–600 ms later" has no source in the app log.**
- The retry trace line is written at the failure, before `settle`.
- Fix: either trace at step 4, or name the source as logcat `BluetoothGatt connect() - device: <masked>` (present: a4-t2 20:24:06.912).
- With R2-M1 the window becomes "after the code-less down, within the cap".
- The "no other attempt line changes" pass rule needs a number: for example the non-retry connect median and the body rate within the min/max of the baseline runs.

**R2-m2 MINOR: the login path is unit-tested only.**
- This is declared ⚠️ in §7, which is acceptable.
- The PR must keep it ⚠️ and must not claim device coverage.

## Checked in the window and holding (✅)
- **Abort or dispose during steps 1–2.** `_abort` sets `_attempt = null` and closes the first link again (`_closing` is reused). Step 3 then sees `!identical(_attempt, a)`. The end code closes `mine` (the first link) and clears `_link`. Nothing leaks.
- **Takeover (a).** `setPage` sets `_det` only when `_link != null` (node_link.dart:331), and v2 keeps `_link` on the closed first link through the window. `_pump` does not abort while `identical(_det, a) && _wanted(a)`.
- **Takeover (b).** `acquire(forNode)` waits for `_ended` on its own 8 s timer, so the bound holds.
- **No other link in the window.** `_pump` starts no attempt or kept read while `_attempt != null`. In a login, the lease holder is awaiting `loginFor`, and a raw lease cannot coexist.
- **Budget.** `due` is not restarted. The second connect's plugin timeout is what is left of `msg2`.
- **Citations.** `DeviceConnector.kt:26` and `:81-86` are correct.
- **Security.** No new input. With R2-M2 there is one more gate trace line, and it is masked. A hostile device still gets at most 2 connects per attempt.
