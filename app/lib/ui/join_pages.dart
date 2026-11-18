// #329 PR 5 plan v16 §2.8 (boards 7.8–7.10, 8.5): the member's pages. The steps are the old console's (_takeInvite,
// _requestJoin, _showPendingBody, _takeApproval / _importApproval, _takeUpdate; nodes.dart:867-1037, :1503-1542)
// unchanged; every record write is an OfflineOp (R10, re-read under the lease R11), ECDH's z is the page's own copy and
// zeroed in `finally`. The member's join itself (R16) runs on the join wait page (net_pages.dart, member mode).
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../member_ui.dart' show SasShowView;
import '../say.dart' show SayLine, stripMarkers, tech;
import '../secure_screen.dart';
import '../src/flows/offline_op.dart';
import '../src/flows/op_session.dart';
import '../src/flows/owner_console.dart' show JoinreqOut;
import '../src/flows/rekey_send.dart';
import '../src/nodelink/app_link.dart';
import '../src/nodelink/lease.dart' show Lease;
import '../src/nodelink/record_writer.dart' show RecordWriter;
import '../src/rust/api/member.dart';
import '../src/rust/api/owner.dart' show OwnerKind, OwnerStep;
import '../src/rust/api/rekey.dart' show UpdateState, infoNetId, memberUpdateImport, memberUpdatePrepare, updateNetId;
import 'code_view.dart';
import 'home_logic.dart' show last4;
import 'home_page.dart' show nodeInfo;
import 'join_choice.dart' show NetMode, kNeedNewInvite;
import 'net_pages.dart' show NetFormPage, askYesNo;
import 'rekey_result.dart';
import 'settings_pages.dart' show opLine;
import 'team_deps.dart';
import 'team_pages.dart' show SasCheck, offlineLine;
import 'theme.dart';
import 'ui_state.dart';
import 'widgets.dart';

/// F37 / T-V1: a member name is at most 32 UTF-8 bytes (10 CJK characters fit, 11 do not).
const kNameMaxBytes = 32;
int nameBytes(String s) => utf8.encode(s).length;

/// T-V2: 「還可以輸入 N 個位元組（約 M 個中文字）」, M = N ÷ 3 (a CJK character is 3 bytes).
String nameLeft(String s) {
  final n = kNameMaxBytes - nameBytes(s);
  return n >= 0 ? '還可以輸入 $n 個位元組（約 ${n ~/ 3} 個中文字）' : '超過 ${-n} 個位元組，請改短';
}

/// R10: a PersistMnet / PersistNet step written under the lease (seal, then compare-and-swap).
Future<void> writeStep(OwnerStep st, OfflinePlatform p, Lease l, RecordWriter w) async {
  if (st.kind != OwnerKind.persistMnet && st.kind != OwnerKind.persistNet) throw st.detail; // the whole line (its technical part is shown under 技術資訊)
  final sealed = await p.seal(st.record, st.aad);
  await w.writeCas(l, st.rel, st.expectedGen, sealed);
}

// ---- 7.8 加入隊伍的網路 -----------------------------------------------------------------------------------------------

class JoinTeamPage extends StatefulWidget {
  const JoinTeamPage({super.key, required this.app, required this.ui});
  final AppLink app;
  final UiState ui;

  @override
  State<JoinTeamPage> createState() => _JoinTeamPageState();
}

class _JoinTeamPageState extends State<JoinTeamPage> {
  final _name = TextEditingController();
  List<String> _nodes = const [];
  String? _node;
  String _line = '';
  bool _running = false;

  AppLink get a => widget.app;

  @override
  void initState() {
    super.initState();
    a.invite.addListener(_redraw);
    _name.addListener(_redraw);
    teamDeps(a).nodeIds().then((ids) {
      if (!mounted) return;
      setState(() {
        _nodes = ids; // every node record: no state filter (O-m5; a re-invited node may still be in the old network)
        if (ids.length == 1) _node = ids.first;
      });
    });
  }

  @override
  void dispose() {
    a.invite.removeListener(_redraw);
    _name.dispose();
    super.dispose();
  }

  void _redraw() => setState(() {});

  void _took(String hex) {
    try {
      final v = parseInvite(hex: hex);
      a.invite.take(hex, v); // no record, no lease (F51)
      setState(() => _line = '收到網路「${v.netName}」的邀請');
    } catch (e) {
      setState(() => _line = '[REQ_FAIL] 邀請不能用：${e is String ? e : tech(e.runtimeType)}');
    }
  }

