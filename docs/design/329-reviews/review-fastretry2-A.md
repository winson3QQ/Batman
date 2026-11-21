# Review A, round 2: `docs/design/329-fast-retry.md` v2

Read-only. Checked against: `node_link.dart`, `ble_gate.dart`, the vendored `DeviceConnector.kt`, pub-cache
`flutter_reactive_ble-5.6.0` (`device_connector.dart`, `rx_ext/repeater.dart`), `connect_fail_test.dart`, and the
a4 logs. The doc is untracked in the worktree (`git status`: `?? docs/design/329-fast-retry.md`).

## Round 1 findings

- **B1: closed.**
  - Line numbers checked: `DeviceConnector.kt:26` (`minTimeMsBeforeDisconnectingIsAllowed = 200L`) and `:81-86`
    (the timer path) match.
  - `timestampEstablishConnection` is set in the failure's `doOnNext` (`:130-134`), so the late DISCONNECTED goes out
    at most about 200 ms (platform time) after the failure.
  - The 400 ms `settle` starts on the Dart side, after the failure reached Dart and `close()` returned. That leaves
    about 200 ms of margin, minus the Rx timer and channel jitter.
  - If the disconnect reaches the plugin ≥ 200 ms after the failure, the DISCONNECTED is sent at once (`:87-89`).
    That happens before the retry's `connectToDevice` in the platform thread's order, and before the new Dart stream
    subscribes (`asyncExpand` after the method returns). So that case is also safe.
  - The unit negative control (`settle` = 0 → `staleHits` > 0, T1 fails) and the device signature check
    (code-less failure < 300 ms) close the gap between the model and the real radio.
- **M1: closed.** §4 fixes `_link` on the first (closed) link from step 1 to step 4. Step 3 → step 4 has no `await`.
  T6 has a negative control.
  - Abort in the window: `_abort` closes the already-closed first link (`close()` returns the cached `_closing`),
    completes `cancel`, and the `settle` race ends.
  - At `_run`'s tail, `identical(_link, mine)` is already false or null. Nothing leaks.
- **M2: closed.**
  - The parser goes into the repo (`329-reviews/` already holds `adv-id-app-nc.py`, so the precedent exists).
  - It fails on zero retry lines.
  - The bar is ≥ 10 fast failures and ≥ 8/10 reads.
  - The login path is stated as ⚠️ unit-only.
- **m1–m4: closed** (§3 radio time, §4 external resource, §5 both Bluetooth orders, §2 step order).

## New findings

### m1 MINOR: the timeout of the second connect can turn into autoConnect

- **Scenario.** Step 4 passes `timeout: <what is left of msg2>`. The plugin treats `timeoutInMs <= 0` as
  `shouldNotTimeout` and calls `rxBleDevice.establishConnection(shouldNotTimeout)` (`DeviceConnector.kt:161`). That
  first argument is RxAndroidBle's **autoConnect**: a background connect that never times out. The plugin's own
  PATCHED note on `getOrCreateConnection` warns about exactly this mode.
- **When it could happen.** `left` is computed from `now()`. `due` is completed by a separate timer, so `now() - t0`
  can reach 8000 before the `due` callback runs. Step 3 then passes and `left` is ≤ 0.
- **Likelihood and effect.** Normally this is unreachable: at step 4 `now - t0 ≤ 1500 + 400 + jitter`. If it did
  happen, `due` would still close the link.
- **Fix.** Pass `msg2` unchanged (`due` is the real bound anyway), or clamp to ≥ 1 s. Add one line to §2 saying a
  timeout ≤ 0 means autoConnect in this plugin.

### m2 MINOR: one factual error in §2 "Why 400 ms"

- **Scenario.** §2 says the late DISCONNECTED "is not sent in every case (only when the disconnect came < 200 ms
  after)".
- **Evidence.** `DeviceConnector.kt:87-89`: when the disconnect comes ≥ 200 ms after, the update is sent **at once**.
  So it is always sent; only its delay varies.
- **Effect.** The conclusion (a fixed cap) still holds.
- **Fix.** Correct the sentence.

### m3 MINOR: a parked link closing in the 400 ms window refuses the second connect

- **Scenario.** The first connect was preceded by `_makeRoom`; the retry is not. Suppose a parked kept link of another
  node is closed during `settle`, for example by the gate's `parkedMax` timer (`ble_gate.dart` `pass`) or by a frame
  arriving on it (`_park` → `gone`).
- **Evidence.** That link counts in `gate.active` while it closes (`!_open`, for up to 5 s). The second
  `gate.connect` is then `Refused` → `noResponse`.
- **Effect.** Rare, and no worse than today.
- **Fix.** Either one line in §4 saying so, or let step 3 also require `gate.active == 0` and otherwise run a
  `_makeRoom(cancel)` bounded by `due`. The first (one line) is enough.

### m4 MINOR: the device criteria need precise definitions for the parser

1. **"A second connect 400–600 ms later."** No BMAPP line gives the second connect's time. Name the source: Android's
   `D/BluetoothGatt connect() - device:` line (it is in the full logcat, e.g. `a4-t2.logcat` at 20:24:06.912). Or add
   the time from the failure to the second connect to the retry line or the attempt line.
2. **"Code-less".** The gate writes a line only when the failure carries a code (`ble_gate.dart` `_states`:
   `if (f != null)`). A code-less down leaves no line at all, whereas `fail=?` means a failure with no number.
   - Define "code-less" as no `gate link …XX down fail=` line within e.g. 1 s after the retry's attempt line.
   - Count a `fail=?` as a coded failure.
3. **"Every fast failure has a retry line."** This must exclude the second failure of an attempt that already
   retried; by design that one has no retry.
4. **"No attempt line other than retries changes (within the runs' spread)."** This is not decidable as written.
   Give a number (e.g. the non-retried connect median within ±100 ms of baseline) or drop the item.

### m5 MINOR: T1's fake must fail only the first connect

`FailRadio.failAt` fails **every** connect to that address (`connect_fail_test.dart:44-56`). T1 needs a per-call
failure (e.g. `failAt` consumed once). Otherwise T1 cannot pass even with a correct implementation, and its negative
control means nothing. This is a test-design detail; state it in §7.

## Lifecycle and security, re-read

- Paths that are covered:
  - background in the window: `core.background` → `_pump` → `_abort` → `cancel` ends `settle`;
  - dispose;
  - lease taken back;
  - takeover (a) and (b);
  - Bluetooth off in both orders.
- `takeoverWait` holds because `due` is not restarted.
- No new input and no secret. The hostile-device bound (2 connects per attempt, 4 per round) is now stated.
- No path is missing that changes the verdict.

## Verdict: APPROVE-WITH-CHANGES

B1, M1 and M2 are closed. No new BLOCKER or MAJOR. Before implementing, fix m1 (pass `msg2` or clamp the second
connect's timeout), m2 (the factual sentence) and m4/m5 (parser and fake definitions). m3 is one line in the doc.
