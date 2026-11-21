# Review B, round 3: 329-fast-retry.md design v3

Reviewer: independent and read-only. I re-read the whole of v3 and checked it against the vendored plugin (`DeviceConnector.kt`, `ReactiveBleClient.kt`, `DeviceConnectionHandler.kt`, `PATCHED.md`, its Kotlin tests), the pub-cache flutter_reactive_ble 5.6.0, `app-tests.yml`, `kotlin-unit-tests.sh` and the a4 logs.

**Verdict: APPROVE-WITH-CHANGES. One MAJOR remains open.**

- Patch 3 checks "is a newer connector there?" at **send** time, on the thread that sends the event.
- The harm happens at **delivery** time, on the Android main thread and then in Dart.
- So under a main-thread stall the stale event can still reach the second link, in both shapes. §0's "v3 removes the cause" overclaims.
- §7 still detects it, and a hit costs only a wasted retry (`noResponse`, as today). But the closure claim and the fix location must change.

## v2 findings: status

| Finding | Status |
|---|---|
| R2-M1: timing argument | ✅ The text is corrected: §2.2 says 400 ms is not a bound, and "always sent" is acknowledged. |
| R2-M2: two shapes, one detected | ⚠️ Detection is fixed (`downs=`, signature in both shapes). Prevention is not complete; see R3-M1. |
| R2-m1: step-4 trace | ✅ |
| R2-m2: login path stays ⚠️ | ✅ |

## Paths that send a code-less DISCONNECTED for the address (checked)

1. **`DeviceConnector.disconnectDevice`, timer branch** (`:81-86`, Rx computation thread). Patched. Covered only if the newer connector already exists **when the timer fires**; see R3-M1.
2. **`disconnectDevice`, immediate branch** (`:87-89`). Unreachable with a newer connector. `ReactiveBleClient.disconnectDevice` (`:136-139`) calls it while the old connector is still in `activeConnections`, and `getOrPut` (`:291`) cannot create a second connector before `remove`. So the guard there never trips, and Kotlin test (3) cannot be built through the client; see R3-m1.
3. **The old connector's `connectionStatusUpdates`.** It relays real state changes of the shared `RxBleDevice` and lives until `disposeSubscriptions`.
   - That happens at the failure + 200 ms (timer branch) or at the native disconnect (immediate branch). Either way it is before the native `connectToDevice` of the retry, because the main thread processes method calls in order and Dart sends the disconnect first.
   - It can only re-emit the new connection's own states, which are not stale. Its `startWith` emission happens at the failure, before step 1.
   - Not a hole. ⚠️ This relies on the RxAndroidBle device-state relay (not vendored) not emitting a late DISCONNECTED for the *old* teardown. The logs support that: `BluetoothGatt close()` / `unregisterApp` ran at 20:24:00.902–.906, before Dart reacted.
4. **`disconnectAllDevices`** (`:141-144`). Called only from `DeviceConnectionHandler.onCancel` (`:27-28`, the event channel losing its Dart listener). That is not on the retry path, so it is unaffected.
   - Pre-existing: it does not clear `activeConnections`. A later connect to that address then gets the disposed connector, whose completed `BehaviorSubject` emits nothing, so the connect hangs until `due`.
   - Out of scope; one line in `PATCHED.md` would be enough.
5. **`ConnectionUpdateError` at the failure** (`DeviceConnector` `doOnNext` and `ReactiveBleClient.connectToDevice` subscribe, `:116`). These carry a code, so there are two `fail=133` lines per failure in the logs. Not stale for the retry.

## Findings

**R3-M1 MAJOR: the patch 3 guard runs at send time; the harm happens at delivery time.**

*Scenario: timer branch.*
- The timer fires at failure + 200 ms on the computation thread. No newer connector exists yet, because Dart only sends the retry's connect at failure + 400 ms or later. So `isCurrent()` is true and the event is sent.
- `DeviceConnectionHandler` delivers through `.observeOn(AndroidSchedulers.mainThread())` (`:50`). If the main looper or the Flutter UI thread is busy from about failure + 200 ms past Dart's step 4, Dart receives the event after `gate.connect` has already put the second `GateLink` in `_links`. That happens synchronously, before the native call.
- The result is shape (b): the gate's `linkStates` listener `_downNow()`s the new link, then the probe gets `Refused`, and the attempt line reads `connected≥0 … noResponse`.
- Shape (a) is also possible: the `connectToDevice` reply reaches Dart before the event, so `asyncExpand` has already subscribed the per-connect stream (`device_connector.dart` `connect`), and the stream's first event is `false`.

*Scenario: immediate branch.*
- Dart's `disconnectFromDevice` reaches a stalled main thread at least 200 ms after the failure. It sends at once (current, so not guarded) and posts the event behind the retry's `connectToDevice`, which may already be queued.
- Result: both shapes again.

