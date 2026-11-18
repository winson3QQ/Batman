// #329 PR 7 §4 (acceptance lines 87 / 88 / 92): the checks every board runs at text scale 1.0, light and dark —
// - 'tap48': Flutter's androidTapTargetGuideline (48×48 dp);
// - 'contrast': Flutter's textContrastGuideline (WCAG AA: 4.5:1, 3:1 for large text);
// - 'contrast2x': the §4 device method (tool/device_contrast.dart measure(): background = the most frequent colour,
//   foreground = the colour with the largest luminance difference among those covering ≥ 2 % of the box's non-background
//   pixels and ≥ 0.2 % of the box — an optimistic pick, plan §4) on the board's 2× pixels, for
//   every visible text (Text / RichText and input text), each in its own glyph box;
// - 'solid': design §3 「實心 ≤ 1」 — at most one solid button (FilledButton, primary or danger) on the surface the user
//   acts on (the top dialog when one is open, else the page).
// - 'words' (#329 PR 7, p1p2-check P1-3 / S6): on every visible text that is not technical (monospace) — a node's last four
//   is upper case (「…7d2c」 is a FAIL), no half-width 「...」, no half-width 「 / 」 between two CJK characters.
//
// Why two contrast rules: Flutter's guideline takes the screen at 1× and calls the most frequent "dark" colour the text.
// A CJK glyph at 13–16 dp is strokes 1–2 px wide at 1×, so the most frequent dark colour is an antialiasing tone,
// not the ink (dry run 2026-11-18: 「說明」 body text drawn in ink #1A1915 on #EFEAE0 (15.6:1) is reported as
// #A39F98, 2.20:1). A board may be excused from 'contrast' only in [a11yExceptions]; 'contrast2x' has no excuse and
// must pass on that board, and an excuse whose rule passes is itself a FAIL (stale).
//
// Limits: Flutter's guideline only measures a semantics node whose label is exactly one Text's text (merged nodes are
// skipped, not passed) and skips disabled nodes; 'contrast2x' skips icons (glyph fonts), texts under a disabled
// button (WCAG exempts inactive controls), texts not fully on the 412×915 board, and texts whose centre is covered.
// Without a CJK board font (flutter_test's box font: none of loadFonts' files on the machine) the two contrast rules
// cannot run: each board FAILs (code review A-MAJOR-1: a check that finds nothing to check is not a pass), unless
// A11Y_ALLOW_NO_FONT=1 is set, which prints A11Y-SKIP per board instead (tap48, solid and words still run).
import 'dart:io' show Platform;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../tool/device_contrast.dart' show Rgba, measure, hex;
import '../retest_s_shot.dart' show shotKey, boardDpr, boardSize, loadedFonts;

/// Why Flutter's textContrastGuideline is not the verdict on a board listed in [a11yExceptions] for 'contrast'.
const flutterAaReason = 'Flutter textContrastGuideline samples at 1× and takes the most frequent dark colour: for '
    'CJK strokes that is an antialiasing tone, not the ink; contrast2x (the §4 method at 2×) passes on this board';

