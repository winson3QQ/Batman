// (review pr6 A-9) "nodes.dart" / "nodes.dart:<line>" below = the old console, deleted by #329 PR 6: see
// `git show c4905ed:app/lib/nodes.dart` (main before PR 6).
// #329 PR 5 plan v16 §2.7 (boards 8.3, 8.4): removing a member / excluding an own node, and the new-secrets checklist.
// The steps are the old console's _remove / _updates (nodes.dart:1348-1421, :1457-1499) unchanged:
// - 8.3 reads every own node of removeOwnNodes(target) that the phone has a record of, one at a time (P19, no skip),
//   then removeCheck; the tick text and its place before the button are Rust's (F32); the commit is an OfflineOp that
//   re-reads the record (R11) and, revoked at 60 s, is judged by the target being gone from the list (R12).
// - 8.4 lists every remaining member (netRecipients) with a bundle and a memory-only mark (T15), and every own node of
//   the record, readable or not (F-M1), each sent through sendNewKey (R17) and shown through RekeyResult (R14).
import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../say.dart' show SayLine, stripMarkers, tech;
import '../src/flows/offline_op.dart';
import '../src/flows/op_session.dart';
import '../src/flows/rekey_send.dart';
import '../src/nodelink/app_link.dart';
import '../src/rust/api/rekey.dart';
import 'code_view.dart';
import 'rekey_result.dart';
import 'settings_pages.dart' show opLine;
import 'team_deps.dart';
import 'team_pages.dart' show MembersPage, offlineLine;
import 'theme.dart';
import 'home_logic.dart' show nameIn;
import 'widgets.dart';

NetOpCalls removeCalls(RemoveOp op) =>
    NetOpCalls(signed: (d) => op.signed(der: d)!, netPersisted: () => op.netPersisted()!, persistFailed: (e) => op.persistFailed(error: e)!);

// ---- 8.3 移除確認 ---------------------------------------------------------------------------------------------------

class RemoveConfirmPage extends StatefulWidget {
  const RemoveConfirmPage(
      {super.key,
      required this.app,
      required this.netId,
      required this.person,
      required this.owner,
      required this.node,
      this.same = const []});
  final AppLink app;
  final String netId;
  final PersonView person;

  /// 8.3 step 4: the same-name lines of 8.2 shown again
  final List<String> same;

  /// the target: [owner] for a person (empty for an own node), [node] the dac hash of an own node (empty for a person)
  final String owner, node;

  @override
  State<RemoveConfirmPage> createState() => _RemoveConfirmPageState();
}

class _RemoveConfirmPageState extends State<RemoveConfirmPage> {
  Future<void>? _settled; // R12: a revoked removal; the page waits for it, then judges
  bool _unknown = false, _judging = false; // R12: judged and still not known / a judgement running
  final _reads = <NodeInfo>[];
  RemovePlanView? _plan;
  String _progress = '', _line = '';
  bool _ticked = false, _running = false;
  final _gone = Completer<void>();

  AppLink get a => widget.app;
  String get rel => 'net/${widget.netId}';

  @override
  void initState() {
    super.initState();
    _check();
  }

  @override
  void dispose() {
    if (!_gone.isCompleted) _gone.complete();
    super.dispose();
  }

  /// P19: every own node of the target's removal that the phone holds is read, one at a time; one that cannot be read
  /// is not checked (the old words). Each read is one OpSession with loginFor's own limit (no outer timer, S-m6).
  Future<void> _check() async {
    final (_, plain) = await teamDeps(a).readRecord(rel);
    final keys = await teamDeps(a).publicKeys();
    if (!mounted) return; // review A m2: never setState on a page that is gone
    if (plain == null) return setState(() => _line = '手機裡的網路紀錄打不開');
    final List<OwnNodeView> own;
    try {
      own = removeOwnNodes(recordPlain: plain, ownerPub: keys['owner']!, person: widget.owner, node: widget.node);
    } catch (e) {
      return setState(() => _line = '[REQ_FAIL] ${e is String ? e : tech(e.runtimeType)}');
    }
    final mine = (await teamDeps(a).nodeIds()).toSet();
    for (var i = 0; i < own.length; i++) {
      final o = own[i];
      var info = Uint8List(0);
      if (mine.contains(o.deviceId)) {
        final l4 = rustLast4(o.deviceId);
        if (mounted) setState(() => _progress = '正在讀第 ${i + 1} / ${own.length} 台：節點 …$l4 的網路版本（確認手機紀錄是最新的）…');
        final r = await OpSession.once(teamDeps(a).op, o.deviceId, '讀節點網路', (c, g) => c.info(), gone: () => _gone.isCompleted);
        final v = r.reply?.value;
        if (v is Uint8List) info = v;
        if (info.isEmpty && mounted) setState(() => _line = '$_line\n節點 …$l4 讀不到（不檢查這台）'.trim());
      }
      _reads.add(NodeInfo(dacHash: o.dacHash, info: info)); // every own node, read or not (AA-m4)
    }
    if (!mounted) return;
    try {
      final plan = removeCheck(
          recordPlain: plain, adminPub: keys['admin']!, ownerPub: keys['owner']!, person: widget.owner, node: widget.node, reads: _reads);
      setState(() {
        _plan = plan;
        _progress = '';
      });
    } catch (e) {
      setState(() => _line = '[REQ_FAIL] ${e is String ? e : tech(e.runtimeType)}');
    }
  }

