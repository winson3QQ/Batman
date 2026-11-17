// #329 design §5.5 (boards 5.1-5.7): one node. Its status (read on entry, then every 60 s by NodeLink), its
// network group (PR 3), 手機 Wi-Fi and 更多 (PR 4 §2.3; technical data and 「從這支手機移除這台節點」 are in 更多).
import 'dart:async';

import 'package:flutter/material.dart';

import '../src/nodelink/app_link.dart';
import '../src/nodelink/core.dart' as nl show Page;
import 'home_logic.dart';
import 'home_page.dart' show nodeInfo;
import '../src/flows/net_index.dart' show NetEntry;
import 'more_pages.dart' show MorePage;
import 'join_choice.dart' show NetMode;
import 'send_key.dart';
import 'team_hub.dart' show PickNetPage;
import 'team_pages.dart' show MembersPage;
import '../say.dart' show screenText;
import '../src/flows/rekey_send.dart' show rustLast4, sameLast4;
import 'net_pages.dart' show CheckNetPage, NetFormPage, goMake;
import 'settings_pages.dart' show WifiPage;
import 'update_route.dart' show openSwUpdate;
import 'ui_state.dart';
import 'widgets.dart';

class NodePage extends StatefulWidget {
  const NodePage({super.key, required this.app, required this.id, required this.ui, this.openUpdate = false});
  final AppLink app;
  final UiState ui;
  final String id;

  /// #329 PR 4 §2.8: opened from the home todo 「軟體更新還沒做完」: the update page opens on top
  final bool openUpdate;

  @override
  State<NodePage> createState() => _NodePageState();
}

class _NodePageState extends State<NodePage> {
  StreamSubscription<void>? _sub;

  @override
  void initState() {
    super.initState();
    _sub = widget.app.link.changed.listen((_) => mounted ? setState(() {}) : null);
    widget.app.nets.addListener(_netsChanged); // #329 PR 3 §2.4: the network group follows the records
    widget.app.sw.addListener(_netsChanged); // #329 PR 4 §2.8: 「還沒做完」
    if (widget.openUpdate) WidgetsBinding.instance.addPostFrameCallback((_) => mounted ? _update() : null);
  }

  Future<void> _update() async {
    await openSwUpdate(context, widget.app, widget.ui, widget.id);
    if (mounted) setState(() {});
  }

