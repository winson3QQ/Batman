// #329 PR 6 (plan D2 / D3 / D4 / D4a): the developer options' pages that take over the old console's last uses —
// 「SSH 金鑰」, 「查看節點設定」, 「文字紀錄」 and 「忘記加入中的節點」. devTrust builds only (the settings page shows the
// entries only there; each page refuses to do anything in another build too). The node operations are one
// OpSession.once each (the session lease only while it runs, login under it: as 5.6); the forget is its own short
// session lease written through RecordWriter (as 4.1's 放棄這次加入).
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../member_ui.dart' show forgetNotice;
import '../say.dart' show SayLine, TechFold, logText, screenText, stripMarkers, tech, techText;
import '../src/flows/net_index.dart' show JoinTodo;
import '../src/flows/op_session.dart';
import '../src/flows/owner_console.dart';
import '../src/nodelink/app_link.dart';
import '../src/nodelink/lease.dart' show LeaseKind;
import '../src/nodelink/node_link.dart' show NodeLink;
import '../src/rust/api/rekey.dart' show netPeople;
import '../src/rust/api/ssh.dart' show sshFingerprint, sshLineProblem;
import 'home_logic.dart' show last4;
import 'remove_pages.dart' show RemoveConfirmPage;
import 'settings_pages.dart' show opDeps, opLine;
import 'team_deps.dart';
import 'team_pages.dart' show sameNameLines;
import 'theme.dart';
import 'ui_state.dart';
import 'widgets.dart';

/// The phone's only node, or null when it has none or several (the dev pages pick it in advance).
String? onlyNode(AppLink app) {
  final ids = app.link.core.states.keys;
  return ids.length == 1 ? ids.first : null;
}

/// One of this phone's nodes, picked first on a dev page: nickname (or 「節點 XXXX」) and last four.
class NodePickCard extends StatelessWidget {
  const NodePickCard({super.key, required this.app, required this.ui, required this.picked, required this.onPick, this.enabled = true});
  final AppLink app;
  final UiState ui;
  final String? picked;
  final void Function(String id) onPick;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final t = BatTheme.of(context);
    final ids = app.link.core.states.keys.toList()..sort();
    if (ids.isEmpty) return Text('這支手機還沒有節點。', style: TextStyle(fontSize: Fs.body, color: t.sub));
    return BatCard(children: [
      for (final id in ids)
        BatRow(
          key: Key('pick-$id'),
          icon: id == picked ? Icons.radio_button_checked : Icons.radio_button_unchecked,
          title: ui.nodes[id]?.nick ?? '節點 ${last4(id)}',
          sub: '後四碼 ${last4(id)}',
          enabled: enabled,
          onTap: () => onPick(id),
        ),
    ]);
  }
}

// ---- D2 SSH 金鑰 -----------------------------------------------------------------------------------------------------

/// The node takes 0–8 lines (node.go:839-842).
const sshMaxLines = 8;

/// The text field's lines as they will be sent: each line's one trailing CR removed (a clipboard often carries CRLF),
/// blank lines dropped. A CR left inside a line makes that line fail the check (it is not removed).
List<String> sshLines(String text) => [
      for (final l in text.split('\n'))
        if (l.trim().isNotEmpty) l.endsWith('\r') ? l.substring(0, l.length - 1) : l
    ];

/// One line's check: the node's rule and the fingerprint (Rust), or why not.
class SshLineCheck {
  const SshLineCheck(this.line, {this.fingerprint, this.problem});
  final String line;
  final String? fingerprint, problem;
  bool get ok => problem == null && fingerprint != null;
}

SshLineCheck checkSshLine(String line) {
  final p = sshLineProblem(line: line);
  if (p != null) return SshLineCheck(line, problem: p);
  final f = sshFingerprint(line: line);
  return f == null ? SshLineCheck(line, problem: '金鑰內容解不開') : SshLineCheck(line, fingerprint: f);
}

const sshReplaceNote = '送出的這一組會取代之前由 app 加入的全部金鑰；節點上原本就有、不是 app 加的不受影響。'
    '例外：一把金鑰如果本來就在節點上、又由 app 送過，之後任何一次取代（不只送出空的一組）都會把它一起移除。'
    '要保留的金鑰（例如 lab key）請每一次都放進這一組。';
const sshSetButton = '設定 SSH 金鑰（取代之前由 app 加入的）';
const sshRemoveButton = '移除 app 加入的全部 SSH 金鑰';
const sshDoneLine = 'SSH 金鑰已設定';
const sshRemovedLine = '已移除 app 加入的全部 SSH 金鑰';

