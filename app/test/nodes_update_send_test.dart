// design 254-app-remove-member v6.4 T19 / T30 (the Dart arm; line "Dart 只在按鈕送"): after the removal committed (T19)
// and after an update was imported (T30) the app sends nothing to a node on its own — no network/update, no frame at
// all — until the user presses 「把新密碼送給節點」. Rust has no path that sends by itself (tests/rekey.rs); what is
// checked here is that nodes.dart does not call request_send_update, and writes no frame, without the button.
//
// This is a page test: the driver (_NodesPageState) is private widget state, so it runs the real NodesPage with a
// fake Rust api, a fake owner session, a mocked platform channel and a fake BLE platform (ReactiveBlePlatform, below
// the plugin: NodesPage builds its own FlutterReactiveBle()). Nothing is asserted about layout or wording; controls
// are found by key or widget type, except 「把新密碼送給節點」 and 「狀態頁」 on the nodes page (no key in the product: by
// their labels, two constants below). The status page's own send button has a key (sendUpdate).
// Negative controls (mutants, never committed): `_takeUpdate` sending after a successful import -> T30 fails;
// `_remove` sending after the commit -> T19 fails; `_sendFromPage` without its `_sendUpdateFor` -> the status page
// arm of T30 fails (its button would only read the page again). The same sends put off by a timer (30 s or 5 min after
// the import / the commit / the status page opening) -> the 10-minute wait ([longWait]) after the 20 s catches them.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_reactive_ble/flutter_reactive_ble.dart';
import 'package:flutter_test/flutter_test.dart';
// ignore: depend_on_referenced_packages
import 'package:reactive_ble_platform_interface/reactive_ble_platform_interface.dart' show CharacteristicInstance;

import 'package:batman_app/nodes.dart';
import 'package:batman_app/src/rust/api/member.dart';
import 'package:batman_app/src/rust/api/owner.dart';
import 'package:batman_app/src/rust/api/rekey.dart';
import 'package:batman_app/src/rust/frb_generated.dart';

const deviceId = '0000000000000c4f2a';
const netId = 'abababababababababababababababababababababababababababababababab';
const files = '/data/user/0/app/files';
const sendLabel = '把新密碼送給節點'; // the only control found by its label (it has no key)
const statusLabel = '狀態頁'; // no key either

final service = Uuid.parse('540aa38c-0086-4d58-a9c0-c7c9d1e1bd42');
final chars = [for (final c in const ['9', 'a', 'b']) Uuid.parse('540aa38c-0086-4d5$c-a9c0-c7c9d1e1bd42')]; // RX, TX, ctrl

// frames of the fake protocol: the node answers every write [n] with [n + 1]
const fLogin = 1, fInfo = 10, fSend = 20, fStatus = 30;

OwnerStep step(OwnerKind kind, {int? frame, String detail = '', String rel = '', Uint8List? info}) => OwnerStep(
    kind: kind,
    frames: [if (frame != null) Uint8List.fromList([frame])],
    signInput: Uint8List(1),
    detail: detail,
    record: Uint8List(2),
    rel: rel,
    generation: BigInt.two,
    aad: Uint8List(1),
    expectedGen: BigInt.one,
    pollLink: false,
    hex: '',
    sas: '',
    renewed: false,
    sent: false,
    left: false,
    waitMs: BigInt.zero,
    sendUpdate: false,
    info: info ?? Uint8List(0),
    sw: false);

class FakeSession implements OwnerSession {
  FakeSession(this.rust);
  final FakeRust rust;

  @override
  OwnerStep? onFrame({required List<int> frame}) => switch (frame[0]) {
        const (fLogin + 1) => step(OwnerKind.loggedIn, detail: 'in'),
        const (fInfo + 1) => step(OwnerKind.answer, detail: 'info', info: Uint8List.fromList([7])),
        _ => step(OwnerKind.answer, detail: 'sent'),
      };

  @override
  OwnerStep requestInfo() => step(OwnerKind.write, frame: fInfo);

