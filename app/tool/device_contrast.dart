// #329 PR 7 §4 (acceptance line 92): text contrast measured on the phone's real pixels, on the PC (pure Dart, no
// python). Input: an `adb shell uiautomator dump` XML and an `adb exec-out screencap -p` PNG of the same screen.
// For each node with a text or content-desc: in its bounds, the colour histogram; background = the most frequent
// colour; foreground = of the colours covering ≥ 2 % of the box, the one whose relative luminance differs most from
// the background; ratio = WCAG 2 contrast ((L1 + 0.05) / (L2 + 0.05)). The board tests (test/support/a11y.dart) use the
// same measure() on the rendered boards, so the board and the device numbers come from one method.
//
// A node with no colour but the background over 2 % says NO-FG (❓, not a pass); a screenshot that is all one colour
// (FLAG_SECURE gives an all-black capture) makes every row ❓ SECURE?. Nothing is sent anywhere; the files are only read.
//
// Usage: dart run tool/device_contrast.dart <dump.xml> <screen.png> [--min 4.5]
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

/// An RGBA picture (8 bits per channel, rows top to bottom).
class Rgba {
  Rgba(this.width, this.height, this.data) : assert(data.length == width * height * 4);
  final int width, height;
  final Uint8List data;

  /// 0xRRGGBB of the pixel (alpha ignored: a screenshot is opaque).
  int rgb(int x, int y) {
    final i = (y * width + x) * 4;
    return (data[i] << 16) | (data[i + 1] << 8) | data[i + 2];
  }
}

/// Decodes an 8-bit, non-interlaced PNG of colour type 2 (RGB) or 6 (RGBA) — what Android's screencap writes and
/// what Flutter's toByteData(png) writes. Anything else throws a FormatException (never a silent wrong picture).
Rgba decodePng(Uint8List bytes) {
  const sig = [137, 80, 78, 71, 13, 10, 26, 10];
  if (bytes.length < 8 || [for (var i = 0; i < 8; i++) bytes[i]].join(',') != sig.join(',')) {
    throw const FormatException('not a PNG');
  }
  final bd = ByteData.sublistView(bytes);
  var p = 8, w = 0, h = 0, type = -1;
  final idat = BytesBuilder(copy: false);
  while (p + 8 <= bytes.length) {
    final len = bd.getUint32(p);
    final name = String.fromCharCodes(bytes.sublist(p + 4, p + 8));
    final body = Uint8List.sublistView(bytes, p + 8, p + 8 + len);
    if (name == 'IHDR') {
      w = ByteData.sublistView(body).getUint32(0);
      h = ByteData.sublistView(body).getUint32(4);
      final depth = body[8], interlace = body[12];
      type = body[9];
      if (depth != 8 || interlace != 0 || (type != 2 && type != 6)) {
        throw FormatException('PNG not supported: depth $depth, colour type $type, interlace $interlace');
      }
    } else if (name == 'IDAT') {
      idat.add(body);
    } else if (name == 'IEND') {
      break;
    }
    p += 12 + len;
  }
  if (type < 0) throw const FormatException('PNG without IHDR');
  final raw = Uint8List.fromList(zlib.decode(idat.takeBytes()));
  final bpp = type == 6 ? 4 : 3, stride = w * bpp;
  if (raw.length != h * (stride + 1)) throw FormatException('PNG data is ${raw.length} bytes, expected ${h * (stride + 1)}');
  final out = Uint8List(w * h * 4);
  var prev = Uint8List(stride);
  for (var y = 0; y < h; y++) {
    final f = raw[y * (stride + 1)];
    final line = Uint8List.fromList(raw.sublist(y * (stride + 1) + 1, (y + 1) * (stride + 1)));
    for (var i = 0; i < stride; i++) {
      final a = i >= bpp ? line[i - bpp] : 0, b = prev[i], c = i >= bpp ? prev[i - bpp] : 0;
      final add = switch (f) {
        0 => 0,
        1 => a,
        2 => b,
        3 => (a + b) >> 1,
        4 => _paeth(a, b, c),
        _ => throw FormatException('PNG filter $f'),
      };
      line[i] = (line[i] + add) & 0xFF;
    }
    for (var x = 0; x < w; x++) {
      final o = (y * w + x) * 4;
      out[o] = line[x * bpp];
      out[o + 1] = line[x * bpp + 1];
      out[o + 2] = line[x * bpp + 2];
      out[o + 3] = bpp == 4 ? line[x * bpp + 3] : 255;
    }
    prev = line;
  }
  return Rgba(w, h, out);
}

