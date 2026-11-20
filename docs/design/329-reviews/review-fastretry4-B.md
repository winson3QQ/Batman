# Review B, round 4: 329-fast-retry.md design v4

Reviewer: independent, read-only. I re-read the whole of v4 and checked it against:
- the vendored plugin: `DeviceConnector.kt`, `ReactiveBleClient.kt`, `DeviceConnectionHandler.kt`;
- flutter_reactive_ble 5.6.0 (pub cache);
- `ble_gate.dart`, `node_link.dart`;
- the older pages: `claim.dart:353`, `claim_recovery.dart:99`, `scan.dart:170`.

**Verdict: APPROVE-WITH-CHANGES.** No BLOCKER or MAJOR is open. R3-M1 is closed by (a) and (b) together. Four MINORs tighten the wording of (a) and its tests.

## R3-M1: closed ✅

### Shape (a): the stale event reaches the new connect's own stream
Guard (a) is state-based: a connector that failed never produces the synthesized DISCONNECTED. No thread ordering can make an event that is never sent arrive late. The residual race is covered in R4-m1.

### Shape (b): the stale event reaches only the gate
Guard (b) covers it from any sender.
- **Why ignoring the down is safe while connecting.** A connecting GateLink's own end always comes through its own connect stream:
  - The connector's own failure is a `ConnectionUpdateError` that carries a message. `failureCode` turns a message without a status into -1 (`fail=?`), which is non-null, so it counts as coded.
  - The connector's own `connectionStatusUpdates` starts only in `doOnNext`, at its first result (`DeviceConnector.kt` `establishConnection`).
  - The plugin timeout (`timeout(...)` → `onErrorReturn`) and "Device is not in queue" both arrive as failures with a message.
- **So the code-less downs (b) ignores come from someone else:** a superseded or stale connector, or `disconnectAllDevices`. `disconnectAllDevices` also ends the link's own connect stream, which carries the event too, so nothing is lost.
- **Closing still works.** `_close` sets `_open = false` before it waits, so (b) does not apply to a link that is closing. Its `_gone` completes on any down as today.

## Your specific questions

### 1. Is "the result is a failure" observable at `disconnectDevice` on both branches?
Mostly yes, with one ordering detail. The failure goes through the Rx chain in this order (`DeviceConnector.kt` `establishConnection`):
- `doOnNext`: it starts `connectionStatusUpdates` (its `startWith` may emit a code-less state), sets `timestampEstablishConnection`, and emits `ConnectionUpdateError`, which is posted to main by `observeOn`;
- only **after** that, the subscriber calls `connectDeviceSubject.onNext(EstablishConnectionFailure)`.

So the event Dart reacts to is posted *before* the subject holds the failure.
- The window is microseconds, on the same RxAndroidBle thread. Dart's reaction is a full round trip: main-thread delivery, then the Dart isolate, then a method call back to main, at least a few ms.
- **Immediate branch:** it runs at least 200 ms after `timestampEstablishConnection`, so the subject is set unless that thread stalled for 200 ms.
- **Timer branch:** whether it is safe depends on *where* the check is made. Checked when the timer fires, it has ~200 ms of margin. Checked on entry to `disconnectDevice`, it has only the round-trip margin. See R4-m1.

### 2. Can the subject still be empty when Dart's disconnect arrives?
Only in that race. The event would then be sent as today, at failure + 200 ms or later.
- Guard (b) covers it if it reaches only the gate.
- If the main thread *also* stalls past Dart's step 4, it can still hit the new connect's own stream (shape (a)). That needs both stalls at once; §7's signature would catch it.
- The fix for R4-m1 makes it unreachable in the timer branch.

### 3. Does (b) break links that are connecting when Bluetooth goes off, or that the stack drops without a code?
No.
- **Bluetooth off:**
  - RxAndroidBle errors the connection, the plugin emits `ConnectionUpdateError` with a message, and Dart sees a coded down plus `false` on the link's own stream.
  - NodeLink's `radio()` also cancels the round, and `_abort` closes the link.
