// #329 PR 4 §2.4 / §2.5: boards 5.6 (phone Wi-Fi) and 5.8 (country) on OpSession with a fake console (op_session_test's
// Fx: owner_console_test's Rig per login). T-W1 the node's rules, T-W2 the field emptied only after the login, T-W3
// 「結果不明」 + 重新讀取, T-W5 the passphrase in no log / reply and the field's flags, T-W6 the country menu's limits,
// T-W7 the confirm dialog, T-W8 the lease released after each read.
import 'package:batman_app/secure_screen.dart';
import 'package:batman_app/src/nodelink/app_link.dart';
import 'package:batman_app/src/nodelink/core.dart';
import 'package:batman_app/src/nodelink/node_link.dart' show LoginForEnd;
import 'package:batman_app/src/rust/frb_generated.dart';
import 'package:batman_app/ui/settings_pages.dart';
import 'package:batman_app/ui/ui_state.dart';
import 'package:batman_app/ui/widgets.dart' show BatRow;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../flows/op_session_test.dart' show Fx;
import '../flows/owner_console_pr4_test.dart' show P4Session;
import '../nodes_update_send_test.dart' as nus show FakeRust;
import 'pages_test.dart' show app, host, id, sv;
import 'ui_state_test.dart' show MemStore;

const secret = 'correct-horse-1';

