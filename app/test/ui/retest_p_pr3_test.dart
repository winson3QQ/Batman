// #329 補測 A（PR 3 小修正與第三輪 MINOR，2026-11-17）: the PR 3 fixes that had no failing test.
// - 結果頁重讀的 hold (net_pages.dart _NetRunPageState._check): while a result row is read again after 檢查網路, the
//   run page holds its lease (busy) and shows no 完成, so it cannot be left half-way.
// - 收起「放棄這次加入」 (net_pages.dart _forgotten): after a forget that went through, the button goes.
// - 「網路已經不在」一行 (net_pages.dart _start, code review A m-5): the member join's team network that no longer opens
//   under the lease -> not started, the lease released, the line shown. PR 3 called this unreachable after C N-3; the
//   PR 5 member mode reaches it (mnetIds are compared, not whether the mnet still opens).
// - `dc ??=` (net_pages.dart _ask): a question's dialog rebuilt during its exit never becomes the open one again, so a
//   lost link afterwards does not pop the run page itself.
// - `_appFlow` onLost (net_pages.dart _NetRunPageState._appFlow): the app's own flow (no test flow) hands the page's
//   dismiss to the console; the link lost while the country question is open closes it. Real AppLink, real NodeLink
//   login (fake BLE node, fake Rust session).
import 'dart:async';

import 'package:batman_app/src/flows/net_index.dart';
import 'package:batman_app/src/flows/net_run.dart';
import 'package:batman_app/src/flows/owner_console.dart';
import 'package:batman_app/src/nodelink/app_link.dart';
import 'package:batman_app/src/nodelink/core.dart' show Rec;
import 'package:batman_app/src/nodelink/lease.dart';
import 'package:batman_app/src/rust/api/owner.dart';
import 'package:batman_app/src/rust/frb_generated.dart';
import 'package:batman_app/swupdate.dart' show swChannel;
import 'package:batman_app/ui/join_choice.dart' show NetMode;
import 'package:batman_app/ui/net_pages.dart';
import 'package:batman_app/ui/theme.dart';
import 'package:batman_app/ui/ui_state.dart';
import 'package:batman_app/ui/widgets.dart' show Btn;
import 'package:flutter/material.dart' hide Page;
import 'package:flutter/services.dart';
import 'package:flutter_reactive_ble/flutter_reactive_ble.dart';
import 'package:flutter_test/flutter_test.dart';

import '../flows/net_run_test.dart' show World, ans, pend;
import '../support/fake_node.dart' show step;
import 'net_pages_test.dart' as npt show deps;
import 'pages_test.dart' show FakeRust, app, host, id;
import 'ui_state_test.dart' show MemStore;

const platform = MethodChannel('dev.batman/platform');

/// The joining member of net 'q' that is one of this phone's nodes (「節點加入網路沒有做完」).
const joining = MemberView(
    name: 'x', last4: '', deviceId: id, joining: true, prevCountry: '', dacHash: 'd4', creator: false, approved: false);
const qView = NetView(netId: 'q', meshId: 'bm-q', netName: 'Q', applied: true, country: 'US', members: [joining]);

/// The Rust calls these pages and the real login make (everything else: pages_test's FakeRust).
class P3Rust extends FakeRust {
  Completer<void>? readGate; // not done = storeReadSealed waits
  bool applied = true;
  final cas = <String>[];
  OwnerStep? forgetStep;
  P3Session session = P3Session();

  @override
  Future<SealedRecord?> crateApiOwnerStoreReadSealed({required String dir, required String rel}) async {
    final g = readGate;
    if (g != null) await g.future;
    return SealedRecord(generation: BigInt.from(7), sealed: Uint8List(3), aad: Uint8List(1));
  }

  @override
  NetView crateApiOwnerNetSummary({required List<int> recordPlain}) =>
      NetView(netId: 'n', meshId: 'bm', netName: 'n', applied: applied, country: 'US', members: const []);

