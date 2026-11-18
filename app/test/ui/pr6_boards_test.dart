// #329 PR 6 §3 (T9 boards): 5.6 phone Wi-Fi and 5.8 country with the current values read (a fake console that logs
// in: op_session_test's Fx, the same as settings_pages_test) — the boards retest_s_boards_test.dart only has in their
// busy state. Rendered at 412×915, light and dark; one PNG each when BOARDS_OUT is set (retest_s_shot.dart).
import 'package:batman_app/secure_screen.dart';
import 'package:batman_app/src/nodelink/core.dart';
import 'package:batman_app/src/rust/frb_generated.dart';
import 'package:batman_app/ui/settings_pages.dart';
import 'package:batman_app/ui/theme.dart';
import 'package:batman_app/ui/ui_state.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../flows/op_session_test.dart' show Fx;
import '../nodes_update_send_test.dart' as nus show FakeRust;
import '../retest_s_shot.dart';
import 'pages_test.dart' show app, id, sv;
import 'ui_state_test.dart' show MemStore;

void main() {
  final rust = nus.FakeRust();
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

  for (final dark in [false, true]) {
    for (final board in ['phone_wifi_read', 'country_read']) {
      final file = '${board}_${dark ? 'dark' : 'light'}';
      testWidgets('pr6 board $file', (t) async {
        sizeView(t);
        t.binding.defaultBinaryMessenger.setMockMethodCallHandler(secureChannel, (c) async => true);
        final f = Fx(rust);
        final a = app();
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
          home: board == 'phone_wifi_read'
              ? WifiPage(app: a, ui: ui, id: id, deps: f.d)
              : CountryPage(app: a, ui: ui, id: id, deps: f.d),
        )));
        await settle(t, f);
        expect(t.takeException(), isNull, reason: 'no overflow');
        // the values were read (not the busy board): the fake console answers name node-ap, country US
        expect(find.textContaining(board == 'phone_wifi_read' ? 'node-ap' : '美國 US'), findsWidgets);
        expect(find.textContaining('另一個操作還在進行'), findsNothing);
        await shoot(t, file);
        await t.pumpWidget(const SizedBox());
        await a.link.dispose();
      });
    }
  }
}
