// member-join code review round 1: "forget" offers approved nodes too, with their own notice (A-1); a paste button
// does nothing while another operation runs (A-m3 / B-m5); the invite button is dev-only like the paste buttons (B-m4).
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:batman_app/member_ui.dart';

Widget app(Widget w) => MaterialApp(home: Scaffold(body: w));

void main() {
  test('a join request cut by a lost link says whether it was saved', () {
    expect(joinreqLostLine(saved: false), contains('申請沒有存，請再按一次'));
    expect(joinreqLostLine(saved: true), contains('申請已存'));
  });

  test('forget offers joining and approved nodes, never the creator', () {
    expect(forgettable(joining: true, approved: false, creator: false), isTrue);
    expect(forgettable(joining: false, approved: true, creator: false), isFalse,
        reason: 'remove-member §3.6 (T39): remove the person instead');
    expect(forgettable(joining: false, approved: false, creator: false), isFalse, reason: 'applied');
    expect(forgettable(joining: true, approved: false, creator: true), isFalse);
    expect(forgetNotice(approved: true), contains('不會撤銷這台已拿到的網路金鑰'));
    expect(forgetNotice(approved: false), isNot(contains('不會撤銷')));
    expect(forgetNotice(approved: false, offerExclude: true), contains('排除這台'), reason: 'remove-member T39: dev offers exclude');
    expect(forgetNotice(approved: false), isNot(contains('排除這台')));
  });

  testWidgets('a disabled paste button does nothing', (t) async {
    var read = 0;
    await t.pumpWidget(app(PasteButton(
        label: '貼上邀請',
        enabled: false,
        devTrust: () async => true,
        readClipboard: () async {
          read++;
          return 'a201';
        },
        onText: (_) {},
        onRefused: (_) {})));
    await t.tap(find.text('貼上邀請'));
    await t.pumpAndSettle();
    expect(read, 0);
  });

  testWidgets('the invite button is refused in a field build', (t) async {
    var ran = 0;
    final why = <String>[];
    await t.pumpWidget(app(DevOnlyButton(label: '邀請隊員', devTrust: () async => false, onPressed: () async => ran++, onRefused: why.add)));
    await t.tap(find.text('邀請隊員'));
    await t.pumpAndSettle();
    expect(ran, 0);
    expect(why, ['只有開發版可以使用遠端邀請']);
    await t.pumpWidget(app(DevOnlyButton(label: '邀請隊員', devTrust: () async => true, onPressed: () async => ran++, onRefused: why.add)));
    await t.tap(find.text('邀請隊員'));
    await t.pumpAndSettle();
    expect(ran, 1);
  });
}