  Future<void> _request() async {
    final held = a.invite.held, node = _node;
    if (held == null || node == null) return;
    final name = _name.text.trim();
    setState(() {
      _running = true;
      _line = '';
    });
    final r = await OpSession.once(
      teamDeps(a).op,
      node,
      '申請加入',
      (c, g) => c.joinreq(inviteHex: held.$1, name: name, pendRel: 'mpend/${held.$2.netIdHex}'),
      gone: () => !mounted,
    );
    if (!mounted) return;
    final v = r.reply?.value;
    if (v is JoinreqOut) {
      a.invite.drop();
      await Navigator.of(context).pushReplacement(
        MaterialPageRoute(
          builder: (_) => MyRequestPage(app: a, ui: widget.ui, netId: held.$2.netIdHex, hex: v.hex, sas: v.sas, renewed: v.renewed),
        ),
      );
      return;
    }
    setState(() {
      _running = false;
      _line = opLine(r);
    });
  }

  @override
  Widget build(BuildContext context) {
    final t = BatTheme.of(context);
    final held = a.invite.held;
    final bytes = nameBytes(_name.text.trim());
    final nameOk = bytes > 0 && bytes <= kNameMaxBytes;
    return PopScope(
      canPop: !_running,
      child: BatPage(
        title: '加入隊伍的網路',
        body: [
          if (held == null)
            const Text('掃描隊長的邀請 QR，或貼上他用訊息傳來的文字。')
          else ...[
            Text('邀請：網路「${held.$2.netName}」', key: const Key('join-invite')),
            TextField(
              key: const Key('join-name'),
              controller: _name,
              decoration: const InputDecoration(labelText: '你的名字（必填，給隊長和隊員看）'),
            ),
            Text(
              nameLeft(_name.text.trim()),
              key: const Key('join-left'),
              style: TextStyle(fontSize: Fs.note, color: t.sub),
            ),
            const BatLabel('用哪一台節點申請'),
            RadioGroup<String>(
              groupValue: _node,
              onChanged: (v) {
                if (!_running) setState(() => _node = v);
              },
              child: BatCard(
                children: [
                  for (final id in _nodes)
                    RadioListTile<String>(
                      key: Key('join-node-$id'),
                      value: id,
                      enabled: !_running,
                      title: Text(widget.ui.nodes[id]?.nick ?? '節點 ${last4(id)}'),
                      subtitle: Text(_nodeLine(id)),
                      secondary: Icon(Icons.circle, size: 12, color: _look(id).ink(BatTheme.of(context))),
                    ),
                ],
              ),
            ),
          ],
          if (_line.isNotEmpty) SayLine(_line, key: const Key('join-line')),
        ],
        foot: [
          // #329 PR 6 (7.8): the main action at the bottom
          if (held == null) CodeInput(devTrust: a.devTrust, onText: _took, onError: (w) => setState(() => _line = w)),
          if (held != null)
            BatButton(
              Btn.requestJoin,
              key: const Key('join-go'),
              onPressed: nameOk && _node != null && !_running ? _request : null,
            ),
          if (held != null) BatButton('不用這份邀請', kind: BtnKind.text, onPressed: _running ? null : a.invite.drop),
        ],
      ),
    );
  }

  /// 讀到的照顏色顯示 (home_logic.dart:176)
  Look _look(String id) => switch (a.link.core.states[id]?.view) {
    'green' => Look.ok,
    'yellow' => Look.warn,
    'red' => Look.bad,
    _ => Look.unk,
  };

  String _nodeLine(String id) {
    if (!a.link.core.states.containsKey(id)) return '還沒讀到';
    final v = nodeInfo(a, id, widget.ui).view;
    if (v == null) return '還沒讀到';
    return v.netId.isEmpty ? '沒有在網路裡' : '已在網路「${v.netId.substring(0, v.netId.length.clamp(0, 8))}…」';
  }
}

// ---- 7.9 我的申請 -----------------------------------------------------------------------------------------------------

/// 7.9: a request renewed since the last time it was shown (Rust's 「[JOINREQ] 申請已換新…」).
const kRenewedNotice = '申請已換新，要重新核對確認碼';

