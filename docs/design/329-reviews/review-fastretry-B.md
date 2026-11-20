# Review B: 329-fast-retry.md (design v1)

Reviewer: independent, read-only. Sources: worktree C:\src\Batman-fr (5b0154b + doc), vendored plugin, pub cache flutter_reactive_ble 5.6.0, Desktop\Batman\a4\a4-t2.logcat / a4-fc.logcat.

**Verdict: REJECT in its current form.** B1 is open. The design's mechanism (reconnect to the same address right after `close()`) runs into a plugin behaviour the design does not account for. Because of it the device check cannot tell "immediate retry does not work on the radio" apart from "our retry is killed by a stale event". The fix is small (B1). After it, the rest looks sound with M1/M2 addressed.

## Checked and holding (✅)
- Evidence numbers reproduced from the logs: 298 attempts, 16 fast failures (370–1070 ms), 15/16 next attempts on the same node read a body 6.4–9.8 s later. One double failure: 20:40:13 → 20:40:19, then round 181 ended `…880c: notFound`, and the next read was at 20:40:56.
- Radio-level support for the premise, which the doc does not cite: at 20:24:00.890 `Failed to read remote features status:Connection Failed Establishment`, then `on_le_disconnect Reason : 62`, then `status=133`. Android had already run `BluetoothGatt close()` / `unregisterApp` at .902–.906, before Dart reacted. The node's adverts kept arriving at .869, 01.018, 01.323 and later. So the node is advertising at once, and the stack cleaned up the GATT client itself.
- `GateLink._close`: when `_down` is already set there is no 5 s wait (`if (!_down) _gone = …`). `_links.remove` sits in `finally`, so the second `connect` is not refused for "this address has a link" (ble_gate.dart `_close`, `connect`).
- The 8 s budget and takeoverWait: `due` is created once before the connect and is not restarted. `acquire` waits on its own 8 s timer for `ended`. So the claims in §3 hold, given the cost in m1.
- The core is untouched. `_pump` starts no attempt and no kept read while `_attempt != null || gate.active > 0` (node_link.dart `_pump`).
- Line references: core.dart:527 (`freeAt = now + p.gap`) and ble_gate.dart:266 (`active > 0` refusal) are correct.

## Findings

**B1 BLOCKER: the plugin's delayed DISCONNECTED for the failed connect lands on the retry.**
- **Scenario.**
  1. The first connect fails with 133. Dart sees it about 3 ms later (log 20:24:00.898 `status=133`, then .901 `BMAPP gate link …17 down`).
  2. The per-connect stream ends, and Repeater detach calls `disconnectFromDevice`. Native `DeviceConnector.disconnectDevice` finds `diff < minTimeMsBeforeDisconnectingIsAllowed` (200 ms). `timestampEstablishConnection` is also set in `doOnNext` for an `EstablishConnectionFailure`. So `sendDisconnectedUpdate` + dispose run on a timer about 200 ms later, while `activeConnections.remove` runs at once (vendored `DeviceConnector.kt` `disconnectDevice`, `establishConnection` `doOnNext`; `ReactiveBleClient.kt:136-139`).
  3. The retry's `connectToDevice` creates a new connector. Its Dart stream is the shared `connectionUpdateStream` filtered by deviceId, and the first `disconnected` ends that stream (flutter_reactive_ble-5.6.0 `device_connector.dart` `connect`: `.where(deviceId == id)…takeWhile`). `updateListeners` of every connector is the one shared subject (`ReactiveBleClient.kt:279`).
  4. About 200 ms later the old connector's `DISCONNECTED` (no failure) therefore arrives as the retry link's first event: `false`. The gate's `linkStates` listener also `_downNow()`s every link of that address (ble_gate.dart constructor).
  5. A real connect needs 386–1277 ms to `connected` (the 15 paired successes above), so the stale event always comes first.
- **Result.** The retry "fails" at about 200 ms with no `down fail=` line, and the attempt is `noResponse`. `PATCHED.md` already names this delayed disconnect hitting "a newer connect to the same address", but guards only the queue entry, not the update.
- **Why the tests miss it.** The unit fakes (`connect_fail_test.dart:40-46`, `ble_gate_test.dart:68-74`) emit the cancel's down synchronously, on `linkStates` only. So T1 passes, the device run shows retries failing, and §7 concludes "premise wrong". That is a misattribution.
- **Fix.** Pick one:
  - (a) Before the second connect, wait until the gate has seen that address's `disconnected` without a failure on `linkStates`. Cap the wait at about 400 ms inside `due`. This is a new gate-owned contract, so write it in §4.
  - (b) A fixed pause of 300 ms or more inside the budget.
  - (c) Patch the plugin: send the delayed update only if `activeConnections[deviceId] === this`. Add a Kotlin regression test in `DeviceConnectorTest`, and a line in `PATCHED.md`.

  In every case, add a fake that emits the delayed same-address `disconnected` 200 ms after the cancel, onto both the shared stream and a newer connect's stream. That is the negative control: T1 fails without the fix. The ≤ 200 ms rule in §7 must change to match.

