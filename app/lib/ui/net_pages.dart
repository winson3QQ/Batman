// #329 PR 3 §2.4 / §2.5 / §2.8 (design §5.4): the network pages — 4.1 (the form: make or join, which nodes),
// NetRunPage (one node after the other, then the result: one route, two stages), CheckNetPage (檢查網路).
//
// Lease rules (plan §2.5, lease.dart:60-90):
// - 4.1 holds no lease while it shows the form. 「開始」: 4.1 acquires, compares its snapshot under the lease, and only
//   then pushes NetRunPage, handing the lease over; until it is handed over every way out of 4.1 releases it
//   (`_pending`, v14 AB-M1). From then NetRunPage is its only pageGone caller.
// - NetRunPage holds a `hold()` while it works (PopScope, keepScreenOn) and gives it back on the result stage; its
//   dispose is pageGone (released at once when idle; when a request is still running, released when it ends).
// - A page that borrows NetRunPage's lease (CheckNetPage from a result row) only takes and gives back its own hold.
// - CheckNetPage opened from 4.1 or the node page acquires its own lease (after the node was chosen) and pageGones it.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../member_ui.dart' show forgetNotice;
import '../nodes.dart' show NodesPage;
import '../say.dart' show screenText;
import '../src/flows/net_index.dart';
import '../src/flows/net_run.dart';
import '../src/flows/owner_console.dart';
import '../src/flows/rekey_send.dart' show RekeyEnd;
import '../src/nodelink/app_link.dart';
import '../src/nodelink/core.dart' as nl show Page;
import '../src/nodelink/handoff.dart';
import '../src/nodelink/lease.dart';
import '../src/nodelink/raw_use.dart' show openRawPage;
import '../swupdate.dart' show swChannel;
import 'home_logic.dart';
import 'home_page.dart' show nodeInfo;
import 'join_pages.dart' show JoinTeamPage;
import 'rekey_result.dart';
import 'theme.dart';
import 'ui_state.dart';
import 'widgets.dart';

/// What a check page or a run page hands back to 4.1: make a network now (§2.8 「建立網路」).
const goMake = 'make';

/// The plain line of a reply for the screen (log marks off).
String plain(String s) => screenText(s);

/// keepScreenOn (the update page's way, swupdate.dart:137); a convenience only.
Future<void> keepScreen(bool on) async {
  try {
    await swChannel.invokeMethod<void>('keepScreenOn', {'on': on});
  } on PlatformException {
    // the flow does not depend on it
  } on MissingPluginException {
    // tests without the channel
  }
}

/// The flows' view of the app, bound to [lease] (§2.5); the dialogs are the page's.
FlowDeps flowDeps(AppLink a, Lease lease, {required AskUser askCountry, required AskUser askRemoved, void Function()? onLost}) =>
    FlowDeps(
      login: (id, {bool clearNotY = false}) => a.link.loginFor(lease, id, clearNotY: clearNotY),
      console: (LoginHandoff h) => OwnerConsole(h, lease, a.writer, a.console,
          after: a.link.after,
          nowMs: a.link.now,
          askCountry: askCountry,
          askRemoved: askRemoved,
          keyError: (e) => keyErrorToRadio(e, a.link),
          log: (l) => debugPrint('BMAPP $l'),
          onLost: onLost),
      // §2.6: the one record read again under the lease; a record that does not read or open is not applied (§2.9)
      applied: (rel) async {
        try {
          final p = await a.nets.src.open(rel);
          return p != null && a.nets.src.summary(p).applied;
        } catch (_) {
          return false;
        }
      },
      blocked: () => a.link.core.blocked,
      leaseValid: () => lease.valid,
    );

/// The old console's questions (nodes.dart:280-292, :656-663), as the new pages' dialogs.
Future<bool> askYesNo(BuildContext context, String title, String body, String yes, String no) async {
  if (!context.mounted) return false;
  final t = BatTheme.of(context);
  return await showDialog<bool>(
          context: context,
          barrierDismissible: false,
          builder: (c) => AlertDialog(
                backgroundColor: t.surf,
                title: Text(title, style: TextStyle(fontSize: Fs.title, fontWeight: FontWeight.w700, color: t.ink)),
                content: SingleChildScrollView(
                    child: Text(body, style: TextStyle(fontSize: Fs.body, height: 1.6, color: t.ink))),
                actions: [
                  Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                    BatButton(yes, onPressed: () => Navigator.pop(c, true)),
                    const SizedBox(height: 6),
                    BatButton(no, kind: BtnKind.text, onPressed: () => Navigator.pop(c, false)),
                  ]),
                ],
              )) ==
      true;
}

