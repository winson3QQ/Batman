// #329 PR 6 §3 / §7 (T9 boards): the PR 6 pages the board files do not have, with a fake console that logs in
// (op_session_test's Fx, the same as settings_pages_test) where the page reads a node:
// - 5.6 phone Wi-Fi and 5.8 country with the current values read (retest_s_boards_test.dart only has their busy state);
//   5.8 also with the node still set to TW (the menu is US only, TW shown as not in the list);
// - 10.5 診斷; the developer options' SSH 金鑰 (two good lines with their fingerprints, one bad line), 查看節點設定 (a
//   read value), 忘記加入中的節點 (one orphan, and its dialog) and 文字紀錄.
// Rendered at 412×915, light and dark; each board: no overflow and its own check; one PNG each when BOARDS_OUT is set
// (retest_s_shot.dart).
import 'package:batman_app/key_abilities.dart';
import 'package:batman_app/secure_screen.dart';
import 'package:batman_app/src/flows/net_index.dart';
import 'package:batman_app/src/nodelink/app_link.dart';
import 'package:batman_app/src/nodelink/core.dart';
import 'package:batman_app/src/rust/api/owner.dart' show SettingsView, StatusView;
import 'package:batman_app/src/rust/frb_generated.dart';
import 'package:batman_app/ui/dev_pages.dart';
import 'package:batman_app/ui/diag_page.dart';
import 'package:batman_app/ui/settings_pages.dart';
import 'package:batman_app/ui/theme.dart';
import 'package:batman_app/ui/ui_state.dart';
import 'package:batman_app/ui/widgets.dart' show BatButton, BatRow;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../flows/op_session_test.dart' show Fx;
import '../flows/owner_console_pr4_test.dart' show P4Session;
import '../retest_s_shot.dart';
import 'pages_test.dart' show app, id, sv;
import 'pr6_dev_test.dart' show DevRust, f1, f2, k1, k2, member, mockChannels, net;
import 'ui_state_test.dart' show MemStore;

/// A board: the page (with the app and the fake console it uses), an optional step after the first frames, its check.
class P6 {
  const P6(this.build, {this.act, required this.check});
  final Widget Function(AppLink a, Fx f, UiState ui) build;
  final Future<void> Function(WidgetTester t, Fx f)? act;
  final void Function(WidgetTester t) check;
}