class MyRequestPage extends StatefulWidget {
  const MyRequestPage(
      {super.key, required this.app, required this.ui, required this.netId, this.hex, this.sas, this.renewed = false});
  final AppLink app;
  final UiState ui;
  final String netId;
  final String? hex, sas;
  final bool renewed;

  @override
  State<MyRequestPage> createState() => _MyRequestPageState();
}

class _MyRequestPageState extends State<MyRequestPage> {
  Future<void>? _settled; // R12: a revoked 放棄申請
  bool _judging = false;
  String? _hex, _sas;
  String _line = '';
  bool _running = false;

  AppLink get a => widget.app;

  @override
  void initState() {
    super.initState();
    _hex = widget.hex;
    _sas = widget.sas;
    if (_hex == null) _show();
  }

  /// 再顯示申請 (nodes.dart:926-954): the request kept in mpend.
  Future<void> _show() async {
    final (_, plain) = await teamDeps(a).readRecord('mpend/${widget.netId}');
    if (!mounted) return;
    if (plain == null) return setState(() => _line = '[REQ_FAIL] 這支手機沒有這個網路的申請');
    try {
      final st = memberPendView(pendPlain: plain);
      setState(() {
        _hex = st.hex;
        _sas = st.sas;
      });
    } catch (e) {
      setState(() => _line = '[REQ_FAIL] ${e is String ? e : tech(e.runtimeType)}');
    }
  }

  Future<void> _drop() async {
    final yes = await askYesNo(context, '放棄申請？', '放棄後，隊長已經給或之後給的同意碼都不能再匯入，要重新申請。', '放棄申請', '取消');
    if (!yes || !mounted) return;
    setState(() => _running = true);
    final r = await OfflineOp.run(teamDeps(a).offline, '放棄申請', (l, w) => w.remove(l, 'mpend/${widget.netId}'));
    if (!mounted) return;
    if (r is OfflineDone) return Navigator.of(context).pop();
    if (r case OfflineUnknown(:final settled)) {
      setState(() {
        _running = false; // R12 (W-m12): the page can be left meanwhile
        _settled = settled;
        _line = kUnknownWait;
      });
      return _judgeDrop();
    }
    setState(() {
      _running = false;
      _line = offlineLine(r);
    });
  }

  /// R12: 放棄申請 is done when mpend is gone (read in a new lease after the work really ended).
  Future<void> _judgeDrop() async {
    final s = _settled;
    if (s == null || _judging) return;
    setState(() => _judging = true);
    final p = teamDeps(a).platform;
    final r = await judgeAfterRevoke(teamDeps(a).offline, s, (l, w) async => (await p.readRecord('mpend/${widget.netId}')).$2 == null);
    if (!mounted) return;
    setState(() {
      _judging = false;
      _line = switch (r) {
        OfflineDone(value: true) => '已經放棄',
        OfflineBusy() => kUnknownWait,
        _ => '結果不明',
      };
      if (r is! OfflineBusy) _settled = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final t = BatTheme.of(context);
    final hex = _hex, sas = _sas;
    return PopScope(
      canPop: !_running,
      child: BatPage(
        title: '我的申請',
        body: [
          const Text('先把申請交給隊長，再用電話把確認碼唸給他聽。'),
          // #329 PR 6 (7.9): the renewed notice as a status component, not orange text
          if (sas != null && widget.renewed) const BatBanner(key: Key('renewed'), look: Look.warn, title: kRenewedNotice),
          if (hex != null) CodeView(hex: hex),
          if (sas != null)
            SecureScreen(
              fallback: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SasShowView(sas: sas),
                  Text('這支手機無法防止截圖', style: TextStyle(color: Look.warn.ink(t))),
                ],
              ),
              child: SasShowView(sas: sas),
            ),
          // #329 PR 6 (7.9): one reminder — sasRule, in SasShowView
          if (_line.isNotEmpty) SayLine(_line, key: const Key('request-line')),
        ],
        foot: [
          BatButton(
            '我收到隊長的同意了',
            onPressed: _running
                ? null
                : () =>
                      Navigator.of(context)
                          .pushReplacement(MaterialPageRoute(builder: (_) => ImportApprovalPage(app: a, ui: widget.ui))),
          ),
          BatButton('放棄申請', kind: BtnKind.text, onPressed: _running ? null : _drop), // T-C3: one primary
          if (_settled != null)
            BatButton(kJudgeAgain, key: const Key('judge-again'), kind: BtnKind.secondary, onPressed: _judging ? null : _judgeDrop),
        ],
      ),
    );
  }
}