/// A node's name; one no longer on the phone (removed meanwhile) is 「節點 XXXX」.
String nodeName(AppLink a, String id, UiState ui) =>
    a.link.core.states.containsKey(id) ? nodeInfo(a, id, ui).name : '節點 ${last4(id)}';

/// The old console's label (nodes.dart:621: mesh id, state, nodes) with the network's name first, so several networks
/// named 「Batman」 are told apart (device session 2026-11-16: four identical 「Batman（已建立）」 rows).
String _netLabel(NetEntry n) {
  final name = n.view.netName.isEmpty ? '' : '${n.view.netName} ';
  return '$name${n.view.meshId}（${n.applied ? '已建立' : '建立中'}，${n.view.members.length} 台）';
}

// ---- 4.1 -----------------------------------------------------------------------------------------------------------

/// Board 4.1: make or join a network, which nodes. [makes]: open in make mode (from 「建立網路」 or 「去建立」);
/// [ticked]: nodes ticked at first (the claimed one from 3.5 / 3.6, the node page's node, a todo's node);
/// [todo]: opened from 「節點加入網路沒有做完」 (its network picked, 「放棄這次加入」 shown).
class NetFormPage extends StatefulWidget {
  const NetFormPage(
      {super.key,
      required this.app,
      required this.ui,
      this.makes = false,
      this.ticked = const {},
      this.todo,
      this.back = nl.Page.home,
      this.backNode,
      this.devTrust = false,
      this.compute,
      this.runFlow,
      this.checkFlow});
  final AppLink app;
  final UiState ui;
  final bool makes;
  final Set<String> ticked;
  final JoinTodo? todo;
  final nl.Page back;
  final String? backNode;
  final bool devTrust;

  /// Tests: the records as listed under the lease at 「開始」 (the app: NetIndex.compute).
  final Future<NetSnapshot> Function()? compute;

  /// Tests: the run NetRunPage starts (the app builds it from the lease).
  final NetRun Function(Lease lease, Future<bool> Function(RunRow) askGoOn, AskUser askCountry, AskUser askRemoved, void Function() lost)? runFlow;

  /// Tests: the check pages it opens.
  final CheckRun Function(Lease lease, String id)? checkFlow;

  @override
  State<NetFormPage> createState() => _NetFormPageState();
}

class _NetFormPageState extends State<NetFormPage> {
  AppLink get a => widget.app;
  late bool _makes = widget.makes;
  String? _pick; // the picked net record (join mode)
  final Set<String> _ticked = {};
  bool _tickedOnce = false;
  String? _maker; // make mode: the node that makes (default: the first ticked)
  final _name = TextEditingController(text: 'Batman');
  int _channel = 40;
  bool _advanced = false;
  bool _busy = false;
  String? _note; // a line under the form (another operation, the records changed)
  Lease? _pending; // acquired, not handed over yet (v14 AB-M1)
  StreamSubscription<void>? _sub;
  NetSnapshot? _seen; // the snapshot the form was made from (§2.4: compared at 開始)
  bool _forgotten = false; // 放棄這次加入 done

  @override
  void initState() {
    super.initState();
    a.link.setPage(nl.Page.home); // P9: a node claimed meanwhile is read and can be ticked
    a.nets.addListener(_changed);
    _sub = a.link.changed.listen((_) => _changed());
    _pick = widget.todo?.net.rel;
  }

  void _changed() {
    // v18 AH m4 / code review B m4: a new NetIndex result is the form's snapshot (not while 開始 compares under its lease)
    final s = a.nets.now;
    if (!s.computing && _pending == null && !_busy) _seen = s;
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    a.nets.removeListener(_changed);
    _sub?.cancel();
    _name.dispose();
    final p = _pending;
    _pending = null;
    if (p != null) unawaited(p.release()); // every way out before the hand-over releases it
    a.link.setPage(widget.back, node: widget.backNode); // core.dart:186-201: the node page with its node
    super.dispose();
  }

  List<String> get _ids => (a.link.core.states.keys.toList()..sort((x, y) => _name4(x).compareTo(_name4(y))));
  String _name4(String id) => nodeName(a, id, widget.ui);