  // the status page (v8.1 §2): one read, a node in `netId`, and the §3.5 hint with its button
  @override
  OwnerStep requestStatusPage() => step(OwnerKind.write, frame: fStatus);
  @override
  String last4() => '4f2a';
  @override
  StatusView statusView({required bool hasNet, required bool hasMnet}) => StatusView(
      color: 'green',
      row: 'r',
      sentence: 's',
      lagNote: '',
      warning: '',
      nodeState: 2,
      netId: netId,
      version: '',
      tech: const [],
      fresh: true,
      rateNote: '',
      unfinished: '',
      unfinishedUnderVerdict: false,
      canLeave: false);
  @override
  UpdateHint updateHint({required List<int> recordPlain, required bool member}) => const UpdateHint(line: 'hint', button: true);

  @override
  OwnerStep requestSendUpdate({required List<int> recordPlain, required bool member, required List<int> adminPub}) {
    rust.sends.add(member ? 'member' : 'admin');
    return step(OwnerKind.write, frame: fSend);
  }

  @override
  dynamic noSuchMethod(Invocation i) => throw UnimplementedError('${i.memberName}');
}

/// the removal: SignAdmin -> PersistNet -> "[REKEY]"
class FakeRemoveOp implements RemoveOp {
  @override
  OwnerStep? signed({required List<int> der}) => step(OwnerKind.persistNet, rel: 'net/$netId');
  @override
  OwnerStep? netPersisted() => step(OwnerKind.answer, detail: '[REKEY] 已換密碼');
  @override
  dynamic noSuchMethod(Invocation i) => throw UnimplementedError('${i.memberName}');
}

class FakeRust implements RustLibApi {
  final calls = <String>[]; // record writes and the removal's start
  final sends = <String>[]; // request_send_update calls
  final records = <String>{}; // the records on "disk"

  @override
  Future<List<String>> crateApiOwnerListNodes({required String dir}) async => [deviceId];
  @override
  Future<List<String>> crateApiOwnerListNets({required String dir}) async => [
        for (final r in records)
          if (r.startsWith('net/')) r.substring(4)
      ];
  @override
  Future<SealedRecord?> crateApiOwnerStoreReadSealed({required String dir, required String rel}) async =>
      records.contains(rel) ? SealedRecord(generation: BigInt.one, sealed: Uint8List(3), aad: Uint8List(1)) : null;
  @override
  Future<BigInt> crateApiOwnerStoreWriteCas({required String dir, required String rel, required BigInt expectedGen, required List<int> sealed}) async {
    calls.add('cas $rel');
    records.add(rel);
    return BigInt.two;
  }

  @override
  Future<int> crateApiClaimFrameLimit({required List<int> ctrl, required int mtu}) async => 244;
  @override
  (OwnerSession, OwnerStep) crateApiOwnerOwnerSessionStart({required List<int> recordPlain, required List<int> ownerPub, required int frameLimit}) =>
      (FakeSession(this), step(OwnerKind.write, frame: fLogin));
  @override
  String crateApiRekeyInfoNetId({required List<int> info}) => info.isEmpty ? '' : netId;

  // T30: the member's import
  @override
  String crateApiRekeyUpdateNetId({required String hex}) => netId;
  @override
  UpdatePrep crateApiRekeyMemberUpdatePrepare(
          {required String hex, Uint8List? mnetPlain, required BigInt mnetGen, required List<Uint8List> nodeRecords, required List<int> ownerEncPub}) =>
      UpdatePrep(state: UpdateState.advance, ephPub: Uint8List(65), mnetGen: mnetGen, detail: '');
  @override
  OwnerStep crateApiRekeyMemberUpdateImport(
          {required String hex,
          Uint8List? mnetPlain,
          required BigInt mnetGen,
          required BigInt expectedGen,
          required List<Uint8List> nodeRecords,
          required List<int> ownerEncPub,
          required List<int> z}) =>
      step(OwnerKind.persistMnet, rel: 'mnet/$netId', detail: '已匯入');

