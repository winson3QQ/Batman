// #254 app — remote invite screens (254-app-member-join v6.1 §5-1, §5-6, §8). Plain widgets with their actions
// passed in (no BLE, no Rust, no platform channel here), so the screen gates are widget-tested:
// - the two SAS screens carry the R22 line and call their action only when the button is pressed, with the SAS
//   string on the screen;
// - pasting is refused unless a dev build (the paste field never reads the clipboard otherwise);
// - the status page (254-app-status-page v8.1 §2) shows Rust's verdict; a network name only from a record on this
//   phone; an E_RATE keeps the earlier read time;
// - My nodes: the controls scroll above the log (f139951).
import 'dart:typed_data';

import 'package:flutter/material.dart';

import 'say.dart' show screenText;

/// 219 §5.5 / R22: the SAS is compared over another channel.
const sasRule = '請用電話或當面核對，不要在傳圖片的同一個聊天裡核對';

/// The admin's approve screen and the member's import screen (§4 steps 5 / 7a): the SAS, the rule, one button.
class SasConfirmView extends StatefulWidget {
  const SasConfirmView({super.key, required this.title, required this.sas, required this.confirmLabel, required this.onConfirm, this.notice});

  final String title;
  final String sas;
  final String confirmLabel;

  /// e.g. 「申請已換新，要重新核對 SAS」
  final String? notice;

  /// called once, only when the button is pressed, with the SAS shown
  final Future<void> Function(String sas) onConfirm;

  @override
  State<SasConfirmView> createState() => _SasConfirmViewState();
}

class _SasConfirmViewState extends State<SasConfirmView> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(widget.title)),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          if (widget.notice != null) Text(widget.notice!, style: const TextStyle(color: Colors.deepOrange)),
          const Text('確認碼'),
          Text(widget.sas, key: const Key('sas'), style: const TextStyle(fontSize: 40, fontFamily: 'monospace', letterSpacing: 6)),
          const SizedBox(height: 8),
          const Text(sasRule, key: Key('sasRule'), style: TextStyle(fontWeight: FontWeight.bold)),
          const SizedBox(height: 16),
          FilledButton(
              key: const Key('sasConfirm'),
              onPressed: _pressed
                  ? null
                  : () async {
                      setState(() => _pressed = true);
                      await widget.onConfirm(widget.sas);
                    },
              child: Text(widget.confirmLabel)),
        ]),
      ),
    );
  }
}

/// The member's request SAS (§4 step 4): shown with the rule; nothing to press.
class SasShowView extends StatelessWidget {
  const SasShowView({super.key, required this.sas, this.notice});
  final String sas;
  final String? notice;

  @override
  Widget build(BuildContext context) {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      if (notice != null) Text(notice!, style: const TextStyle(color: Colors.deepOrange)),
      Text('確認碼 $sas', key: const Key('sas'), style: const TextStyle(fontSize: 24, fontFamily: 'monospace')),
      const Text(sasRule, key: Key('sasRule')),
    ]);
  }
}

/// A paste button for the dev build's hex codes (§5-1, the same rule as the claim QR): refused unless [devTrust];
/// the clipboard is read only then, and cleared after reading.
class PasteButton extends StatelessWidget {
  const PasteButton(
      {super.key, required this.label, required this.devTrust, required this.readClipboard, required this.onText, required this.onRefused, this.enabled = true});

  final String label;

  /// false while another operation runs (one at a time)
  final bool enabled;
  final Future<bool> Function() devTrust;
  final Future<String?> Function() readClipboard;
  final void Function(String text) onText;
  final void Function(String why) onRefused;

  @override
  Widget build(BuildContext context) {
    return OutlinedButton(
        key: Key('paste:$label'),
        onPressed: !enabled
            ? null
            : () async {
          if (!await devTrust()) {
            onRefused('只有開發版可以貼上');
            return;
          }
          final t = (await readClipboard())?.trim() ?? '';
          if (t.isEmpty) {
            onRefused('剪貼簿是空的');
            return;
          }
          onText(t);
        },
        child: Text(label));
  }
}

/// A remote-invite action that is not a paste (邀請隊員): refused unless a dev build, like the paste buttons.
class DevOnlyButton extends StatelessWidget {
  const DevOnlyButton({super.key, required this.label, required this.devTrust, required this.onPressed, required this.onRefused, this.enabled = true});

