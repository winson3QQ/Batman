// design 254-app-claim-noover v2.1 T7 (R6) + the page-level order of T3: the whole claim page path with a fake BLE
// node and a fake ClaimSession: re-claim over a node record (confirmed) -> msg1 -> PersistPending -> begin -> CLAIMED.
// The store calls come in the order of R1 (nothing on node/ before CLAIMED; copy -> write -> remove), and after
// [CLAIMED] the QR is forgotten: 「認領」 is off until a new scan.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_reactive_ble/flutter_reactive_ble.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart' show Uint64List;
import 'package:flutter_test/flutter_test.dart';

import 'package:batman_app/claim.dart';
import 'package:batman_app/src/rust/api/claim.dart';
import 'package:batman_app/src/rust/api/owner.dart' show SealedRecord;
import 'package:batman_app/src/rust/api/simple.dart' show StatusInfo;
import 'package:batman_app/src/rust/frb_generated.dart';

const qrText = 'a201726261746d616e2d746573742d71722d303102582000112233445566778899aabbccddeeff0011';
const deviceId = '0000000000000c4f2a';
const files = '/data/user/0/app/files';
const dir = '$files/records';

ClaimStep step(StepKind kind, {List<Uint8List> frames = const [], String path = '', String pendingPath = '', String detail = ''}) =>
    ClaimStep(kind: kind, frames: frames, path: path, record: Uint8List(2), pendingPath: pendingPath, detail: detail);

/// msg2 -> PersistPending; pending persisted -> the begin frame; the node's answer -> CLAIMED
class FakeSession implements ClaimSession {
  @override
  ClaimStep? onFrame({required List<int> frame}) => frame[0] == 2
      ? step(StepKind.persistPending, path: 'claim-pending/$deviceId')
      : step(StepKind.claimed, path: 'node/$deviceId', pendingPath: 'claim-pending/$deviceId', detail: '認領成功');

  @override
  ClaimStep? pendingPersisted() => step(StepKind.write, frames: [Uint8List.fromList([3])]);

  @override
  dynamic noSuchMethod(Invocation i) => null;
}

class FakeRust implements RustLibApi {
  final calls = <String>[];
  ClaimTarget target = ClaimTarget.node;
  bool pendingOnDisk = false; // a pending of another K
  bool copyFails = false;
  String statusState = 'unclaimed'; // what the fake node's status/public says
  String? statusLast4 = '4f2a';

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
          {required ClaimQr qr, required List<int> ownerPub, required List<int> ownerEncPub, required List<int> sigEnc, required int frameLimit}) =>
      (FakeSession(), step(StepKind.write, frames: [Uint8List.fromList([1])]));
  @override
  Future<SealParams> crateApiClaimStoreSealParams({required String dir, required String rel}) async =>
      SealParams(generation: BigInt.two, aad: Uint8List(1));
  @override
  Future<void> crateApiClaimStoreWriteSealed({required String dir, required String rel, required BigInt generation, required List<int> sealed}) async =>
      calls.add('write $rel');
  @override
  Future<void> crateApiClaimStoreRemove({required String dir, required String rel}) async => calls.add('remove $rel');
  @override
  Future<bool> crateApiClaimStoreKeepCopy({required String dir, required String rel}) async {
    calls.add('copy $rel');
    if (copyFails) throw 'Io(StorageFull)';
    return true;
  }
  @override
  Future<SealedRecord?> crateApiOwnerStoreReadSealed({required String dir, required String rel}) async {
    calls.add('read $rel');
    return pendingOnDisk ? SealedRecord(generation: BigInt.one, sealed: Uint8List(3), aad: Uint8List(1)) : null;
  }

  @override
  Future<bool> crateApiClaimPendingMatchesQr({required List<int> record, required ClaimQr qr}) async => false;

  @override
  dynamic noSuchMethod(Invocation i) => throw UnimplementedError('${i.memberName}');
}

/// one provd node: every write gets the next answer frame on TX (msg1 -> [2], begin -> [4])
class FakeBle implements FlutterReactiveBle {
  final tx = StreamController<List<int>>.broadcast();
  final written = <List<int>>[];

  @override
  Stream<DiscoveredDevice> scanForDevices({required List<Uuid> withServices, ScanMode scanMode = ScanMode.balanced, bool requireLocationServicesEnabled = true}) =>
      (StreamController<DiscoveredDevice>()..add(DiscoveredDevice(id: 'AA', name: '', serviceData: const {}, manufacturerData: Uint8List(0), rssi: -40, serviceUuids: const []))).stream; // open, like a real scan
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
    final answer = value[0] == 1 ? 2 : 4;
    Timer.run(() => tx.add([answer]));
  }

  @override
  dynamic noSuchMethod(Invocation i) => throw UnimplementedError('${i.memberName}');
}

