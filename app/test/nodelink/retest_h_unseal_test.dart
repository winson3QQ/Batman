// #329 re-test (2026-11-17 audit): T-H5 (design §9.1) — 解開次數, counted on the real AppLink (its own NodeLink,
// SessionProber, hint wiring, NetIndex and lease registry) with a fake radio, a fake Rust API and a fake Keystore.
// What is counted: every record read from the store (Rust storeReadSealed, by path), every folder listing and every
// net summary. A home round must open no net / mnet record and list nothing; one read on the node page of a node in a
// known network opens exactly one; a lease release computes the network summary exactly once.
// Design negative control: the home page lists / opens the networks on every status read again -> FAIL.
import 'dart:async';
import 'dart:io';

import 'package:batman_app/src/flows/net_index.dart';
import 'package:batman_app/src/nodelink/app_link.dart';
import 'package:batman_app/src/nodelink/core.dart';
import 'package:batman_app/src/nodelink/lease.dart';
import 'package:batman_app/src/rust/api/owner.dart';
import 'package:batman_app/src/rust/api/member.dart' show MnetView;
import 'package:batman_app/src/rust/frb_generated.dart';
import 'package:flutter/services.dart';
import 'package:flutter_reactive_ble/flutter_reactive_ble.dart';
import 'package:flutter_test/flutter_test.dart';

import 'prober_hint_test.dart' show HintSession;
import 'prober_test.dart' show step;

const platform = MethodChannel('dev.batman/platform');
const id = '0000000000000c4f2a7d2c';
const netId = 'aa';

const netView = NetView(netId: netId, meshId: 'bm-aa', netName: '小隊', applied: true, country: 'US', members: []);

class CountingRust implements RustLibApi {
  final reads = <String>[]; // storeReadSealed paths
  final lists = <String>[]; // folder listings through Rust
  int summaries = 0;
  int sessions = 0;

  @override
  Future<SealedRecord?> crateApiOwnerStoreReadSealed({required String dir, required String rel}) async {
    reads.add(rel);
    return SealedRecord(generation: BigInt.one, sealed: Uint8List(3), aad: Uint8List(1));
  }

  @override
  Future<List<String>> crateApiOwnerListNodes({required String dir}) async => [id];
  @override
  Future<List<String>> crateApiOwnerListNets({required String dir}) async {
    lists.add('net');
    return [netId];
  }

  @override
  Future<List<String>> crateApiMemberListMnets({required String dir}) async {
    lists.add('mnet');
    return const [];
  }

  @override
  Future<List<String>> crateApiMemberListPends({required String dir}) async {
    lists.add('mpend');
    return const [];
  }

  @override
  NetView crateApiOwnerNetSummary({required List<int> recordPlain}) {
    summaries++;
    return netView;
  }

  @override
  MnetView crateApiMemberMnetSummary({required List<int> mnetPlain}) => throw UnimplementedError('no mnet here');

  @override
  Future<int> crateApiClaimFrameLimit({required List<int> ctrl, required int mtu}) async => 244;

  @override
  (OwnerSession, OwnerStep) crateApiOwnerOwnerSessionStart(
      {required List<int> recordPlain, required List<int> ownerPub, required int frameLimit}) {
    sessions++;
    // logged in at once; the status page request is answered by the next frame from the node
    return (HintSession([step(OwnerKind.answer)], netId: netId), step(OwnerKind.loggedIn, loginEnd: 1));
  }

  @override
  dynamic noSuchMethod(Invocation i) => throw UnimplementedError('${i.memberName}');
}

/// One node 'AA' that advertises, connects, and answers every write with one frame.
class OneNodeBle implements FlutterReactiveBle {
  final bleStatus = StreamController<BleStatus>.broadcast(sync: true);
  StreamController<List<int>>? tx;
  int writes = 0;

  @override
  Stream<BleStatus> get statusStream => bleStatus.stream;
  final links = StreamController<ConnectionStateUpdate>.broadcast(sync: true);
  @override
  Stream<ConnectionStateUpdate> get connectedDeviceStream => links.stream;

  @override
  Stream<DiscoveredDevice> scanForDevices(
      {required List<Uuid> withServices, ScanMode scanMode = ScanMode.balanced, bool requireLocationServicesEnabled = true}) {
    final c = StreamController<DiscoveredDevice>();
    scheduleMicrotask(() => c.add(DiscoveredDevice(
        id: 'AA', name: '', serviceData: const {}, manufacturerData: Uint8List(0), rssi: -40, serviceUuids: const [])));
    return c.stream;
  }

  @override
  Stream<ConnectionStateUpdate> connectToDevice(
      {required String id, Map<Uuid, List<Uuid>>? servicesWithCharacteristicsToDiscover, Duration? connectionTimeout}) {
    late final StreamController<ConnectionStateUpdate> c;
    c = StreamController<ConnectionStateUpdate>(onCancel: () => scheduleMicrotask(() => links
        .add(ConnectionStateUpdate(deviceId: id, connectionState: DeviceConnectionState.disconnected, failure: null))));
    scheduleMicrotask(() =>
        c.add(ConnectionStateUpdate(deviceId: id, connectionState: DeviceConnectionState.connected, failure: null)));
    return c.stream;
  }

  @override
  Future<int> requestMtu({required String deviceId, required int mtu}) async => 517;
  @override
  Future<List<int>> readCharacteristic(QualifiedCharacteristic c) async => [0];
  @override
  Stream<List<int>> subscribeToCharacteristic(QualifiedCharacteristic c) {
    final s = tx = StreamController<List<int>>.broadcast();
    return s.stream;
  }