  final String label;
  final bool enabled;
  final Future<bool> Function() devTrust;
  final Future<void> Function() onPressed;
  final void Function(String why) onRefused;

  @override
  Widget build(BuildContext context) {
    return OutlinedButton(
        key: Key('dev:$label'),
        onPressed: !enabled
            ? null
            : () async {
                if (!await devTrust()) {
                  onRefused('只有開發版可以使用遠端邀請');
                  return;
                }
                await onPressed();
              },
        child: Text(label));
  }
}

/// The line a join request ends with when the link went away during it: whether the request was already saved.
String joinreqLostLine({required bool saved}) =>
    saved ? '[REQ_FAIL] 連線斷了；申請已存，按「再顯示申請」' : '[REQ_FAIL] 連線斷了，申請沒有存，請再按一次';

/// Which members "forget" offers (member-join §3): joining or approved ones, never the network's creator.
bool forgettable({required bool joining, required bool approved, required bool creator}) => (joining || approved) && !creator;

/// The confirm text of "forget": an approved node keeps what it was given.
String forgetNotice({required bool approved}) =>
    approved ? '只從本機清單移除，不會撤銷這台已拿到的網路金鑰。' : '只改這支手機裡的網路紀錄，節點本身不會被改動。';

/// One status page read (docs/design/254-app-status-page.md v8.1 §2), as Rust made it: every node string already
/// filtered and cut; "" = no line. [fresh] false: the node answered E_RATE and Rust kept the earlier verdict.
class StatusFields {
  const StatusFields(
      {this.color = 'grey',
      this.sentence = '',
      this.lagNote = '',
      this.warning = '',
      this.membership = '',
      this.version = '',
      this.tech = const [],
      this.rateNote = '',
      this.fresh = true,
      this.unfinished = '',
      this.unfinishedUnderVerdict = false,
      this.canLeave = false,
      this.leaveTitle = '',
      this.leaveBody = ''});
  final String color, sentence, lagNote, warning, membership, version, rateNote;
  final List<String> tech;
  final bool fresh;

  /// 254-app-leave v4.1 §2: info key 11 = true — the unfinished-change line; right under the verdict when key 10 is
  /// absent, else after the ⚠️ line
  final String unfinished;
  final bool unfinishedUnderVerdict;

  /// the leave button shows; its confirm dialog (title, body) as Rust made it
  final bool canLeave;
  final String leaveTitle, leaveBody;
}

/// 254-app-leave v4.1 §3: a leave waits longer than provd's 330 s helper wait, is never re-sent, and a lost link after it
/// went out says "outcome unknown"
const joinWait = Duration(seconds: 360);
const leaveUnclear = '[REQ_FAIL] 結果不明 — 請重新連線後看狀態頁';

/// Frames the run loop may write; made only by [SendTrack.outgoing].
class Outgoing {
  Outgoing._(this.frames);
  final List<Uint8List> frames;
}

/// What the leave button got back (leave v4.1 §2-§3): the line to show, the page re-read after a reply 0, and whether
/// that re-read read nothing (the page is then marked stale).
class LeaveResult {
  const LeaveResult(this.line, this.fields, {this.stale = false});
  final String? line;
  final StatusFields? fields;
  final bool stale;
}

/// The leave line when the owner request ended without an answer and said nothing either (busy, …).
const leaveNotAsked = '[REQ_FAIL] 沒有送出 — 請再按一次';

/// The leave button's request (leave v4.1 §3): [ask] is the owner request; when it returns no answer (a write that
/// threw, a failed re-login, …) the line it last said is shown on the page instead (code review B-M1) — never nothing.
/// [left]: network/leave answered 0 in that request; then the page is read once more ([reread]).
Future<LeaveResult> leaveFlow(
    {required Future<String?> Function({required Duration wait, required bool retry, required String unclear}) ask,
    required String? Function() lastSaid,
    required bool Function() left,
    required Future<StatusFields?> Function() reread}) async {
  final a = await sendLeave(ask);
  if (a == null) return LeaveResult(lastSaid() ?? leaveNotAsked, null);
  if (!left()) return LeaveResult(a, null);
  final again = await reread();
  return LeaveResult(a, again, stale: again == null);
}

/// An Ended step's answer line: a detail that is already a marked line (the bridge's leave Unknown, code review A-m2)
/// is shown as it is; any other end says the link ended.
String endedLine(String detail) => detail.startsWith('[') ? detail : '[REQ_FAIL] 連線已結束：$detail';

