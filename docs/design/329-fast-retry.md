# #329: a connect that fails fast is tried once more in the same attempt

Status: design **v4.2** (2026-11-21). Branch `fix/329-fast-retry`. Checklist line of #329: 「快速失敗立刻重試一次」 (app side).
Reviews: `329-reviews/review-fastretry{,2,3,4}-{A,B}.md` (v1: both REJECT; v2, v3: APPROVE-WITH-CHANGES with a MAJOR
open; v4 / v4.1: both APPROVE-WITH-CHANGES, MINORs only, folded in v4.1 / v4.2).

## 0. Changes

- v4.1 → v4.2: round 4 A (APPROVE-WITH-CHANGES, 4 MINOR): a volatile `failed` flag for (a) (m1), a prober that makes a
  GATT call for (b)'s Dart control (m2), the Kotlin tests count only the updates after `disconnectDevice` (m3), the
  full class name in `PLUGIN_MUST` (m4).
- v4 → v4.1: round 4 B (APPROVE-WITH-CHANGES, 4 MINOR): where (a) checks (R4-m1), a connector that connected and then
  dropped (R4-m2), the Kotlin test construction (R4-m3), where (b)'s flag is set plus a close test (R4-m4).
- v3 → v4: round 3 A M1 / B R3-M1 (the same MAJOR): v3's guard ran when the event was sent; the harm comes when it
  is delivered through the main thread, so it never tripped. Replaced by two state-based guards (§2.1): (a) a failed
  connector sends no synthesized DISCONNECTED, (b) the gate ignores code-less downs on a link still connecting. The
  generation map is gone. MINORs: new test class in `PLUGIN_MUST` and a manual negative control (A m1 / B R3-m2),
  `codelessDowns` bounded (A m2 / B R3-m4), §5 rows (A m3), the ±1 s match and the close outside `downs=` (B R3-m3).
- v2.1 → v3: round 2 B (APPROVE-WITH-CHANGES, 2 MAJOR):
  - **R2-M1 / R2-M2**: the late DISCONNECTED is sent when Dart's `disconnectFromDevice` reaches the plugin (or at failure
    + 200 ms, whichever is later), and nothing bounds when that call arrives (the Android main thread). So no fixed
    wait is a proof, and an event that lands after step 4 may hit only the gate's `linkStates` (the second link marked
    down, the attempt reads `connected=NNN result=noResponse`). v3 tried to remove the cause in the plugin (replaced in v4): a
    connector sends its delayed DISCONNECTED only while no newer connector exists for that address. `settle` stays as a
    second guard. The device run logs every code-less down of the address during a retry and FAILs on the stale-event
    signature in both shapes (§7).
  - R2-m1: the step-4 trace line (already in v2.1). R2-m2: the login path stays ⚠️ in the PR.
- v2 → v2.1: round 2 A (APPROVE-WITH-CHANGES, 5 MINOR): timeout `msg2` for the second connect (m1), the late
  DISCONNECTED is always sent (m2), the parked-link-closing refusal (m3), the device criterion as the parser computes
  it (m4), the fake decides per call (m5).
- v1 → v2:
  - **B1 (A and B, BLOCKER)**: v1 reconnected at once. The plugin sends a late, code-less DISCONNECTED for an address up
    to 200 ms after a failed connect (`DeviceConnector.kt:26, 81-86`), which `329-ble-settle.md` §2.1 avoids only
    because the same address is never tried within 6 s. A reconnect inside that window gets that stale `false`. v2
    waits `settle` = 400 ms after the failure before the second connect (§2).
  - **A M1**: `_link` during the retry window is stated (§4).
  - **B M2**: every link the attempt opens is closed on every exit (§4); tests assert `gate.links == 0`.
  - **A M2 / B M1**: device acceptance rebuilt: ≥ 10 fast failures, ≥ 8/10 retries read, a code-less retry failure =
    the B1 signature = FAIL, parser in the repo (§7).
  - MINORs: the order of steps (A m3), the external resource (A m4), radio time (A m2), worst case (B m1), the gain
    stated honestly (B m3), Bluetooth off in both orders (A m1 / B m2), what `after` measures (B m4), RxAndroidBle
    behaviour checked on the device (B m5).

