// #329 PR 5 R16 (§2.10): NetFormPage's mode. No mode from the entry -> joinChoice on the records (both -> asked,
// AA-M1); the member's join only on the team network's entry node, found by its last four (R18), never 建立網路
// when the phone holds an mnet or an mpend (Y-M2); two candidates -> the user picks (AC-m4); the field build has no
// member branch (T-S5).
import 'package:batman_app/src/flows/net_index.dart';
import 'package:batman_app/src/flows/net_run.dart';
import 'package:batman_app/src/nodelink/app_link.dart';
import 'package:batman_app/src/nodelink/core.dart';
import 'package:batman_app/src/rust/api/owner.dart' show NetView;
import 'package:batman_app/src/rust/frb_generated.dart';
import 'package:batman_app/swupdate.dart' show swChannel;
import 'package:batman_app/ui/join_choice.dart';
import 'package:batman_app/ui/join_pages.dart' show JoinTeamPage, MyRequestPage;
import 'package:batman_app/ui/net_pages.dart';
import 'package:batman_app/ui/team_deps.dart' show teamDepsOverride;
import 'package:batman_app/ui/ui_state.dart';
import 'package:batman_app/ui/widgets.dart' show Btn;
import 'package:flutter/material.dart' hide Page;
import 'package:flutter_test/flutter_test.dart';

import '../flows/net_run_test.dart' show World, ans;
import 'net_pages_test.dart' show deps;
import 'pages_test.dart' show app, host, id;
import 'join_pages_test.dart' as jp;
import 'ui_state_test.dart' show MemStore;

const twin = '1111111111111111117d2c'; // the same last four as pages_test's id
const other = '22222222222222222299ff';

NetEntry net(String nid) =>
    NetEntry(nid, NetView(netId: nid, meshId: 'bm-$nid', netName: 'Own', applied: true, country: 'US', members: const []));

NetSnapshot snap({bool net0 = false, List<MnetEntry> mnets = const [], List<String> pends = const []}) => NetSnapshot(
    netFiles: net0 ? 1 : 0,
    nets: net0 ? [net('a')] : const [],
    anyMnet: mnets.isNotEmpty,
    anyMpend: pends.isNotEmpty,
    mnetIds: [for (final m in mnets) m.id],
    mpendIds: pends,
    mnets: mnets);

const m1 = MnetEntry('m1', name: '山隊', entryLast4: '7D2C'); // R18: case does not matter