// ---- 7.10 匯入隊長的同意 ---------------------------------------------------------------------------------------------

class ImportApprovalPage extends StatefulWidget {
  const ImportApprovalPage({super.key, required this.app, required this.ui, this.onJoin});
  final AppLink app;
  final UiState ui;

  /// R16: 「讓這台加入隊長的網路」 after the import; null = 4.1 in member mode on the network just imported (AC-m3)
  final void Function(BuildContext context, String netId)? onJoin;

  @override
  State<ImportApprovalPage> createState() => _ImportApprovalPageState();
}

class _ImportApprovalPageState extends State<ImportApprovalPage> {
  bool _needInvite = false; // R12 Y-m9: the judgement says a new invite is needed
  Future<void>? _settled; // R12: a revoked import
  bool _judging = false;
  void _join(BuildContext c, String id) => Navigator.of(c).pushReplacement(MaterialPageRoute(
      builder: (_) => NetFormPage(app: widget.app, ui: widget.ui, mode: NetMode.member, memberNet: id)));

  String _line = '', _hex = '', _netId = '';
  ImportPrep? _prep;
  bool _replace = false, _running = false, _imported = false;
  int _tries = 0;

  AppLink get a => widget.app;

  /// _takeApproval (nodes.dart:957-999): read-only checks; the replace question; then the confirmation code.
  Future<void> _got(String hex) async {
    final String id;
    try {
      id = approvalNetId(hex: hex);
    } catch (e) {
      return setState(() => _line = '[REQ_FAIL] 同意碼不能用：${e is String ? e : tech(e.runtimeType)}');
    }
    final (pendGen, pend) = await teamDeps(a).readRecord('mpend/$id');
    final (_, mnet) = await teamDeps(a).readRecord('mnet/$id');
    if (!mounted) return; // review A m2
    ImportPrep prep;
    var replace = false;
    try {
      prep = memberImportPrepare(hex: hex, pendGen: pendGen, pendPlain: pend, mnetPlain: mnet, replace: false);
      if (prep.state == ImportState.replace) {
        final yes = await askYesNo(context, '要換成新的網路紀錄嗎？', prep.detail, '換成新的', '取消');
        if (!mounted) return;
        if (!yes) {
          return setState(() => _line = '[REQ_FAIL] 沒有匯入：保留舊紀錄');
        }
        replace = true;
        prep = memberImportPrepare(hex: hex, pendGen: pendGen, pendPlain: pend, mnetPlain: mnet, replace: true);
      }
    } catch (e) {
      return setState(() => _line = '[REQ_FAIL] 同意碼不能匯入：${e is String ? e : tech(e.runtimeType)}');
    }
    if (!mounted) return;
    if (prep.state != ImportState.ready || pend == null) return setState(() => _line = prep.detail);
    setState(() {
      _hex = hex;
      _netId = id;
      _prep = prep;
      _replace = replace;
      _line = '';
    });
  }

  /// _importApproval (nodes.dart:1001-1037) under the lease: ECDH, read again, write mnet, drop mpend; z zeroed.
  Future<void> _import(String sas) async {
    final prep = _prep!;
    final p = teamDeps(a).platform;
    final hex = _hex, id = _netId;
    setState(() => _running = true);
    final r = await OfflineOp.run(teamDeps(a).offline, '匯入同意', (l, w) async {
      Uint8List? z;
      try {
        z = ownCopy(await p.ecdh(prep.ephPub));
        final (pendGen, pend) = await p.readRecord('mpend/$id'); // R11: 7c checks the generation 7a saw
        final (mnetGen, mnet) = await p.readRecord('mnet/$id');
        if (pend == null) throw '找不到申請';
        final st = memberImportApproval(
          hex: hex,
          pendGen: pendGen,
          pendPlain: pend,
          expectedPendGen: prep.pendGen,
          mnetPlain: mnet,
          mnetGen: mnetGen,
          z: z,
          confirmedSas: sas,
          replace: _replace,
        );
        await writeStep(st, p, l, w);
        try {
          await w.remove(l, 'mpend/$id'); // a failed removal is harmless (the old code's rule)
        } catch (_) {}
        return st.detail;
      } finally {
        zero(z);
      }
    });
    if (!mounted) return;
    if (r case OfflineUnknown(:final settled)) {
      setState(() {
        _running = false; // R12 (W-m12)
        _settled = settled;
        _line = kUnknownWait;
      });
      return _judgeImport();
    }
    setState(() {
      _running = false;
      _tries++;
      if (r case OfflineDone(:final value)) {
        _imported = true;
        _line = value;
      } else {
        _line = '[REQ_FAIL] 沒有匯入：${offlineLine(r)}';
      }
    });
  }