## 1. Problem and evidence

A "fast failure" is a connect that Android ends with `status=133` within about a second, before the link came up. The
node never saw it (node btmon: no `Device Connected` for the failed attempt; 41/41 successes matched within 1.5 s on
both nodes). Phone air log (a4-t2, 20:24:00): `.890` Connection Failed Establishment, reason 62, then 133; Android ran
`BluetoothGatt close()` at `.902–.906`; the node's adverts kept arriving at `.869`, `01.018` and later (review B). The
cause is at the radio level and is not fixed here.

Since `329-ble-settle.md` the attempt ends at the first link event, so a fast failure itself costs ~0.5 s. But the
scheduler frees that address only after `Params.gap` (6 s, `core.dart:527`); the next attempt comes ~8 s later.

✅ App logs of the A4 runs (`Desktop/Batman/a4/a4-t2.logcat`, `a4-fc.logcat`, S20, wsl.32/33), each fast failure paired
with the next attempt on the same node (both reviewers reproduced the numbers):

| | count |
|---|---|
| attempts | 298 |
| fast failures (`connected=-1`, < 1.5 s, each with `gate link …XX down fail=133`) | 16 (370–1070 ms); 14 on 02 (…880c), 5 within 20:40–20:44 |
| next attempt on the same address read a body | 15 / 16 (6.4–9.8 s later) |
| next attempt failed fast again | 1 / 16 (20:40:13 → :19, read at 20:40:56, 43 s after the first failure) |

Who feels it (review B m3): in a round with two nodes the other node's read fills part of the 8 s, so the gain is on a
node page (one target), on the last node of a round, and on a round that would end 沒找到 for that node.

⚠️ Not known: whether a connect ~0.4 s after a 133 reads as often as one 8 s later. Nothing measured it. §7 decides; if
it does not hold, the change is not shipped.

## 2. The rule

In one attempt (NodeLink `_run`, and the flows' login `_lfAttempt`), when the **first link event is a failure** (the
connect stream gives `false`, an error, or ends) — not the budget `due`, not a cancel — and it came less than
`fastMax` = 1500 ms after the connect started, and this attempt has not retried yet:

1. `await link.close()` — the link is already down, so `_close` does not wait (`ble_gate.dart` `_close`: `_gone` only
   when `!_down`); its `finally` removes it from the gate's table;
2. wait `settle` = 400 ms on the injected clock, racing `due` and `cancel` (either ends the wait: no retry,
   `noResponse`);
3. re-check, with no `await` between this and step 4: not cancelled, `due` not completed, not disposed; `_run`:
   `identical(_attempt, a)`; `_lfAttempt`: `identical(reg.current, lease) && lease.valid`;
4. `gate.connect(token, a.addr, timeout: msg2)` to the **same address** (round 2 A m1: never the remaining time —
   the plugin turns a timeout ≤ 0 into a never-ending autoConnect, `DeviceConnector.kt:161`; `due` bounds it anyway), and in the same synchronous
   step `mine` / `_link` (or `link`) = the new link;
5. from here it is the usual attempt with the **same** `due` (not restarted): its first event decides; a second failure
   is `noResponse`. Never a third connect.

### 2.1 Two guards against the late DISCONNECTED

Every sender of a code-less DISCONNECTED for the address was checked (round 3 B): the old connector's
`disconnectDevice` (timer branch `DeviceConnector.kt:81-86`, immediate branch `:87-89`) is the only one on the retry
path; the old connector's `connectionStatusUpdates` relays only real state changes of the device; `disconnectAllDevices`
runs only on the event channel's `onCancel`; the failure's own `ConnectionUpdateError` carries a code. Plugin events
reach Dart through `observeOn(mainThread)` (`DeviceConnectionHandler.kt:48-50`), so a guard that runs when the event is
*sent* cannot order it against the retry's connect (round 3 A M1 / B R3-M1: v3's send-time generation check never
trips). v4 uses two state-based guards instead; each closes one shape of the harm:

