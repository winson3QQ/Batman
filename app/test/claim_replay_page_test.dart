// 254-app-replay §10 at the claim page: T1 after the claim's own finish (D1 / D16 at page level), T2 when 「認領」 finds
// the node already claimed (D3 = §0's symptom), T3 only with a node record (D4), the page leaving (D6), replay_due
// failing (D13). The claim page's search uses a fake FlutterReactiveBle; the recovery a fake field (replay_fakes.dart).
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_reactive_ble/flutter_reactive_ble.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart' show Uint64List;
import 'package:flutter_test/flutter_test.dart';
import 'package:batman_app/src/nodelink/ble_gate.dart';
import 'package:batman_app/src/nodelink/lease.dart';
import 'package:batman_app/src/nodelink/raw_use.dart';

import 'nodelink/node_link_test.dart' as nlt show Clock, Radio;

import 'package:batman_app/claim.dart';
import 'package:batman_app/src/rust/api/claim.dart';
import 'package:batman_app/src/rust/api/owner.dart' show SealedRecord;
import 'package:batman_app/src/rust/api/replay.dart';
import 'package:batman_app/src/rust/api/simple.dart' show StatusInfo;
import 'package:batman_app/src/rust/frb_generated.dart';

import 'replay_fakes.dart';

const qrText = 'a201726261746d616e2d746573742d71722d303102582000112233445566778899aabbccddeeff0011';
const files = '/data/user/0/app/files';

ClaimStep cstep(StepKind kind, {List<List<int>> frames = const [], String path = '', String pendingPath = '', String detail = ''}) =>
    ClaimStep(kind: kind, frames: [for (final f in frames) Uint8List.fromList(f)], path: path, record: Uint8List(2), pendingPath: pendingPath, detail: detail);

/// msg1 [1] -> [2] = msg2 -> PersistPending; begin [3] -> [4] -> finish [5]; the finish answer [6] -> Ended (9)
class FakeClaim implements ClaimSession {
  FakeClaim(this.rust);
  final FakeRust rust;

  @override
  ClaimStep? onFrame({required List<int> frame}) => switch (frame[0]) {
        2 => cstep(StepKind.persistPending, path: pendPath),
        4 => cstep(StepKind.write, frames: [
            [5]
          ]),
        _ => cstep(StepKind.ended, detail: 'QR 不符，或認領仍在收尾 — 請確認 QR 後稍後再試（TryReplay）'),
      };

  @override
  ClaimStep? pendingPersisted() => cstep(StepKind.write, frames: [
        [3]
      ]);

  @override
  bool replayDue() {
    if (rust.dueThrows) throw 'gone';
    return rust.due;
  }

  @override
  bool finishedWith9() => true;

  @override
  dynamic noSuchMethod(Invocation i) => null;
}

class FakeRust implements RustLibApi {
  final calls = <String>[];
  final disk = <String, Uint8List>{};
  ClaimTarget target = ClaimTarget.pending;
  String statusState = 'claimed';
  String? statusLast4;
  bool due = true;
  bool dueThrows = false;
  bool replayOff = false; // negative control D3: the page never recovers
  final pendingIds = <String>[]; // claim-pending/ file names (T4)
  final nodeIds = <String>[];

  @override
  Future<List<String>> crateApiOwnerListPending({required String dir}) async => [...pendingIds];
  @override
  Future<List<String>> crateApiOwnerListNodes({required String dir}) async => [...nodeIds];
  final endTexts = <String>[];

