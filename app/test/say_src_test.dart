// #329 PR 6 D7a (3) / T-C4c-src: a source scan of the screens — a Rust sentence (`.detail`, `.line`, `.text` of a
// reply, a page's `_line` / `_note`, a caught `$e`) never goes into a widget that shows it as is (Text, a BatBanner /
// BatRow title, a SnackBar, a dialog's content). It goes through SayLine (main part + 技術資訊), StatusHero /
// BatBanner text (they split), screenText (main part only) or stripMarkers into one of those.
// Negative control: put back one `Text(x.detail)` -> FAIL.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Where a sentence would be shown as is.
final _rules = <String, RegExp>{
  // (Selectable)Text: #329 PR 6's dev pages show node answers in a SelectableText
  'Text(<sentence>)': RegExp(r'\b(?:Selectable)?Text\(\s*(?!screenText\()[\w!?.]*\b(?:detail|line|text|_line|_note|note|_text)\b(?![\w(])', multiLine: true),
  'Text(<literal with \$e>)': RegExp(r"""\b(?:Selectable)?Text\(\s*'[^']*\$\{?e\b"""),
  'title: <sentence>': RegExp(r'\btitle:\s*(?!screenText\()[\w!?.]*\.(?:detail|line)\b'),
  'SnackBar(<sentence>)': RegExp(r'SnackBar\([^;]*\.(?:detail|line)\b'),
};

/// Hits that are not a Rust sentence, each with its reason (file suffix, the matched text).
const _allow = <(String, String, String)>[
  ('lib/ui/code_view.dart', 'Text(_line', 'fixed Dart lines only (已複製 / 複製失敗 / 已清除剪貼簿)'),
  ('lib/ui/net_pages.dart', 'Text(r.note', 'RunRow.note: fixed Dart lines only (net_run.dart 已加入，新密碼…)'),
  ('lib/ui/widgets.dart', 'Text(line', 'NodeRow\'s own parameter: nodeRowWords, Dart words only'),
  ('lib/ui/widgets.dart', 'Text(text', 'BatLabel / BatButton label parameters: fixed words and the Btn table'),
  ('lib/claim.dart', 'Text(text', '_ask\'s own parameter: Dart questions only (reclaimText, t3Text)'),
];

List<File> _files() {
  final out = <File>[];
  for (final d in ['lib/ui']) {
    out.addAll(Directory(d).listSync(recursive: true).whereType<File>().where((f) => f.path.endsWith('.dart')));
  }
  out.addAll([File('lib/claim.dart'), File('lib/member_ui.dart')]);
  return out;
}

List<String> scan() {
  final bad = <String>[];
  final used = <int>{};
  for (final f in _files()) {
    final path = f.path.replaceAll('\\', '/');
    final src = f.readAsStringSync();
    for (final MapEntry(key: rule, value: re) in _rules.entries) {
      for (final m in re.allMatches(src)) {
        final hit = m.group(0)!.replaceAll(RegExp(r'\s+'), '');
        final a = _allow.indexWhere((x) => path.endsWith(x.$1) && hit.startsWith(x.$2.replaceAll(' ', '')));
        if (a >= 0) {
          used.add(a);
          continue;
        }
        final line = '\n'.allMatches(src.substring(0, m.start)).length + 1;
        bad.add('$path:$line: $rule: ${m.group(0)!.replaceAll('\n', ' ')}');
      }
    }
  }
  for (var i = 0; i < _allow.length; i++) {
    if (!used.contains(i)) bad.add('stale allow-list entry: ${_allow[i].$1} / ${_allow[i].$2} (${_allow[i].$3})');
  }
  return bad;
}

void main() {
  test('D7a (3): the files are there (an empty scan is a FAIL)', () {
    final fs = _files();
    expect(fs.length, greaterThanOrEqualTo(20));
    // #329 PR 6: the new pages that show Rust sentences (dev pages, 診斷, 全隊) are in the scan
    final names = fs.map((f) => f.path.replaceAll('\\', '/')).toList();
    for (final p in ['lib/ui/dev_pages.dart', 'lib/ui/diag_page.dart', 'lib/ui/team_status_page.dart', 'lib/ui/settings_pages.dart']) {
      expect(names.any((n) => n.endsWith(p)), isTrue, reason: p);
    }
    for (final f in fs) {
      expect(f.existsSync(), isTrue, reason: f.path);
    }
  });

  test('D7a (3): no Rust sentence goes into a widget unsplit', () {
    final bad = scan();
    expect(bad, isEmpty, reason: bad.join('\n'));
  });

  test('D7a (3): the rules catch what they are for (each rule finds its example)', () {
    expect(_rules['Text(<sentence>)']!.hasMatch("Text(r.value.detail, style: x)"), isTrue);
    expect(_rules['Text(<sentence>)']!.hasMatch('Text(_line, key: k)'), isTrue);
    expect(_rules['Text(<sentence>)']!.hasMatch('Text(screenText(_line))'), isFalse);
    expect(_rules['Text(<sentence>)']!.hasMatch('SelectableText(_text, key: k)'), isTrue);
    expect(_rules['Text(<sentence>)']!.hasMatch('SelectableText(screenText(_text))'), isFalse);
    expect(_rules['Text(<literal with \$e>)']!.hasMatch("Text('出錯：\$e')"), isTrue);
    expect(_rules['title: <sentence>']!.hasMatch('BatBanner(title: st.detail)'), isTrue);
    expect(_rules['SnackBar(<sentence>)']!.hasMatch('SnackBar(content: Text(r.line))'), isTrue);
  });
}
