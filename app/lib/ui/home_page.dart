// #329 design §5.1 (boards 1.5-1.11): the home page. Top to bottom: how things are now (StatusHero), my nodes,
// what can be done. Everything comes from NodeLink (§4.3); this page writes nothing.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../claim.dart';
import '../nodes.dart';
import '../src/nodelink/app_link.dart';
import '../src/nodelink/core.dart' as nl;
import '../src/nodelink/lease.dart';
import '../src/nodelink/raw_use.dart';
import '../src/rust/api/owner.dart' show StatusView, listPending;
import 'home_logic.dart';
import 'node_page.dart';
import 'settings_page.dart';
import 'theme.dart';
import 'widgets.dart';

const _platform = MethodChannel('dev.batman/platform');

/// The phone's view of its nodes, built from NodeLink (used by the home page and the node page).
NodeInfo nodeInfo(AppLink a, String id) {
  final c = a.link.core;
  final s = c.states[id]!;
  final now = a.link.now();
  final when = a.link.readWall[id]; // wall time (the core's clock stops in deep sleep; review pr1 A-m8)
  return NodeInfo(
    id: id,
    name: '節點 ${last4(id)}',
    state: s,
    fresh: c.fresh(id, now),
    shownWhy: c.shownWhy(id),
    view: s.extra is StatusView ? s.extra as StatusView : null,
    readWall: when,
  );
}

/// Opens an older page (it keeps its own BLE code) under a raw lease (§4.4, PR 1). The page's busy work holds the
/// lease past a pop (RawUse). While the last read is being ended (up to 5 s) the user sees why nothing opens yet
/// (review pr1 B-m4).
Future<void> openUnderLease(BuildContext context, AppLink a, String name, Widget Function(RawUse use) page) async {
  final m = ScaffoldMessenger.of(context);
  var shown = false;
  final slow = Timer(const Duration(milliseconds: 300), () {
    shown = true;
    m.showSnackBar(const SnackBar(content: Text('正在結束上一個讀取…')));
  });
  final lease = await a.link.acquire(name, LeaseKind.raw);
  slow.cancel();
  if (shown) m.hideCurrentSnackBar();
  if (!context.mounted) {
    await lease?.release(); // never keep a lease no page will use (review pr1 A-m4)
    return;
  }
  if (lease == null) {
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text('另一個操作還在進行：${a.reg.current?.name ?? ''}')));
    return;
  }
  final use = RawUse(lease, a.gate);
  await Navigator.of(context).push(MaterialPageRoute(builder: (_) => page(use)));
  lease.pageGone();
}

class HomePage extends StatefulWidget {
  const HomePage({super.key, required this.app, required this.devTrust, required this.canClaim});
  final AppLink app;
  final bool devTrust;
  final bool canClaim;

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  StreamSubscription<void>? _sub;
  Timer? _tick;
  int _pending = 0;

  AppLink get a => widget.app;

  @override
  void initState() {
    super.initState();
    _sub = a.link.changed.listen((_) => mounted ? setState(() {}) : null);
    _tick = Timer.periodic(const Duration(seconds: 15), (_) => mounted ? setState(() {}) : null);
    _todos();
  }

  @override
  void dispose() {
    _sub?.cancel();
    _tick?.cancel();
    super.dispose();
  }

  /// §5.1 todos this version knows: an unfinished claim (devTrust only, F48) and a lease taken back (§4.4).
  Future<void> _todos() async {
    var n = 0;
    if (widget.devTrust) {
      try {
        final p = await listPending(dir: a.records);
        n = p.where((id) => !a.link.core.states.containsKey(id)).length;
      } catch (_) {}
    }
    if (mounted) setState(() => _pending = n);
  }

  Future<void> _back(Future<void> f) async {
    await f;
    a.link.setPage(nl.Page.home);
    await _todos();
    if (mounted) setState(() {});
  }

