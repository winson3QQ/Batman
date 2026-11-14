// design v8.5.1 §4.1: the key gates of 「我的節點」 after a login, with a fake BLE node and a fake owner session.
// - 「建立網路」 reads the key levels live first (nodes.dart _makeNetwork): makeNetwork off -> `[REQ_FAIL] [KEY_LEVEL]`,
//   and neither publicKeys nor signAdmin is asked of Kotlin;
// - Kotlin's own gate (MainActivity.gate -> KeyPolicy.refused; error code `keyLevel`) refusing signAdmin in the middle
//   of a make-network is said on screen with the same [KEY_LEVEL] words, not only logged.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_reactive_ble/flutter_reactive_ble.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:batman_app/nodes.dart';
import 'package:batman_app/src/rust/api/owner.dart';
import 'package:batman_app/src/rust/frb_generated.dart';

const platform = MethodChannel('dev.batman/platform');
const deviceId = '0000000000000c4f2a';

OwnerStep step(OwnerKind kind, {String detail = ''}) => OwnerStep(
    kind: kind,
    frames: const [],
    signInput: Uint8List(4),
    detail: detail,
    record: Uint8List(0),
    rel: '',
    generation: BigInt.zero,
    aad: Uint8List(0),
    expectedGen: BigInt.zero,
    pollLink: false,
    hex: '',
    sas: '',
    renewed: false,
    sent: false,
    left: false,
    waitMs: BigInt.zero,
    sendUpdate: false,
    info: Uint8List(0),
    sw: false,
    note: ''); // 254-app-team-status: OwnerStep.note (the duplicate-address line)

/// make-network asks for the admin signature first; an empty signature ends it (as owner.rs does)
class FakeSession implements OwnerSession {
  final signed_ = <int>[];

  @override
  OwnerStep requestMakeNetwork(
          {required String netName, required int channel, required List<int> ownerEncPub, required List<int> adminPub}) =>
      step(OwnerKind.signAdmin);

  @override
  OwnerStep? signed({required List<int> der}) {
    signed_.add(der.length);
    return step(OwnerKind.answer, detail: der.isEmpty ? '[REQ_FAIL] 沒有簽章，沒有建立網路' : '[NET_MADE] 假的');
  }

  @override
  dynamic noSuchMethod(Invocation i) => throw UnimplementedError('${i.memberName}');
}

class FakeRust implements RustLibApi {
  final session = FakeSession();

  @override
  Future<List<String>> crateApiOwnerListNodes({required String dir}) async => [deviceId];
  @override
  Future<SealedRecord?> crateApiOwnerStoreReadSealed({required String dir, required String rel}) async =>
      SealedRecord(generation: BigInt.one, sealed: Uint8List(3), aad: Uint8List(1));
  @override
  Future<int> crateApiClaimFrameLimit({required List<int> ctrl, required int mtu}) async => 244;
  @override
  (OwnerSession, OwnerStep) crateApiOwnerOwnerSessionStart(
          {required List<int> recordPlain, required List<int> ownerPub, required int frameLimit}) =>
      (session, step(OwnerKind.loggedIn, detail: '已登入'));

  @override
  dynamic noSuchMethod(Invocation i) => throw UnimplementedError('${i.memberName}');
}

class FakeBle implements FlutterReactiveBle {
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
  Stream<List<int>> subscribeToCharacteristic(QualifiedCharacteristic c) => const Stream.empty();

  @override
  dynamic noSuchMethod(Invocation i) => throw UnimplementedError('${i.memberName}');
}

/// the `keyLevels` answer in MainActivity's full shape: the four levels by role name, then what KeyPolicy allows
Map<String, Object?> levels({bool makeNetwork = true, int? admin = 1}) => {
      'RECORD_AES': 1,
      'OWNER_SIGN': 1,
      'ADMIN_SIGN': admin,
      'OWNER_ENC': 1,
      'appUsable': true,
      'claim': true,
      'login': true,
      'recover': true,
      'makeNetwork': makeNetwork,
      'softOwnerEnc': false,
    };

