// #329 §12 PR 1: the smallest visible piece — one line per node under the startup check, from NodeLink alone. The
// real home page (§5.1) comes in PR 2; colours are given only to a 「新鮮」 read (§4.3.1).
import 'dart:async';

import 'package:flutter/material.dart';

import 'core.dart';
import 'node_link.dart';

String _last4(String id) => id.length > 4 ? id.substring(id.length - 4) : id;

/// The line for one node: (text, colour or null).
(String, Color?) nodeLine(NodeLink nl, String id) {
  final c = nl.core;
  final s = c.states[id]!;
  final why = c.shownWhy(id);
  if (why != null) {
    return switch (why) {
      Why.bluetoothOff => ('藍牙沒有打開', Colors.red),
      Why.noPermission => ('app 還沒有藍牙權限', Colors.red),
      Why.keys => ('手機的金鑰不能用', Colors.red),
      Why.identity => ('身分和手機記錄的不同', Colors.red),
      Why.refused => ('節點不接受這支手機的登入', Colors.orange),
      Why.notFound => ('手機連不到節點：可能沒開機、還在開機、離太遠，或另一支手機正在連它', Colors.orange),
    };
  }
  final now = nl.now();
  if (c.fresh(id, now)) {
    return switch (s.view) {
      'green' => ('正常', Colors.green),
      'yellow' => ('要注意', Colors.orange),
      'red' => ('有問題', Colors.red),
      "2'" => ('狀態未知 — 一直如此請找維修人員', Colors.grey),
      _ => ('節點回報不明', Colors.grey),
    };
  }
  if (s.kind == Kind.read && s.readAt != null) {
    final ago = ((now - s.readAt!) / 1000).round();
    return ('上次讀取 $ago 秒前', null);
  }
  if (s.responded) return ('有回應，還沒拿到狀態', null);
  return ('正在找節點…', null);
}

class NodeStatusList extends StatefulWidget {
  const NodeStatusList({super.key, required this.link});
  final NodeLink link;

  @override
  State<NodeStatusList> createState() => _NodeStatusListState();
}

class _NodeStatusListState extends State<NodeStatusList> {
  StreamSubscription<void>? _sub;
  Timer? _tick;

  @override
  void initState() {
    super.initState();
    _sub = widget.link.changed.listen((_) => mounted ? setState(() {}) : null);
    _tick = Timer.periodic(const Duration(seconds: 10), (_) => mounted ? setState(() {}) : null); // the 「秒前」
  }

  @override
  void dispose() {
    _sub?.cancel();
    _tick?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ids = widget.link.core.states.keys.toList()..sort();
    if (ids.isEmpty) return const SizedBox.shrink();
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        const Expanded(child: Text('節點狀態（自動讀取）', style: TextStyle(fontSize: 16))),
        IconButton(onPressed: widget.link.refresh, icon: const Icon(Icons.refresh), tooltip: '重新整理'),
      ]),
      for (final id in ids)
        Builder(builder: (_) {
          final (t, color) = nodeLine(widget.link, id);
          return ListTile(
            dense: true,
            leading: Icon(Icons.circle, size: 14, color: color ?? Colors.grey.shade400),
            title: Text('節點 …${_last4(id)}'),
            subtitle: Text(t),
          );
        }),
    ]);
  }
}
