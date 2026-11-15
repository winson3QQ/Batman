// #329 PR 1 review r3 F-M1: the older 附近的節點 page under a raw lease — its scan counts against the gate's 4 in 30 s,
// and a read in progress holds the lease past a pop until the read ends. Negative controls: ScanPage's rawUse => null,
// or no rawScanStarted -> FAIL.
import 'dart:async';

import 'package:batman_app/scan.dart';
import 'package:batman_app/src/nodelink/ble_gate.dart';
import 'package:batman_app/src/nodelink/core.dart' show NodeLinkCore;
import 'package:batman_app/src/nodelink/lease.dart';
import 'package:batman_app/src/nodelink/node_link.dart';
import 'package:batman_app/src/nodelink/raw_use.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_reactive_ble/flutter_reactive_ble.dart';
import 'package:flutter_test/flutter_test.dart';

import 'nodelink/node_link_test.dart' as nlt show Clock, Radio, FakeProber;

/// One device; a connection that never comes up (the read waits until its 30 s limit).
class SlowBle implements FlutterReactiveBle {
  @override
  Stream<DiscoveredDevice> scanForDevices(
          {required List<Uuid> withServices, ScanMode scanMode = ScanMode.balanced, bool requireLocationServicesEnabled = true}) =>
      (StreamController<DiscoveredDevice>()
            ..add(DiscoveredDevice(id: 'AA', name: '', serviceData: const {}, manufacturerData: Uint8List(0), rssi: -40, serviceUuids: const [])))
          .stream;
  @override
  Stream<ConnectionStateUpdate> connectToDevice(
          {required String id, Map<Uuid, List<Uuid>>? servicesWithCharacteristicsToDiscover, Duration? connectionTimeout}) =>
      StreamController<ConnectionStateUpdate>().stream;
  @override
  dynamic noSuchMethod(Invocation i) => throw UnimplementedError('${i.memberName}');
}

void main() {
  testWidgets('附近的節點: the scan is counted; popped mid-read, the lease is held until the read ends', (t) async {
    t.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('dev.batman/platform'), (c) async => c.method == 'blePermissions' ? true : null);
    final clock = nlt.Clock();
    final reg = LeaseRegistry(after: clock.after);
    final gate = BleGate(nlt.Radio(), reg, now: () => clock.t, after: clock.after);
    final nl = NodeLink(
        core: NodeLinkCore(const []),
        gate: gate,
        reg: reg,
        prober: nlt.FakeProber({}),
        readRecords: () async => const [],
        now: () => clock.t,
        after: clock.after);
    await t.pumpWidget(MaterialApp(
        home: Builder(
            builder: (c) => TextButton(
                onPressed: () => openRawPage(Navigator.of(c), nl, gate, '附近的節點', (u) => ScanPage(ble: SlowBle(), use: u)),
                child: const Text('open')))));
    await t.tap(find.text('open'));
    await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await t.pumpAndSettle();
    final lease = reg.current!;
    await t.tap(find.text('搜尋'));
    await t.pumpAndSettle();
    expect(gate.recentScanStarts, 1, reason: 'the page\'s scan is counted');
    await t.tap(find.text('點一下讀取狀態'));
    await t.pump();
    t.state<NavigatorState>(find.byType(Navigator)).pop();
    await t.pumpAndSettle();
    expect(find.byType(ScanPage), findsNothing);
    expect(reg.current, same(lease), reason: 'the read still runs');
    for (var i = 0; i < 40; i++) {
      await t.pump(const Duration(seconds: 1)); // the read's 30 s limit
      await t.runAsync(() => Future<void>.delayed(Duration.zero));
    }
    await t.pumpAndSettle();
    expect(reg.current, isNull, reason: 'the read ended: released');
  });
}
