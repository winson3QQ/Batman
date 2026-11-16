// #329 PR 4 §2.8: the update page from the node page. T-U1 the lease held while the page is open and given back when
// it closes (console first); every call on the update's own clock (review D M1). T-U2 a login gone while the page
// waits -> the next request logs in again (the reboot after 套用). T-U3 the home todo only for 「已準備、還沒套用」, gone
// when done. T-U5 去設定手機 Wi-Fi -> 5.6 after the update page's lease is back, the same update kept. Busy -> no page.
// Fake console: op_session_test's Fx; a scripted SwFlow / SwLink.
import 'package:batman_app/src/flows/owner_console.dart' show SwLink;
import 'package:batman_app/src/nodelink/app_link.dart';
import 'package:batman_app/src/rust/api/owner.dart' show OwnerSession;
import 'package:batman_app/src/rust/api/swupdate.dart';
import 'package:batman_app/src/rust/frb_generated.dart';
import 'package:batman_app/swupdate.dart';
import 'package:batman_app/ui/settings_pages.dart' show WifiPage;
import 'package:batman_app/ui/update_route.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../flows/op_session_test.dart' show Fx;
import '../flows/owner_console_pr4_test.dart' show FakeSwLink;
import '../nodes_update_send_test.dart' as nus show FakeRust;
import 'pages_test.dart' show app, host, id, keys;
import 'package:batman_app/ui/home_page.dart' show HomePage;
import 'package:batman_app/ui/node_page.dart' show NodePage;
import 'ui_state_test.dart' show MemStore;
import 'package:batman_app/ui/ui_state.dart';
import 'package:batman_app/secure_screen.dart';

SwAction act(SwKind k, {String text = '', List<SwButton> buttons = const [], int waitMs = 0}) => SwAction(
    kind: k,
    waitMs: BigInt.from(waitMs),
    note: '',
    text: text,
    tech: '',
    percent: -1,
    buttons: buttons,
    ip: '',
    port: 0,
    bearerHex: '',
    size: BigInt.zero,
    payload: 0,
    uploading: false);

/// The flow: start asks the node once; a press of 套用 asks again (the reboot wait).
class Flow implements SwFlow {
  final calls = <String>[];
  @override
  SwAction start() {
    calls.add('start');
    return act(SwKind.send, waitMs: 15000);
  }

  @override
  SwAction press(SwButton b, BigInt nowMs) {
    calls.add('press ${b.name}');
    return act(SwKind.send, waitMs: 15000);
  }

  @override
  dynamic noSuchMethod(Invocation i) => throw UnimplementedError('${i.memberName}');
}

/// The node's answers as the update reads them: first 「已準備」 (套用 offered), then done.
class Link extends FakeSwLink {
  final script = <SwAction>[
    act(SwKind.show_, text: '已準備好', buttons: [SwButton.apply]),
    act(SwKind.done, text: '更新完成'),
  ];
  @override
  SwAction answered(OwnerSession s, BigInt now) {
    super.answered(s, now);
    return script.removeAt(0);
  }

  @override
  SwAction noLink(BigInt now) {
    super.noLink(now);
    return act(SwKind.show_, text: '連不到節點', buttons: [SwButton.retry]);
  }
}

/// An update whose clock reads 4242 (the app clock in the Rig reads something else).
class Hold extends SwHold {
  Hold(super.flow);
  @override
  BigInt now() => BigInt.from(4242);
}

