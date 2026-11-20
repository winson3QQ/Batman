// #329 PR 4 §2.3 / §2.6 / §2.7: the node page's groups and its unfinished-change line (T-N2), 更多 (T-N3 the leave row
// only on a fresh read, T-N4 the nickname without 3.5 / 3.6, removal back to the home page with the update hold gone),
// and the leave page (T-L1 the three ends of leaveFlow, T-L2 the read after a leave on the same session, T-L3 the lease
// back at the result, T-L4 the dialog's facts, 取消). Fake console: op_session_test's Fx.
import 'package:batman_app/member_ui.dart' show leaveNotAsked;
import 'package:batman_app/src/flows/owner_console.dart' show SwLink;
import 'package:batman_app/src/nodelink/app_link.dart';
import 'package:batman_app/src/nodelink/core.dart';
import 'package:batman_app/src/nodelink/node_link.dart' show LoginForEnd;
import 'package:batman_app/src/rust/api/owner.dart' show NetView, StatusView;
import 'package:batman_app/src/flows/net_index.dart' show NetEntry, NetSnapshot;
import 'package:batman_app/src/rust/frb_generated.dart';
import 'package:batman_app/swupdate.dart' show SwFlow, SwHold;
import 'package:batman_app/ui/add_pages.dart' show AddedPage;
import 'package:batman_app/ui/more_pages.dart';
import 'package:batman_app/ui/node_page.dart';
import 'package:batman_app/ui/ui_state.dart';
import 'package:batman_app/ui/widgets.dart' show Btn;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../flows/op_session_test.dart' show Fx;
import '../flows/owner_console_pr4_test.dart' show FakeSwLink, P4Session;
import '../support/fake_node.dart' as nus show FakeRust;
import 'pages_test.dart' show app, host, id;
import 'ui_state_test.dart' show MemStore;

class Rust extends nus.FakeRust {
  final dialogs = <String>[];
  final removed = <String>[];
  @override
  Future<bool> crateApiClaimStoreKeepCopy({required String dir, required String rel}) async => true;
  @override
  Future<void> crateApiClaimStoreRemove({required String dir, required String rel}) async => removed.add(rel);
  @override
  List<String> crateApiOwnerLeaveConfirmText(
      {required String last4, required String netId, required bool adminApplied, required bool memberEntry}) {
    dialogs.add('$last4 $netId admin=$adminApplied member=$memberEntry');
    return ['要讓節點 …$last4 離開隊伍網路嗎？', '離開後這台的 HaLow 無線電會關閉。'];
  }
}

StatusView view({String netId = '', bool canLeave = true, String unfinished = '', bool under = false, String warning = '', String lagNote = ''}) =>
    StatusView(
        color: 'green',
        row: '3',
        sentence: '已連上隊伍網路',
        lagNote: lagNote,
        warning: warning, note: '',
        nodeState: 2,
        netId: netId,
        version: 'v',
        tech: const [],
        fresh: true,
        rateNote: '',
        unfinished: unfinished,
        unfinishedUnderVerdict: under,
        canLeave: canLeave);

void read(AppLink a, StatusView v, {bool fresh = true}) => a.link.core.states[id]!
  ..kind = Kind.read
  ..view = 'green'
  ..readAt = fresh ? a.link.now() : a.link.now() - 400000
  ..extra = v
  ..last = Concl.read;

/// #329 UX plan §4.9 / T21: the session of a node that answers the status request after a leave with E_RATE (on a
/// kept session the page was read less than the node's limit ago): Rust then returns the page from before the leave,
/// marked not fresh.
class RateSession extends P4Session {
  RateSession(super.rust);
  @override
  StatusView statusView({required bool hasNet, required bool hasMnet}) {
    pageReads++;
    final v = view(netId: 'ab12');
    return StatusView(
        color: v.color,
        row: v.row,
        sentence: v.sentence,
        lagNote: v.lagNote,
        warning: v.warning, note: '',
        nodeState: v.nodeState,
        netId: v.netId,
        version: v.version,
        tech: v.tech,
        fresh: false,
        rateNote: '節點忙碌，顯示的是先前的狀態',
        unfinished: v.unfinished,
        unfinishedUnderVerdict: v.unfinishedUnderVerdict,
        canLeave: v.canLeave);
  }
}

class _Flow implements SwFlow {
  @override
  dynamic noSuchMethod(Invocation i) => throw UnimplementedError('${i.memberName}');
}

