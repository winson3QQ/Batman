// #329 補測 A（PR 2 F-MINOR-3，2026-11-17）: 「UiState 只流向顯示」的測試鎖 (design §4.6: no decision reads
// `ui/state-v1` — not which node is connected, not what may be done, not the keys).
// Differential, black-box: the same nodes, the same reads and the same records, shown once with an empty UiState and
// once with a UiState that differs in every node field (nicknames that sort the other way, the last kinds swapped and
// opposite to today's reads, a read time in the future and one long ago). What the user can do must be the same:
// the set of buttons and keyed rows (and whether each is on), the node each action is about, the nodes ticked and the
// nodes a run is started on. Only words may differ.
// The welcome / home-tip flags are the same on both sides: they decide which display page or card shows (§5.2), by
// design.
import 'package:batman_app/key_abilities.dart';
import 'package:batman_app/src/flows/net_index.dart';
import 'package:batman_app/src/flows/net_run.dart';
import 'package:batman_app/src/nodelink/app_link.dart';
import 'package:batman_app/src/nodelink/core.dart';
import 'package:batman_app/src/rust/api/owner.dart' show NetView, StatusView;
import 'package:batman_app/src/rust/frb_generated.dart';
import 'package:batman_app/swupdate.dart' show swChannel;
import 'package:batman_app/ui/home_page.dart';
import 'package:batman_app/ui/net_pages.dart';
import 'package:batman_app/ui/node_page.dart';
import 'package:batman_app/ui/ui_state.dart';
import 'package:batman_app/ui/widgets.dart' show Btn;
import 'package:flutter/material.dart' hide Page;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../flows/net_run_test.dart' show World, ans;
import '../nodelink/app_link_test.dart' show StatusBle;
import 'net_pages_test.dart' as npt show deps;
import 'pages_test.dart' show FakeRust, host;
import 'ui_state_test.dart' show MemStore;

const idA = '0000000000000c4f2a1111'; // 「節點 1111」 sorts first by default
const idB = '0000000000000c4f2a2222';

StatusView sv(String color, {int nodeState = 2, String warning = ''}) => StatusView(
    color: color,
    row: '3',
    sentence: color == 'green' ? '已連上隊伍網路' : '有狀況',
    lagNote: '',
    warning: warning, note: '',
    nodeState: nodeState,
    netId: '',
    version: 'v',
    tech: const [],
    fresh: true,
    rateNote: '',
    unfinished: '',
    unfinishedUnderVerdict: false,
    canLeave: false);

KeyAbilities keys() => KeyAbilities.from({
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
    });

/// Both nodes read now with [v].
AppLink two(StatusView v, {List<String> ids = const [idA, idB]}) {
  AppLink.forgetForTest();
  final a = AppLink.create(platform: const MethodChannel('dev.batman/platform'), filesDir: '/x', ble: StatusBle());
  a.link.core.setRecords([for (final i in ids) Rec(i, 1)]);
  for (final i in ids) {
    a.link.core.states[i]!
      ..kind = Kind.read
      ..view = v.color
      ..readAt = a.link.now()
      ..extra = v
      ..last = Concl.read;
    a.link.readWall[i] = DateTime(2026, 11, 17, 9, 30);
  }
  return a;
}

UiState plain() => UiState(MemStore()..ids = [idA, idB]);

/// Every node field different: nicknames sorting B before A, kinds opposite, one time in the future, one long ago.
UiState full() {
  final u = UiState(MemStore()..ids = [idA, idB]);
  u.nodes[idA] = const UiNode(nick: 'B 隊', look: 'bad', readAt: 4102444000);
  u.nodes[idB] = const UiNode(nick: 'A 隊', look: 'ok', readAt: 1000);
  return u;
}

/// What the user can do on screen: each button (its words, on or off), each icon button, each keyed widget.
List<String> actions(WidgetTester t) {
  String words(Widget w) => [
        for (final e in find.descendant(of: find.byWidget(w), matching: find.byType(Text)).evaluate())
          (e.widget as Text).data ?? (e.widget as Text).textSpan?.toPlainText() ?? ''
      ].join('|');
  return [
    for (final b in t.widgetList<ButtonStyleButton>(find.bySubtype<ButtonStyleButton>())) 'button ${words(b)}:${b.onPressed != null}',
    for (final b in t.widgetList<IconButton>(find.byType(IconButton))) 'icon ${b.tooltip}:${b.onPressed != null}',
    for (final e in find.byWidgetPredicate((w) => w.key is ValueKey<String>).evaluate())
      'key ${(e.widget.key! as ValueKey<String>).value}',
  ]..sort();
}

