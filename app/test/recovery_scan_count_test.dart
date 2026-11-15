// #329 PR 1 review r4 G-M1 (E14): the claim recovery's scan is counted by the gate (A10: 4 in 30 s), through
// ReactiveRecoveryBle's onScan. Negative control: ReactiveRecoveryBle without onScan -> FAIL.
import 'dart:async';
import 'dart:typed_data';

import 'package:batman_app/claim_recovery.dart';
import 'package:flutter_reactive_ble/flutter_reactive_ble.dart';
import 'package:flutter_test/flutter_test.dart';

class OneDeviceBle implements FlutterReactiveBle {
  @override
  Stream<DiscoveredDevice> scanForDevices(
          {required List<Uuid> withServices, ScanMode scanMode = ScanMode.balanced, bool requireLocationServicesEnabled = true}) =>
      (StreamController<DiscoveredDevice>()
            ..add(DiscoveredDevice(id: 'AA', name: '', serviceData: const {}, manufacturerData: Uint8List(0), rssi: -40, serviceUuids: const [])))
          .stream;
  @override
  dynamic noSuchMethod(Invocation i) => throw UnimplementedError('${i.memberName}');
}

void main() {
  test('each recovery scan start is reported once', () async {
    var starts = 0;
    final r = ReactiveRecoveryBle(OneDeviceBle(), onScan: () => starts++);
    final seen = await r.scan(const Duration(milliseconds: 10));
    expect(seen.keys, ['AA']);
    expect(starts, 1);
    await r.scan(const Duration(milliseconds: 10));
    expect(starts, 2);
  });
}