void main() {
  final rust = nus.FakeRust();
  setUpAll(() => RustLib.initMock(api: rust));

  Future<void> allowSecure(WidgetTester t) async =>
      t.binding.defaultBinaryMessenger.setMockMethodCallHandler(secureChannel, (c) async => true);

  // the fake links run on their own clocks, outside the widget test's fake time (their close waits on them)
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

  Future<Fx> openWifi(WidgetTester t, {int logins = 2}) async {
    await allowSecure(t);
    final f = Fx(rust, logins: logins);
    final a = app();
    await t.pumpWidget(host(WifiPage(app: a, ui: UiState(MemStore()), id: id, deps: f.d)));
    await settle(t, f);
    return f;
  }

  /// [page] pushed over a base route (back on a root route never pops: a PopScope test needs a route under it)
  Future<void> pushed(WidgetTester t, Widget page) async {
    await t.pumpWidget(host(Builder(
        builder: (c) => TextButton(
            onPressed: () => Navigator.of(c).push(MaterialPageRoute(builder: (_) => page)), child: const Text('base')))));
    await t.tap(find.text('base'));
    await t.pump();
    await t.pump(const Duration(seconds: 1));
  }

  TextField field(WidgetTester t, String key) => t.widget<TextField>(find.byKey(Key(key)));
  bool sendEnabled(WidgetTester t) => t.widget<FilledButton>(find.widgetWithText(FilledButton, '送出')).onPressed != null;

  group('5.6 phone Wi-Fi', () {
    testWidgets('the current name is read (one operation, lease released) and fills the name field', (t) async {
      final f = await openWifi(t);
      expect(find.text('node-ap'), findsWidgets);
      expect(field(t, 'wifi-ssid').controller!.text, 'node-ap');
      expect(f.reg.current, isNull, reason: 'T-W8: the read gave the lease back');
      expect((f.rigs.first.session as P4Session).asked, ['settings/get']);
    });

    for (final (ssid, pass, ok) in [
      ('node-ap', 'abcdefghijk', false), // 11
      ('node-ap', 'abcdefghijkl', true), // 12
      ('node-ap', 'a' * 63, true),
      ('node-ap', 'a' * 64, false),
      ('node-ap', 'abc def ghijkl', false), // a blank
      ('node-ap', 'abcdefghijk#', false), // outside the set
      ('node-ap', 'CHANGE-ME-NOW', false), // the placeholder (review A m2)
      (' node-ap', 'abcdefghijkl', false),
      ('node-ap ', 'abcdefghijkl', false),
      ('node ap', 'abcdefghijkl', true), // a blank inside the name is fine
      ('a' * 33, 'abcdefghijkl', false),
      ('', 'abcdefghijkl', false),
      ('節點', 'abcdefghijkl', false),
    ]) {
      testWidgets('T-W1: "$ssid" / ${pass.length} chars -> ${ok ? 'can send' : 'cannot'}', (t) async {
        await openWifi(t);
        await t.enterText(find.byKey(const Key('wifi-ssid')), ssid);
        await t.enterText(find.byKey(const Key('wifi-pass')), pass);
        await t.pump();
        expect(sendEnabled(t), ok);
      });
    }

    testWidgets('T-W2 / T-W5: sent -> 已更新; the field is empty; the passphrase is in no log line', (t) async {
      final logs = <String>[];
      final saved = debugPrint;
      debugPrint = (String? m, {int? wrapWidth}) => logs.add(m ?? '');
      try {
      final f = await openWifi(t);
      await t.enterText(find.byKey(const Key('wifi-pass')), secret);
      await t.pump();
      await t.tap(find.widgetWithText(FilledButton, '送出'));
      await settle(t, f);
      expect(find.textContaining('已更新'), findsOneWidget);
      expect(field(t, 'wifi-pass').controller!.text, isEmpty);
      expect((f.rigs[1].session as P4Session).asked, ['settings/set ap node-ap']);
      expect(logs.join('\n'), isNot(contains(secret)));
      expect(f.reg.current, isNull);
      } finally {
        debugPrint = saved; // restored inside the test (the binding checks it)
      }
    });

    testWidgets('T-W2 (review D m6): a login that fails leaves the passphrase in the field (nothing sent)', (t) async {
      final f = await openWifi(t);
      f.loginEnd = LoginForEnd.notFound;
      await t.enterText(find.byKey(const Key('wifi-pass')), secret);
      await t.pump();
      await t.tap(find.widgetWithText(FilledButton, '送出'));
      await settle(t, f);
      expect(field(t, 'wifi-pass').controller!.text, secret);
      expect(find.textContaining('沒有找到這台節點'), findsOneWidget);
    });

    testWidgets('T-W3: lost after the sent write -> 結果不明 and 重新讀取', (t) async {
      final f = await openWifi(t);
      f.rigs[1].radio.silent = true;
      await t.enterText(find.byKey(const Key('wifi-pass')), secret);
      await t.pump();
      await t.tap(find.widgetWithText(FilledButton, '送出'));
      await settle(t, f);
      f.rigs[1].radio.drop();
      await settle(t, f);
      expect(find.textContaining('結果不明 — 請重新讀取設定'), findsOneWidget);
      expect(find.widgetWithText(TextButton, '重新讀取'), findsOneWidget);
    });

    testWidgets('the node refuses -> its reason, never 已更新', (t) async {
      final f = await openWifi(t);
      (f.rigs[1].session as P4Session).setAnswer = 'error';
      await t.enterText(find.byKey(const Key('wifi-pass')), secret);
      await t.pump();
      await t.tap(find.widgetWithText(FilledButton, '送出'));
      await settle(t, f);
      expect(find.textContaining('節點不接受這個值'), findsOneWidget);
      expect(find.textContaining('已更新'), findsNothing);
    });

    testWidgets('T-W5: the passphrase field cannot be copied, autofilled or learned; shown = the visible-password keyboard',
        (t) async {
      await openWifi(t);
      var p = field(t, 'wifi-pass');
      expect((p.obscureText, p.enableInteractiveSelection, p.autofillHints, p.enableIMEPersonalizedLearning, p.enableSuggestions),
          (true, false, null, false, false));
      await t.tap(find.byKey(const Key('wifi-show')));
      await t.pump();
      p = field(t, 'wifi-pass');
      expect((p.obscureText, p.keyboardType), (false, TextInputType.visiblePassword));
    });

    testWidgets('code review A m5: while sending, back does not close the page; the fields cannot change (B m7)', (t) async {
      await allowSecure(t);
      final f = Fx(rust);
      await pushed(t, WifiPage(app: app(), ui: UiState(MemStore()), id: id, deps: f.d));
      await settle(t, f);
      f.rigs[1].radio.silent = true;
      await t.enterText(find.byKey(const Key('wifi-pass')), secret);
      await t.pump();
      await t.tap(find.widgetWithText(FilledButton, '送出'));
      await settle(t, f);
      expect(field(t, 'wifi-ssid').enabled, isFalse);
      await t.state<NavigatorState>(find.byType(Navigator)).maybePop();
      await t.pump(const Duration(seconds: 1));
      await t.pump(); // a popped route goes on the frame after its transition
      await t.pump(const Duration(seconds: 5));
      expect(find.byType(WifiPage), findsOneWidget);
    });

    testWidgets('the page is a SecureScreen', (t) async {
      await openWifi(t);
      expect(find.byType(SecureScreen), findsOneWidget);
    });
  });

  group('5.8 country', () {
    Future<(Fx, Object)> openCountry(WidgetTester t, {int nodeState = 1, bool fresh = true, bool push = false}) async {
      final f = Fx(rust);
      final a = app();
      final s = a.link.core.states[id]!;
      {
        s
          ..kind = Kind.read
          ..view = 'yellow'
          ..readAt = fresh ? a.link.now() : a.link.now() - 400000 // older than NodeLink's 300 s
          ..extra = sv('yellow', nodeState: nodeState)
          ..last = Concl.read;
      }
      final page = CountryPage(app: a, ui: UiState(MemStore()), id: id, deps: f.d);
      if (push) {
        await pushed(t, page);
      } else {
        await t.pumpWidget(host(page));
      }
      await settle(t, f);
      return (f, a);
    }

    bool rowEnabled(WidgetTester t, String cc) => t.widget<BatRow>(find.byKey(Key('country-$cc'))).enabled;

    testWidgets('T-W7: a fresh read, not in a network -> TW confirmed -> settings/set TW -> 已更新', (t) async {
      final (f, _) = await openCountry(t);
      expect(find.text('美國 US'), findsWidgets);
      expect(rowEnabled(t, 'TW'), isTrue);
      await t.tap(find.byKey(const Key('country-TW')));
      await t.pumpAndSettle();
      expect(find.textContaining('從 美國 US 改成 台灣 TW'), findsOneWidget);
      await t.tap(find.widgetWithText(FilledButton, '改'));
      await settle(t, f);
      expect((f.rigs[1].session as P4Session).asked, ['settings/set country TW']);
      expect(find.text('已更新。'), findsOneWidget);
    });

    testWidgets('T-W7: 取消 sends nothing', (t) async {
      final (f, _) = await openCountry(t);
      await t.tap(find.byKey(const Key('country-TW')));
      await t.pumpAndSettle();
      await t.tap(find.widgetWithText(TextButton, '取消'));
      await settle(t, f);
      expect(f.logins, 1, reason: 'only the read logged in');
    });

    testWidgets('T-W6: in a network -> the menu cannot be used, and says why', (t) async {
      final (f, _) = await openCountry(t, nodeState: 2);
      expect(rowEnabled(t, 'TW'), isFalse);
      expect(find.text('要先離開網路才能改國家。'), findsOneWidget);
      await t.tap(find.byKey(const Key('country-TW')));
      await t.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
      expect(f.logins, 1);
    });

    testWidgets('code review A m2: the menu follows the NodeLink reads while the page is open', (t) async {
      final (_, ao) = await openCountry(t, nodeState: 2);
      final a = ao as AppLink;
      expect(rowEnabled(t, 'TW'), isFalse);
      a.link.core.states[id]!.extra = sv('yellow', nodeState: 1); // the next read: not in a network any more
      a.link.radio(); // nothing changes in NodeLink but it tells its listeners
      await t.pump();
      await t.pump(); // the stream delivers after this frame
      expect(rowEnabled(t, 'TW'), isTrue);
      await a.link.dispose();
    });

    testWidgets('code review A m2 / B m8: the outcome not known -> 重新讀取', (t) async {
      final (f, _) = await openCountry(t);
      f.rigs[1].radio.silent = true;
      await t.tap(find.byKey(const Key('country-TW')));
      await t.pumpAndSettle();
      await t.tap(find.widgetWithText(FilledButton, '改'));
      await settle(t, f);
      f.rigs[1].radio.drop();
      await settle(t, f);
      expect(find.textContaining('結果不明'), findsOneWidget);
      expect(find.widgetWithText(OutlinedButton, '重新讀取'), findsOneWidget);
    });

    testWidgets('code review A m5: while sending, back does not close the page', (t) async {
      final (f, _) = await openCountry(t, push: true);
      f.rigs[1].radio.silent = true;
      await t.tap(find.byKey(const Key('country-TW')));
      await t.pumpAndSettle();
      await t.tap(find.widgetWithText(FilledButton, '改'));
      await settle(t, f);
      await t.state<NavigatorState>(find.byType(Navigator)).maybePop();
      await t.pump(const Duration(seconds: 1));
      await t.pump(); // a popped route goes on the frame after its transition
      await t.pump(const Duration(seconds: 5));
      expect(find.byType(CountryPage), findsOneWidget);
    });

    testWidgets('T-W6: no fresh read of the node -> the menu cannot be used', (t) async {
      await openCountry(t, fresh: false);
      expect(rowEnabled(t, 'TW'), isFalse);
      expect(find.textContaining('先讓手機讀到這台的狀態'), findsOneWidget);
    });

    testWidgets('T-W6: the settings could not be read -> the menu cannot be used, 重新讀取', (t) async {
      final f = Fx(rust)..loginEnd = LoginForEnd.notFound;
      final a = app();
      a.link.core.states[id]! // a fresh read, not in a network: only the settings read is missing
        ..kind = Kind.read
        ..view = 'yellow'
        ..readAt = a.link.now()
        ..extra = sv('yellow', nodeState: 1)
        ..last = Concl.read;
      await t.pumpWidget(host(CountryPage(app: a, ui: UiState(MemStore()), id: id, deps: f.d)));
      await settle(t, f);
      expect(rowEnabled(t, 'TW'), isFalse);
      expect(find.textContaining('讀不到目前的國家'), findsOneWidget);
      expect(find.widgetWithText(OutlinedButton, '重新讀取'), findsOneWidget);
    });
  });
}