**(a) Plugin patch 3: a failed connector sends no synthesized DISCONNECTED.** In `DeviceConnector.disconnectDevice`,
both branches: when the connector's result is a failure, `sendDisconnectedUpdate` is skipped; `disposeSubscriptions()`
runs as today. "A failure" = a `@Volatile failed` flag, set by a new `doOnNext` placed **before** the existing one
(so before the failure's state DISCONNECTED and `ConnectionUpdateError` go out, round 4 A m1) and by `doOnError`; the
subject check (`hasThrowable()`, or a value that is an `EstablishConnectionFailure`) is kept as a second test.
The check runs where the update would be sent (round 4 B R4-m1): in the immediate branch at the call, in the timer
branch inside its `doFinally`, ~200 ms after the failure, so the microsecond window between `doOnNext` posting the
error and the subscriber storing the failure is long past. (`getValue()` is read before `disposeSubscriptions()`
completes the subject; after completion RxJava 2 returns null.) The
failure was already reported to Dart (the code-less DISCONNECTED of the state change and the `ConnectionUpdateError`s
with the code); the Dart connect stream had already ended on it; a `GateLink` that failed is `_down` already, so its
`close()` waits for nothing. A connector that is connected, or that is cancelled while still connecting, sends it as
today (the gate's `_gone` waits for it). A connector that connected and then **dropped** also holds a failure (its
`onErrorReturn`), so it skips it too (round 4 B R4-m2): harmless, the drop already reached Dart with a code and its
gate link is down; Kotlin test (5) pins this. This removes the stale event from **the new connect's own stream** (shape
(a), whatever the thread timing), because the event is never produced. Other listeners: the older pages (ClaimPage,
claim recovery, the scan page, the old console) use the same plugin; on a failed connect their connect stream also
ended on the first event (`takeWhile`), so they lose nothing.

**(b) Gate: a connecting link ignores code-less downs from `linkStates`.** In `BleGate`'s `linkStates` listener, a link
that is open and has **not yet had its own first connect event** is not marked down by a code-less down (one with a
code still marks it); while connecting, its own connect stream is the authority, and its own failure always reaches it
there. The flag is set in `GateLink._on` (the plugin's CONNECTING
events are filtered out before it, so they do not count; round 4 B R4-m4). Once it had its first event, or is closing
(`_close` sets `_open = false` before it waits), behaviour is as today (a closing link's `_gone` still completes on
any down). This closes **the shape where a stale down reaches only the gate** (shape (b): `_downNow` on the new link,
then `connected>=0 ... noResponse`) from any sender, including ones not found above.

Kotlin tests (`DeviceConnectorTest`, new inner class `NoStaleDisconnectTest`, real `DeviceConnector`, mocked
`RxBleDevice` whose `establishConnection` errors, as `QueueCleanupTest`): (1) failure, then `disconnectDevice` < 200 ms
after (timer branch; real timer and `Thread.sleep(500)` as `delayedDisposeKeepsNewerEntry`) -> no `DISCONNECTED`
update; (2) failure, `Thread.sleep(>= 250)` (the code uses `System.currentTimeMillis`), then `disconnectDevice` (immediate
branch) -> none; (3) a connected connector (`just(conn).concatWith(never())`) -> the update is sent (today); (4)
cancelled while connecting (`never()`, immediate branch) -> sent (today); (5) connected, then dropped (an error after
the connection), then `disconnectDevice` -> none. `connectionUpdateBehaviorSubject` is static and replays its last
value: each test subscribes after its setup or skips the replayed value (round 4 B R4-m3). Tests (1), (2), (5) count
only the updates after `disconnectDevice` is called: the failure itself always sends a state DISCONNECTED through
`startWith` (setup `connectionState` = DISCONNECTED), with or without patch 3; (3), (4) assert exactly one
DISCONNECTED in that span (round 4 A m3). The class is added to `PLUGIN_MUST` as `DeviceConnectorTest$NoStaleDisconnectTest` (round 4 A m4)
(`app/tools/kotlin-unit-tests.sh:28`) so a missing class FAILs. Negative control (manual, output in the PR; the CI
controls test only the judge): the skip removed -> (1) and (2) fail.

