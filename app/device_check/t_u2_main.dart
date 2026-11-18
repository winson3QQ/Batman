// #329 T-U2 end to end (design :146; 2026-11-17 audit: only fake Rust before): the real record store (Rust), the real
// Keystore (seal / open) and UiState together. A device-only check program (not `flutter test`, which uninstalls apps on
// failure). It needs a hardware-backed RECORD_AES: an emulator's keystore is software level 0, which the key policy
// refuses (PlatformException(keyLevel, RECORD_AES, 0)), so every premise fails there. Run it on a phone under a package
// of its own that has NEVER held keys or records (a brand-new applicationId; the program refuses otherwise — on
// 2026-11-18 it was run under dev3, which held node 7C31, and its `firstRun` destroyed that node's owner key):
//   flutter build apk --debug --flavor tu2 -t device_check/t_u2_main.dart
//   adb -s <phone> install -r build/app/outputs/flutter-apk/app-tu2-debug.apk
//   adb -s <phone> shell am start -n dev.batman.app.tu2/dev.batman.batman_app.MainActivity
//   adb -s <phone> logcat -d | grep T-U2
// Four broken files — length 0, an unknown header version, a ciphertext byte flipped, a body of version 2 — must each
// read as 「no saved state」 (defaults, no exception), and the next write after each must work and read back.
// Prints one line per case, `T-U2 PASS <case>` / `T-U2 FAIL <case>: why`, then `T-U2 DONE pass=N fail=M`.
import 'dart:io';

import 'package:batman_app/src/rust/frb_generated.dart';
import 'package:batman_app/ui/cbor_mini.dart' show cborEncode;
import 'package:batman_app/ui/ui_state.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

const platform = MethodChannel('dev.batman/platform');

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const MaterialApp(home: Scaffold(body: Center(child: Text('T-U2 running')))));
  await RustLib.init();
  final files = (await platform.invokeMethod<String>('filesDir'))!;
  final dir = '$files/t-u2-records'; // its own directory: never the app's records
  // 2026-11-18 (#329 PR 6): `firstRun` REGENERATES all four keys (Keys.kt firstRun), so running this over a package
  // that holds records destroys them for good — it did, on the S20's dev3 (the owner key of node 7C31 was lost; only a
  // re-flash brings that node back). Refuse when the package has any key or any app record; generate keys only when
  // there are none.
  final levels = await platform.invokeMapMethod<String, dynamic>('keyLevels');
  final hasKey = levels != null && levels.values.any((v) => v != null);
  final hasRecords = Directory('$files/records').existsSync();
  if (hasKey || hasRecords) {
    debugPrint('T-U2 REFUSED: this package already has ${hasKey ? 'keys' : 'records'} — run it under a fresh package');
    debugPrint('T-U2 DONE pass=0 fail=1');
    return;
  }
  try {
    await platform.invokeMethod<Object?>('firstRun'); // no key yet: the four keys
  } catch (e) {
    debugPrint('T-U2 diag firstRun: $e');
  }
  try {
    debugPrint('T-U2 diag keyLevels: ${await platform.invokeMethod<Object?>('keyLevels')}');
    final s = RecordUiStore('$files/t-u2-diag', platform);
    Directory('$files/t-u2-diag').createSync(recursive: true);
    final g = await s.write(0, cborEncode(<Object, Object>{1: 1}));
    final r = await s.read();
    debugPrint('T-U2 diag write gen=$g read=${r?.$1} plain=${r?.$2?.length}');
  } catch (e) {
    debugPrint('T-U2 diag store: $e');
  }
  var pass = 0, fail = 0;
  File file() => File('$dir/$uiRel');

  Future<UiState> fresh(List<String> log) async {
    final ui = UiState(RecordUiStore(dir, platform), log: log.add);
    await ui.load();
    return ui;
  }

  Future<void> run(String name, Future<void> Function() breakIt) async {
    final d = Directory(dir);
    if (d.existsSync()) d.deleteSync(recursive: true);
    d.createSync(recursive: true);
    try {
      final ui0 = await fresh([]);
      await ui0.setHomeTip();
      if (!(await fresh([])).homeTip) throw 'premise: a real record did not read back';
      await breakIt();
      final log = <String>[];
      final ui = await fresh(log);
      if (ui.homeTip) throw 'the broken file was read as a saved state';
      await ui.setHomeTip();
      if (!(await fresh([])).homeTip) throw 'the next write did not read back (log: $log)';
      pass++;
      debugPrint('T-U2 PASS $name (log: ${log.join(' | ')})');
    } catch (e) {
      fail++;
      debugPrint('T-U2 FAIL $name: $e');
    }
  }

  await run('length 0', () async => file().writeAsBytesSync(Uint8List(0)));
  await run('header version 2', () async {
    final b = file().readAsBytesSync();
    if (String.fromCharCodes(b.sublist(0, 3)) != 'BMR') throw 'premise: not the store header';
    b[3] = 2;
    file().writeAsBytesSync(b);
  });
  await run('ciphertext byte flipped', () async {
    final b = file().readAsBytesSync();
    b[b.length - 1] ^= 0x01;
    file().writeAsBytesSync(b);
  });
  await run('sealed body of version 2', () async {
    final store = RecordUiStore(dir, platform);
    final r = (await store.read())!;
    await store.write(r.$1, cborEncode(<Object, Object>{1: 2, 3: true}));
  });
  debugPrint('T-U2 DONE pass=$pass fail=$fail');
}
