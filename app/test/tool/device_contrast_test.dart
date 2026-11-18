// #329 PR 7 §4: tool/device_contrast.dart on synthetic screenshots (a PNG written here, every PNG filter type, RGB and
// RGBA) and a synthetic uiautomator dump: the ink is found even when antialiasing tones outnumber it (the reason the
// method is not Flutter's "most frequent dark colour"), a low-contrast text is LOW, a box with only a speck of
// another colour is NO-FG (❓, not a pass), an all-black FLAG_SECURE capture is SECURE?, and the table's numbers are
// WCAG's. Negative controls (run by hand, see the PR): fg = the most frequent other colour -> the antialiasing test
// FAILs; the 2 % floor removed -> the speck test FAILs.
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import '../../tool/device_contrast.dart';

const bg = 0xEFEAE0, ink = 0x1A1915, aa = 0xA39F98, pale = 0xB0AA9C;

/// A [w]×[h] picture filled with [fill]; [paint] sets pixels.
Rgba pic(int w, int h, int fill) {
  final d = Uint8List(w * h * 4);
  for (var i = 0; i < w * h; i++) {
    d[i * 4] = fill >> 16;
    d[i * 4 + 1] = (fill >> 8) & 0xFF;
    d[i * 4 + 2] = fill & 0xFF;
    d[i * 4 + 3] = 255;
  }
  return Rgba(w, h, d);
}

void put(Rgba p, int x, int y, int c) {
  final i = (y * p.width + x) * 4;
  p.data[i] = c >> 16;
  p.data[i + 1] = (c >> 8) & 0xFF;
  p.data[i + 2] = c & 0xFF;
}

/// Fills [x1, x2) × [y1, y2) with [c].
void rect(Rgba p, int x1, int y1, int x2, int y2, int c) {
  for (var y = y1; y < y2; y++) {
    for (var x = x1; x < x2; x++) {
      put(p, x, y, c);
    }
  }
}

int _crc(List<int> b) {
  var c = 0xFFFFFFFF;
  for (final v in b) {
    c ^= v;
    for (var k = 0; k < 8; k++) {
      c = (c & 1) != 0 ? 0xEDB88320 ^ (c >> 1) : c >> 1;
    }
  }
  return c ^ 0xFFFFFFFF;
}

/// A PNG of [p] (RGBA, or RGB when [rgb]); row y uses filter y % 5, so the decoder meets all five.
Uint8List png(Rgba p, {bool rgb = false}) {
  final bpp = rgb ? 3 : 4, stride = p.width * bpp;
  final raw = BytesBuilder();
  var prev = Uint8List(stride);
  for (var y = 0; y < p.height; y++) {
    final line = Uint8List(stride);
    for (var x = 0; x < p.width; x++) {
      for (var k = 0; k < bpp; k++) {
        line[x * bpp + k] = p.data[(y * p.width + x) * 4 + k];
      }
    }
    final f = y % 5;
    raw.addByte(f);
    for (var i = 0; i < stride; i++) {
      final a = i >= bpp ? line[i - bpp] : 0, b = prev[i], c = i >= bpp ? prev[i - bpp] : 0;
      final pr = switch (f) {
        0 => 0,
        1 => a,
        2 => b,
        3 => (a + b) >> 1,
        _ => () {
            final q = a + b - c, pa = (q - a).abs(), pb = (q - b).abs(), pc = (q - c).abs();
            return pa <= pb && pa <= pc ? a : (pb <= pc ? b : c);
          }(),
      };
      raw.addByte((line[i] - pr) & 0xFF);
    }
    prev = line;
  }
  final out = BytesBuilder()..add([137, 80, 78, 71, 13, 10, 26, 10]);
  void chunk(String name, List<int> body) {
    final head = ByteData(4)..setUint32(0, body.length);
    final typed = [...name.codeUnits, ...body];
    out
      ..add(head.buffer.asUint8List())
      ..add(typed)
      ..add((ByteData(4)..setUint32(0, _crc(typed))).buffer.asUint8List());
  }

  final ihdr = ByteData(13)
    ..setUint32(0, p.width)
    ..setUint32(4, p.height)
    ..setUint8(8, 8)
    ..setUint8(9, rgb ? 2 : 6);
  chunk('IHDR', ihdr.buffer.asUint8List());
  chunk('IDAT', zlib.encode(raw.takeBytes()));
  chunk('IEND', const []);
  return out.takeBytes();
}

/// The screen: three text boxes of 100×20 at y 0 / 20 / 40, plus one empty box at y 60.
/// - box 1: dark ink (6 %) with antialiasing tones (20 %, more than the ink): the ink is the foreground;
/// - box 2: pale text (10 %) on the background: LOW;
/// - box 3: one pixel of ink in a background box: NO-FG (a speck is no text);
/// - box 4: background only, NO-FG.
Rgba screen() {
  final p = pic(100, 80, bg);
  rect(p, 0, 0, 100, 4, aa); // 400 px = 20 % of 2000
  rect(p, 0, 4, 60, 6, ink); // 120 px = 6 %
  rect(p, 0, 20, 100, 22, pale); // 200 px = 10 %
  put(p, 50, 50, ink);
  return p;
}

const dump = '''<?xml version='1.0' encoding='UTF-8' standalone='yes' ?><hierarchy rotation="0">
<node index="0" text="" resource-id="" class="android.widget.FrameLayout" content-desc="" bounds="[0,0][100,80]">
<node index="0" text="" class="android.view.View" content-desc="首頁&#10;節點 7D2C" bounds="[0,0][100,20]" />
<node index="1" text="淡色字 &amp; 說明" class="android.view.View" content-desc="" bounds="[0,20][100,40]" />
<node index="2" text="" class="android.view.View" content-desc="一點" bounds="[0,40][100,60]" />
<node index="3" text="" class="android.view.View" content-desc="空" bounds="[0,60][100,80]" />
<node index="4" text="" class="android.view.View" content-desc="" bounds="[0,0][10,10]" />
<node index="5" text="外面" class="android.view.View" content-desc="" bounds="[200,200][300,300]" />
</node></hierarchy>''';