  @override
  Future<ClaimQr> crateApiClaimParseClaimQr({required String text}) async => ClaimQr(deviceId: deviceId, k: Uint8List(32));
  @override
  Future<ClaimTarget> crateApiClaimClaimTarget({required String dir, required String deviceId}) async => target;
  @override
  StatusInfo crateApiSimpleDecodeStatus({required List<int> bytes}) =>
      StatusInfo(state: statusState, trial: false, idLast4: statusLast4, versions: Uint64List(0), transports: const []);
  @override
  Future<int> crateApiClaimFrameLimit({required List<int> ctrl, required int mtu}) async => 244;
  @override
  Future<Uint8List> crateApiClaimOwnerEncSignInput({required List<int> ownerEncPub}) async => Uint8List(4);
  @override
  Future<Uint8List> crateApiClaimDerToRaw({required List<int> der}) async => Uint8List(64);
  @override
  (ClaimSession, ClaimStep) crateApiClaimClaimSessionStart(
          {required ClaimQr qr, required List<int> ownerPub, required List<int> ownerEncPub, required List<int> sigEnc, required int frameLimit, required bool devSoftEnc}) =>
      (FakeClaim(this), cstep(StepKind.write, frames: [
        [1]
      ]));
  @override
  Future<SealParams> crateApiClaimStoreSealParams({required String dir, required String rel}) async =>
      SealParams(generation: BigInt.two, aad: Uint8List(1));
  @override
  Future<void> crateApiClaimStoreWriteSealed({required String dir, required String rel, required BigInt generation, required List<int> sealed}) async {
    calls.add('write $rel');
    disk[rel] = Uint8List.fromList(sealed);
  }

  @override
  Future<void> crateApiClaimStoreRemove({required String dir, required String rel}) async {
    calls.add('remove $rel');
    disk.remove(rel);
    pendingIds.remove(rel.replaceFirst('claim-pending/', '')); // the list follows the disk
  }

  @override
  Future<bool> crateApiClaimStoreKeepCopy({required String dir, required String rel}) async {
    calls.add('copy $rel');
    return disk.containsKey(rel);
  }

  @override
  Future<SealedRecord?> crateApiOwnerStoreReadSealed({required String dir, required String rel}) async {
    final d = disk[rel];
    return d == null ? null : SealedRecord(generation: BigInt.one, sealed: d, aad: Uint8List(1));
  }

  @override
  Future<bool> crateApiClaimPendingMatchesQr({required List<int> record, required ClaimQr qr}) async => true;

  @override
  (ReplaySession, Uint8List) crateApiReplayReplaySessionPrepare(
      {required List<int> pendingPlain, required String deviceId, required bool devSoftEnc}) {
    if (replayOff) throw '這個版本的 app 還不能恢復中斷的認領（紀錄先保留）';
    return (FakeReplay(), Uint8List.fromList([4, ...List.filled(64, 1)]));
  }

  @override
  String crateApiReplayRecoveryEndText({required RecoveryEnd end, required bool after9, required bool unanswered, required bool oldRecord}) {
    if (end == RecoveryEnd.stopped && !unanswered) return '';
    final s = 'END ${end.name} after9=$after9';
    endTexts.add(s);
    return s;
  }

  @override
  dynamic noSuchMethod(Invocation i) => throw UnimplementedError('${i.memberName}');
}

/// The claim page's BLE: one device 'AA'; each write gets the next frame on TX ([1] -> [2], [3] -> [4], [5] -> [6]
/// unless the finish answer is held back)
class FakeBle implements FlutterReactiveBle {
  @override
  Stream<BleStatus> get statusStream => Stream.value(BleStatus.ready); // the recovery waits for it (ReactiveRecoveryBle)
  final tx = StreamController<List<int>>.broadcast();
  final written = <List<int>>[];
  bool answerFinish = true;

  @override
  Stream<DiscoveredDevice> scanForDevices({required List<Uuid> withServices, ScanMode scanMode = ScanMode.balanced, bool requireLocationServicesEnabled = true}) =>
      (StreamController<DiscoveredDevice>()..add(DiscoveredDevice(id: 'AA', name: '', serviceData: const {}, manufacturerData: Uint8List(0), rssi: -40, serviceUuids: const []))).stream;
  @override
  Stream<ConnectionStateUpdate> connectToDevice({required String id, Map<Uuid, List<Uuid>>? servicesWithCharacteristicsToDiscover, Duration? connectionTimeout}) =>
      (StreamController<ConnectionStateUpdate>()..add(ConnectionStateUpdate(deviceId: id, connectionState: DeviceConnectionState.connected, failure: null))).stream;
  @override
  Future<List<int>> readCharacteristic(QualifiedCharacteristic c) async => [0];
  @override
  Future<int> requestMtu({required String deviceId, required int mtu}) async => 517;
  @override
  Stream<List<int>> subscribeToCharacteristic(QualifiedCharacteristic c) => tx.stream;
  @override
  Future<void> writeCharacteristicWithoutResponse(QualifiedCharacteristic c, {required List<int> value}) async {
    written.add(value);
    if (value[0] == 5 && !answerFinish) return;
    Timer.run(() => tx.add([value[0] + 1]));
  }