Neither is excluded by a 400 ms `settle`. The stall is plausible during the first rounds after an app relaunch, which is exactly what `a4cycle.sh` exercises. That message ordering on the main looper and the Flutter task runner is FIFO is inferred, not measured.

*Fix, two parts:*
1. **Plugin: decide at delivery, on the main thread.**
   - Stamp each `ConnectionUpdate` from `sendDisconnectedUpdate` with its connector's generation.
   - Drop it in `DeviceConnectionHandler`'s main-thread subscriber when the address's generation has moved on.
   - Generation bumps also run on the main thread (in `connectToDevice`), so the check and the bump are ordered with no TOCTOU. Today's check-then-send on the computation thread has a small race of its own.
   - An event delivered before the bump reaches Dart before the `connectToDevice` reply, so before the per-connect stream subscribes. That closes shape (a).
2. **Gate: an open link that has not yet had its own first connect event ignores code-less `linkStates` downs.**
   - The connect stream is the authority while connecting: the link's own failure always carries a code (`ConnectionUpdateError`), and its own `connectionStatusUpdates` starts only after that first event.
   - Once the link is closing (`_open == false`) or has had its first event, code-less downs count as today, so `close()`'s `_gone` wait is unchanged.
   - That closes shape (b).

*Tests:*
- A Dart unit test: stale code-less `false` on `linkStates` only, after step 4. It must fail without the gate rule.
- A Kotlin test: the timer fires before the newer connect, and the newer connect is processed before delivery (use a `TestScheduler` as the main-thread scheduler via `RxAndroidPlugins`). It must fail with the send-time guard only.

*Docs:* change the §0 / §2.1 wording from "removes the cause" to what is actually proven.

**R3-m1 MINOR: Kotlin test (3) and the immediate-branch guard are unreachable.** As in path 2 above, the immediate branch cannot meet a newer connector through `ReactiveBleClient`. The test could only construct a `DeviceConnector` with `isCurrent = { false }`, which tests the lambda, not a field path. Its negative control proves nothing about real behaviour. Either drop it, or keep the guard as defence-in-depth and say so. With R3-M1's delivery-time check this point disappears.

**R3-m2 MINOR: CI wiring is overstated.**
- `app-tests.yml:137-155` contains judge-level negative controls only: an empty result, a missing must-run class, an injected failure. None of them removes a patch.
- "Guard removed → (1) fails" is therefore a one-off manual control. It must be recorded in the PR with output, as for patches 1 and 2.
- Add the new test class to `PLUGIN_MUST` (`kotlin-unit-tests.sh:28`), or a missing `StaleDisconnectTest` would not FAIL the judge.
- Tests (1) and (2) are feasible as stated: real `DeviceConnector` and real timer, like `QueueCleanupTest.delayedDisposeKeepsNewerEntry`, which uses `Thread.sleep(500)`.

**R3-m3 MINOR: the §7 signature can raise a false FAIL.**
- "A code-less down … not **followed** within 1 s by a `fail=` line": when a connected retry is dropped by the node during msg2, the coded `ConnectionUpdateError` and the code-less state DISCONNECTED can arrive in either order.
- Fix: match a `fail=` line within ±1 s.
- Also say that the attempt's own end-of-attempt close is outside `downs=`. It is, because `_run` traces before `mine?.close()`; state it so the parser keeps that.

**R3-m4 MINOR: the generation map's lifetime is unstated.**
- It should live next to `activeConnections` in the companion (static), and it should not be reset by `initializeClient`. Otherwise connectors from a previous client instance (engine re-attach) check a map nobody bumps.
- Like `BleGate.codelessDowns`, it gains one entry per address and never shrinks. With rotating addresses (#362) that is unbounded but tiny; prune, or state the bound.

## Checked and holding (✅)
- **Retry window:** steps 1–5, the `_link` / `mine` / `link` invariant, takeover (a) and (b), abort or dispose in the window, Bluetooth off in both orders. `_pump` starts no attempt or kept read while `_attempt != null`.
- **Second connect timeout:** `msg2`, because `DeviceConnector.kt:161` treats a timeout ≤ 0 as no timeout. `due` bounds the attempt.
- **§4 rare case:** a parked link that starts closing in the window → `Refused` → `noResponse`. Correct; `connect` refuses when `active > 0`.
- **Native disconnect is issued:** proven indirectly. Otherwise `getOrPut` would return the failed connector and replay the failure, and the 15/16 reads 6–10 s later would not exist.
- **Security:** no new input. Patch 3 only drops events. Traces are masked. A hostile device still gets at most 2 connects per attempt.
