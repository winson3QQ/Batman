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

import '../say.dart' show screenText;
import '../src/flows/offline_op.dart';
import '../src/flows/op_session.dart';
import '../src/flows/rekey_send.dart';
import '../src/nodelink/app_link.dart';
import '../src/rust/api/rekey.dart';
import 'code_view.dart';
import 'rekey_result.dart';
import 'settings_pages.dart' show opLine;
import 'team_deps.dart';
import 'team_pages.dart' show offlineLine;
import 'theme.dart';
import 'widgets.dart';

NetOpCalls removeCalls(RemoveOp op) =>
    NetOpCalls(signed: (d) => op.signed(der: d)!, netPersisted: () => op.netPersisted()!, persistFailed: (e) => op.persistFailed(error: e)!);

// ---- 8.3 移除確認 ---------------------------------------------------------------------------------------------------

class RemoveConfirmPage extends StatefulWidget {
  const RemoveConfirmPage(
      {super.key, required this.app, required this.netId, required this.person, required this.owner, required this.node});
  final AppLink app;
  final String netId;
  final PersonView person;

  /// the target: [owner] for a person (empty for an own node), [node] the dac hash of an own node (empty for a person)
  final String owner, node;

  @override
  State<RemoveConfirmPage> createState() => _RemoveConfirmPageState();
}

class _RemoveConfirmPageState extends State<RemoveConfirmPage> {
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
    if (plain == null || !mounted) return setState(() => _line = '手機裡的網路紀錄打不開');
    final List<OwnNodeView> own;
    try {
      own = removeOwnNodes(recordPlain: plain, ownerPub: keys['owner']!, person: widget.owner, node: widget.node);
    } catch (e) {
      return setState(() => _line = '[REQ_FAIL] ${e is String ? e : e.runtimeType}');
    }
    final mine = (await teamDeps(a).nodeIds()).toSet();
    for (var i = 0; i < own.length; i++) {
      final o = own[i];
      var info = Uint8List(0);
      if (mine.contains(o.deviceId)) {
        final l4 = rustLast4(o.deviceId);
        if (mounted) setState(() => _progress = '正在讀第 ${i + 1} / ${own.length} 台：節點 …$l4 的網路版本（確認手機紀錄是最新的）…');
        final r = await OpSession.once(teamDeps(a).op, o.deviceId, '移除隊員', (c, g) => c.info(), gone: () => _gone.isCompleted);
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
      setState(() => _line = '[REQ_FAIL] ${e is String ? e : e.runtimeType}');
    }
  }

  Future<void> _commit() async {
    final p = teamDeps(a).platform;
    final keys = await teamDeps(a).publicKeys();
    setState(() => _running = true);
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
    final done = switch (r) {
      OfflineDone(:final value) => value.detail.startsWith('[REKEY]'),
      OfflineUnknown(:final settled) => await _judge(settled), // R12
      _ => false,
    };
    if (done) {
      a.ticks.removed(widget.netId);
      if (mounted) {
        await Navigator.of(context)
            .pushReplacement(MaterialPageRoute(builder: (_) => RekeyPage(app: a, netId: widget.netId, removal: true)));
      }
      return;
    }
    if (!mounted) return;
    setState(() {
      _running = false;
      _line = r is OfflineDone<NetOpEnd> ? screenText(r.value.detail) : (r is OfflineUnknown ? '結果不明，請到隊員名單確認' : offlineLine(r));
    });
  }

  /// R12 after a revoke: removed only when the target is gone from the record (the whole owner, AB-m3; an own node by
  /// its dac hash, AA-m5). Read after the work really ended (L-m2).
  Future<bool> _judge(Future<void> settled) async {
    await settled;
    final (_, plain) = await teamDeps(a).readRecord(rel);
    final keys = await teamDeps(a).publicKeys();
    if (plain == null) return false;
    try {
      final people = netPeople(recordPlain: plain, ownerPub: keys['owner']!);
      if (widget.owner.isNotEmpty) return !people.any((p) => p.owner == widget.owner);
      return !people.any((p) => p.isSelf && p.nodes.any((n) => n.dacHash == widget.node));
    } catch (_) {
      return false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = BatTheme.of(context);
    final plan = _plan;
    return PopScope(
      canPop: !_running,
      child: BatPage(title: widget.node.isEmpty ? '移除${widget.person.name}' : '排除這台', body: [
        Text('指紋 ${widget.person.fpr}', style: TextStyle(fontSize: Fs.note, color: t.sub)),
        if (_progress.isNotEmpty) Text(_progress, key: const Key('remove-progress')),
        if (plan != null) Text(screenText(plan.text), key: const Key('remove-plan')),
        if (plan != null && plan.ok)
          CheckboxListTile(
              key: const Key('remove-tick'),
              value: _ticked,
              onChanged: _running ? null : (v) => setState(() => _ticked = v ?? false),
              title: Text(removeTickText())),
        if (_line.isNotEmpty) Text(screenText(_line), key: const Key('remove-line')),
      ], foot: [
        // F32: the tick before the button; Rust refuses without it. Not ok -> no button (the old 沒有開始).
        if (plan != null && plan.ok)
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
    _load();
  }

  @override
  void dispose() {
    a.ticks.removeListener(_redraw);
    super.dispose();
  }

  void _redraw() => setState(() {});

  Future<void> _load() async {
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
      setState(() => _line = '[REQ_FAIL] ${e is String ? e : e.runtimeType}');
    }
  }

  Future<void> _bundle(String owner) async {
    final p = teamDeps(a).platform;
    final keys = await teamDeps(a).publicKeys();
    setState(() => _running = true);
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
        _line = r is OfflineDone<NetOpEnd> ? screenText(r.value.detail) : (r is OfflineUnknown ? '結果不明，請再按一次「複製更新包」' : offlineLine(r));
      }
    });
  }

  /// R17 with the node's dac hash and this network; same last four on the phone -> each candidate in turn (X-m1).
  Future<void> _send(PersonNode n) async {
    final cands = [for (final id in _phone) if (n.last4.isNotEmpty && sameLast4(rustLast4(id), n.last4)) id];
    setState(() => _running = true);
    RekeySent? res;
    for (final id in cands) {
      res = await sendNewKey(teamDeps(a).send(context), id, expectDac: n.dacHash, expectNet: widget.netId, gone: () => !mounted);
      if (res.line != notThisNodeLine) break;
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
        if (_line.isNotEmpty) Text(_line, key: const Key('rekey-page-line')),
        const BatLabel('1　先把更新包交給每位隊員'),
        Text('這些勾只是幫你記，app 不知道對方換好了沒', style: note),
        if (_people.isEmpty) Text('沒有需要更新包的隊員。', style: note),
        for (final p in _people)
          BatCard(children: [
            CheckboxListTile(
              key: Key('handed-${p.owner}'),
              value: a.ticks.handed(widget.netId, p.owner),
              onChanged: (v) => a.ticks.tick(widget.netId, p.owner, v ?? false), // T-R1: a mark, never a condition
              title: Text('${p.name}（${p.fpr}）…${p.nodes.join('、…')}'),
              subtitle: p.note.isEmpty ? const Text('已交出') : Text('${p.note}\n已交出'),
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
        title: n.last4.isEmpty ? '一台沒有編號紀錄的節點' : '節點 …${n.last4}${n.state == 'joining' ? '（加入中）' : ''}',
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
              ? Text(opLine(sent.notReached!), style: note)
              : RekeyResult(end: sent.end, line: sent.line, member: false),
        ),
    ]);
  }
}