void main() {
  final rust = FakeRust();
  setUpAll(() => RustLib.initMock(api: rust));
  setUp(() => rust
    ..calls.clear()
    ..target = ClaimTarget.node
    ..pendingOnDisk = false
    ..copyFails = false
    ..statusState = 'unclaimed'
    ..statusLast4 = '4f2a');

  /// scan, 「認領」, answer the dialog with [confirm], then let the claim run
  Future<FakeBle> runClaim(WidgetTester t, String confirm, {Duration findFor = const Duration(seconds: 60), int realMs = 0}) async {
    final ble = FakeBle();
    t.binding.defaultBinaryMessenger.setMockMethodCallHandler(const MethodChannel('dev.batman/platform'), (c) async {
      switch (c.method) {
        case 'scanQr':
          return qrText;
        case 'filesDir':
          return files;
        case 'blePermissions':
          return true;
        case 'publicKeys':
          return {'owner': Uint8List(65), 'ownerEnc': Uint8List(65)};
        case 'signOwner':
          return Uint8List(70);
        case 'seal':
          return Uint8List(3);
        case 'open':
          return Uint8List(4);
      }
      return null;
    });
    await t.pumpWidget(MaterialApp(home: ClaimPage(ble: ble, findFor: findFor)));
    await t.tap(find.text('掃描 QR'));
    await t.pumpAndSettle();
    await t.tap(find.text('認領'));
    await t.pumpAndSettle();
    if (confirm.isNotEmpty) await t.tap(find.text(confirm)); // '' = no dialog (nothing held)
    for (var i = 0; i < 100; i++) {
      // a cancelled subscription answers with a root-zone future: let the real event loop run it
      await t.runAsync(() => Future<void>.delayed(Duration(milliseconds: realMs))); // realMs: the search window is wall-clock
      await t.pump(const Duration(milliseconds: 200));
    }
    await t.pumpAndSettle();
    return ble;
  }

  testWidgets('T7 / T3: a confirmed re-claim goes through; records in R1 order; after [CLAIMED] 認領 is off', (t) async {
    rust
      ..calls.clear()
      ..target = ClaimTarget.node
      ..pendingOnDisk = false
      ..copyFails = false;
    final ble = await runClaim(t, '重新認領');
    expect(find.text('認領成功'), findsOneWidget);
    expect(ble.written, [[1], [3]], reason: 'msg1, then begin after the pending');
    expect(rust.calls, [
      'read claim-pending/$deviceId', // PersistPending: from disk (no pending there)
      'write claim-pending/$deviceId',
      'copy node/$deviceId', // CLAIMED: copy -> write -> remove
      'write node/$deviceId',
      'remove claim-pending/$deviceId',
    ]);
    final claim = t.widget<FilledButton>(find.widgetWithText(FilledButton, '認領'));
    expect(claim.onPressed, isNull, reason: 'R6: the QR is forgotten after [CLAIMED]');
  });

  // T12 at page level (code review A-m1): a pending of another K is on disk, the user chose this QR (R4), and the copy
  // fails at PersistPending -> no new pending is written and claim/begin never goes out (only msg1 was written).
  testWidgets('T12: the pending copy fails at PersistPending -> no pending written, no begin', (t) async {
    rust
      ..calls.clear()
      ..target = ClaimTarget.pending
      ..pendingOnDisk = true
      ..copyFails = true;
    final ble = await runClaim(t, '改用這張 QR 碼');
    expect(ble.written, [[1]], reason: 'msg1 only: no begin');
    expect(rust.calls, ['read claim-pending/$deviceId', 'read claim-pending/$deviceId', 'copy claim-pending/$deviceId']);
    expect(find.textContaining('認領沒有完成'), findsOneWidget);
  });

  // 2026-11-13 on the phone (R7-2): a confirmed re-claim of a node that is still claimed found no unclaimed node and only
  // said 「請確認節點已開機、就在旁邊」 while the node was right there. A claimed node publishes no id tail, so the page
  // cannot know it is this QR's node: the power / range hint stays, a claimed node nearby is added as a possibility
  // (no count, no reset advice), and nothing is written. Negative control: the added sentence removed -> FAIL.
  testWidgets('R7-2: a node record held, a claimed node nearby -> hint kept, "use it from 我的節點", nothing written', (t) async {
    rust
      ..statusState = 'claimed'
      ..statusLast4 = null;
    final ble = await runClaim(t, '重新認領', findFor: const Duration(milliseconds: 800), realMs: 50);
    expect(find.textContaining('請確認節點已開機、就在旁邊'), findsOneWidget);
    expect(find.textContaining('可能就是這台'), findsOneWidget);
    expect(find.textContaining('不用重新認領'), findsOneWidget);
    expect(find.textContaining('重燒過卡的話，要掃它新的 QR 碼'), findsOneWidget, reason: 'a re-flashed node has a new identity and a new QR');
    expect(find.textContaining('恢復出廠'), findsNothing);
    expect(find.textContaining('台已認領'), findsNothing, reason: 'no count: rotating BLE addresses can count one node twice');
    expect(ble.written, isEmpty, reason: 'no msg1 to a node that is not ours');
    expect(rust.calls, isEmpty, reason: 'no record read for writing, none written');
  });

  // no record for this device id (a first claim): a claimed node nearby may be someone else's -> say it cannot be
  // claimed, never "use it from 我的節點"
  testWidgets('R7-2: no record held, a claimed node nearby -> "cannot be claimed", not "use it from 我的節點"', (t) async {
    rust
      ..target = ClaimTarget.nothing
      ..statusState = 'member'
      ..statusLast4 = null;
    await runClaim(t, '', findFor: const Duration(milliseconds: 800), realMs: 50);
    expect(find.textContaining('請確認節點已開機、就在旁邊'), findsOneWidget);
    expect(find.textContaining('已經被認領的節點不能再認領'), findsOneWidget);
    expect(find.textContaining('我的節點'), findsNothing);
    expect(rust.calls, isEmpty);
  });

  // control: nothing claimed nearby (an unclaimed node of another tail) -> only the plain message
  testWidgets('R7-2 control: no claimed node seen -> the plain NOT_FOUND only', (t) async {
    rust.statusLast4 = '9999';
    final ble = await runClaim(t, '重新認領', findFor: const Duration(milliseconds: 800), realMs: 50);
    expect(find.textContaining('秒內沒找到編號末四碼'), findsOneWidget);
    expect(find.textContaining('請確認節點已開機、就在旁邊'), findsOneWidget);
    expect(find.textContaining('附近有已認領的節點'), findsNothing);
    expect(ble.written, isEmpty);
    expect(rust.calls, isEmpty);
  });
}