/// board file (`<board>_<light|dark>`) -> rule -> why the rule does not apply there. Only 'contrast' may be excused;
/// each entry here is the 2026-11-18 dry run's Flutter contrast FAIL list (73 of 182 board files), every one checked
/// by expectA11y against contrast2x node by node. The list is the Windows rasterizer's: on Linux (WSL, same font file)
/// Flutter's guideline passes all 73 (WSL run 2026-11-18), so a stale entry is a FAIL on Windows only.
const a11yExceptions = <String, Map<String, String>>{
  '1.1_startup_splash_light': {'contrast': flutterAaReason},
  '10.3_leave_light': {'contrast': flutterAaReason},
  '2.4_keys_not_hardware_light': {'contrast': flutterAaReason},
  '2.4_keys_unreadable_light': {'contrast': flutterAaReason},
  '2.4_tech_opened_light': {'contrast': flutterAaReason},
  '3.1_claim_dev_light': {'contrast': flutterAaReason},
  '3.1_claim_field_light': {'contrast': flutterAaReason},
  '3.2_nick_dark': {'contrast': flutterAaReason},
  '3.2_nick_light': {'contrast': flutterAaReason},
  '3.3_claiming_dark': {'contrast': flutterAaReason},
  '3.3_claiming_light': {'contrast': flutterAaReason},
  '3.4_not_found_light': {'contrast': flutterAaReason},
  '3.4_refused_dark': {'contrast': flutterAaReason},
  '3.4_refused_light': {'contrast': flutterAaReason},
  '3.7_confirm_light': {'contrast': flutterAaReason},
  '3.7_entry_light': {'contrast': flutterAaReason},
  '3.7_pick_light': {'contrast': flutterAaReason},
  '3.7_recovering_light': {'contrast': flutterAaReason},
  '4.1_member_mode_light': {'contrast': flutterAaReason},
  '5.5_more_tech_opened_long_light': {'contrast': flutterAaReason},
  '5.7_remove_dialog_light': {'contrast': flutterAaReason},
  '7.3_invite_code_light': {'contrast': flutterAaReason},
  '7.4_request_light': {'contrast': flutterAaReason},
  '7.5_approve_light': {'contrast': flutterAaReason},
  '7.6_approval_code_light': {'contrast': flutterAaReason},
  '7.8_join_team_light': {'contrast': flutterAaReason},
  '7.9_my_request_light': {'contrast': flutterAaReason},
  '8.1_members_dark': {'contrast': flutterAaReason},
  '8.1_members_light': {'contrast': flutterAaReason},
  '8.2_person_light': {'contrast': flutterAaReason},
  '8.3_remove_dark': {'contrast': flutterAaReason},
  '8.3_remove_light': {'contrast': flutterAaReason},
  '8.4_new_secrets_dark': {'contrast': flutterAaReason},
  '8.4_new_secrets_light': {'contrast': flutterAaReason},
  '8.5_new_key_light': {'contrast': flutterAaReason},
  '9.2_start_light': {'contrast': flutterAaReason},
  '9.x_done_light': {'contrast': flutterAaReason},
  '9.x_reverted_light': {'contrast': flutterAaReason},
  'about_dark': {'contrast': flutterAaReason},
  'about_light': {'contrast': flutterAaReason},
  'country_dark': {'contrast': flutterAaReason},
  'country_light': {'contrast': flutterAaReason},
  'country_read_dark': {'contrast': flutterAaReason},
  'country_read_light': {'contrast': flutterAaReason},
  'country_tw_read_dark': {'contrast': flutterAaReason},
  'country_tw_read_light': {'contrast': flutterAaReason},
  'dev_node_settings_dark': {'contrast': flutterAaReason},
  'dev_node_settings_light': {'contrast': flutterAaReason},
  'dev_orphan_joins_dark': {'contrast': flutterAaReason},
  'dev_orphan_joins_dialog_light': {'contrast': flutterAaReason},
  'dev_orphan_joins_light': {'contrast': flutterAaReason},
  'dev_scan_dark': {'contrast': flutterAaReason},
  'dev_scan_found_dark': {'contrast': flutterAaReason},
  'dev_scan_found_light': {'contrast': flutterAaReason},
  'dev_ssh_keys_dark': {'contrast': flutterAaReason},
  'dev_ssh_keys_light': {'contrast': flutterAaReason},
  'dev_text_log_light': {'contrast': flutterAaReason},
  'help_light': {'contrast': flutterAaReason},
  'long_remove_dialog_24char_light': {'contrast': flutterAaReason},
  'more_light': {'contrast': flutterAaReason},
  'node_page_all_groups_light': {'contrast': flutterAaReason},
  'permissions_dark': {'contrast': flutterAaReason},
  'permissions_light': {'contrast': flutterAaReason},
  'phone_lost_light': {'contrast': flutterAaReason},
  'phone_wifi_light': {'contrast': flutterAaReason},
  'phone_wifi_read_light': {'contrast': flutterAaReason},
  'settings_dev_dark': {'contrast': flutterAaReason},
  'settings_dev_light': {'contrast': flutterAaReason},
  'swupdate_prepared_light': {'contrast': flutterAaReason},
  'swupdate_writing_light': {'contrast': flutterAaReason},
  'team_fresh_light': {'contrast': flutterAaReason},
  'team_hub_light': {'contrast': flutterAaReason},
  'team_old_light': {'contrast': flutterAaReason},
};

