// #329 PR 7 (plan §2): the node page's status-area button (T6), 「看節點清單」 on home rows 7 / 8 (T7), the home page's
// first rounds per node (T8 (a)), the node page's 「網路：」 line (T9) and the claim-pending todo against the states of
// the moment (T11). Each test names its negative control (run for the PR by breaking the code; the FAIL lines are in
// the PR body).
import 'package:batman_app/src/flows/net_index.dart';
import 'package:batman_app/src/nodelink/app_link.dart';
import 'package:batman_app/src/nodelink/core.dart';
import 'package:batman_app/src/rust/api/owner.dart' show StatusView;
import 'package:batman_app/src/rust/api/rekey.dart' show UpdateHint;
import 'package:batman_app/src/rust/frb_generated.dart';
import 'package:batman_app/ui/home_logic.dart' show last4, whyNext;
import 'package:batman_app/ui/home_page.dart';
import 'package:batman_app/ui/intro_pages.dart' show PermissionsPage;
import 'package:batman_app/ui/node_page.dart';
import 'package:batman_app/ui/ui_state.dart';
import 'package:batman_app/ui/widgets.dart';
import 'package:flutter/material.dart' hide Page;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'pages_test.dart' show FakeRust, app, host, id, keys;
import 'ui_state_test.dart' show MemStore;

const other = '00000000000000000beef1';

class Pr7Rust extends FakeRust {
  List<String> pending = [];
  @override
  Future<List<String>> crateApiOwnerListPending({required String dir}) async => [...pending];

  /// statuspage.rs membership_line, as the node page calls it through owner.rs:444
  @override
  String crateApiOwnerStatusMembershipLine({required int nodeState, required String netId, String? name}) =>
      switch (nodeState) {
        2 => netId.isEmpty ? '網路：（讀不到名稱）' : (name != null ? '網路：$name（已是隊員）' : '網路：別支手機建立的網路'),
        1 => '已認領，還沒加入網路',
        _ => '',
      };
}

StatusView view(String color, {int nodeState = 2, String netId = 'ab12', String sentence = '已連上隊伍網路'}) => StatusView(
    color: color,
    row: '3',
    sentence: sentence,
    lagNote: '',
    warning: '',
    nodeState: nodeState,
    netId: netId,
    version: '',
    tech: const [],
    fresh: true,
    rateNote: '',
    unfinished: '',
    unfinishedUnderVerdict: false,
    canLeave: false);

void read(AppLink a, String node, StatusView v) {
  a.link.core.states[node]!
    ..kind = Kind.read
    ..view = v.color
    ..readAt = a.link.now()
    ..extra = v
    ..last = Concl.read;
  a.link.readWall[node] = DateTime(2026, 11, 18, 9, 30);
}