void main() {
  final rust = Rust();
  setUpAll(() => RustLib.initMock(api: rust));
  setUp(rust.dialogs.clear);

  Future<void> settle(WidgetTester t, Fx f) async {
    for (var i = 0; i < 6; i++) {
      await t.runAsync(() async {
        for (final r in f.rigs) {
          await r.clock.run(500);
        }
      });
      await t.pump(const Duration(milliseconds: 100));
    }
  }

  group('node page', () {
    // #329 PR 6 test migration gap 2 (old member_ui_test :159): Rust decides the lag small print (rows 3 / 4,
    // statuspage.rs); the node page shows it under the verdict while the read is fresh, and not on old data.
    for (final fresh in [true, false]) {
      testWidgets('lagNote: ${fresh ? 'shown on a fresh read' : 'not shown on old data'}', (t) async {
        final a = app();
        read(a, view(lagNote: '約 4 分鐘後才會更新'), fresh: fresh);
        await t.pumpWidget(host(NodePage(app: a, id: id, ui: UiState(MemStore()))));
        expect(find.textContaining('約 4 分鐘後才會更新'), fresh ? findsOneWidget : findsNothing);
      });
    }
    for (final (under, order) in [(true, ['未完成', '注意']), (false, ['注意', '未完成'])]) {
      testWidgets('T-N2: the unfinished-change line ${under ? 'right under the verdict' : 'after the ⚠️ line'}', (t) async {
        final a = app();
        read(a, view(unfinished: '未完成', under: under, warning: '注意'));
        await t.pumpWidget(host(NodePage(app: a, id: id, ui: UiState(MemStore()))));
        final next = find.textContaining('未完成');
        expect(next, findsOneWidget);
        final text = (t.widget<Text>(next)).data!;
        expect(text.indexOf(order[0]) < text.indexOf(order[1]), isTrue, reason: text);
      });
    }

    testWidgets('groups: 手機 Wi-Fi and 更多; no removal or tech data on the node page itself', (t) async {
      final a = app();
      await t.pumpWidget(host(NodePage(app: a, id: id, ui: UiState(MemStore()))));
      expect(find.byKey(const Key('node-wifi')), findsOneWidget);
      expect(find.byKey(const Key('node-more')), findsOneWidget);
      expect(find.text('從這支手機移除這台節點'), findsNothing);
    });
  });

  group('更多', () {
    testWidgets('T-N3: 離開網路 only on a fresh read that can leave', (t) async {
      for (final (fresh, can, shown) in [(true, true, true), (false, true, false), (true, false, false)]) {
        final a = app();
        read(a, view(canLeave: can), fresh: fresh);
        await t.pumpWidget(host(MorePage(app: a, ui: UiState(MemStore()), id: id)));
        expect(find.byKey(const Key('more-leave')), shown ? findsOneWidget : findsNothing, reason: 'fresh $fresh can $can');
        await t.pumpWidget(const SizedBox());
        AppLink.forgetForTest();
      }
    });

    testWidgets('T-N4: 改暱稱 saves and comes back; never 3.5 / 3.6', (t) async {
      final a = app();
      final ui = UiState(MemStore()..ids = [id]);
      await t.runAsync(ui.load);
      await t.pumpWidget(host(MorePage(app: a, ui: ui, id: id)));
      await t.tap(find.text('改暱稱'));
      await t.pumpAndSettle();
      expect(find.text('改暱稱'), findsWidgets);
      expect(find.textContaining('已加入這支手機'), findsNothing);
      await t.enterText(find.byType(TextField), '北門');
      await t.tap(find.widgetWithText(FilledButton, Btn.save));
      await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
      await t.pumpAndSettle();
      expect(find.byType(AddedPage), findsNothing);
      expect(find.byType(MorePage), findsOneWidget);
      expect(ui.nodes[id]?.nick, '北門');
    });

    testWidgets('removal: back to the home page, and the update left of it is dropped', (t) async {
      final a = app();
      final ui = UiState(MemStore()..ids = [id]);
      await t.runAsync(ui.load);
      a.sw.take(id, () => (FakeSwLink() as SwLink, SwHold(_Flow())));
      await t.pumpWidget(host(Builder(
          builder: (c) => TextButton(
              onPressed: () => Navigator.of(c).push(MaterialPageRoute(builder: (_) => NodePage(app: a, id: id, ui: ui))),
              child: const Text('home')))));
      await t.tap(find.text('home'));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const Key('node-more')));
      await t.pumpAndSettle();
      await t.tap(find.text('從這支手機移除這台節點'));
      await t.pumpAndSettle();
      await t.tap(find.widgetWithText(FilledButton, '移除'));
      await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
      await t.pumpAndSettle();
      expect(find.text('home'), findsOneWidget, reason: 'the home page, not a node page that has nothing left');
      expect(find.byType(NodePage), findsNothing);
      expect(rust.removed, ['node/$id']);
      expect(a.sw.of(id), isNull);
      a.link.dispose();
      await t.pumpWidget(const SizedBox());
      AppLink.forgetForTest();
    });
  });

  group('離開網路', () {
    Future<(Fx, AppLink)> openLeave(WidgetTester t, {String netId = 'ab12', bool push = false, bool rate = false}) async {
      final f = rate ? Fx(rust, make: RateSession.new) : Fx(rust);
      final a = app();
      read(a, view(netId: netId));
      final page = LeavePage(app: a, ui: UiState(MemStore()), id: id, deps: f.d);
      if (push) {
        // over a base route: back on a root route never pops (a PopScope test needs a route under it)
        await t.pumpWidget(host(Builder(
            builder: (c) => TextButton(
                onPressed: () => Navigator.of(c).push(MaterialPageRoute(builder: (_) => page)), child: const Text('base')))));
        await t.tap(find.text('base'));
        await t.pump();
        await t.pump(const Duration(seconds: 1));
      } else {
        await t.pumpWidget(host(page));
      }
      await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await t.pump();
      return (f, a);
    }

    testWidgets('T-L4: the dialog is Rust\'s, from the fresh read\'s network and the device id\'s own last four', (t) async {
      await openLeave(t);
      expect(rust.dialogs, ['7d2c ab12 admin=false member=false']);
      expect(find.text('要讓節點 …7D2C 離開隊伍網路嗎？'), findsOneWidget); // #329 PR 6: the last four upper case on screen (device 2026-11-18)
    });

    testWidgets('T-L1 / T-L2 / T-L3: left -> the read after it on the same session (cut once); the lease back at once',
        (t) async {
      final (f, _) = await openLeave(t);
      await t.tap(find.widgetWithText(FilledButton, Btn.leaveNetwork));
      await settle(t, f);
      final s = f.rigs.first.session as P4Session;
      expect(s.asked, ['network/leave', 'status page']);
      expect(f.logins, 1, reason: 'one login: the read is on the same session');
      expect(find.text('已離開隊伍網路'), findsOneWidget);
      expect(t.widget<Text>(find.byKey(const Key('leave-after'))).data, '這台還沒加入隊伍網路', reason: 'the cut read');
      expect(f.reg.current, isNull, reason: 'T-L3: released at the result, the page still open');
      expect(find.byType(LeavePage), findsOneWidget);
    });

    testWidgets('UX plan T21: left, the read after it answered E_RATE (the page before the leave, not fresh) -> stale',
        (t) async {
      final (f, _) = await openLeave(t, rate: true);
      await t.tap(find.widgetWithText(FilledButton, Btn.leaveNetwork));
      await settle(t, f);
      final s = f.rigs.first.session as RateSession;
      expect(s.asked, ['network/leave', 'status page']);
      expect(s.pageReads, 1, reason: 'the page was read on this session');
      expect(find.text('已離開隊伍網路'), findsOneWidget);
      expect(find.byKey(const Key('leave-stale')), findsOneWidget);
      expect(find.byKey(const Key('leave-after')), findsNothing, reason: 'the fields from before the leave are shown');
      expect(find.text('已連上隊伍網路'), findsNothing);
    });

    testWidgets('T-L1: not left -> its line, no read after it', (t) async {
      final (f, _) = await openLeave(t);
      (f.rigs.first.session as P4Session).leaveMode = 'refused';
      await t.tap(find.widgetWithText(FilledButton, Btn.leaveNetwork));
      await settle(t, f);
      expect((f.rigs.first.session as P4Session).asked, ['network/leave']);
      expect(find.textContaining('沒有離開網路'), findsOneWidget);
    });

    testWidgets('T-L1: no session -> the login\'s line, nothing sent', (t) async {
      final (f, _) = await openLeave(t);
      f.loginEnd = LoginForEnd.notFound;
      await t.tap(find.widgetWithText(FilledButton, Btn.leaveNetwork));
      await settle(t, f);
      expect(find.textContaining('沒有找到這台節點'), findsOneWidget);
      expect(f.rigs.first.radio.written, isEmpty);
      expect(find.text(leaveNotAsked), findsNothing);
    });

    // #329 honest-errors C2
    testWidgets('T-L1: the node near but no session -> that line, nothing sent', (t) async {
      final (f, _) = await openLeave(t);
      f
        ..loginEnd = LoginForEnd.notFound
        ..loginFound = true;
      await t.tap(find.widgetWithText(FilledButton, Btn.leaveNetwork));
      await settle(t, f);
      expect(find.textContaining('附近有像是這台節點的裝置，但沒有連上'), findsOneWidget);
      expect(find.textContaining('沒有找到這台節點'), findsNothing);
      expect(f.rigs.first.radio.written, isEmpty);
    });

    testWidgets('T-L1: the link lost after network/leave went out -> 結果不明 (leave v4.1 §3)', (t) async {
      final (f, _) = await openLeave(t);
      f.rigs.first.radio.silent = true;
      await t.tap(find.widgetWithText(FilledButton, Btn.leaveNetwork));
      await settle(t, f);
      f.rigs.first.radio.drop();
      await settle(t, f);
      expect(find.textContaining('結果不明'), findsOneWidget);
      expect((f.rigs.first.session as P4Session).asked, ['network/leave'], reason: 'no read after an unknown end');
    });

    testWidgets('code review A m6: an applied net record of that network -> the dialog admin sentence', (t) async {
      final f = Fx(rust);
      final a = app();
      read(a, view(netId: 'ab12'));
      a.nets.setForTest(NetSnapshot(netFiles: 1, nets: [
        NetEntry('ab12', const NetView(netId: 'ab12', meshId: 'bm', netName: 'n', applied: true, country: 'US', members: [])),
      ]));
      await t.pumpWidget(host(LeavePage(app: a, ui: UiState(MemStore()), id: id, deps: f.d)));
      await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await t.pump();
      expect(rust.dialogs.last, startsWith('7d2c ab12 admin=true'));
    });

    testWidgets('code review A m10: left, but the read after it read nothing -> says so', (t) async {
      final (f, _) = await openLeave(t);
      (f.rigs.first.session as P4Session).pageSilent = true;
      await t.tap(find.widgetWithText(FilledButton, Btn.leaveNetwork));
      for (var i = 0; i < 7; i++) {
        await settle(t, f); // past the 15 s of the read
      }
      expect(find.text('已離開隊伍網路'), findsOneWidget);
      expect(find.byKey(const Key('leave-stale')), findsOneWidget);
    });

    testWidgets('code review A m5: while the leave runs, back does not close the page', (t) async {
      final (f, _) = await openLeave(t, push: true);
      f.rigs.first.radio.silent = true;
      await t.tap(find.widgetWithText(FilledButton, Btn.leaveNetwork));
      await settle(t, f);
      await t.state<NavigatorState>(find.byType(Navigator)).maybePop();
      await t.pump(const Duration(seconds: 1));
      await t.pump(); // a popped route goes on the frame after its transition
      await t.pump(const Duration(seconds: 5));
      expect(find.byType(LeavePage), findsOneWidget);
    });

    // #329 PR 6 test migration gap 3 (old member_ui_test :451 「a double tap opens one dialog」): the page is its own
    // confirmation now; two quick taps on 離開網路 send network/leave once, on one login.
    testWidgets('a double tap on 離開網路 sends network/leave once', (t) async {
      final (f, _) = await openLeave(t);
      final at = t.getCenter(find.widgetWithText(FilledButton, Btn.leaveNetwork));
      await t.tapAt(at);
      await t.pump();
      await t.tapAt(at); // the same spot: the label is 「正在離開…」 by now
      await settle(t, f);
      expect((f.rigs.first.session as P4Session).asked.where((q) => q == 'network/leave').length, 1);
      expect(f.logins, 1);
    });

    testWidgets('取消 sends nothing', (t) async {
      final (f, _) = await openLeave(t);
      await t.tap(find.widgetWithText(TextButton, Btn.cancel));
      await t.pumpAndSettle();
      expect(f.logins, 0);
      expect(find.byType(LeavePage), findsNothing);
    });
  });
}