void main() {
  test('WCAG numbers: black / white 21, a colour on itself 1, #767676 on white ≈ 4.54', () {
    expect(wcag(0x000000, 0xFFFFFF), closeTo(21, 0.01));
    expect(wcag(0x336699, 0x336699), 1);
    expect(wcag(0x767676, 0xFFFFFF), closeTo(4.54, 0.01));
    expect(wcag(ink, bg), closeTo(wcag(bg, ink), 1e-12), reason: 'symmetric');
  });

  test('PNG round trip: RGBA and RGB, all five filters', () {
    final p = screen();
    for (final rgb in [false, true]) {
      final d = decodePng(png(p, rgb: rgb));
      expect((d.width, d.height), (100, 80));
      for (var y = 0; y < 80; y++) {
        for (var x = 0; x < 100; x++) {
          expect(d.rgb(x, y), p.rgb(x, y), reason: 'rgb=$rgb ($x, $y)');
        }
      }
    }
    expect(() => decodePng(Uint8List.fromList([1, 2, 3])), throwsFormatException);
  });

  test('the ink is the foreground even when antialiasing tones outnumber it', () {
    final m = measure(screen(), 0, 0, 100, 20)!;
    expect(m.bg, bg);
    expect(m.fg, ink, reason: 'largest luminance difference, not the most frequent other colour (that is $aa)');
    expect(m.fgShare, closeTo(0.06, 1e-9));
    expect(m.ratio, closeTo(wcag(ink, bg), 1e-9));
    expect(m.ratio, greaterThan(4.5));
  });

  // S20, 2026-11-18: a dark card row (984 × 192 px) with a 1-px border and a short light label — measured over the
  // whole box the border (3.4 %) won over the label's ink (< 2 %) and the row read 1.39 (LOW). Negative controls: the
  // share against the whole box, or no inset -> the border is the foreground and this FAILs.
  test('a card row: the label, not the card border, is the foreground', () {
    const cardBg = 0x211F18, border = 0x3B372B, label = 0xEFE9D9, page = 0x14130F;
    final p = pic(300, 80, page);
    rect(p, 10, 10, 290, 70, border); // the card, its 1-px border
    rect(p, 11, 11, 289, 69, cardBg);
    rect(p, 40, 30, 70, 34, label); // 120 px of ink in a 280 × 60 box (0.7 %)
    final rows = report([const UiNode('新增節點', 10, 10, 290, 70)], p);
    expect(rows[1], startsWith('PASS'), reason: rows[1]);
    expect(rows[1], contains(hex(label)));
  });

  test('pale text is LOW; a one-pixel speck is no foreground (NO-FG)', () {
    final p = screen();
    final pale1 = measure(p, 0, 20, 100, 40)!;
    expect(pale1.fg, pale);
    expect(pale1.ratio, lessThan(4.5));
    final speck = measure(p, 0, 40, 100, 60)!;
    expect(speck.fg, isNull, reason: 'one pixel of 2000 is under the 2 % floor');
    expect(speck.ratio, 1.0);
    expect(measure(p, 200, 200, 300, 300), isNull, reason: 'outside the picture');
  });

  test('the uiautomator dump: text or content-desc, entities, bounds; empty nodes skipped', () {
    final n = parseUiDump(dump);
    expect(n.map((e) => e.words), ['首頁\n節點 7D2C', '淡色字 & 說明', '一點', '空', '外面']);
    expect((n[1].x1, n[1].y1, n[1].x2, n[1].y2), (0, 20, 100, 40));
  });

  test('the table: PASS / LOW / NO-FG / OFF, and an all-black capture is SECURE? for every row', () {
    final rows = report(parseUiDump(dump), decodePng(png(screen())));
    expect(rows.first, startsWith('verdict'));
    expect(rows.skip(1).map((r) => r.split('\t').first), ['PASS', 'LOW', 'NO-FG', 'NO-FG', 'OFF']);
    expect(rows[1], contains('#1A1915 (6.0%)'));
    expect(rows[1], contains(wcag(ink, bg).toStringAsFixed(2)));
    final black = report(parseUiDump(dump), pic(100, 80, 0x000000));
    expect(black.skip(1).every((r) => r.startsWith('SECURE?')), isTrue);
  });

  test('the command line: exit 1 with a LOW row, the table printed', () async {
    final d = Directory.systemTemp.createTempSync('contrast');
    try {
      File('${d.path}/dump.xml').writeAsStringSync(dump);
      File('${d.path}/screen.png').writeAsBytesSync(png(screen()));
      final dart = '${Platform.environment['FLUTTER_ROOT'] ?? 'C:/src/flutter'}/bin/cache/dart-sdk/bin/dart${Platform.isWindows ? '.exe' : ''}';
      final r = await Process.run(dart, ['tool/device_contrast.dart', '${d.path}/dump.xml', '${d.path}/screen.png']);
      expect(r.exitCode, 1, reason: '${r.stdout}${r.stderr}');
      expect(r.stdout as String, contains('5 nodes, 1 PASS, 4 not PASS'));
      File('${d.path}/empty.xml').writeAsStringSync('<hierarchy></hierarchy>');
      final e = await Process.run(dart, ['tool/device_contrast.dart', '${d.path}/empty.xml', '${d.path}/screen.png']);
      expect(e.exitCode, 1, reason: 'nothing measured is not a pass');
    } finally {
      d.deleteSync(recursive: true);
    }
  });
}
