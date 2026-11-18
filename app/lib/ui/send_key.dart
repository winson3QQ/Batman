// #329 PR 5 R17 / R14: 「把新密碼送給節點」 on the node page (the hint card and 更多): sendNewKey for this node with the
// confirmation (its default), the result through RekeyResult. A send that stopped before the node's record was known
// (nothing sent: no network, no record, not reached) shows its own line.
import 'package:flutter/material.dart';

import '../say.dart' show SayLine;
import '../src/flows/rekey_send.dart';
import '../src/nodelink/app_link.dart';
import 'rekey_result.dart';
import 'settings_pages.dart' show opLine;
import 'team_deps.dart';
import 'widgets.dart';

const kSendKey = '把新密碼送給節點';

class SendKeyButton extends StatefulWidget {
  const SendKeyButton({super.key, required this.app, required this.id, this.row = false, this.off = false});
  final AppLink app;
  final String id;

  /// true: a row (更多); false: a button (the hint card)
  final bool row;

  /// #329 PR 7 T6: Bluetooth off or no permission (nothing can be sent): the button is a greyed secondary one, so the
  /// status area's Bluetooth button is the page's only primary one; the widget (and a result it shows) stays
  final bool off;

  @override
  State<SendKeyButton> createState() => _SendKeyButtonState();
}

class _SendKeyButtonState extends State<SendKeyButton> {
  RekeySent? _sent;
  bool _running = false;

  Future<void> _send() async {
    setState(() => _running = true);
    final r = await sendNewKey(teamDeps(widget.app).send(context), widget.id, gone: () => !mounted);
    if (!mounted) return;
    setState(() {
      _running = false;
      _sent = r;
    });
    widget.app.link.refresh(); // R17 step 5 (review A m4): the node read again, the card follows
  }

  @override
  Widget build(BuildContext context) {
    final s = _sent;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      if (widget.row)
        BatRow(key: Key('send-key-${widget.id}'), icon: Icons.vpn_key_outlined, title: kSendKey, enabled: !_running, onTap: _send)
      else
        BatButton(kSendKey,
            key: Key('send-key-${widget.id}'),
            kind: widget.off ? BtnKind.secondary : BtnKind.primary,
            onPressed: _running || widget.off ? null : _send),
      if (s != null)
        Padding(
          padding: const EdgeInsets.all(12),
          child: s.notReached != null
              ? SayLine(opLine(s.notReached!), key: const Key('send-key-line'))
              : s.member == null
                  ? SayLine(s.line, key: const Key('send-key-line'))
                  : RekeyResult(end: s.end, line: s.line, member: s.member!, version: s.version),
        ),
    ]);
  }
}
