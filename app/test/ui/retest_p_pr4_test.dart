// #329 補測 A（PR 4 守衛，2026-11-17）: the PR 4 guards that had no failing test (listed on #329).
// - `link.refresh()` after a leave (more_pages.dart _LeavePageState._leave): the node's 「不是 Y」 memo is cleared and a
//   round may start at once — observed through NodeLinkCore.notY (core.refresh clears it).
// - `openSwUpdate`'s `context.mounted` branch (update_route.dart): the page that asked is gone while the lease is being
//   taken -> the session is given back (the lease released), no update is taken, no page is pushed.
// - `SwHolds.take`'s done check (sw_holds.dart): an update that ended (done) is never taken up again; a new one is made.
// Fake console: op_session_test's Fx.
import 'dart:async';

import 'package:batman_app/src/flows/op_session.dart';
import 'package:batman_app/src/flows/owner_console.dart' show SwLink;
import 'package:batman_app/src/flows/sw_holds.dart';
import 'package:batman_app/src/nodelink/app_link.dart';
import 'package:batman_app/src/rust/api/swupdate.dart';
import 'package:batman_app/src/rust/frb_generated.dart';
import 'package:batman_app/secure_screen.dart';
import 'package:batman_app/swupdate.dart';
import 'package:batman_app/ui/more_pages.dart';
import 'package:batman_app/ui/ui_state.dart';
import 'package:batman_app/ui/update_route.dart';
import 'package:batman_app/ui/widgets.dart' show Btn;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../flows/op_session_test.dart' show Fx;
import '../flows/owner_console_pr4_test.dart' show FakeSwLink;
import 'more_pages_test.dart' show Rust, read, view;
import 'pages_test.dart' show app, host, id;
import 'ui_state_test.dart' show MemStore;
import 'update_route_test.dart' as ur show Flow, act;

void main() {
  final rust = Rust();
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

  Future<void> finish(WidgetTester t, AppLink a) async {
    await t.pumpWidget(const SizedBox());
    await a.link.dispose();
    await t.pump(const Duration(seconds: 10));
    AppLink.forgetForTest();
  }

  testWidgets('retest-p PR4 link.refresh(): after a leave the node is read again (its 「不是 Y」 memo cleared)', (t) async {
    final f = Fx(rust);
    final a = app();
    read(a, view(netId: 'ab12'));
    a.link.core.notY['AA:BB'] = {id}; // a memo from before: this address is not this node
    await t.pumpWidget(host(LeavePage(app: a, ui: UiState(MemStore()), id: id, deps: f.d)));
    await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
    await t.pump();
    expect(a.link.core.notY, isNotEmpty);
    await t.tap(find.widgetWithText(FilledButton, Btn.leaveNetwork));
    await settle(t, f);
    expect(find.text('已離開隊伍網路'), findsOneWidget, reason: 'the leave ran');
    expect(a.link.core.notY, isEmpty, reason: 'refresh() after the leave (core.refresh clears the memo)');
    await finish(t, a);
  });

  testWidgets('retest-p PR4 context.mounted: the asking page gone while the lease is taken -> the session given back, no page',
      (t) async {
    t.binding.defaultBinaryMessenger.setMockMethodCallHandler(swChannel, (c) async => null);
    t.binding.defaultBinaryMessenger.setMockMethodCallHandler(secureChannel, (c) async => true);
    final f = Fx(rust);
    final a = app();
    final gate = Completer<void>();
    final d = OpDeps(
      acquire: (n) async {
        await gate.future; // the lease comes after the page is gone
        return f.d.acquire(n);
      },
      busyName: f.d.busyName,
      login: f.d.login,
      console: f.d.console,
      keepScreen: f.d.keepScreen,
    );
    var made = 0;
    Object? error;
    await t.pumpWidget(host(Builder(
        builder: (c) => TextButton(
            onPressed: () => openSwUpdate(c, a, UiState(MemStore()), id, deps: d, make: () {
                  made++;
                  return (FakeSwLink() as SwLink, SwHold(ur.Flow()));
                }, specifier: () => 'x').catchError((Object e) => error = e),
            child: const Text('node')))));
    await t.tap(find.text('node'));
    await t.pump();
    await t.pumpWidget(const SizedBox()); // the node page is gone
    gate.complete();
    await settle(t, f);
    expect(error, isNull, reason: 'nothing is pushed on a page that is gone');
    expect(f.reg.current, isNull, reason: 'the session given back: its lease released');
    expect(made, 0, reason: 'no update taken');
    expect(a.sw.of(id), isNull);
    expect(find.byType(SwUpdatePage), findsNothing);
    await finish(t, a);
  });

  test('retest-p PR4 SwHolds.take: an update that ended (done) is not taken up again; one half-way is', () {
    final s = SwHolds();
    final first = (FakeSwLink() as SwLink, SwHold(ur.Flow()));
    expect(identical(s.take('a', () => first), first), isTrue);
    final again = (FakeSwLink() as SwLink, SwHold(ur.Flow()));
    first.$2.last = ur.act(SwKind.show_, buttons: [SwButton.apply]); // half-way: kept
    expect(identical(s.take('a', () => again), first), isTrue, reason: 'half-way: the same update');
    first.$2.last = ur.act(SwKind.done, text: '更新完成'); // done
    final fresh = (FakeSwLink() as SwLink, SwHold(ur.Flow()));
    final got = s.take('a', () => fresh);
    expect(identical(got, fresh), isTrue, reason: 'a done update is replaced by a new one');
    expect(identical(s.of('a'), fresh), isTrue);
  });
}
