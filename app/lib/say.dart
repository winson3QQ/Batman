// #254 app — the words the screens use. On-screen lines are plain Traditional Chinese; the logcat copy of a line keeps
// its English prefix tag ("BMAPP owner", "BMAPP claim", ...) and may start with ASCII markers ("[LOGGED_IN] ",
// "[ANSWER] [NET_MADE] ", ...) that scripts grep for. The screen never shows the markers.
//
// #329 PR 6 D7: the technical part of a sentence (codes, reason codes, reply codes, internal English words, a verb the
// node sent) is wrapped in U+001E … U+001F, by Rust's sentence functions and by the Dart lines that add one. A line may
// hold several such parts (joined sentences keep each pair). The screen shows the main part; the technical part only
// under 「技術資訊（給維修人員看）」 (SayLine). Logs and copied text show the two characters as 〔 〕.

import 'package:flutter/material.dart';

import 'ui/theme.dart';

final _markers = RegExp(r'^(?:\[[A-Z_]+\] )+', multiLine: true);

/// U+001E: the start of a technical part.
const techOpen = '\u001e';

/// U+001F: the end of a technical part.
const techClose = '\u001f';

/// [s] as a technical part (for Dart's own lines: a non-String exception, a type name).
String tech(Object s) => '$techOpen$s$techClose';

/// (main, tech): main = [line] without every paired U+001E … U+001F part; tech = those parts in order, joined with
/// 「；」 (empty ones skipped). Unpaired (a lone end, a start never ended, or a start inside an open part) -> both control
/// characters removed and the whole line is main (rather show too much than swallow words). The same rule as Rust's
/// test helper `split_code`; both are checked against app/test/fixtures/split_vectors.txt.
(String, String) splitCode(String line) {
  final main = StringBuffer();
  final parts = <String>[];
  StringBuffer? cur;
  String whole() => line.replaceAll(techOpen, '').replaceAll(techClose, '');
  for (final r in line.runes) {
    final ch = String.fromCharCode(r);
    if (ch == techOpen) {
      if (cur != null) return (whole(), '');
      cur = StringBuffer();
    } else if (ch == techClose) {
      if (cur == null) return (whole(), '');
      parts.add(cur.toString());
      cur = null;
    } else {
      (cur ?? main).write(ch);
    }
  }
  if (cur != null) return (whole(), '');
  return (main.toString(), parts.where((p) => p.isNotEmpty).join('；'));
}

/// [line] as the screen shows it: without its leading log markers (on every line) and without its technical parts.
String screenText(String line) => upperLast4(splitCode(line.replaceAll(_markers, '')).$1);

/// #329 PR 6 (device session 2026-11-18): a node's last four on screen are upper case everywhere (p1p2-check: 「…7d2c」
/// on 4.1 / 10.3 / 8.4). Several Rust sentences put `…{last4}` in lower case and the same value is also the node name
/// sent to a node (`node-{last4}`), so it is upper-cased here, at display, not at its source. Only 「…」 + exactly four
/// hex digits: a network id (bm-…) or a longer hex run is left as it is.
String upperLast4(String s) =>
    s.replaceAllMapped(RegExp(r'…([0-9a-fA-F]{4})(?![0-9a-fA-F])'), (m) => '…${m[1]!.toUpperCase()}');

/// The technical parts of [line] ('' = none).
String techText(String line) => splitCode(line).$2;

/// [line] for a log or for copied text: the two control characters as visible 〔 〕 (G MINOR-5).
String logText(String line) => line.replaceAll(techOpen, '〔').replaceAll(techClose, '〕');

/// The title of every technical fold (design §3.2).
const techTitle = '技術資訊（給維修人員看）';

/// A sentence on screen (#329 PR 6 D7): its main part, and — when it has one — its technical part under a small
/// collapsed 「技術資訊（給維修人員看）」 row. Several lines (joined with '\n') keep every line's main words.
class SayLine extends StatelessWidget {
  const SayLine(this.line, {super.key, this.style, this.techKey});
  final String line;
  final TextStyle? style;

  /// the key of the technical text, once opened (tests)
  final Key? techKey;

  @override
  Widget build(BuildContext context) {
    final text = Text(screenText(line), style: style);
    final t = techText(line);
    if (t.isEmpty) return text;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
      text,
      TechFold(t, techKey: techKey),
    ]);
  }
}

/// The collapsed 「技術資訊（給維修人員看）」 row and, once opened, [text] (design §3.2: technical information is always
/// collapsed).
class TechFold extends StatefulWidget {
  const TechFold(this.text, {super.key, this.techKey});
  final String text;
  final Key? techKey;
  @override
  State<TechFold> createState() => _TechFoldState();
}

class _TechFoldState extends State<TechFold> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    final sub = BatTheme.of(context).sub;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
      InkWell(
        onTap: () => setState(() => _open = !_open),
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 48),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(_open ? Icons.expand_less : Icons.expand_more, size: 18, color: sub),
            const SizedBox(width: 4),
            Flexible(child: Text(techTitle, style: TextStyle(fontSize: Fs.meta, color: sub))),
          ]),
        ),
      ),
      if (_open)
        SelectableText(widget.text,
            key: widget.techKey, style: TextStyle(fontSize: Fs.meta, fontFamily: 'monospace', color: sub)),
    ]);
  }
}

/// A node state as STATUS names it (protocol value from batman_proto::status), in words.
String stateText(String state) => switch (state) {
      'unclaimed' => '未認領',
      'claimed' => '已認領（還沒加入網路）',
      'member' => '已加入網路',
      'legacy' => '舊版節點',
      _ => '狀態不明',
    };

/// A caught error in a Dart line (#329 PR 6 D7, I MINOR-2): a Rust String error already carries its own technical
/// parts and is joined as is; anything else (an exception object) is technical as a whole.
String sayErr(Object e) => e is String ? e : tech(e);

/// [line] without the log markers at the start of each of its lines, technical parts kept (a line joined into another
/// line that SayLine shows later).
String stripMarkers(String line) => line.replaceAll(_markers, '');