void main() {
  setUpAll(() => RustLib.initMock(api: FakeRust()));
  setUp(() => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(swChannel, (c) async => null));

  Future<void> settle(WidgetTester t) async {
    for (var i = 0; i < 4; i++) {
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

  Future<void> tall(WidgetTester t) async {
    t.view.physicalSize = const Size(1080, 5000);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
  }

  testWidgets('retest-p UiState lock: home — the same actions and the same node behind 看這台節點, whatever UiState holds',
      (t) async {
    await tall(t);
    Future<(List<String>, String)> run(UiState ui) async {
      final a = two(sv('yellow', warning: '電量低'));
      await t.pumpWidget(host(HomePage(app: a, ui: ui, devTrust: true, keys: keys())));
      await settle(t);
      final acts = actions(t);
      await t.tap(find.widgetWithText(FilledButton, Btn.seeNode));
      await settle(t);
      final target = t.widget<NodePage>(find.byType(NodePage)).id;
      await finish(t, a);
      return (acts, target);
    }

    final (actsA, targetA) = await run(plain());
    final (actsB, targetB) = await run(full());
    expect(targetA, idA, reason: 'row 12: the first of the two (by device id)');
    expect(targetB, targetA, reason: 'UiState never decides which node the action is about');
    expect(actsB, actsA, reason: 'UiState never decides what can be done');
  });

  testWidgets('retest-p UiState lock: node page — the same groups and rows, whatever UiState holds', (t) async {
    await tall(t);
    Future<List<String>> run(UiState ui) async {
      final a = two(sv('red', nodeState: 1));
      a.devTrust = true;
      a.nets.setForTest(const NetSnapshot(netFiles: 1, nets: [
        NetEntry('n1', NetView(netId: 'n1', meshId: 'bm', netName: 'n', applied: true, country: 'US', members: [])),
      ]));
      await t.pumpWidget(host(NodePage(app: a, id: idA, ui: ui)));
      await settle(t);
      final acts = actions(t);
      await finish(t, a);
      return acts;
    }

    final actsA = await run(plain());
    final actsB = await run(full());
    expect(actsA, contains('key node-join'), reason: 'not in a network, the phone has one: 加入網路');
    expect(actsB, actsA);
  });

  testWidgets('retest-p UiState lock: 4.1 — the same nodes ticked and the same nodes started, whatever UiState holds',
      (t) async {
    await tall(t);
    Future<(Set<String>, Set<String>, List<String>)> run(UiState ui) async {
      final a = two(sv('red', nodeState: 1));
      a.nets.setForTest(const NetSnapshot());
      final w = World()..script('make', [ans('[NET_MADE] 網路已建立', rel: 'net/n1')]);
      String idOf(String title) => [idA, idB].firstWhere((i) => nodeName(a, i, ui) == title);
      await t.pumpWidget(host(Builder(
          builder: (c) => Scaffold(
              body: TextButton(
                  onPressed: () => Navigator.of(c).push(MaterialPageRoute(
                      builder: (_) => NetFormPage(
                            app: a,
                            ui: ui,
                            makes: true,
                            compute: () async => const NetSnapshot(),
                            runFlow: (l, go, _, _, _) =>
                                NetRun(npt.deps(w, l), ids: const [idA, idB], makes: true, askGoOn: go),
                          ))),
                  child: const Text('open'))))));
      await t.tap(find.text('open'));
      await settle(t);
      final ticked = {
        for (final c in t.widgetList<CheckboxListTile>(find.byType(CheckboxListTile)))
          if (c.value == true) idOf((c.title! as Text).data!)
      };
      final acts = actions(t);
      await t.tap(find.widgetWithText(FilledButton, Btn.start));
      await settle(t);
      final started = t.widget<NetRunPage>(find.byType(NetRunPage)).ids.toSet();
      await finish(t, a);
      return (ticked, started, acts);
    }

    final (tickedA, startedA, actsA) = await run(plain());
    final (tickedB, startedB, actsB) = await run(full());
    expect(tickedA, {idA, idB}, reason: 'both read as not in a network: both ticked');
    expect(tickedB, tickedA, reason: 'UiState never decides which nodes are ticked');
    expect(startedB, startedA, reason: 'UiState never decides which nodes a run starts on');
    expect(actsB, actsA);
  });
}
