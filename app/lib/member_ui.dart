// #254 app — remote invite screens (254-app-member-join v6.1 §5-1, §5-6, §8). Plain widgets with their actions
// passed in (no BLE, no Rust, no platform channel here), so the screen gates are widget-tested:
// - the two SAS screens carry the R22 line and call their action only when the button is pressed, with the SAS
//   string on the screen;
// - pasting is refused unless a dev build (the paste field never reads the clipboard otherwise);
// - the status page (254-app-status-page v8.1 §2) shows Rust's verdict; a network name only from a record on this
//   phone; an E_RATE keeps the earlier read time;
// - My nodes: the controls scroll above the log (f139951).
import 'package:flutter/material.dart';

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
      this.fresh = true});
  final String color, sentence, lagNote, warning, membership, version, rateNote;
  final List<String> tech;
  final bool fresh;
}

/// The network name for [netId]: only from a record on this phone (net/ or mnet/), never the id itself.
String? networkName(String netId, Map<String, String> names) => netId.isEmpty ? null : names[netId];

/// §2-1 / §2-5: the read time shown — a fresh read is "now"; a read refused with E_RATE keeps the earlier read's time.
DateTime readTime({required bool fresh, required DateTime now, DateTime? previous}) => fresh || previous == null ? now : previous;

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
  const StatusPageView({super.key, required this.initial, required this.initialAt, required this.onRefresh, this.clock = DateTime.now});
  final StatusFields initial;
  final DateTime initialAt;

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

  Future<void> _refresh() async {
    setState(() => _busy = true);
    try {
      final r = await widget.onRefresh();
      if (r != null && mounted) {
        setState(() {
          _at = readTime(fresh: r.fresh, now: widget.clock(), previous: _at);
          _f = r;
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
      Text('讀取於 ${hms(_at)}', key: const Key('readAt'), style: small),
      if (f.lagNote.isNotEmpty) Text(f.lagNote, key: const Key('lagNote'), style: small),
      const SizedBox(height: 8),
      if (f.warning.isNotEmpty) Text('⚠️ ${f.warning}', key: const Key('warning'), style: const TextStyle(color: Colors.deepOrange)),
      if (f.membership.isNotEmpty) Text(f.membership, key: const Key('membership')),
      if (f.version.isNotEmpty) Text('軟體版本：${f.version}', key: const Key('version')),
      const SizedBox(height: 8),
      Row(children: [
        FilledButton(key: const Key('refresh'), onPressed: _busy ? null : _refresh, child: const Text('重新整理')),
        const SizedBox(width: 8),
        if (f.rateNote.isNotEmpty) Expanded(child: Text(f.rateNote, key: const Key('rateNote'))),
      ]),
      ExpansionTile(
          key: const Key('tech'),
          title: const Text('技術資訊（給維修人員看）'),
          expandedCrossAxisAlignment: CrossAxisAlignment.start,
          children: [for (final l in f.tech) Text(l, style: small)]),
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
