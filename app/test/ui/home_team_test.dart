// #329 PR 5 §2.10 / design §5.1: the home page's team routes. A request waiting (mpend) is a todo that opens 7.9 and
// counts as one; row 6's 看我的申請 -> 7.9, 加入隊長的網路 -> 7.8; none of them in the field build (F14 / T-S5).
import 'package:batman_app/src/flows/net_index.dart';
import 'package:batman_app/src/nodelink/app_link.dart';
import 'package:batman_app/src/nodelink/core.dart';
import 'package:batman_app/src/rust/frb_generated.dart';
import 'package:batman_app/ui/home_page.dart';
import 'package:batman_app/ui/join_pages.dart' show JoinTeamPage, MyRequestPage;
import 'package:batman_app/ui/team_deps.dart' show teamDepsOverride;
import 'package:batman_app/ui/team_hub.dart' show PickPendPage;
import 'package:batman_app/ui/ui_state.dart';
import 'package:batman_app/ui/widgets.dart' show Btn;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'join_pages_test.dart' as jp;
import 'pages_test.dart' show app, host, id, keys, sv;
import 'ui_state_test.dart' show MemStore;

void main() {
  setUpAll(() => RustLib.initMock(api: jp.TeamRust()));

  Future<AppLink> home(WidgetTester t, NetSnapshot s, {bool dev = true, int nodeState = 2}) async {
    t.view.physicalSize = const Size(1080, 5000);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    teamDepsOverride = jp.World(const [], const {}).deps;
    addTearDown(() => teamDepsOverride = null);
    final a = app();
    a.link.core.states[id]!
      ..kind = Kind.read
      ..view = 'green'
      ..readAt = a.link.now()
      ..extra = sv('green', nodeState: nodeState)
      ..last = Concl.read;
    a.nets.setForTest(s);
    await t.pumpWidget(host(HomePage(app: a, ui: UiState(MemStore()..ids = [id]), devTrust: dev, keys: keys())));
    await t.pump();
    return a;
  }

  Future<void> finish(WidgetTester t, AppLink a) async {
    await t.pumpWidget(const SizedBox());
    await a.link.dispose();
    await t.pump(const Duration(seconds: 10));
    AppLink.forgetForTest();
  }

  const pend = NetSnapshot(anyMpend: true, mpendIds: ['p1']);

  testWidgets('a request waiting: the todo, counted, opens 7.9 on that request', (t) async {
    final a = await home(t, pend);
    expect(find.byKey(const Key('todo-pend-p1')), findsOneWidget);
    expect(find.text('有 1 件事要你處理'), findsOneWidget);
    await t.tap(find.descendant(of: find.byKey(const Key('todo-pend-p1')), matching: find.text(Btn.seeRequest)));
    await t.pumpAndSettle();
    expect(t.widget<MyRequestPage>(find.byType(MyRequestPage)).netId, 'p1');
    await finish(t, a);
  });

  testWidgets('T-S5: the field build has no such todo', (t) async {
    final a = await home(t, pend, dev: false);
    expect(find.byKey(const Key('todo-pend-p1')), findsNothing);
    expect(find.text('有 1 件事要你處理'), findsNothing);
    await finish(t, a);
  });

  testWidgets('row 6 with a request: 看我的申請 -> 7.9 (picked when several)', (t) async {
    final a = await home(t, pend, nodeState: 1);
    await t.tap(find.widgetWithText(FilledButton, Btn.seeRequest));
    await t.pumpAndSettle();
    expect(find.byType(PickPendPage), findsOneWidget);
    await finish(t, a);
  });

  testWidgets('row 6 with nothing: 加入隊長的網路 -> 7.8', (t) async {
    final a = await home(t, const NetSnapshot(), nodeState: 1);
    await t.tap(find.text(Btn.joinTeam));
    await t.pumpAndSettle();
    expect(find.byType(JoinTeamPage), findsOneWidget);
    await finish(t, a);
  });
}
