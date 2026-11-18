// #329 PR 5 R15 / T-P5-E / T-S5: 「隊伍與邀請」. With no record at all every row is there and opens its page, which
// says why there is nothing to do; the field build has no such row; the leader's network pick lists applied networks
// only and tells same names apart (R13).
import 'package:batman_app/src/flows/net_index.dart';
import 'package:batman_app/src/rust/api/owner.dart' show NetView;
import 'package:batman_app/src/rust/frb_generated.dart';
import 'package:batman_app/ui/settings_page.dart';
import 'package:batman_app/ui/team_deps.dart' show teamDepsOverride;
import 'package:batman_app/ui/team_hub.dart';
import 'package:batman_app/ui/net_pages.dart' show NetFormPage;
import 'package:batman_app/src/nodelink/core.dart' as nl show Page;
import 'package:batman_app/ui/ui_state.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'join_pages_test.dart' as jp;
import 'pages_test.dart' show app, host;
import 'ui_state_test.dart' show MemStore;

/// T-P5-E: written out here, not read from the page's own list (a row taken out of both still fails).
const rows = ['隊員名單', '邀請隊員', '收隊員的申請', '產生更新包', '收隊長的邀請', '再顯示申請', '匯入隊長的同意', '讓我的節點加入隊長的網路', '貼上隊長給的新密碼'];

NetEntry net(String id, String name, {bool applied = true}) => NetEntry(
    id, NetView(netId: id, meshId: 'bm-${id.substring(0, 2)}', netName: name, applied: applied, country: 'US', members: const []));

void main() {
  setUpAll(() => RustLib.initMock(api: jp.TeamRust()));

  Future<void> settle(WidgetTester t) async {
    for (var i = 0; i < 4; i++) {
      await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 5)));
      await t.pump(const Duration(milliseconds: 300));
    }
  }

  void tall(WidgetTester t) {
    t.view.physicalSize = const Size(1080, 5000);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
  }

  testWidgets('T-P5-E: no record at all -> every row there, each opens its page', (t) async {
    tall(t);
    teamDepsOverride = jp.World(const [], const {}).deps;
    addTearDown(() => teamDepsOverride = null);
    final a = app();
    a.nets.setForTest(const NetSnapshot());
    await t.pumpWidget(host(TeamHubPage(app: a, ui: UiState(MemStore()))));
    for (final r in rows) {
      expect(find.byKey(Key('hub-$r')), findsOneWidget, reason: r);
    }
    expect(kHubLeaderRows.length + kHubMemberRows.length, rows.length);
    for (final r in rows) {
      await t.tap(find.byKey(Key('hub-$r')));
      await settle(t);
      expect(find.byType(TeamHubPage).hitTestable(), findsNothing, reason: '$r opened a page');
      await t.state<NavigatorState>(find.byType(Navigator)).maybePop();
      await settle(t);
    }
  });

  testWidgets('review A m7: the member join from the hub returns to the settings state (Page.other)', (t) async {
    tall(t);
    final a = app();
    a.nets.setForTest(const NetSnapshot());
    await t.pumpWidget(host(TeamHubPage(app: a, ui: UiState(MemStore()))));
    await t.tap(find.byKey(const Key('hub-讓我的節點加入隊長的網路')));
    await settle(t);
    expect(t.widget<NetFormPage>(find.byType(NetFormPage)).back, nl.Page.other);
  });

  testWidgets('no network: the leader\'s pick says why', (t) async {
    tall(t);
    final a = app();
    a.nets.setForTest(const NetSnapshot());
    await t.pumpWidget(host(TeamHubPage(app: a, ui: UiState(MemStore()))));
    await t.tap(find.byKey(const Key('hub-隊員名單')));
    await settle(t);
    expect(find.text('這支手機沒有已建立的網路'), findsOneWidget);
  });

  testWidgets('R13 / S-m7: applied networks only; the same name told apart by its id', (t) async {
    tall(t);
    final a = app();
    a.nets.setForTest(NetSnapshot(
        netFiles: 3, nets: [net('aa11', 'Batman'), net('bb22', 'Batman'), net('cc33', 'Other', applied: false)]));
    await t.pumpWidget(host(PickNetPage(app: a, title: '隊員名單', next: (id) => Text('next $id'))));
    await settle(t);
    expect(find.text('Batman bm-aa（代號 …AA11）'), findsOneWidget);
    expect(find.text('Batman bm-bb（代號 …BB22）'), findsOneWidget);
    expect(find.byKey(const Key('pick-cc33')), findsNothing);
    await t.tap(find.byKey(const Key('pick-bb22')));
    await settle(t);
    expect(find.text('next bb22'), findsOneWidget);
  });

  for (final dev in [true, false]) {
    testWidgets('T-S5: 「隊伍與邀請」 in settings only in the dev build (dev=$dev)', (t) async {
      tall(t);
      await t.pumpWidget(host(SettingsPage(app: app(), ui: UiState(MemStore()), devTrust: dev)));
      expect(find.byKey(const Key('settings-team')), dev ? findsOneWidget : findsNothing);
    });
  }
}