class SshKeysPage extends StatefulWidget {
  const SshKeysPage({super.key, required this.app, required this.ui, this.deps});
  final AppLink app;
  final UiState ui;
  final OpDeps? deps; // tests

  @override
  State<SshKeysPage> createState() => _SshKeysPageState();
}

class _SshKeysPageState extends State<SshKeysPage> {
  late final OpDeps _d = widget.deps ?? opDeps(widget.app);
  final _text = TextEditingController();
  // S20 device session 2026-11-18: with one node the button did nothing until the node row was tapped; picked already
  late String? _id = onlyNode(widget.app);
  bool _sending = false;
  String _line = '';

  @override
  void initState() {
    super.initState();
    _text.addListener(() => mounted ? setState(() {}) : null);
  }

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  Future<void> _send(List<String> lines) async {
    final id = _id;
    if (id == null || !widget.app.devTrust) return;
    if (lines.isEmpty) {
      final t = BatTheme.of(context);
      final yes = await showDialog<bool>(
          context: context,
          builder: (c) => AlertDialog(
                backgroundColor: t.surf,
                title: Text('移除 app 加入的全部 SSH 金鑰？', style: TextStyle(fontSize: Fs.title, fontWeight: FontWeight.w700, color: t.ink)),
                content: Text('之後就不能用那些金鑰登入這台節點。如果這把金鑰本來就在節點上（不是 app 加的），也會被一起移除。',
                    style: TextStyle(fontSize: Fs.body, height: 1.6, color: t.ink)),
                actions: [
                  Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                    BatButton(Btn.remove, key: const Key('ssh-remove-yes'), kind: BtnKind.danger, onPressed: () => Navigator.pop(c, true)),
                    const SizedBox(height: 6),
                    BatButton(Btn.cancel, kind: BtnKind.text, onPressed: () => Navigator.pop(c, false)),
                  ]),
                ],
              ));
      if (yes != true || !mounted) return;
    }
    setState(() {
      _sending = true;
      _line = '';
    });
    final r = await OpSession.once(_d, id, 'SSH 金鑰', (c, gone) => c.sshKeys(lines), gone: () => !mounted);
    if (!mounted) return;
    final reply = r.reply;
    final ok = r.end == OpEnd.done && reply != null && reply.kind == ReplyKind.answer && reply.text.startsWith('[SSH_DONE]');
    setState(() {
      _sending = false;
      _line = ok
          ? (lines.isEmpty ? sshRemovedLine : sshDoneLine)
          : '${opLine(r)}${r.end == OpEnd.failed || reply?.kind == ReplyKind.unclear ? '\n節點可能已經套用了；查看節點設定看不到 SSH 金鑰，只能從節點那邊確認。' : ''}';
    });
  }

  @override
  Widget build(BuildContext context) {
    final t = BatTheme.of(context);
    final note = TextStyle(fontSize: Fs.note, height: 1.55, color: t.sub);
    final lines = sshLines(_text.text);
    final checks = [for (final l in lines) checkSshLine(l)];
    final tooMany = lines.length > sshMaxLines;
    final allOk = !tooMany && checks.every((c) => c.ok);
    final can = widget.app.devTrust && _id != null && !_sending && allOk;
    return PopScope(
      canPop: !_sending,
      child: BatPage(title: 'SSH 金鑰', body: [
        Text('選一台節點，貼上要給它的 SSH 公鑰（ssh-ed25519，一行一把，最多 $sshMaxLines 把）。', style: note),
        NodePickCard(app: widget.app, ui: widget.ui, picked: _id, enabled: !_sending, onPick: (id) => setState(() => _id = id)),
        TextField(
          key: const Key('ssh-lines'),
          controller: _text,
          enabled: !_sending,
          minLines: 3,
          maxLines: 10,
          autocorrect: false,
          enableSuggestions: false,
          style: const TextStyle(fontFamily: 'monospace', fontSize: Fs.meta),
          decoration: const InputDecoration(border: OutlineInputBorder(), labelText: '公鑰（一行一把）'),
        ),
        Text(sshReplaceNote, key: const Key('ssh-replace-note'), style: TextStyle(fontSize: Fs.body, height: 1.6, color: t.ink)),
        if (tooMany) Text('最多 $sshMaxLines 行（現在 ${lines.length} 行）', key: const Key('ssh-too-many'), style: TextStyle(fontSize: Fs.body, color: t.badInk)),
        if (lines.isNotEmpty)
          BatCard(children: [
            for (var i = 0; i < checks.length; i++)
              BatRow(
                key: Key('ssh-check-$i'),
                icon: checks[i].ok ? Icons.check_circle_outline : Icons.error_outline,
                title: checks[i].ok ? '第 ${i + 1} 行：${checks[i].fingerprint}' : '第 ${i + 1} 行不合格：${checks[i].problem}',
                sub: checks[i].ok ? '請和你手上的公鑰指紋核對（ssh-keygen -lf）' : null,
              ),
          ])
        else
          Text('沒有任何一行：送出 = 移除 app 加入的全部 SSH 金鑰。', key: const Key('ssh-empty-note'), style: note),
        if (_line.isNotEmpty) SayLine(_line, key: const Key('ssh-line'), style: TextStyle(fontSize: Fs.body, height: 1.6, color: t.ink)),
      ], foot: [
        BatButton(
          _sending ? '正在送出…' : (lines.isEmpty ? sshRemoveButton : sshSetButton),
          key: const Key('ssh-send'),
          kind: lines.isEmpty ? BtnKind.danger : BtnKind.primary,
          onPressed: can ? () => _send(lines) : null,
        ),
      ]),
    );
  }
}