  Future<void> _commit() async {
    if (_running) return; // review B m1: busy before the first await (a double tap starts nothing)
    setState(() => _running = true);
    final p = teamDeps(a).platform;
    final keys = await teamDeps(a).publicKeys();
    if (!mounted) return;
    final r = await OfflineOp.run(teamDeps(a).offline, '移除隊員', (l, w) async {
      final (gen, plain) = await p.readRecord(rel); // R11: the commit is a CAS from what is on disk now
      if (plain == null) throw '[REQ_FAIL] 手機裡的網路紀錄打不開';
      final (op, st) = RemoveOp.startRemove(
          recordPlain: plain,
          recordGen: gen,
          adminPub: keys['admin']!,
          ownerPub: keys['owner']!,
          person: widget.owner,
          node: widget.node,
          reads: _reads,
          ticked: _ticked);
      return runNetOp(st, removeCalls(op), l, w, p);
    });
    if (!mounted) return;
    if (r case OfflineUnknown(:final settled)) {
      // R12 (W-m12): PopScope released at once; the judgement runs when the work has really ended
      setState(() {
        _running = false;
        _settled = settled;
        _line = kUnknownWait;
      });
      unawaited(_judge());
      return;
    }
    if (r case OfflineDone(:final value) when value.detail.startsWith('[REKEY]')) return _removed();
    setState(() {
      _running = false;
      _line = r is OfflineDone<NetOpEnd> ? stripMarkers(r.value.detail) : offlineLine(r);
    });
  }

  Future<void> _removed() async {
    a.ticks.removed(widget.netId);
    if (mounted) {
      await Navigator.of(context)
          .pushReplacement(MaterialPageRoute(builder: (_) => RekeyPage(app: a, netId: widget.netId, removal: true)), result: true);
    }
  }

  /// R12 after a revoke, in a new lease: removed only when the target is gone from the record (the whole owner, AB-m3;
  /// an own node by its dac hash, AA-m5). Busy -> 「再查一次」; otherwise 「結果不明」 with the two ways on (T-m4).
  Future<void> _judge() async {
    final s = _settled;
    if (s == null || _judging) return;
    setState(() => _judging = true);
    final keys = await teamDeps(a).publicKeys();
    final p = teamDeps(a).platform;
    final r = await judgeAfterRevoke(teamDeps(a).offline, s, (l, w) async {
      final (_, plain) = await p.readRecord(rel);
      if (plain == null) return false;
      final people = netPeople(recordPlain: plain, ownerPub: keys['owner']!);
      if (widget.owner.isNotEmpty) return !people.any((x) => x.owner == widget.owner);
      return !people.any((x) => x.isSelf && x.nodes.any((n) => n.dacHash == widget.node));
    });
    if (!mounted) return;
    if (r case OfflineDone(value: true)) return _removed();
    setState(() {
      _judging = false;
      _unknown = r is! OfflineBusy;
      _line = _unknown ? '結果不明' : kUnknownWait;
    });
  }