Dart tests (`connect_fail_test.dart`): a stale code-less `false` on `linkStates` only, after step 4 and before the
second link's first event (a hook in `FailRadio.connect` before the second connect's `true`) -> the retry reads a
body; negative control: guard (b) removed -> `connected>=0 ... noResponse`. The prober of this test makes one GATT
call first (`requestMtu`), so a link marked down fails it (round 4 A m2: `FakeProber` / `LoginProber` make none);
both `_run` and `_lfAttempt`. And the gate rule alone: a code-less down on a connecting link does not mark it down, a coded one does, a
code-less one on an up link does (today); and a code-less down on a connecting link, then `close()`: the close ends on
the cancel's own down, not after `closeMax` (5 s).

### 2.2 Why `settle` stays

Why 400 ms: the late DISCONNECTED is sent `200 − (t_disconnect − t_failure)` ms after Dart's disconnect, i.e. at the
earliest 200 ms after the failure (`timestampEstablishConnection` is set on the failure too), and later when the
disconnect call reaches the plugin late (round 2 B R2-M1). So 400 ms is **not** a bound; with §2.1 it does not need
to be one. It stays because a reconnect 0 ms after Android's `BluetoothGatt close()` was never measured, the plugin's
own comment cites Android ignoring too-early operations (issuetracker 37121223), and it costs 0.4 s against ~8 s.
Waiting for that event instead (review B option (a)) was not taken: it is always sent, but at once when the disconnect
comes ≥ 200 ms after the failure (`:87-89`) and delayed otherwise, so telling it apart needs the same cap anyway
(round 2 A m2).

Why 1500 ms: all 16 fast failures ended in ≤ 1070 ms. The slower failure shapes (2.9 s 133, 5.0 s Accept Timeout,
`329-ble-settle.md` §1 A) are not retried: too little of the 8 s would be left (connect + msg2 took ~1.5–2.5 s). The
retry is not limited to code 133 (the code is a log-only field by `329-ble-settle.md` §2.2 and may arrive after the
attempt); the 1500 ms bound is what limits it.