/// The request the leave button makes, with the call policy fixed here ([ask] is the page's owner request).
Future<String?> sendLeave(Future<String?> Function({required Duration wait, required bool retry, required String unclear}) ask) =>
    ask(wait: joinWait, retry: false, unclear: leaveUnclear);

/// 「連線失敗，還沒有寫入或送出」: what a lost link says before anything that changes the node went out.
const notSentLine = '[REQ_FAIL] 連線失敗，還沒有寫入或送出，請重試';

/// Whether a request may have reached the node (leave v4.1 §3 / L9): a record write that landed, or a step Rust marked
/// `sent` (the write that carries network/leave). Nothing else — a Sign step or another write — counts.
class SendTrack {
  bool wrote = false;
  void persisted() => wrote = true;
  void write({required bool sent}) {
    if (sent) wrote = true;
  }

  /// The only way to get frames the run loop may write (nodes.dart `_write` takes an [Outgoing]): the sent mark is
  /// taken BEFORE the frames go out, so a write that throws half-way is "possibly sent" (code review B-M1 / A-m1).
  Outgoing outgoing({required bool sent, required List<Uint8List> frames}) {
    write(sent: sent);
    return Outgoing._(frames);
  }

  /// the line for a lost link / timeout of a request with an [unclear] line
  String unclearNow(String unclear) => wrote ? unclear : notSentLine;
}

/// The network name for [netId]: only from a record on this phone (net/ or mnet/), never the id itself.
String? networkName(String netId, Map<String, String> names) => netId.isEmpty ? null : names[netId];

/// §2-1 / §2-5: the read time shown — a fresh read is "now"; a read refused with E_RATE keeps the earlier read's time.
DateTime readTime({required bool fresh, required DateTime now, DateTime? previous}) => fresh || previous == null ? now : previous;

/// The time of the last fresh status-page read of this session, kept across closing and reopening the page: reopening
/// within the node's 1 / s quota answers E_RATE with the earlier verdict, which keeps its own time (code review A-m1).
class ReadClock {
  DateTime? last;

  /// the read time to show for a read that just ended ([fresh] false: E_RATE kept the earlier verdict)
  DateTime stamp({required bool fresh, required DateTime now}) => last = readTime(fresh: fresh, now: now, previous: last);
}

/// The line under 「重新整理」 when a refresh read nothing (timeout, link lost, another request running).
const refreshMissed = '沒有讀到，請再按一次';

String _two(int n) => n.toString().padLeft(2, '0');

/// HH:MM:SS (the app's own clock, display only)
String hms(DateTime t) => '${_two(t.hour)}:${_two(t.minute)}:${_two(t.second)}';

Color verdictColor(String c) => switch (c) {
      'green' => Colors.green,
      'yellow' => Colors.amber,
      'red' => Colors.red,
      _ => Colors.grey,
    };

/// The status page (§2), top to bottom: the verdict (colour + sentence), 讀取於, the lag small print (rows 3 / 4), the
/// ⚠️ line, the membership line, the version, 「重新整理」, and the technical list collapsed. No battery: the node never
/// sends it.
class StatusPageView extends StatefulWidget {
  const StatusPageView(
      {super.key, required this.initial, required this.initialAt, required this.onRefresh, this.onLeave, this.clock = DateTime.now});
  final StatusFields initial;
  final DateTime initialAt;

  /// 「離開網路」 after the user confirmed (leave v4.1): see [leaveFlow]
  final Future<LeaveResult> Function()? onLeave;

  /// reads status + info again; null when nothing was read (the link was lost, or another request runs)
  final Future<StatusFields?> Function() onRefresh;
  final DateTime Function() clock;

  @override
  State<StatusPageView> createState() => _StatusPageViewState();
}

class _StatusPageViewState extends State<StatusPageView> {
  late StatusFields _f = widget.initial;
  late DateTime _at = widget.initialAt;
  bool _busy = false;
  // the last refresh read nothing (code review B-m3)
  bool _missed = false;
  // the last leave's answer line
  String _leaveLine = '';

