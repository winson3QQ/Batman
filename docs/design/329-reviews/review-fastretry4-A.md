# Review A round 4: `docs/design/329-fast-retry.md` v4.1

Read-only. Checked against: the vendored plugin (`DeviceConnector.kt`, `ReactiveBleClient.kt`,
`DeviceConnectionHandler.kt`, `PluginController.kt`, `ProtobufMessageConverter.kt`, `lib/src/converter/protobuf_converter.dart`),
its Kotlin tests (`DeviceConnectorTest.kt`), `ble_gate.dart`, `ble_backend.dart`, the Dart fakes (`connect_fail_test.dart`,
`node_link_test.dart`, `login_for_test.dart`, `review_pr1_test.dart`, `ble_gate_test.dart`, `kept_link_test.dart`) and
`kotlin-unit-tests.sh`.

## Round 3 M1: closed

Two state-based guards replace the send-time check.

- **(a)** removes the stale event at its source.
- **(b)** makes the gate ignore it whatever its sender or delivery time.

So they no longer depend on the order of main-thread delivery. One small cross-thread race is left in (a) (m1). On the retry path
it only matters together with a second, independent stall, and (b) plus `settle` still cover the gate shape.

## Does (b) break connecting links that the stack drops without a code?

No, as long as "code-less" in the gate means `failure == null`. Evidence:

- Every plugin failure (an `EstablishConnectionFailure`: "Device is not in queue", "Unknown error", RxAndroidBle errors on
  Bluetooth off) reaches Dart as a `ConnectionUpdateError`.
- The Kotlin converter **always** sets a failure on it (`ProtobufMessageConverter.kt:64-77`, `setMessage(errorMessage ?: "")`).
- The Dart side turns it into a non-null `GenericFailure` (`protobuf_converter.dart:88-92`, `179-194`).
- `failureCode("")` returns -1 (`ble_backend.dart`). So these are **coded** for the gate (`fail=?`), and (b) still lets them mark the link down.
- The code-less `DISCONNECTED` events of a failure (the `startWith(device.connectionState)` of `connectionStatusUpdates`, and the
  synthesized one) come through the same `connectionUpdateStream` that feeds the link's own connect stream. So the link still ends
  on its own `false`.
- `disconnectAll` (`DeviceConnectionHandler.kt:27-29` `onCancel`, `PluginController.kt:79-82` `deinitialize`) only runs when the
  event channel goes away, so nothing reaches Dart from it.
- The existing tests that send a code-less down on `linkStates` only (`review_pr1_test.dart:452-460` `goDown`, `kept_link_test.dart`
  `linkDown`, the `onCancel` downs in `node_link_test.dart:54-56` and `ble_gate_test.dart:71-73`) do it on a link that is already up,
  or on one that is closing. (b) leaves both cases unchanged.
  - `close()` sets `_open = false` before it waits (`ble_gate.dart` `_close`), so the down from the cancel still completes `_gone`.

## Findings

### m1 MINOR: (a) is not fully independent of thread timing in the immediate branch

**Scenario.** The failure's `doOnNext` (`DeviceConnector.kt:129-140`) runs in this order:

1. It first touches `connectionStatusUpdates`, which synchronously posts the code-less `DISCONNECTED`. That is the event Dart's
   connect stream ends on (`329-ble-settle.md` §2.1, I-M1).
2. Only after that does it write `timestampEstablishConnection`. This is a plain `private var`, not volatile.
3. The subscriber stores the failure in `connectDeviceSubject` later still.

If the Rx thread stalls between steps 1 and 2 for longer than a Dart round trip, Dart's `disconnectFromDevice` is handled on the
main thread while it still sees:

- timestamp 0, so `diff` is huge and the **immediate** branch runs;
- a subject value that is not yet a failure.

So the synthesized `DISCONNECTED` is sent.

**Impact.** That event is sent within milliseconds of the failure. To reach the retry's connect stream it would also need the main
thread to stall for more than `settle`. The gate shape is covered by (b). If it ever happened, the outcome is one failed retry,
which is today's result, and the §7 signature would flag it.