Trace: one line `attempt …XX×…NNNN link failed after Nms, connecting once more` (`_lfAttempt`: `loginFor …`) at step 1,
and `attempt …XX×…NNNN second connect +Nms` at step 4 (N = ms from the failure; round 2 A m4), through `mask` like
every line. For a retried attempt the attempt line also gets ` downs=+a,+b…` (at most 4): the times (ms from the
first failure) of the code-less downs the gate saw for that address from the failure to the attempt line; the gate
keeps, per address, the times of its last 4 code-less downs (`BleGate.codelessDowns(addr)`, read-only for NodeLink),
for at most 16 addresses (the oldest address goes first; rotating addresses, #362). The attempt's own close comes after
the attempt line (`_run` traces before `mine?.close()`), so it is never in `downs=`.
This measures the plugin's real delay on the phone (round 2 B R2-M2). The attempt line keeps its format; `connected=` is from the start of the connect that came up
(the second one after a retry), `after` stays from the start of the attempt, and ` retried` is appended when a retry
happened.

## 3. What does not change

- The scheduler (`core.dart`) is untouched: one attempt is one attempt for `perAddr` = 2, `gap`, the caps, the queues
  and every memo. The core never sees the first failure.
- The 8 s connect-to-msg2 budget per attempt (`due` created once). So `takeoverWait` (`329-takeover.md` §1.1 (b)) holds.
  Worst case (review B m1): an attempt that used to end ~0.6 s after a fast failure may now run to 8 s (a second
  connect that hangs) plus the close's 5 s, the same bound as any attempt today; a takeover then waits up to its 8 s.
- Radio time (review A m2): one address may now see up to 4 connects in a round (2 attempts × 2), all inside the
  attempts' existing 8 s budgets.
- Kept / parked links: a retry happens only for a link that never came up; nothing is kept from it.
- `LoginFor` 60 s: the retry is inside the attempt, which `stopBudget` already cuts (`cancel`).
- Older pages (ClaimPage, claim recovery, the scan page, the old console) are not touched.

## 4. Ownership and contracts

- **The attempt's links**: owned by the attempt (`_run` / `_lfAttempt`), as today. Invariant (review B M2): every link
  the attempt opens is closed on every exit path. The first is closed in step 1; the second by the existing end code,
  because `mine` (`_run`) / `link` (`_lfAttempt`) now point at it. `_abort` closes `_link`, which points at the current
  one.
- **`_link` in the window** (review A M1): from step 1 to step 4 `_link` keeps pointing at the first (closed) link; it is
  replaced in step 4, never set to null in between. So `setPage`'s takeover (`node_link.dart:331`) and `acquire(forNode)`
  (`:389`), both gated on `_link != null`, see the attempt as "past the start of its connect" during the window, as
  they do today for the whole attempt. A takeover in the window: `setPage` sets `_det`, the retry goes on (the
  attempt is still `_attempt`), its read enters as `keptRead`; `acquire` waits for `ended`, then `_abort()` — if the
  abort comes in the window, step 3 sees `!identical(_attempt, a)` and no second connect is made.
- **The gate's table** (one link in use, `ble_gate.dart:266`): kept by closing before reconnecting. A `Refused` on the
  second connect = `noResponse`, as today. Rare case (round 2 A m3): another node's parked link that starts closing in
  the 400 ms (its 120 s timer) counts in `gate.active` for up to 5 s; there is no `_makeRoom` before step 4, so the
  retry is refused → `noResponse`, no worse than today.
- **The plugin's connectors** (review A m4): written only by the plugin. Patch 3 adds no state: it reads the
  connector's own result. Fail-safe toward today: when the result is not a failure, the event is sent as today.
- **The gate's link state** (`_down`): written by the link's connect stream and by the `linkStates` listener, as today;
  guard (b) narrows the listener's write for a link still connecting. Owner unchanged (the gate).
- **`BleGate.codelessDowns`**: written only by the gate's `linkStates` listener; read by NodeLink for the trace only, never
  for a decision. ⚠️ (review B m5)
  RxAndroidBle is not vendored: that reconnecting right after the error raises no `BleAlreadyConnectedException`
  and the old connector is gone is checked on the device (§7: any retry failure's class / status is logged, without
  the message, which holds the address).

No file, flag, message or stored state is added.

## 5. Lifecycle

| Path | Today | After | Test |
|---|---|---|---|
| fast failure, then success | noResponse, next try ~8 s | read in the same attempt, ~0.4 s + connect later | T1 (`_run` and `_lfAttempt`) with the stale-false fake |
| fast failure, then the late DISCONNECTED (any timing) | — | not produced (patch 3); a stale code-less down from any other sender does not mark a connecting link down (guard (b)) | Kotlin (1)-(2); Dart stale-on-linkStates test; negative controls in §2.1 |
| main thread busy for longer than `settle` | — | as above: neither guard depends on timing | the same tests (the Dart one delivers the stale down after step 4) |
| a connected link closed, then its address connected at once (old pages) | the late DISCONNECTED is sent (today) | unchanged (patch 3 is for failed connectors only); NodeLink never does this within 6 s | Kotlin (3) |
| fast failure twice | noResponse | noResponse after both; no third connect | T2 (connect count = 2) |
| slow failure (≥ 1500 ms) | noResponse | unchanged, no retry | T3 (connect count = 1) |
| budget `due` ends | noResponse | unchanged, no retry on `due` (also when `due` comes during `settle`) | existing `connect_fail_test` + T4 |
| cancel in the first connect / in `settle` / in the second connect | noResponse | no second connect when before step 4; after it, as a cancel today | T4 |
| page opens in the window (takeover a) | — | `_det` set, the retry's read enters as `keptRead` | T6, negative control: `_link = null` in the window → T6 fails |
| `acquire(forNode)` in the window (takeover b) | — | waits for `ended`; no second connect after `_abort` | T6 |
| Bluetooth off, radio status before the failure | round cancelled | `identical(_attempt, a)` false → no retry | T5 |
| Bluetooth off, failure before the radio status | noResponse | the retry may start; `radio()` → `_abort` closes it; nothing recorded | T5 |
| lease taken back during a login retry | — | step 3 lease check → noResponse | T5 |
| dispose in the window | — | step 3 → no connect | T4 |
| every case above | — | `gate.links == 0` and `gate.active == 0` at the end | asserted in T1–T6; negative control: `mine` left on the first link → fails |
| install / upgrade / downgrade | — | in memory only; a downgrade restores the 8 s wait | n/a |
| crash / restart | — | nothing persists | n/a |
| platform | Android | Android; iOS is not built | n/a |

## 6. Security

No new input. Patch 3 only drops an event a failed connector would send; it sends nothing new. Guard (b) narrows when
a code-less event may mark a link down; a coded failure still does.
The retry goes to the same address the scheduler chose, within the same 8 s budget; the attempt's trust
rules (certificate, login) are unchanged. A hostile nearby device that answers with fast failures gets at most two
connects per attempt inside the same 8 s; the scheduler's caps are unchanged. The availability risk is a leaked link
(review B M2), covered by the invariant in §4 and its tests. The new trace line carries the masked address (last 2)
and id (last 4) only; the failure class / status on a retry failure is logged without the message. No secret.

## 7. Verification

- Unit (fake backend and clock, `connect_fail_test.dart`): T1–T6 above, for `_run` and `_lfAttempt` where both apply.
  The fake decides per connect call (round 2 A m5: `FailRadio.failAt` fails every connect to an address; T1 needs
  "the first connect fails, the next one comes up").
  Plus a unit test where a stale code-less `false` reaches `linkStates` only, after step 4: the trace shows it in
  `downs=` (the device signature is computable). Negative controls: (1) no retry branch → T1 fails at both call sites; (2) `settle` = 0 → T1 fails (stale false);
  (3) `mine` / `link` not moved to the second link → the `gate.links == 0` checks fail; (4) `_link` nulled in the
  window → T6 fails.
- Plugin: the Kotlin tests of §2.1 (in `PLUGIN_MUST`) in the CI Kotlin step; the manual negative control in the PR.
- Full Dart suite; `flutter analyze lib test`.
- Device (S20, both nodes on wsl.33, NodeLink rounds via `a4cycle.sh`), run until **≥ 10 fast failures** (base rate
  ~5 % of attempts, so ~200 attempts; several runs pooled). A parser in the repo
  (`docs/design/329-reviews/fast-retry-stats.py`, as `adv-id-app-nc.py`) reads the app log and prints, per retry:
  failure code (gate line), gap between the two connects, the retry's result and connect time, time from the first
  failure to the read; it **FAILs on zero retry lines**. Pass:
  - every fast failure (< 1500 ms) of an attempt without a retry yet has a retry line, and its `second connect +N`
    has 400 ≤ N ≤ 600;
  - ≥ 8 of the first 10 retries read a body (baseline: 15/16 read 8 s later);
  - the stale-event signature, either shape, FAILs the run (round 2 B R2-M2): a code-less down in `downs=` later than
    the `second connect +N` time with no `fail=` gate line for that address within ±1 s of it (`fail=?` counts as a
    code; round 3 B R3-m3) — whether the retry ended with `connected=-1` or with `connected≥0 … noResponse`;
  - report per retry: the failure code, `second connect +N`, `downs=`, the retry's result and connect time, the time from
    the first failure to the read;
  - (the "other attempts unchanged" item of v2 is dropped: not decidable; round 2 A m4.)
  Report also the per-round 沒找到 count against the baseline runs.
- Login path (`_lfAttempt`): unit only; on the device it is not exercised by `a4cycle.sh`. The PR marks it ⚠️.
- Negative control on the device: the baseline logs above (main APK: the next try 6.4–9.8 s after the failure).

## 8. Later work

Kept when the key-authority work (#255) changes the login: this is below the login (link up or not) and reads no
login result. It does not touch the advertising.
