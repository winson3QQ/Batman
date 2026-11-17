// #329 PR 5 plan v16 §2.2 / §6 step 2: CodeView and CodeInput against fake platform calls.
// R1 when a QR is drawn, R2 every device pixel of every module, R3 FLAG_SECURE fallback (and the Wi-Fi page's default
// unchanged), R4 copy / clear / leave reminder / paste always clears, R5 scan and paste reach one onText.
import 'dart:math';
import 'dart:ui' as ui;

import 'package:batman_app/secure_screen.dart';
import 'package:batman_app/ui/code_view.dart';
import 'package:batman_app/ui/theme.dart';
import 'package:batman_app/ui/widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// a fake platform that records calls
class FakeCode {
  QrBits? qr;
  final asked = <String>[];
  String? clip = 'something';
  int copies = 0, clears = 0;
  String? copyError, clearError;
  Object? scanResult; // String? or PlatformException

  CodePlatform get p => CodePlatform(
        qrMatrix: (hex) async {
          asked.add(hex);
          return qr;
        },
        copy: (text) async {
          copies++;
          if (copyError == null) clip = text;
          return copyError;
        },
        clear: () async {
          clears++;
          if (clearError == null) clip = null;
          return clearError;
        },
        read: () async => clip,
        scan: () async {
          final r = scanResult;
          if (r is PlatformException) throw r;
          return r as String?;
        },
      );
}

/// a well-formed QR of [version] with random modules (R1 checks the shape only)
QrBits bitsOf(int version, {int seed = 7}) {
  final size = 17 + 4 * version;
  final r = Random(seed);
  return QrBits(size, version, Uint8List.fromList(List.generate(size * ((size + 7) ~/ 8), (_) => r.nextInt(256))));
}

Widget host(Widget w) => MaterialApp(
      theme: batThemeData(Brightness.light),
      home: Scaffold(body: Padding(padding: const EdgeInsets.all(16), child: SingleChildScrollView(child: w))),
    );

