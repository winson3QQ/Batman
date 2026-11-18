// #329 補測 A（T9 / Q1，2026-11-18）: the boards of retest_p_layout_test.dart (1.1 the startup splash, 2.4 the phone's
// keys, welcome pages 2 / 3, the 「從這支手機移除這台節點」 dialog, 技術資訊 opened on 更多, long sentences) at 412×915,
// text scale 1.0, light and dark, with that file's fake data (its own fake Rust, hence a file of its own). Each board:
// no overflow and, when BOARDS_OUT is set, $BOARDS_OUT/<board>_<light|dark>.png (design T9; see retest_s_boards_test).
import 'package:batman_app/main.dart' show StartupCheck;
import 'package:batman_app/src/nodelink/app_link.dart';
import 'package:batman_app/src/rust/frb_generated.dart';
import 'package:batman_app/ui/home_page.dart';
import 'package:batman_app/ui/intro_pages.dart';
import 'package:batman_app/ui/more_pages.dart' show MorePage;
import 'package:batman_app/ui/node_page.dart';
import 'package:batman_app/ui/theme.dart';
import 'package:batman_app/ui/ui_state.dart';
import 'package:batman_app/ui/widgets.dart' show Btn;
import 'package:flutter/material.dart' hide Page;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'key_abilities_test.dart' as ka show FakeRust, answer;
import 'retest_s_shot.dart';
import 'support/a11y.dart';
import 'support/font_levels.dart';
import 'ui/retest_p_layout_test.dart' show P, app, id, keys, longNamed, platform, startup, sv, tapText;
import 'ui/ui_state_test.dart' show MemStore;

void main() {
  final rust = ka.FakeRust()..nodes = ['0000000000000c4f2a', '00000000000000beef0000000000c4f2a7d2c'];
  setUpAll(() async {
    RustLib.initMock(api: rust);
    await loadFonts();
    // ignore: avoid_print
    print('retest-s boards (p): fonts ${loadedFonts.isEmpty ? 'NONE (box font)' : loadedFonts.join(', ')}');
  });
  setUp(() => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(platform, (c) async => null));

  final boards = <String, P>{
    '1.1_startup_splash': P((ui) {
      startup(never: true);
      return const StartupCheck();
    }),
    '2.4_keys_not_hardware': P((ui) {
      startup(keyLevels: ka.answer(appUsable: false));
      return const StartupCheck();
    }),
    '2.4_keys_unreadable': P((ui) {
      startup(keyLevels: PlatformException(code: 'keystore', message: 'KeyStoreException'));
      return const StartupCheck();
    }),
    '2.4_tech_opened': P((ui) {
      startup(keyLevels: ka.answer(appUsable: false));
      return const StartupCheck();
    }, act: (t) => tapText(t, '技術資訊（給維修人員看）')),
    'intro_2': P((ui) => IntroPages(onDone: () {}), act: (t) => tapText(t, Btn.next)),
    'intro_3': P((ui) => IntroPages(onDone: () {}), act: (t) async {
      await tapText(t, Btn.next);
      await tapText(t, Btn.next);
    }),
    '5.7_remove_dialog': P((ui) => MorePage(app: app(sv('green', canLeave: true)), ui: ui, id: id), act: (t) async {
      await tapText(t, '從這支手機移除這台節點');
      // #329 PR 7 T16 (p1p2-check 5.7): a space between the last four and 「嗎」, as the other sentences
      expect(t.widget<Text>(find.byKey(const Key('remove-title'))).data, '要從這支手機移除節點 7D2C 嗎？');
    }),
    '5.5_more_tech_opened_long': P((ui) => MorePage(app: app(sv('green', canLeave: true, long: true)), ui: ui, id: id), act: (t) async {
      await tapText(t, '技術資訊（給維修人員看）');
      // #329 PR 7 (p1p2-check 5.5): an opened fold shows 「expand_less」, not a page's chevron
      final row = find.byKey(const Key('more-tech'));
      expect(find.descendant(of: row, matching: find.byIcon(Icons.expand_less)), findsOneWidget);
      expect(find.descendant(of: row, matching: find.byIcon(Icons.chevron_right)), findsNothing);
    }),
    'long_home_problem': P((ui) => HomePage(app: app(sv('red', long: true)), ui: longNamed(), devTrust: true, keys: keys())),
    'long_home_not_read': P((ui) => HomePage(app: app(null), ui: longNamed(), devTrust: true, keys: keys())),
    'long_node_page': P((ui) => NodePage(app: app(sv('red', long: true)), id: id, ui: longNamed())),
    'long_remove_dialog_24char': P((ui) => MorePage(app: app(sv('green', canLeave: true, long: true)), ui: longNamed(), id: id),
        act: (t) => tapText(t, '從這支手機移除這台節點')),
  };

  // #329 PR 7 T8 (b): every board also at text scale 2.0 (design §3.1 T-C2: no overflow; its checks and PNG at 1.0)
  for (final (dark, scale) in const [(false, 1.0), (true, 1.0), (false, 2.0), (true, 2.0)]) {
    for (final e in boards.entries) {
      final file = '${e.key}_${dark ? 'dark' : 'light'}';
      testWidgets('retest-s board $file${scale == 1.0 ? '' : ' ×2.0'}', (t) async {
        sizeView(t);
        final sem = t.ensureSemantics(); // #329 PR 7 §4: the guidelines read the semantics tree
        final ui = UiState(MemStore());
        await t.pumpWidget(frame(MaterialApp(
          theme: batThemeData(Brightness.light),
          darkTheme: batThemeData(Brightness.dark),
          themeMode: dark ? ThemeMode.dark : ThemeMode.light,
          debugShowCheckedModeBanner: false,
          builder: (c, child) => MediaQuery(data: MediaQuery.of(c).copyWith(textScaler: scale == 1.0 ? TextScaler.noScaling : TextScaler.linear(scale)), child: child!),
          home: e.value.build(ui),
        )));
        for (var i = 0; i < 5; i++) {
          await t.pump(const Duration(milliseconds: 100)); // the startup check's answers
        }
        expect(t.takeException(), isNull, reason: 'no overflow');
        final act = e.value.act;
        if (act != null) {
          await act(t);
          expect(t.takeException(), isNull, reason: 'no overflow after the step');
        }
        expectSixLevels(t);
        if (scale == 1.0) await expectA11y(t, file); // #329 PR 7 §4: 48 dp, contrast, one solid button
        if (scale == 1.0) await shoot(t, file);
        await t.pumpWidget(const SizedBox()); // the pages' timers go with them
        sem.dispose();
        AppLink.forgetForTest();
      });
    }
  }
}