  /// §2.5 / v15 AD m5 / v18 AH m9: ticked once, when the list is first shown: the nodes read as not in a network,
  /// and the ones brought in; others stay as the user leaves them.
  void _tickOnce() {
    if (_tickedOnce || a.link.core.states.isEmpty) return;
    _tickedOnce = true;
    // code review B m6: a node that is a member of a network on this phone is not ticked even when its last read
    // (before the lease) still says 「not in a network」
    final members = {
      for (final n in a.nets.now.nets)
        for (final m in n.view.members)
          if (m.deviceId.isNotEmpty) m.deviceId
    };
    for (final id in _ids) {
      final v = nodeInfo(a, id, widget.ui).view;
      if (v != null && v.nodeState.toInt() == 1 && !members.contains(id)) _ticked.add(id);
    }
    _ticked.addAll(widget.ticked.where(a.link.core.states.containsKey));
    final t = widget.todo;
    if (t != null && a.link.core.states.containsKey(t.deviceId)) _ticked.add(t.deviceId);
  }

  NetEntry? _picked(NetSnapshot s) {
    if (s.nets.isEmpty) return null;
    final p = _pick;
    // code review C N-3: a network the user picked that is gone is not replaced by another one (no 開始 until picked)
    if (p != null) return s.nets.where((n) => n.rel == p).firstOrNull;
    return s.nets.length == 1 ? s.nets.first : null;
  }

  String _key(NetSnapshot s) => '${[for (final n in s.nets) '${n.rel}:${n.applied}'].join(',')}|${s.netFiles}';