/// The words of each solid button on the surface the user acts on.
List<String> solidButtons() {
  final dialogs = find.byType(Dialog).evaluate().toList();
  final scope = dialogs.isEmpty
      ? find.byType(FilledButton)
      : find.descendant(of: find.byWidget(dialogs.last.widget), matching: find.byType(FilledButton));
  return [
    for (final e in scope.evaluate())
      find.descendant(of: find.byWidget(e.widget), matching: find.byType(Text)).evaluate().map((t) => (t.widget as Text).data ?? '').join()
  ];
}

bool _under<W extends Widget>(Element e, [bool Function(W w)? test]) {
  var found = false;
  e.visitAncestorElements((a) {
    final w = a.widget;
    if (w is W && (test == null || test(w))) {
      found = true;
      return false;
    }
    return true;
  });
  return found;
}

/// One measured text of the 2× board: its words, size, ratio (null = no foreground ≥ 2 %), the target.
class TextContrast {
  const TextContrast(this.words, this.ratio, this.target, this.bg, this.fg);
  final String words;
  final double? ratio;
  final double target;
  final int bg;
  final int? fg;
  bool get passed => ratio != null && ratio! >= target - 0.01;
  @override
  String toString() =>
      '"${words.length > 24 ? '${words.substring(0, 24)}…' : words}" ${ratio?.toStringAsFixed(2) ?? 'NO-FG'} (min $target) bg ${hex(bg)} fg ${fg == null ? '-' : hex(fg!)}';
}

/// Every visible text of the board measured with the §4 method on the 2× picture of [shotKey].
Future<List<TextContrast>> boardTextContrast(WidgetTester t) async {
  final box = shotKey.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  final img = await t.runAsync(() async {
    final i = await box.toImage(pixelRatio: boardDpr);
    final b = await i.toByteData(format: ui.ImageByteFormat.rawStraightRgba);
    final r = Rgba(i.width, i.height, b!.buffer.asUint8List());
    i.dispose();
    return r;
  });
  final dialogs = find.byType(Dialog).evaluate().toList();
  Finder scoped(Finder f) => dialogs.isEmpty ? f : find.descendant(of: find.byWidget(dialogs.last.widget), matching: f);
  final out = <TextContrast>[];
  final view = Offset.zero & boardSize;

  void one(Element e, RenderBox r, String words, TextStyle? style, List<TextBox> boxes) {
    if (words.trim().isEmpty || boxes.isEmpty) return;
    if (_under<ButtonStyleButton>(e, (b) => b.onPressed == null && b.onLongPress == null)) return; // inactive control
    var local = boxes.first.toRect();
    for (final b in boxes.skip(1)) {
      local = local.expandToInclude(b.toRect());
    }
    final g = MatrixUtils.transformRect(r.getTransformTo(null), local);
    if (!(view.contains(g.topLeft) && view.contains(g.bottomRight - const Offset(0.01, 0.01)))) return;
    final hit = HitTestResult();
    WidgetsBinding.instance.hitTestInView(hit, g.center, t.view.viewId);
    if (!hit.path.any((p) => p.target == r)) return; // covered (or under a barrier)
    final m = measure(img!, (g.left * boardDpr).floor(), (g.top * boardDpr).floor(), (g.right * boardDpr).ceil(), (g.bottom * boardDpr).ceil());
    if (m == null) return;
    final size = style?.fontSize ?? 14, bold = (style?.fontWeight?.value ?? 400) >= 700;
    final large = size >= 18 || (bold && size >= 14); // Flutter's kLargeTextMinimumSize / kBoldTextMinimumSize
    out.add(TextContrast(words, m.fg == null ? null : m.ratio, large ? 3.0 : 4.5, m.bg, m.fg));
  }

  for (final e in scoped(find.byType(RichText)).evaluate()) {
    if (_under<Icon>(e)) continue;
    final rt = e.widget as RichText;
    final r = e.renderObject;
    if (r is! RenderParagraph) continue;
    final words = rt.text.toPlainText();
    one(e, r, words, rt.text.style, r.getBoxesForSelection(TextSelection(baseOffset: 0, extentOffset: words.length)));
  }
  for (final e in scoped(find.byType(EditableText)).evaluate()) {
    final w = e.widget as EditableText;
    RenderEditable? re;
    void find0(RenderObject o) {
      if (re != null) return;
      if (o is RenderEditable) {
        re = o;
        return;
      }
      o.visitChildren(find0);
    }

    find0(e.renderObject!);
    final words = w.obscureText ? '' : w.controller.text;
    if (re == null || words.isEmpty) continue;
    one(e, re!, words, w.style, re!.getBoxesForSelection(TextSelection(baseOffset: 0, extentOffset: words.length)));
  }
  return out;
}

