// #329 PR 3 §2.5 / §2.8 / §3.2: the network pages on the real AppLink (lease registry, NodeLink, real Navigator) with
// fake flows (net_run_test's World). What is asserted is who holds the lease when: T-M1 (a)-(i), T-R1, and the 4.1
// hand-over (v14 AB-M1), the 開始 refusal (D9), the dialog closed by a blocked radio (§2.9), keepScreenOn.
import 'dart:async';

import 'package:batman_app/src/flows/net_index.dart';
import 'package:batman_app/src/flows/net_run.dart';
import 'package:batman_app/src/flows/owner_console.dart';
import 'package:batman_app/src/nodelink/core.dart';
import 'package:batman_app/src/rust/api/owner.dart' show MemberView, NetView;
import 'package:batman_app/src/nodelink/app_link.dart';
import 'package:batman_app/src/nodelink/lease.dart';
import 'package:batman_app/src/rust/frb_generated.dart';
import 'package:batman_app/swupdate.dart' show swChannel;
import 'package:batman_app/ui/net_pages.dart';
import 'package:batman_app/ui/ui_state.dart';
import 'package:batman_app/ui/widgets.dart' show Btn;
import 'package:flutter/material.dart' hide Page;
import 'package:flutter_test/flutter_test.dart';

import '../flows/net_run_test.dart' show World, ans, pend;
import 'pages_test.dart' show FakeRust, app, host, id, sv;
import 'ui_state_test.dart' show MemStore;

/// The World's deps, on the page's real lease; [gate] holds every login until it completes.
FlowDeps deps(World w, Lease l, {Completer<void>? gate, AppLink? app}) {
  final d = w.deps;
  return FlowDeps(
    login: (i, {bool clearNotY = false}) async {
      if (gate != null) await gate.future;
      return d.login(i, clearNotY: clearNotY);
    },
    console: d.console,
    applied: d.applied,
    blocked: app == null ? d.blocked : () => app.link.core.blocked, // the app: NodeLink's precondition
    leaseValid: () => l.valid,
  );
}

