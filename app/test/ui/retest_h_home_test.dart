// #329 re-test (2026-11-17 audit): the home-page parts of T-H2 and T-H3 (design §9.1) that no test named.
// T-H2(a): an earlier run's stored read (UiState) is shown in the unk style only, never with its colour.
// T-H3: the claim-pending todo is not shown for a node that has its node/<id> record (a finished claim); the todos are
// not recomputed by a home round; a lease taken back is a todo until 「知道了」.
// Already covered elsewhere (see the re-test report): joining (pages_test.dart), mpend (home_team_test.dart), SwHold
// (update_route_test.dart), claim-pending only in a dev build (key_abilities_test.dart).
import 'package:batman_app/src/nodelink/app_link.dart';
import 'package:batman_app/src/nodelink/lease.dart';
import 'package:batman_app/src/rust/frb_generated.dart';
import 'package:batman_app/ui/home_page.dart';
import 'package:batman_app/ui/ui_state.dart';
import 'package:batman_app/ui/widgets.dart' show Btn, Look, NodeRow, StatusHero;
import 'package:flutter/material.dart' hide Page;
import 'package:flutter_test/flutter_test.dart';

import 'pages_test.dart' show FakeRust, app, host, id, keys;
import 'ui_state_test.dart' show MemStore;

const other = '00000000000000000beef1';

class PendingRust extends FakeRust {
  List<String> pending = [];
  int pendingCalls = 0;
  bool pendingThrows = false;
  @override
  Future<List<String>> crateApiOwnerListPending({required String dir}) async {
    pendingCalls++;
    if (pendingThrows) throw StateError('store');
    return [...pending];
  }
}