  Future<void> _start(NetSnapshot s) async {
    if (_busy || _ticked.isEmpty) return;
    setState(() {
      _busy = true;
      _note = null;
    });
    try {
      final l = await a.link.acquire(_makes ? '建立網路' : '加入網路', LeaseKind.session);
      if (!mounted) {
        await l?.release(); // raw_use.dart:75-78
        return;
      }
      if (l == null) {
        setState(() => _note = '另一個操作還在進行：${a.reg.current?.name ?? ''}'); // D9: the form stays
        return;
      }
      _pending = l;
      // §2.4: the records again under the lease; another network or another state since the form was made -> no start
      final now = await (widget.compute ?? a.nets.compute)();
      // code review D M-1: the list's order (nicknames, as shown), so the node marked 「由這台建立網路」 is the one that makes
      final ticked = _ids.where(_ticked.contains).toList();
      if (!mounted || _pending == null) return; // dispose released it
      if (now.listFailed || _key(now) != _key(_seen ?? s) || ticked.length != _ticked.length) {
        _pending = null;
        await l.release();
        _seen = now;
        if (mounted) setState(() => _note = '手機裡的網路紀錄剛剛變了，請再確認一次再按「開始」。');
        return;
      }
      final order = [
        if (_makes) _maker != null && ticked.contains(_maker) ? _maker! : ticked.first,
        ...ticked.where((id) => !_makes || id != (_maker != null && ticked.contains(_maker) ? _maker : ticked.first)),
      ];
      final rel = _makes ? null : _picked(now)?.rel;
      if (!_makes && rel == null) {
        _pending = null;
        await l.release();
        if (mounted) setState(() => _note = '要加入的網路已經不在這支手機上，請重新選。'); // code review A m-5
        return;
      }
      _pending = null; // handed over: NetRunPage is its only pageGone caller from here
      final r = await Navigator.of(context).push<String>(MaterialPageRoute(
          builder: (_) => NetRunPage(
              app: a,
              ui: widget.ui,
              lease: l,
              ids: order,
              makes: _makes,
              joinRel: rel,
              name: _name.text,
              channel: _channel,
              flow: widget.runFlow == null ? null : (g, c, r, d) => widget.runFlow!(l, g, c, r, d),
              checkFlow: widget.checkFlow)));
      if (!mounted) return;
      if (r == goMake) {
        setState(() => _makes = true); // §2.8: 建立網路 from the check page
      } else {
        Navigator.of(context).pop();
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _check(NetEntry n) async {
    final r = await Navigator.of(context).push<String>(MaterialPageRoute(
        // code review B M3: the creator found by its name (`node-<last4>`), not a ticked node
        builder: (_) => CheckNetPage(app: a, ui: widget.ui, nets: [n], flow: widget.checkFlow)));
    if (!mounted) return;
    if (r == goMake) setState(() => _makes = true);
  }

  /// join2 §3.4 (nodes.dart:1250-1295): its own short session lease, written through RecordWriter (§2.4).
  Future<void> _forget(JoinTodo t) async {
    final ok = await askYesNo(context, '要放棄 ${_name4(t.deviceId)} 這次的加入嗎？', forgetNotice(approved: false), Btn.forgetJoin, Btn.cancel);
    if (!ok || !mounted) return;
    final l = await a.link.acquire(Btn.forgetJoin, LeaseKind.session);
    if (!mounted) {
      await l?.release();
      return;
    }
    if (l == null) {
      setState(() => _note = '另一個操作還在進行：${a.reg.current?.name ?? ''}');
      return;
    }
    String line;
    try {
      final (gen, p) = await a.console.readRecord(t.net.rel);
      if (p == null) throw recordUnopenedLine;
      line = await forgetJoining(l, a.writer,
          rel: t.net.rel, plain: p, gen: gen, dacHash: t.member.dacHash, seal: a.console.seal, keyError: (e) => keyErrorToRadio(e, a.link));
      _forgotten = true; // code review B m9: done, the button goes
    } catch (e) {
      line = e is String ? e : '[REQ_FAIL] 忘記沒有成功';
    } finally {
      await l.release();
    }
    if (mounted) setState(() => _note = plain(line));
  }

  Future<void> _oldConsole() async {
    final busy = await openRawPage(Navigator.of(context), a.link, a.gate, '我的節點', (u) => NodesPage(ble: a.ble, use: u));
    if (busy != null && mounted) setState(() => _note = '另一個操作還在進行：$busy');
  }

  @override
  Widget build(BuildContext context) {
    final t = BatTheme.of(context);
    final s = a.nets.now;
    final title = _makes ? Btn.makeNetwork : Btn.joinNetwork;
    if (s.computing) return BatPage(title: title, body: const [StatusHero(look: Look.busy, text: '正在讀取網路紀錄')]);
    if (s.listFailed) {
      return BatPage(title: title, body: [
        StatusHero(look: Look.bad, text: '讀不到手機裡的網路紀錄', extra: [BatButton(Btn.tryAgain, onPressed: a.nets.recompute)]),
      ]);
    }
    if (!_makes && s.noneOpens) {
      // join2 T8 (nodes.dart:609-610)
      return BatPage(title: title, body: const [
        StatusHero(look: Look.bad, text: '手機裡沒有可用的網路紀錄，不能再加節點。', next: '若 App 重裝過：新建網路會讓整隊分成兩個網路，舊節點要重燒。'),
      ]);
    }
    if (!_makes && s.netFiles == 0 && s.records != NetRecords.none) {
      // D3: only a team network (mnet) or a request (mpend): the member's join is the older console's (PR 5)
      return BatPage(title: title, body: [
        StatusHero(
            look: Look.unk,
            text: s.records == NetRecords.mpend ? '還在等隊長同意你的申請' : '這支手機加入的是別人的隊伍網路',
            extra: [if (widget.devTrust) BatButton(Btn.oldConsole, onPressed: _oldConsole)]),
      ]);
    }
    if (!_makes && s.netFiles == 0) _makes = true; // no network at all: make (§5.1 row 6)
    _seen ??= s;
    _tickOnce();
    final ids = _ids;
    final picked = _makes ? null : _picked(s);
    final pending = picked != null && !picked.applied;
    final firstTicked = ids.where(_ticked.contains).firstOrNull;
    final maker = _maker != null && _ticked.contains(_maker) ? _maker : firstTicked;
    final todo = widget.todo;
    return BatPage(
      title: title,
      body: [
        if (!_makes) ...[
          const BatLabel('要加入哪個網路'),
          RadioGroup<String>(
            groupValue: picked?.rel,
            onChanged: (v) => setState(() => _pick = v),
            child: BatCard(children: [
              for (final n in s.nets)
                RadioListTile<String>(value: n.rel, title: Text(_netLabel(n), style: TextStyle(fontSize: Fs.body, color: t.ink))),
            ]),
          ),
          if (pending)
            // §2.4 / join2 §3.2: a pending network is not joined; it is checked first
            StatusHero(look: Look.warn, text: '這個網路還沒確認建立完成', extra: [
              BatButton(Btn.checkNetwork, onPressed: () => _check(picked)),
              // v10 T-M1: only when no applied net (the same rule as 「沒有 net 才建立」)
              if (!s.anyApplied) BatButton(Btn.makeNetwork, kind: BtnKind.text, onPressed: () => setState(() => _makes = true)),
            ]),
        ],
        if (_makes) ...[
          const BatLabel('網路名稱'),
          TextField(controller: _name, maxLength: 24, decoration: const InputDecoration(border: OutlineInputBorder())),
        ],
        if (!pending) ...[
          BatLabel(_makes ? '要用哪些節點' : '要加入的節點'),
          BatCard(children: [
            for (final id in ids)
              CheckboxListTile(
                value: _ticked.contains(id),
                onChanged: (v) => setState(() => v == true ? _ticked.add(id) : _ticked.remove(id)),
                title: Text(_name4(id), style: TextStyle(fontSize: Fs.body, color: t.ink)),
                subtitle: Text(
                    [
                      nodeRowWords(nodeInfo(a, id, widget.ui), firstRounds: a.link.core.roundsRun < 3).$2,
                      if (_makes && id == maker) '由這台建立網路',
                    ].join('　'),
                    style: TextStyle(fontSize: Fs.meta, color: t.sub)),
                secondary: _makes && _ticked.contains(id) && id != maker
                    ? IconButton(tooltip: '改由這台建立', icon: const Icon(Icons.star_border), onPressed: () => setState(() => _maker = id))
                    : null,
              ),
          ]),
          if (_makes)
            BatCard(children: [
              BatRow(icon: Icons.tune, title: '進階', sub: '頻道 $_channel', onTap: () => setState(() => _advanced = !_advanced)),
              if (_advanced)
                RadioGroup<int>(
                  groupValue: _channel,
                  onChanged: (v) => setState(() => _channel = v ?? 40),
                  child: Column(children: [
                    for (final ch in const [40, 42])
                      RadioListTile<int>(
                          value: ch,
                          title: Text(ch == 40 ? '40（4 MHz，預設）' : '42（2 MHz）', style: TextStyle(fontSize: Fs.body, color: t.ink))),
                  ]),
                ),
            ]),
        ],
        if (todo != null && !_makes && !_forgotten) BatButton(Btn.forgetJoin, kind: BtnKind.text, onPressed: () => _forget(todo)),
        if (_note != null) Text(_note!, style: TextStyle(fontSize: Fs.body, color: t.ink)),
      ],
      foot: pending
          ? null
          : [
              BatButton(Btn.start,
                  onPressed: _busy || _ticked.isEmpty || (!_makes && picked == null) ? null : () => _start(s)),
            ],
    );
  }
}

// ---- 4.2-4.5: the run and its result (one route) -------------------------------------------------------------------

class NetRunPage extends StatefulWidget {
  const NetRunPage({
    super.key,
    required this.app,
    required this.ui,
    required this.lease,
    required this.ids,
    required this.makes,
    this.joinRel,
    this.name = 'Batman',
    this.channel = 40,
    this.member = false,
    this.flow,
    this.checkFlow,
  });
  final AppLink app;
  final UiState ui;
  final Lease lease;
  final List<String> ids;
  final bool makes;

  /// #329 PR 5 R16: a member's own node joins the team network of [joinRel] (mnet)
  final bool member;
  final String? joinRel;
  final String name;
  final int channel;

  /// Tests: the flow (fake logins and console); the app builds it from the lease.
  /// [lost]: closes a question the console asked when its link goes (§2.9).
  final NetRun Function(Future<bool> Function(RunRow) askGoOn, AskUser askCountry, AskUser askRemoved, void Function() lost)? flow;

  /// Tests: the check a result row opens.
  final CheckRun Function(Lease lease, String id)? checkFlow;

  @override
  State<NetRunPage> createState() => _NetRunPageState();
}

/// The run [p] asks for (the app's flow, on [d]); every parameter of the page goes in (R16: [NetRunPage.member]).
NetRun runFor(NetRunPage p, FlowDeps d, Future<bool> Function(RunRow) go) => NetRun(d,
    ids: p.ids, makes: p.makes, joinRel: p.joinRel, name: p.name, channel: p.channel, member: p.member, askGoOn: go);

class _NetRunPageState extends State<NetRunPage> {
  AppLink get a => widget.app;
  late final NetRun run;
  Cancel? _hold;
  bool _gone = false;
  bool _borrowed = false; // a check page works on this lease

  @override
  void initState() {
    super.initState();
    run = (widget.flow ?? _appFlow)(_askGoOn, _askCountry, _askRemoved, _dismiss);
    run.addListener(_changed);
    _work(run.run);
  }

  NetRun _appFlow(Future<bool> Function(RunRow) go, AskUser country, AskUser removed, void Function() lost) =>
      runFor(widget, flowDeps(a, widget.lease, askCountry: country, askRemoved: removed, onLost: lost), go);

  void _changed() {
    if (mounted) setState(() {});
  }

  /// Work under this page's lease: a hold (the lease is 「進行中」), PopScope, keepScreenOn; given back when it ends.
  void _work(Future<void> Function() f) {
    if (!widget.lease.valid) return;
    final h = _hold = widget.lease.hold();
    unawaited(keepScreen(true));
    f().whenComplete(() {
      unawaited(keepScreen(false));
      if (identical(_hold, h)) _hold = null;
      h(); // §2.5: given back after the request in progress (with pageGone first, the lease goes now)
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _gone = true;
    run.pageGone();
    run.removeListener(_changed);
    widget.lease.pageGone(); // idle: released now; working: when the hold is given back
    super.dispose();
  }

  BuildContext? _open; // the question on screen

  /// §2.9 (code review B M4): the console's link went (or it was closed): its open question goes as 「不要」 before
  /// anything else is asked — never two questions on top of each other.
  void _dismiss() {
    final c = _open;
    if (c != null) _closeQ(c, false);
  }

  /// The one way a question closes (a button, a blocked radio, a lost link): only while it is still the open one, so
  /// two of them in the same moment never pop a second route — the run page itself (code review C N-1 / D m-2).
  void _closeQ(BuildContext c, bool answer) {
    if (!identical(_open, c)) return;
    _open = null;
    if (c.mounted) Navigator.of(c).pop(answer);
  }

  Future<bool> _ask(Widget Function(BuildContext c) dialog) async {
    if (_gone || !mounted) return false;
    // §2.9: the radio blocked or the lease gone while the question is open -> closed as 「停」 / 「不要」
    BuildContext? dc;
    final sub = a.link.changed.listen((_) {
      final c = dc;
      if (c != null && c.mounted && (a.link.core.blocked != null || !widget.lease.valid)) _closeQ(c, false);
    });
    try {
      return await showDialog<bool>(
              context: context,
              barrierDismissible: false,
              builder: (c) {
                dc ??= _open = c; // once: a rebuild during its exit never makes it open again
                return dialog(c);
              }) ==
          true;
    } finally {
      if (identical(_open, dc)) _open = null;
      await sub.cancel();
    }
  }

  Widget _dialog(BuildContext c, String title, String body, String yes, String no) {
    final t = BatTheme.of(c);
    return PopScope(
      canPop: false,
      child: AlertDialog(
        backgroundColor: t.surf,
        title: Text(title, style: TextStyle(fontSize: Fs.title, fontWeight: FontWeight.w700, color: t.ink)),
        content: SingleChildScrollView(child: Text(body, style: TextStyle(fontSize: Fs.body, height: 1.6, color: t.ink))),
        actions: [
          Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            BatButton(yes, onPressed: () => _closeQ(c, true)),
            const SizedBox(height: 6),
            BatButton(no, kind: BtnKind.text, onPressed: () => _closeQ(c, false)),
          ]),
        ],
      ),
    );
  }

  Future<bool> _askGoOn(RunRow r) => _ask((c) => _dialog(c, '${_name(r.id)} 沒有完成', plain(r.line), Btn.nextNode, Btn.stopHere));
  Future<bool> _askCountry(String q) => _ask((c) => _dialog(c, '要改這台節點的國家嗎？', plain(q), '改', '不要'));
  Future<bool> _askRemoved(String q) => _ask((c) => _dialog(c, '這台之前被排除過', plain(q), '確定，加回', Btn.cancel));

  String _name(String id) => nodeName(a, id, widget.ui);

  Future<void> _check(RunRow r) async {
    _borrowed = true;
    setState(() {});
    final res = await Navigator.of(context).push<String>(MaterialPageRoute(
        builder: (_) => CheckNetPage(
            app: a, ui: widget.ui, borrowed: widget.lease, preselect: r.id, first: r.persistedRel, flow: widget.checkFlow)));
    _borrowed = false;
    if (!mounted) return;
    if (res == goMake) {
      Navigator.of(context).pop(goMake); // v12 X-M2: 4.1 switches to make mode; this page's dispose releases the lease
      return;
    }
    // v14 AB m6: the row from its own record, read again
    final rel = r.persistedRel;
    if (rel != null && widget.lease.valid) {
      final h = _hold = widget.lease.hold(); // code review B m7: the other rows wait (working)
      setState(() {});
      try {
        if (await flowDeps(a, widget.lease, askCountry: (_) async => false, askRemoved: (_) async => false).applied(rel)) {
          r.state = RowState.ok;
          r.line = '網路已建立';
          // code review D m-1: the network is made now: the run no longer reads as 「沒有建立完成」
          if (run.stopped == StopWhy.makeFailed) run.stopped = StopWhy.none;
        }
      } finally {
        if (identical(_hold, h)) _hold = null;
        h();
      }
    }
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final t = BatTheme.of(context);
    final working = run.running || _hold != null;
    final i = run.index;
    final title = working && i >= 0 && run.rows.length > 1 ? '第 ${i + 1} 台，共 ${run.rows.length} 台' : (widget.makes ? Btn.makeNetwork : Btn.joinNetwork);
    return PopScope(
      canPop: !working && !_borrowed,
      child: BatPage(
        title: title,
        body: [
          if (working)
            StatusHero(look: Look.busy, text: i >= 0 ? '${_name(run.rows[i].id)}：${run.rows[i].line}' : '正在進行', next: '請留在這個畫面')
          else
            StatusHero(
                look: run.rows.every((r) => r.state == RowState.ok && r.sendEnd != RekeyEnd.applying) ? Look.ok : Look.warn,
                text: !run.rows.every((r) => r.state == RowState.ok)
                    ? '有節點沒有完成'
                    : run.rows.any((r) => r.sendEnd == RekeyEnd.applying)
                        ? '已加入，有節點的新密碼還在套用'
                        : '完成',
                next: switch (run.stopped) {
                  StopWhy.blocked => '藍牙或權限現在不能用，已經停止。',
                  StopWhy.keys => '這支手機的金鑰現在不能用，已經停止。',
                  StopWhy.leaseLost => '這個操作已經停止。',
                  StopWhy.makeFailed => '網路沒有建立完成，其他節點沒有開始。',
                  _ => null,
                }),
          BatCard(children: [
            for (final r in run.rows)
              Padding(
                padding: const EdgeInsets.all(14),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text('${_name(r.id)}　${switch (r.state) {
                    RowState.ok => '完成',
                    RowState.failed => '沒有完成',
                    RowState.running => '進行中',
                    RowState.waiting => '等待中',
                    RowState.notDone => '還沒做',
                  }}', style: TextStyle(fontSize: Fs.body, fontWeight: FontWeight.w700, color: t.ink)),
                  if (r.line.isNotEmpty && r.line != r.sendLine && r.state != RowState.waiting && r.state != RowState.notDone)
                    Text(plain(r.line), style: TextStyle(fontSize: Fs.body, height: 1.5, color: t.ink)),
                  if (r.note.isNotEmpty) Text(r.note, style: TextStyle(fontSize: Fs.meta, color: t.sub)),
                  if (r.sendEnd case final e?) RekeyResult(end: e, line: r.sendLine, member: widget.member), // R14
                  if (!working && r.state == RowState.failed && needsNewInvite(r.line) && a.devTrust)
                    BatButton('收隊長的邀請', // S-m2
                        kind: BtnKind.secondary,
                        onPressed: () => Navigator.of(context)
                            .push(MaterialPageRoute(builder: (_) => JoinTeamPage(app: a, ui: widget.ui)))),
                  if (!working && r.canRetry)
                    BatButton(Btn.retryNode, kind: BtnKind.secondary, onPressed: () => _work(() => run.retry(r))),
                  if (!working && r.canCheck) BatButton(Btn.checkNetwork, kind: BtnKind.secondary, onPressed: () => _check(r)),
                ]),
              ),
          ]),
        ],
        foot: working ? null : [BatButton(Btn.done, onPressed: () => Navigator.of(context).pop())],
      ),
    );
  }
}

