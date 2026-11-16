// #329 PR 3 v18 §2.9 (AG-M1, code review A m-4): Kotlin's `open` answers every failure with the code "keystore", so a
// record that does not open is 「這筆打不開」 — never a key error, never an exception out of the flows. The app's two
// readers: ConsolePlatform.readRecord (the console's requests) and flowDeps.applied (a record read again under the
// lease). Real AppLink, fake Rust store, mocked platform channel.
import 'dart:typed_data';

import 'package:batman_app/src/nodelink/app_link.dart';
import 'package:batman_app/src/nodelink/lease.dart';
import 'package:batman_app/src/rust/api/owner.dart';
import 'package:batman_app/src/rust/frb_generated.dart';
import 'package:batman_app/ui/net_pages.dart' show flowDeps;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'pages_test.dart' show FakeRust, app;

class StoreRust extends FakeRust {
  SealedRecord? sealed;
  bool applied = true;
  @override
  Future<SealedRecord?> crateApiOwnerStoreReadSealed({required String dir, required String rel}) async => sealed;
  @override
  NetView crateApiOwnerNetSummary({required List<int> recordPlain}) =>
      NetView(netId: 'n', meshId: 'bm', netName: 'n', applied: applied, country: 'US', members: const []);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final rust = StoreRust();
  setUpAll(() => RustLib.initMock(api: rust));

  Object? openFails; // what the platform's `open` throws (null = it opens)
  setUp(() {
    rust
      ..sealed = SealedRecord(generation: BigInt.from(7), sealed: Uint8List(3), aad: Uint8List(1))
      ..applied = true;
    openFails = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('dev.batman/platform'), (c) async {
      if (c.method != 'open') return null;
      final f = openFails;
      if (f != null) throw f;
      return Uint8List(4);
    });
  });
  tearDown(AppLink.forgetForTest);

  test('readRecord: a record that does not open (keystore) -> its generation and no bytes, not an error', () async {
    final a = app();
    openFails = PlatformException(code: 'keystore', message: 'AEADBadTagException');
    final (gen, plain) = await a.console.readRecord('net/n');
    expect((gen, plain), (BigInt.from(7), null));
    openFails = null;
    final (_, ok) = await a.console.readRecord('net/n');
    expect(ok, isNotNull);
    rust.sealed = null;
    final (g0, none) = await a.console.readRecord('net/n');
    expect((g0, none), (BigInt.zero, null), reason: 'no record');
  });

  test('flowDeps.applied: opens -> the record\'s applied; does not open / no record -> false (檢查網路), never a throw',
      () async {
    final a = app();
    final l = a.reg.acquire('建立網路', LeaseKind.session)!;
    final applied = flowDeps(a, l, askCountry: (_) async => false, askRemoved: (_) async => false).applied;
    expect(await applied('net/n'), isTrue);
    rust.applied = false;
    expect(await applied('net/n'), isFalse);
    rust.applied = true;
    openFails = PlatformException(code: 'keystore');
    expect(await applied('net/n'), isFalse);
    openFails = null;
    rust.sealed = null;
    expect(await applied('net/n'), isFalse);
    await l.release();
  });
}
