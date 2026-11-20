// #329 honest-errors C4: home's status area keeps its height between "looking", "not read yet" and "all normal", so
// the node list under it does not move when the state changes.
// Negative control: `steady: true` removed at home_page.dart -> both cases FAIL (the three y differ).
import 'package:batman_app/src/nodelink/app_link.dart';
import 'package:batman_app/ui/home_page.dart';
import 'package:batman_app/ui/theme.dart';
import 'package:batman_app/ui/ui_state.dart';
import 'package:batman_app/ui/widgets.dart' show Look, StatusHero;
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

  // state name -> (the app, the title the status area must show: the premise that the state is the one meant)
  final states = <String, (AppLink Function(), String)>{
    'looking': (() => app(null), '正在找你的節點'),
    'not read yet': (() => app(null)..link.core.states[id]!.roundsEnded = 2, '還沒讀到'),
    'all normal': (() => app(sv('green')), '一切正常'),
    // 329-takeover H7: home normal with a reminder (a short name); 「可以使用」 is also in 「一切正常，可以使用」, so the
    // premise looks for the reminder line. Mutation: the variant with HomeAction.seeNode -> its y differs.
    'a reminder': (() => app(sv('green', note: kNote)), '有一則提醒'),
  };

  // every other page: the status area is as before (no kept lines). Mutation: `steady = false` -> `true` in widgets.dart.
  testWidgets('a StatusHero without steady keeps nothing: no placeholder, shorter than the steady one', (t) async {
    Future<double> h(bool? steady) async {
      await t.pumpWidget(MaterialApp(
          theme: batThemeData(Brightness.light),
          home: Scaffold(
              body: Column(children: [
            steady == null ? const StatusHero(look: Look.ok, text: '一切正常') : StatusHero(look: Look.ok, text: '一切正常', steady: steady),
          ]))));
      return t.getSize(find.byType(StatusHero)).height;
    }

    final plain = await h(null);
    expect(find.descendant(of: find.byType(StatusHero), matching: find.byType(Stack)), findsNothing);
    expect(await h(false), plain);
    expect(await h(true), greaterThan(plain + 50), reason: 'premise: steady is what adds the height');
  });

  for (final scale in const [1.0, 1.3]) {
    testWidgets('the node list starts at the same y in the three states, 360 dp wide x$scale', (t) async {
      t.view.physicalSize = const Size(360, 800);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.reset);
      final ys = <String, double>{};
      final heights = <String, double>{};
      for (final e in states.entries) {
        final a = e.value.$1();
        final ui = UiState(MemStore())..homeTip = true; // the first-run tip card is seen
        await t.pumpWidget(MaterialApp(
          key: ValueKey(e.key),
          theme: batThemeData(Brightness.light),
          builder: (c, child) =>
              MediaQuery(data: MediaQuery.of(c).copyWith(textScaler: TextScaler.linear(scale)), child: child!),
          home: HomePage(app: a, ui: ui, devTrust: false, keys: keys()),
        ));
        await t.pump(const Duration(milliseconds: 100));
        expect(t.takeException(), isNull);
        expect(find.descendant(of: find.byType(StatusHero), matching: find.textContaining(e.value.$2)), findsOneWidget,
            reason: 'premise: the state is ${e.key}');
        heights[e.key] = t.getSize(find.byType(StatusHero)).height;
        ys[e.key] = t.getTopLeft(find.text('我的節點')).dy;
        await t.pumpWidget(const SizedBox());
        AppLink.forgetForTest();
      }
      final y = ys['all normal']!;
      expect(ys['looking'], closeTo(y, 0.5), reason: '$ys $heights');
      expect(ys['a reminder'], closeTo(y, 0.5), reason: '$ys $heights');
      // Limit, stated (design C4): at text scale 1.3 the "not read yet" title is three lines at 360 dp (two are kept),
      // so that state is one title line (42 dp) lower. Equal at 1.0.
      expect(ys['not read yet'], closeTo(y + (scale == 1.0 ? 0 : 42), 0.5), reason: '$ys $heights');
    });
  }
}
