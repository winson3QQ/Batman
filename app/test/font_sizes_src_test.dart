// #329 PR 7 T8 (b) (design §3.1, review B-M4): the source half of 「only the six sizes」. Every `fontSize:` in lib/
// (generated Rust bindings aside) is one of the Fs levels — no number, no `Fs.x ± n`, no other expression; a
// conditional is allowed when both its values are. The 確認碼 big digits are the only numbers (a list of file +
// value, each once). The rendered half is test/support/font_levels.dart in every board test.
// Negative control: a `fontSize: 15` or `Fs.hero - 3` put back in lib/ -> FAIL.
import 'dart:io';

import 'package:batman_app/ui/theme.dart';
import 'package:flutter_test/flutter_test.dart';

/// (file, value) -> how many times: the 確認碼 digits (design §3.1 lists the six levels for words; these are codes),
/// and theme.dart's sixLevels, whose `size` is always an Fs level (its calls are all Fs; the board tests' rendered
/// check sees Material's roles at those sizes)
const sasNumbers = {
  ('lib/member_ui.dart', '40'): 1,
  ('lib/member_ui.dart', '24'): 1,
  ('lib/ui/team_pages.dart', '44'): 1,
  ('lib/ui/theme.dart', 'size'): 1,
};

final level = RegExp(r'^Fs\.(welcome|hero|title|body|note|meta)$');

/// The expression after `fontSize:` at [i]: up to the first `,` or unmatched closing bracket at depth 0.
String exprAt(String src, int i) {
  var depth = 0;
  var j = i;
  for (; j < src.length; j++) {
    final c = src[j];
    if (c == '(' || c == '[' || c == '{') depth++;
    if (c == ')' || c == ']' || c == '}') {
      if (depth == 0) break;
      depth--;
    }
    if (c == ',' && depth == 0) break;
  }
  return src.substring(i, j).replaceAll(RegExp(r'\s+'), ' ').trim();
}

/// The values an expression can give: `a ? b : c` -> b and c (each split again); anything else is itself.
List<String> values(String e) {
  final q = e.indexOf('?');
  if (q < 0) return [e];
  final rest = e.substring(q + 1);
  final c = rest.indexOf(':');
  if (c < 0) return [e];
  return [...values(rest.substring(0, c).trim()), ...values(rest.substring(c + 1).trim())];
}

void main() {
  test('Fs is the six levels of design §3.1', () {
    expect([Fs.welcome, Fs.hero, Fs.title, Fs.body, Fs.note, Fs.meta], [28.0, 24.0, 18.0, 16.0, 14.0, 13.0]);
  });

  test('every fontSize in lib/ is an Fs level (the 確認碼 digits listed)', () {
    final files = Directory('lib')
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) => f.path.endsWith('.dart') && !f.path.replaceAll('\\', '/').contains('lib/src/rust/'))
        .toList();
    expect(files, isNotEmpty);
    final bad = <String>[];
    final seen = <(String, String), int>{};
    var found = 0;
    for (final f in files) {
      final path = f.path.replaceAll('\\', '/');
      final src = f.readAsStringSync();
      for (final m in RegExp(r'fontSize(Factor|Delta)').allMatches(src)) {
        bad.add('$path:${'\n'.allMatches(src.substring(0, m.start)).length + 1} ${m[0]} (scales a size)');
      }
      for (final m in RegExp(r'\bfontSize:').allMatches(src)) {
        found++;
        final line = '\n'.allMatches(src.substring(0, m.start)).length + 1;
        final e = exprAt(src, m.end);
        for (final v in values(e)) {
          if (level.hasMatch(v)) continue;
          final key = (path, v);
          if (sasNumbers.containsKey(key)) {
            seen[key] = (seen[key] ?? 0) + 1;
            continue;
          }
          bad.add('$path:$line fontSize: $e');
        }
      }
    }
    expect(found, greaterThan(50), reason: 'the scan found the sizes (a scan that finds nothing must not pass)');
    expect(bad, isEmpty, reason: 'design §3.1: only the six sizes');
    expect(seen, sasNumbers, reason: 'each listed 確認碼 size once, as listed');
  });

  test('theme.dart sixLevels gives Material\'s text roles Fs levels only', () {
    final src = File('lib/ui/theme.dart').readAsStringSync();
    final calls = RegExp(r's\(t\.(\w+), ([^)]*)\)').allMatches(src).toList();
    expect(calls.length, 15, reason: 'every role of TextTheme');
    for (final c in calls) {
      expect(level.hasMatch(c[2]!.trim()), isTrue, reason: '${c[1]}: ${c[2]}');
    }
  });

  test('the scan itself: what it refuses and allows', () {
    String one(String s) => exprAt(s, s.indexOf('fontSize:') + 'fontSize:'.length);
    expect(one('TextStyle(fontSize: Fs.hero - 3, color: x)'), 'Fs.hero - 3');
    expect(level.hasMatch(one('TextStyle(fontSize: Fs.hero - 3, color: x)')), isFalse);
    expect(level.hasMatch(one('TextStyle(fontSize: 15)')), isFalse);
    expect(level.hasMatch(one('const TextStyle(fontSize: Fs.body)')), isTrue);
    expect(values(one('TextStyle(fontSize: k ? Fs.body : 17, w: 1)')), ['Fs.body', '17']);
    expect(values(one('TextStyle(fontSize: f(a, b) ? Fs.body : Fs.note)')), ['Fs.body', 'Fs.note']);
  });
}
