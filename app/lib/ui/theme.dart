// #329 design §3.1: the colour tokens (light / dark) and the six type sizes. Widgets read tokens only, never a
// literal colour. ThemeMode.system.
import 'dart:math' as math;

import 'package:flutter/material.dart';

@immutable
class BatTheme extends ThemeExtension<BatTheme> {
  const BatTheme({
    required this.bg,
    required this.surf,
    required this.ink,
    required this.sub,
    required this.line,
    required this.acc,
    required this.accInk,
    required this.accText,
    required this.okBg,
    required this.okInk,
    required this.warnBg,
    required this.warnInk,
    required this.badBg,
    required this.badInk,
    required this.unkBg,
    required this.unkInk,
    required this.danger,
    required this.dangerInk,
  });

  final Color bg, surf, ink, sub, line, acc, accInk, accText;
  final Color okBg, okInk, warnBg, warnInk, badBg, badInk, unkBg, unkInk, danger, dangerInk;

  static const light = BatTheme(
    bg: Color(0xFFEFEAE0),
    surf: Color(0xFFFBF8F1),
    ink: Color(0xFF1A1915),
    sub: Color(0xFF5E5848),
    line: Color(0xFFD6CEBC),
    acc: Color(0xFF1F1E1A),
    accInk: Color(0xFFEFE6CF),
    accText: Color(0xFF46561B),
    okBg: Color(0xFFDEE8CA),
    okInk: Color(0xFF33471A),
    warnBg: Color(0xFFF6E6C2),
    warnInk: Color(0xFF684500),
    badBg: Color(0xFFF3D8CE),
    badInk: Color(0xFF86220F),
    unkBg: Color(0xFFE3DCCB),
    unkInk: Color(0xFF4A4436),
    danger: Color(0xFF9E2A16),
    dangerInk: Color(0xFFFFFFFF),
  );

  static const dark = BatTheme(
    bg: Color(0xFF14130F),
    surf: Color(0xFF211F18),
    ink: Color(0xFFEFE9D9),
    sub: Color(0xFFADA58F),
    line: Color(0xFF3B372B),
    acc: Color(0xFFB9AD89),
    accInk: Color(0xFF17160F),
    accText: Color(0xFFC6D48E),
    okBg: Color(0xFF27341A),
    okInk: Color(0xFFC7DD9C),
    warnBg: Color(0xFF3F3110),
    warnInk: Color(0xFFF2D68A),
    badBg: Color(0xFF48201A),
    badInk: Color(0xFFF7BBAF),
    unkBg: Color(0xFF2E2B22),
    unkInk: Color(0xFFD0C9B5),
    danger: Color(0xFFF08A78),
    dangerInk: Color(0xFF2A0D07),
  );

  /// The (ink, background) pairs that must reach 4.5:1 (T-C1).
  List<(String, Color, Color)> get pairs => [
        ('ink/bg', ink, bg),
        ('ink/surf', ink, surf),
        ('sub/bg', sub, bg),
        ('sub/surf', sub, surf),
        ('accInk/acc', accInk, acc),
        ('accText/bg', accText, bg),
        ('accText/surf', accText, surf),
        ('okInk/okBg', okInk, okBg),
        ('warnInk/warnBg', warnInk, warnBg),
        ('badInk/badBg', badInk, badBg),
        ('unkInk/unkBg', unkInk, unkBg),
        ('dangerInk/danger', dangerInk, danger),
        ('danger/bg', danger, bg),
      ];

  static BatTheme of(BuildContext c) => Theme.of(c).extension<BatTheme>()!;

  @override
  BatTheme copyWith() => this;

  @override
  BatTheme lerp(ThemeExtension<BatTheme>? other, double t) => t < 0.5 ? this : (other as BatTheme? ?? this);
}

/// The six sizes of §3.1 (sp).
abstract final class Fs {
  static const welcome = 28.0;
  static const hero = 24.0;
  static const title = 18.0;
  static const body = 16.0;
  static const note = 14.0;
  static const meta = 13.0;
}

ThemeData batThemeData(Brightness b) {
  final t = b == Brightness.light ? BatTheme.light : BatTheme.dark;
  return ThemeData(
    useMaterial3: true,
    brightness: b,
    scaffoldBackgroundColor: t.bg,
    colorScheme: ColorScheme.fromSeed(seedColor: t.acc, brightness: b).copyWith(surface: t.bg, onSurface: t.ink),
    textTheme: Typography.material2021().black.apply(bodyColor: t.ink, displayColor: t.ink),
    extensions: [t],
  );
}

/// WCAG relative-luminance contrast ratio (T-C1).
double contrast(Color a, Color b) {
  double lin(double v) => v <= 0.03928 ? v / 12.92 : math.pow((v + 0.055) / 1.055, 2.4).toDouble();
  double lum(Color c) => 0.2126 * lin(c.r) + 0.7152 * lin(c.g) + 0.0722 * lin(c.b);
  final la = lum(a), lb = lum(b);
  final hi = la > lb ? la : lb, lo = la > lb ? lb : la;
  return (hi + 0.05) / (lo + 0.05);
}