  @override
  Future<void> writeCharacteristicWithoutResponse(QualifiedCharacteristic c, {required List<int> value}) async {
    writes++;
    final s = tx;
    Timer(const Duration(milliseconds: 5), () => s?.add([1]));
  }

  @override
  dynamic noSuchMethod(Invocation i) => throw UnimplementedError('${i.memberName}');
}

Future<void> until(bool Function() ok, String what) async {
  final stop = DateTime.now().add(const Duration(seconds: 20));
  while (!ok()) {
    if (DateTime.now().isAfter(stop)) fail('timed out waiting for $what');
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final rust = CountingRust();
  setUpAll(() => RustLib.initMock(api: rust));

  late Directory dir;
  final opens = <String>[]; // Keystore opens (platform 'open')
  setUp(() {
    dir = Directory.systemTemp.createTempSync('bm-th5');
    File('${dir.path}/records/net/$netId').createSync(recursive: true); // one network record on the phone
    rust.reads.clear();
    rust.lists.clear();
    rust.summaries = 0;
    rust.sessions = 0;
    opens.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(platform, (c) async {
      switch (c.method) {
        case 'open':
          opens.add('open');
          return Uint8List(4);
        case 'publicKeys':
          return {'owner': Uint8List(65)};
        case 'signOwner':
          return Uint8List(70);
        case 'keyLevels':
          return {'appUsable': true, 'login': true, 'claim': true, 'recover': true, 'makeNetwork': true, 'softOwnerEnc': false};
      }
      return null;
    });
  });
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(platform, null);
    AppLink.forgetForTest();
  });

  List<String> netReads() => rust.reads.where((r) => r.startsWith('net/') || r.startsWith('mnet/')).toList();
  int reads(AppLink a) => a.link.readWall.containsKey(id) ? 1 : 0;

  test('T-H5: home rounds open 0 net / mnet records and list nothing; one node-page read opens exactly 1', () async {
    AppLink.forgetForTest();
    final ble = OneNodeBle();
    final a = AppLink.create(platform: platform, filesDir: dir.path, ble: ble);
    addTearDown(() => a.link.dispose());
    a.devTrust = true; // a dev build: the node page works out the 「這台還在舊密碼」 hint (R6)
    // the phone knows the node's network (as NetIndex has it after the startup check)
    a.nets.setForTest(const NetSnapshot(netFiles: 1, nets: [NetEntry(netId, netView)]));
    ble.bleStatus.add(BleStatus.ready);

    await a.link.start(Page.home);
    await until(() => a.link.core.states[id]?.kind == Kind.read, 'the first home read');
    expect(rust.sessions, 1);
    // a second home read (the 「重新整理」 button)
    final w1 = a.link.readWall[id];
    await Future<void>.delayed(const Duration(milliseconds: 50));
    a.link.refresh();
    await until(() => rust.sessions == 2 && a.link.readWall[id] != w1, 'the second home read');
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(netReads(), isEmpty, reason: 'a home read opens no net / mnet record (reads: ${rust.reads})');
    expect(rust.lists, isEmpty, reason: 'a home read lists no network folder');
    expect(rust.summaries, 0);
    // #329 rotating identifier §3.3: the resolver build at start opens each node record once more
    expect(opens.length, 3, reason: 'only the node record: once for the identifier resolver at start, once per read');
    expect(a.link.hints, isEmpty, reason: 'no 「舊密碼」 line outside the node page');

    // the node page: X33 reads it at once; the node is in a network the phone knows -> exactly one record opened
    a.link.setPage(Page.node, node: id);
    await until(() => rust.sessions == 3, 'the node-page read');
    await until(() => a.link.hints.containsKey(id), 'the hint of the node-page read');
    expect(netReads(), ['net/$netId'], reason: 'exactly one net record for one node-page read');
    expect(rust.lists, isEmpty);
    expect(reads(a), 1);

    // back home: the hint goes, and a home read opens nothing again
    a.link.setPage(Page.home);
    expect(a.link.hints, isEmpty, reason: 'the 「舊密碼」 line is only on the node page');
    await Future<void>.delayed(const Duration(milliseconds: 50));
    a.link.refresh();
    await until(() => rust.sessions == 4, 'the home read after the node page');
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(netReads(), ['net/$netId'], reason: 'still the one of the node page (reads: ${rust.reads})');
  });

  test('T-H5: a lease release computes the network summary exactly once', () async {
    AppLink.forgetForTest();
    final ble = OneNodeBle();
    final a = AppLink.create(platform: platform, filesDir: dir.path, ble: ble);
    addTearDown(() => a.link.dispose());
    ble.bleStatus.add(BleStatus.ready);
    await a.link.start(Page.home);
    await until(() => a.link.core.states[id]?.kind == Kind.read, 'the first home read');
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(rust.summaries, 0, reason: 'nothing computed before a release');
    expect(netReads(), isEmpty);

    final l = await a.link.acquire('建立網路', LeaseKind.session);
    expect(l, isNotNull);
    await l!.release();
    await until(() => !a.nets.now.computing && a.nets.now.nets.isNotEmpty, 'the summary after the release');
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(rust.summaries, 1, reason: 'one computation per release');
    expect(netReads(), ['net/$netId']);
    expect(a.nets.now.nets.single.id, netId);
  });
}