  Future<void> _leave() async {
    if (_busy || widget.onLeave == null) return;
    final yes = await showDialog<bool>(
        context: context,
        builder: (c) => AlertDialog(
              title: Text(_f.leaveTitle),
              content: Text(_f.leaveBody, key: const Key('leaveBody')),
              actions: [
                TextButton(key: const Key('leaveCancel'), onPressed: () => Navigator.pop(c, false), child: const Text('取消')),
                TextButton(key: const Key('leaveConfirm'), onPressed: () => Navigator.pop(c, true), child: const Text('離開網路')),
              ],
            ));
    if (yes != true || !mounted) return;
    setState(() => _busy = true);
    try {
      final r = await widget.onLeave!();
      if (mounted) {
        setState(() {
          _leaveLine = r.line ?? '';
          final again = r.fields;
          if (again != null) {
            _at = readTime(fresh: again.fresh, now: widget.clock(), previous: _at);
            _f = again;
          }
          // left, but the re-read read nothing: the page is stale (code review A-m4)
          _missed = r.stale;
        });
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _refresh() async {
    // one read at a time: a second tap before the button is redrawn disabled does nothing (S20 fix 3)
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final r = await widget.onRefresh();
      if (mounted) {
        setState(() {
          _missed = r == null;
          if (r != null) {
            _at = readTime(fresh: r.fresh, now: widget.clock(), previous: _at);
            _f = r;
            _leaveLine = ''; // the leave answer belonged to the earlier read
          }
        });
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final f = _f;
    const small = TextStyle(fontSize: 12, color: Colors.black54);
    return ListView(padding: const EdgeInsets.all(16), children: [
      Row(key: const Key('verdict'), crossAxisAlignment: CrossAxisAlignment.start, children: [
        Icon(Icons.circle, key: Key('color:${f.color}'), color: verdictColor(f.color)),
        const SizedBox(width: 8),
        Expanded(child: Text(f.sentence, key: const Key('sentence'), style: const TextStyle(fontSize: 18))),
      ]),
      if (f.unfinished.isNotEmpty && f.unfinishedUnderVerdict) Text(f.unfinished, key: const Key('unfinished')),
      Text('讀取於 ${hms(_at)}', key: const Key('readAt'), style: small),
      if (f.lagNote.isNotEmpty) Text(f.lagNote, key: const Key('lagNote'), style: small),
      const SizedBox(height: 8),
      if (f.warning.isNotEmpty) Text('⚠️ ${f.warning}', key: const Key('warning'), style: const TextStyle(color: Colors.deepOrange)),
      if (f.unfinished.isNotEmpty && !f.unfinishedUnderVerdict) Text(f.unfinished, key: const Key('unfinished')),
      if (f.membership.isNotEmpty) Text(f.membership, key: const Key('membership')),
      if (f.version.isNotEmpty) Text('軟體版本：${f.version}', key: const Key('version')),
      const SizedBox(height: 8),
      Row(children: [
        FilledButton(key: const Key('refresh'), onPressed: _busy ? null : _refresh, child: Text(_busy ? '讀取中…' : '重新整理')),
        const SizedBox(width: 8),
        if (_missed)
          const Expanded(child: Text(refreshMissed, key: Key('missed')))
        else if (f.rateNote.isNotEmpty)
          Expanded(child: Text(f.rateNote, key: const Key('rateNote'))),
      ]),
      ExpansionTile(
          key: const Key('tech'),
          title: const Text('技術資訊（給維修人員看）'),
          expandedCrossAxisAlignment: CrossAxisAlignment.start,
          children: [for (final l in f.tech) Text(l, style: small)]),
      if (f.canLeave && widget.onLeave != null) ...[
        const SizedBox(height: 16),
        Align(
            alignment: Alignment.centerLeft,
            child: TextButton(
                key: const Key('leave'),
                onPressed: _busy ? null : _leave,
                child: const Text('離開網路', style: TextStyle(color: Colors.red)))),
      ],
      if (_leaveLine.isNotEmpty) Text(screenText(_leaveLine), key: const Key('leaveLine')),
    ]);
  }
}

/// The "My nodes" layout (f139951): the controls scroll on their own above the log — on a phone they are taller than
/// the screen (found on the S20: 「加入隊伍網路」 was laid out off-screen and could not be reached).
class ControlsAndLog extends StatelessWidget {
  const ControlsAndLog({super.key, required this.controls, required this.log});
  final List<Widget> controls;
  final List<String> log;

  @override
  Widget build(BuildContext context) {
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Expanded(flex: 3, child: SingleChildScrollView(child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: controls))),
      const Divider(),
      Expanded(flex: 2, child: ListView(children: [for (final l in log) Text(l, style: const TextStyle(fontFamily: 'monospace'))])),
    ]);
  }
}