- **A code-less drop of a *connecting* link:** I found no path that produces one only on `linkStates`.
- **If one existed anyway:** the link stays not-down, but its own connect stream still ends it. Worst case, the attempt runs to `due` (8 s). Its `close()` is unaffected.
- **Pre-existing and unchanged:** a failure posted *before* Dart subscribes the per-connect stream. For example, a synchronous error inside `connectToDevice` before the reply. The connect stream misses it, and the attempt waits for `due` (the down is coded, so (b) still marks the link). Not introduced by v4.

### 4. The older pages
- `claim.dart`, `claim_recovery.dart` and `scan.dart` each decide on the first `connected` / `disconnected` of their own connect stream, then `cancel()`. None waits for a DISCONNECTED after a cancel, and none reads `connectedDeviceStream`.
- They do not go through `BleGate`, so (b) does not touch them.
- (a) only removes an event they would no longer be listening for.
- flutter_reactive_ble's own `_disconnectionUpdates` (service-cache invalidation) also fires on the coded failure, so nothing is lost.
- ✅ No change.

## Findings

**R4-m1 MINOR: say where (a)'s check runs.** Evaluate "the result is a failure" when the update would be sent: inside `doFinally` for the timer branch, and at the call for the immediate branch. That gives the timer branch ~200 ms of margin against the order "`doOnNext` posts, then the subject is set" described above. Also add `hasThrowable()` for the "ended with an error" case. Do not rely on `connectDeviceSubject.value`: in RxJava 2, `BehaviorSubject.getValue()` returns null once the subject is completed or errored.

**R4-m2 MINOR: (a) also changes connected-then-dropped connectors, unlike what §2.1 says.**
- After a connected link drops, `connectDevice` errors. `onErrorReturn` emits `EstablishConnectionFailure`, and the subject's latest value becomes a failure.
- (a) then skips the synthesized DISCONNECTED for that connector too. §2.1 says "a connector that connected … sends it as today", which is true only while it is still connected.
- It is harmless: the drop already reached Dart (a coded `ConnectionUpdateError`, plus the state change), the GateLink is `_down`, a kept link's `_park` listener reacts to the stream, and the old pages already ended.
- Fix: correct the text. Either choose the condition "never had an `EstablishedConnection`" (closer to today), or keep "latest result is a failure" and add Kotlin test (5): connected, then dropped, then disconnect → no update.

**R4-m3 MINOR: the Kotlin tests are feasible; say how to build them.**
- (1) and (2): `establishConnection` returns `Observable.error(...)`. (2) needs `Thread.sleep(≥ 250)` after the failure, because `diff` uses `System.currentTimeMillis`.
- (3): `Observable.just(conn).concatWith(Observable.never())`.
- (4): `Observable.never()`. `timestampEstablishConnection` is then 0, so it takes the immediate branch.
- Observe through the static `connectionUpdateBehaviorSubject`, a `BehaviorSubject` shared across tests: subscribe *after* the setup, or skip the replayed value. Otherwise test (1) can see a DISCONNECTED left over from an earlier test.

**R4-m4 MINOR: the GateLink "first event" flag.**
- Set it in `_on` (true or false) and test it.
- The backend filters connect events to connected / disconnected only (`ble_backend.dart` `connect`), so CONNECTING correctly does not count.
- Add a Dart test: a code-less down on a connecting link, then `close()` → completes on the cancel's own DISCONNECTED, not after `closeMax`.

## Unchanged from round 3 and still holding (✅)
- **Retry window:** steps 1–5, the `_link` / `mine` / `link` invariant, takeover (a) and (b), abort and dispose in the window, Bluetooth off in both orders.
- **Timeouts:** `msg2` for the second connect, `due` not restarted.
- **CI:** `PLUGIN_MUST` gets the new class, and the manual negative control is recorded in the PR.
- **Device criterion:** ±1 s match, the attempt's own close kept outside `downs=`.
- **Security:** (a) and (b) only drop or ignore events and add no input. Traces stay masked. A hostile nearby device still gets at most 2 connects per attempt.