void main() {
  final rust = Pr7Rust();
  setUpAll(() => RustLib.initMock(api: rust));
  final platformCalls = <String>[];
  setUp(() {
    rust.pending = [];
    platformCalls.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('dev.batman/platform'), (c) async {
      platformCalls.add(c.method);
      return c.method == 'blePermissions' || c.method == 'bluetoothSettings' ? true : null;
    });
  });

  Future<void> settle(WidgetTester t) async {
    for (var i = 0; i < 4; i++) {
      await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 5)));
      await t.pump(const Duration(milliseconds: 300));
    }
  }

  Future<void> done(WidgetTester t, AppLink a) async {
    await t.pumpWidget(const SizedBox());
    await a.link.dispose();
    AppLink.forgetForTest();
  }

  int filled(WidgetTester t) => find.byType(FilledButton).evaluate().length;

  group('T6 the node page\'s status-area button (negative control: no `extra` -> FAIL)', () {
    testWidgets('Bluetooth off -> 「開啟藍牙設定」, the only primary button; its sentence points at it; it opens the settings',
        (t) async {
      final a = app();
      read(a, id, view('green'));
      a.link.radio(bluetooth: false);
      await t.pumpWidget(host(NodePage(app: a, id: id, ui: UiState(MemStore()))));
      await settle(t);
      expect(find.byKey(const Key('node-open-bt')), findsOneWidget);
      expect(find.text(Btn.openBluetooth), findsOneWidget);
      expect(filled(t), 1);
      expect(find.textContaining(whyNext(Why.bluetoothOff)), findsOneWidget);
      expect(whyNext(Why.bluetoothOff), contains('「${Btn.openBluetooth}」'));
      expect(find.text(Btn.makeNetwork), findsNothing, reason: 'never 建立網路 here (PR 3 D8)');
      await t.tap(find.byKey(const Key('node-open-bt')));
      await settle(t);
      expect(platformCalls, contains('bluetoothSettings'));
      await done(t, a);
    });

    testWidgets('no permission -> 「允許藍牙權限」 opens 2.2; granted -> NodeLink told at once, the button goes '
        '(negative control: no radio(permission: true) -> FAIL)', (t) async {
      final a = app();
      read(a, id, view('green'));
      a.link.radio(permission: false);
      await t.pumpWidget(host(NodePage(app: a, id: id, ui: UiState(MemStore()))));
      await settle(t);
      expect(find.byKey(const Key('node-allow-bt')), findsOneWidget);
      expect(find.textContaining(whyNext(Why.noPermission)), findsOneWidget);
      expect(whyNext(Why.noPermission), isNot(contains('首頁')));
      expect(whyNext(Why.noPermission), contains('「${Btn.allowBluetooth}」'));
      await t.tap(find.byKey(const Key('node-allow-bt')));
      await settle(t);
      expect(find.byType(PermissionsPage), findsOneWidget, reason: 'board 2.2, as the home page');
      await t.tap(find.text(Btn.goOn));
      await settle(t);
      expect(find.byType(PermissionsPage), findsNothing);
      expect(a.link.core.blocked, isNull, reason: 'the permission reached NodeLink');
      expect(find.byKey(const Key('node-allow-bt')), findsNothing);
      expect(find.textContaining('還沒有藍牙權限'), findsNothing);
      await done(t, a);
    });

    testWidgets('the new-key hint with its button and Bluetooth off -> the Bluetooth button is the only primary one',
        (t) async {
      final a = app()..devTrust = true;
      read(a, id, view('green'));
      a.link.hints[id] = const UpdateHint(line: '這台節點的網路密碼還是舊的', button: true);
      a.link.radio(bluetooth: false);
      await t.pumpWidget(host(NodePage(app: a, id: id, ui: UiState(MemStore()))));
      await settle(t);
      expect(find.byKey(const Key('node-hint')), findsOneWidget);
      expect(find.byKey(Key('send-key-$id')), findsOneWidget, reason: 'the hint keeps its button (greyed)');
      expect(filled(t), 1);
      expect(find.ancestor(of: find.text(Btn.openBluetooth), matching: find.byType(FilledButton)), findsOneWidget);
      expect(t.widget<BatButton>(find.byKey(Key('send-key-$id'))).onPressed, isNull);
      await done(t, a);
    });

    testWidgets('Bluetooth on, permission given -> no status-area button', (t) async {
      final a = app();
      read(a, id, view('green'));
      await t.pumpWidget(host(NodePage(app: a, id: id, ui: UiState(MemStore()))));
      await settle(t);
      expect(find.byKey(const Key('node-open-bt')), findsNothing);
      expect(find.byKey(const Key('node-allow-bt')), findsNothing);
      expect(filled(t), 0);
      await done(t, a);
    });
  });

  testWidgets('T7: rows 7 / 8 with several nodes -> 「看節點清單」 brings 「我的節點」 into view (negative control: no button '
      '-> FAIL)', (t) async {
    t.view.physicalSize = const Size(360, 640);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    final a = app();
    a.link.core.setRecords(const [Rec(id, 1), Rec(other, 2)]);
    read(a, id, view('red', sentence: '沒有連上隊伍網路'));
    read(a, other, view('red', sentence: '沒有連上隊伍網路'));
    for (var i = 0; i < 4; i++) {
      a.reg.unsavedTodos.add('上一個操作可能沒有存完：操作 $i'); // pushes the list below the screen
    }
    await t.pumpWidget(host(HomePage(app: a, ui: UiState(MemStore()), devTrust: false, keys: keys())));
    await settle(t);
    expect(find.text('有 2 台節點有問題'), findsOneWidget);
    expect(find.text(Btn.showList), findsOneWidget);
    bool listShown() {
      final f = find.text('我的節點', skipOffstage: false);
      if (f.evaluate().isEmpty) return false;
      final y = t.getTopLeft(f).dy;
      return y >= 0 && y < 640;
    }

    expect(listShown(), isFalse, reason: 'premise: the list starts below the screen');
    await t.tap(find.text(Btn.showList));
    await t.pumpAndSettle();
    expect(listShown(), isTrue);
    await done(t, a);
  });

  testWidgets('T8 (a) / F m-8: home is in its first rounds while any node is; each row uses its own node\'s rounds '
      '(negative control: `every` -> FAIL)', (t) async {
    final a = app();
    a.link.core.setRecords(const [Rec(id, 1), Rec(other, 2)]);
    for (final n in [id, other]) {
      a.link.core.states[n]!.last = Concl.notYet;
    }
    a.link.core.states[id]!.roundsEnded = 2;
    final ui = UiState(MemStore());
    await t.pumpWidget(host(HomePage(app: a, ui: ui, devTrust: false, keys: keys())));
    await settle(t);
    expect(t.widget<StatusHero>(find.byType(StatusHero)).text, '正在找你的節點…', reason: 'one node still in its first rounds');
    final rows = {for (final r in t.widgetList<NodeRow>(find.byType(NodeRow))) r.name: r.line};
    expect(rows['節點 ${last4(id)}'], '附近有還沒認出來的裝置，還在找');
    expect(rows['節點 ${last4(other)}'], '正在找節點…');
    a.link.core.states[other]!.roundsEnded = 2;
    await t.pump(const Duration(seconds: 15)); // the page's 15 s tick
    expect(t.widget<StatusHero>(find.byType(StatusHero)).text, isNot('正在找你的節點…'));
    await done(t, a);
  });

  group('T9 the node page\'s 「網路：」 line (PR 2 B-m12)', () {
    Future<AppLink> open(WidgetTester t, StatusView v, {bool stale = false}) async {
      final a = app();
      a.nets.setForTest(const NetSnapshot(anyMnet: true, mnetIds: ['ab12'], mnets: [MnetEntry('ab12', name: '山隊')]));
      read(a, id, v);
      a.link.core.states[id]!.stale = stale;
      await t.pumpWidget(host(NodePage(app: a, id: id, ui: UiState(MemStore()))));
      await settle(t);
      return a;
    }

    testWidgets('fresh, in a network -> the line with this phone\'s name for it', (t) async {
      final a = await open(t, view('green'));
      expect(find.byKey(const Key('node-membership')), findsOneWidget);
      expect(find.text('網路：山隊（已是隊員）'), findsOneWidget);
      await done(t, a);
    });

    testWidgets('not fresh -> no line (negative control: no freshness condition -> FAIL)', (t) async {
      final a = await open(t, view('green'), stale: true);
      expect(find.byKey(const Key('node-membership')), findsNothing);
      await done(t, a);
    });

    testWidgets('k1 = 1 (claimed, not in a network) -> no line (negative control: no k1 condition -> FAIL)', (t) async {
      final a = await open(t, view('yellow', nodeState: 1, netId: ''));
      expect(find.byKey(const Key('node-membership')), findsNothing);
      expect(find.text('已認領，還沒加入網路'), findsNothing);
      await done(t, a);
    });
  });

  testWidgets('T11: a claim-pending todo whose node record arrives after the list was read goes at the next build '
      '(negative control: the count fixed when the list was read -> FAIL)', (t) async {
    rust.pending = [other];
    final a = app(); // node/<id> only: `other` has no record yet
    await t.pumpWidget(host(HomePage(app: a, ui: UiState(MemStore()..ids = [id]), devTrust: true, keys: keys())));
    await settle(t);
    expect(find.text('上次新增節點沒有做完'), findsOneWidget);
    a.link.core.setRecords(const [Rec(id, 1), Rec(other, 2)]); // the states now hold it (no lease released: no new list)
    await t.pump(const Duration(seconds: 15));
    expect(find.text('上次新增節點沒有做完'), findsNothing);
    await done(t, a);
  });
}
