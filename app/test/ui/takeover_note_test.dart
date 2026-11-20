// 329-takeover.md §1.3 / §7 H5: a node's note (joined but CRIT) is printed where its warning was: the node page, and the
// leave page's status fields. Negative control: node_page.dart printing `v.warning` -> the node page case FAILs;
// leaveFieldsOf giving `v.warning` -> the fields case FAILs.
import 'package:batman_app/src/nodelink/app_link.dart';
import 'package:batman_app/ui/more_pages.dart' show leaveFieldsOf;
import 'package:batman_app/ui/home_page.dart';
import 'package:batman_app/ui/node_page.dart';
import 'package:batman_app/ui/theme.dart';
import 'package:batman_app/ui/ui_state.dart';
import 'package:batman_app/ui/widgets.dart' show StatusHero;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'layout_test.dart' show app, id, keys, kNote, sv;
import 'ui_state_test.dart' show MemStore;

void main() {
  setUp(() {
    final m = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    m.setMockMethodCallHandler(const MethodChannel('dev.batman/platform'), (c) async => null);
  });
  tearDown(AppLink.forgetForTest);

  testWidgets('H5: the node page prints the note where the warning was', (t) async {
    await t.pumpWidget(MaterialApp(
        theme: batThemeData(Brightness.light),
        home: NodePage(app: app(sv('green', note: kNote)), id: id, ui: UiState(MemStore()))));
    await t.pump(const Duration(milliseconds: 100));
    expect(find.text(kNote), findsOneWidget);
    await t.pumpWidget(const SizedBox());
  });

  // H1 / H4 on the page. Negative control: home_page.dart without `hint:` -> FAIL.
  testWidgets('H4: home: the hero 「可以使用」 with the reminder, the row\'s small line 「有一則提醒」, no hero button',
      (t) async {
    await t.pumpWidget(MaterialApp(
        theme: batThemeData(Brightness.light),
        home: HomePage(app: app(sv('green', note: kNote)), ui: UiState(MemStore())..homeTip = true, devTrust: false, keys: keys())));
    await t.pump(const Duration(milliseconds: 100));
    expect(find.descendant(of: find.byType(StatusHero), matching: find.textContaining('有一則提醒，點節點看。')), findsOneWidget);
    expect(find.descendant(of: find.byType(StatusHero), matching: find.byType(FilledButton)), findsNothing);
    expect(find.textContaining('一切正常'), findsNothing);
    expect(find.text(kNote), findsNothing, reason: 'the note itself is on the node page only');
    expect(t.widget<Text>(find.byKey(const Key('row-hint'))).data, '有一則提醒');
    await t.pumpWidget(const SizedBox());
  });

  test('H5: the leave page\'s status fields carry the note as their ⚠️ line', () {
    expect(leaveFieldsOf(sv('green', note: kNote)).warning, kNote);
    expect(leaveFieldsOf(sv('green')).warning, '');
  });
}
