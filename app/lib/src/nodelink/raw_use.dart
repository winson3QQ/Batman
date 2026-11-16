// #329 §4.4 原始佔用的頁面 (review pr1 A-M1 / B-M1): an older page keeps its own BLE code under a raw lease. While the
// page is busy (a claim, a recovery, a login, a read) the lease is held, so popping the page does not hand Bluetooth
// back to NodeLink until that work ends (at most 900 s after the pop; then the registry takes the lease back and a
// to-do is recorded, but the page itself is not stopped: it does not use the gate); the page's scan starts count against the gate's 4 in 30 s (A10, A-m7).
import 'package:flutter/material.dart' show MaterialPageRoute;
import 'package:flutter/widgets.dart';

import 'ble_gate.dart';
import 'lease.dart';
import 'node_link.dart';

class RawUse {
  RawUse(this.lease, this.gate);
  final Lease lease;
  final BleGate gate;
}

/// For an older page's State: `_busy` becomes a getter / setter over [rawBusy].
mixin RawBusy<T extends StatefulWidget> on State<T> {
  RawUse? get rawUse;

  bool _rawBusy = false;
  Cancel? _rawHold;

  bool get rawBusy => _rawBusy;
  set rawBusy(bool v) {
    if (v == _rawBusy) return;
    _rawBusy = v;
    if (v) {
      // fail-closed (review pr1 r2 C-m2 / D-3): a lease that is gone (taken back at 900 s) throws here, so the work
      // that wanted it does not start
      _rawHold = rawUse?.lease.hold();
    } else {
      final h = _rawHold;
      _rawHold = null;
      h?.call();
    }
  }

  /// The busy work ended: also after the page is gone (the lease must not wait for the 900 s).
  void rawIdle() {
    rawBusy = false;
    if (mounted) setState(() {});
  }

  void rawScanStarted() => rawUse?.gate.noteScanStart();
}

/// Gives the page's lease up when the page is disposed (not when the route's future completes: the page is still
/// mounted for its exit animation and may start work then; review pr1 r2 C-m2 / D-10).
class RawLeaseScope extends StatefulWidget {
  const RawLeaseScope({super.key, required this.lease, required this.child});
  final Lease lease;
  final Widget child;

  @override
  State<RawLeaseScope> createState() => _RawLeaseScopeState();
}

class _RawLeaseScopeState extends State<RawLeaseScope> {
  @override
  void dispose() {
    widget.lease.pageGone();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

/// §4.4: open an older page under a raw lease. Returns null when the page was opened (and has closed), or the name
/// of the operation that holds the radio (the caller shows 「另一個操作還在進行：<名稱>」).
Future<String?> openRawPage(NavigatorState nav, NodeLink link, BleGate gate, String name, Widget Function(RawUse use) page) async {
  final lease = await link.acquire(name, LeaseKind.raw);
  if (lease == null) return link.reg.current?.name ?? '';
  if (!nav.mounted) {
    await lease.release(); // review pr1 A-m4: never keep a lease no page will use
    return null;
  }
  await nav.push(MaterialPageRoute<void>(builder: (_) => RawLeaseScope(lease: lease, child: page(RawUse(lease, gate)))));
  return null;
}
