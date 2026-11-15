// #329 PR 1 review r3 E-M1 (E9 / E10 / E16): the real AppLink's wiring — the app lifecycle, the BLE status stream and
// the prober's key errors reach its NodeLink. A fake FlutterReactiveBle stands in for the platform's.
// Negative controls: AppLink without the lifecycle observer, without wireRadio, or the prober without keyError -> FAIL.
import 'dart:async';

import 'package:batman_app/src/nodelink/app_link.dart';
import 'package:batman_app/src/nodelink/core.dart';
import 'package:flutter/services.dart';
import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter/widgets.dart' show AppLifecycleState;
import 'package:flutter_reactive_ble/flutter_reactive_ble.dart';
import 'package:flutter_test/flutter_test.dart';

class StatusBle implements FlutterReactiveBle {
  final ctl = StreamController<BleStatus>.broadcast(sync: true);
  @override
  Stream<BleStatus> get statusStream => ctl.stream;
  @override
  Stream<ConnectionStateUpdate> get connectedDeviceStream => const Stream.empty();
  @override
  dynamic noSuchMethod(Invocation i) => throw UnimplementedError('${i.memberName}');
}

void main() {
  testWidgets('AppLink: lifecycle, Bluetooth status and key refusals reach NodeLink', (t) async {
    AppLink.forgetForTest();
    final ble = StatusBle();
    final a = AppLink.create(platform: const MethodChannel('dev.batman/platform'), filesDir: '/x', ble: ble);
    final core = a.link.core;
    expect(core.fg, isTrue);
    t.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    expect(core.fg, isFalse, reason: 'E9: the app-wide observer');
    t.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    expect(core.fg, isTrue);
    ble.ctl.add(BleStatus.poweredOff);
    expect(core.blocked, Why.bluetoothOff, reason: 'E10: the status stream');
    ble.ctl.add(BleStatus.ready);
    expect(core.blocked, isNull);
    a.prober.keyError!(PlatformException(code: 'keyLevel', message: 'OWNER_SIGN', details: 0));
    expect(core.blocked, Why.keys, reason: 'E16: a key refusal from the prober');
    AppLink.forgetForTest();
  });

  testWidgets('r3 F-m2: the prober''s log lines reach logcat masked (no long id)', (t) async {
    AppLink.forgetForTest();
    final a = AppLink.create(platform: const MethodChannel('dev.batman/platform'), filesDir: '/x', ble: StatusBle());
    final lines = <String>[];
    final keep = debugPrint;
    debugPrint = (String? m, {int? wrapWidth}) => lines.add(m ?? '');
    try {
      a.prober.log!('probe 0123456789abcdef0123456789abcdef: StateError at AA:BB:CC:DD:EE:F1');
    } finally {
      debugPrint = keep;
    }
    expect(lines, hasLength(1));
    expect(lines.single, isNot(matches(RegExp(r'[0-9a-fA-F]{8,}'))));
    expect(lines.single, isNot(contains('AA:BB')));
    AppLink.forgetForTest();
  });
}