/// The contrast rules need the board's real font: with flutter_test's box font every glyph is a filled square and
/// neither Flutter's guideline nor contrast2x measures text. True when retest_s_shot.loadFonts found the CJK font.
bool get contrastJudged => loadedFonts.any((f) => f.startsWith('Roboto='));

/// Each rule's failure text for this board (empty = all pass); [measured] gets the contrast2x texts. Without the
/// board font ([contrastJudged] false) the two contrast rules are not run (expectA11y says so, never as a pass).
Future<Map<String, String>> a11yFailures(WidgetTester t, {List<TextContrast>? measured}) async {
  final out = <String, String>{};
  final tap = await androidTapTargetGuideline.evaluate(t);
  if (!tap.passed) out['tap48'] = tap.reason ?? '(no reason)';
  final solid = solidButtons();
  if (solid.length > 1) out['solid'] = '${solid.length} solid buttons: $solid';
  final words = wordProblems();
  if (words.isNotEmpty) out['words'] = words.join('; ');
  if (!contrastJudged) return out;
  final c = await textContrastGuideline.evaluate(t);
  if (!c.passed) out['contrast'] = c.reason ?? '(no reason)';
  final texts = await boardTextContrast(t);
  measured?.addAll(texts);
  final low = texts.where((m) => !m.passed).toList();
  if (texts.isEmpty) {
    out['contrast2x'] = 'no text measured (a check that finds nothing is not a pass)';
  } else if (low.isNotEmpty) {
    out['contrast2x'] = '${low.length} of ${texts.length} texts: ${low.join('; ')}';
  }
  return out;
}

/// #329 PR 7 'words': the visible, non-technical texts (RichText, not monospace) that break the display rules —
/// a lower-case last four after 「…」 (upper case on screen, design §3.4 / say.dart upperLast4), half-width 「...」, a
/// half-width 「/」 between CJK characters (S6: full-width 「／」).
List<String> wordProblems() {
  final lower = RegExp(r'…(?=[0-9a-f]{4}(?![0-9a-fA-F]))(?=[0-9]*[a-f])[0-9a-f]{4}');
  const cjk = r'[㐀-鿿豈-﫿]';
  final slash = RegExp('$cjk ?/ ?$cjk');
  final out = <String>[];
  for (final e in find.byType(RichText).evaluate()) {
    final w = e.widget as RichText;
    if (w.text.style?.fontFamily == 'monospace') continue;
    final s = w.text.toPlainText();
    for (final m in lower.allMatches(s)) {
      out.add('lower-case last four "${m[0]}" in "$s"');
    }
    if (s.contains('...')) out.add('half-width "..." in "$s"');
    for (final m in slash.allMatches(s)) {
      out.add('half-width "/" in "${m[0]}" ("$s")');
    }
  }
  return out;
}

