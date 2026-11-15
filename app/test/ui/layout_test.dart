// #329 design §9.1 T-C2 (with T-C3 and the rendered half of T-C4a): every new page at {360×640, 412×915} × text
// scale {1.0, 1.3, 2.0} × {light, dark}: no overflow (an overflow is a test exception), Android's tap-target and
// text-contrast guidelines, at most one primary (filled) button, and none of the retired words on screen.
import 'package:batman_app/key_abilities.dart';
import 'package:batman_app/src/nodelink/app_link.dart';
import 'package:batman_app/src/nodelink/core.dart';
import 'package:batman_app/src/rust/api/owner.dart' show StatusView;
import 'package:batman_app/ui/home_page.dart';
import 'package:batman_app/ui/intro_pages.dart';
import 'package:batman_app/ui/node_page.dart';
import 'package:batman_app/ui/settings_page.dart';
import 'package:batman_app/ui/theme.dart';
import 'package:batman_app/ui/ui_state.dart';
import 'package:flutter/material.dart' hide Page;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../nodelink/app_link_test.dart' show StatusBle;
import 'ui_state_test.dart' show MemStore;

const id = '0000000000000c4f2a7d2c';

StatusView sv(String color, {int nodeState = 2}) => StatusView(
    color: color,
    row: '3',
    sentence: color == 'green' ? '已連上隊伍網路' : '沒有連上隊伍網路',
    lagNote: '',
    warning: '',
    nodeState: nodeState,
    netId: 'ab12',
    version: '1.5.14',
    tech: const ['頻道：42'],
    fresh: true,
    rateNote: '',
    unfinished: '',
    unfinishedUnderVerdict: false,
    canLeave: false);

KeyAbilities keys() => KeyAbilities.from({
      'RECORD_AES': 1,
      'OWNER_SIGN': 1,
      'ADMIN_SIGN': 1,
      'OWNER_ENC': 1,
      'appUsable': true,
      'claim': true,
      'login': true,
      'recover': true,
      'makeNetwork': true,
      'softOwnerEnc': false,
    });

/// An AppLink with one node record, read now with [view] (null = not read).
AppLink app(StatusView? view) {
  AppLink.forgetForTest();
  final a = AppLink.create(platform: const MethodChannel('dev.batman/platform'), filesDir: '/x', ble: StatusBle());
  final c = a.link.core;
  c.setRecords(const [Rec(id, 1)]);
  if (view != null) {
    c.states[id]!
      ..kind = Kind.read
      ..view = view.color
      ..readAt = a.link.now()
      ..extra = view
      ..last = Concl.read;
    a.link.readWall[id] = DateTime(2026, 11, 16, 1, 30);
  }
  return a;
}

final retired = RegExp(r'網主|末四碼|管理者(?!金鑰)|成員|(?<![A-Za-z_])SAS(?![A-Za-z_])|StrongBox|ownerEnc|#\d');

void main() {
  final pages = <String, Widget Function(UiState ui)>{
    'home, all fine': (ui) => HomePage(app: app(sv('green')), ui: ui, devTrust: true, keys: keys()),
    'home, not in a network': (ui) => HomePage(app: app(sv('red', nodeState: 1)), ui: ui, devTrust: true, keys: keys()),
    'home, not read yet': (ui) => HomePage(app: app(null), ui: ui, devTrust: false, keys: keys()),
    'home, a to-do banner': (ui) {
      final a = app(sv('green'));
      a.reg.unsavedTodos.add('上一個操作可能沒有存完：新增節點');
      return HomePage(app: a, ui: ui, devTrust: true, keys: keys());
    },
    'node page': (ui) => NodePage(app: app(sv('red')), id: id, ui: ui),
    'home, Bluetooth off': (ui) {
      final a = app(sv('green'));
      a.link.radio(bluetooth: false);
      return HomePage(app: a, ui: ui, devTrust: true, keys: keys());
    },
    'home, identity mismatch': (ui) {
      final a = app(null);
      a.link.core.states[id]!
        ..kind = Kind.unreachable
        ..why = Why.identity;
      return HomePage(app: a, ui: ui, devTrust: true, keys: keys());
    },
    'home, unreachable': (ui) {
      final a = app(null);
      a.link.core.states[id]!
        ..kind = Kind.unreachable
        ..why = Why.notFound
        ..last = Concl.notFound;
      return HomePage(app: a, ui: ui, devTrust: true, keys: keys());
    },
    'home, no node': (ui) {
      final a = app(null);
      a.link.core.setRecords(const []);
      return HomePage(app: a, ui: ui, devTrust: true, keys: keys());
    },
    'node page, identity': (ui) {
      final a = app(null);
      a.link.core.states[id]!
        ..kind = Kind.unreachable
        ..why = Why.identity;
      return NodePage(app: a, id: id, ui: ui);
    },
    'settings (dev)': (ui) => SettingsPage(app: app(null), devTrust: true),
    'about': (ui) => const AboutPage(),
    'intro': (ui) => IntroPages(onDone: () {}),
    'permissions': (ui) => PermissionsPage(ask: () async => false),
  };
  for (final size in const [Size(360, 640), Size(412, 915)]) {
    for (final scale in const [1.0, 1.3, 2.0]) {
      for (final dark in [false, true]) {
        for (final e in pages.entries) {
          testWidgets('T-C2 ${e.key} ${size.width.toInt()}x${size.height.toInt()} ×$scale ${dark ? 'dark' : 'light'}', (t) async {
            t.view.physicalSize = size;
            t.view.devicePixelRatio = 1;
            addTearDown(t.view.reset);
            final ui = UiState(MemStore());
            await t.pumpWidget(MaterialApp(
              theme: batThemeData(Brightness.light),
              darkTheme: batThemeData(Brightness.dark),
              themeMode: dark ? ThemeMode.dark : ThemeMode.light,
              builder: (c, child) =>
                  MediaQuery(data: MediaQuery.of(c).copyWith(textScaler: TextScaler.linear(scale)), child: child!),
              home: e.value(ui),
            ));
            await t.pump(const Duration(milliseconds: 100));
            expect(t.takeException(), isNull, reason: 'no overflow');
            await expectLater(t, meetsGuideline(androidTapTargetGuideline));
            await expectLater(t, meetsGuideline(textContrastGuideline));
            expect(find.byType(FilledButton).evaluate().length, lessThanOrEqualTo(1), reason: 'T-C3: one primary button');
            for (final w in t.widgetList<Text>(find.byType(Text))) {
              final s = w.data ?? w.textSpan?.toPlainText() ?? '';
              expect(retired.hasMatch(s), isFalse, reason: 'T-C4a: "$s"');
            }
            await t.pumpWidget(const SizedBox()); // the pages' timers go with them
            AppLink.forgetForTest();
          });
        }
      }
    }
  }
}
