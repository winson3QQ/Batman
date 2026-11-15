// #329 §4.4 原始佔用的頁面 (review pr1 A-M1 / B-M1): an older page keeps its own BLE code under a raw lease. While the
// page is busy (a claim, a recovery, a login, a read) the lease is held, so popping the page does not hand Bluetooth
// back to NodeLink until that work ends (at most 420 s after the pop, then the registry takes it back); the page's
// scan starts count against the gate's 4 in 30 s (A10, A-m7).
import 'package:flutter/widgets.dart';

import 'ble_gate.dart';
import 'lease.dart';

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
      try {
        _rawHold = rawUse?.lease.hold();
      } on StateError {
        _rawHold = null; // the lease was taken back (420 s): nothing to hold
      }
    } else {
      final h = _rawHold;
      _rawHold = null;
      h?.call();
    }
  }

  /// The busy work ended: also after the page is gone (the lease must not wait for the 420 s).
  void rawIdle() {
    rawBusy = false;
    if (mounted) setState(() {});
  }

  void rawScanStarted() => rawUse?.gate.noteScanStart();
}