**M1 MAJOR: the device acceptance criterion is not discriminating.**
- **Sample size.** 40 cycles is about 85 attempts, which means about 4–5 fast failures at the observed rate of 16 in 298. With ≥ 2/3, a retry that truly succeeds only 50% of the time passes with probability 0.5 at n=3, 0.31 at n=4 and 0.19 at n=5.
- **The stop rule is wrong.** "If immediate retries fail as often as the first connect" does not work as a test: a first connect fails about 5% of the time, so the baseline is the 15/16 delayed-retry success, not that.
- **Failures are clustered.** 14 of the 16 fast failures are on …880c, and 5 of them fall in 20:40–20:44. The run must include that node, and the failures are not independent.
- **The stats tool hides retries.** `a4stats.py` does not parse retries. A retried success has `connected>=0`, so it disappears from `fast-failures`. The script is also outside the repo.
- **Fix.**
  - Run until there are at least 10 fast failures (about 100 cycles, as in t2).
  - Pass = at least 8/10 retries succeed, and **0 retry failures without a `down fail=` code** (the B1 signature).
  - Per retry, report the failure code, the gap between the two connects, `connected=`, and the time from the failure to the read.
  - Compare round `notFound` counts with the baseline.
  - Put the parser in the repo.

**M2 MAJOR: link-closing invariant with two links per attempt.**
- **Scenario.** `_run` closes `mine` at the end, and `_lfAttempt` closes `link`. If either still points at the first link, the second `GateLink` is never closed.
- **Impact.** It stays in `_links` with a token, so `gate.active` counts it (`active` getter). No timer closes a link that is not parked. `_pump` then never starts an attempt or a kept read again (it requires `gate.active == 0`): a permanent wedge until a lease revokes the token.
- **What the design covers.** §4 names only `_link`.
- **Fix.**
  - State the invariant: every GateLink opened by the attempt is closed on every exit (normal end, abort, exception, dispose, and Refused on the second connect).
  - Every T1–T5 case at both call sites asserts `gate.links == 0` at the end.
  - Negative control: leave `mine` on the first link and confirm the test fails.

**m1 MINOR: the cost of a hanging retry is not stated.** After a fast failure the attempt used to end in about 0.6 s. If the retry hangs (the 5 s Accept Timeout shape), it now runs to `due` (8 s) plus up to `closeMax` 5 s, and a takeover `acquire` waits its full 8 s. This stays within the existing bounds, but say so in §3 and §5.

**m2 MINOR: the retry trigger is broader than the evidence.**
- The rule retries any fast first `false`, error or end, but the evidence is only `fail=133`.
- The "Bluetooth off → no retry" row in T5 assumes the radio status reaches the core before the connect failure. That order is unverified on Android. The outcome is harmless either way (the second connect fails or is refused). Test both orders and drop the ordering claim.

**m3 MINOR: §1 overstates the user-visible gain.**
- In two-node rounds the 6–8 s gap is partly filled by the other node's read (20:40:13 fast failure on …880c, then …7d2c read at 20:40:15).
- The real gains are single-target or node-page reads, and rounds that end `notFound` after two fast failures (round 181).
- "43 s" counts from the first failure; it is 36 s from the second.

**m4 MINOR: trace and timing details.**
- Say whether `after Nms` stays measured from the first connect. It should, since it is the attempt's real length.
- The `a4stats.py` regex tolerates the trailing ` retried` (no `$` anchor) ✅.

**m5 MINOR: unverified RxAndroidBle assumptions (not vendored).**
- A new `establishConnection` on the cached `RxBleDevice` right after the error must not hit `BleAlreadyConnectedException`.
- The old connector's `connectionStatusUpdates` stays subscribed to the same `RxBleDevice` for up to 200 ms and relays the retry's CONNECTING / CONNECTED.
- Verify on the device: log the class and status of a retry failure, without the address-bearing message.

## Lifecycle and security
- **Lifecycle.**
  - Install, upgrade, downgrade and crash: in memory only, n/a ✅.
  - Dependency restart (Bluetooth off mid-retry): see m2.
  - Kept or parked links: not involved ✅.
  - App to background during the close window: `_abort` covers it, but the abort-to-pump path needs to be in T4.
- **Security.** No new input or secret. A hostile nearby device that answers with fast failures gets at most 2 connects per attempt inside the same 8 s, and does not change the perAddr/gap accounting. The new trace line is masked. No findings beyond M2 (a leaked link is an availability self-DoS).
