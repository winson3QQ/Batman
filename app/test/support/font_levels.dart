// #329 PR 7 T8 (b) (design §3.1, review B-M4): every text the board tests render is at one of the six sizes (28 / 24
// / 18 / 16 / 14 / 13 sp). Only the 確認碼 big digits (Key('sas'): 40 / 44 / 24) are outside them. Icons are glyphs,
// not text, and are skipped. The size checked is the style's (before the text scale).
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

final sixLevels = {28.0, 24.0, 18.0, 16.0, 14.0, 13.0};
final sasSizes = {40.0, 44.0, 24.0};

/// The rendered texts whose size is not allowed: 'size "text"' for each.
List<String> offLevelTexts(WidgetTester t) {
  final bad = <String>[];
  void walk(InlineSpan s, double? inherited, bool sas) {
    final size = s.style?.fontSize ?? inherited;
    if (s is TextSpan) {
      final own = s.text ?? '';
      if (own.trim().isNotEmpty) {
        final ok = size != null && (sixLevels.contains(size) || (sas && sasSizes.contains(size)));
        if (!ok) bad.add('$size "${own.length > 30 ? '${own.substring(0, 30)}…' : own}"');
      }
      for (final c in s.children ?? const <InlineSpan>[]) {
        walk(c, size, sas);
      }
    }
  }

  bool under<W extends Widget>(Element e, [bool Function(W w)? test]) {
    var found = false;
    e.visitAncestorElements((a) {
      final w = a.widget;
      if (w is W && (test == null || test(w))) {
        found = true;
        return false;
      }
      return true;
    });
    return found;
  }

  for (final e in find.byType(RichText, skipOffstage: false).evaluate()) {
    if (under<Icon>(e)) continue;
    final sas = under<Text>(e, (w) => w.key == const Key('sas')) || e.widget.key == const Key('sas');
    walk((e.widget as RichText).text, null, sas);
  }
  for (final e in find.byType(EditableText, skipOffstage: false).evaluate()) {
    final w = e.widget as EditableText;
    final size = w.style.fontSize;
    if (w.controller.text.isNotEmpty && (size == null || !sixLevels.contains(size))) {
      bad.add('$size (input) "${w.controller.text}"');
    }
  }
  return bad;
}

void expectSixLevels(WidgetTester t) => expect(offLevelTexts(t), isEmpty, reason: 'design §3.1: only the six sizes');
