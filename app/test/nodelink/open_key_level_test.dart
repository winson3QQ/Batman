// #329 PR 7 T1: Kotlin's `open` now goes through the key gate (KeyHandlers.open: the record AES key's level only) and
// answers a refusal as error `keyLevel` (message RECORD_AES, details = its level), the same shape as the other key
// uses. This drives the real AppLink (its NodeLink, SessionProber and keyError wiring) with a fake radio, a fake Rust
// API and a platform channel whose `open` answers that refusal: X26 must take it, so the home page shows 2.4 (Why.keys,
// home_logic decideHome row 2). A regression guard on the Dart side: it also passes before T1 (the prober already sent
// every open error to keyCheck); the negative controls of T1 itself are Kotlin's KeyHandlersTest and
// MainActivityKeyUseLintTest. Negative control of this test: prober.dart's keyCheck(e) on an open error removed -> FAIL.
import 'dart:io';

import 'package:batman_app/src/nodelink/app_link.dart';
import 'package:batman_app/src/nodelink/core.dart';
import 'package:batman_app/src/rust/frb_generated.dart';
import 'package:flutter/services.dart';
import 'package:flutter_reactive_ble/flutter_reactive_ble.dart';
import 'package:flutter_test/flutter_test.dart';

import 'retest_h_unseal_test.dart' show CountingRust, OneNodeBle, until;

const platform = MethodChannel('dev.batman/platform');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final rust = CountingRust();
  setUpAll(() => RustLib.initMock(api: rust));

  late Directory dir;
  final calls = <String>[];
  setUp(() {
    dir = Directory.systemTemp.createTempSync('bm-t1-open');
    calls.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(platform, (c) async {
      calls.add(c.method);
      switch (c.method) {
        case 'open': // KeyHandlers.open: RECORD_AES not allowed in this build (level 0 = SOFTWARE)
          throw PlatformException(code: 'keyLevel', message: 'RECORD_AES', details: 0);
        case 'publicKeys':
          return {'owner': Uint8List(65)};
        case 'signOwner':
          return Uint8List(70);
      }
      return null;
    });
  });
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(platform, null);
    AppLink.forgetForTest();
    dir.deleteSync(recursive: true);
  });

  test('T1: open refused as keyLevel RECORD_AES -> X26 (2.4), no login attempted', () async {
    AppLink.forgetForTest();
    final ble = OneNodeBle();
    final a = AppLink.create(platform: platform, filesDir: dir.path, ble: ble);
    addTearDown(() => a.link.dispose());
    ble.bleStatus.add(BleStatus.ready);
    expect(a.link.core.blocked, isNull, reason: 'before: nothing blocks');

    await a.link.start(Page.home);
    await until(() => calls.contains('open'), 'the record open of the first home read');
    await until(() => a.link.core.blocked == Why.keys, 'X26 after the open refusal');

    expect(calls, isNot(contains('signOwner')), reason: 'the refused open ends the attempt before any key use');
    expect(rust.sessions, 0, reason: 'no session without the opened record');
  });
}
