// #329 design §5.1 (boards 1.5-1.11): the home page. Top to bottom: how things are now (StatusHero), my nodes,
// what can be done. Everything comes from NodeLink (§4.3); this page writes nothing.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../claim.dart';
import '../key_abilities.dart';
import '../nodes.dart';
import '../src/nodelink/app_link.dart';
import '../src/nodelink/core.dart' as nl;
import '../src/nodelink/raw_use.dart';
import '../src/rust/api/owner.dart' show StatusView, listPending, listNets;
import '../src/rust/api/member.dart' show listMnets, listPends;
import 'home_logic.dart';
import 'intro_pages.dart';
import 'node_page.dart';
import 'settings_page.dart';
import 'theme.dart';
import 'ui_state.dart';
import 'widgets.dart';

const _platform = MethodChannel('dev.batman/platform');

/// The phone's view of its nodes, built from NodeLink (used by the home page and the node page).
NodeInfo nodeInfo(AppLink a, String id, [UiState? ui]) {
  final c = a.link.core;
  final s = c.states[id]!;
  final now = a.link.now();
  final when = a.link.readWall[id]; // wall time (the core's clock stops in deep sleep; review pr1 A-m8)
  return NodeInfo(
    id: id,
    name: ui?.nodes[id]?.nick ?? '節點 ${last4(id)}',
    state: s,
    fresh: c.fresh(id, now),
    shownWhy: c.shownWhy(id),
    view: s.extra is StatusView ? s.extra as StatusView : null,
    readWall: when,
    prev: ui?.nodes[id],
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
  // PR 1's openRawPage: the lease is given up at the page's dispose; the page's busy work holds it past a pop
  final busy = await openRawPage(Navigator.of(context), a.link, a.gate, name, (u) {
    slow.cancel();
    if (shown) m.hideCurrentSnackBar();
    return page(u);
  });
  slow.cancel();
  if (busy != null) m.showSnackBar(SnackBar(content: Text('另一個操作還在進行：$busy')));
}

class HomePage extends StatefulWidget {
  const HomePage({super.key, required this.app, required this.ui, required this.devTrust, required this.keys, this.notes = const []});
  final AppLink app;
  final UiState ui;
  final bool devTrust;
  /// What the startup check said besides 「正常」 (a cleared interrupted save, keys only software-protected): kept on
  /// the settings page, not lost at the hand-over (review r3 F-m4)
  final List<String> notes;
  /// KeyGate (§4.1, F42): the startup key check; an entry a key cannot serve is grey with the reason
  final KeyAbilities keys;

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> with WidgetsBindingObserver {
  StreamSubscription<void>? _sub;
  Timer? _tick;
  int _pending = 0;
  NetRecords _records = NetRecords.unknown; // until the records were looked at: the neutral button (review r3 E-m3)

  AppLink get a => widget.app;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _sub = a.link.changed.listen((_) {
      _remember();
      if (mounted) setState(() {});
    });
    _tick = Timer.periodic(const Duration(seconds: 15), (_) => mounted ? setState(() {}) : null);
    _todos();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _sub?.cancel();
    _tick?.cancel();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState s) {
    if (s == AppLifecycleState.paused || s == AppLifecycleState.hidden) widget.ui.background(); // §4.6
  }

  /// §4.6: each fresh read's kind and time go to UiState (written only when a kind changed)
  void _remember() {
    final c = a.link.core, now = a.link.now();
    final reads = <String, (String, DateTime)>{};
    for (final id in c.states.keys) {
      final w = a.link.readWall[id];
      if (w == null || !c.fresh(id, now)) continue;
      final s = c.states[id]!;
      final v = s.extra;
      // not in a network is 「要注意」 on screen (row 6), so it is remembered as warn, not bad (PR 2 review A-m1)
      final notIn = v is StatusView && v.nodeState.toInt() == 1;
      reads[id] = (notIn ? 'warn' : switch (s.view) { 'green' => 'ok', 'yellow' => 'warn', 'red' => 'bad', _ => 'unk' }, w);
    }
    if (reads.isNotEmpty) widget.ui.noteReads(reads);
  }

  /// §5.1 todos this version knows: an unfinished claim (devTrust only, F48) and a lease taken back (§4.4).
  Future<void> _todos() async {
    // §5.1 row 6: which network records the phone holds (names only, nothing opened)
    var recs = NetRecords.none;
    try {
      if ((await listNets(dir: a.records)).isNotEmpty) {
        recs = NetRecords.net;
      } else if ((await listMnets(dir: a.records)).isNotEmpty) {
        recs = NetRecords.mnet;
      } else if ((await listPends(dir: a.records)).isNotEmpty) {
        recs = NetRecords.mpend;
      }
    } catch (_) {
      recs = NetRecords.unknown; // could not tell: the neutral 加入網路 into the console, never 建立網路 (review r2 D-m9)
    }
    _records = recs;
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
        _permission();
      case HomeAction.addNode:
        _addNode();
      case HomeAction.seeNode:
        if (h.node != null) _open(h.node!);
      // the network flows come in PR 3: until then these open the older console, where the same button is
      case HomeAction.joinNetwork || HomeAction.makeNetwork || HomeAction.seeRequest || HomeAction.joinTeam:
        _back(openUnderLease(context, a, '我的節點', (u) => NodesPage(ble: a.ble, use: u)));
      case HomeAction.refresh:
        a.link.refresh();
      case HomeAction.openBluetooth:
        _settings('bluetoothSettings', '請到手機的設定打開藍牙'); // §5.1 row 1: the system page; the status stream follows
      case HomeAction.showList || HomeAction.none:
        break;
    }
  }

  /// Opens a system settings page; when the phone has none, says where to go instead (review r2 D-m8).
  Future<void> _settings(String method, String otherwise) async {
    final ok = await _platform.invokeMethod<bool>(method).catchError((Object _) => false);
    if (ok != true && mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(otherwise)));
  }

  /// Board 2.2 first, when the app has no Bluetooth permission (F28: asked only when the user presses a button).
  Future<bool> _permission() async {
    final ok = await Navigator.of(context).push<bool>(MaterialPageRoute(
        builder: (_) => PermissionsPage(ask: () async => await _platform.invokeMethod<bool>('blePermissions') ?? false)));
    if (ok == true) a.link.radio(permission: true);
    return ok == true;
  }

  Future<void> _addNode() async {
    if (!widget.keys.claim) {
      // KeyGate (review r2 C-m6): every way to 新增節點 says the keys' own reason, none opens the claim page
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(widget.keys.refusal(KeyUse.claim) ?? '')));
      return;
    }
    if (a.link.core.blocked == nl.Why.noPermission && !await _permission()) return;
    if (!mounted) return;
    await _back(openUnderLease(context, a, '新增節點', (u) => ClaimPage(ble: a.ble, use: u)));
  }

  void _open(String id) {
    a.link.setPage(nl.Page.node, node: id);
    _back(Navigator.of(context).push(MaterialPageRoute(builder: (_) => NodePage(app: a, id: id, ui: widget.ui))));
  }

  @override
  Widget build(BuildContext context) {
    final t = BatTheme.of(context);
    final ids = a.link.core.states.keys.toList()..sort();
    final infos = [for (final id in ids) nodeInfo(a, id, widget.ui)];
    final todos = _pending + a.reg.unsavedTodos.length;
    final firstRounds = a.link.core.roundsRun < 3;
    final h = decideHome(
        HomeInputs(nodes: infos, blocked: a.link.core.blocked, firstRounds: firstRounds, todos: todos, records: _records));
    final freshest = infos.map((n) => n.readWall).whereType<DateTime>().fold<DateTime?>(null, (x, y) => x == null || y.isAfter(x) ? y : x);
    // a row about one node shows that node's read time, and only a fresh one (review r2 C-m8)
    final about = h.node == null ? null : infos.where((n) => n.id == h.node).firstOrNull;
    final shownTime = about != null ? (about.fresh ? about.readWall : null) : freshest;
    final actionText = switch (h.action) {
      HomeAction.allowBluetooth => Btn.allowBluetooth,
      HomeAction.addNode => Btn.addNode,
      HomeAction.seeNode => Btn.seeNode,
      HomeAction.openBluetooth => Btn.openBluetooth,
      HomeAction.joinNetwork => Btn.joinNetwork,
      HomeAction.makeNetwork => Btn.makeNetwork,
      HomeAction.seeRequest => Btn.seeRequest,
      _ => null,
    };
    return BatPage(
      title: 'Batman',
      badge: true,
      actions: [
        IconButton(
          tooltip: '設定',
          icon: Icon(Icons.settings_outlined, color: t.ink),
          onPressed: () {
            a.link.setPage(nl.Page.other); // §4.3.2: no reads while the settings are on screen (T-L8; review A-m3)
            _back(Navigator.of(context).push(MaterialPageRoute(builder: (_) => SettingsPage(app: a, devTrust: widget.devTrust, notes: widget.notes))));
          },
        ),
      ],
      body: [
        StatusHero(
          look: h.look,
          text: h.text,
          next: h.next,
          time: shownTime == null || h.look == Look.busy ? null : '讀取於 ${hhmmss(shownTime)}',
          onRefresh: h.look == Look.busy ? null : a.link.refresh,
          extra: actionText == null
              ? null
              : [
                  BatButton(actionText, onPressed: () => _act(h)),
                  if (h.second == HomeAction.joinTeam)
                    BatButton(Btn.joinTeam, kind: BtnKind.text, onPressed: () => _act(HomeHero(h.row, h.look, h.text, action: h.second))),
                ],
        ),
        if (h.row == 14 && !widget.ui.homeTip) HomeTipCard(onDone: () => widget.ui.setHomeTip().then((_) => mounted ? setState(() {}) : null)),
        for (final m in a.reg.unsavedTodos)
          BatBanner(look: Look.warn, title: m, text: '這個操作沒有在時間內結束，app 已經停止它。請到那台節點的頁面看目前的狀態，需要的話再做一次。',
              action: Btn.gotIt, onAction: () => setState(() => a.reg.unsavedTodos.remove(m))),
        if (_pending > 0)
          BatBanner(look: Look.warn, title: '上次新增節點沒有做完', action: Btn.finishIt, onAction: _addNode),
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
            sub: widget.keys.refusal(KeyUse.claim) ?? '把另一台節點加入這支手機',
            enabled: widget.keys.claim,
            onTap: _addNode,
          ),
        ]),
      ],
    );
  }
}