void main() {
  // #329 PR 6 (S20 device session 2026-11-18): the running card said 「這一步最多 6 分鐘」 twice, and under
  // 「正在確認節點連上了，最多 2 分鐘」 it said 6 minutes. The limit is said once: the step's own, else the run's 6 min.
  // #329 PR 7 (p1p2-check 4.x_working): the connect step says its own limit (design §5.4: login 60 s), not the run's 6
  // minutes; a step with no limit the code keeps (正在確認) says none.
  // Negative controls: a fixed 6-minute line -> the 6 / 2 minute cases FAIL; kRunWait alone -> the connect case FAILs;
  // the PR 6 version (6 minutes for every step without one) -> the connect case FAILs.
  test('runWaitFor: the time limit once per step, the current step own limit', () {
    for (final (line, want) in [
      ('正在連到節點…', '請留在這個畫面。這一步最多 1 分鐘。'),
      ('正在確認', '請留在這個畫面。'),
      ('正在加入網路，這一步最多 6 分鐘', '請留在這個畫面。'),
      ('正在確認節點連上了，最多 2 分鐘', '請留在這個畫面。'),
    ]) {
      expect(runWaitFor(line), want, reason: line);
      expect('$line\n${runWaitFor(line)}'.split('最多').length - 1, line == '正在確認' ? 0 : 1, reason: 'at most one limit on the card: $line');
    }
  });

  final rust = FakeRust();
  final screen = <bool>[];
  setUpAll(() => RustLib.initMock(api: rust));
  setUp(() {
    screen.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(swChannel, (c) async {
      if (c.method == 'keepScreenOn') screen.add((c.arguments as Map)['on'] as bool);
      return null;
    });
  });

  /// 4.1 in make mode for node [id] over a home route; [w] answers; [gate] holds the logins.
  Future<AppLink> openForm(WidgetTester t, World w,
      {Completer<void>? gate, Future<NetSnapshot> Function()? compute, CheckRun Function(Lease, String)? check}) async {
    final a = app();
    a.nets.setForTest(const NetSnapshot());
    await t.pumpWidget(host(Builder(
        builder: (c) => Scaffold(
            body: TextButton(
                onPressed: () => Navigator.of(c).push(MaterialPageRoute(
                    builder: (_) => NetFormPage(
                          app: a,
                          ui: UiState(MemStore()..ids = [id]),
                          makes: true,
                          ticked: const {id},
                          compute: compute ?? () async => const NetSnapshot(),
                          runFlow: (l, go, _, _, _) => NetRun(deps(w, l, gate: gate), ids: const [id], makes: true, askGoOn: go),
                          checkFlow: check,
                        ))),
                child: const Text('open'))))));
    await t.tap(find.text('open'));
    await t.pumpAndSettle();
    return a;
  }

  /// The back button: the top navigator's maybePop (what PopScope intercepts).
  Future<void> back(WidgetTester t) async {
    await t.state<NavigatorState>(find.byType(Navigator).last).maybePop();
    await t.pump(const Duration(seconds: 1)); // past a pop transition
    await t.pump(); // the popped route is removed on the frame after its transition
    await t.pump(const Duration(seconds: 5)); // and the page under it (4.1 pops itself after a run page that returned)
  }

  Future<void> start(WidgetTester t) async {
    await t.tap(find.widgetWithText(FilledButton, Btn.start));
    await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
    await t.pump();
    await t.pump(const Duration(milliseconds: 400));
  }

  Future<void> settle(WidgetTester t) async {
    for (var i = 0; i < 6; i++) {
      await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
      await t.pump(const Duration(milliseconds: 200));
    }
  }

  /// A lease release makes NetIndex compute again from real files; in a widget test that IO only ends inside
  /// runAsync, so the test computes once more there (the newest computation wins).
  Future<void> recomputed(WidgetTester t, AppLink a) async {
    await t.runAsync(a.nets.recompute);
    await t.pump();
  }

  /// The end of a test: no NodeLink timer left (its round 6 s after a release).
  Future<void> finish(WidgetTester t, AppLink a) async {
    await t.pumpWidget(const SizedBox());
    await a.link.dispose();
    await t.pump(const Duration(seconds: 10));
    AppLink.forgetForTest();
  }

  testWidgets('T-M1(a)(b): no lease on 4.1; 開始 acquires it; the result stage keeps it (one route), idle; 完成 releases it',
      (t) async {
    final w = World()..script('make', [ans('[NET_MADE] 網路已建立', rel: 'net/n1')]);
    final gate = Completer<void>();
    final a = await openForm(t, w, gate: gate);
    expect(a.reg.current, isNull, reason: '4.1 holds no lease while it shows the form');
    await start(t);
    final l = a.reg.current;
    expect(l, isNotNull);
    expect(l!.busy, isTrue, reason: 'working: a hold');
    expect(find.textContaining('最多 1 分鐘'), findsOneWidget); // #329 PR 6 (4.x_working): the limit once; PR 7: the connect step's own (§5.4)
    gate.complete();
    await settle(t);
    expect(find.text('完成'), findsWidgets);
    expect(identical(a.reg.current, l), isTrue, reason: 'v12 W-M1: the result stage still holds the lease');
    expect(l.busy, isFalse, reason: 'the hold was given back');
    expect(screen, [true, false], reason: 'keepScreenOn while working only');
    await t.tap(find.widgetWithText(FilledButton, Btn.done));
    await t.pumpAndSettle();
    await settle(t);
    expect(a.reg.current, isNull, reason: 'leaving the result page releases it');
    expect(a.reg.unsavedTodos, isEmpty);
    await finish(t, a);
  });

  testWidgets('T-M1(c): back does nothing while the run works (PopScope)', (t) async {
    final w = World()..script('make', [ans('[NET_MADE] 網路已建立', rel: 'net/n1')]);
    final gate = Completer<void>();
    final a = await openForm(t, w, gate: gate);
    await start(t);
    await back(t);
    expect(find.byType(NetRunPage), findsOneWidget);
    expect(find.textContaining('最多 1 分鐘'), findsOneWidget); // #329 PR 6 (4.x_working): the limit once; PR 7: the connect step's own (§5.4)
    expect(a.reg.current, isNotNull);
    gate.complete();
    await settle(t);
    await finish(t, a);
  });

  testWidgets('T-M1(g): the page gone mid-request: the lease waits for that request, then goes; no 「沒存完」 todo', (t) async {
    final w = World()
      ..holdMake = Completer<void>()
      ..script('make', [ans('[NET_MADE] 網路已建立', rel: 'net/n1')]);
    final a = await openForm(t, w);
    await start(t);
    await settle(t);
    final l = a.reg.current!;
    await t.pumpWidget(const SizedBox()); // every page disposed (the system closed them)
    expect(identical(a.reg.current, l), isTrue, reason: 'the request in progress still holds it');
    w.holdMake!.complete();
    await settle(t);
    expect(a.reg.current, isNull, reason: 'released once the request ended');
    expect(a.reg.unsavedTodos, isEmpty);
    expect(w.calls, ['make $id', 'close $id']);
    await finish(t, a);
  });

  testWidgets('D9: 開始 while another operation holds the radio -> 4.1 stays, the form kept, the reason shown', (t) async {
    final w = World();
    final a = await openForm(t, w);
    final other = (await t.runAsync(() => a.link.acquire('移除節點', LeaseKind.session)))!;
    await start(t);
    expect(find.textContaining('另一個操作還在進行：移除節點'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, Btn.start), findsOneWidget);
    expect(identical(a.reg.current, other), isTrue);
    await t.runAsync(other.release);
    await finish(t, a);
  });

  testWidgets('v14 AB-M1: 4.1 closed while it compares its snapshot -> the lease it took is released', (t) async {
    final w = World();
    final slow = Completer<NetSnapshot>();
    final a = await openForm(t, w, compute: () => slow.future);
    await start(t);
    expect(a.reg.current, isNotNull, reason: 'acquired, comparing');
    await t.pumpWidget(const SizedBox());
    slow.complete(const NetSnapshot());
    await settle(t);
    expect(a.reg.current, isNull);
    await finish(t, a);
  });

  testWidgets('§2.4: the records changed since the form was made -> not started, the lease released, the user told', (t) async {
    final w = World();
    final a = await openForm(t, w, compute: () async => const NetSnapshot(netFiles: 1));
    await start(t);
    await recomputed(t, a);
    expect(find.textContaining('網路紀錄剛剛變了'), findsOneWidget);
    expect(a.reg.current, isNull);
    expect(w.logins, isEmpty);
    await finish(t, a);
  });

  testWidgets('T-M1(h)/(i): result row -> 檢查網路 (borrowed) -> back keeps the lease; again -> 建立網路 -> 4.1 make mode, lease free',
      (t) async {
    final w = World()
      ..appliedAfterMake = false
      ..dac[id] = 'd4'
      ..script('make', [ans('[NET_STATE] 結果不明', rel: 'net/n1')])
      ..script('confirm', [ans('[NET_STATE] 沒有套用'), ans('[NET_STATE] 沒有套用，可以再建立一次')]);
    final a = await openForm(t, w,
        check: (l, i) => CheckRun(deps(w, l), id: i, snapshot: () async => NetSnapshot(netFiles: 1, nets: [pend('n1', 'd4')])));
    await start(t);
    await settle(t);
    final l = a.reg.current!;
    expect(find.widgetWithText(OutlinedButton, Btn.checkNetwork), findsOneWidget, reason: 'a written make row: 檢查網路 only');
    expect(find.text(Btn.retryNode), findsNothing);
    await t.tap(find.widgetWithText(OutlinedButton, Btn.checkNetwork));
    await t.pumpAndSettle();
    await back(t); // from the check page
    expect(identical(a.reg.current, l), isTrue, reason: '(h) the borrowing page never releases');
    expect(l.valid, isTrue);
    await t.tap(find.widgetWithText(OutlinedButton, Btn.checkNetwork));
    await t.pumpAndSettle();
    await t.tap(find.widgetWithText(FilledButton, Btn.start));
    await settle(t);
    expect(find.text(Btn.makeNetwork), findsWidgets);
    await t.tap(find.widgetWithText(TextButton, Btn.makeNetwork));
    await t.pumpAndSettle();
    await settle(t);
    expect(a.reg.current, isNull, reason: '(i) the result page went: its lease with it');
    await recomputed(t, a);
    expect(find.widgetWithText(FilledButton, Btn.start), findsOneWidget, reason: '4.1, make mode');
    await finish(t, a);
  });

  testWidgets('T-R1(a)(b): a check page with its own lease: chosen first, then the lease; back blocked while working; '
      '建立網路 -> popped, the lease released', (t) async {
    final w = World()
      ..dac[id] = 'd4'
      ..script('confirm', [ans('[NET_STATE] 沒有套用')]);
    final gate = Completer<void>();
    final a = app();
    String? popped;
    await t.pumpWidget(host(Builder(
        builder: (c) => Scaffold(
            body: TextButton(
                onPressed: () async => popped = await Navigator.of(c).push<String>(MaterialPageRoute(
                    builder: (_) => CheckNetPage(
                          app: a,
                          ui: UiState(MemStore()..ids = [id]),
                          preselect: id,
                          flow: (l, i) => CheckRun(deps(w, l, gate: gate), id: i, snapshot: () async => NetSnapshot(netFiles: 1, nets: [pend('n1', 'd4')])),
                        ))),
                child: const Text('open'))))));
    await t.tap(find.text('open'));
    await t.pumpAndSettle();
    expect(a.reg.current, isNull, reason: 'the node is shown before any lease');
    await t.tap(find.widgetWithText(FilledButton, Btn.start));
    await settle(t);
    expect(a.reg.current, isNotNull);
    await back(t);
    expect(find.textContaining('正在檢查節點'), findsOneWidget, reason: '(b) back blocked while working');
    gate.complete();
    await settle(t);
    await t.tap(find.widgetWithText(TextButton, Btn.makeNetwork));
    await t.pumpAndSettle();
    await settle(t);
    expect(popped, goMake);
    expect(a.reg.current, isNull);
    await finish(t, a);
  });

  testWidgets('§2.9: the 繼續 / 停 dialog closes as 停 when Bluetooth goes off while it is open', (t) async {
    final w = World()..script('join', [ans('[REQ_FAIL] x')]);
    final a = app();
    final l = (await t.runAsync(() => a.link.acquire('加入網路', LeaseKind.session)))!;
    await t.pumpWidget(host(NetRunPage(
      app: a,
      ui: UiState(MemStore()..ids = [id]),
      lease: l,
      ids: const [id, 'other'],
      makes: false,
      joinRel: 'net/a',
      flow: (go, _, _, _) => NetRun(deps(w, l, app: a), ids: const [id, 'other'], makes: false, joinRel: 'net/a', askGoOn: go),
    )));
    await settle(t);
    expect(find.text(Btn.nextNode), findsOneWidget, reason: 'asked');
    a.link.radio(bluetooth: false);
    await settle(t);
    expect(find.text(Btn.nextNode), findsNothing, reason: 'closed by the blocked radio');
    expect(find.textContaining('藍牙或權限現在不能用'), findsOneWidget);
    expect(w.logins, [id], reason: 'the next node never started');
    await finish(t, a);
  });

  testWidgets('code review B M3: 檢查網路 from 4.1 checks the creator found by name, not the ticked node', (t) async {
    final a = app();
    a.link.core.setRecords(const [Rec(id, 1), Rec('other', 1)]);
    final me = 'node-${id.substring(id.length - 4)}';
    final p = NetEntry('p1', NetView(netId: 'p1', meshId: 'bm', netName: 'n', applied: false, country: 'US', members: [
      MemberView(name: me, last4: '', deviceId: '', joining: true, prevCountry: '', dacHash: 'd4', creator: true, approved: false),
    ]));
    a.nets.setForTest(NetSnapshot(netFiles: 1, nets: [p]));
    await t.pumpWidget(host(NetFormPage(app: a, ui: UiState(MemStore()..ids = [id]), ticked: const {'other'})));
    await t.pump();
    await t.tap(find.widgetWithText(FilledButton, Btn.checkNetwork));
    await t.pumpAndSettle();
    expect(find.textContaining('檢查的是節點 ${id.substring(id.length - 4).toUpperCase()}'), findsOneWidget);
    await finish(t, a);
  });

  testWidgets('code review B M4: the link lost while the country question is open -> it closes; one 繼續 / 停 only', (t) async {
    final w = World()..script('join', [ans('[JOINED] 已加入')]);
    final a = app();
    final l = (await t.runAsync(() => a.link.acquire('加入網路', LeaseKind.session)))!;
    await t.pumpWidget(host(NetRunPage(
      app: a,
      ui: UiState(MemStore()..ids = [id]),
      lease: l,
      ids: const [id, 'other'],
      makes: false,
      joinRel: 'net/a',
      flow: (go, country, _, lost) {
        final d = w.deps;
        return NetRun(
            FlowDeps(
                login: d.login,
                console: (h) => _AskConsole(country, lost),
                applied: d.applied,
                blocked: () => a.link.core.blocked,
                leaseValid: () => l.valid),
            ids: const [id, 'other'],
            makes: false,
            joinRel: 'net/a',
            askGoOn: go);
      },
    )));
    await settle(t);
    expect(find.text(Btn.nextNode), findsOneWidget);
    expect(find.text('要改這台節點的國家嗎？'), findsNothing, reason: 'closed by the lost link, not left under it');
    expect(find.byType(AlertDialog), findsOneWidget);
    await t.tap(find.text(Btn.stopHere));
    await settle(t);
    await finish(t, a);
  });

  testWidgets('code review B m4: a new NetIndex result is the form\'s snapshot (開始 is not refused the first time)', (t) async {
    final w = World()..script('make', [ans('[NET_MADE] 網路已建立', rel: 'net/n1')]);
    final gate = Completer<void>();
    final a = await openForm(t, w, gate: gate, compute: () async => const NetSnapshot(netFiles: 1));
    a.nets.setForTest(const NetSnapshot(netFiles: 1)); // a record appeared meanwhile; the form follows it
    await t.pump();
    await start(t);
    expect(find.textContaining('網路紀錄剛剛變了'), findsNothing);
    expect(a.reg.current, isNotNull);
    gate.complete();
    await settle(t);
    await finish(t, a);
  });

  testWidgets('code review B m6: a node already a member of a network is not ticked, even read as 「not in a network」', (t) async {
    final a = app();
    a.link.core.states[id]!
      ..kind = Kind.read
      ..view = 'red'
      ..readAt = a.link.now()
      ..extra = sv('red', nodeState: 1)
      ..last = Concl.read;
    final n = NetEntry('n1', NetView(netId: 'n1', meshId: 'bm', netName: 'n', applied: true, country: 'US', members: [
      MemberView(name: 'x', last4: '', deviceId: id, joining: false, prevCountry: '', dacHash: '', creator: false, approved: false),
    ]));
    a.nets.setForTest(NetSnapshot(netFiles: 1, nets: [n]));
    await t.pumpWidget(host(NetFormPage(app: a, ui: UiState(MemStore()..ids = [id]))));
    await t.pump();
    expect(t.widget<CheckboxListTile>(find.byType(CheckboxListTile)).value, isFalse);
    await finish(t, a);
  });

  testWidgets('code review D M-1: the node marked 「由這台建立網路」 (list order) is the one that makes', (t) async {
    final w = World()..holdMake = Completer<void>();
    final a = app();
    const other = '0000000000000000001234'; // 節點 1234 sorts before 節點 7D2C
    a.link.core.setRecords(const [Rec(id, 1), Rec(other, 1)]);
    a.nets.setForTest(const NetSnapshot());
    await t.pumpWidget(host(Builder(
        builder: (c) => TextButton(
            onPressed: () => Navigator.of(c).push(MaterialPageRoute(
                builder: (_) => NetFormPage(
                    app: a,
                    ui: UiState(MemStore()..ids = [id, other]),
                    makes: true,
                    ticked: const {id, other}, // ticked in this order: id first
                    compute: () async => const NetSnapshot(),
                    runFlow: (l, go, _, _, _) => NetRun(deps(w, l), ids: const [other, id], makes: true, askGoOn: go)))),
            child: const Text('open')))));
    await t.tap(find.text('open'));
    await t.pumpAndSettle();
    expect(find.textContaining('由這台建立網路'), findsOneWidget);
    final marked = t.widget<CheckboxListTile>(find.ancestor(of: find.textContaining('由這台建立網路'), matching: find.byType(CheckboxListTile)));
    expect((marked.title as Text).data, '節點 1234');
    await start(t);
    expect(t.widget<NetRunPage>(find.byType(NetRunPage)).ids.first, other, reason: 'the marked one makes');
    w.holdMake!.complete();
    await settle(t);
    await finish(t, a);
  });


  testWidgets('device session 2026-11-16: networks with the same name are told apart (name, mesh id, state, nodes)', (t) async {
    final a = app();
    NetEntry e(String n, String mesh, int members) => NetEntry(
        n,
        NetView(netId: n, meshId: mesh, netName: 'Batman', applied: true, country: 'US', members: [
          for (var i = 0; i < members; i++)
            MemberView(name: 'm$i', last4: '', deviceId: 'd$i', joining: false, prevCountry: '', dacHash: '', creator: false, approved: false)
        ]));
    a.nets.setForTest(NetSnapshot(netFiles: 2, nets: [e('n1', 'bm-aaaa', 2), e('n2', 'bm-bbbb', 0)]));
    await t.pumpWidget(host(NetFormPage(app: a, ui: UiState(MemStore()..ids = [id]), ticked: const {id})));
    await t.pump();
    expect(find.text('Batman bm-aaaa（已建立，2 台）'), findsOneWidget);
    expect(find.text('Batman bm-bbbb（已建立，0 台）'), findsOneWidget);
    await finish(t, a);
  });
  testWidgets('code review C N-3: the network the user picked is gone -> no 開始 (never another network instead)', (t) async {
    final a = app();
    NetEntry e(String n) => NetEntry(n, NetView(netId: n, meshId: 'bm', netName: n, applied: true, country: 'US', members: const []));
    a.nets.setForTest(NetSnapshot(netFiles: 2, nets: [e('A'), e('B')]));
    await t.pumpWidget(host(NetFormPage(app: a, ui: UiState(MemStore()..ids = [id]), ticked: const {id})));
    await t.pump();
    await t.tap(find.textContaining('B bm（已建立'));
    await t.pump();
    a.nets.setForTest(NetSnapshot(netFiles: 2, nets: [e('A')])); // B no longer opens
    await t.pump();
    expect(t.widget<FilledButton>(find.widgetWithText(FilledButton, Btn.start)).onPressed, isNull);
    await finish(t, a);
  });

  testWidgets('code review C N-1 / D m-2: a blocked radio and a lost link in the same moment close the question once', (t) async {
    final a = app();
    final l = (await t.runAsync(() => a.link.acquire('加入網路', LeaseKind.session)))!;
    final w = World()..script('join', [ans('[JOINED] 已加入')]);
    void Function()? lostNow;
    await t.pumpWidget(host(NetRunPage(
      app: a,
      ui: UiState(MemStore()..ids = [id]),
      lease: l,
      ids: const [id],
      makes: false,
      joinRel: 'net/a',
      flow: (go, country, _, lost) {
        lostNow = lost;
        final d = w.deps;
        return NetRun(
            FlowDeps(
                login: d.login,
                console: (h) => _AskConsole(country, () {}),
                applied: d.applied,
                blocked: () => a.link.core.blocked,
                leaseValid: () => l.valid),
            ids: const [id],
            makes: false,
            joinRel: 'net/a',
            askGoOn: go);
      },
    )));
    await settle(t);
    expect(find.text('要改這台節點的國家嗎？'), findsOneWidget);
    a.link.radio(bluetooth: false); // the blocked notice and the lost link, in one moment
    lostNow!();
    await settle(t);
    expect(find.byType(NetRunPage), findsOneWidget, reason: 'the second close never pops the run page');
    await finish(t, a);
  });

  testWidgets('code review C N-5 / D m-3: a check page closed during its login: no confirm, its lease released', (t) async {
    final w = World()
      ..dac[id] = 'd4'
      ..script('confirm', [ans('[NET_STATE] 網路已建立')]);
    final gate = Completer<void>();
    final a = app();
    await t.pumpWidget(host(Builder(
        builder: (c) => TextButton(
            onPressed: () => Navigator.of(c).push(MaterialPageRoute(
                builder: (_) => CheckNetPage(
                    app: a,
                    ui: UiState(MemStore()..ids = [id]),
                    preselect: id,
                    flow: (l, i) => CheckRun(deps(w, l, gate: gate), id: i, snapshot: () async => NetSnapshot(netFiles: 1, nets: [pend('n1', 'd4')]))))),
            child: const Text('open')))));
    await t.tap(find.text('open'));
    await t.pumpAndSettle();
    await t.tap(find.widgetWithText(FilledButton, Btn.start));
    await settle(t);
    expect(a.reg.current, isNotNull);
    await t.pumpWidget(const SizedBox()); // the system closes the page while its login runs
    gate.complete();
    await settle(t);
    expect(w.confirmed, isEmpty);
    expect(a.reg.current, isNull);
    await finish(t, a);
  });
}

/// A console whose join asks the country, then loses its link while the question is open (code review B M4).
class _AskConsole implements OwnerConsole {
  _AskConsole(this.country, this.lost);
  final AskUser country;
  final void Function() lost;
  bool closed = false;
  @override
  bool get alive => !closed;
  @override
  Future<ConsoleReply> joinNetwork(String rel) async {
    final q = country('[COUNTRY] 要改成 US 嗎');
    Timer(const Duration(milliseconds: 300), lost); // the link goes while it is open
    await q;
    return const ConsoleReply(ReplyKind.unclear, '[JOIN_STATE] 結果不明', sessionAlive: false);
  }

  @override
  Future<void> close() async => closed = true;
  @override
  dynamic noSuchMethod(Invocation i) => throw UnimplementedError('${i.memberName}');
}
