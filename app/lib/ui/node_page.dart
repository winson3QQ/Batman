// #329 design §5.5 (boards 5.1-5.7): one node. Its status (read on entry, then every 60 s by NodeLink), its
// technical data, and 「從這支手機移除這台節點」 (T17). Network / Wi-Fi / update pages come in PR 3 / 4.
import 'dart:async';

import 'package:flutter/material.dart';

import '../src/nodelink/app_link.dart';
import '../src/nodelink/lease.dart';
import 'home_logic.dart';
import 'home_page.dart' show nodeInfo;
import 'theme.dart';
import 'ui_state.dart';
import 'widgets.dart';

class NodePage extends StatefulWidget {
  const NodePage({super.key, required this.app, required this.id, required this.ui});
  final AppLink app;
  final UiState ui;
  final String id;

  @override
  State<NodePage> createState() => _NodePageState();
}

class _NodePageState extends State<NodePage> {
  StreamSubscription<void>? _sub;
  bool _tech = false;

  @override
  void initState() {
    super.initState();
    _sub = widget.app.link.changed.listen((_) => mounted ? setState(() {}) : null);
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  Future<void> _remove(String name) async {
    final t = BatTheme.of(context);
    final yes = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        backgroundColor: t.surf,
        title: Text('要從這支手機移除$name嗎？', style: TextStyle(fontSize: Fs.title, fontWeight: FontWeight.w700, color: t.ink)),
        content: Text(
            '這支手機會忘記$name（後四碼 ${last4(widget.id)}），之後不能再用這支手機管理它。節點本身不會改變。之後要再新增它，只能請維修人員重新燒錄（會換新的 QR）。',
            style: TextStyle(fontSize: Fs.body, height: 1.6, color: t.ink)),
        actions: [
          BatButton(Btn.remove, kind: BtnKind.danger, onPressed: () => Navigator.pop(c, true)),
          BatButton(Btn.cancel, kind: BtnKind.text, onPressed: () => Navigator.pop(c, false)),
        ],
      ),
    );
    if (yes != true || !mounted) return;
    final a = widget.app;
    final lease = await a.link.acquire('移除節點', LeaseKind.session);
    if (!mounted) return;
    if (lease == null) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('另一個操作還在進行：${a.reg.current?.name ?? ''}')));
      return;
    }
    String? err;
    try {
      // T17: keep a copy first; no copy -> nothing is deleted
      final kept = await lease.run(() => a.writer.keepCopy(lease, 'node/${widget.id}'));
      if (!kept) {
        err = '沒有辦法先留一份副本，所以沒有移除。紀錄維持原樣。';
      } else {
        await lease.run(() => a.writer.remove(lease, 'node/${widget.id}'));
      }
    } catch (e) {
      err = '沒有移除成功，紀錄維持原樣（$e）';
    }
    await lease.release();
    if (err == null) await widget.ui.forget(widget.id); // §5.5: its nickname and status go too
    if (!mounted) return;
    if (err != null) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(err)));
      return;
    }
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final a = widget.app;
    if (!a.link.core.states.containsKey(widget.id)) {
      return const BatPage(title: '節點', body: [Text('這台節點已經不在這支手機上。')]);
    }
    final t = BatTheme.of(context);
    final n = nodeInfo(a, widget.id, widget.ui);
    final (look, line, meta) = nodeRowWords(n, firstRounds: a.link.core.roundsRun < 3);
    final v = n.view;
    final next = [
      if (n.fresh && v != null && v.warning.isNotEmpty) v.warning,
      if (n.fresh && v != null && v.lagNote.isNotEmpty) v.lagNote,
      if (n.shownWhy != null) '節點可能沒開機、還在開機，或離手機太遠。app 會持續自動重試，連上後這裡會自己更新。',
    ];
    return BatPage(
      title: n.name,
      body: [
        StatusHero(
          look: look,
          text: line,
          next: next.isEmpty ? null : next.join('\n'),
          time: n.readWall == null ? null : (n.fresh ? '讀取於 ${hhmm(n.readWall!)}' : meta),
          onRefresh: a.link.refresh,
        ),
        BatCard(children: [
          BatRow(
              icon: Icons.build_outlined,
              title: '技術資訊（給維修人員看）',
              onTap: () => setState(() => _tech = !_tech)),
          if (_tech)
            Padding(
              padding: const EdgeInsets.all(14),
              child: SelectableText(
                [
                  '後四碼 ${last4(widget.id)}',
                  if (v != null) ...['版本 ${v.version}', if (v.netId.isNotEmpty) '網路 ${v.netId}', ...v.tech],
                ].join('\n'),
                style: TextStyle(fontFamily: 'monospace', fontSize: Fs.meta, height: 1.5, color: t.ink),
              ),
            ),
        ]),
        const BatLabel('會影響這支手機的動作'),
        BatCard(children: [
          BatRow(
            icon: Icons.delete_outline,
            title: '從這支手機移除這台節點',
            sub: '之後要再新增它，只能請維修人員重新燒錄',
            danger: true,
            onTap: () => _remove(n.name),
          ),
        ]),
      ],
    );
  }
}