// ---- D3 查看節點設定 -------------------------------------------------------------------------------------------------

class NodeSettingsPage extends StatefulWidget {
  const NodeSettingsPage({super.key, required this.app, required this.ui, this.deps});
  final AppLink app;
  final UiState ui;
  final OpDeps? deps;

  @override
  State<NodeSettingsPage> createState() => _NodeSettingsPageState();
}

class _NodeSettingsPageState extends State<NodeSettingsPage> {
  late final OpDeps _d = widget.deps ?? opDeps(widget.app);
  late String? _id = onlyNode(widget.app); // device 2026-11-18: one node -> picked already
  bool _reading = false;
  String _text = '';
  bool _ok = false;

  Future<void> _read() async {
    final id = _id;
    if (id == null || !widget.app.devTrust) return;
    setState(() {
      _reading = true;
      _text = '';
    });
    final r = await OpSession.once(_d, id, '查看節點設定', (c, gone) => c.settings(), gone: () => !mounted);
    if (!mounted) return;
    final reply = r.reply;
    setState(() {
      _reading = false;
      _ok = r.end == OpEnd.done && reply != null && reply.kind == ReplyKind.answer;
      // the answer's text is Rust's whitelist (settings_text: no passphrase, node strings through `shown`); kept with
      // its technical parts: the screen splits them (SayLine's rule), the copy shows them as 〔 〕
      _text = _ok ? stripMarkers(reply!.text) : opLine(r);
    });
  }

  @override
  Widget build(BuildContext context) {
    final t = BatTheme.of(context);
    final tech = techText(_text);
    return BatPage(title: '查看節點設定', body: [
      Text('節點回傳的設定（白名單欄位，不含密碼）。', style: TextStyle(fontSize: Fs.note, height: 1.55, color: t.sub)),
      NodePickCard(app: widget.app, ui: widget.ui, picked: _id, enabled: !_reading, onPick: (id) => setState(() => _id = id)),
      if (_text.isNotEmpty)
        BatCard(children: [
          Padding(
            padding: const EdgeInsets.all(14),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
              SelectableText(screenText(_text),
                  key: const Key('settings-text'), style: TextStyle(fontSize: Fs.body, height: 1.6, color: t.ink)),
              if (tech.isNotEmpty) TechFold(tech, techKey: const Key('settings-tech')),
            ]),
          ),
        ]),
    ], foot: [
      BatButton(_reading ? '讀取中…' : '讀取設定', key: const Key('settings-read'), onPressed: _id == null || _reading ? null : _read),
      if (_ok)
        BatButton('複製',
            key: const Key('settings-copy'),
            kind: BtnKind.text,
            onPressed: () => Clipboard.setData(ClipboardData(text: logText(_text)))),
    ]);
  }
}

// ---- D4 文字紀錄 ----------------------------------------------------------------------------------------------------

/// A log line for the screen and the copy: device ids and Bluetooth addresses cut to their last four (the logcat
/// path's [NodeLink.mask]); the technical-part markers U+001E / U+001F shown as 〔 〕 and any other control character
/// as a space (no invisible character left, plan D7).
String logShown(String l) => logText(NodeLink.mask(l))
    .replaceAll(RegExp(r'[\u0000-\u001d\u007f]'), ' ');

