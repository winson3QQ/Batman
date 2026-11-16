// #329 §9.1 for the new pages: T-N1 (「從這支手機移除這台節點」), T-H4 (an entry a key cannot serve is grey with its
// reason), T-U5 (a stored read time in the future says only 「之前讀過」).
import 'dart:io';

import 'package:batman_app/key_abilities.dart';
import 'package:batman_app/src/nodelink/app_link.dart';
import 'package:batman_app/src/nodelink/core.dart';
import 'package:batman_app/src/flows/net_index.dart';
import 'package:batman_app/src/rust/api/owner.dart' show MemberView, NetView, StatusView;
import 'package:batman_app/src/rust/frb_generated.dart';
import 'package:batman_app/ui/home_logic.dart';
import 'package:batman_app/ui/home_page.dart';
import 'package:batman_app/ui/intro_pages.dart';
import 'package:batman_app/ui/node_page.dart';
import 'package:batman_app/ui/settings_page.dart';
import 'package:batman_app/ui/theme.dart';
import 'package:batman_app/ui/widgets.dart' show Btn, StatusHero;
import 'package:batman_app/ui/ui_state.dart';
import 'package:flutter/material.dart' hide Page;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../nodelink/app_link_test.dart' show StatusBle;
import 'ui_state_test.dart' show MemStore;

const id = '0000000000000c4f2a7d2c';

class FakeRust implements RustLibApi {
  final calls = <String>[];
  bool copyOk = true;
  @override
  Future<bool> crateApiClaimStoreKeepCopy({required String dir, required String rel}) async {
    calls.add('copy $rel');
    return copyOk;
  }

  @override
  Future<void> crateApiClaimStoreRemove({required String dir, required String rel}) async => calls.add('remove $rel');
  @override
  Future<List<String>> crateApiOwnerListNodes({required String dir}) async => const [];
  List<String> nets = [], mnets = [], pends = [];
  Future<void>? netsGate; // not done = the records are still being looked at
  @override
  Future<List<String>> crateApiOwnerListNets({required String dir}) async {
    await netsGate;
    return nets;
  }
  @override
  Future<List<String>> crateApiMemberListMnets({required String dir}) async => mnets;
  @override
  Future<List<String>> crateApiMemberListPends({required String dir}) async => pends;
  @override
  Future<List<String>> crateApiOwnerListPending({required String dir}) async => const [];
  @override
  dynamic noSuchMethod(Invocation i) => throw UnimplementedError('${i.memberName}');
}

StatusView sv(String color, {int nodeState = 2}) => StatusView(
    color: color,
    row: '3',
    sentence: 'x',
    lagNote: '',
    warning: '',
    nodeState: nodeState,
    netId: '',
    version: '',
    tech: const [],
    fresh: true,
    rateNote: '',
    unfinished: '',
    unfinishedUnderVerdict: false,
    canLeave: false);

KeyAbilities keys({bool claim = true}) => KeyAbilities.from({
      'RECORD_AES': 1,
      'OWNER_SIGN': 1,
      'ADMIN_SIGN': 1,
      'OWNER_ENC': claim ? 1 : 0,
      'appUsable': true,
      'claim': claim,
      'login': true,
      'recover': claim,
      'makeNetwork': true,
      'softOwnerEnc': false,
    });

AppLink app({String filesDir = '/x'}) {
  AppLink.forgetForTest();
  final a = AppLink.create(platform: const MethodChannel('dev.batman/platform'), filesDir: filesDir, ble: StatusBle());
  a.link.core.setRecords(const [Rec(id, 1)]);
  return a;
}

/// #329 PR 3 §2.6: a records folder holding these network record files (NetIndex lists the folders itself).
String recordsDir({List<String> nets = const [], List<String> mnets = const [], List<String> pends = const []}) {
  final d = Directory.systemTemp.createTempSync('bm-recs');
  for (final (kind, names) in [('net', nets), ('mnet', mnets), ('mpend', pends)]) {
    for (final n in names) {
      File('${d.path}/records/$kind/$n').createSync(recursive: true);
    }
  }
  return d.path;
}

Widget host(Widget w) => MaterialApp(theme: batThemeData(Brightness.light), home: w);