void main() {
  final rust = PendingRust();
  setUpAll(() => RustLib.initMock(api: rust));
  setUp(() => rust
    ..pending = []
    ..pendingCalls = 0
    ..pendingThrows = false);

  Future<AppLink> home(WidgetTester t, {bool devTrust = true, UiState? ui}) async {
    final a = app(); // the phone has node/<id>
    await t.pumpWidget(host(HomePage(app: a, ui: ui ?? UiState(MemStore()..ids = [id]), devTrust: devTrust, keys: keys())));
    await t.pump();
    await t.pump();
    return a;
  }

  Future<void> done(WidgetTester t, AppLink a) async {
    a.link.dispose();
    await t.pumpWidget(const SizedBox());
    AppLink.forgetForTest();
  }

  testWidgets('T-H2(a): an earlier run\'s stored read -> unk row 「上次讀取 …，當時正常」, never ok; the status area is not 一切正常',
      (t) async {
    final ui = UiState(MemStore()..ids = [id]);
    await t.runAsync(ui.load);
    await t.runAsync(() => ui.noteReads({id: ('ok', DateTime.now().toUtc().subtract(const Duration(hours: 2)))}));
    expect(ui.nodes[id]?.look, 'ok', reason: 'premise: the stored read was ok');
    final a = app();
    a.link.core.states[id]!.roundsEnded = 2; // after this node's first rounds (#329 PR 7 T8): the stored read is shown
    await t.pumpWidget(host(HomePage(app: a, ui: ui, devTrust: false, keys: keys())));
    await t.pump();
    final row = t.widget<NodeRow>(find.byType(NodeRow));
    expect(row.look, Look.unk);
    expect(row.line, startsWith('上次讀取 '));
    expect(row.line, endsWith('，當時正常'));
    final hero = t.widget<StatusHero>(find.byType(StatusHero));
    expect(hero.look, Look.unk);
    expect(find.textContaining('一切正常'), findsNothing);
    await done(t, a);
  });

  testWidgets('T-H3: claim-pending — no todo when node/<id> exists (a finished claim); a todo for one without it',
      (t) async {
    rust.pending = [id]; // the claim finished: the node record is there
    var a = await home(t);
    expect(rust.pendingCalls, 1, reason: 'premise: the pending list was read at startup');
    expect(find.text('上次新增節點沒有做完'), findsNothing);
    await done(t, a);

    rust.pending = [id, other]; // `other` has no node record: an unfinished claim
    a = await home(t);
    expect(find.text('上次新增節點沒有做完'), findsOneWidget);
    await done(t, a);
  });

  testWidgets('T-H3: claim-pending — not in a field build even without node/<id>', (t) async {
    rust.pending = [other];
    final a = await home(t, devTrust: false);
    expect(find.text('上次新增節點沒有做完'), findsNothing);
    await done(t, a);
  });

  testWidgets('T-H3: a home round does not recompute the todos (only startup and coming back to the page)', (t) async {
    final a = await home(t);
    expect((rust.pendingCalls, find.text('上次新增節點沒有做完').evaluate().length), (1, 0));
    rust.pending = [other]; // appears on disk while the home page is shown
    for (var i = 0; i < 3; i++) {
      a.link.refresh(); // what a home round does to the page: NodeLink fires `changed`
      await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await t.pump();
    }
    await t.pump(const Duration(seconds: 16)); // the 15 s repaint tick too
    expect(rust.pendingCalls, 1, reason: 'a home round never lists the pending claims');
    expect(find.text('上次新增節點沒有做完'), findsNothing);
    // back from another page (the settings): computed again
    await t.tap(find.byTooltip('設定'));
    await t.pumpAndSettle();
    await t.pageBack();
    await t.pumpAndSettle();
    expect(rust.pendingCalls, 2);
    expect(find.text('上次新增節點沒有做完'), findsOneWidget);
    await done(t, a);
  });

  testWidgets('T-H3: the todos are computed again when a lease is released (a claim that finished behind the home page)',
      (t) async {
    rust.pending = [other]; // a claim running: no node record yet
    final a = await home(t);
    expect(find.text('上次新增節點沒有做完'), findsOneWidget);
    final l = (await t.runAsync(() => a.link.acquire('新增節點', LeaseKind.raw)))!;
    rust.pending = []; // the claim finished meanwhile (its pending record removed)
    await t.runAsync(() => l.release());
    await t.pump();
    await t.pump();
    expect(find.text('上次新增節點沒有做完'), findsNothing, reason: 'computed again at the release');
    await done(t, a);
  });

  testWidgets('T-H3 / T-G3(c): a raw lease taken back -> 「上一個操作可能沒有存完：<名稱>」 on the home page; 知道了 removes it',
      (t) async {
    final a = await home(t, devTrust: false);
    expect(find.textContaining('上一個操作可能沒有存完'), findsNothing);
    final l = (await t.runAsync(() => a.link.acquire('新增節點', LeaseKind.raw)))!;
    l.hold(); // the older page's busy work
    l.pageGone(); // the user pressed back
    await t.pump(const Duration(seconds: 899));
    expect(a.reg.current, l, reason: 'still held before the cap');
    expect(find.textContaining('上一個操作可能沒有存完'), findsNothing);
    await t.pump(const Duration(seconds: 16)); // past the cap, and the page's 15 s tick
    expect(a.reg.current, isNull);
    expect(find.text('上一個操作可能沒有存完：新增節點'), findsOneWidget);
    await t.tap(find.text(Btn.gotIt));
    await t.pump();
    expect(find.text('上一個操作可能沒有存完：新增節點'), findsNothing);
    expect(a.reg.unsavedTodos, isEmpty);
    await done(t, a);
  });

  testWidgets('review misc J m-2: the pending list unreadable at a release keeps the todo shown (never hides it)',
      (t) async {
    rust.pending = [other]; // an unfinished claim
    final a = await home(t);
    expect(find.text('上次新增節點沒有做完'), findsOneWidget);
    rust.pendingThrows = true;
    final l = (await t.runAsync(() => a.link.acquire('新增節點', LeaseKind.raw)))!;
    await t.runAsync(() => l.release());
    await t.pump();
    await t.pump();
    expect(rust.pendingCalls, 2, reason: 'premise: the release did read the list again');
    expect(find.text('上次新增節點沒有做完'), findsOneWidget);
    await done(t, a);
  });

  testWidgets('review misc I m1: the home page removes its lease listener when it goes away', (t) async {
    final a = await home(t);
    final withHome = a.reg.listeners.length;
    await t.pumpWidget(const SizedBox());
    expect(a.reg.listeners.length, withHome - 1);
    a.link.dispose();
    AppLink.forgetForTest();
  });
}
