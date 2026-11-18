// #329 PR 6 D7 / T-C4c: the technical part of a sentence (U+001E … U+001F) — splitCode against the vectors Rust's
// split_code is checked against too (test/fixtures/split_vectors.txt), SayLine's main part and fold, StatusHero's
// joined lines (G-M1: main.dart's `lines.skip(1).join('\n')`, node_page.dart's `next.join('\n')`), the log form.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:batman_app/say.dart';
import 'package:batman_app/ui/theme.dart';
import 'package:batman_app/ui/widgets.dart';

const o = '\u001e', c = '\u001f';

Widget host(Widget w) => MaterialApp(theme: ThemeData(extensions: const [BatTheme.light]), home: Scaffold(body: ListView(children: [w])));

void main() {
  test('splitCode: the shared vectors (the same file as Rust split_code)', () {
    final lines = File('test/fixtures/split_vectors.txt').readAsLinesSync().where((l) => l.trim().isNotEmpty && !l.startsWith('#'));
    String dec(String s) => s.replaceAll('<<', o).replaceAll('>>', c);
    var n = 0;
    for (final l in lines) {
      final f = l.split('|');
      expect(f, hasLength(3), reason: l);
      expect(splitCode(dec(f[0])), (dec(f[1]), dec(f[2])), reason: l);
      n++;
    }
    expect(n, greaterThanOrEqualTo(10), reason: 'a vector file that checks nothing is a FAIL');
  });

  test('splitCode: joined sentences keep every main word (G-M1), unpaired / nested keep everything', () {
    // claim_recovery.dart `'${t.step.detail}$warn'` with Rust's replay.rs:133 neutral line
    const warn = '。這筆暫存可能不是這台節點最後一次認領用的，請不要一直重試';
    final (m, t) = splitCode('節點沒有接受這次恢復，已停止；紀錄先保留${o}claim/replay，代碼 3$c$warn');
    expect(m, contains('請不要一直重試'));
    expect(m, isNot(contains('代碼')));
    expect(t, 'claim/replay，代碼 3');
    // unpaired: nothing is swallowed
    expect(splitCode('a${o}b').$1, 'ab');
    expect(splitCode('a${c}b').$1, 'ab');
    expect(splitCode('x$o$o y$c$c z').$1, 'x y z');
  });

  test('screenText: markers off on every line, technical parts off; logText shows them as 〔 〕', () {
    expect(screenText('[REQ_FAIL] 沒有送出$o代碼 3$c\n[UPDATE] 已收到'), '沒有送出\n已收到');
    expect(techText('[REQ_FAIL] 沒有送出$o代碼 3$c'), '代碼 3');
    expect(logText('沒有送出$o代碼 3$c'), '沒有送出〔代碼 3〕');
    expect(stripMarkers('[A] x$o y$c'), 'x$o y$c');
    expect(sayErr('rust 句子$o代碼$c'), 'rust 句子$o代碼$c', reason: 'a Rust String keeps its own marks (I MINOR-2)');
    expect(sayErr(StateError('x')), startsWith(o), reason: 'anything else is technical as a whole');
  });

  testWidgets('SayLine: the main part on screen; the code only after 技術資訊 is opened', (t) async {
    await t.pumpWidget(host(SayLine('[REQ_FAIL] 沒有離開網路（節點仍在隊伍網路裡）— 請再按一次$o代碼 11$c', techKey: const Key('tk'))));
    expect(find.text('沒有離開網路（節點仍在隊伍網路裡）— 請再按一次'), findsOneWidget, reason: 'the next step stays on the main part');
    expect(find.textContaining('代碼'), findsNothing);
    expect(find.text(techTitle), findsOneWidget);
    await t.tap(find.text(techTitle));
    await t.pump();
    expect(find.byKey(const Key('tk')), findsOneWidget);
    expect((t.widget<SelectableText>(find.byKey(const Key('tk')))).data, '代碼 11');
  });

  testWidgets('SayLine: no technical part -> no fold', (t) async {
    await t.pumpWidget(host(const SayLine('[LEFT] 已離開隊伍網路')));
    expect(find.text('已離開隊伍網路'), findsOneWidget);
    expect(find.text(techTitle), findsNothing);
  });

  // G-M1 (main.dart:264, node_page.dart:184): StatusHero.next is several lines joined; a technical part in the first
  // line must not hide the lines after it
  testWidgets('StatusHero: every line of next keeps its words; the codes under one fold', (t) async {
    await t.pumpWidget(host(StatusHero(
        look: Look.bad,
        text: '啟動檢查：金鑰讀不到$o讀取失敗：x$c',
        next: ['節點自動讀取沒有啟動：讀不到紀錄${o}StateError$c', '請完全關閉 app 再開'].join('\n'))));
    expect(find.text('啟動檢查：金鑰讀不到'), findsOneWidget);
    expect(find.text('節點自動讀取沒有啟動：讀不到紀錄\n請完全關閉 app 再開'), findsOneWidget);
    expect(find.textContaining('StateError'), findsNothing);
    await t.tap(find.text(techTitle));
    await t.pump();
    expect(find.textContaining('讀取失敗：x；StateError'), findsOneWidget);
  });

  testWidgets('BatBanner text: the main part, the code folded', (t) async {
    await t.pumpWidget(host(BatBanner(look: Look.unk, title: '剛才的新增節點', text: '[CLAIM_FAIL] 認領中斷：中斷${o}lost$c')));
    expect(find.text('認領中斷：中斷'), findsOneWidget);
    expect(find.textContaining('lost'), findsNothing);
  });
}
