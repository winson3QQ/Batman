// #329 PR 3 §2.7 (design §5.3): 3.2 取名 (UiState.setNick), 3.5 / 3.6 (the next step follows NetIndex), the home
// page's F41 line, openRawPageFor's result, and the claim page's dev inputs only in a dev build.
import 'package:batman_app/claim.dart';
import 'package:batman_app/src/flows/net_index.dart';
import 'package:batman_app/src/nodelink/app_link.dart';
import 'package:batman_app/src/nodelink/ble_gate.dart';
import 'package:batman_app/src/nodelink/core.dart';
import 'package:batman_app/src/nodelink/lease.dart';
import 'package:batman_app/src/nodelink/node_link.dart';
import 'package:batman_app/src/nodelink/raw_use.dart';
import 'package:batman_app/src/rust/frb_generated.dart';
import 'package:batman_app/ui/add_pages.dart';
import 'package:batman_app/ui/home_page.dart';
import 'package:batman_app/ui/net_pages.dart' show NetFormPage;
import 'package:batman_app/ui/ui_state.dart';
import 'package:batman_app/ui/widgets.dart' show Btn;
import 'package:flutter/material.dart' hide Page;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../nodelink/node_link_test.dart' as nlt show Clock, Radio, FakeProber;
import 'pages_test.dart' show FakeRust, app, host, id, keys;
import 'ui_state_test.dart' show MemStore;

