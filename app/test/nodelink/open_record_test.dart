// #329 PR 5 R8 (review A m1 / C m3): the hint's record opener. A key error while opening is thrown on, so the hint
// keeps its last value (prober _hint's catch); it is never read as 「no record」, which would clear the hint.
import 'package:batman_app/src/nodelink/app_link.dart' show openSealedRecord;
import 'package:batman_app/src/rust/frb_generated.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../nodes_update_send_test.dart' show FakeRust;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final rust = FakeRust();
  setUpAll(() => RustLib.initMock(api: rust));
  const channel = MethodChannel('dev.batman/platform');

  test('a key error while opening is thrown on, not 「no record」', () async {
    rust.records.add('net/aa');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, (c) async {
      if (c.method == 'open') throw PlatformException(code: 'KEY_LOCKED');
      return null;
    });
    await expectLater(openSealedRecord(channel, '/x', 'net/aa'), throwsA(isA<PlatformException>()));
  });

  test('no record on disk -> null (the hint is cleared only then)', () async {
    expect(await openSealedRecord(channel, '/x', 'net/none'), isNull);
  });
}