int _paeth(int a, int b, int c) {
  final p = a + b - c, pa = (p - a).abs(), pb = (p - b).abs(), pc = (p - c).abs();
  return pa <= pb && pa <= pc ? a : (pb <= pc ? b : c);
}

/// WCAG 2 relative luminance of 0xRRGGBB.
double luminance(int rgb) {
  double ch(int v) {
    final s = v / 255;
    return s <= 0.03928 ? s / 12.92 : math.pow((s + 0.055) / 1.055, 2.4).toDouble();
  }

  return 0.2126 * ch((rgb >> 16) & 0xFF) + 0.7152 * ch((rgb >> 8) & 0xFF) + 0.0722 * ch(rgb & 0xFF);
}

/// WCAG 2 contrast ratio of two colours (≥ 1).
double wcag(int a, int b) {
  final la = luminance(a), lb = luminance(b);
  return la > lb ? (la + 0.05) / (lb + 0.05) : (lb + 0.05) / (la + 0.05);
}

/// One box's measure: the background, the foreground (null = no other colour covers [minShare]), its share, the ratio.
class BoxContrast {
  const BoxContrast(this.bg, this.fg, this.fgShare, this.ratio, this.pixels);
  final int bg;
  final int? fg;
  final double fgShare;
  final double ratio; // 1.0 without a foreground
  final int pixels;
}

/// Measures the box [x1, x2) × [y1, y2) of [img] (clipped to the picture; null = nothing of it is inside).
BoxContrast? measure(Rgba img, int x1, int y1, int x2, int y2, {double minShare = 0.02}) {
  x1 = x1.clamp(0, img.width);
  x2 = x2.clamp(0, img.width);
  y1 = y1.clamp(0, img.height);
  y2 = y2.clamp(0, img.height);
  if (x2 <= x1 || y2 <= y1) return null;
  final hist = <int, int>{};
  for (var y = y1; y < y2; y++) {
    for (var x = x1; x < x2; x++) {
      final c = img.rgb(x, y);
      hist[c] = (hist[c] ?? 0) + 1;
    }
  }
  final n = (x2 - x1) * (y2 - y1);
  final bg = hist.entries.reduce((a, b) => b.value > a.value ? b : a).key;
  final lbg = luminance(bg);
  int? fg;
  var best = -1.0;
  for (final e in hist.entries) {
    if (e.key == bg || e.value < minShare * n) continue;
    final d = (luminance(e.key) - lbg).abs();
    if (d > best) {
      best = d;
      fg = e.key;
    }
  }
  return BoxContrast(bg, fg, fg == null ? 0 : hist[fg]! / n, fg == null ? 1.0 : wcag(fg, bg), n);
}

/// A uiautomator node with something to read: its words (text, else content-desc) and bounds in screen pixels.
class UiNode {
  const UiNode(this.words, this.x1, this.y1, this.x2, this.y2);
  final String words;
  final int x1, y1, x2, y2;
}