void main() {
  setUpAll(() => RustLib.initMock(api: jp.TeamRust()));
  setUp(() => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(swChannel, (c) async => null));

  Future<void> settle(WidgetTester t) async {
    for (var i = 0; i < 6; i++) {
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

  /// 4.1 for [s] over a home route, opened from row 6 with [ticked]; [nodes]: the phone's node records.
  Future<(AppLink, World)> open(WidgetTester t, NetSnapshot s,
      {bool dev = true,
      NetMode? mode,
      String? memberNet,
      Set<String> ticked = const {},
      List<String> nodes = const [id],
      NetSnapshot? underLease}) async {
    t.view.physicalSize = const Size(1080, 5000);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    final a = app();
    a.devTrust = dev;
    a.link.core.setRecords([for (final n in nodes) Rec(n, 1)]);
    a.nets.setForTest(s);
    final w = World()
      ..script('mjoin', [ans('[JOINED] 已套用：節點 …7d2c 已加入網路 bm-a')])
      ..script('join', [ans('[JOINED] 已套用：節點 …7d2c 已加入網路 bm-a')]);
    await t.pumpWidget(host(Builder(
        builder: (c) => Scaffold(
            body: TextButton(
                onPressed: () => Navigator.of(c).push(MaterialPageRoute(
                    builder: (_) => NetFormPage(
                          app: a,
                          ui: UiState(MemStore()..ids = nodes),
                          mode: mode,
                          memberNet: memberNet,
                          ticked: ticked,
                          compute: () async => underLease ?? s,
                          // what 4.1 hands the run page is asserted on NetRunPage (runFor carries it into the app's
                          // NetRun: net_run_page_pr5_test); the run here only has to end
                          runFlow: (l, go, _, _, _) =>
                              NetRun(deps(w, l, app: a), ids: const [id], makes: false, joinRel: 'net/a', askGoOn: go),
                        ))),
                child: const Text('open'))))));
    await t.tap(find.text('open'));
    await settle(t);
    return (a, w);
  }

  Future<void> start(WidgetTester t) async {
    await t.tap(find.widgetWithText(FilledButton, Btn.start));
    await settle(t);
  }

  NetRunPage runPage(WidgetTester t) => t.widget<NetRunPage>(find.byType(NetRunPage));

  testWidgets('AA-M1: net + mnet -> asked; 這支手機建立的網路 -> the leader form, a ticked node starts as before', (t) async {
    final (a, _) = await open(t, snap(net0: true, mnets: [m1]), ticked: {id});
    expect(find.byKey(const Key('mode-member')), findsOneWidget);
    await t.tap(find.byKey(const Key('mode-leader')));
    await settle(t);
    expect(find.text('要加入哪個網路'), findsOneWidget, reason: 'the PR 3 leader form');
    await start(t);
    expect([runPage(t).member, runPage(t).joinRel, ...runPage(t).ids], [false, 'net/a', id]);
    await finish(t, a);
  });

  testWidgets('net + mnet -> 隊長的網路（我是隊員） -> the member join on the entry node', (t) async {
    final (a, _) = await open(t, snap(net0: true, mnets: [m1]));
    await t.tap(find.byKey(const Key('mode-member')));
    await settle(t);
    expect(find.byKey(const Key('member-entry')), findsOneWidget);
    await start(t);
    expect([runPage(t).member, runPage(t).joinRel, ...runPage(t).ids], [true, 'mnet/m1', id]);
    await finish(t, a);
  });

  testWidgets('Y-M2: only mnet, row 6 brings a node that is not the entry -> the entry node; never 建立網路', (t) async {
    final (a, _) = await open(t, snap(mnets: [m1]), ticked: {other}, nodes: [id, other]);
    expect(find.text(Btn.makeNetwork), findsNothing);
    expect(find.text('網路名稱'), findsNothing);
    expect(find.text('用節點 …7D2C 加入「山隊」'), findsOneWidget);
    await start(t);
    expect(runPage(t).ids, [id], reason: 'not the ticked node');
    await finish(t, a);
  });

  testWidgets('only mnet, its entry node not on this phone -> kNotEntryNode, no 開始, no 建立網路', (t) async {
    final (a, _) = await open(t, snap(mnets: [m1]), nodes: [other]);
    expect(find.text(kNotEntryNode), findsOneWidget);
    expect(t.widget<FilledButton>(find.widgetWithText(FilledButton, Btn.start)).onPressed, isNull);
    expect(find.text('網路名稱'), findsNothing);
    await finish(t, a);
  });

  testWidgets('AC-m4: two nodes with the entry\'s last four -> listed, 開始 only after a pick', (t) async {
    final (a, _) = await open(t, snap(mnets: [m1]), nodes: [id, twin]);
    expect(find.byKey(const Key('entry-$id')), findsOneWidget);
    expect(find.byKey(const Key('entry-$twin')), findsOneWidget);
    expect(t.widget<FilledButton>(find.widgetWithText(FilledButton, Btn.start)).onPressed, isNull);
    await t.tap(find.byKey(const Key('entry-$twin')));
    await settle(t);
    await start(t);
    expect(runPage(t).ids, [twin]);
    await finish(t, a);
  });

  testWidgets('no entry left -> kNeedNewInvite with 收隊長的邀請; an mnet that does not open -> 再試一次 (AC-m8)',
      (t) async {
    var (a, _) = await open(t, snap(mnets: [const MnetEntry('m1', name: '山隊')]));
    expect(find.text(kNeedNewInvite), findsOneWidget);
    await t.tap(find.text('收隊長的邀請'));
    await settle(t);
    expect(find.byType(JoinTeamPage), findsOneWidget);
    await finish(t, a);
    (a, _) = await open(t, snap(mnets: [const MnetEntry('m1', opens: false)]));
    expect(find.text('這筆隊伍網路的紀錄現在打不開'), findsOneWidget);
    expect(find.text(Btn.tryAgain), findsOneWidget);
    expect(find.textContaining('重新申請'), findsNothing);
    await finish(t, a);
  });

  testWidgets('two mnets: picked first, same names told apart; memberNet (from 7.10) is not picked again', (t) async {
    const m2 = MnetEntry('ab99', name: '山隊', entryLast4: '7d2c');
    var (a, _) = await open(t, snap(mnets: [m1, m2]));
    expect(find.text('山隊（代號 …AB99）'), findsOneWidget);
    expect(t.widget<FilledButton>(find.widgetWithText(FilledButton, Btn.start)).onPressed, isNull);
    await finish(t, a);
    (a, _) = await open(t, snap(mnets: [m1, m2]), memberNet: 'ab99');
    expect(find.byKey(const Key('mnet-ab99')), findsNothing);
    await start(t);
    expect(runPage(t).joinRel, 'mnet/ab99');
    await finish(t, a);
  });

  testWidgets('only mpend -> 看我的申請 (7.9); never 建立網路', (t) async {
    teamDepsOverride = jp.World(const [], const {}).deps; // 7.9 reads the request
    addTearDown(() => teamDepsOverride = null);
    final (a, _) = await open(t, snap(pends: ['p1']));
    expect(find.text('還在等隊長同意你的申請'), findsOneWidget);
    expect(find.text('網路名稱'), findsNothing);
    await t.tap(find.text('看我的申請'));
    await settle(t);
    expect(find.byType(MyRequestPage), findsOneWidget);
    await finish(t, a);
  });

  testWidgets('T-S5: the field build has no member branch (only mnet -> the words, no button, never 建立網路)', (t) async {
    final (a, _) = await open(t, snap(mnets: [m1]), dev: false);
    expect(find.text('這支手機加入的是別人的隊伍網路'), findsOneWidget);
    expect(find.byKey(const Key('member-entry')), findsNothing);
    expect(find.text('網路名稱'), findsNothing);
    await finish(t, a);
  });

  testWidgets('AA-m3: an mnet or mpend file appeared since the form was made -> not started, the user told', (t) async {
    final (a, _) = await open(t, snap(net0: true),
        mode: NetMode.leader, ticked: {id}, underLease: snap(net0: true, pends: ['p9']));
    await start(t);
    a.nets.setForTest(snap(net0: true)); // the release recomputes from real files: the form's records again
    await settle(t);
    expect(find.byType(NetRunPage), findsNothing);
    expect(find.text('手機裡的網路紀錄剛剛變了，請再確認一次再按「開始」。'), findsOneWidget);
    await finish(t, a);
  });

  testWidgets('nothing at all -> 建立網路 (§5.1 row 6, unchanged)', (t) async {
    final (a, _) = await open(t, snap());
    expect(find.text('網路名稱'), findsOneWidget);
    await finish(t, a);
  });
}