void main() {
  final rust = nus.FakeRust();
  setUpAll(() => RustLib.initMock(api: rust));

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

  Future<(Fx, AppLink, Link, Hold)> openIt(WidgetTester t, {int logins = 3}) async {
    t.binding.defaultBinaryMessenger.setMockMethodCallHandler(swChannel, (c) async => null);
    t.binding.defaultBinaryMessenger.setMockMethodCallHandler(secureChannel, (c) async => true);
    final f = Fx(rust, logins: logins);
    final a = app();
    final link = Link();
    final hold = Hold(Flow());
    await t.pumpWidget(host(Builder(
        builder: (c) => TextButton(
            onPressed: () => openSwUpdate(c, a, UiState(MemStore()), id,
                deps: f.d, make: () => (link as SwLink, hold), specifier: () => 'leave the Wi-Fi'),
            child: const Text('node')))));
    await t.tap(find.text('node'));
    await settle(t, f);
    return (f, a, link, hold);
  }

  testWidgets('T-U1: the lease is held while the page is open, released (console first) when it closes; the update clock',
      (t) async {
    final (f, a, link, _) = await openIt(t);
    expect(find.text('已準備好'), findsOneWidget);
    expect(f.reg.current, isNotNull, reason: 'held while the page is open, idle included (Fx hands out the Rig lease)');
    expect(link.nows, [BigInt.from(4242)], reason: 'review D M1: the update clock, never the app clock');
    await t.state<NavigatorState>(find.byType(Navigator)).maybePop();
    await settle(t, f);
    expect(f.reg.current, isNull);
    expect(f.rigs.first.c.alive, isFalse);
    expect(find.text('node'), findsOneWidget);
    expect(a.sw.unfinished(id), isTrue, reason: 'prepared, not applied: kept for the home todo');
  });

  testWidgets('T-U2: the login went away while the page waited -> 套用 logs in again', (t) async {
    final (f, _, link, _) = await openIt(t);
    f.rigs.first.radio.drop(); // the node closed the idle login (300 s) — or rebooted
    await settle(t, f);
    await t.tap(find.text('套用並重開'));
    await settle(t, f);
    expect(f.logins, 2);
    expect(find.text('更新完成'), findsOneWidget);
    expect(link.answers, 2);
  });

  testWidgets('review C m8: each new action of the page notifies AppLink.sw (the home todo follows)', (t) async {
    final (f, a, _, _) = await openIt(t);
    var n = 0;
    a.sw.addListener(() => n++);
    await t.tap(find.text('套用並重開'));
    await settle(t, f);
    expect(n, greaterThan(0));
  });

  testWidgets('T-U3: done -> the update leaves AppLink.sw when the page closes', (t) async {
    final (f, a, _, _) = await openIt(t);
    await t.tap(find.text('套用並重開'));
    await settle(t, f);
    expect(a.sw.unfinished(id), isFalse, reason: 'no 套用 left');
    await t.tap(find.text('關閉'));
    await settle(t, f);
    expect(a.sw.of(id), isNull);
  });

  testWidgets('T-U3: the todo condition is Rust\'s 套用 button, not the picked files', (t) async {
    final a = app();
    final h = SwHold(Flow());
    a.sw.take(id, () => (FakeSwLink(), h));
    h.uris = ['content://p'];
    h.last = act(SwKind.show_, buttons: [SwButton.pick]); // abandoned: files were picked, nothing prepared
    expect(a.sw.unfinished(id), isFalse);
    h.last = act(SwKind.show_, buttons: [SwButton.applyAnyway, SwButton.abandon]);
    expect(a.sw.unfinished(id), isTrue);
    expect(a.sw.unfinishedIds, [id]);
    AppLink.forgetForTest();
  });

  testWidgets('T-U3: the home page shows 「軟體更新還沒做完」 for a prepared update; the node page says 還沒做完', (t) async {
    final a = app();
    final h = SwHold(Flow())..last = act(SwKind.show_, buttons: [SwButton.apply]);
    a.sw.take(id, () => (FakeSwLink(), h));
    await t.pumpWidget(host(HomePage(app: a, ui: UiState(MemStore()), devTrust: false, keys: keys())));
    await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
    await t.pump();
    expect(find.text('軟體更新還沒做完'), findsOneWidget);
    await t.pumpWidget(host(NodePage(app: a, id: id, ui: UiState(MemStore()))));
    expect(find.textContaining('還沒做完'), findsOneWidget);
    h.last = act(SwKind.done);
    a.sw.touched();
    await t.pumpWidget(host(HomePage(app: a, ui: UiState(MemStore()), devTrust: false, keys: keys())));
    await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
    await t.pump();
    expect(find.text('軟體更新還沒做完'), findsNothing);
    a.link.dispose();
    await t.pumpWidget(const SizedBox());
    await t.pump(const Duration(seconds: 10));
    AppLink.forgetForTest();
  });

  testWidgets('another operation holds the lease -> no update page', (t) async {
    t.binding.defaultBinaryMessenger.setMockMethodCallHandler(swChannel, (c) async => null);
    final f = Fx(rust)..busy = true;
    final a = app();
    await t.pumpWidget(host(Scaffold(
        body: Builder(
            builder: (c) => TextButton(
                onPressed: () => openSwUpdate(c, a, UiState(MemStore()), id,
                    deps: f.d, make: () => (Link() as SwLink, Hold(Flow())), specifier: () => ''),
                child: const Text('node'))))));
    await t.tap(find.text('node'));
    await settle(t, f);
    expect(find.byType(SwUpdatePage), findsNothing);
    expect(find.textContaining('另一個操作還在進行'), findsOneWidget);
  });

  testWidgets('T-U5: 去設定手機 Wi-Fi -> 5.6, the update page\'s lease given back first; the same update kept', (t) async {
    final (f, a, link, hold) = await openIt(t);
    link.script.insert(0, act(SwKind.show_, text: '要先設定手機 Wi-Fi', buttons: [SwButton.setAp]));
    await t.tap(find.text('套用並重開'));
    await settle(t, f);
    await t.tap(find.text('去設定手機 Wi-Fi'));
    await settle(t, f);
    expect(find.byType(WifiPage), findsOneWidget);
    expect(identical(a.sw.of(id)?.$2, hold), isTrue);
  });
}
