# Review A round 3: `docs/design/329-fast-retry.md` v3

Read-only. Checked against: the vendored plugin (`DeviceConnector.kt`, `ReactiveBleClient.kt`,
`channelhandlers/DeviceConnectionHandler.kt`, `PATCHED.md`), `app/tools/kotlin-unit-tests.sh`,
`.github/workflows/app-tests.yml`, `ble_gate.dart` and `node_link.dart`.

## The question for this round: does patch 3 close round 2 B R2-M1 / R2-M2?

No. On the paths where R2-M1 / R2-M2 can still happen, patch 3's check never fires.

### M1 MAJOR: patch 3 decides on the platform side, but the hazard is about delivery order on the Dart side

**Evidence.**

- `DeviceConnectionHandler.kt:48-50`: every connection update reaches Dart via `.observeOn(AndroidSchedulers.mainThread())`.
  So an update is not sent the moment `sendDisconnectedUpdate` runs. It becomes a runnable posted to the end of the main looper's queue.
- Dart's `disconnectFromDevice` (sent by the Repeater's `onCancel` as soon as the stream ends at the failure) and the retry's
  `connectToDevice` (sent ≥ 400 ms later) are both platform messages handled in order on the same main thread.
  ⚠️ That ordering is inferred from the Flutter Android embedding (`DartMessenger` dispatches on the platform thread); I have not
  read the engine source.

**Both branches under R2-M1's own premise (the main thread is late):**

- **Immediate branch** (the disconnect is handled ≥ 200 ms after the failure):
  - `sendDisconnectedUpdate` runs inside the disconnect handler, before the retry's `connectToDevice` has run.
  - At that moment no newer connector exists, so `isCurrent()` is true and the event is sent.
  - Its runnable is posted after the `connectToDevice` message that is already queued. So Dart first gets the reply to
    `connectToDevice` (the new stream subscribes in `asyncExpand`), then the stale `disconnected`. The new link is hit through
    both the connect stream and the gate.
- **Timer branch:**
  - The timer fires at failure + 200 ms platform time. With `settle` = 400 ms, Dart's `connectToDevice` cannot have been handled
    by then, so again `isCurrent()` is true and the event is sent.
  - If the main thread is late in running that runnable until after Dart's step 4, the gate's `linkStates` → `_downNow()` marks
    the new GateLink as down (`_down = true`; `_on(true)` does not clear it). Every `_usable` check then refuses, and the attempt
    reads `connected≥0 … noResponse`. That is exactly R2-M2.

**Conclusion.** With `settle` ≥ 200 ms, patch 3's check only matters when the newer connect is handled before the timer fires,
and that cannot happen. So patch 3 is effectively dead code on the paths that still matter. Its Kotlin tests (1)–(3) would pass,
but they do not cover the delivery-order path. The §5 row "the late DISCONNECTED → lands in the 400 ms wait" also no longer
matches v3's own §2.2.

**Fix.** Either option makes the outcome independent of timing; both are recommended.

- **(a) Plugin: suppress the event by state, not by time or generation.** When `disconnectDevice` runs on a connector whose
  result is `EstablishConnectionFailure` (`connectDeviceSubject.value is EstablishConnectionFailure`), never send the synthetic
  DISCONNECTED.
  - That failure was already reported to Dart as two `ConnectionUpdateError`s (`DeviceConnector.kt` `doOnNext`,
    `ReactiveBleClient.kt:115-121`).
  - The Dart GateLink is already `_down`, so `close()` does not wait for this event (`ble_gate.dart` `_close`).
  - A cancel while still connecting (no result yet) is unchanged. The gate's `_gone` still needs that event, otherwise a close
    would wait the full 5 s.
  - Kotlin tests: a failed connector plus a late disconnect sends nothing; a cancel while connecting still sends; an established
    connector still sends. Negative control: the guard removed makes the first test fail.
- **(b) Dart: make the gate robust whatever the plugin's timing.** Until a GateLink's own connect stream has produced its first
  event, a `linkStates` down only completes `_gone` (which is needed during a close); it does not set `_down`.
  - Before the first event, the connect stream's own `false` / error / done is what decides (`state.first` in `_run` /
    `_lfAttempt`), so no real failure is missed: a real failure always reaches the connect stream too, through the same
    `connectionUpdateStream`.
  - Dart unit test: a code-less and a coded down on `linkStates`, after step 4 and before up, still let the read happen.
    Negative control: without (b) the result is `connected≥0 … noResponse`.

With (a) and/or (b), patch 3 can be dropped (less plugin divergence) or kept as a third guard. If it is kept, its tests must
not claim to cover R2-M2.

## Everything else in v3, re-read

### m1 MINOR: the new plugin test class is not a must-run in CI

- `kotlin-unit-tests.sh:28`: `PLUGIN_MUST='DeviceConnectorTest$QueueCleanupTest OrphanConnectorTest'`. Unlike the app's tests
  (`:6`), plugin classes are **not** made must-run automatically, so a `StaleDisconnectTest` (or its replacement from M1 (a))
  that never ran would pass silently.
- §2.1 says "CI keeps the negative-control step for it as for patches 1 and 2". The CI negative controls
  (`app-tests.yml:137-155`) only judge doctored XML (empty / missing class / one failure). None of them is a "guard removed →
  test fails" mutation.
- Fix: add the class to `PLUGIN_MUST` and to the "class missing" control. State that the code-mutation negative control is run
  once by hand, with its output in the PR.

### m2 MINOR: `codelessDowns` per address is unbounded across rotating addresses

- The addresses rotate (#362), and the gate listens to the global `connectedDeviceStream` (older pages too). The map gains one
  entry per address for as long as the app runs.
- Fix: keep only addresses seen in the last 60 s, or cap the map at, say, 16 entries.

### m3 MINOR: §5 and §0 are out of date with §2.1 / §2.2

- The "late DISCONNECTED" row still claims the 400 ms wait as the guard.
- Fix: rewrite it per M1 (the guard from (a) / (b), the test, the negative control). Add a row for "main thread late ≥ settle"
  with the test from M1 (b).

### m4 MINOR: generation bump placement (only if patch 3 is kept)

- Bump the generation in `getOrCreateConnection`, inside the `getOrPut` lambda, not in the overridable
  `createDeviceConnector` (tests override it: `ReactiveBleClientTest`).
- `initializeClient()` (`ReactiveBleClient.kt:56-58`) resets `activeConnections`. State whether the generation map is reset as
  well; the fail-open "missing = current" makes either choice safe.

## Checked and fine

- B1, M1 and M2 from rounds 1–2, and round 2 m1 (`timeout: msg2`, `DeviceConnector.kt:161`), m2, m3, m4 and m5 are reflected.
- The §7 device signature (a code-less down in `downs=` after `second connect +N`, not followed within 1 s by `fail=`) detects
  the M1 scenario if it happens on the phone, so the device run is a valid detector.
- With a base rate of about 10 retries, though, a rare main-thread stall would probably not show up. That is why M1 asks for a
  structural fix, not only detection.
- Ownership:
  - `codelessDowns` is written by the gate's listener only and read only for the trace.
  - The generation map is written by `ReactiveBleClient` only.
- Security: no new input. The trace stays masked.
- Lifecycle: install, upgrade, downgrade and crash are memory-only. A downgrade to the old APK drops the plugin patch with it,
  which is consistent.

## Verdict: APPROVE-WITH-CHANGES

M1 must be fixed: M1 (a) and/or (b), with their tests and negative controls. Then re-review the whole document. While M1 is
open the rule says revise. The MINORs can be fixed in the same revision.
