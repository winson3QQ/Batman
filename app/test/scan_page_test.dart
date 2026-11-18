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
  t20();
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

/// #329 PR 7 T20: a scan whose stream the test drives; its cancel completes when [cancelDone] does; connects counted.
class ScanBle implements FlutterReactiveBle {
  final scans = <StreamController<DiscoveredDevice>>[];
  final connects = <String>[];
  Completer<void>? cancelDone; // null: the cancel completes at once
  @override
  Stream<DiscoveredDevice> scanForDevices(
      {required List<Uuid> withServices, ScanMode scanMode = ScanMode.balanced, bool requireLocationServicesEnabled = true}) {
    late final StreamController<DiscoveredDevice> c;
    c = StreamController<DiscoveredDevice>(
        onListen: () => c.add(DiscoveredDevice(
            id: 'AA', name: '', serviceData: const {}, manufacturerData: Uint8List(0), rssi: -40, serviceUuids: const [])),
        onCancel: () => cancelDone?.future);
    scans.add(c);
    return c.stream;
  }

  @override
  Stream<ConnectionStateUpdate> connectToDevice(
      {required String id, Map<Uuid, List<Uuid>>? servicesWithCharacteristicsToDiscover, Duration? connectionTimeout}) {
    connects.add(id);
    return StreamController<ConnectionStateUpdate>().stream;
  }

  @override
  dynamic noSuchMethod(Invocation i) => throw UnimplementedError('${i.memberName}');
}