class LogPage extends StatefulWidget {
  const LogPage({super.key, required this.app});
  final AppLink app;

  @override
  State<LogPage> createState() => _LogPageState();
}

class _LogPageState extends State<LogPage> {
  @override
  Widget build(BuildContext context) {
    final t = BatTheme.of(context);
    final lines = [for (final l in widget.app.link.core.log) logShown(l)];
    return BatPage(title: '文字紀錄', body: [
      Text('節點自動讀取與佔用的紀錄（最多 500 行，只在這次開 app 的記憶體裡）。裝置編號與藍牙位址只留後四碼。',
          style: TextStyle(fontSize: Fs.note, height: 1.55, color: t.sub)),
      if (lines.isEmpty)
        Text('還沒有紀錄', key: const Key('log-empty'), style: TextStyle(fontSize: Fs.body, color: t.ink))
      else
        BatCard(children: [
          Padding(
            padding: const EdgeInsets.all(12),
            child: SelectableText(lines.join('\n'),
                key: const Key('log-text'), style: TextStyle(fontFamily: 'monospace', fontSize: Fs.meta, height: 1.5, color: t.ink)),
          ),
        ]),
    ], foot: [
      BatButton(Btn.refresh, kind: BtnKind.secondary, onPressed: () => setState(() {})),
      if (lines.isNotEmpty)
        BatButton('複製', key: const Key('log-copy'), kind: BtnKind.text, onPressed: () => Clipboard.setData(ClipboardData(text: lines.join('\n')))),
    ]);
  }
}

// ---- D4a 忘記加入中的節點 ---------------------------------------------------------------------------------------------

/// 「排除這台」 for a node that is not one of this phone's own nodes in that record (review pr6 A-5).
const orphanNotOwnLine = '這台不在這支手機自己的節點裡，不能從這裡排除';

class OrphanJoinsPage extends StatefulWidget {
  const OrphanJoinsPage({super.key, required this.app, required this.ui});
  final AppLink app;
  final UiState ui;

  @override
  State<OrphanJoinsPage> createState() => _OrphanJoinsPageState();
}

class _OrphanJoinsPageState extends State<OrphanJoinsPage> {
  String _line = '';
  bool _busy = false;

  AppLink get a => widget.app;

  @override
  void initState() {
    super.initState();
    a.nets.addListener(_changed);
  }

