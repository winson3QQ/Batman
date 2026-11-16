// #329 design §3.1 T-C1: every text / background pair of both themes reaches 4.5:1; the ratio itself is checked
// against known values so a broken formula cannot pass.
import 'package:batman_app/ui/theme.dart';
import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('contrast: black on white is 21:1, a colour on itself 1:1, #767676 on white about 4.54', () {
    expect(contrast(const Color(0xFF000000), const Color(0xFFFFFFFF)), closeTo(21, 0.01));
    expect(contrast(const Color(0xFF336699), const Color(0xFF336699)), closeTo(1, 0.001));
    expect(contrast(const Color(0xFF767676), const Color(0xFFFFFFFF)), closeTo(4.54, 0.02));
  });

  for (final (name, t) in [('light', BatTheme.light), ('dark', BatTheme.dark)]) {
    test('T-C1 $name: every pair reaches 4.5:1', () {
      expect(t.pairs, isNotEmpty, reason: 'nothing to check is a failure');
      for (final (what, ink, bg) in t.pairs) {
        expect(contrast(ink, bg), greaterThanOrEqualTo(4.5), reason: '$name $what');
      }
    });
  }
}