  // the status page's reads of this phone's records
  @override
  Future<List<String>> crateApiMemberListMnets({required String dir}) async => [
        for (final r in records)
          if (r.startsWith('mnet/')) r.substring(5)
      ];
  @override
  MnetView crateApiMemberMnetSummary({required List<int> mnetPlain}) =>
      const MnetView(netId: netId, netName: 'n', entryState: 'applied', deviceLast4: '4f2a');
  @override
  List<String> crateApiOwnerLeaveConfirmText({required String last4, required String netId, required bool adminApplied, required bool memberEntry}) =>
      const ['t', 'b'];
  @override
  String crateApiOwnerStatusMembershipLine({required int nodeState, required String netId, String? name}) => 'm';

  // T19: the admin's removal
  @override
  NetView crateApiOwnerNetSummary({required List<int> recordPlain}) =>
      const NetView(netId: netId, meshId: 'm', netName: 'n', applied: true, country: 'US', members: []);
  @override
  List<PersonView> crateApiRekeyNetPeople({required List<int> recordPlain, required List<int> ownerPub}) => const [
        PersonView(owner: 'b0b0', fpr: 'F', name: 'Bob', isSelf: false, nodes: [PersonNode(last4: '1234', dacHash: 'dd', state: 'applied')], sameName: [])
      ];
  @override
  List<OwnNodeView> crateApiRekeyRemoveOwnNodes({required List<int> recordPlain, required List<int> ownerPub, required String person, required String node}) =>
      const [OwnNodeView(deviceId: deviceId, dacHash: 'ee')];
  @override
  RemovePlanView crateApiRekeyRemoveCheck(
          {required List<int> recordPlain,
          required List<int> adminPub,
          required List<int> ownerPub,
          required String person,
          required String node,
          required List<NodeInfo> reads}) =>
      const RemovePlanView(ok: true, text: 'plan', unverified: false, nodes: 1);
  @override
  String crateApiRekeyRemoveTickText() => 'tick';
  @override
  (RemoveOp, OwnerStep) crateApiRekeyRemoveOpStartRemove(
      {required List<int> recordPlain,
      required BigInt recordGen,
      required List<int> adminPub,
      required List<int> ownerPub,
      required String person,
      required String node,
      required List<NodeInfo> reads,
      required bool ticked}) {
    calls.add('remove $person ticked=$ticked reads=${reads.map((r) => r.info.length).toList()}');
    return (FakeRemoveOp(), step(OwnerKind.signAdmin));
  }

  @override
  List<RecipientView> crateApiRekeyNetRecipients({required List<int> recordPlain, required List<int> ownerPub}) => const [];

  @override
  dynamic noSuchMethod(Invocation i) => throw UnimplementedError('${i.memberName}');
}

/// One provd node under the BLE plugin: found by a scan, connects, and answers every frame written to RX with
/// [frame + 1] on TX. `written` = the first byte of every frame the app wrote.
class FakeNode extends ReactiveBlePlatform {
  final scans = StreamController<ScanResult>.broadcast(sync: true);
  final conns = StreamController<ConnectionStateUpdate>.broadcast(sync: true);
  final values = StreamController<CharacteristicValue>.broadcast(sync: true);
  final written = <int>[];
  CharacteristicInstance? tx;

  @override
  Future<void> initialize() async {}
  @override
  Stream<BleStatus> get bleStatusStream => const Stream.empty();
  @override
  Stream<ScanResult> get scanStream => scans.stream;
  @override
  Stream<ConnectionStateUpdate> get connectionUpdateStream => conns.stream;
  @override
  Stream<CharacteristicValue> get charValueUpdateStream => values.stream;

  @override
  Stream<void> scanForDevices({required List<Uuid> withServices, required ScanMode scanMode, required bool requireLocationServicesEnabled}) {
    Timer(const Duration(milliseconds: 10), () {
      scans.add(ScanResult(
          result: Result.success(
              DiscoveredDevice(id: 'AA', name: '', serviceData: const {}, manufacturerData: Uint8List(0), rssi: -40, serviceUuids: const []))));
    });
    return Stream.value(null);
  }