  @override
  void dispose() {
    a.nets.removeListener(_changed);
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  String _who(JoinTodo j) {
    final l4 = j.deviceId.isNotEmpty ? last4(j.deviceId) : j.member.last4.toUpperCase();
    return l4.isEmpty ? j.member.name : '…$l4';
  }

  String _net(JoinTodo j) => j.net.view.netName.isEmpty ? j.net.view.meshId : j.net.view.netName;

  Future<void> _ask(JoinTodo j) async {
    if (_busy || !a.devTrust) return;
    final t = BatTheme.of(context);
    final pick = await showDialog<String>(
        context: context,
        builder: (c) => AlertDialog(
              backgroundColor: t.surf,
              title: Text('要放棄 ${_who(j)} 加入「${_net(j)}」嗎？', style: TextStyle(fontSize: Fs.title, fontWeight: FontWeight.w700, color: t.ink)),
              content: Text(forgetNotice(approved: false, offerExclude: a.devTrust), style: TextStyle(fontSize: Fs.body, height: 1.6, color: t.ink)),
              actions: [
                Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  BatButton(Btn.forgetJoin, key: const Key('orphan-forget'), onPressed: () => Navigator.pop(c, 'forget')),
                  // remove-member §3.6: a node that may be lost / captured is excluded instead (the old console's choice)
                  if (a.devTrust) ...[
                    const SizedBox(height: 8),
                    BatButton(Btn.excludeThis,
                        key: const Key('orphan-exclude'), kind: BtnKind.danger, onPressed: () => Navigator.pop(c, 'exclude')),
                  ],
                  const SizedBox(height: 6),
                  BatButton(Btn.cancel, kind: BtnKind.text, onPressed: () => Navigator.pop(c)),
                ]),
              ],
            ));
    if (!mounted) return;
    if (pick == 'exclude') return _exclude(j);
    if (pick == 'forget') return _forget(j);
  }

  /// The exclusion of this very node (review pr6 A-5: as the old console did, `_pendingExclude = (net, m.dacHash)` at
  /// main c4905ed nodes.dart:1283): RemoveConfirmPage — PersonPage's own controller (team_pages.dart `go('', dacHash)`)
  /// — for this phone's group with this node as the target. A node that is not one of this phone's own nodes in the
  /// record is said so (nothing to exclude from here).
  Future<void> _exclude(JoinTodo j) async {
    final d = teamDeps(a);
    try {
      final (_, plain) = await d.readRecord(j.net.rel); // (A-7: a failed read is said too, not left unhandled)
      final keys = await d.publicKeys();
      if (!mounted) return;
      if (plain == null) return setState(() => _line = stripMarkers(recordUnopenedLine));
      final people = netPeople(recordPlain: plain, ownerPub: keys['owner']!);
      final self = people.where((p) => p.isSelf).firstOrNull;
      if (self == null) return setState(() => _line = '這個網路紀錄裡找不到這支手機自己的節點');
      if (!self.nodes.any((n) => n.dacHash == j.member.dacHash)) return setState(() => _line = orphanNotOwnLine);
      await Navigator.of(context).push(MaterialPageRoute(
          builder: (_) => RemoveConfirmPage(
              app: a, netId: j.net.id, person: self, owner: '', node: j.member.dacHash, same: sameNameLines(self, people))));
    } catch (e) {
      // review pr6 A-7: a Rust String error keeps its own words; anything else is technical as a whole
      if (mounted) setState(() => _line = e is String ? '讀不到網路紀錄裡的隊員：$e' : '讀不到網路紀錄裡的隊員${tech(e)}');
    }
  }

  /// join2 §3.4: this phone's record only (the node is not changed); its own short session lease, RecordWriter.
  Future<void> _forget(JoinTodo j) async {
    setState(() {
      _busy = true;
      _line = '';
    });
    final l = await a.link.acquire(Btn.forgetJoin, LeaseKind.session);
    if (!mounted) {
      await l?.release();
      return;
    }
    if (l == null) {
      setState(() {
        _busy = false;
        _line = '另一個操作還在進行：${a.reg.current?.name ?? ''}';
      });
      return;
    }
    String line;
    try {
      final (gen, p) = await a.console.readRecord(j.net.rel);
      if (p == null) throw recordUnopenedLine;
      line = await forgetJoining(l, a.writer,
          rel: j.net.rel, plain: p, gen: gen, dacHash: j.member.dacHash, seal: a.console.seal, keyError: (e) => keyErrorToRadio(e, a.link));
    } catch (e) {
      line = e is String ? e : '[REQ_FAIL] 忘記沒有成功${tech(e)}'; // review pr6 A-7: the exception as 技術資訊
    } finally {
      await l.release(); // NetIndex computes again on the release: the row goes once the record says so
    }
    if (mounted) {
      setState(() {
        _busy = false;
        _line = stripMarkers(line); // technical parts kept: SayLine shows them under 技術資訊
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = BatTheme.of(context);
    final s = a.nets.now;
    return BatPage(title: '忘記加入中的節點', body: [
      Text('網路紀錄裡還在「加入中」、但這支手機已經沒有那台節點紀錄的項目（例如節點已從這支手機移除）。還有節點紀錄的，請到首頁的待辦處理。',
          style: TextStyle(fontSize: Fs.note, height: 1.55, color: t.sub)),
      if (s.computing)
        Text('正在讀手機裡的網路紀錄…', style: TextStyle(fontSize: Fs.body, color: t.sub))
      else if (s.orphansUnknown)
        Text('讀不到手機上的節點清單', key: const Key('orphan-unknown'), style: TextStyle(fontSize: Fs.body, color: t.ink))
      else if (s.orphanJoins.isEmpty)
        Text('沒有這種項目。', key: const Key('orphan-none'), style: TextStyle(fontSize: Fs.body, color: t.ink))
      else
        BatCard(children: [
          for (final j in s.orphanJoins)
            BatRow(
              key: Key('orphan-${j.net.id}-${j.member.dacHash}'),
              icon: Icons.link_off,
              title: '「${_net(j)}」裡的 ${_who(j)}',
              sub: '加入中，手機裡沒有這台的紀錄',
              enabled: !_busy,
              onTap: () => _ask(j),
            ),
        ]),
      if (_line.isNotEmpty) SayLine(_line, key: const Key('orphan-line'), style: TextStyle(fontSize: Fs.body, height: 1.6, color: t.ink)),
    ]);
  }
}