void main() {
  final rust = FakeRust();
  setUpAll(() => RustLib.initMock(api: rust));
  setUp(rust.session.signed_.clear);
  final calls = <String>[];
  var keys = levels();
  Object? signAdmin; // what `signAdmin` answers; a PlatformException is thrown

  /// open 「我的節點」 and log in to the one node (every key fits at login)
  Future<void> login(WidgetTester t) async {
    keys = levels();
    signAdmin = Uint8List(70);
    t.binding.defaultBinaryMessenger.setMockMethodCallHandler(platform, (c) async {
      calls.add(c.method);
      switch (c.method) {
        case 'filesDir':
          return '/data/user/0/app/files';
        case 'keyLevels':
          return keys;
        case 'blePermissions':
          return true;
        case 'open':
          return Uint8List(4);
        case 'publicKeys':
          return {'owner': Uint8List(65), 'ownerEnc': Uint8List(65), 'admin': Uint8List(65)};
        case 'signAdmin':
          final a = signAdmin;
          if (a is PlatformException) throw a;
          return a;
      }
      return null;
    });
    await t.pumpWidget(MaterialApp(home: NodesPage(ble: FakeBle())));
    await t.pumpAndSettle();
    await t.tap(find.text('節點 …4f2a'));
    for (var i = 0; i < 10; i++) {
      // a cancelled subscription answers with a root-zone future: let the real event loop run it
      await t.runAsync(() => Future<void>.delayed(Duration.zero));
      await t.pump(const Duration(milliseconds: 300)); // the login polls what the scan found
    }
    await t.pumpAndSettle();
    expect(find.textContaining('已登入'), findsOneWidget, reason: 'the fake login went through');
    expect(t.widget<FilledButton>(find.widgetWithText(FilledButton, '建立網路')).onPressed, isNotNull, reason: 'logged in, not busy');
    calls.clear();
  }

  Future<void> makeNetwork(WidgetTester t) async {
    await t.ensureVisible(find.text('建立網路'));
    await t.pumpAndSettle();
    await t.tap(find.text('建立網路'));
    for (var i = 0; i < 5; i++) {
      await t.pump(const Duration(milliseconds: 100));
    }
  }

  // M1 (review 2026-11-14): negative control = the gate in _makeNetwork disabled -> this test FAILs
  testWidgets('建立網路: makeNetwork not allowed -> [KEY_LEVEL] refusal; publicKeys / signAdmin never asked', (t) async {
    await login(t);
    keys = levels(makeNetwork: false, admin: 0); // the admin key is not hardware any more (read live)
    await makeNetwork(t);
    expect(find.text('這支手機的網路管理金鑰不是硬體保護，不能建立網路'), findsOneWidget);
    expect(calls, ['keyLevels']);
    expect(calls, isNot(contains('publicKeys')));
    expect(calls, isNot(contains('signAdmin')));
    expect(rust.session.signed_, isEmpty, reason: 'the session was never asked to make a network');
  });

  testWidgets('建立網路: the admin key is lost -> the lost-key words, nothing asked', (t) async {
    await login(t);
    keys = levels(makeNetwork: false, admin: null);
    await makeNetwork(t);
    expect(find.text('這支手機的網路管理金鑰不見了，不能建立或更改網路'), findsOneWidget);
    expect(calls, ['keyLevels']);
  });

  // M3: Dart let it through (the levels changed between the read and the use, or a path with no Dart gate), Kotlin's
  // gate refuses the signature. Negative control = _keyFail only logging again -> this test FAILs
  for (final (name, level, text) in [
    ('not hardware', 0, '這支手機的網路管理金鑰不是硬體保護'),
    ('lost', null, '這支手機的網路管理金鑰不見了，不能建立或更改網路'),
  ]) {
    testWidgets('建立網路: Kotlin refuses signAdmin (admin key $name) -> said as [KEY_LEVEL], an empty signature ends it', (t) async {
      await login(t);
      signAdmin = PlatformException(code: 'keyLevel', message: 'ADMIN_SIGN', details: level);
      await makeNetwork(t);
      expect(calls, containsAllInOrder(['keyLevels', 'publicKeys', 'signAdmin']));
      expect(find.text(text), findsOneWidget);
      expect(rust.session.signed_, [0], reason: 'an empty signature: the flow ends before any record write');
      await t.pump(const Duration(seconds: 200)); // the request's wait timer
      await t.pumpAndSettle();
    });
  }

  testWidgets('control: every key fits -> the admin signature is asked and handed on', (t) async {
    await login(t);
    await makeNetwork(t);
    expect(calls, containsAllInOrder(['keyLevels', 'publicKeys', 'signAdmin']));
    expect(rust.session.signed_, [70]);
    expect(find.textContaining('網路管理金鑰'), findsNothing);
    await t.pump(const Duration(seconds: 200));
    await t.pumpAndSettle();
  });
}