  @override
  OwnerStep crateApiOwnerNetForgetJoining({required List<int> recordPlain, required BigInt recordGen, required String dacHash}) =>
      forgetStep ?? (throw '建立網路的節點不能忘記');

  @override
  Future<BigInt> crateApiOwnerStoreWriteCas(
      {required String dir, required String rel, required BigInt expectedGen, required List<int> sealed}) async {
    cas.add(rel);
    return expectedGen + BigInt.one;
  }

  // the real login (HandoffProber)
  @override
  Future<List<String>> crateApiOwnerListNodes({required String dir}) async => const [id];
  @override
  Future<int> crateApiClaimFrameLimit({required List<int> ctrl, required int mtu}) async => 244;
  @override
  (OwnerSession, OwnerStep) crateApiOwnerOwnerSessionStart(
          {required List<int> recordPlain, required List<int> ownerPub, required int frameLimit}) =>
      (session, step(OwnerKind.loggedIn, detail: '已登入'));
}

/// The node's session: a join first asks whether to change the node's country.
class P3Session implements OwnerSession {
  final calls = <String>[];
  @override
  OwnerStep requestJoinNetwork(
      {required List<int> recordPlain,
      required BigInt recordGen,
      required List<int> adminPub,
      required List<int> ownerEncPub,
      required bool removedConfirmed}) {
    calls.add('join');
    return step(OwnerKind.confirmCountry, detail: '[COUNTRY] 節點的國家是 US，要改成網路的 TW 嗎？');
  }

  @override
  OwnerStep? countryConfirmed({required bool yes}) {
    calls.add('country $yes');
    return step(OwnerKind.answer, detail: '[REQ_FAIL] 已取消');
  }

  @override
  void dispose() => calls.add('dispose');
  @override
  dynamic noSuchMethod(Invocation i) => throw UnimplementedError('${i.memberName}');
}

/// A BLE node that is always found, connects, and can drop its link.
class LoginBle implements FlutterReactiveBle {
  final statusCtl = StreamController<BleStatus>.broadcast(sync: true);
  StreamController<ConnectionStateUpdate>? conn;
  final tx = StreamController<List<int>>.broadcast();
  int connects = 0;

  void drop() => conn?.add(const ConnectionStateUpdate(
      deviceId: 'AA', connectionState: DeviceConnectionState.disconnected, failure: null));

  @override
  Stream<BleStatus> get statusStream => statusCtl.stream;
  @override
  Stream<ConnectionStateUpdate> get connectedDeviceStream => const Stream.empty();
  @override
  Stream<DiscoveredDevice> scanForDevices(
          {required List<Uuid> withServices, ScanMode scanMode = ScanMode.balanced, bool requireLocationServicesEnabled = true}) =>
      (StreamController<DiscoveredDevice>()
            ..add(DiscoveredDevice(
                id: 'AA', name: '', serviceData: const {}, manufacturerData: Uint8List(0), rssi: -40, serviceUuids: const [])))
          .stream;
  @override
  Stream<ConnectionStateUpdate> connectToDevice(
      {required String id, Map<Uuid, List<Uuid>>? servicesWithCharacteristicsToDiscover, Duration? connectionTimeout}) {
    connects++;
    final c = conn = StreamController<ConnectionStateUpdate>();
    c.add(ConnectionStateUpdate(deviceId: id, connectionState: DeviceConnectionState.connected, failure: null));
    return c.stream;
  }

  @override
  Future<int> requestMtu({required String deviceId, required int mtu}) async => 517;
  @override
  Future<List<int>> readCharacteristic(QualifiedCharacteristic c) async => [0];
  @override
  Stream<List<int>> subscribeToCharacteristic(QualifiedCharacteristic c) => tx.stream;
  @override
  Future<void> writeCharacteristicWithoutResponse(QualifiedCharacteristic c, {required List<int> value}) async {}
  @override
  dynamic noSuchMethod(Invocation i) => throw UnimplementedError('${i.memberName}');
}