void main() {
  final rust = FakeRust();
  setUpAll(() => RustLib.initMock(api: rust));

  Future<void> finish(WidgetTester t, AppLink a) async {
    await t.pumpWidget(const SizedBox());
    await a.link.dispose();
    await t.pump(const Duration(seconds: 10));
    AppLink.forgetForTest();
  }

  group('UiState.setNick (3.2)', () {
    test('trimmed and saved; 1-24 characters; control / format / separator characters refused, not stripped', () async {
      final ui = UiState(MemStore()..ids = [id]);
      await ui.load();
      expect(await ui.setNick(id, '  前門  '), isNull);
      expect(ui.nodes[id]!.nick, '前門');
      expect(await ui.setNick(id, '   '), isNotNull);
      expect(await ui.setNick(id, 'x' * 25), isNotNull);
      expect(await ui.setNick(id, '一' * 24), isNull, reason: '24 characters (not bytes)');
      for (final bad in ['a\u0007b', 'a​b', 'a b', 'a b']) {
        expect(await ui.setNick(id, bad), isNotNull, reason: 'U+${bad.runes.elementAt(1).toRadixString(16)}');
      }
      expect(ui.nodes[id]!.nick, '一' * 24, reason: 'a refused name changes nothing');
    });
  });

  group('3.5 / 3.6 (design §5.3)', () {
    Future<AppLink> added(WidgetTester t, NetSnapshot s, {int nodes = 1}) async {
      final a = app();
      a.link.core.setRecords([for (var i = 0; i < nodes; i++) Rec(i == 0 ? id : 'other$i', 1)]);
      a.nets.setForTest(s);
      await t.pumpWidget(host(AddedPage(app: a, ui: UiState(MemStore()..ids = [id]), id: id)));
      await t.pump();
      return a;
    }

    testWidgets('no network record, the only node (3.5): 建立網路 + 我是隊員，加入隊長的網路', (t) async {
      final a = await added(t, const NetSnapshot());
      expect(find.widgetWithText(FilledButton, Btn.makeNetwork), findsOneWidget);
      expect(find.text(Btn.memberJoin), findsOneWidget);
      expect(find.text(Btn.addAnother), findsNothing);
      await finish(t, a);
    });

    testWidgets('no network record, another node (3.6): 建立網路 + 再加一台', (t) async {
      final a = await added(t, const NetSnapshot(), nodes: 2);
      expect(find.widgetWithText(FilledButton, Btn.makeNetwork), findsOneWidget);
      expect(find.text(Btn.addAnother), findsOneWidget);
      await finish(t, a);
    });

    testWidgets('a network record (pending too): 加入網路 + 再加一台, never 建立網路', (t) async {
      final a = await added(t, const NetSnapshot(netFiles: 1), nodes: 2);
      expect(find.widgetWithText(FilledButton, Btn.joinNetwork), findsOneWidget);
      expect(find.text(Btn.makeNetwork), findsNothing);
      await finish(t, a);
    });

    testWidgets('not computed yet: the neutral 加入網路 (D-m9)', (t) async {
      final a = await added(t, const NetSnapshot(computing: true));
      expect(find.widgetWithText(FilledButton, Btn.joinNetwork), findsOneWidget);
      await finish(t, a);
    });

    testWidgets('建立網路 opens 4.1 in make mode with this node ticked', (t) async {
      final a = await added(t, const NetSnapshot());
      await t.tap(find.widgetWithText(FilledButton, Btn.makeNetwork));
      await t.pumpAndSettle();
      final f = t.widget<NetFormPage>(find.byType(NetFormPage));
      expect(f.makes, isTrue);
      expect(f.ticked, {id});
      await finish(t, a);
    });
  });

  testWidgets('3.2: a refused name is said and nothing goes on; a good one goes to 3.5 / 3.6', (t) async {
    final a = app();
    a.nets.setForTest(const NetSnapshot());
    final ui = UiState(MemStore()..ids = [id]);
    await t.pumpWidget(host(Builder(
        builder: (c) => TextButton(
            onPressed: () => Navigator.of(c).push(MaterialPageRoute(builder: (_) => NickPage(app: a, ui: ui, id: id))),
            child: const Text('open')))));
    await t.tap(find.text('open'));
    await t.pumpAndSettle();
    expect(find.text('節點 ${id.substring(id.length - 4).toUpperCase()}'), findsOneWidget, reason: 'the default name');
    await t.enterText(find.byType(TextField), '   ');
    await t.tap(find.widgetWithText(FilledButton, Btn.save));
    await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
    await t.pumpAndSettle();
    expect(find.byType(AddedPage), findsNothing);
    expect(find.textContaining('名字要 1 到'), findsOneWidget);
    await t.enterText(find.byType(TextField), '前門');
    await t.tap(find.widgetWithText(FilledButton, Btn.save));
    await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
    await t.pumpAndSettle();
    expect(find.byType(AddedPage), findsOneWidget);
    expect(ui.nodes[id]!.nick, '前門');
    await finish(t, a);
  });

  testWidgets('F41: the home page shows a closed claim\'s line once; 知道了 clears it', (t) async {
    final a = app();
    a.lastClaimNote = '認領成功：節點 …7D2C';
    await t.pumpWidget(host(HomePage(app: a, ui: UiState(MemStore()..ids = [id]), devTrust: false, keys: keys())));
    await t.pump();
    expect(find.text('認領成功：節點 …7D2C'), findsOneWidget);
    await t.tap(find.text(Btn.gotIt));
    await t.pump();
    expect(find.text('認領成功：節點 …7D2C'), findsNothing);
    expect(a.lastClaimNote, isNull);
    await finish(t, a);
  });

  testWidgets('openRawPageFor returns what the page popped; busy -> the holder\'s name, nothing opened', (t) async {
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
    (String?, ClaimDone?)? got;
    await t.pumpWidget(MaterialApp(
        home: Builder(
            builder: (c) => TextButton(
                onPressed: () async => got = await openRawPageFor<ClaimDone>(Navigator.of(c), nl, gate, '新增節點', (u) => Builder(
                    builder: (p) => TextButton(onPressed: () => Navigator.of(p).pop(const ClaimDone('abc')), child: const Text('done')))),
                child: const Text('open')))));
    await t.tap(find.text('open'));
    await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
    await t.pumpAndSettle();
    await t.tap(find.text('done'));
    await t.pumpAndSettle();
    expect(got?.$1, isNull);
    expect(got?.$2?.id, 'abc');
    final other = reg.acquire('移除節點', LeaseKind.session)!;
    got = null;
    await t.tap(find.text('open'));
    await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
    await t.pumpAndSettle();
    expect(got?.$1, '移除節點');
    expect(find.text('done'), findsNothing);
    await other.release();
    await nl.dispose();
  });

  testWidgets('design §5.3: the claim page shows the dev inputs only in a dev build', (t) async {
    for (final dev in [false, true]) {
      t.binding.defaultBinaryMessenger.setMockMethodCallHandler(const MethodChannel('dev.batman/platform'), (c) async {
        return switch (c.method) { 'devTrust' => dev, 'filesDir' => '/x', _ => null };
      });
      await t.pumpWidget(MaterialApp(home: ClaimPage(key: ValueKey(dev))));
      await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await t.pump();
      expect(find.byType(TextField), dev ? findsOneWidget : findsNothing, reason: 'dev=$dev');
      expect(find.text(Btn.pasteQr), dev ? findsOneWidget : findsNothing, reason: 'dev=$dev');
      expect(find.text(Btn.scanQr), findsOneWidget);
    }
  });
}