  void _act(HomeHero h) {
    switch (h.action) {
      case HomeAction.allowBluetooth:
        _platform.invokeMethod<bool>('blePermissions').then((ok) => a.link.radio(permission: ok ?? false));
      case HomeAction.addNode:
        _addNode();
      case HomeAction.seeNode:
        if (h.node != null) _open(h.node!);
      case HomeAction.joinNetwork:
        _back(openUnderLease(context, a, '加入網路', (u) => NodesPage(ble: a.ble, use: u)));
      case HomeAction.refresh:
        a.link.refresh();
      case HomeAction.openBluetooth || HomeAction.showList || HomeAction.none:
        break;
    }
  }

  void _addNode() => _back(openUnderLease(context, a, '新增節點', (u) => ClaimPage(ble: a.ble, use: u)));

  void _open(String id) {
    a.link.setPage(nl.Page.node, node: id);
    _back(Navigator.of(context).push(MaterialPageRoute(builder: (_) => NodePage(app: a, id: id))));
  }

  @override
  Widget build(BuildContext context) {
    final t = BatTheme.of(context);
    final ids = a.link.core.states.keys.toList()..sort();
    final infos = [for (final id in ids) nodeInfo(a, id)];
    final todos = _pending + a.reg.unsavedTodos.length;
    final firstRounds = a.link.core.roundsRun < 3;
    final h = decideHome(HomeInputs(nodes: infos, blocked: a.link.core.blocked, firstRounds: firstRounds, todos: todos));
    final freshest = infos.map((n) => n.readWall).whereType<DateTime>().fold<DateTime?>(null, (x, y) => x == null || y.isAfter(x) ? y : x);
    final actionText = switch (h.action) {
      HomeAction.allowBluetooth => Btn.allowBluetooth,
      HomeAction.addNode => Btn.addNode,
      HomeAction.seeNode => Btn.seeNode,
      HomeAction.joinNetwork => Btn.joinNetwork,
      _ => null,
    };
    return BatPage(
      title: 'Batman',
      badge: true,
      actions: [
        IconButton(
          tooltip: '設定',
          icon: Icon(Icons.settings_outlined, color: t.ink),
          onPressed: () => _back(Navigator.of(context)
              .push(MaterialPageRoute(builder: (_) => SettingsPage(app: a, devTrust: widget.devTrust)))),
        ),
      ],
      body: [
        StatusHero(
          look: h.look,
          text: h.text,
          next: h.next,
          time: freshest == null || h.look == Look.busy ? null : '讀取於 ${hhmm(freshest)}',
          onRefresh: h.look == Look.busy ? null : a.link.refresh,
          extra: actionText == null ? null : [BatButton(actionText, onPressed: () => _act(h))],
        ),
        for (final m in a.reg.unsavedTodos)
          BatBanner(look: Look.warn, title: m, text: '這個操作沒有在時間內結束，app 已經停止它。請到那台節點的頁面看目前的狀態，需要的話再做一次。',
              action: Btn.gotIt, onAction: () => setState(() => a.reg.unsavedTodos.remove(m))),
        if (_pending > 0)
          BatBanner(look: Look.warn, title: '上次新增節點沒有做完', action: '繼續完成', onAction: _addNode),
        if (infos.isNotEmpty) ...[
          const BatLabel('我的節點'),
          BatCard(children: [
            for (final n in infos)
              Builder(builder: (_) {
                final (look, line, meta) = nodeRowWords(n, firstRounds: firstRounds);
                return NodeRow(look: look, name: n.name, line: line, meta: meta, onTap: () => _open(n.id));
              }),
          ]),
        ],
        const BatLabel('可以做的事'),
        BatCard(children: [
          BatRow(
            icon: Icons.add,
            title: Btn.addNode,
            sub: widget.canClaim ? '把另一台節點加入這支手機' : '這支手機的金鑰現在不能新增節點',
            enabled: widget.canClaim,
            onTap: _addNode,
          ),
        ]),
      ],
    );
  }
}