// ---- 檢查網路 --------------------------------------------------------------------------------------------------------

/// §2.8: 檢查網路 on the node that made the pending records. [borrowed]: the result page's lease (only holds are
/// taken); otherwise the node is chosen first and then a lease acquired. [preselect]: the node to check (from a
/// result row or the node page); otherwise the creator's name `node-<last4>` against the phone's nodes.
class CheckNetPage extends StatefulWidget {
  const CheckNetPage({super.key, required this.app, required this.ui, this.borrowed, this.preselect, this.first, this.nets, this.flow});
  final AppLink app;
  final UiState ui;
  final Lease? borrowed;
  final String? preselect;
  final String? first;

  /// The pending records the page was opened for (4.1's picked one); null = all of the phone's.
  final List<NetEntry>? nets;

  /// Tests: the flow on a lease.
  final CheckRun Function(Lease lease, String id)? flow;

  @override
  State<CheckNetPage> createState() => _CheckNetPageState();
}

class _CheckNetPageState extends State<CheckNetPage> {
  AppLink get a => widget.app;
  String? _id;
  Lease? _own; // acquired by this page (pageGone on dispose)
  CheckRun? _run;
  bool _working = false;
  String? _note;

  Lease? get _lease => widget.borrowed ?? _own;

  @override
  void initState() {
    super.initState();
    _id = widget.preselect ?? _byName();
  }