  @override
  Widget build(BuildContext context) {
    final t = BatTheme.of(context);
    final plan = _plan;
    return PopScope(
      canPop: !_running,
      child: BatPage(title: widget.node.isEmpty ? nameIn('移除', widget.person.name, '') : '排除這台', body: [
        Text('指紋 ${widget.person.fpr}', style: TextStyle(fontSize: Fs.note, color: t.sub)),
        for (final s in widget.same) Text(s, key: const Key('remove-same'), style: TextStyle(fontSize: Fs.note, color: t.sub)),
        if (_progress.isNotEmpty) Text(_progress, key: const Key('remove-progress')),
        if (plan != null) SayLine(plan.text, key: const Key('remove-plan')),
        if (plan != null && plan.ok)
          CheckboxListTile(
              key: const Key('remove-tick'),
              value: _ticked,
              onChanged: _running ? null : (v) => setState(() => _ticked = v ?? false),
              title: Text(removeTickText())),
        if (_line.isNotEmpty) SayLine(_line, key: const Key('remove-line')),
      ], foot: [
        if (_settled != null && !_unknown)
          BatButton(kJudgeAgain, key: const Key('remove-judge'), onPressed: _judging ? null : _judge)
        else if (_unknown) ...[
          BatButton('到換密碼檢查清單',
              onPressed: () => Navigator.of(context)
                  .pushReplacement(MaterialPageRoute(builder: (_) => RekeyPage(app: a, netId: widget.netId)))),
          BatButton('到隊員名單確認',
              kind: BtnKind.secondary,
              onPressed: () => Navigator.of(context)
                  .pushReplacement(MaterialPageRoute(builder: (_) => MembersPage(app: a, netId: widget.netId)))),
        ],
        // F32: the tick before the button; Rust refuses without it. Not ok -> no button (the old 沒有開始).
        if (plan != null && plan.ok && _settled == null)
          BatButton('移除並換密碼', key: const Key('remove-go'), kind: BtnKind.danger, onPressed: _ticked && !_running ? _commit : null),
      ]),
    );
  }
}

// ---- 8.4 換密碼檢查清單 -----------------------------------------------------------------------------------------------

class RekeyPage extends StatefulWidget {
  const RekeyPage({super.key, required this.app, required this.netId, this.removal = false});
  final AppLink app;
  final String netId;

  /// true: entered from a removal (else from 「產生更新包」)
  final bool removal;

  @override
  State<RekeyPage> createState() => _RekeyPageState();
}

class _RekeyPageState extends State<RekeyPage> {
  VersionRead _ver = VersionRead.pending; // R19
  List<RecipientView> _people = const [];
  List<PersonNode> _own = const [];
  List<String> _phone = const [];
  final _bundles = <String, String>{}; // owner -> the bundle just made (memory, this page)
  final _sent = <String, RekeySent>{}; // dac hash -> the last send's result (memory, this page)
  String _line = '';
  bool _running = false;

  AppLink get a => widget.app;
  String get rel => 'net/${widget.netId}';

  @override
  void initState() {
    super.initState();
    a.ticks.addListener(_redraw);
    a.nets.addListener(_reread); // R19: NetIndex only as the trigger; the number is read from the record
    _load();
  }

  @override
  void dispose() {
    a.ticks.removeListener(_redraw);
    a.nets.removeListener(_reread);
    super.dispose();
  }

  void _redraw() => setState(() {});

  Future<void> _reread() async {
    if (!mounted) return;
    setState(() => _ver = VersionRead.pending);
    final v = await teamDeps(a).netVersion(widget.netId);
    if (mounted) setState(() => _ver = v);
  }

  Future<void> _load() async {
    unawaited(_reread());
    final (_, plain) = await teamDeps(a).readRecord(rel);
    final keys = await teamDeps(a).publicKeys();
    final phone = await teamDeps(a).nodeIds();
    if (!mounted) return;
    if (plain == null) return setState(() => _line = '手機裡的網路紀錄打不開');
    try {
      final people = netRecipients(recordPlain: plain, ownerPub: keys['owner']!);
      final self = netPeople(recordPlain: plain, ownerPub: keys['owner']!).where((p) => p.isSelf);
      setState(() {
        _people = people;
        _own = [for (final p in self) ...p.nodes];
        _phone = phone;
      });
    } catch (e) {
      setState(() => _line = '[REQ_FAIL] ${e is String ? e : tech(e.runtimeType)}');
    }
  }

  Future<void> _bundle(String owner) async {
    if (_running) return; // review B m1: busy before the first await (a double tap starts nothing)
    setState(() => _running = true);
    final p = teamDeps(a).platform;
    final keys = await teamDeps(a).publicKeys();
    if (!mounted) return;
    final r = await OfflineOp.run(teamDeps(a).offline, '產生更新包', (l, w) async {
      final (_, plain) = await p.readRecord(rel); // the record at the press (old _updates; R11)
      if (plain == null) throw '[REQ_FAIL] 手機裡的網路紀錄打不開';
      final (op, st) = RemoveOp.startBundle(recordPlain: plain, adminPub: keys['admin']!, ownerPub: keys['owner']!, person: owner);
      return runNetOp(st, removeCalls(op), l, w, p);
    });
    if (!mounted) return;
    setState(() {
      _running = false;
      if (r case OfflineDone(:final value) when value.hex.isNotEmpty) {
        _bundles[owner] = value.hex;
        _line = '';
      } else {
        _line = r is OfflineDone<NetOpEnd> ? stripMarkers(r.value.detail) : (r is OfflineUnknown ? '結果不明，請再按一次「複製更新包」' : offlineLine(r));
      }
    });
  }