  void _netsChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    widget.app.nets.removeListener(_netsChanged);
    widget.app.sw.removeListener(_netsChanged);
    _sub?.cancel();
    super.dispose();
  }

  Future<void> _open(Widget page) async {
    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => page));
    if (mounted) setState(() {});
  }

  /// §2.8 (code review A M-1 / B M2): 建立網路 on the check page -> 4.1 in make mode for this node; the check page's
  /// own lease goes at its dispose (the 開始 of 4.1 waits for it, D9).
  Future<void> _check(AppLink a, List<NetEntry> pending) async {
    final r = await Navigator.of(context).push<String>(
        MaterialPageRoute(builder: (_) => CheckNetPage(app: a, ui: widget.ui, preselect: widget.id, nets: pending)));
    if (r != goMake || !mounted) return;
    await Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => NetFormPage(app: a, ui: widget.ui, makes: true, ticked: {widget.id}, back: nl.Page.node, backNode: widget.id)));
  }

  /// #329 PR 3 §2.4 (design §5.5 :755): 加入網路 when this node is not in a network and the phone has one; 檢查網路
  /// when a pending network was made by a node of this name; never 建立網路 (D8: the home page and 3.5 / 3.6 are where
  /// a network is made). Null = nothing to show.
  List<Widget>? _network(AppLink a, NodeInfo n) {
    final nets = a.nets.now;
    final join = n.view != null && n.view!.nodeState.toInt() == 1 && nets.netFiles > 0;
    // R16: the member's join where this node is the entry of a team network on the phone, whatever its nodeState
    final entries = [
      for (final m in nets.mnets)
        if (a.devTrust && m.opens && m.entryLast4.isNotEmpty && sameLast4(rustLast4(widget.id), m.entryLast4)) m.id
    ];
    final member = entries.isNotEmpty;
    final me = 'node-${last4(widget.id).toLowerCase()}';
    final pending = [
      for (final e in nets.nets)
        if (!e.applied && e.view.members.any((m) => m.creator && m.name.toLowerCase() == me)) e
    ];
    if (!join && !member && pending.isEmpty) return null;
    return [
      const BatLabel('網路'),
      BatCard(children: [
        if (join || member)
          BatRow(
              key: const Key('node-join'),
              icon: Icons.hub_outlined,
              title: Btn.joinNetwork,
              // both -> asked in 4.1 (joinChoice); one -> that mode
              onTap: () => Navigator.of(context).push(MaterialPageRoute(
                  builder: (_) => NetFormPage(
                      app: a,
                      ui: widget.ui,
                      mode: join && member ? null : (member ? NetMode.member : NetMode.leader),
                      memberNet: entries.length == 1 ? entries.first : null,
                      ticked: {widget.id},
                      back: nl.Page.node,
                      backNode: widget.id)))),
        if (pending.isNotEmpty)
          BatRow(
              icon: Icons.fact_check_outlined,
              title: Btn.checkNetwork,
              sub: '這台建立的網路還沒確認建立完成',
              onTap: () => _check(a, pending)),
      ]),
    ];
  }

  /// §2.10 (E-M1): the new-key hint of this node's read, right under the verdict and before every group, whatever
  /// the node's state; its button sends through R17. Dev builds only (T-S5: the Rust entry has no dev gate, P9).
  Widget? _hint(AppLink a) {
    final h = a.link.hints[widget.id];
    if (!a.devTrust || h == null) return null;
    return StatusHero(
        key: const Key('node-hint'),
        look: Look.warn,
        text: screenText(h.line),
        extra: [if (h.button) SendKeyButton(app: a, id: widget.id)]);
  }

  /// §2.10: 「隊員」 when the phone holds a network it made: the node's own network when it is in an applied one, else
  /// picked.
  List<Widget>? _team(AppLink a, NodeInfo n) {
    final nets = a.nets.now;
    if (!a.devTrust || nets.netFiles == 0) return null;
    final mine = nets.nets.where((e) => e.applied && n.view != null && e.view.netId == n.view!.netId).firstOrNull;
    return [
      const BatLabel('隊員'),
      BatCard(children: [
        BatRow(
            key: const Key('node-team'),
            icon: Icons.groups_outlined,
            title: '隊員名單',
            sub: '邀請、收申請、移除隊員與換密碼',
            onTap: () => _open(mine != null
                ? MembersPage(app: a, netId: mine.id)
                : PickNetPage(app: a, title: '隊員名單', next: (id) => MembersPage(app: a, netId: id)))),
      ]),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final a = widget.app;
    if (!a.link.core.states.containsKey(widget.id)) {
      return const BatPage(title: '節點', body: [Text('這台節點已經不在這支手機上。')]);
    }
    final n = nodeInfo(a, widget.id, widget.ui);
    final (look, line, meta) = nodeRowWords(n, firstRounds: a.link.core.roundsRun < 3);
    final v = n.view;
    final next = [
      // #329 PR 4 §2.3 (leave v4.1 §2): the unfinished-change line, right under the verdict when info key 10 is absent
      if (n.fresh && v != null && v.unfinished.isNotEmpty && v.unfinishedUnderVerdict) v.unfinished,
      if (n.fresh && v != null && v.warning.isNotEmpty) v.warning,
      if (n.fresh && v != null && v.unfinished.isNotEmpty && !v.unfinishedUnderVerdict) v.unfinished,
      if (n.fresh && v != null && v.lagNote.isNotEmpty) v.lagNote,
      if (n.shownWhy != null) whyNext(n.shownWhy!),
    ];
    return BatPage(
      title: n.name,
      body: [
        StatusHero(
          look: look,
          text: line,
          next: next.isEmpty ? null : next.join('\n'),
          time: n.readWall == null ? null : (n.fresh ? '讀取於 ${hhmmss(n.readWall!)}' : meta),
          onRefresh: a.link.refresh,
        ),
        ?_hint(a),
        ...?_network(a, n),
        ...?_team(a, n),
        // #329 PR 4 §2.3 (design §5.5): 手機 Wi-Fi, 軟體更新, 更多 (隊員: PR 5)
        const BatLabel('手機 Wi-Fi'),
        BatCard(children: [
          BatRow(
              key: const Key('node-wifi'),
              icon: Icons.wifi,
              title: '手機 Wi-Fi',
              sub: '給手機連的 Wi-Fi 名稱和密碼',
              onTap: () => _open(WifiPage(app: a, ui: widget.ui, id: widget.id))),
        ]),
        const BatLabel('軟體更新'),
        BatCard(children: [
          BatRow(
              key: const Key('node-update'),
              icon: Icons.system_update_alt,
              title: '軟體更新',
              sub: a.sw.unfinished(widget.id) ? '還沒做完：已準備好，還沒套用' : '選更新檔、傳送、套用',
              onTap: _update),
        ]),
        BatCard(children: [
          BatRow(
              key: const Key('node-more'),
              icon: Icons.more_horiz,
              title: Btn.more,
              sub: '改暱稱、國家、離開網路、技術資訊、移除',
              onTap: () => _open(MorePage(app: a, ui: widget.ui, id: widget.id))),
        ]),
      ],
    );
  }
}