/// The nodes of a `uiautomator dump` with a non-empty text or content-desc (Flutter puts its labels in content-desc).
List<UiNode> parseUiDump(String xml) {
  final out = <UiNode>[];
  final node = RegExp(r'<node\b([^>]*?)/?>');
  String? attr(String a, String name) => RegExp('\\b$name="([^"]*)"').firstMatch(a)?.group(1);
  for (final m in node.allMatches(xml)) {
    final a = m.group(1)!;
    final words = _unescape((attr(a, 'text') ?? '').isNotEmpty ? attr(a, 'text')! : (attr(a, 'content-desc') ?? ''));
    final b = RegExp(r'\[(-?\d+),(-?\d+)\]\[(-?\d+),(-?\d+)\]').firstMatch(attr(a, 'bounds') ?? '');
    if (words.trim().isEmpty || b == null) continue;
    out.add(UiNode(words, int.parse(b.group(1)!), int.parse(b.group(2)!), int.parse(b.group(3)!), int.parse(b.group(4)!)));
  }
  return out;
}

String _unescape(String s) => s
    .replaceAll('&#10;', '\n')
    .replaceAll('&lt;', '<')
    .replaceAll('&gt;', '>')
    .replaceAll('&quot;', '"')
    .replaceAll('&apos;', "'")
    .replaceAll('&amp;', '&');

String hex(int rgb) => '#${rgb.toRadixString(16).padLeft(6, '0').toUpperCase()}';

/// One row per node: verdict, ratio, bg, fg (share), bounds, words. Verdicts: PASS (≥ [min]), LOW (< [min]), NO-FG
/// (❓ no foreground over 2 %), OFF (box outside the picture), SECURE? (the whole picture is one colour).
List<String> report(List<UiNode> nodes, Rgba img, {double min = 4.5}) {
  final first = img.rgb(0, 0);
  var oneColour = true;
  for (var i = 0; i < img.width * img.height && oneColour; i++) {
    if (img.rgb(i % img.width, i ~/ img.width) != first) oneColour = false;
  }
  final rows = <String>['verdict\tratio\tbg\tfg (share)\tbounds\twords'];
  for (final n in nodes) {
    final words = n.words.replaceAll('\n', ' ');
    final shown = words.length > 40 ? '${words.substring(0, 40)}…' : words;
    final at = '[${n.x1},${n.y1}][${n.x2},${n.y2}]';
    if (oneColour) {
      rows.add('SECURE?\t-\t${hex(first)}\t-\t$at\t$shown');
      continue;
    }
    final m = measure(img, n.x1, n.y1, n.x2, n.y2);
    if (m == null) {
      rows.add('OFF\t-\t-\t-\t$at\t$shown');
    } else if (m.fg == null) {
      rows.add('NO-FG\t-\t${hex(m.bg)}\t-\t$at\t$shown');
    } else {
      rows.add('${m.ratio >= min ? 'PASS' : 'LOW'}\t${m.ratio.toStringAsFixed(2)}\t${hex(m.bg)}\t'
          '${hex(m.fg!)} (${(m.fgShare * 100).toStringAsFixed(1)}%)\t$at\t$shown');
    }
  }
  return rows;
}

void main(List<String> args) {
  final files = args.where((a) => !a.startsWith('--')).toList();
  final mi = args.indexOf('--min');
  final min = mi >= 0 && mi + 1 < args.length ? double.parse(args[mi + 1]) : 4.5;
  if (files.length < 2) {
    stderr.writeln('usage: dart run tool/device_contrast.dart <dump.xml> <screen.png> [--min 4.5]');
    exitCode = 2;
    return;
  }
  final nodes = parseUiDump(File(files[0]).readAsStringSync());
  if (nodes.isEmpty) {
    stderr.writeln('no node with text or content-desc in ${files[0]} (nothing measured: not a pass)');
    exitCode = 1;
    return;
  }
  final rows = report(nodes, decodePng(File(files[1]).readAsBytesSync()), min: min);
  stdout.writeln(rows.join('\n'));
  final low = rows.skip(1).where((r) => !r.startsWith('PASS')).length;
  stdout.writeln('${rows.length - 1} nodes, ${rows.length - 1 - low} PASS, $low not PASS (LOW / NO-FG / OFF / SECURE?)');
  if (low > 0) exitCode = 1;
}