  @override
  Stream<void> connectToDevice(String id, Map<Uuid, List<Uuid>>? servicesWithCharacteristicsToDiscover, Duration? connectionTimeout) {
    Timer(const Duration(milliseconds: 10),
        () => conns.add(ConnectionStateUpdate(deviceId: id, connectionState: DeviceConnectionState.connected, failure: null)));
    return Stream.value(null);
  }

  @override
  Future<void> disconnectDevice(String deviceId) async {}
  @override
  Future<int> requestMtuSize(String deviceId, int? mtu) async => 517;
  @override
  Future<List<DiscoveredService>> getDiscoverServices(String deviceId) async => [
        DiscoveredService(serviceId: service, serviceInstanceId: 's', characteristicIds: chars, characteristics: [
          for (final c in chars)
            DiscoveredCharacteristic(
                characteristicId: c,
                characteristicInstanceId: '$c',
                serviceId: service,
                isReadable: true,
                isWritableWithResponse: true,
                isWritableWithoutResponse: true,
                isNotifiable: true,
                isIndicatable: false)
        ])
      ];
  @override
  Future<List<DiscoveredService>> discoverServices(String deviceId) => getDiscoverServices(deviceId);

  @override
  Stream<void> readCharacteristic(CharacteristicInstance characteristic) {
    Timer(const Duration(milliseconds: 10), () => values.add(CharacteristicValue(characteristic: characteristic, result: const Result.success([0]))));
    return Stream.value(null);
  }

  @override
  Stream<void> subscribeToNotifications(CharacteristicInstance characteristic) {
    tx = characteristic;
    return Stream.value(null);
  }

  @override
  Future<void> stopSubscribingToNotifications(CharacteristicInstance characteristic) async {}

  @override
  Future<WriteCharacteristicInfo> writeCharacteristicWithoutResponse(CharacteristicInstance characteristic, List<int> value) async {
    written.add(value[0]);
    Timer.run(() => values.add(CharacteristicValue(characteristic: tx!, result: Result.success([value[0] + 1]))));
    return WriteCharacteristicInfo(characteristic: characteristic, result: const Result.success(Unit()));
  }
}

