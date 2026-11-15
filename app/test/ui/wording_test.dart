// #329 §3.4 T-C4b / T-C4a (source half) / T-C5. Scans the app's Dart and Rust sources (a test that finds no file or
// no quoted button fails: nothing to check is not a pass).
import 'dart:io';

import 'package:batman_app/ui/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

List<File> sources() => [
      for (final d in ['lib', 'rust/bridge/src', 'rust/batman-proto/src'])
        ...Directory(d).listSync(recursive: true).whereType<File>().where((f) =>
            (f.path.endsWith('.dart') || f.path.endsWith('.rs')) && !f.path.replaceAll(r'\', '/').contains('/src/rust/')),
    ];

void main() {
  test('T-C4b: every button a sentence tells the user to press (按「…」) is in the Btn table', () {
    final files = sources();
    expect(files.length, greaterThan(20));
    final named = <String, String>{};
    for (final f in files) {
      for (final m in RegExp(r'按「([^」]+)」').allMatches(f.readAsStringSync())) {
        named[m[1]!] = f.path;
      }
    }
    expect(named, isNotEmpty);
    final missing = {for (final e in named.entries) if (!Btn.all.contains(e.key)) e.key: e.value};
    expect(missing, isEmpty);
  });

  test('T-C4a (source): retired words are gone from the user-facing strings', () {
    // 管理者 only in 管理者金鑰, 成員 only in 成員金鑰 (key names); comments are skipped
    final bad = RegExp(r'網主|末四碼|管理者(?!金鑰)|(?<!／)成員(?!金鑰)');
    final hits = <String>[];
    for (final f in sources()) {
      final lines = f.readAsLinesSync();
      for (var i = 0; i < lines.length; i++) {
        final code = lines[i].trimLeft();
        if (code.startsWith('//') || code.startsWith('///') || code.startsWith('*')) continue;
        if (bad.hasMatch(lines[i])) hits.add('${f.path}:${i + 1}: ${lines[i].trim()}');
      }
    }
    expect(hits, isEmpty);
  });

  test('T-C5: the activity is portrait only (manifest)', () {
    final m = File('android/app/src/main/AndroidManifest.xml').readAsStringSync();
    final activity = RegExp(r'<activity[^>]*android:name="\.MainActivity"[^>]*>', dotAll: true).firstMatch(m);
    expect(activity, isNotNull);
    expect(activity![0], contains('android:screenOrientation="portrait"'));
  });
}
