// #329 design §5.1 (boards 1.5-1.11): the home page. Top to bottom: how things are now (StatusHero), my nodes,
// what can be done. Everything comes from NodeLink (§4.3); this page writes nothing.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../claim.dart';
import '../key_abilities.dart';
import '../src/nodelink/app_link.dart';
import '../src/nodelink/core.dart' as nl;
import '../src/nodelink/lease.dart' show Lease, LeaseListener, Token;
import '../src/nodelink/raw_use.dart';
import '../src/rust/api/owner.dart' show StatusView, listPending;
import '../src/flows/net_index.dart' show JoinTodo;
import 'add_pages.dart';
import 'home_logic.dart';
import 'intro_pages.dart';
import 'join_pages.dart' show JoinTeamPage, MyRequestPage;
import 'net_pages.dart' show NetFormPage;
import 'team_hub.dart' show PickPendPage;
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

/// #329 PR 3 §2.7: [openUnderLease] that returns what the page popped (ClaimPage: ClaimDone).
Future<T?> openUnderLeaseFor<T>(BuildContext context, AppLink a, String name, Widget Function(RawUse use) page) async {
  final m = ScaffoldMessenger.of(context);
  var shown = false;
  final slow = Timer(const Duration(milliseconds: 300), () {
    shown = true;
    m.showSnackBar(const SnackBar(content: Text('正在結束上一個讀取…')));
  });
  final (busy, r) = await openRawPageFor<T>(Navigator.of(context), a.link, a.gate, name, (u) {
    slow.cancel();
    if (shown) m.hideCurrentSnackBar();
    return page(u);
  });
  slow.cancel();
  if (busy != null) m.showSnackBar(SnackBar(content: Text('另一個操作還在進行：$busy')));
  return r;
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

class _HomePageState extends State<HomePage> with WidgetsBindingObserver implements LeaseListener {
  StreamSubscription<void>? _sub;
  Timer? _tick;
  int _pending = 0;

  AppLink get a => widget.app;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _sub = a.link.changed.listen((_) {
      _remember();
      if (mounted) setState(() {});
    });
    a.nets.addListener(_netsChanged); // #329 PR 3 §2.6: row 6 and the join todos follow the network records
    a.sw.addListener(_netsChanged); // #329 PR 4 §2.8: 「軟體更新還沒做完」
    _tick = Timer.periodic(const Duration(seconds: 15), (_) => mounted ? setState(() {}) : null);
    a.reg.listeners.add(this); // T-H3: the todos are computed again once a lease is released (design §5.1)
    _todos();
  }

  // re-test 2026-11-17 (T-H3): a claim still running behind a closed page left 「上次新增節點沒有做完」 until the next
  // page change; the todos follow the release of every lease now
  @override
  void revoked(Token t) {}

  @override
  void released(Lease l, {required bool revoked}) => _todos();

  void _netsChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    a.reg.listeners.remove(this);
    a.nets.removeListener(_netsChanged);
    a.sw.removeListener(_netsChanged);
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
  /// Row 6's records and the join todos come from NetIndex (#329 PR 3 §2.6).
  Future<void> _todos() async {
    var n = 0;
    if (widget.devTrust) {
      try {
        final p = await listPending(dir: a.records);
        n = p.where((id) => !a.link.core.states.containsKey(id)).length;
      } catch (_) {
        return; // review misc J m-2: the list unreadable -> keep the todos shown (never hide one on an error)
      }
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
      // #329 PR 5 §2.10: row 6 to the new pages; 4.1 decides leader or member by R16 (T-N2's split unchanged)
      case HomeAction.makeNetwork:
        _form(makes: true, node: h.node);
      case HomeAction.joinNetwork:
        _form(makes: false, node: h.node);
      case HomeAction.seeRequest when widget.devTrust: // review B m5: 7.9 only in the dev build (F14)
        _back(Navigator.of(context).push(MaterialPageRoute(builder: (_) => PickPendPage(app: a, ui: widget.ui))));
      case HomeAction.joinTeam:
        _back(Navigator.of(context).push(MaterialPageRoute(builder: (_) => JoinTeamPage(app: a, ui: widget.ui))));
      case HomeAction.refresh:
        a.link.refresh();
      case HomeAction.openBluetooth:
        _settings('bluetoothSettings', '請到手機的設定打開藍牙'); // §5.1 row 1: the system page; the status stream follows
      case HomeAction.showList || HomeAction.none || HomeAction.seeRequest:
        break;
    }
  }

  /// 4.1 (§2.4 / §2.5): make or join, [node] ticked; [todo]: 「節點加入網路沒有做完」 (its network, 「放棄這次加入」).
  void _form({required bool makes, String? node, JoinTodo? todo}) => _back(Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => NetFormPage(
          app: a, ui: widget.ui, makes: makes, ticked: {?node}, todo: todo))));

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
    // §2.7: the claim page pops ClaimDone when a node was added -> 3.2 取名 -> 3.5 / 3.6; a claim that ends after the
    // page was closed leaves its line for the home page (F41)
    final done = await openUnderLeaseFor<ClaimDone>(
        context, a, '新增節點', (u) => ClaimPage(ble: a.ble, use: u, goneNote: (s) => a.lastClaimNote = s));
    a.link.setPage(nl.Page.home);
    await _todos();
    if (done == null || !mounted) {
      if (mounted) setState(() {});
      return;
    }
    final r = await Navigator.of(context).push<String>(
        MaterialPageRoute(builder: (_) => NickPage(app: a, ui: widget.ui, id: done.id, devTrust: widget.devTrust)));
    a.link.setPage(nl.Page.home);
    if (!mounted) return;
    setState(() {});
    if (r == addAgain) await _addNode(); // 3.6 「再加一台」
  }

  void _open(String id, {bool update = false}) {
    a.link.setPage(nl.Page.node, node: id);
    _back(Navigator.of(context)
        .push(MaterialPageRoute(builder: (_) => NodePage(app: a, id: id, ui: widget.ui, openUpdate: update))));
  }

  @override
  Widget build(BuildContext context) {
    final t = BatTheme.of(context);
    final ids = a.link.core.states.keys.toList()..sort();
    final infos = [for (final id in ids) nodeInfo(a, id, widget.ui)];
    final nets = a.nets.now;
    // #329 PR 5 (design §5.1): a request waiting is a todo (dev builds only: F14)
    final pends = widget.devTrust ? nets.mpendIds : const <String>[];
    final todos = _pending +
        a.reg.unsavedTodos.length +
        nets.todos.length +
        a.sw.unfinishedOf(a.link.core.states.containsKey).length +
        pends.length;
    final firstRounds = a.link.core.roundsRun < 3;
    final h = decideHome(
        HomeInputs(nodes: infos, blocked: a.link.core.blocked, firstRounds: firstRounds, todos: todos, records: nets.records));
    // the status area's time is only ever a fresh read's: an older one is not 「讀取於」 (review r3 E-m8 / C-m8)
    final freshest = infos.where((n) => n.fresh).map((n) => n.readWall).whereType<DateTime>().fold<DateTime?>(null, (x, y) => x == null || y.isAfter(x) ? y : x);
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
            _back(Navigator.of(context).push(MaterialPageRoute(builder: (_) => SettingsPage(app: a, ui: widget.ui, devTrust: widget.devTrust, notes: widget.notes))));
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
                  if (h.second == HomeAction.joinTeam && widget.devTrust) // 7.8 (F14 / T-S5)
                    BatButton(Btn.joinTeam, kind: BtnKind.text, onPressed: () => _act(HomeHero(h.row, h.look, h.text, action: h.second))),
                ],
        ),
        if (h.row == 14 && !widget.ui.homeTip) HomeTipCard(onDone: () => widget.ui.setHomeTip().then((_) => mounted ? setState(() {}) : null)),
        for (final m in a.reg.unsavedTodos)
          BatBanner(
              look: Look.warn,
              title: m,
              // #329 PR 5 R12: an offline operation's own sentence (it touches no node), else the node one
              text: a.reg.unsavedText[m] ?? '這個操作沒有在時間內結束，app 已經停止它。請到那台節點的頁面看目前的狀態，需要的話再做一次。',
              action: Btn.gotIt,
              onAction: () => setState(() {
                    a.reg.unsavedTodos.remove(m);
                    a.reg.unsavedText.remove(m);
                  })),
        if (_pending > 0)
          BatBanner(look: Look.warn, title: '上次新增節點沒有做完', action: Btn.finishIt, onAction: _addNode),
        // F41 (§2.7): the line of a claim that ended after its page was closed, once
        if (a.lastClaimNote != null)
          BatBanner(
              look: Look.unk,
              title: '剛才的新增節點',
              text: a.lastClaimNote,
              action: Btn.gotIt,
              onAction: () => setState(() => a.lastClaimNote = null)),
        // §5.1: a node of this phone that started joining a network and did not finish (NetIndex, `forgettable`)
        for (final j in nets.todos)
          BatBanner(
              look: Look.warn,
              title: '節點加入網路沒有做完',
              text: '${nodeInfo(a, j.deviceId, widget.ui).name} 加入「${j.net.view.netName.isEmpty ? j.net.view.meshId : j.net.view.netName}」還沒有完成。',
              action: Btn.finishIt,
              onAction: () => _form(makes: false, todo: j)),
        // #329 PR 5 (design §5.1): a request waiting for the leader -> 7.9
        for (final id in pends)
          BatBanner(
              key: Key('todo-pend-$id'),
              look: Look.unk,
              title: '你的加入申請還在等隊長同意',
              action: Btn.seeRequest,
              onAction: () => _back(Navigator.of(context)
                  .push(MaterialPageRoute(builder: (_) => MyRequestPage(app: a, ui: widget.ui, netId: id))))),
        // #329 PR 4 §2.8 (design §4.8): an update prepared and not applied (memory only, as the update itself)
        for (final id in a.sw.unfinishedOf(a.link.core.states.containsKey))
          BatBanner(
              look: Look.warn,
              title: '軟體更新還沒做完',
              text: '${nodeInfo(a, id, widget.ui).name}：更新已經準備好，還沒套用。',
              action: Btn.finishIt,
              onAction: () => _open(id, update: true)),
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
