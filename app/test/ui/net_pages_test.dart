// #329 PR 3 §2.5 / §2.8 / §3.2: the network pages on the real AppLink (lease registry, NodeLink, real Navigator) with
// fake flows (net_run_test's World). What is asserted is who holds the lease when: T-M1 (a)-(i), T-R1, and the 4.1
// hand-over (v14 AB-M1), the 開始 refusal (D9), the dialog closed by a blocked radio (§2.9), keepScreenOn.
import 'dart:async';

import 'package:batman_app/src/flows/net_index.dart';
import 'package:batman_app/src/flows/net_run.dart';
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
import 'pages_test.dart' show FakeRust, app, host, id;
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
      {Completer<void>? gate, Future<NetSnapshot> Function()? compute, CheckRun Function(Lease, String, bool)? check}) async {
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
                          runFlow: (l, go, _, _) => NetRun(deps(w, l, gate: gate), ids: const [id], makes: true, askGoOn: go),
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
    expect(find.text('請留在這個畫面'), findsOneWidget);
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
    expect(find.text('請留在這個畫面'), findsOneWidget);
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
        check: (l, i, picked) => CheckRun(deps(w, l), id: i, picked: picked, snapshot: () async => NetSnapshot(netFiles: 1, nets: [pend('n1', 'd4')])));
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
                          flow: (l, i, p) => CheckRun(deps(w, l, gate: gate), id: i, picked: p, snapshot: () async => NetSnapshot(netFiles: 1, nets: [pend('n1', 'd4')])),
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
      flow: (go, _, _) => NetRun(deps(w, l, app: a), ids: const [id, 'other'], makes: false, joinRel: 'net/a', askGoOn: go),
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
}