/// The labels of the semantics nodes Flutter's contrast guideline failed (its reason names each node).
List<String> flutterContrastLabels(String reason) =>
    [for (final m in RegExp(r'label: "([^"]*)"').allMatches(reason)) m.group(1)!.replaceAll(r'\n', '\n')];

/// #329 PR 7 code review A-MAJOR-1: a board run without the board font judges no contrast, and a check that finds
/// nothing to check is a FAIL, never a pass. Only an explicit `A11Y_ALLOW_NO_FONT=1` turns it into an A11Y-SKIP line
/// (printed; the contrast rules are then not judged in that run). [judged]: [contrastJudged].
List<String> noFontProblems(String file, {required bool judged, required Map<String, String> env}) {
  if (judged) return const [];
  const why = 'no board font (box font): none of the CJK font files of loadFonts (retest_s_shot.dart cjkFontPaths) '
      'is on this machine, so contrast and contrast2x cannot be judged';
  if (env['A11Y_ALLOW_NO_FONT'] == '1') {
    // ignore: avoid_print
    print('A11Y-SKIP $file contrast, contrast2x: $why — NOT judged in this run (A11Y_ALLOW_NO_FONT=1)');
    return const [];
  }
  return ['A11Y-FAIL $file contrast: $why (install fonts-noto-cjk, or set A11Y_ALLOW_NO_FONT=1 to skip on purpose)'];
}

/// Runs the rules on board file [file] (`<board>_<light|dark>`) and fails with every problem at once. An excused
/// 'contrast' holds only while every node Flutter failed was measured by contrast2x and passed there.
Future<void> expectA11y(WidgetTester t, String file) async {
  final measured = <TextContrast>[];
  final fails = await a11yFailures(t, measured: measured);
  final excused = contrastJudged ? a11yExceptions[file] ?? const <String, String>{} : const <String, String>{};
  final problems = <String>[
    ...noFontProblems(file, judged: contrastJudged, env: Platform.environment),
    for (final f in fails.entries)
      if (!excused.containsKey(f.key)) 'A11Y-FAIL $file ${f.key}: ${f.value}',
    for (final r in excused.keys)
      if (Platform.isWindows && !fails.containsKey(r)) 'A11Y-FAIL $file $r: stale exception (the rule passes now): ${excused[r]}',
    for (final r in excused.keys)
      if (r != 'contrast') 'A11Y-FAIL $file $r: only Flutter\'s contrast rule may be excused',
    if (excused.containsKey('contrast') && fails.containsKey('contrast'))
      for (final l in flutterContrastLabels(fails['contrast']!))
        if (!measured.any((m) => m.words == l && m.passed))
          'A11Y-FAIL $file contrast: excused, but "$l" is not a passed contrast2x text (${measured.where((m) => m.words == l).join('; ')})',
  ];
  if ((Platform.environment['A11Y_LOG'] ?? '').isNotEmpty) {
    final lowest = measured.isEmpty ? null : (measured.toList()..sort((a, b) => (a.ratio ?? 0).compareTo(b.ratio ?? 0))).first;
    // ignore: avoid_print
    print('A11Y-LOG $file: contrast2x ${measured.length} texts, lowest $lowest; '
        'flutter contrast ${fails.containsKey('contrast') ? 'FAIL (excused ${excused.containsKey('contrast')})' : 'pass'}');
  }
  expect(problems, isEmpty, reason: problems.join('\n'));
}