  @override
  dynamic noSuchMethod(Invocation i) => throw UnimplementedError('${i.memberName}');
}

void main() {
  var devTrust = false; // what the platform says (T4 is dev only)
  var blePerm = true;
  var blePermAsked = 0;
  var blePermDelay = Duration.zero;
  final rust = FakeRust();
  setUpAll(() => RustLib.initMock(api: rust));
  setUp(() {
    rust
      ..calls.clear()
      ..disk.clear()
      ..disk[pendPath] = Uint8List.fromList(pendingBytes)
      ..target = ClaimTarget.pending
      ..statusState = 'claimed'
      ..statusLast4 = null
      ..due = true
      ..dueThrows = false
      ..replayOff = false
      ..pendingIds.clear()
      ..nodeIds.clear()
      ..endTexts.clear();
  });

  late FakeField field;
  late FakeBle ble;

  /// scan, 「認領」, answer dialogs in [confirm] order as they appear, run (wall-clock search, fake-clock recovery)
  Future<void> runPage(WidgetTester t,
      {List<String> confirm = const [], int iters = 400, bool Function()? until, bool t4 = false, RawUse? use, bool fakeRecovery = true}) async {
    final t0 = t.binding.clock.now();
    now = () => t.binding.clock.now().difference(t0);
    mockPlatformReadOnly(t, (c) async { // read-only replies, as on the S20
      switch (c.method) {
        case 'scanQr':
          return qrText;
        case 'devTrust':
          return devTrust;
        case 'filesDir':
          return files;
        case 'blePermissions':
          blePermAsked++;
          if (blePermDelay > Duration.zero) await Future<void>.delayed(blePermDelay);
          return blePerm;
        case 'publicKeys':
          return {'owner': Uint8List(65), 'ownerEnc': Uint8List(65), 'admin': Uint8List(65)};
        case 'open':
          return Uint8List.fromList((c.arguments as Map)['sealed'] as Uint8List);
        case 'seal':
          return Uint8List.fromList((c.arguments as Map)['plain'] as Uint8List);
      }
      return FakePlatform().handle(c);
    });
    await t.pumpWidget(MaterialApp(
        home: ClaimPage(
            ble: ble, recoveryBle: fakeRecovery ? field : null, use: use, findFor: const Duration(milliseconds: 800))));
    if (t4) {
      await t.pumpAndSettle(); // the pending list is read at start
      await t.tap(find.text('從認領暫存恢復'));
    } else {
      await t.tap(find.text('掃描 QR'));
      await t.pumpAndSettle();
      await t.tap(find.text('認領'));
    }
    final left = [...confirm];
    for (var i = 0; i < iters; i++) {
      await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 5))); // the search window is wall-clock
      await t.pump(const Duration(milliseconds: 250));
      if (left.isNotEmpty && find.text(left.first).evaluate().isNotEmpty) {
        await t.tap(find.text(left.removeAt(0)));
      }
      if (until != null && until()) break;
    }
  }

  bool pageSays(String s) => find.textContaining(s).evaluate().isNotEmpty;

  setUp(() {
    field = FakeField();
    ble = FakeBle();
    devTrust = false;
    blePerm = true;
    blePermAsked = 0;
    blePermDelay = Duration.zero;
  });

  // D3 = §0's symptom: the node is claimed, the phone holds only the pending -> 「認領」 with the same QR finds no
  // unclaimed node -> T2 -> the node record is written (copy -> write -> remove the pending), the QR forgotten.
  // Negative control: no recovery (the field build's refusal here) -> NOT_FOUND and no node record (today's behaviour).
  testWidgets('D3: claimed node + only a pending -> T2 recovers it', (t) async {
    field.add(Dev('BB', -50, ours: true));
    await runPage(t, until: () => pageSays('已恢復') || pageSays('RECOVERED'));
    await t.pump(const Duration(minutes: 5));
    expect(pageSays('沒找到未認領的這台，改試恢復先前的認領'), isTrue);
    expect(rust.calls, ['copy $nodeRecPath', 'write $nodeRecPath', 'remove $pendPath']);
    expect(rust.disk[nodeRecPath], rec(1));
    final claim = t.widget<FilledButton>(find.widgetWithText(FilledButton, '認領'));
    expect(claim.onPressed, isNull, reason: 'R6: after a recovery the QR is forgotten');
  });

  testWidgets('D3 negative control: no recovery -> NOT_FOUND, no node record', (t) async {
    rust.replayOff = true;
    field.add(Dev('BB', -50, ours: true));
    // #335 CI: the search window is wall-clock (800 ms); wait for its outcome, not a fixed number of iterations (a
    // 5 ms real delay is ~15 ms on Windows, ~5 ms on Linux: 120 iterations were enough only on Windows)
    await runPage(t, iters: 2000, until: () => pageSays('秒內沒找到編號末四碼'));
    expect(pageSays('秒內沒找到編號末四碼'), isTrue);
    expect(rust.disk.containsKey(nodeRecPath), isFalse);
    expect(rust.disk[pendPath], pendingBytes);
    expect(field.connects, 0);
  });

  // D4 / T3: a node record AND a pending -> asked first; 取消 -> no connection, the records unchanged, NOT_FOUND
  testWidgets('D4: node record + pending -> T3 asked; cancelled -> nothing connects', (t) async {
    rust.target = ClaimTarget.nodeAndPending;
    rust.disk[nodeRecPath] = Uint8List.fromList([0x6f]);
    field.add(Dev('BB', -50, ours: true));
    await runPage(t, confirm: ['重新認領', '取消'], iters: 2000, until: () => pageSays('秒內沒找到編號末四碼')); // wall-clock search, as D3-
    expect(field.connects, 0);
    expect(rust.calls, isEmpty);
    expect(pageSays('秒內沒找到編號末四碼'), isTrue);
    expect(rust.disk[nodeRecPath], [0x6f]);
  });

  testWidgets('D4: node record + pending -> T3 confirmed -> recovered', (t) async {
    rust.target = ClaimTarget.nodeAndPending;
    rust.disk[nodeRecPath] = Uint8List.fromList([0x6f]);
    field.add(Dev('BB', -50, ours: true));
    await runPage(t, confirm: ['重新認領', '恢復'], until: () => rust.calls.contains('remove $pendPath'));
    await t.pump(const Duration(minutes: 5));
    expect(rust.calls, ['copy $nodeRecPath', 'write $nodeRecPath', 'remove $pendPath']);
  });

  // D4: the node record forgotten (dev 「忘記節點」), the pending still there -> no T3, straight to the recovery
  // (§2's accepted exception). Negative control: T3 asked whatever is held -> the test hangs at the dialog.
  testWidgets('D4: only a pending -> no T3 question', (t) async {
    field.add(Dev('BB', -50, ours: true));
    await runPage(t, until: () => rust.calls.contains('remove $pendPath'));
    await t.pump(const Duration(minutes: 5));
    expect(find.text('要恢復這台節點嗎？'), findsNothing);
    expect(rust.disk[nodeRecPath], rec(1));
  });

  // T1 at the page (D1): the claim's finish answered 9 (replay_due) -> after 15 s the SAME device ('AA', the one the
  // claim used) is replayed; provd's cache lags one handshake (N3) -> round 2 recovers. Nothing else is connected.
  testWidgets('T1: finish 9 -> the claim\'s device is replayed and recovered', (t) async {
    rust
      ..statusState = 'unclaimed'
      ..statusLast4 = '4f2a';
    field
      ..add(Dev('AA', -70, ours: true)..fakeFor = 1)
      ..add(Dev('CC', -20));
    await runPage(t, until: () => rust.calls.contains('remove $pendPath'));
    await t.pump(const Duration(minutes: 5));
    expect(ble.written, [
      [1],
      [3],
      [5]
    ], reason: 'msg1, begin, finish');
    expect(field.connectLog, ['AA', 'AA']);
    expect(pageSays('改試恢復這次的認領'), isTrue);
    expect(rust.disk[nodeRecPath], rec(1));
  });

  // D13: replay_due() throws -> false: no recovery, the pending kept, nothing surfaces as an error
  testWidgets('D13: replay_due throws -> no recovery, pending kept', (t) async {
    rust
      ..statusState = 'unclaimed'
      ..statusLast4 = '4f2a'
      ..dueThrows = true;
    field.add(Dev('AA', -70, ours: true));
    await runPage(t, iters: 200);
    expect(field.connects, 0);
    expect(rust.disk[pendPath], isNotNull);
    expect(rust.calls.where((c) => c.contains('remove')), isEmpty);
    expect(pageSays('認領中斷'), isFalse);
  });

  // D6 (§2): the page is left while the claim waits for the finish answer -> the finish is not interrupted; at T1's
  // decision point the page is gone -> no recovery; the pending stays for the next 「認領」 (T2)
  testWidgets('D6: page left during the finish -> T1 does not start, pending kept', (t) async {
    rust
      ..statusState = 'unclaimed'
      ..statusLast4 = '4f2a';
    ble.answerFinish = false;
    field.add(Dev('AA', -70, ours: true));
    await runPage(t, iters: 40, until: () => ble.written.length == 3);
    expect(ble.written.last, [5], reason: 'the finish went out');
    await t.pumpWidget(const MaterialApp(home: Text('elsewhere')));
    for (var i = 0; i < 500; i++) {
      await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 1)));
      await t.pump(const Duration(milliseconds: 250));
    }
    expect(field.connects, 0, reason: 'no T1 after the page left');
    expect(rust.disk[pendPath], isNotNull);
    expect(rust.calls.where((c) => c.contains('remove')), isEmpty);
  });

  // D6: leaving the page during a recovery stops it (dispose -> cancel): no further connections, pending kept.
  // 「停止恢復」 replaces 「認領」 while it runs.
  testWidgets('D6: the stop button while recovering, then the page leaves -> stopped, pending kept', (t) async {
    for (var i = 0; i < 6; i++) {
      field.add(Dev('X$i', -20 - i)..msg2Silent = true);
    }
    await runPage(t, iters: 200, until: () => field.connects >= 2);
    expect(find.widgetWithText(FilledButton, '停止恢復'), findsOneWidget);
    await t.pumpWidget(const MaterialApp(home: Text('elsewhere')));
    final n = field.connects;
    for (var i = 0; i < 400; i++) {
      await t.pump(const Duration(milliseconds: 250));
    }
    expect(field.connects, n, reason: 'nothing connects after the page left');
    expect(field.devs.values.expand((d) => d.links).every((l) => l.closed), isTrue);
    expect(rust.disk[pendPath], pendingBytes);
  });

  // ---- v6 T4: 「從認領暫存恢復」 ----

  Future<void> openPage(WidgetTester t) async {
    mockPlatformReadOnly(t, (c) async {
      switch (c.method) {
        case 'devTrust':
          return devTrust;
        case 'filesDir':
          return files;
      }
      return null;
    });
    await t.pumpWidget(MaterialApp(home: ClaimPage(ble: ble, recoveryBle: field)));
    await t.pumpAndSettle();
  }

  // D17: a dev build shows the entry only when a claim-pending exists. Negative control: the non-empty check -> the
  // entry with no pending.
  testWidgets('D17: the entry only with a claim-pending', (t) async {
    devTrust = true;
    await openPage(t);
    expect(find.text('從認領暫存恢復'), findsNothing, reason: 'no pending');
    rust.pendingIds.add(deviceId);
    await openPage(t);
    await t.pumpWidget(const SizedBox());
    await t.pumpWidget(MaterialApp(home: ClaimPage(ble: ble, recoveryBle: field)));
    await t.pumpAndSettle();
    expect(find.text('從認領暫存恢復'), findsOneWidget);
  });

  // D21: the field build (devTrust false) has no entry, whatever is on disk. Negative control: the devTrust check
  // dropped -> the entry in the field build.
  testWidgets('D21: no entry in the field build', (t) async {
    rust.pendingIds.add(deviceId);
    await openPage(t);
    expect(find.text('從認領暫存恢復'), findsNothing);
  });

  // D18 (Dart): the list names each pending by the last 6 characters, or by the whole id where two share them.
  // Negative control: always the last 6 -> two identical labels.
  test('D18: pendingLabels — 6 characters, the full id where they collide', () {
    expect(pendingLabels(['0000000000000c4f2a', 'e61551410cfd538e24']), {
      '0000000000000c4f2a': '…0c4f2a',
      'e61551410cfd538e24': '…538e24',
    });
    expect(pendingLabels(['aaaaaaaaaaaa0c4f2a', 'bbbbbbbbbbbb0c4f2a', 'e61551410cfd538e24']), {
      'aaaaaaaaaaaa0c4f2a': 'aaaaaaaaaaaa0c4f2a',
      'bbbbbbbbbbbb0c4f2a': 'bbbbbbbbbbbb0c4f2a',
      'e61551410cfd538e24': '…538e24',
    });
  });

  // #329 PR 1 review r5 I-M1: the real ClaimPage builds its recovery radio itself (no injected recoveryBle): the
  // recovery's scan is counted by the gate (A10, 4 in 30 s). Negative control: ClaimPage's
  // ReactiveRecoveryBle(_ble) without onScan -> FAIL.
  testWidgets('r5 I-M1: T4 on the real recovery radio -> its scan is counted by the gate', (t) async {
    devTrust = true;
    rust.pendingIds.add(deviceId);
    final clock = nlt.Clock();
    final reg = LeaseRegistry(after: clock.after);
    final gate = BleGate(nlt.Radio(), reg, now: () => clock.t, after: clock.after);
    final lease = reg.acquire('新增節點', LeaseKind.raw)!;
    await runPage(t,
        t4: true,
        confirm: ['節點 …0c4f2a', '恢復'],
        use: RawUse(lease, gate),
        fakeRecovery: false,
        iters: 60,
        until: () => gate.recentScanStarts > 0);
    expect(gate.recentScanStarts, greaterThan(0), reason: 'the recovery scanned through the page''s counted radio');
    await t.pumpWidget(const SizedBox());
    for (var i = 0; i < 40; i++) {
      await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 5)));
      await t.pump(const Duration(seconds: 30)); // the recovery's own waits run out (it stops without a page)
    }
    await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
  });

  // D22: cancelled at the confirmation -> no connection, nothing written, the pending kept. Negative control: the
  // confirmation's answer ignored -> a connection.
  testWidgets('D22: T4 cancelled at the confirmation -> nothing connects', (t) async {
    devTrust = true;
    rust.pendingIds.add(deviceId);
    field.add(Dev('BB', -50, ours: true));
    await runPage(t, t4: true, confirm: ['節點 …0c4f2a', '取消'], iters: 80);
    expect(pageSays('沒有恢復，手機裡的紀錄沒有改動'), isTrue);
    expect(field.connects, 0);
    expect(rust.calls, isEmpty);
    expect(rust.disk[pendPath], pendingBytes);
  });

  // T4 end to end at the page: chosen and confirmed -> its own intro (not T2's), recovered, node record written,
  // pending removed; `_busy` holds the other buttons off while it runs; the BLE permissions were asked first.
  // Negative controls: `_busy` not taken -> 掃描 QR enabled during the run; T2's intro -> FAIL.
  testWidgets('T4: chosen + confirmed -> recovered, own intro, _busy held, permissions asked', (t) async {
    devTrust = true;
    rust.pendingIds.add(deviceId);
    field.add(Dev('BB', -50, ours: true));
    var checks = 0;
    var freeDuringRun = false;
    await runPage(t, t4: true, confirm: ['節點 …0c4f2a', '恢復'], until: () {
      if (field.connects > 0 && !rust.calls.contains('remove $pendPath')) {
        final scan = t.widget<FilledButton>(find.widgetWithText(FilledButton, '掃描 QR'));
        final paste = t.widget<OutlinedButton>(find.widgetWithText(OutlinedButton, '貼上 QR 碼（開發用）'));
        checks++;
        if (scan.onPressed != null || paste.onPressed != null) freeDuringRun = true;
      }
      return rust.calls.contains('remove $pendPath');
    });
    await t.pump(const Duration(minutes: 5));
    expect(checks, greaterThan(0));
    expect(freeDuringRun, isFalse, reason: 'the other buttons are off during T4');
    expect(blePermAsked, 1);
    expect(pageSays('從認領暫存恢復節點 …0c4f2a'), isTrue);
    expect(pageSays('沒找到未認領的這台'), isFalse, reason: 'T4 has its own intro');
    expect(rust.calls, ['copy $nodeRecPath', 'write $nodeRecPath', 'remove $pendPath']);
    expect(rust.disk[nodeRecPath], rec(1));
  });

  // v6.1 §19.2-8: no BLE permission -> said, nothing connects. Negative control: the permission check dropped.
  testWidgets('T4: no BLE permission -> no connection', (t) async {
    devTrust = true;
    blePerm = false;
    rust.pendingIds.add(deviceId);
    field.add(Dev('BB', -50, ours: true));
    await runPage(t, t4: true, confirm: ['節點 …0c4f2a', '恢復'], iters: 80);
    expect(pageSays('沒有藍牙權限'), isTrue);
    expect(field.connects, 0);
    expect(rust.disk[pendPath], pendingBytes);
  });

  // §19.2-4 / v6.1 §19.2-6: a node record too -> T3 is asked, without T2's 「沒找到未認領的這台」. Negative control: T2's
  // T3 text in T4 -> FAIL.
  testWidgets('T4 + a node record -> T3 asked without the "not found" sentence', (t) async {
    devTrust = true;
    rust
      ..pendingIds.add(deviceId)
      ..nodeIds.add(deviceId)
      ..disk[nodeRecPath] = Uint8List.fromList([0x6f]);
    field.add(Dev('BB', -50, ours: true));
    var sawT3 = false;
    await runPage(t, t4: true, confirm: ['節點 …0c4f2a', '恢復'], iters: 60, until: () {
      if (find.text('要恢復這台節點嗎？').evaluate().isNotEmpty) {
        sawT3 = true;
        return true;
      }
      return false;
    });
    expect(sawT3, isTrue);
    expect(find.textContaining('手機裡有它一次沒完成的認領'), findsOneWidget);
    expect(find.textContaining('沒找到未認領的這台'), findsNothing);
    await t.tap(find.text('取消'));
    for (var i = 0; i < 20; i++) {
      await t.pump(const Duration(milliseconds: 250));
    }
    expect(field.connects, 0);
  });

  // T4 review A-m1 (the reviewer's probe): the page is left while the BLE permission is being asked (after the
  // confirmation) -> no recovery runs without its page / stop button: no connection, nothing written, pending kept.
  // Negative control: the `mounted` check before _recover removed -> connects, node written, pending removed.
  testWidgets('T4: page left after the confirmation -> no recovery in the background', (t) async {
    devTrust = true;
    blePermDelay = const Duration(seconds: 5);
    rust.pendingIds.add(deviceId);
    field.add(Dev('BB', -50, ours: true));
    await runPage(t, t4: true, confirm: ['節點 …0c4f2a', '恢復'], iters: 40, until: () => blePermAsked == 1);
    expect(blePermAsked, 1);
    await t.pumpWidget(const MaterialApp(home: Text('elsewhere')));
    for (var i = 0; i < 400; i++) {
      await t.pump(const Duration(milliseconds: 250));
    }
    expect(field.connects, 0);
    expect(rust.calls, isEmpty);
    expect(rust.disk[pendPath], pendingBytes);
  });

  // T4 review A-m2: after a successful T4 the list is read again: that pending is gone, so is the entry.
  // Negative control: no list refresh after the run -> the entry stays.
  testWidgets('T4: after a recovery the entry is gone with its pending', (t) async {
    devTrust = true;
    rust.pendingIds.add(deviceId);
    field.add(Dev('BB', -50, ours: true));
    await runPage(t, t4: true, confirm: ['節點 …0c4f2a', '恢復'], until: () => rust.calls.contains('remove $pendPath'));
    await t.pump(const Duration(minutes: 5));
    await t.pumpAndSettle();
    expect(rust.pendingIds, isEmpty);
    expect(find.text('從認領暫存恢復'), findsNothing);
  });
}