  /// §2.8: the creator's name (`node-<last4>`) against the phone's nodes; one match only.
  String? _byName() {
    final names = <String>{
      for (final n in widget.nets ?? a.nets.now.nets)
        if (!n.applied)
          for (final m in n.view.members)
            if (m.creator) m.name.toLowerCase()
    };
    final hits = [
      for (final id in a.link.core.states.keys)
        if (names.contains('node-${last4(id).toLowerCase()}')) id
    ];
    return hits.length == 1 ? hits.single : null;
  }

  @override
  void dispose() {
    _run?.pageGone(); // §3.2 T-R1(c): nothing starts after the request in progress
    _own?.pageGone();
    super.dispose();
  }

  Future<void> _go({bool clearNotY = false}) async {
    final id = _id;
    if (id == null || _working) return;
    setState(() {
      _working = true;
      _note = null;
    });
    try {
      var l = _lease;
      if (l == null) {
        // §2.8: chosen first, then the lease
        final got = await a.link.acquire(Btn.checkNetwork, LeaseKind.session);
        if (!mounted) {
          await got?.release();
          return;
        }
        if (got == null) {
          setState(() => _note = '另一個操作還在進行：${a.reg.current?.name ?? ''}');
          return;
        }
        _own = l = got;
      }
      if (!l.valid) return;
      final run = _run = (widget.flow ?? _appFlow)(l, id);
      final h = l.hold();
      try {
        await run.run(clearNotY: clearNotY);
      } finally {
        h();
      }
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  CheckRun _appFlow(Lease l, String id) => CheckRun(
        flowDeps(a, l, askCountry: (_) async => false, askRemoved: (_) async => false),
        id: id,
        first: widget.first,
        snapshot: a.nets.compute, // §2.8: listed under the lease, not NetIndex
      );

  @override
  Widget build(BuildContext context) {
    final t = BatTheme.of(context);
    final id = _id;
    final r = _run;
    final end = r?.end;
    return PopScope(
      canPop: !_working,
      child: BatPage(
        title: Btn.checkNetwork,
        body: [
          if (id == null) ...[
            const BatLabel('要檢查哪一台節點'),
            BatCard(children: [
              for (final n in a.link.core.states.keys)
                BatRow(
                    icon: Icons.router_outlined,
                    title: nodeName(a, n, widget.ui),
                    onTap: () => setState(() => _id = n)),
            ]),
          ] else ...[
            StatusHero(
              look: _working ? Look.busy : switch (end) { CheckEnd.upgraded => Look.ok, null => Look.unk, _ => Look.warn },
              text: _working
                  ? '正在檢查節點 ${last4(id)}'
                  : switch (end) {
                      null => '檢查的是節點 ${last4(id)}',
                      CheckEnd.upgraded => '網路已建立',
                      CheckEnd.answered => '節點回答了，網路還沒有建立完成',
                      CheckEnd.notCreator => '這台不是這些網路的建立者',
                      CheckEnd.nothingToCheck => '沒有需要檢查的網路',
                      CheckEnd.loginFailed => '沒有連到節點 ${last4(id)}',
                      CheckEnd.noAnswer => '沒有拿到節點的回答',
                      CheckEnd.blocked => '已經停止',
                      CheckEnd.unreadable => '讀不到手機裡的網路紀錄',
                    },
              next: _working ? '請留在這個畫面' : null,
            ),
            if (r != null)
              for (final l in r.lines) Text(plain(l), style: TextStyle(fontSize: Fs.body, height: 1.5, color: t.ink)),
          ],
          if (_note != null) Text(_note!, style: TextStyle(fontSize: Fs.body, color: t.ink)),
        ],
        foot: _working || id == null
            ? null
            : [
                if (end == null) BatButton(Btn.start, onPressed: () => _go()),
                if (end == CheckEnd.upgraded || end == CheckEnd.nothingToCheck)
                  BatButton(Btn.done, onPressed: () => Navigator.of(context).pop()),
                if (end != null && end != CheckEnd.upgraded && end != CheckEnd.nothingToCheck && end != CheckEnd.notCreator)
                  BatButton(Btn.checkAgain, onPressed: () => _go(clearNotY: true)),
                if (end == CheckEnd.notCreator)
                  BatButton(Btn.otherNode, onPressed: () => setState(() {
                        _id = null;
                        _run = null;
                      })),
                if (r != null && r.offerMake)
                  BatButton(Btn.makeNetwork, kind: BtnKind.text, onPressed: () => Navigator.of(context).pop(goMake)),
              ],
      ),
    );
  }
}

