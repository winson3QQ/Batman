# Vendored reactive_ble_mobile 5.6.0 (patched)

This directory is `reactive_ble_mobile` 5.6.0 copied verbatim from pub.dev
(pub cache archive sha256 `1af5ff867926ff104fab763734db33fa18ac6c9d05e58988dc43879a56168d56`),
BSD-3-Clause, see `LICENSE`. `app/pubspec.yaml` points at it with
`dependency_overrides:`. Only the files listed below differ from upstream
(plus this file). Each patched file carries a `PATCHED (Batman, ...)` comment.
`.pre-commit-config.yaml` keeps the whitespace / end-of-file hooks off this
tree so it stays byte-identical to upstream; gitleaks still scans it.

All paths below are under `android/src/`.

## Patch 1: dequeue on every exit path (upstream #558)

- `main/kotlin/com/signify/hue/flutterreactiveble/ble/DeviceConnector.kt`:
  the connector's `ConnectionQueue` entry is removed through
  `removeFromQueueOnce()` (guarded by an `AtomicBoolean`), called from the
  existing `doOnNext` / `doOnError` and from a new `doFinally` on the
  connection chain.
- `test/kotlin/com/signify/hue/flutterreactiveble/ble/DeviceConnectorTest.kt`:
  two regression tests in `QueueCleanupTest`.

Upstream removes the queue entry only in `doOnNext` and `doOnError`. When the
Dart side cancels a connect before it produced its first event, the native
side runs `disconnectDevice` -> `disposeSubscriptions`, a dispose, which runs
neither. The address then stays in the queue forever and every later connect
(any address) waits in `waitUntilFirstOfQueue`. `doFinally` also runs on
dispose; the once-guard keeps a late dispose (the 200 ms delayed disconnect
after a fresh connection) from removing the entry of a newer connect to the
same address. The delayed-dispose test holds the stream open
(`concatWith(Observable.never())`), as a real connection does, so it fails
without the guard.

Not taken from upstream PR #910: its unconditional remove in
`disposeSubscriptions` (it can remove a newer same-address entry on the
delayed-disconnect path) and its `takeUntil` -> `take(1)` change (not needed
for this bug; it changes the "Device is not in queue" path).

- Issue: https://github.com/PhilipsHue/flutter_reactive_ble/issues/558
- Fix PR (open, unmerged when vendored): https://github.com/PhilipsHue/flutter_reactive_ble/pull/910

## Patch 2: only a connect creates a connector (Batman #329)

- `main/kotlin/com/signify/hue/flutterreactiveble/ble/ReactiveBleClient.kt`:
  `connectToDevice` uses `getOrCreateConnection` (upstream's `getOrPut`).
  Every other operation (discover services, read, write, notify, MTU,
  priority, RSSI) uses `getConnection`, which returns
  `EstablishConnectionFailure(deviceId, "Device is not connected")` at once
  when the address has no active connector and creates nothing. Each caller
  already maps that failure to its own result (`CharOperationFailed`,
  `MtuNegotiateFailed`, an error for discover services / RSSI, an empty
  notification stream). The message is the one upstream already uses for
  `clearGattCache` on an address with no connector.
- `main/kotlin/com/signify/hue/flutterreactiveble/ble/ConnectionQueue.kt`:
  `addToQueue` / `removeFromQueue` are `@Synchronized`. Add runs on the
  platform thread, remove on the RxAndroidBle callbacks thread, the
  computation thread or (with patch 1) the platform thread. Without the lock
  one read-copy-`onNext` can overwrite the other and leave a dead entry at the
  head of the queue (the same permanent wedge).
- `test/kotlin/com/signify/hue/flutterreactiveble/ble/OrphanConnectorTest.kt`
  (new): an operation after `disconnectDevice` fails at once, creates no
  connector, and a later connect to another address still reaches
  `establishConnection`; plus a control without the late operation.
- `test/kotlin/com/signify/hue/flutterreactiveble/ble/ReactiveBleClientTest.kt`:
  the test client starts with the mocked connector registered for `"test"`
  and `""`, because the operation tests relied on an operation creating the
  connector.

In 5.6.0 a Dart read / write / subscribe first calls `getDiscoveredServices`
and then the operation: two method calls. If the app cancels the connect in
between, the second call reached `getConnection`, which created a new
connector with timeout 0 (autoConnect, never times out). It entered the queue
and nobody disposed it, so every later connect waited behind it.
Upstream has no issue or PR for this path that we know of (PR #910 does not
touch it).

## How to drop this

Drop the vendoring only when an upstream `reactive_ble_mobile` release fixes
BOTH paths: #558 (cancel before the first event leaves the address queued)
and patch 2 (an operation on an address with no connector creates one).
Then:

1. Before deleting anything, copy `DeviceConnectorTest.kt` (`QueueCleanupTest`)
   and `OrphanConnectorTest.kt` onto that release's source and run its
   `:reactive_ble_mobile:testDebugUnitTest` (judge by the JUnit XML: every
   test runs, none fails). Both test classes must pass against the
   unpatched release; if either fails, keep the vendoring.
2. Delete this directory and the `dependency_overrides: reactive_ble_mobile`
   entry in `app/pubspec.yaml`, un-pin and bump `flutter_reactive_ble` /
   `reactive_ble_platform_interface`, drop the `flutter:` line under
   `environment:` if nothing else needs it, and run `flutter pub get`.
3. Re-run the device sequence on a phone against two nodes: open a node
   page, go back 1.2 s later while its connect is still pending, six times
   (`fast.sh` style). Pass = every app connect attempt is followed by a
   platform `BluetoothGatt: connect()` line in logcat; one attempt with no
   `connect()` line is a wedge and a FAIL.

If upstream changes `DeviceConnector.kt` or `ReactiveBleClient.kt` but does
not fix both paths, do not merge by hand: re-vendor the new release and
re-apply only the patches still needed.