void main() {
  final rust = DevRust(); // the fake node library's FakeRust, plus the SSH line check and fingerprints
  setUpAll(() async {
    RustLib.initMock(api: rust);
    await loadFonts();
  });

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

  Future<void> pick(WidgetTester t) async {
    await t.tap(find.byKey(const Key('pick-$id')));
    await t.pump();
  }

  /// The node set to [cc] (what settings/get answers).
  void country(Fx f, String cc) => (f.rigs[0].session as P4Session).now =
      SettingsView(read: true, name: 'BCM2711-6c89', country: cc, channel: 42, bwMhz: 2, apSsid: 'node-ap');

  KeyAbilities soft() => KeyAbilities.from({
        'RECORD_AES': 1, 'OWNER_SIGN': 1, 'ADMIN_SIGN': 1, 'OWNER_ENC': 0, 'appUsable': true, 'claim': true,
        'login': true, 'recover': true, 'makeNetwork': true, 'softOwnerEnc': true,
      });

  final orphan = JoinTodo(NetEntry('n1', net(const [])), member('dev0000b', 'dB'));

  // file name (ASCII) -> board
  final boards = <String, P6>{
    'phone_wifi_read': P6((a, f, ui) => WifiPage(app: a, ui: ui, id: id, deps: f.d), check: (t) {
      // the values were read (not the busy board): the fake console answers name node-ap
      expect(find.textContaining('node-ap'), findsWidgets);
      expect(find.textContaining('另一個操作還在進行'), findsNothing);
    }),
    'country_read': P6((a, f, ui) => CountryPage(app: a, ui: ui, id: id, deps: f.d), check: (t) {
      expect(find.textContaining('美國 US'), findsWidgets);
      expect(find.textContaining('另一個操作還在進行'), findsNothing);
    }),
    // D11: only US in the menu; a node still set to TW shows it as not in the list
    'country_tw_read': P6((a, f, ui) {
      country(f, 'TW');
      return CountryPage(app: a, ui: ui, id: id, deps: f.d);
    }, check: (t) {
      expect(t.widget<BatRow>(find.byKey(const Key('country-now'))).right, 'TW（不在可選清單）');
      expect(find.byKey(const Key('country-US')), findsOneWidget);
      expect(find.byKey(const Key('country-TW')), findsNothing);
      expect(find.textContaining('台灣 TW'), findsNothing);
    }),
    // D6 (10.5): version, flavor, the key abilities with the software-only warning, each node's technical lines
    '10.5_diagnostics': P6((a, f, ui) {
      a.link.core.states[id]!.extra = StatusView(
          color: 'green', row: '3', sentence: 'x', lagNote: '', warning: '', nodeState: 2, netId: '', version: '',
          tech: const ['軟體版本 1.4.12', 'image openmanet-24.10 bcm2711', 'mesh bm-0123456789ab', '回覆\u001e代碼 7\u001f'],
          fresh: true, rateNote: '', unfinished: '', unfinishedUnderVerdict: false, canLeave: false);
      return DiagPage(app: a, keys: soft());
    }, check: (t) {
      expect(find.text('1.6.0+12'), findsOneWidget);
      expect(find.text(softKeyWarning), findsOneWidget);
      expect(find.text('節點 …7D2C'), findsOneWidget);
      expect(find.text('回覆〔代碼 7〕'), findsOneWidget);
    }),
    // D2: two good lines with their fingerprints, one bad line (why), the send button off
    'dev_ssh_keys': P6((a, f, ui) => SshKeysPage(app: a, ui: ui, deps: f.d), act: (t, f) async {
      await pick(t);
      await t.enterText(find.byKey(const Key('ssh-lines')), '$k1\n$k2\nssh-rsa AAAAB3NzaC1yc2E x');
      await t.pump();
      await t.pump(const Duration(milliseconds: 300)); // the field's label animation to its floating place
    }, check: (t) {
      expect(find.text('第 1 行：$f1'), findsOneWidget);
      expect(find.text('第 2 行：$f2'), findsOneWidget);
      expect(find.text('第 3 行不合格：不是節點接受的格式：要是 ssh-ed25519 公鑰，後面的註解最多 40 個可列印 ASCII 字元'), findsOneWidget);
      expect(find.text(sshReplaceNote), findsOneWidget);
      expect(t.widget<BatButton>(find.byKey(const Key('ssh-send'))).onPressed, isNull);
    }),
    // D3: one read value (Rust's settings_text shape), copyable
    'dev_node_settings': P6((a, f, ui) {
      (f.rigs[0].session as P4Session).getDetail =
          '目前設定：名稱 BCM2711-6c89，國家 US，HaLow 無線電 頻道 42（2 MHz），給手機連的 Wi-Fi「node-ap」';
      return NodeSettingsPage(app: a, ui: ui, deps: f.d);
    }, act: (t, f) async {
      await pick(t);
      await t.tap(find.byKey(const Key('settings-read')));
      await settle(t, f);
    }, check: (t) {
      expect(t.widget<SelectableText>(find.byKey(const Key('settings-text'))).data,
          '目前設定：名稱 BCM2711-6c89，國家 US，HaLow 無線電 頻道 42（2 MHz），給手機連的 Wi-Fi「node-ap」');
      expect(find.byKey(const Key('settings-copy')), findsOneWidget);
    }),
    // D4a: one orphan join
    'dev_orphan_joins': P6((a, f, ui) {
      a.nets.setForTest(NetSnapshot(orphanJoins: [orphan]));
      return OrphanJoinsPage(app: a, ui: ui);
    }, check: (t) => expect(find.text('「山隊」裡的 …000B'), findsOneWidget)),
    'dev_orphan_joins_dialog': P6((a, f, ui) {
      a.nets.setForTest(NetSnapshot(orphanJoins: [orphan]));
      return OrphanJoinsPage(app: a, ui: ui);
    }, act: (t, f) async {
      await t.tap(find.text('「山隊」裡的 …000B'));
      await t.pump();
      await t.pump(const Duration(milliseconds: 300));
    }, check: (t) {
      expect(find.byKey(const Key('orphan-forget')), findsOneWidget);
      expect(find.byKey(const Key('orphan-exclude')), findsOneWidget);
    }),
    // D4: masked lines, markers as 〔〕
    'dev_text_log': P6((a, f, ui) {
      a.link.core.log
        ..clear()
        ..addAll([
          '0.0   node …7d2c: read start',
          '1.2   AA:BB:CC:DD:EE:5F -> body 0000000000000c4f2a7d2c\u001e代碼 3\u001f',
          '3.4   lease taken back after 420 s: 手機 Wi-Fi',
          '5.6   RecordWriter refused writeCas node/…7d2c',
        ]);
      return LogPage(app: a);
    }, check: (t) {
      final s = t.widget<SelectableText>(find.byKey(const Key('log-text'))).data!;
      expect(s, contains('1.2   …5F -> body …7d2c〔代碼 3〕'));
      expect(s, isNot(contains('0c4f2a')));
    }),
  };

  for (final dark in [false, true]) {
    for (final e in boards.entries) {
      final file = '${e.key}_${dark ? 'dark' : 'light'}';
      testWidgets('pr6 board $file', (t) async {
        sizeView(t);
        mockChannels(t); // appVersion / flavor, the clipboard
        t.binding.defaultBinaryMessenger.setMockMethodCallHandler(secureChannel, (c) async => true);
        final f = Fx(rust);
        final a = app()..devTrust = true; // the developer options' pages: a devTrust build
        a.link.core.states[id]! // a fresh read, not in a network (the country can be changed)
          ..kind = Kind.read
          ..view = 'yellow'
          ..readAt = a.link.now()
          ..extra = sv('yellow', nodeState: 1)
          ..last = Concl.read;
        final ui = UiState(MemStore());
        await t.pumpWidget(frame(MaterialApp(
          theme: batThemeData(Brightness.light),
          darkTheme: batThemeData(Brightness.dark),
          themeMode: dark ? ThemeMode.dark : ThemeMode.light,
          debugShowCheckedModeBanner: false,
          builder: (c, child) => MediaQuery(data: MediaQuery.of(c).copyWith(textScaler: TextScaler.noScaling), child: child!),
          home: e.value.build(a, f, ui),
        )));
        await settle(t, f);
        expect(t.takeException(), isNull, reason: 'no overflow');
        final act = e.value.act;
        if (act != null) {
          await act(t, f);
          expect(t.takeException(), isNull, reason: 'no overflow after the step');
        }
        e.value.check(t);
        await shoot(t, file);
        await t.pumpWidget(const SizedBox());
        await a.link.dispose();
        await t.pump(const Duration(seconds: 10)); // NodeLink's round after a release
      });
    }
  }
}
