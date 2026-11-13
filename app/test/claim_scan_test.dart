// 254-app-qr §5 D1: the claim page's 「掃描 QR」 button is there in every flavor; a scan that comes back null changes
// nothing; error `camera` shows the camera hint; a scanned text goes through the one parser (Rust, mocked here) and
// shows the node number's last 4. Code review r1: the button is off while a scan is open (A-m4); a text that is not a
// claim QR forgets the QR read before (A-m5). The platform channel and the Rust API are fakes; nothing needs BLE or a
// camera.
import 'dart:async';
import 'dart:collection';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:batman_app/claim.dart';
import 'package:batman_app/src/rust/api/claim.dart';
import 'package:batman_app/src/rust/frb_generated.dart';

const qrText = 'a201726261746d616e2d746573742d71722d303102582000112233445566778899aabbccddeeff0011';
const notClaim = 'https://example.com/not-a-claim';
const deviceId = '0000000000000c4f2a';

/// only parseClaimQr is used by the scan path; anything else fails the test
class FakeRust implements RustLibApi {
  final parsed = <String>[];
  @override
  Future<ClaimQr> crateApiClaimParseClaimQr({required String text}) async {
    parsed.add(text);
    if (text != qrText) throw 'not hex';
    return ClaimQr(deviceId: deviceId, k: Uint8List(32));
  }

  @override
  dynamic noSuchMethod(Invocation i) => throw UnimplementedError('${i.memberName}');
}

void main() {
  final rust = FakeRust();
  setUpAll(() => RustLib.initMock(api: rust));

  /// [scans]: what each scanQr call answers — a String / null, a PlatformException to throw, or a Completer to wait on
  Future<void> page(WidgetTester t, {required bool dev, required List<Object?> scans}) async {
    rust.parsed.clear();
    final queue = Queue<Object?>.of(scans);
    t.binding.defaultBinaryMessenger.setMockMethodCallHandler(const MethodChannel('dev.batman/platform'), (c) async {
      switch (c.method) {
        case 'devTrust':
          return dev;
        case 'scanQr':
          final next = queue.removeFirst();
          if (next is PlatformException) throw next;
          if (next is Completer<String?>) return next.future;
          return next;
      }
      return null;
    });
    await t.pumpWidget(const MaterialApp(home: ClaimPage()));
    await t.pumpAndSettle();
  }

  FilledButton button(WidgetTester t, String label) => t.widget<FilledButton>(find.widgetWithText(FilledButton, label));
  Future<void> scan(WidgetTester t) async {
    await t.tap(find.text('掃描 QR'));
    await t.pumpAndSettle();
  }

  const read = '已讀取節點（編號末四碼 …4f2a）的 QR 碼，可以按「認領」';

  for (final dev in [true, false]) {
    final flavor = dev ? 'dev' : 'field';

    testWidgets('$flavor: the scan button is there; a null scan changes nothing', (t) async {
      await page(t, dev: dev, scans: [null]);
      expect(find.text('掃描 QR'), findsOneWidget);
      await scan(t);
      expect(rust.parsed, isEmpty);
      expect(button(t, '認領').onPressed, isNull, reason: 'no QR read');
      expect(find.descendant(of: find.byType(ListView), matching: find.byType(Text)), findsNothing, reason: 'no line said');
    });

    testWidgets('$flavor: a scanned text is parsed, shows the last 4; a later null keeps it', (t) async {
      final logs = <String>[];
      final old = debugPrint;
      debugPrint = (String? m, {int? wrapWidth}) => logs.add(m ?? '');
      try {
        await page(t, dev: dev, scans: [qrText, null]);
        await scan(t);
        expect(rust.parsed, [qrText]);
        expect(find.text(read), findsOneWidget);
        expect(button(t, '認領').onPressed, isNotNull);
        await scan(t);
        expect(rust.parsed, [qrText], reason: 'null: nothing parsed again');
        expect(find.text(read), findsOneWidget);
        expect(button(t, '認領').onPressed, isNotNull, reason: 'the QR read before is kept');
      } finally {
        debugPrint = old;
      }
      expect(logs, isNotEmpty, reason: 'the read was logged (by its last 4 only)');
      expect(logs.where((l) => l.contains(qrText) || l.contains(deviceId)), isEmpty, reason: 'the QR is never logged');
    });

    testWidgets('$flavor: a QR that is not a claim QR forgets the one read before', (t) async {
      await page(t, dev: dev, scans: [qrText, notClaim]);
      await scan(t);
      expect(button(t, '認領').onPressed, isNotNull);
      await scan(t);
      expect(rust.parsed, [qrText, notClaim]);
      expect(find.textContaining('這不是認領用的 QR 碼'), findsOneWidget);
      expect(button(t, '認領').onPressed, isNull, reason: 'no claim of the previous node');
    });

    testWidgets('$flavor: the scan button is off while a scan is open', (t) async {
      final open = Completer<String?>();
      await page(t, dev: dev, scans: [open]);
      await t.tap(find.text('掃描 QR'));
      await t.pump();
      expect(button(t, '掃描 QR').onPressed, isNull, reason: 'a second tap would be busy');
      open.complete(null);
      await t.pumpAndSettle();
      expect(button(t, '掃描 QR').onPressed, isNotNull);
    });

    testWidgets('$flavor: error camera shows the camera hint', (t) async {
      await page(t, dev: dev, scans: [PlatformException(code: 'camera')]);
      await scan(t);
      expect(find.text('無法使用相機：請確認已允許相機權限，且沒有其他 app 正在使用相機'), findsOneWidget);
      expect(button(t, '認領').onPressed, isNull);
      expect(button(t, '掃描 QR').onPressed, isNotNull, reason: 'can try again');
    });
  }
}
