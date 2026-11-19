// #329 rotating identifier (329-rotating-id-plan.md v6.1 §3.3 / §8 S9): building the resolver from the node records.
// A record that does not open is left out; a key error while opening one is not reported as 「金鑰無法使用」 (that is
// the login's to say, when it opens the record itself).
import 'dart:async';
import 'dart:io';

import 'package:batman_app/src/nodelink/app_link.dart';
import 'package:batman_app/src/nodelink/core.dart';
import 'package:batman_app/src/rust/frb_generated.dart';
import 'package:flutter/services.dart';
import 'package:flutter_reactive_ble/flutter_reactive_ble.dart';
import 'package:flutter_test/flutter_test.dart';

import 'retest_h_unseal_test.dart' show CountingRust, OneNodeBle, id, platform, until;

/// Nothing advertises: no login opens a record, only the resolver build does.
class QuietBle extends OneNodeBle {
  @override
  Stream<DiscoveredDevice> scanForDevices(
          {required List<Uuid> withServices,
          ScanMode scanMode = ScanMode.balanced,
          bool requireLocationServicesEnabled = true}) =>
      StreamController<DiscoveredDevice>().stream;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('buildResolver: records that do not open are left out; the opened bytes are zeroed afterwards', () async {
    final plains = {'a': Uint8List.fromList([1, 2, 3]), 'd': Uint8List.fromList([4, 5])};
    final asked = <String>[];
    List<List<int>>? got;
    final r = await buildResolver(['a', 'b', 'c', 'd'], (id) async {
      asked.add(id);
      if (id == 'b') return null; // no record file
      if (id == 'c') throw PlatformException(code: 'keyLevel', message: 'RECORD_AES'); // the Keystore refused
      return plains[id];
    }, (p) {
      got = [for (final x in p) [...x]];
      return (mfr) => 'n${p.length}';
    });
    expect(asked, ['a', 'b', 'c', 'd'], reason: 'a failure does not stop the others');
    expect(got, [
      [1, 2, 3],
      [4, 5]
    ]);
    expect(r(Uint8List(8)), 'n2');
    expect(plains.values.every((p) => p.every((b) => b == 0)), isTrue, reason: 'zeroed once the resolver has them');
  });

  test('buildResolver: the opened bytes are zeroed when making the resolver throws', () async {
    final plain = Uint8List.fromList([9, 9]);
    await expectLater(buildResolver(['a'], (_) async => plain, (_) => throw StateError('x')), throwsStateError);
    expect(plain, [0, 0]);
  });

  test('AppLink: a key error while the resolver build opens a record does not turn 「金鑰無法使用」 on', () async {
    final rust = CountingRust();
    RustLib.initMock(api: rust);
    final dir = Directory.systemTemp.createTempSync('bm-advid');
    final calls = <String>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(platform, (c) async {
      calls.add(c.method);
      switch (c.method) {
        case 'open':
          throw PlatformException(code: 'keyLevel', message: 'RECORD_AES'); // details null: the key is gone
        case 'publicKeys':
          return {'owner': Uint8List(65)};
        case 'keyLevels':
          return {'appUsable': true, 'login': true, 'claim': true, 'recover': true, 'makeNetwork': true, 'softOwnerEnc': false};
      }
      return null;
    });
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(platform, null);
      AppLink.forgetForTest();
    });
    AppLink.forgetForTest();
    final ble = QuietBle();
    final a = AppLink.create(platform: platform, filesDir: dir.path, ble: ble);
    addTearDown(() => a.link.dispose());
    ble.bleStatus.add(BleStatus.ready);
    await a.link.start(Page.home);
    await until(() => calls.contains('open'), 'the resolver build opening the node record');
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(rust.reads, ['node/$id']);
    expect(calls.where((m) => m == 'open'), hasLength(1));
    expect(a.link.core.keys, isTrue);
    expect(a.link.core.blocked, isNull, reason: 'no overlay: the build never reports a key error');
    expect(calls.where((m) => m == 'keyLevels'), isEmpty, reason: 'the build does not read the key abilities');
    expect(a.link.core.roundActive, isTrue, reason: 'the round goes on, the node is looked for the old way');
  });
}
