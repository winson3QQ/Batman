// #254 app — remote invite screens (254-app-member-join v6.1 §5-1, §5-6, §8). Plain widgets with their actions
// passed in (no BLE, no Rust, no platform channel here), so the screen gates are widget-tested:
// - the two SAS screens carry the R22 line and call their action only when the button is pressed, with the SAS
//   string on the screen;
// - pasting is refused unless a dev build (the paste field never reads the clipboard otherwise);
// - the status page shows a network name only when the node's network id matches a record on this phone.
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
  const PasteButton({super.key, required this.label, required this.devTrust, required this.readClipboard, required this.onText, required this.onRefused});

  final String label;
  final Future<bool> Function() devTrust;
  final Future<String?> Function() readClipboard;
  final void Function(String text) onText;
  final void Function(String why) onRefused;

  @override
  Widget build(BuildContext context) {
    return OutlinedButton(
        key: Key('paste:$label'),
        onPressed: () async {
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

/// The fields of the status page (§8): only what the node sent ("" = not given).
class StatusFields {
  const StatusFields({this.state = '', this.reason = '', this.neighbours = '', this.health = '', this.snr = '', this.version = '', this.netId = ''});
  final String state, reason, neighbours, health, snr, version;

  /// info key 10 (lowercase hex): the network the node is in
  final String netId;
}

/// The network name for [netId]: only from a record on this phone (net/ or mnet/), never the id itself.
String? networkName(String netId, Map<String, String> names) => netId.isEmpty ? null : names[netId];

/// The status page (§8). No battery: the node never sends it.
class StatusPageView extends StatelessWidget {
  const StatusPageView({super.key, required this.fields, required this.names});
  final StatusFields fields;

  /// net_id hex -> netcfg name, from this phone's records
  final Map<String, String> names;

  @override
  Widget build(BuildContext context) {
    final f = fields;
    final name = networkName(f.netId, names);
    Widget row(String k, String v) => v.isEmpty ? const SizedBox.shrink() : Text('$k：$v', key: Key('status:$k'));
    return ListView(padding: const EdgeInsets.all(16), children: [
      row('狀態', f.state),
      row('原因', f.reason),
      row('網路名稱', name ?? (f.netId.isEmpty ? '' : '（不是這支手機的網路）')),
      row('鄰近節點', f.neighbours),
      row('網路狀況', f.health),
      row('訊號', f.snr),
      row('軟體版本', f.version),
    ]);
  }
}
