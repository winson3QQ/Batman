// #329 PR 5 R14 / R16 / S-m2 on the run page: the send after a join shown only through RekeyResult (an applying send
// is not all green, X-m7), the member's run, and 「收隊長的邀請」 on a line asking for a new invite (devTrust only).
import 'package:batman_app/src/flows/net_run.dart';
import 'package:batman_app/src/nodelink/app_link.dart';
import 'package:batman_app/src/nodelink/lease.dart';
import 'package:batman_app/src/rust/frb_generated.dart';
import 'package:batman_app/ui/net_pages.dart';
import 'package:batman_app/ui/rekey_result.dart';
import 'package:batman_app/ui/ui_state.dart';
import 'package:batman_app/ui/widgets.dart' show Btn;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../flows/net_run_test.dart' show World, ans;
import 'net_pages_test.dart' show deps;
import 'pages_test.dart' show FakeRust, app, host, id;
import 'ui_state_test.dart' show MemStore;

const l4 = '7d2c'; // the last four of pages_test's id

void main() {
  setUpAll(() => RustLib.initMock(api: FakeRust()));

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

  Future<AppLink> run(WidgetTester t, World w, {bool member = false, bool devTrust = true}) async {
    t.view.physicalSize = const Size(1080, 5000);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    final a = app();
    a.devTrust = devTrust;
    final l = (await t.runAsync(() => a.link.acquire('加入網路', LeaseKind.session)))!;
    final rel = member ? 'mnet/m1' : 'net/a';
    await t.pumpWidget(host(NetRunPage(
      app: a,
      ui: UiState(MemStore()..ids = [id]),
      lease: l,
      ids: const [id],
      makes: false,
      joinRel: rel,
      member: member,
      flow: (go, _, _, _) =>
          NetRun(deps(w, l, app: a), ids: const [id], makes: false, member: member, joinRel: rel, askGoOn: go),
    )));
    await settle(t);
    return a;
  }

  testWidgets('X-m7: an applying send -> joined, warn, Rust\'s line through RekeyResult, no tick, no retry', (t) async {
    final w = World()
      ..script('join', [ans('[JOINED] 已套用：節點 …$l4 已加入網路 bm-a', send: true)])
      ..script('send', [ans('[UPDATED] 節點 …$l4 正在套用新密碼，稍後再看狀態頁')]);
    final a = await run(t, w);
    expect(find.text('已加入，有節點的新密碼還在套用'), findsOneWidget);
    expect(find.byType(RekeyResult), findsOneWidget);
    expect(find.text('[UPDATED] 節點 …$l4 正在套用新密碼，稍後再看狀態頁'), findsNothing, reason: 'shown once, plain');
    expect(find.byKey(const Key('rekey-tick')), findsNothing);
    expect(find.text(Btn.retryNode), findsNothing);
    expect(find.text(kRekeyOthersRule), findsOneWidget, reason: 'X-m5: the leader is told what the app cannot see');
    await finish(t, a);
  });

  testWidgets('current -> 完成, the leader\'s tick', (t) async {
    final w = World()
      ..script('join', [ans('[JOINED] 已套用：節點 …$l4 已加入網路 bm-a', send: true)])
      ..script('send', [ans('[UPDATED] 節點 …$l4 已換成新密碼')]);
    final a = await run(t, w);
    expect(find.text('完成'), findsWidgets);
    expect(find.byKey(const Key('rekey-tick')), findsOneWidget);
    await finish(t, a);
  });

  testWidgets('R16 member: memberJoin, the send as the member\'s; no tick (T-M1), the two checks', (t) async {
    final w = World()
      ..script('mjoin', [ans('[JOINED] 已套用：節點 …$l4 已加入網路 bm-a', send: true)])
      ..script('send', [ans('[UPDATED] 節點 …$l4 已換成新密碼')]);
    final a = await run(t, w, member: true);
    expect(w.joinRels, ['mnet/m1']);
    expect(w.sends, ['mnet/m1 member=true']);
    expect(find.byKey(const Key('rekey-tick')), findsNothing);
    expect(find.text('這台節點已換成這支手機的版本'), findsOneWidget);
    expect(find.text(kMemberRekeyRule), findsOneWidget);
    await finish(t, a);
  });

  testWidgets('the run of the app carries every page parameter, member too', (t) async {
    final a = app();
    final l = (await t.runAsync(() => a.link.acquire('加入網路', LeaseKind.session)))!;
    for (final m in [true, false]) {
      final p = NetRunPage(
          app: a, ui: UiState(MemStore()), lease: l, ids: const [id], makes: false, joinRel: 'mnet/m1', member: m);
      final r = runFor(p, deps(World(), l, app: a), (_) async => true);
      expect((r.member, r.joinRel, r.makes, r.rows.single.id), (m, 'mnet/m1', false, id));
    }
    await t.runAsync(l.release);
    await finish(t, a);
  });

  for (final dev in [true, false]) {
    testWidgets('S-m2: 需要新的邀請 -> 「收隊長的邀請」 only in the dev build (dev=$dev)', (t) async {
      final w = World()..script('mjoin', [ans('[REQ_FAIL] 加入網路沒有成功：需要新的邀請（手機裡已沒有這台節點的加入資料）')]);
      final a = await run(t, w, member: true, devTrust: dev);
      expect(find.text('收隊長的邀請'), dev ? findsOneWidget : findsNothing);
      await finish(t, a);
    });
  }
}
