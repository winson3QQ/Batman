// #329 補測 A（T9 / Q1，2026-11-18）: the shared part of the board renders — real fonts when this machine has them,
// and one PNG per board into $BOARDS_OUT (nothing written when it is unset; the boards are still rendered and checked).
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// The logical size of every board (design T9: 412×915) and the PNG's pixels per logical pixel.
const boardSize = Size(412, 915);
const boardDpr = 2.0;

final shotKey = GlobalKey();

/// The fonts the PNGs are drawn with (empty: flutter_test's box font, the PNGs are unreadable).
final loadedFonts = <String>[];

/// Loads a CJK font as the theme's family (Roboto) and as monospace, and the Material icons. A font file that is not
/// on this machine is skipped (then the text shows as boxes; the checks do not depend on it).
Future<void> loadFonts() async {
  final root = Platform.environment['FLUTTER_ROOT'] ?? 'C:/src/flutter';
  // #329 PR 7 §4: the same Windows font file seen from WSL (the contrast checks and their exceptions are judged on it)
  const cjk = ['C:/Windows/Fonts/NotoSansTC-VF.ttf', '/mnt/c/Windows/Fonts/NotoSansTC-VF.ttf', '/usr/share/fonts/opentype/noto/NotoSansCJK-Regular.ttc'];
  Future<void> family(String name, List<String> paths) async {
    for (final p in paths) {
      final f = File(p);
      if (!f.existsSync()) continue;
      final l = FontLoader(name)..addFont(Future.value(ByteData.sublistView(f.readAsBytesSync())));
      await l.load();
      loadedFonts.add('$name=$p');
      return;
    }
  }

  await family('Roboto', cjk);
  await family('monospace', cjk);
  await family('MaterialIcons', ['$root/bin/cache/artifacts/material_fonts/materialicons-regular.otf']);
}

/// The board's frame: a 412×915 view at [boardDpr], the app inside a boundary the PNG is taken from.
void sizeView(WidgetTester t) {
  t.view.physicalSize = boardSize * boardDpr;
  t.view.devicePixelRatio = boardDpr;
  addTearDown(t.view.reset);
}

Widget frame(Widget app) => RepaintBoundary(key: shotKey, child: app);

/// Writes the board as $BOARDS_OUT/[file].png (nothing when BOARDS_OUT is unset).
Future<void> shoot(WidgetTester t, String file) async {
  final out = Platform.environment['BOARDS_OUT'];
  if (out == null || out.isEmpty) return;
  final box = shotKey.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  await t.runAsync(() async {
    final img = await box.toImage(pixelRatio: boardDpr);
    final png = await img.toByteData(format: ui.ImageByteFormat.png);
    img.dispose();
    Directory(out).createSync(recursive: true);
    File('$out/$file.png').writeAsBytesSync(png!.buffer.asUint8List());
  });
}