/// A console whose join asks the country, then waits for [gate] (the run is still working).
class _AskThenWait implements OwnerConsole {
  _AskThenWait(this.country, this.gate);
  final AskUser country;
  final Completer<void> gate;
  @override
  bool get alive => true;
  @override
  Future<ConsoleReply> joinNetwork(String rel) async {
    await country('[COUNTRY] 要改成 US 嗎');
    await gate.future;
    return const ConsoleReply(ReplyKind.unclear, '[JOIN_STATE] 結果不明', sessionAlive: false);
  }

  @override
  Future<void> close() async {}
  @override
  dynamic noSuchMethod(Invocation i) => throw UnimplementedError('${i.memberName}');
}

Map<String, Object?> keyLevels() => {
      'RECORD_AES': 1,
      'OWNER_SIGN': 1,
      'ADMIN_SIGN': 1,
      'OWNER_ENC': 1,
      'appUsable': true,
      'claim': true,
      'login': true,
      'recover': true,
      'makeNetwork': true,
      'softOwnerEnc': false,
    };

void main() {
  final rust = P3Rust();
  setUpAll(() => RustLib.initMock(api: rust));
  setUp(() {
    rust
      ..readGate = null
      ..applied = true
      ..cas.clear()
      ..forgetStep = null
      ..session = P3Session();
    final m = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    m.setMockMethodCallHandler(swChannel, (c) async => null);
    m.setMockMethodCallHandler(platform, (c) async {
      switch (c.method) {
        case 'open':
          return Uint8List(4);
        case 'seal':
          return Uint8List(3);
        case 'publicKeys':
          return {'owner': Uint8List(65), 'ownerEnc': Uint8List(65), 'admin': Uint8List(65)};
        case 'keyLevels':
          return keyLevels();
      }
      return null;
    });
  });

  Future<void> settle(WidgetTester t, [int n = 6]) async {
    for (var i = 0; i < n; i++) {
      await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
      await t.pump(const Duration(milliseconds: 200));
    }
  }

  Future<void> finish(WidgetTester t, AppLink a) async {
    await t.pumpWidget(const SizedBox());
    await a.link.dispose();
    await t.pump(const Duration(seconds: 10));
    AppLink.forgetForTest();
  }

  testWidgets('retest-p PR3 結果頁重讀的 hold: while a row is read again after 檢查網路 the lease is busy and 完成 is not offered',
      (t) async {
    final a = app();
    final l = (await t.runAsync(() => a.link.acquire('建立網路', LeaseKind.session)))!;
    final w = World()
      ..appliedAfterMake = false
      ..dac[id] = 'd4'
      ..script('make', [ans('[NET_STATE] 結果不明', rel: 'net/n1')])
      ..script('confirm', [ans('[NET_STATE] 沒有套用')]);
    await t.pumpWidget(host(NetRunPage(
      app: a,
      ui: UiState(MemStore()..ids = [id]),
      lease: l,
      ids: const [id],
      makes: true,
      flow: (go, _, _, _) => NetRun(npt.deps(w, l), ids: const [id], makes: true, askGoOn: go),
      checkFlow: (lease, i) =>
          CheckRun(npt.deps(w, lease), id: i, snapshot: () async => NetSnapshot(netFiles: 1, nets: [pend('n1', 'd4')])),
    )));
    await settle(t);
    expect(find.widgetWithText(FilledButton, Btn.done), findsOneWidget, reason: 'the result stage');
    expect(l.busy, isFalse);
    await t.tap(find.widgetWithText(OutlinedButton, Btn.checkNetwork));
    await t.pumpAndSettle();
    final gate = rust.readGate = Completer<void>(); // the record read again waits
    await t.state<NavigatorState>(find.byType(Navigator)).maybePop(); // back from the check page, nothing checked
    await settle(t);
    expect(find.byType(CheckNetPage), findsNothing);
    expect(l.busy, isTrue, reason: 'the reread holds the lease (the other rows wait)');
    expect(find.widgetWithText(FilledButton, Btn.done), findsNothing, reason: 'working: no 完成 while the row is read again');
    gate.complete();
    await settle(t);
    expect(l.busy, isFalse, reason: 'given back after the read');
    expect(find.widgetWithText(FilledButton, Btn.done), findsOneWidget);
    expect(find.text('網路已建立'), findsWidgets, reason: 'the row read again (applied)');
    await finish(t, a);
  });

  testWidgets('retest-p PR3 收起「放棄這次加入」: after the forget went through, the button is gone', (t) async {
    t.view.physicalSize = const Size(1080, 4000);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    final a = app();
    const n = NetEntry('q', qView);
    const snap = NetSnapshot(netFiles: 1, nets: [n], todos: [JoinTodo(n, joining)]);
    a.nets.setForTest(snap);
    rust.forgetStep = step(OwnerKind.persistNet, rel: 'net/q', detail: '已放棄節點 …7d2c 這次的加入');
    await t.pumpWidget(host(Builder(
        builder: (c) => Scaffold(
            body: TextButton(
                onPressed: () => Navigator.of(c).push(MaterialPageRoute(
                    builder: (_) => NetFormPage(app: a, ui: UiState(MemStore()..ids = [id]), todo: snap.todos.first))),
                child: const Text('open'))))));
    await t.tap(find.text('open'));
    await settle(t);
    expect(find.widgetWithText(TextButton, Btn.forgetJoin), findsOneWidget);
    await t.tap(find.widgetWithText(TextButton, Btn.forgetJoin));
    await t.pumpAndSettle();
    await t.tap(find.widgetWithText(FilledButton, Btn.forgetJoin)); // the question's own button
    await settle(t);
    a.nets.setForTest(snap); // the release recomputes from real files: the form's records again
    await settle(t);
    expect(rust.cas, ['net/q'], reason: 'the forget was written through RecordWriter');
    expect(find.text('已放棄節點 …7d2c 這次的加入'), findsOneWidget);
    expect(find.widgetWithText(TextButton, Btn.forgetJoin), findsNothing, reason: 'done: the button goes (code review B m9)');
    expect(a.reg.current, isNull);
    await finish(t, a);
  });

  testWidgets('retest-p PR3 「網路已經不在」: the team network no longer opens under the lease -> not started, the line shown',
      (t) async {
    t.view.physicalSize = const Size(1080, 4000);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    final a = app();
    a.devTrust = true;
    const m1 = MnetEntry('m1', name: '山隊', entryLast4: '7D2C');
    const s = NetSnapshot(anyMnet: true, mnetIds: ['m1'], mnets: [m1]);
    // the same files (mnetIds): the form's key compares equal; the record no longer opens
    const under = NetSnapshot(anyMnet: true, mnetIds: ['m1'], mnets: [MnetEntry('m1', name: '山隊', opens: false)]);
    a.nets.setForTest(s);
    final w = World()..script('mjoin', [ans('[JOINED] 已套用')]);
    var runs = 0;
    await t.pumpWidget(host(Builder(
        builder: (c) => Scaffold(
            body: TextButton(
                onPressed: () => Navigator.of(c).push(MaterialPageRoute(
                    builder: (_) => NetFormPage(
                          app: a,
                          ui: UiState(MemStore()..ids = [id]),
                          mode: NetMode.member,
                          compute: () async => under,
                          runFlow: (l, go, _, _, _) {
                            runs++;
                            return NetRun(npt.deps(w, l, app: a), ids: const [id], makes: false, member: true, joinRel: 'mnet/m1', askGoOn: go);
                          },
                        ))),
                child: const Text('open'))))));
    await t.tap(find.text('open'));
    await settle(t);
    expect(find.byKey(const Key('member-entry')), findsOneWidget);
    await t.tap(find.widgetWithText(FilledButton, Btn.start));
    await settle(t);
    a.nets.setForTest(s); // the release recomputes from real files: the form's records again
    await settle(t);
    expect(find.byType(NetRunPage), findsNothing);
    expect(runs, 0, reason: 'no run');
    expect(find.text('要加入的網路已經不在這支手機上，請重新選。'), findsOneWidget);
    expect(a.reg.current, isNull, reason: 'the lease released');
    await finish(t, a);
  });

  testWidgets('retest-p PR3 dc ??=: a question rebuilt during its exit is not the open one; a lost link then pops nothing',
      (t) async {
    final a = app();
    final l = (await t.runAsync(() => a.link.acquire('加入網路', LeaseKind.session)))!;
    final w = World();
    final gate = Completer<void>();
    void Function()? lostNow;
    final dark = ValueNotifier(false);
    await t.pumpWidget(ValueListenableBuilder<bool>(
        valueListenable: dark,
        builder: (_, d, _) => MaterialApp(
              theme: batThemeData(d ? Brightness.dark : Brightness.light),
              home: Builder(
                  builder: (c) => Scaffold(
                      body: TextButton(
                          onPressed: () => Navigator.of(c).push(MaterialPageRoute(
                              builder: (_) => NetRunPage(
                                    app: a,
                                    ui: UiState(MemStore()..ids = [id]),
                                    lease: l,
                                    ids: const [id],
                                    makes: false,
                                    joinRel: 'net/a',
                                    flow: (go, country, _, lost) {
                                      lostNow = lost;
                                      final dd = w.deps;
                                      return NetRun(
                                          FlowDeps(
                                              login: dd.login,
                                              console: (h) => _AskThenWait(country, gate),
                                              applied: dd.applied,
                                              blocked: () => a.link.core.blocked,
                                              leaseValid: () => l.valid),
                                          ids: const [id],
                                          makes: false,
                                          joinRel: 'net/a',
                                          askGoOn: go);
                                    },
                                  ))),
                          child: const Text('open')))),
            )));
    await t.tap(find.text('open'));
    await settle(t);
    expect(find.text('要改這台節點的國家嗎？'), findsOneWidget);
    await t.tap(find.text('不要')); // answered: the dialog starts its exit
    await t.pump();
    dark.value = true; // the theme changes while it is still on screen: its builder runs again
    await t.pump();
    lostNow!(); // the console's link goes now
    await t.pump();
    await t.pump(const Duration(seconds: 1));
    await t.pump();
    expect(find.byType(NetRunPage), findsOneWidget, reason: 'the run page is never popped by a closed question');
    gate.complete();
    await settle(t);
    await finish(t, a);
  });

  testWidgets('retest-p PR3 _appFlow onLost: the app\'s own flow; the link lost while the country question is open closes it',
      (t) async {
    AppLink.forgetForTest();
    final ble = LoginBle();
    final a = AppLink.create(platform: platform, filesDir: '/x', ble: ble);
    a.link.core.setRecords(const [Rec(id, 1)]);
    final l = (await t.runAsync(() => a.link.acquire('加入網路', LeaseKind.session)))!;
    await t.pumpWidget(host(Builder(
        builder: (c) => Scaffold(
            body: TextButton(
                onPressed: () => Navigator.of(c).push(MaterialPageRoute(
                    builder: (_) => NetRunPage(
                        app: a, ui: UiState(MemStore()..ids = [id]), lease: l, ids: const [id], makes: false, joinRel: 'net/a'))),
                child: const Text('open'))))));
    await t.tap(find.text('open'));
    for (var i = 0; i < 30 && find.text('要改這台節點的國家嗎？').evaluate().isEmpty; i++) {
      await settle(t, 1);
    }
    expect(ble.connects, 1, reason: 'the real login connected');
    expect(rust.session.calls, ['join'], reason: 'the console the app built asked the join');
    expect(find.text('要改這台節點的國家嗎？'), findsOneWidget);
    ble.drop(); // the node's link goes while the question is open
    await settle(t);
    expect(find.text('要改這台節點的國家嗎？'), findsNothing, reason: 'closed by the console\'s onLost (the page\'s dismiss)');
    expect(rust.session.calls, isNot(contains('country true')), reason: 'never answered 改');
    await settle(t, 60); // the console's close (up to 10 s) and the run end
    await finish(t, a);
  });
}
