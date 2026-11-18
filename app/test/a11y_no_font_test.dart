// #329 PR 7 code review A-MAJOR-1: a board run without the CJK board font judges no contrast, so it FAILs — it does
// not pass with an A11Y-SKIP line — unless A11Y_ALLOW_NO_FONT=1 is set on purpose. This file never calls loadFonts, so
// here the board font is missing on every machine. Negative control (the PR body): noFontProblems back to "print
// A11Y-SKIP, return nothing" -> the three FAIL tests below FAIL.
import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'retest_s_shot.dart' show cjkFontPaths, loadedFonts;
import 'support/a11y.dart';

void main() {
  test('no font, no A11Y_ALLOW_NO_FONT -> a FAIL line naming the board', () {
    expect(noFontProblems('x_light', judged: false, env: const {}),
        [startsWith('A11Y-FAIL x_light contrast: no board font')]);
    expect(noFontProblems('x_light', judged: false, env: const {'A11Y_ALLOW_NO_FONT': '0'}), hasLength(1),
        reason: 'only the value 1 skips');
  });

  test('no font with A11Y_ALLOW_NO_FONT=1 -> no FAIL (an A11Y-SKIP line is printed); the font loaded -> nothing', () {
    expect(noFontProblems('x_light', judged: false, env: const {'A11Y_ALLOW_NO_FONT': '1'}), isEmpty);
    expect(noFontProblems('x_light', judged: true, env: const {}), isEmpty);
  });

  test('a Linux runner with fonts-noto-cjk finds its font (Debian / Ubuntu path is in the list)', () {
    expect(cjkFontPaths, contains('/usr/share/fonts/opentype/noto/NotoSansCJK-Regular.ttc'));
  });

  testWidgets('black box: a board checked without the font FAILs in expectA11y', (t) async {
    expect(loadedFonts, isEmpty, reason: 'this file loads no font');
    await t.pumpWidget(const MaterialApp(home: Scaffold(body: Center(child: Text('說明')))));
    final allowed = Platform.environment['A11Y_ALLOW_NO_FONT'] == '1';
    Object? failure;
    try {
      await expectA11y(t, 'probe_light');
    } on TestFailure catch (e) {
      failure = e;
    }
    if (allowed) {
      expect(failure, isNull, reason: 'A11Y_ALLOW_NO_FONT=1: skipped on purpose');
    } else {
      expect(failure, isNotNull, reason: 'no font must not pass');
      expect('$failure', contains('A11Y-FAIL probe_light contrast: no board font'));
    }
  });
}
