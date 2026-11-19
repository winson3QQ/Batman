# Vendored reactive_ble_mobile 5.6.0 (patched)

This directory is `reactive_ble_mobile` 5.6.0 copied verbatim from pub.dev
(pub cache archive sha256 `1af5ff867926ff104fab763734db33fa18ac6c9d05e58988dc43879a56168d56`),
BSD-3-Clause, see `LICENSE`. `app/pubspec.yaml` points at it with
`dependency_overrides:`. Only the files listed below differ from upstream
(plus this file).

## What changed

- `android/src/main/kotlin/com/signify/hue/flutterreactiveble/ble/DeviceConnector.kt`:
  the connector's `ConnectionQueue` entry is removed through
  `removeFromQueueOnce()` (guarded by an `AtomicBoolean`), called from the
  existing `doOnNext` / `doOnError` and from a new `doFinally` on the
  connection chain.
- `android/src/test/kotlin/com/signify/hue/flutterreactiveble/ble/DeviceConnectorTest.kt`:
  two regression tests in `QueueCleanupTest`.

## Why

Upstream removes the queue entry only in `doOnNext` and `doOnError`. When the
Dart side cancels a connect before it produced its first event, the native
side runs `disconnectDevice` -> `disposeSubscriptions`, a dispose, which runs
neither. The address then stays in the queue forever and every later connect
(any address) waits in `waitUntilFirstOfQueue`. `doFinally` also runs on
dispose; the once-guard keeps a late dispose (the 200 ms delayed disconnect
after a fresh connection) from removing the entry of a newer connect to the
same address.

Not taken from upstream PR #910: its unconditional remove in
`disposeSubscriptions` (it can remove a newer same-address entry on the
delayed-disconnect path) and its `takeUntil` -> `take(1)` change (not needed
for this bug; it changes the "Device is not in queue" path).

- Issue: https://github.com/PhilipsHue/flutter_reactive_ble/issues/558
- Fix PR (open, unmerged when vendored): https://github.com/PhilipsHue/flutter_reactive_ble/pull/910

## How to drop this

When a `reactive_ble_mobile` release fixes #558 (cancel before first event
no longer leaves the address queued), delete this directory and the
`dependency_overrides: reactive_ble_mobile` entry in `app/pubspec.yaml`, bump
`flutter_reactive_ble`, run `flutter pub get`, and re-run the BLE connect /
cancel tests. If upstream changes `DeviceConnector.kt`, do not merge by hand:
re-vendor the new release and re-apply the patch only if still needed.