**Fix (cheap).** Add a `@Volatile var failed` set in a `doOnNext` placed **before** the existing one (before any listener update is
posted, so it happens-before every Dart-visible event of the failure). Check `failed` in both branches, in addition to the subject
check. Then (a) is order-independent.

### m2 MINOR: the Dart negative control for (b) cannot fail with the fakes as they are

**Scenario.** The control is: guard (b) removed → `connected>=0 … noResponse`. But `FakeProber.probe`
(`node_link_test.dart:87-92`, imported by `connect_fail_test.dart`) never makes a GATT call. Its result does not depend on
`link.up` or `_usable`, so a link marked down still "reads a body". The control would pass both with and without (b).

`LoginProber` `ok` (`login_for_test.dart:28-32`) also hands off without touching the link.

**Fix.** In this test, use a prober that makes one GATT call (e.g. `await link.requestMtu(247)` before answering), or that answers
`noResponse` when `!link.up`. State this in §2.1, for both `_run` and `_lfAttempt`.

### m3 MINOR: Kotlin tests (1), (2) and (5) must count only updates after `disconnectDevice`

**Scenario.** Both `DeviceConnectorTest` setups stub `device.connectionState` as `DISCONNECTED` (`:44`, `:182`). On the failure,
`connectionStatusUpdates`' `startWith` therefore emits `ConnectionUpdateSuccess(DISCONNECTED)` through `updateListeners`. That
happens with or without patch 3.

An assertion of "no `DISCONNECTED` update" over the whole run fails even with the fix. That makes the negative control meaningless.

§2.1 deals with the replayed static subject (R4-m3) but not with this emission.

**Fix.** Each of these tests records only the updates that arrive after the `disconnectDevice` call (or clears the captured list
right before it), and asserts that list. Tests (3) and (4) assert that list contains exactly one `DISCONNECTED`.

### m4 MINOR: the name to add to `PLUGIN_MUST`

The judge matches on the testcase classname after the last dot (`kotlin-unit-tests.sh:85-86`). An inner class therefore appears as
`DeviceConnectorTest$NoStaleDisconnectTest`, just like the existing `DeviceConnectorTest$QueueCleanupTest` (`:28`).

Write that exact token in §2.1, so the entry is not just `NoStaleDisconnectTest`.

## The rest of v4.1, re-read

- §2 steps 1–5, §3, §4 (`_link` in the window, the gate's table, `codelessDowns` capped at 16 addresses) and §5 / §7 are
  consistent with §2.1.
- (b)'s flag is set in `GateLink._on`, after the backend's filter (`ble_backend.dart` `connect`: only connected / disconnected
  pass), so the plugin's `CONNECTING` events do not count. ✅
- (a)'s check in the timer branch's `doFinally` reads the subject before `disposeSubscriptions()` completes it. ✅
- (a) skipping a connector that connected and then dropped is harmless. Its `onErrorReturn` emitted a coded
  `ConnectionUpdateError`, which reaches the link's stream and the gate. The flutter_reactive_ble `_disconnectionUpdates`
  clean-up (`reactive_ble.dart:329`) also fires on that `disconnected`.
- The other tests are writable as stated:
  - Kotlin (3) `just(conn).concatWith(never())`, (4) `never()`, (5) `just(conn).concatWith(error)`;
  - the Dart stale-on-`linkStates` test needs a hook in `FailRadio.connect` to emit right after the second connect, before its
    microtask `true`;
  - the gate-only rule tests;
  - the close-after-ignored-down test.
- Security: no new input. A hostile device can only produce coded failures, which (b) still honours. The trace stays masked.
- Lifecycle: nothing persists. A downgrade reverts the plugin and the Dart side together (one APK).

## Verdict: APPROVE-WITH-CHANGES

No BLOCKER or MAJOR. m2 and m3 are needed so that the stated negative controls can actually fail. m1 is a cheap hardening that
makes the claim "whatever the thread timing" true. m4 is wording. These do not need another full review round. Check them in the
code review.