  /// R17 with the node's dac hash and this network; same last four on the phone -> each candidate in turn (X-m1).
  Future<void> _send(PersonNode n) async {
    final cands = [for (final id in _phone) if (n.last4.isNotEmpty && sameLast4(rustLast4(id), n.last4)) id];
    setState(() => _running = true);
    RekeySent? res;
    for (final id in cands) {
      if (!mounted) break;
      final r = await sendNewKey(teamDeps(a).send(context), id, expectDac: n.dacHash, expectNet: widget.netId, gone: () => !mounted);
      // X-m1 / review A m3: the node itself answered -> done; a mismatch or an unreached one -> try the next; at the end
      // an unreached one is shown over a mismatch (it may be the right node, out of range)
      if (r.notReached == null && r.line != notThisNodeLine) {
        res = r;
        break;
      }
      if (res == null || r.notReached != null) res = r;
    }
    if (!mounted) return;
    setState(() {
      _running = false;
      if (res != null) _sent[n.dacHash] = res;
    });
  }

  @override
  Widget build(BuildContext context) {
    final t = BatTheme.of(context);
    final note = TextStyle(fontSize: Fs.note, height: 1.55, color: t.sub);
    return PopScope(
      canPop: !_running,
      child: BatPage(title: '換新的網路密碼', body: [
        Text(leaderVersionLine(_ver), key: const Key('net-version')),
        if (_line.isNotEmpty) SayLine(_line, key: const Key('rekey-page-line')),
        const BatLabel('1　先把更新包交給每位隊員'),
        Text('這些勾只是幫你記，app 不知道對方換好了沒', style: note),
        if (_people.isEmpty) Text('沒有需要更新包的隊員。', style: note),
        for (final p in _people)
          BatCard(children: [
            CheckboxListTile(
              key: Key('handed-${p.owner}'),
              value: a.ticks.handed(widget.netId, p.owner),
              onChanged: (v) => a.ticks.tick(widget.netId, p.owner, v ?? false), // T-R1: a mark, never a condition
              // #329 PR 7 (p1p2-check 8.4): the nodes on their own line as 「節點 …XXXX」 (upper case; after the Latin
              // fingerprint a 「…」 was drawn as three low dots)
              title: Text('${p.name}（${p.fpr}）'),
              subtitle: Text([
                if (p.nodes.isNotEmpty) '節點 ${p.nodes.map((n) => '…${n.toUpperCase()}').join('、')}',
                if (p.note.isNotEmpty) p.note,
                '已交出',
              ].join('\n')),
            ),
            if (_bundles[p.owner] case final hex?)
              Padding(padding: const EdgeInsets.all(12), child: CodeView(hex: hex, qr: false)) // T10: text only
            else
              BatRow(icon: Icons.content_copy, title: '複製更新包', enabled: !_running, onTap: () => _bundle(p.owner)),
          ]),
        const BatLabel('2　再換你自己的節點'),
        for (final n in _own) _ownRow(n, note),
      ]),
    );
  }

  Widget _ownRow(PersonNode n, TextStyle note) {
    final cands = [for (final id in _phone) if (n.last4.isNotEmpty && sameLast4(rustLast4(id), n.last4)) id];
    final sent = _sent[n.dacHash];
    return BatCard(children: [
      BatRow(
        key: Key('own-${n.dacHash}'),
        icon: Icons.router_outlined,
        title: n.last4.isEmpty ? '一台沒有編號紀錄的節點' : '節點 …${n.last4.toUpperCase()}${n.state == 'joining' ? '（加入中）' : ''}',
        sub: cands.isEmpty
            ? (n.last4.isEmpty
                ? '這支手機從這裡送不了：到那台的節點頁，按「更多」→「把新密碼送給節點」'
                : '這支手機從這裡送不了：手機沒有這台的紀錄。要換這台的密碼，得在擁有它的手機上做，或讓它離開網路')
            : null,
        right: cands.isEmpty ? null : '送出',
        enabled: cands.isNotEmpty && !_running,
        onTap: cands.isEmpty ? null : () => _send(n),
      ),
      if (sent != null)
        Padding(
          padding: const EdgeInsets.all(12),
          child: sent.notReached != null
              ? SayLine(opLine(sent.notReached!), style: note)
              : RekeyResult(end: sent.end, line: sent.line, member: false),
        ),
    ]);
  }
}