/// #329 PR 7 T20 (#329:114): ScanPage holds the raw lease while it scans, by its own hold (`_scanHold`), not `_busy`.
/// Negative controls (PR body): no scan hold -> the pop test FAILs (released at once); dispose not waiting for the
/// cancel -> the pop test FAILs; the scan marked as `_busy` -> the tap test FAILs (no connect); a hold per press ->
/// the twice test FAILs; no release at the stream's end -> the end test FAILs; hold() not caught -> the taken-back
/// test FAILs.
void t20() {
  late nlt.Clock clock;
  late LeaseRegistry reg;
  late BleGate gate;
  late NodeLink nl;

  Future<Lease> open(WidgetTester t, FlutterReactiveBle ble) async {
    t.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('dev.batman/platform'), (c) async => c.method == 'blePermissions' ? true : null);
    clock = nlt.Clock();
    reg = LeaseRegistry(after: clock.after);
    gate = BleGate(nlt.Radio(), reg, now: () => clock.t, after: clock.after);
    nl = NodeLink(
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
                onPressed: () => openRawPage(Navigator.of(c), nl, gate, '附近的節點', (u) => ScanPage(ble: ble, use: u)),
                child: const Text('open')))));
    await t.tap(find.text('open'));
    await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await t.pumpAndSettle();
    return reg.current!;
  }

  Future<void> search(WidgetTester t) async {
    await t.tap(find.text('搜尋'));
    await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
    await t.pumpAndSettle();
  }

  Future<void> pop(WidgetTester t) async {
    t.state<NavigatorState>(find.byType(Navigator)).pop();
    await t.pumpAndSettle();
    await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
    await t.pump();
  }

  testWidgets('T20: popped while scanning -> the lease is held until the scan\'s cancel completes', (t) async {
    final ble = ScanBle()..cancelDone = Completer<void>();
    final lease = await open(t, ble);
    await search(t);
    expect(lease.busy, isTrue, reason: 'the scan holds the lease');
    await pop(t);
    expect(find.byType(ScanPage), findsNothing);
    expect(reg.current, same(lease), reason: 'the scan is still being cancelled');
    ble.cancelDone!.complete();
    await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
    await t.pump();
    expect(reg.current, isNull, reason: 'cancelled: released');
    await t.runAsync(nl.dispose);
  });

  testWidgets('T20: a node tapped while scanning still connects (the scan is not `_busy`)', (t) async {
    final ble = ScanBle();
    await open(t, ble);
    await search(t);
    await t.tap(find.text('點一下讀取狀態'));
    await t.pump();
    await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
    await t.pump();
    expect(ble.connects, ['AA']);
    await pop(t);
    for (var i = 0; i < 40; i++) {
      await t.pump(const Duration(seconds: 1)); // the read's 30 s limit
      await t.runAsync(() => Future<void>.delayed(Duration.zero));
    }
    await t.pumpAndSettle();
    expect(reg.current, isNull, reason: 'the read ended: released');
    await t.runAsync(nl.dispose);
  });

  testWidgets('T20: 搜尋 twice, then 停止 -> nothing held; popped -> released at once', (t) async {
    final ble = ScanBle();
    final lease = await open(t, ble);
    await search(t);
    await search(t);
    expect(ble.scans.length, 2);
    expect(lease.busy, isTrue);
    await t.tap(find.text('停止'));
    await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
    await t.pumpAndSettle();
    expect(lease.busy, isFalse, reason: 'one hold, given back once');
    await pop(t);
    expect(reg.current, isNull);
    await t.runAsync(nl.dispose);
  });

  testWidgets('T20: the scan\'s stream ends -> its hold is given back', (t) async {
    final ble = ScanBle();
    final lease = await open(t, ble);
    await search(t);
    expect(lease.busy, isTrue);
    await t.runAsync(() => ble.scans.last.close());
    await t.pumpAndSettle();
    expect(lease.busy, isFalse);
    expect(find.textContaining('搜尋已結束'), findsOneWidget);
    await pop(t);
    expect(reg.current, isNull);
    await t.runAsync(nl.dispose);
  });

  testWidgets('T20 (F m-9): the lease taken back -> 搜尋 says so and starts no scan (no uncaught error)', (t) async {
    final ble = ScanBle();
    final lease = await open(t, ble);
    await t.runAsync(lease.release); // no longer valid: hold() throws
    await search(t);
    expect(t.takeException(), isNull);
    expect(ble.scans, isEmpty);
    expect(find.textContaining('另一個操作還在進行'), findsOneWidget);
    await pop(t);
    await t.runAsync(nl.dispose);
  });

  // code review B-m3: 搜尋 waits for the old scan's cancel; 停止 meanwhile gives the hold back -> no scan at all
  testWidgets('T20 (code review B-m3): 停止 while 搜尋 waits for the old cancel -> no new scan, nothing held', (t) async {
    final ble = ScanBle();
    final lease = await open(t, ble);
    await search(t);
    expect(ble.scans.length, 1);
    ble.cancelDone = Completer<void>(); // the first scan's cancel hangs
    await t.tap(find.text('搜尋'));
    await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
    await t.tap(find.text('停止')); // still enabled: no rebuild while 搜尋 waits
    await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
    ble.cancelDone!.complete();
    await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
    await t.pumpAndSettle();
    expect(ble.scans.length, 1, reason: 'stopped: the waiting 搜尋 starts no scan');
    expect(lease.busy, isFalse, reason: 'the hold was given back');
    await pop(t);
    expect(reg.current, isNull);
    await t.runAsync(nl.dispose);
  });

  // code review A-m2: 停止 waits for the scan's cancel; 搜尋 meanwhile -> its scan runs under the hold
  testWidgets('T20 (code review A-m2): 搜尋 while 停止 waits for the cancel -> the new scan holds the lease', (t) async {
    final ble = ScanBle();
    final lease = await open(t, ble);
    await search(t);
    ble.cancelDone = Completer<void>(); // the scan's cancel hangs
    await t.tap(find.text('停止'));
    await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
    await t.pump();
    await t.tap(find.text('搜尋'));
    await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
    expect(ble.scans.length, 1, reason: 'the new scan waits for the old cancel');
    ble.cancelDone!.complete();
    ble.cancelDone = null;
    await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
    await t.pumpAndSettle();
    expect(ble.scans.length, 2, reason: 'the new scan started');
    expect(lease.busy, isTrue, reason: 'and it runs under the hold (停止 did not give it back)');
    await t.tap(find.text('停止'));
    await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
    await t.pumpAndSettle();
    expect(lease.busy, isFalse);
    await pop(t);
    expect(reg.current, isNull);
    await t.runAsync(nl.dispose);
  });
}