void main() {
  void secure(WidgetTester t, bool on) =>
      t.binding.defaultBinaryMessenger.setMockMethodCallHandler(secureChannel, (c) async => on);

  /// a tall phone (400 x 1600 logical) so the buttons under the QR are on screen
  void tall(WidgetTester t) {
    t.view.devicePixelRatio = 3;
    t.view.physicalSize = const Size(1200, 4800);
    addTearDown(t.view.reset);
  }

  group('R1: when a QR is drawn', () {
    test('only a well-formed QR of version ≤ 27', () {
      expect(qrDrawable(bitsOf(1)), isTrue);
      expect(qrDrawable(bitsOf(27)), isTrue);
      expect(qrDrawable(bitsOf(28)), isFalse, reason: 'over the R-8 limit');
      expect(qrDrawable(null), isFalse);
      final b = bitsOf(5);
      expect(qrDrawable(QrBits(b.size + 1, 5, b.bits)), isFalse, reason: 'size != 17 + 4v');
      expect(qrDrawable(QrBits(b.size, 5, Uint8List(b.bits.length - 1))), isFalse, reason: 'bits too short');
    });

    testWidgets('v28 -> no QR, the reason, and 複製文字 still there', (t) async {
      secure(t, true);
      final f = FakeCode()..qr = bitsOf(28);
      await t.pumpWidget(host(CodeView(hex: 'a201', platform: f.p)));
      await t.pumpAndSettle();
      expect(find.byKey(const Key('code-qr')), findsNothing);
      expect(find.byKey(const Key('code-toolong')), findsOneWidget);
      expect(find.text(Btn.copyText), findsOneWidget);
      expect(f.asked, ['A201'], reason: 'the QR text is the hex upper-cased');
    });
  });

  testWidgets('R2: every device pixel of every module, at a fractional device pixel ratio', (t) async {
    secure(t, true);
    t.view.devicePixelRatio = 2.75;
    t.view.physicalSize = const Size(1100, 2400);
    addTearDown(t.view.reset);
    final q = bitsOf(3, seed: 11);
    final f = FakeCode()..qr = q;
    await t.pumpWidget(host(CodeView(hex: 'ab', platform: f.p)));
    await t.pumpAndSettle();
    final box = t.renderObject<RenderRepaintBoundary>(find.byKey(const Key('code-qr')));
    final dpr = t.view.devicePixelRatio;
    final img = (await t.runAsync(() => box.toImage(pixelRatio: dpr)))!;
    final data = (await t.runAsync(() => img.toByteData(format: ui.ImageByteFormat.rawRgba)))!;
    final px = img.width ~/ (q.size + 8);
    expect(px, greaterThan(0));
    expect(img.width, px * (q.size + 8), reason: 'a whole number of device pixels per module');
    var checked = 0;
    for (var y = 0; y < img.height; y++) {
      for (var x = 0; x < img.width; x++) {
        final mx = x ~/ px - 4, my = y ~/ px - 4;
        final black = mx >= 0 && my >= 0 && mx < q.size && my < q.size && q.on(mx, my);
        final r = data.getUint8((y * img.width + x) * 4);
        expect(r, black ? 0 : 255, reason: 'pixel ($x,$y) module ($mx,$my)');
        checked++;
      }
    }
    expect(checked, img.width * img.height);
  });

  group('R3: FLAG_SECURE cannot be set', () {
    testWidgets('CodeView: no QR, the fallback with the clipboard warning, copy still works', (t) async {
      tall(t);
      secure(t, false);
      final f = FakeCode()..qr = bitsOf(2);
      await t.pumpWidget(host(CodeView(hex: 'ab', platform: f.p)));
      await t.pumpAndSettle();
      expect(find.byKey(const Key('code-qr')), findsNothing);
      expect(find.byKey(const Key('code-noqr')), findsOneWidget);
      expect(find.byKey(const Key('code-clipwarn')), findsOneWidget, reason: 'always shown on such a phone');
      await t.tap(find.text(Btn.copyText));
      await t.pumpAndSettle();
      expect(f.copies, 1);
    });

    testWidgets('a SecureScreen without fallback keeps the default sentence (the Wi-Fi page)', (t) async {
      secure(t, false);
      await t.pumpWidget(host(const SecureScreen(child: Text('secret'))));
      await t.pumpAndSettle();
      expect(find.text('secret'), findsNothing);
      expect(find.text('這支手機無法防止這個畫面被截圖，所以不顯示內容'), findsOneWidget);
    });
  });

  group('R4: clipboard', () {
    testWidgets('review A m5 / T-m8: after a copy the clipboard warning shows even with a QR on a secure screen', (t) async {
      tall(t);
      secure(t, true);
      final f = FakeCode()..qr = bitsOf(1);
      await t.pumpWidget(host(CodeView(hex: 'ab', platform: f.p)));
      await t.pumpAndSettle();
      expect(find.byKey(const Key('code-clipwarn-copied')), findsNothing);
      await t.tap(find.text(Btn.copyText));
      await t.pumpAndSettle();
      expect(find.byKey(const Key('code-clipwarn-copied')), findsOneWidget);
    });

    testWidgets('T10: an update bundle (qr: false) never asks for a QR; copy and the warning still there', (t) async {
      tall(t);
      secure(t, true);
      final f = FakeCode()..qr = bitsOf(1);
      await t.pumpWidget(host(CodeView(hex: 'ab', platform: f.p, qr: false)));
      await t.pumpAndSettle();
      expect(f.asked, isEmpty);
      expect(find.byKey(const Key('code-qr')), findsNothing);
      expect(find.byKey(const Key('code-clipwarn')), findsOneWidget);
      await t.tap(find.text(Btn.copyText));
      await t.pumpAndSettle();
      expect(f.clip, 'ab');
    });

    testWidgets('copy -> 清除剪貼簿 appears and clears; no reminder after clearing', (t) async {
      tall(t);
      secure(t, true);
      final f = FakeCode()..qr = bitsOf(1);
      await t.pumpWidget(host(CodeView(hex: 'ab', platform: f.p)));
      await t.pumpAndSettle();
      expect(find.text(Btn.clearClip), findsNothing, reason: 'only after a copy');
      await t.tap(find.text(Btn.copyText));
      await t.pumpAndSettle();
      expect(f.clip, 'ab', reason: 'the lower-case hex is copied');
      await t.tap(find.text(Btn.clearClip));
      await t.pumpAndSettle();
      expect(f.clears, 1);
      expect(f.clip, isNull);
      await t.pumpWidget(host(const SizedBox()));
      await t.pump();
      expect(find.text('剛才複製的碼還在剪貼簿'), findsNothing);
    });

    testWidgets('leaving with the code still copied -> one reminder', (t) async {
      tall(t);
      secure(t, true);
      final f = FakeCode()..qr = bitsOf(1);
      final page = GlobalKey<NavigatorState>();
      await t.pumpWidget(MaterialApp(
          navigatorKey: page,
          theme: batThemeData(Brightness.light),
          home: const Scaffold(body: Text('base'))));
      page.currentState!.push(MaterialPageRoute(builder: (_) => Scaffold(body: CodeView(hex: 'ab', platform: f.p))));
      await t.pumpAndSettle();
      await t.tap(find.text(Btn.copyText));
      await t.pumpAndSettle();
      page.currentState!.pop();
      await t.pumpAndSettle();
      expect(find.text('剛才複製的碼還在剪貼簿'), findsOneWidget);
    });

    testWidgets('a copy too large says so', (t) async {
      tall(t);
      secure(t, true);
      final f = FakeCode()
        ..qr = bitsOf(1)
        ..copyError = 'clipTooLarge';
      await t.pumpWidget(host(CodeView(hex: 'ab', platform: f.p)));
      await t.pumpAndSettle();
      await t.tap(find.text(Btn.copyText));
      await t.pumpAndSettle();
      expect(find.text('這段太大，無法複製'), findsOneWidget);
      expect(find.text(Btn.clearClip), findsNothing, reason: 'nothing was copied');
    });
  });

  group('R5 + R4: CodeInput', () {
    Future<(List<String>, List<String>)> run(WidgetTester t, FakeCode f, {required bool dev, required String tap}) async {
      final got = <String>[], errs = <String>[];
      await t.pumpWidget(host(CodeInput(devTrust: dev, platform: f.p, onText: got.add, onError: errs.add)));
      if (find.text(tap).evaluate().isNotEmpty) {
        await t.tap(find.text(tap));
        await t.pumpAndSettle();
      }
      return (got, errs);
    }

    testWidgets('paste: text through, clipboard cleared', (t) async {
      final f = FakeCode()..clip = 'A2 01 ff';
      final (got, errs) = await run(t, f, dev: true, tap: Btn.pasteText);
      expect(got, ['A2 01 ff'], reason: 'raw: Rust parses case and spaces');
      expect(errs, isEmpty);
      expect(f.clears, 1);
    });

    testWidgets('paste refused (empty / too long) still clears the clipboard', (t) async {
      final empty = FakeCode()..clip = '   ';
      final (g1, e1) = await run(t, empty, dev: true, tap: Btn.pasteText);
      expect(g1, isEmpty);
      expect(e1, ['剪貼簿是空的']);
      expect(empty.clears, 1);
      final long = FakeCode()..clip = 'a' * (kPasteMax + 1);
      final (g2, e2) = await run(t, long, dev: true, tap: Btn.pasteText);
      expect(g2, isEmpty);
      expect(e2, ['這段文字太長，不是 app 產生的碼']);
      expect(long.clears, 1);
    });

    testWidgets('no paste button outside the dev build; scan still works', (t) async {
      final f = FakeCode()..scanResult = 'a201';
      final (got, _) = await run(t, f, dev: false, tap: Btn.scanQr);
      expect(find.text(Btn.pasteText), findsNothing);
      expect(got, ['a201']);
    });

    testWidgets('scan: camera error -> the claim page sentence; left without a code -> nothing', (t) async {
      final cam = FakeCode()..scanResult = PlatformException(code: 'camera');
      final (g1, e1) = await run(t, cam, dev: true, tap: Btn.scanQr);
      expect(g1, isEmpty);
      expect(e1.single, startsWith('無法使用相機'));
      final none = FakeCode()..scanResult = null;
      final (g2, e2) = await run(t, none, dev: true, tap: Btn.scanQr);
      expect(g2, isEmpty);
      expect(e2, isEmpty);
    });
  });
}