void main() {
  final rust = FakeRust();
  final node = FakeNode();
  setUpAll(() {
    RustLib.initMock(api: rust);
    ReactiveBlePlatform.instance = node; // FlutterReactiveBle() takes it at its first use (not Android / iOS here)
  });

  /// let the real event loop and the fake clock run
  Future<void> settle(WidgetTester t, [int rounds = 25]) async {
    for (var i = 0; i < rounds; i++) {
      await t.runAsync(() => Future<void>.delayed(Duration.zero));
      await t.pump(const Duration(milliseconds: 200));
    }
  }

  /// a long stretch of the app's clock (10 minutes) after the 20 s of [settle]: a send put off by a timer (30 s,
  /// 5 min, ...) would show up here
  Future<void> longWait(WidgetTester t) async {
    await t.pump(const Duration(minutes: 10));
    await settle(t, 5);
  }

  Future<void> press(WidgetTester t, Finder f) async {
    await t.ensureVisible(f);
    await t.pump();
    await t.tap(f);
    await settle(t);
  }

  Future<void> open(WidgetTester t, {required Set<String> records, String clipboard = ''}) async {
    rust
      ..calls.clear()
      ..sends.clear()
      ..records.clear()
      ..records.addAll(records);
    node.written.clear();
    final m = t.binding.defaultBinaryMessenger;
    m.setMockMethodCallHandler(const MethodChannel('dev.batman/platform'), (c) async {
      switch (c.method) {
        case 'filesDir':
          return files;
        case 'blePermissions' || 'devTrust':
          return true;
        case 'publicKeys':
          return {'owner': Uint8List(65), 'ownerEnc': Uint8List(65), 'admin': Uint8List(65)};
        case 'signOwner' || 'signAdmin':
          return Uint8List(70);
        case 'seal':
          return Uint8List(3);
        case 'open':
          return Uint8List(4);
        case 'ecdh':
          return Uint8List(32);
      }
      return null;
    });
    m.setMockMethodCallHandler(SystemChannels.platform, (c) async => c.method == 'Clipboard.getData' ? {'text': clipboard} : null);
    await t.pumpWidget(const MaterialApp(home: NodesPage()));
    await settle(t, 5);
  }

  testWidgets('T30: an imported update is not sent to the node until the button is pressed', (t) async {
    await open(t, records: {'node/$deviceId', 'mnet/$netId'}, clipboard: 'a1');
    await press(t, find.byType(ListTile)); // log in to the node: a send would have a session to go out on
    expect(node.written, [fLogin], reason: 'the owner session is up');

    await press(t, find.byKey(const Key('paste:貼上更新包')));
    expect(rust.calls, ['cas mnet/$netId'], reason: 'the update was imported (mnet written)');
    await settle(t, 100); // 20 s of the app's clock: nothing is sent later either
    await longWait(t);
    expect(rust.sends, isEmpty, reason: 'T30: 0 network/update after the import');
    expect(node.written, [fLogin], reason: 'T30: no frame at all after the import');

    await press(t, find.widgetWithText(TextButton, sendLabel));
    expect(rust.sends, ['member'], reason: 'the button sends, from the mnet record');
    expect(node.written, [fLogin, fInfo, fSend]);
  });

  testWidgets('T30: the status page sends an imported update only when its button is pressed', (t) async {
    await open(t, records: {'node/$deviceId', 'mnet/$netId'}, clipboard: 'a1');
    await press(t, find.byType(ListTile));
    await press(t, find.byKey(const Key('paste:貼上更新包')));
    expect(rust.calls, ['cas mnet/$netId'], reason: 'the update was imported (mnet written)');

    await press(t, find.widgetWithText(TextButton, statusLabel));
    expect(find.byKey(const Key('sendUpdate')), findsOneWidget, reason: 'the status page is open, with its send button');
    await settle(t, 100);
    await longWait(t);
    expect(rust.sends, isEmpty, reason: 'T30: opening and showing the status page sends no network/update');
    expect(node.written, [fLogin, fStatus], reason: 'only the read of the page');

    await press(t, find.byKey(const Key('sendUpdate')));
    expect(rust.sends, ['member'], reason: 'the status page button sends, from the mnet record');
    expect(node.written, [fLogin, fStatus, fSend, fStatus], reason: 'the send, then the page is read again');
  });

  testWidgets('T19: after the removal committed nothing is sent to the node until the button is pressed', (t) async {
    await open(t, records: {'node/$deviceId', 'net/$netId'});
    await press(t, find.byKey(const Key('dev:成員名單／移除')));
    await press(t, find.byType(SimpleDialogOption)); // the one other person: remove
    // §2.4: the own node's info was read (a login and one info request) before the question
    expect(node.written, [fLogin, fInfo]);
    await press(t, find.byType(CheckboxListTile));
    await press(t, find.descendant(of: find.byType(AlertDialog), matching: find.byType(TextButton)).last);
    expect(rust.calls, ['remove b0b0 ticked=true reads=[1]', 'cas net/$netId'], reason: 'the removal committed (net written)');
    expect(find.byType(SimpleDialog), findsOneWidget, reason: 'the updates list (§3.3) follows the commit');
    await settle(t, 100);
    expect(rust.sends, isEmpty, reason: 'T19: 0 network/update after the commit');
    expect(node.written, [fLogin, fInfo], reason: 'T19: no frame at all after the commit');
    await longWait(t);
    expect(rust.sends, isEmpty, reason: 'T19: 0 network/update 10 minutes after the commit (the list still open)');
    expect(node.written, [fLogin, fInfo]);
    await press(t, find.byType(SimpleDialogOption).last); // close the list
    await settle(t, 100);
    await longWait(t);
    expect(rust.sends, isEmpty);
    expect(node.written, [fLogin, fInfo]);

    await press(t, find.widgetWithText(TextButton, sendLabel));
    await press(t, find.descendant(of: find.byType(AlertDialog), matching: find.byType(TextButton)).last); // the order reminder: send
    expect(rust.sends, ['admin'], reason: 'the button sends, from the net record');
    expect(node.written, [fLogin, fInfo, fInfo, fSend]);
  });
}