  /// R12 (W-m1 / Y-m9): the same approval prepared again WITHOUT the request (with it, prepare would bind and say Ready):
  /// AlreadyImported -> 「已經匯入」, and a leftover mpend is removed in the same new lease (or the home todo stays);
  /// NeedsNewInvite -> 「結果不明」 and why; anything else -> 「結果不明」.
  Future<void> _judgeImport() async {
    final s = _settled;
    if (s == null || _judging) return;
    setState(() => _judging = true);
    final p = teamDeps(a).platform;
    final hex = _hex, id = _netId;
    final r = await judgeAfterRevoke(teamDeps(a).offline, s, (l, w) async {
      final (_, pend) = await p.readRecord('mpend/$id');
      final (_, mnet) = await p.readRecord('mnet/$id');
      final prep = memberImportPrepare(hex: hex, pendGen: BigInt.zero, pendPlain: null, mnetPlain: mnet, replace: false);
      if (prep.state == ImportState.alreadyImported && pend != null) await w.remove(l, 'mpend/$id');
      return prep.state;
    });
    if (!mounted) return;
    setState(() {
      _judging = false;
      if (r is! OfflineBusy) _settled = null;
      switch (r) {
        case OfflineDone(value: ImportState.alreadyImported):
          _imported = true;
          _line = '已經匯入';
        case OfflineDone(value: ImportState.needsNewInvite):
          _line = '結果不明\n$kNeedNewInvite';
          _needInvite = true;
          _prep = null; // review B m3 / C m6: not a dead end: paste again or get a new invite
        case OfflineBusy():
          _line = kUnknownWait;
        default:
          _line = '結果不明';
          _prep = null; // the approval can be pasted again (the judgement re-runs the old checks)
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final prep = _prep;
    return PopScope(
      canPop: !_running,
      child: BatPage(
        title: '匯入隊長的同意',
        body: [
          if (prep == null && !_imported)
            CodeInput(devTrust: a.devTrust, onText: _got, onError: (w) => setState(() => _line = w)),
          if (prep != null && !_imported) ...[
            const Text('核對隊長的同意'),
            SasCheck(
              key: ValueKey(_tries),
              sas: prep.sas,
              confirmLabel: '確認碼相同，匯入',
              onConfirm: () => _import(prep.sas),
            ),
          ],
          if (_line.isNotEmpty) SayLine(_line, key: const Key('import-line')),
        ],
        foot: [
          if (_settled != null && !_imported)
            BatButton(kJudgeAgain, key: const Key('judge-again'), onPressed: _judging ? null : _judgeImport),
          if (_needInvite && !_imported)
            BatButton(
              '收隊長的邀請',
              key: const Key('import-invite'),
              kind: BtnKind.secondary,
              onPressed: () => Navigator.of(context)
                  .pushReplacement(MaterialPageRoute(builder: (_) => JoinTeamPage(app: a, ui: widget.ui))),
            ),
          if (_imported)
            BatButton(
              '讓這台加入隊長的網路',
              key: const Key('import-join'),
              onPressed: () => (widget.onJoin ?? _join)(context, _netId),
            ),
        ],
      ),
    );
  }
}

// ---- 8.5 收到新密碼 -----------------------------------------------------------------------------------------------------

/// m6 / S-m8: 8.5's failure line; a record changed elsewhere gets the old console's 「請隊長再複製一次」 (nodes.dart:1534).
String updateFailLine(OfflineReply r) => switch (r) {
      OfflineFailed(:final line) when line == kStaleRecordLine => '請隊長再複製一次你的包，再貼上',
      _ => offlineLine(r),
    };

/// 8.5 (AA-m7): the member's own question before a send; only on this page (R17's `confirm` keeps the old behaviour).
const kMemberSendAsk = '隊長說大家都拿到更新包了嗎？太早送，你的節點會和還沒換的人斷線';

/// 8.5 / V-m8: a node of this phone as read for the list: its network matches, or it could not be read.
enum UpdateNode { inNet, unread }

class UpdateImportPage extends StatefulWidget {
  const UpdateImportPage({super.key, required this.app, required this.ui});
  final AppLink app;
  final UiState ui;

  @override
  State<UpdateImportPage> createState() => _UpdateImportPageState();
}

class _UpdateImportPageState extends State<UpdateImportPage> {
  Future<void>? _settled; // R12: a revoked import
  bool _judging = false;
  String _hex = '';
  VersionRead? _ver; // R19: null = which network is not known yet
  String _line = '', _netId = '';
  bool _running = false, _imported = false, _listing = false;
  final _nodes = <String, UpdateNode>{};
  final _sent = <String, RekeySent>{};

  AppLink get a => widget.app;

  @override
  void initState() {
    super.initState();
    final ids = a.nets.now.mnetIds;
    if (ids.length == 1) _readVersion('mnet/${ids.single}');
  }

  Future<void> _readVersion(String rel) async {
    setState(() => _ver = VersionRead.pending);
    final v = await teamDeps(a).mnetVersion(rel);
    if (mounted) setState(() => _ver = v);
  }

  /// _takeUpdate (nodes.dart:1503-1542): ECDH only on Advance; the second part checks the generation the first saw.
  Future<void> _got(String hex) async {
    final String id;
    try {
      id = updateNetId(hex: hex);
    } catch (e) {
      return setState(() => _line = '[REQ_FAIL] 更新包不能用：${e is String ? e : tech(e.runtimeType)}');
    }
    if (_running) return; // review B m1: busy before the first await
    setState(() => _running = true);
    final d = teamDeps(a);
    final keys = await d.publicKeys();
    final nodes = <Uint8List>[]; // rule 4: the own nodes = every node record of this phone (A-m12)
    for (final n in await d.nodeIds()) {
      final (_, p) = await d.readRecord('node/$n');
      if (p != null) nodes.add(p);
    }
    final p = d.platform;
    if (!mounted) return;
    final r = await OfflineOp.run(d.offline, '匯入新密碼', (l, w) async {
      Uint8List? z;
      try {
        final (mnetGen, mnet) = await p.readRecord('mnet/$id');
        final prep = memberUpdatePrepare(
          hex: hex,
          mnetPlain: mnet,
          mnetGen: mnetGen,
          nodeRecords: nodes,
          ownerEncPub: keys['ownerEnc']!,
        );
        // device session 2026-11-17: each Rust line loses its log marker before they are joined (「[UPDATE] 已收到新密碼」
        // showed on the second line; SayLine strips them line by line)
        if (prep.state == UpdateState.alreadyImported) return '這份更新包你之前匯入過了，可能不是最新的（${stripMarkers(prep.detail)}）';
        if (prep.state == UpdateState.advance) z = ownCopy(await p.ecdh(prep.ephPub)); // only on Advance (S-m8)
        final (gen2, mnet2) = await p.readRecord('mnet/$id');
        final st = memberUpdateImport(
          hex: hex,
          mnetPlain: mnet2,
          mnetGen: gen2,
          expectedGen: prep.mnetGen,
          nodeRecords: nodes,
          ownerEncPub: keys['ownerEnc']!,
          z: z ?? Uint8List(0),
        );
        await writeStep(st, p, l, w);
        return '${stripMarkers(prep.detail)}\n${stripMarkers(st.detail)}'; // Rust's 「更新到第 N 版」 shown as is (T-M1)
      } finally {
        zero(z);
      }
    });
    if (!mounted) return;
    if (r case OfflineUnknown(:final settled)) {
      setState(() {
        _running = false; // R12 (W-m12)
        _settled = settled;
        _hex = hex;
        _netId = id;
        _line = kUnknownWait;
      });
      return _judgeUpdate();
    }
    setState(() {
      _running = false;
      if (r case OfflineDone(:final value)) {
        _imported = true; // also after 「已經匯入過」: the phone holds that version; sending it is what it sends anyway
        _netId = id;
        _line = value;
      } else {
        _line = '[REQ_FAIL] 沒有匯入：${updateFailLine(r)}';
      }
    });
    if (_imported) unawaited(_readVersion('mnet/$_netId')); // Z-m4: read again after the import
    if (_imported) await _list();
  }

  /// R12: the same bundle prepared again in a new lease: AlreadyImported -> 「已經匯入」 (then the nodes are listed);
  /// otherwise 「結果不明」.
  Future<void> _judgeUpdate() async {
    final s = _settled;
    if (s == null || _judging) return;
    setState(() => _judging = true);
    final d = teamDeps(a);
    final keys = await d.publicKeys();
    final nodes = <Uint8List>[];
    for (final n in await d.nodeIds()) {
      final (_, p) = await d.readRecord('node/$n');
      if (p != null) nodes.add(p);
    }
    final p = d.platform;
    final hex = _hex, id = _netId;
    final r = await judgeAfterRevoke(d.offline, s, (l, w) async {
      final (gen, mnet) = await p.readRecord('mnet/$id');
      return memberUpdatePrepare(hex: hex, mnetPlain: mnet, mnetGen: gen, nodeRecords: nodes, ownerEncPub: keys['ownerEnc']!)
          .state;
    });
    if (!mounted) return;
    final done = r is OfflineDone<UpdateState> && r.value == UpdateState.alreadyImported;
    setState(() {
      _judging = false;
      if (r is! OfflineBusy) _settled = null;
      _imported = done;
      _line = done ? '已經匯入' : (r is OfflineBusy ? kUnknownWait : '結果不明');
    });
    if (done) {
      unawaited(_readVersion('mnet/$id'));
      await _list();
    }
  }

  /// V-m8: every node record of this phone, one info read each (in turn: one session at a time); this network's
  /// nodes and the unread ones are listed, the others' network is not this one.
  Future<void> _list() async {
    final d = teamDeps(a);
    setState(() => _listing = true);
    for (final id in await d.nodeIds()) {
      if (!mounted) return;
      final r = await OpSession.once(d.op, id, '讀節點網路', (c, g) => c.info(), gone: () => !mounted);
      final info = r.reply?.value;
      final net = info is List<int> ? infoNetId(info: info) : null;
      if (!mounted) return;
      setState(() {
        if (net == null) {
          _nodes[id] = UpdateNode.unread;
        } else if (net == _netId) {
          _nodes[id] = UpdateNode.inNet;
        }
      });
    }
    if (mounted) setState(() => _listing = false);
  }

  Future<void> _send(String id) async {
    final yes = await askYesNo(context, '把新密碼送給這台節點？', kMemberSendAsk, '送出', '取消');
    if (!yes || !mounted) return;
    setState(() => _running = true);
    final r = await sendNewKey(teamDeps(a).send(context), id, expectNet: _netId, gone: () => !mounted);
    if (!mounted) return;
    setState(() {
      _running = false;
      _sent[id] = r;
    });
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !_running,
    child: BatPage(
      title: '收到新密碼',
      body: [
        if (_ver case final v?) Text(memberVersionLine(v), key: const Key('update-version')),
        if (!_imported) ...[
          const Text('貼上隊長給你的更新包。'),
          CodeInput(devTrust: a.devTrust, scan: false, onText: _got, onError: (w) => setState(() => _line = w)),
        ],
        if (_line.isNotEmpty) SayLine(_line, key: const Key('update-line')),
        if (_settled != null)
          BatButton(kJudgeAgain, key: const Key('judge-again'), onPressed: _judging ? null : _judgeUpdate),
        if (_imported) ...[
          const BatLabel('把新密碼送到你的節點'),
          if (_listing) const Text('正在讀每台節點在哪個網路…'),
          if (!_listing && _nodes.isEmpty) const Text('沒有找到這個網路的節點'),
          for (final MapEntry(key: id, value: kind) in _nodes.entries)
            BatCard(
              key: Key('update-node-$id'),
              children: [
                BatRow(
                  icon: Icons.router_outlined,
                  title: widget.ui.nodes[id]?.nick ?? '節點 ${last4(id)}',
                  sub: kind == UpdateNode.inNet ? '這個網路的節點' : '讀不到，不知道是不是這個網路',
                  right: '送出',
                  enabled: !_running,
                  onTap: () => _send(id),
                ),
                if (_sent[id] case final s?)
                  Padding(
                    padding: const EdgeInsets.all(12),
                    child: s.notReached != null
                        ? SayLine(opLine(s.notReached!))
                        : RekeyResult(end: s.end, line: s.line, member: true, version: s.version ?? _ver),
                  ),
              ],
            ),
        ],
      ],
    ),
  );
}