void main() {
  final rust = FakeRust();
  setUpAll(() => RustLib.initMock(api: rust));
  setUp(() => rust
    ..calls.clear()
    ..copyOk = true);

  group('T-N1 remove from this phone', () {
    Future<(AppLink, UiState, MemStore)> open(WidgetTester t) async {
      final a = app();
      final store = MemStore()..ids = [id];
      final ui = UiState(store);
      await t.runAsync(ui.load);
      await t.runAsync(() => ui.noteReads({id: ('ok', DateTime.utc(2026))}));
      await t.pumpWidget(host(NodePage(app: a, id: id, ui: ui)));
      // #329 PR 4 §2.6: the removal moved into 更多 (the same code)
      await t.tap(find.byKey(const Key('node-more')));
      await t.pumpAndSettle();
      await t.tap(find.text('從這支手機移除這台節點'));
      await t.pumpAndSettle();
      return (a, ui, store);
    }

    testWidgets('confirmed: a copy, then the record goes, UiState forgets it, no Bluetooth', (t) async {
      final (a, ui, _) = await open(t);
      await t.tap(find.widgetWithText(FilledButton, '移除'));
      await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
      await t.pumpAndSettle();
      expect(rust.calls, ['copy node/$id', 'remove node/$id']);
      expect(ui.nodes.containsKey(id), isFalse);
      expect((a.gate.links, a.gate.scans), (0, 0));
      expect(a.reg.current, isNull, reason: 'the lease is released');
      a.link.dispose();
      await t.pumpWidget(const SizedBox());
      AppLink.forgetForTest();
    });

    testWidgets('cancelled: nothing changes', (t) async {
      final (_, ui, _) = await open(t);
      await t.tap(find.text('取消'));
      await t.pumpAndSettle();
      expect(rust.calls, isEmpty);
      expect(ui.nodes.containsKey(id), isTrue);
      AppLink.forgetForTest();
    });

    testWidgets('no copy could be kept: nothing is deleted, the user is told', (t) async {
      rust.copyOk = false;
      final (_, ui, _) = await open(t);
      await t.tap(find.widgetWithText(FilledButton, '移除'));
      await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
      await t.pumpAndSettle();
      expect(rust.calls, ['copy node/$id']);
      expect(ui.nodes.containsKey(id), isTrue);
      expect(find.textContaining('沒有移除'), findsOneWidget);
      AppLink.instance!.link.dispose();
      await t.pumpWidget(const SizedBox());
      AppLink.forgetForTest();
    });
  });

  // PR 2 review r2 C-M1: row 6's button comes from the phone's network records, read by the real home page.
  // Negative controls: records always none, or always net -> FAIL.
  for (final (nets, mnets, pends, button, second) in [
    (['n'], <String>[], <String>[], '加入網路', null),
    (<String>[], ['m'], <String>[], '加入網路', null),
    (<String>[], <String>[], ['p'], '看我的申請', null),
    (<String>[], <String>[], <String>[], '建立網路', '加入隊長的網路'),
  ]) {
    testWidgets('r2 C-M1: row 6 with nets $nets mnets $mnets pends $pends -> $button', (t) async {
      final a = app(filesDir: recordsDir(nets: nets, mnets: mnets, pends: pends));
      await t.runAsync(a.nets.recompute); // as main does once the startup check passed
      a.link.core.states[id]!
        ..kind = Kind.read
        ..view = 'red'
        ..readAt = a.link.now()
        ..extra = sv('red', nodeState: 1)
        ..last = Concl.read;
      await t.pumpWidget(host(HomePage(app: a, ui: UiState(MemStore()), devTrust: false, keys: keys())));
      await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await t.pump();
      expect(find.widgetWithText(FilledButton, button), findsOneWidget);
      expect(find.text('加入隊長的網路'), second == null ? findsNothing : findsOneWidget);
      await t.pumpWidget(const SizedBox());
      AppLink.forgetForTest();
    });
  }

  testWidgets('r2 C-m2: row 1 opens the Bluetooth settings; 設定 counts as Page.other; only fresh reads are remembered',
      (t) async {
    final calls = <String>[];
    t.binding.defaultBinaryMessenger.setMockMethodCallHandler(const MethodChannel('dev.batman/platform'), (c) async {
      calls.add(c.method);
      return true;
    });
    final a = app();
    final ui = UiState(MemStore()..ids = [id]);
    a.link.radio(bluetooth: false);
    a.link.core.states[id]!
      ..kind = Kind.read
      ..view = 'green'
      ..readAt = a.link.now() - 400000 // read, but not fresh
      ..last = Concl.read;
    a.link.readWall[id] = DateTime.utc(2026);
    await t.pumpWidget(host(HomePage(app: a, ui: ui, devTrust: true, keys: keys())));
    await t.pump();
    await t.tap(find.widgetWithText(FilledButton, '開啟藍牙設定'));
    await t.pump();
    expect(calls, contains('bluetoothSettings'));
    a.link.radio(bluetooth: true); // a change: the page remembers fresh reads only
    await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
    expect(ui.nodes, isEmpty, reason: 'a stale read is not remembered');
    await t.tap(find.byTooltip('設定'));
    await t.pumpAndSettle();
    expect(a.link.core.page, Page.other);
    a.link.dispose();
    await t.pumpWidget(const SizedBox());
    AppLink.forgetForTest();
  });

  testWidgets('r2 C-m6: with keys that cannot claim, no way to 新增節點 opens the claim page', (t) async {
    final a = app();
    a.link.core.setRecords(const []);
    final k = keys(claim: false);
    await t.pumpWidget(host(HomePage(app: a, ui: UiState(MemStore()), devTrust: false, keys: k)));
    await t.pump();
    await t.tap(find.widgetWithText(FilledButton, '新增節點'));
    await t.pump();
    expect(find.text('認領節點'), findsNothing);
    expect(find.text(k.refusal(KeyUse.claim)!), findsWidgets);
    await t.pumpWidget(const SizedBox());
    AppLink.forgetForTest();
  });

  testWidgets('r2 C-m4 / T-U6(b): node-provided text never reaches ui/state-v1', (t) async {
    final a = app();
    const marker = 'MARKER-7Q';
    final store = MemStore()..ids = [id];
    final ui = UiState(store);
    a.link.core.states[id]!
      ..kind = Kind.read
      ..view = 'green'
      ..readAt = a.link.now()
      ..extra = StatusView(
          color: 'green', row: '3', sentence: marker, lagNote: marker, warning: '', nodeState: 2, netId: marker,
          version: marker, tech: const [marker], fresh: true, rateNote: '', unfinished: '', unfinishedUnderVerdict: false,
          canLeave: false)
      ..last = Concl.read;
    a.link.readWall[id] = DateTime.utc(2026);
    await t.pumpWidget(host(HomePage(app: a, ui: ui, devTrust: false, keys: keys())));
    a.link.refresh();
    await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
    await t.runAsync(ui.background);
    expect(store.plain, isNotNull, reason: 'something was written');
    expect(String.fromCharCodes(store.plain!).contains(marker), isFalse);
    a.link.dispose();
    await t.pumpWidget(const SizedBox());
    AppLink.forgetForTest();
  });

  testWidgets('r2 D-m4: 開發者選項 only in a dev build', (t) async {
    for (final dev in [false, true]) {
      await t.pumpWidget(host(SettingsPage(app: app(), ui: UiState(MemStore()), devTrust: dev)));
      await t.pump();
      expect(find.text('開發者選項'), dev ? findsOneWidget : findsNothing);
      expect(find.text('舊版控制台'), dev ? findsOneWidget : findsNothing);
    }
    await t.pumpWidget(const SizedBox());
    AppLink.forgetForTest();
  });

  testWidgets('T-H4: 新增節點 is grey with the key\'s own reason when the keys cannot claim', (t) async {
    final ui = UiState(MemStore());
    final k = keys(claim: false);
    await t.pumpWidget(host(HomePage(app: app(), ui: ui, devTrust: false, keys: k)));
    await t.pump();
    expect(find.text(k.refusal(KeyUse.claim)!), findsOneWidget);
    await t.tap(find.text('新增節點').last);
    await t.pump();
    expect(find.text('認領節點'), findsNothing, reason: 'the older claim page does not open');
    await t.pumpWidget(const SizedBox());
    await t.pumpWidget(host(HomePage(app: app(), ui: ui, devTrust: false, keys: keys())));
    await t.pump();
    expect(find.text('把另一台節點加入這支手機'), findsOneWidget, reason: 'allowed: the plain line');
    await t.pumpWidget(const SizedBox());
    AppLink.forgetForTest();
  });

  testWidgets('review A-M3: the node page gives each reason its own next step', (t) async {
    final a = app();
    final s = a.link.core.states[id]!
      ..kind = Kind.unreachable
      ..why = Why.identity;
    expect(s.why, Why.identity);
    await t.pumpWidget(host(NodePage(app: a, id: id, ui: UiState(MemStore()))));
    await t.pump();
    expect(find.textContaining('不要在它上面做任何設定'), findsOneWidget);
    expect(find.textContaining('會持續自動重試'), findsNothing);
    await t.pumpWidget(const SizedBox());
    AppLink.forgetForTest();
  });

  testWidgets('review A-m1: a node not in a network is remembered as warn (not 「當時有問題」)', (t) async {
    final a = app();
    final c = a.link.core;
    c.states[id]!
      ..kind = Kind.read
      ..view = 'red'
      ..readAt = a.link.now()
      ..extra = sv('red', nodeState: 1)
      ..last = Concl.read;
    a.link.readWall[id] = DateTime.utc(2026, 11, 16);
    final ui = UiState(MemStore()..ids = [id]);
    await t.pumpWidget(host(HomePage(app: a, ui: ui, devTrust: false, keys: keys())));
    a.link.refresh(); // a change: the home page remembers the fresh reads
    await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
    await t.pump();
    expect(ui.nodes[id]?.look, 'warn');
    a.link.dispose();
    await t.pumpWidget(const SizedBox());
    AppLink.forgetForTest();
  });

  test('T-U5: an earlier run\'s read time in the future says only 之前讀過', () {
    final s = NodeState();
    NodeInfo n(int at) => NodeInfo(
        id: id,
        name: '節點 7D2C',
        state: s,
        fresh: false,
        shownWhy: null,
        prev: UiNode(look: 'ok', readAt: at));
    final now = DateTime.now().toUtc().millisecondsSinceEpoch ~/ 1000;
    expect(nodeRowWords(n(now + 3600), firstRounds: false).$2, '之前讀過');
    expect(nodeRowWords(n(now - 60), firstRounds: false).$2, startsWith('上次讀取 '));
    expect(nodeRowWords(n(now - 60), firstRounds: false).$2, endsWith('，當時正常'));
    expect(nodeRowWords(n(now - 60), firstRounds: false).$1.name, 'unk', reason: 'T2: old data only in the unk style');
  });

  // ---- PR 2 review r3: the wiring of the pages (E-m9 / F-m4) ---------------------------------------------------------

  testWidgets('r3 E-m9: row 2 「允許藍牙權限」 asks Android; allowed -> the permission precondition holds', (t) async {
    t.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('dev.batman/platform'), (c) async => c.method == 'blePermissions' ? true : null);
    final a = app();
    a.link.radio(permission: false);
    final ui = UiState(MemStore()..ids = [id]);
    await t.pumpWidget(host(HomePage(app: a, ui: ui, devTrust: false, keys: keys())));
    await t.pump();
    expect(a.link.core.blocked, Why.noPermission);
    await t.tap(find.widgetWithText(FilledButton, Btn.allowBluetooth));
    await t.pumpAndSettle();
    await t.tap(find.widgetWithText(FilledButton, Btn.goOn));
    await t.pumpAndSettle();
    expect(a.link.core.blocked, isNot(Why.noPermission));
    expect(find.byType(PermissionsPage), findsNothing, reason: 'allowed: back on the home page');
    a.link.dispose();
    await t.pumpWidget(const SizedBox());
    AppLink.forgetForTest();
  });

  testWidgets('r3 E-m6: a permission request that fails is a refusal, the button works again', (t) async {
    await t.pumpWidget(host(PermissionsPage(ask: () async => throw PlatformException(code: 'x'))));
    await t.tap(find.widgetWithText(FilledButton, Btn.goOn));
    await t.pumpAndSettle();
    expect(find.text('藍牙權限沒有開'), findsOneWidget);
    expect(t.widget<FilledButton>(find.widgetWithText(FilledButton, Btn.goOn)).onPressed, isNotNull);
  });

  testWidgets('r3 E-m9: the intro pages — 跳過說明 and 開始 both end them; back goes one page back', (t) async {
    var done = 0;
    await t.pumpWidget(host(IntroPages(onDone: () => done++)));
    await t.tap(find.text(Btn.skipIntro));
    expect(done, 1);
    await t.tap(find.text(Btn.next));
    await t.pumpAndSettle();
    await t.tap(find.text(Btn.next));
    await t.pumpAndSettle();
    expect(find.text(Btn.skipIntro), findsNothing, reason: 'the last page has only 開始');
    await t.tap(find.text(Btn.start));
    expect(done, 2);
  });

  testWidgets('r3 E-m9: a node row opens the node page (Page.node); back -> Page.home', (t) async {
    final a = app();
    a.link.core.states[id]!
      ..kind = Kind.read
      ..view = 'green'
      ..readAt = a.link.now()
      ..extra = sv('green')
      ..last = Concl.read;
    a.link.readWall[id] = DateTime.utc(2026, 11, 16);
    final ui = UiState(MemStore()..ids = [id]);
    await t.pumpWidget(host(HomePage(app: a, ui: ui, devTrust: false, keys: keys())));
    await t.pump();
    await t.tap(find.text('節點 7D2C').last);
    await t.pumpAndSettle();
    expect((a.link.core.page, find.byType(NodePage).evaluate().length), (Page.node, 1));
    await t.pageBack();
    await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
    await t.pumpAndSettle();
    expect(a.link.core.page, Page.home);
    a.link.dispose();
    await t.pumpWidget(const SizedBox());
    AppLink.forgetForTest();
  });

  testWidgets('r3 E-m9: going to the background writes a newer read time once', (t) async {
    final store = MemStore()..ids = [id];
    final ui = UiState(store);
    await t.runAsync(ui.load);
    await t.runAsync(() => ui.noteReads({id: ('ok', DateTime.utc(2026, 1, 1))}));
    await t.runAsync(() => ui.noteReads({id: ('ok', DateTime.utc(2026, 1, 2))})); // same kind: kept in memory only
    final a = app();
    await t.pumpWidget(host(HomePage(app: a, ui: ui, devTrust: false, keys: keys())));
    expect(store.writes, 1);
    t.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    t.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
    expect(store.writes, 2);
    t.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
    expect(store.writes, 2, reason: 'nothing newer since');
    t.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    a.link.dispose();
    await t.pumpWidget(const SizedBox());
    AppLink.forgetForTest();
  });

  testWidgets('r3 F-m4: what the startup check said is on the settings page', (t) async {
    final a = app();
    await t.pumpWidget(host(SettingsPage(app: a, ui: UiState(MemStore()), devTrust: false, notes: const ['注意：只有軟體保護'])));
    expect(find.text('啟動時的提醒'), findsOneWidget);
    expect(find.text('注意：只有軟體保護'), findsOneWidget);
    await t.pumpWidget(host(SettingsPage(app: a, ui: UiState(MemStore()), devTrust: false)));
    expect(find.text('啟動時的提醒'), findsNothing);
    a.link.dispose();
    AppLink.forgetForTest();
  });

  testWidgets('#329 PR 3 §2.6: a node of this phone that did not finish joining is a todo on the home page', (t) async {
    final a = app();
    const n = NetView(netId: 'q', meshId: 'bm-q', netName: '小隊', applied: true, country: 'US', members: []);
    const m = MemberView(
        name: 'node-0002', last4: '0002', deviceId: id, joining: true, prevCountry: '', dacHash: '', creator: false, approved: false);
    a.nets.setForTest(const NetSnapshot(netFiles: 1, nets: [NetEntry('q', n)], todos: [JoinTodo(NetEntry('q', n), m)]));
    await t.pumpWidget(host(HomePage(app: a, ui: UiState(MemStore()..ids = [id]), devTrust: false, keys: keys())));
    await t.pump();
    expect(find.text('節點加入網路沒有做完'), findsOneWidget);
    expect(find.textContaining('加入「小隊」還沒有完成'), findsOneWidget);
    a.nets.setForTest(const NetSnapshot());
    await t.pump();
    expect(find.text('節點加入網路沒有做完'), findsNothing, reason: 'the banner follows NetIndex');
    a.link.dispose();
    await t.pumpWidget(const SizedBox());
    AppLink.forgetForTest();
  });

  testWidgets('r3 E-m3: before the network records were looked at, row 6 offers the neutral 加入網路, never 建立網路',
      (t) async {
    final a = app(filesDir: recordsDir()); // NetIndex not computed yet: computing
    a.link.core.states[id]!
      ..kind = Kind.read
      ..view = 'red'
      ..readAt = a.link.now()
      ..extra = sv('red', nodeState: 1)
      ..last = Concl.read;
    a.link.readWall[id] = DateTime.utc(2026, 11, 16);
    await t.pumpWidget(host(HomePage(app: a, ui: UiState(MemStore()..ids = [id]), devTrust: false, keys: keys())));
    await t.pump();
    expect(find.widgetWithText(FilledButton, Btn.joinNetwork), findsOneWidget);
    expect(find.text(Btn.makeNetwork), findsNothing);
    await t.runAsync(a.nets.recompute);
    await t.pump();
    expect(find.text(Btn.makeNetwork), findsOneWidget, reason: 'looked at: no record -> 建立網路');
    a.link.dispose();
    await t.pumpWidget(const SizedBox());
    AppLink.forgetForTest();
  });

  // ---- PR 2 review r3 E-MINOR-1 / -3 / -6, F-MINOR-2: more wiring --------------------------------------------------

  void readNode(AppLink a, String n, {required bool fresh, String color = 'green', int nodeState = 2}) {
    a.link.core.states[n]!
      ..kind = Kind.read
      ..view = color
      ..readAt = fresh ? a.link.now() : a.link.now() - 400000
      ..extra = sv(color, nodeState: nodeState)
      ..last = Concl.read;
    a.link.readWall[n] = DateTime.utc(2026, 11, 16, 1, 2, 3);
  }

  Finder heroTime() => find.descendant(of: find.byType(StatusHero), matching: find.textContaining('讀取於'));

  testWidgets('r3 E-m3 / C-m8: the status area time is a fresh read\'s only', (t) async {
    const other = '00000000000000aaaa';
    final a = app();
    a.link.core.setRecords(const [Rec(id, 1), Rec(other, 1)]);
    final ui = UiState(MemStore()..ids = [id, other]);
    readNode(a, id, fresh: true);
    readNode(a, other, fresh: true);
    await t.pumpWidget(host(HomePage(app: a, ui: ui, devTrust: false, keys: keys())));
    await t.pump();
    expect(heroTime(), findsOneWidget, reason: 'all fresh and green: 讀取於 (the control)');
    readNode(a, id, fresh: false);
    readNode(a, other, fresh: false);
    a.link.refresh();
    await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
    await t.pump();
    expect(heroTime(), findsNothing, reason: 'row 10, every read old: no 讀取於');
    a.link.core.states[other]!
      ..kind = Kind.unreachable
      ..why = Why.notFound
      ..last = Concl.notFound;
    readNode(a, id, fresh: true);
    a.link.refresh();
    await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
    await t.pump();
    expect(heroTime(), findsNothing, reason: 'row 8 is about the unreachable node: not the other one\'s fresh time');
    a.link.dispose();
    await t.pumpWidget(const SizedBox());
    AppLink.forgetForTest();
  });

  testWidgets('r3 E-MINOR-1 (F / V15): the first-use tip shows once at all-fine; 知道了 writes it', (t) async {
    final store = MemStore()..ids = [id];
    final ui = UiState(store);
    final a = app();
    readNode(a, id, fresh: true);
    await t.pumpWidget(host(HomePage(app: a, ui: ui, devTrust: false, keys: keys())));
    await t.pump();
    expect(find.text('第一次使用的提示'), findsOneWidget);
    await t.tap(find.text(Btn.gotIt));
    await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
    await t.pump();
    expect((ui.homeTip, find.text('第一次使用的提示').evaluate().length), (true, 0));
    final again = UiState(store);
    await t.runAsync(again.load);
    expect(again.homeTip, isTrue);
    a.link.dispose();
    await t.pumpWidget(const SizedBox());
    AppLink.forgetForTest();
  });

  testWidgets('r3 E-MINOR-3 (B): 開啟藍牙設定 that cannot open says where to go', (t) async {
    t.binding.defaultBinaryMessenger.setMockMethodCallHandler(const MethodChannel('dev.batman/platform'), (c) async => false);
    final a = app();
    a.link.radio(bluetooth: false);
    await t.pumpWidget(host(HomePage(app: a, ui: UiState(MemStore()..ids = [id]), devTrust: false, keys: keys())));
    await t.pump();
    await t.tap(find.widgetWithText(FilledButton, Btn.openBluetooth));
    await t.pump();
    expect(find.text('請到手機的設定打開藍牙'), findsOneWidget);
    a.link.dispose();
    await t.pumpWidget(const SizedBox());
    AppLink.forgetForTest();
  });

  for (final (answer, hint) in [(true, false), (false, true)]) {
    testWidgets('r3 E-MINOR-6 (L): refused, 開啟 app 設定 -> appSettings; cannot open ($answer) -> a hint $hint', (t) async {
      final calls = <String>[];
      t.binding.defaultBinaryMessenger.setMockMethodCallHandler(const MethodChannel('dev.batman/platform'), (c) async {
        calls.add(c.method);
        return answer;
      });
      await t.pumpWidget(host(PermissionsPage(ask: () async => false)));
      await t.tap(find.widgetWithText(FilledButton, Btn.goOn));
      await t.pumpAndSettle();
      await t.tap(find.text(Btn.openAppSettings));
      await t.pump();
      expect(calls, ['appSettings']);
      expect(find.textContaining('打不開設定頁'), hint ? findsOneWidget : findsNothing);
    });
  }
}
