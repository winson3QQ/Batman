// #329 PR 4 §2.6 / §2.7 (design §5.5 board 5.7, board 10.3): 「更多」 of a node — nickname, country, leave the network,
// technical data, remove from this phone — and the leave page. The leave is 254-app-leave v4.1 as the old console does
// it (leaveFlow / sendLeave, unchanged); only who answers its four questions changes: one OpSession.once holds the
// lease for the leave and the one read after it, on the same Rust session (after_left), then gives it back (D6).
import 'dart:async';

import 'package:flutter/material.dart';

import '../member_ui.dart' show LeaveResult, StatusFields, leaveFlow, leaveNotAsked, memberEntryOf;
import '../say.dart' show screenText;
import '../src/flows/op_session.dart';
import '../src/flows/owner_console.dart';
import '../src/nodelink/app_link.dart';
import '../src/nodelink/lease.dart';
import '../src/rust/api/member.dart' show mnetSummary;
import '../src/rust/api/owner.dart' show StatusView, leaveConfirmText;
import 'add_pages.dart' show NickPage;
import 'home_logic.dart';
import 'home_page.dart' show nodeInfo;
import 'join_pages.dart' show UpdateImportPage;
import 'send_key.dart';
import 'settings_pages.dart' show CountryPage, opDeps, opLine;
import 'theme.dart';
import 'ui_state.dart';
import 'widgets.dart';

/// Board 5.7. This page holds no lease; each row's page or action takes its own.
class MorePage extends StatefulWidget {
  const MorePage({super.key, required this.app, required this.ui, required this.id, this.deps});
  final AppLink app;
  final UiState ui;
  final String id;
  final OpDeps? deps; // tests: the leave page's

  @override
  State<MorePage> createState() => _MorePageState();
}

class _MorePageState extends State<MorePage> {
  bool _tech = false;
  StreamSubscription<void>? _sub;

  @override
  void initState() {
    super.initState();
    _sub = widget.app.link.changed.listen((_) => mounted ? setState(() {}) : null);
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  Future<void> _push(Widget page) async {
    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => page));
    if (mounted) setState(() {});
  }

  /// T17 (moved from the node page, PR 2, unchanged): keep a copy first; no copy -> nothing is deleted. On success the
  /// app goes back to the home page (review C m9: the node page has nothing left to show).
  Future<void> _remove(String name) async {
    final t = BatTheme.of(context);
    final yes = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        backgroundColor: t.surf,
        title: Text('要從這支手機移除$name嗎？', style: TextStyle(fontSize: Fs.title, fontWeight: FontWeight.w700, color: t.ink)),
        content: Text('這支手機會忘記它，之後不能再管理它。要再新增，只能請維修人員重新燒錄。',
            style: TextStyle(fontSize: Fs.body, height: 1.6, color: t.ink)),
        actions: [
          Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            BatButton(Btn.remove, kind: BtnKind.danger, onPressed: () => Navigator.pop(c, true)),
            const SizedBox(height: 6),
            BatButton(Btn.cancel, kind: BtnKind.text, onPressed: () => Navigator.pop(c, false)),
          ]),
        ],
      ),
    );
    if (yes != true || !mounted) return;
    final a = widget.app;
    final lease = await a.link.acquire('移除節點', LeaseKind.session);
    if (!mounted) return;
    if (lease == null) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('另一個操作還在進行：${a.reg.current?.name ?? ''}')));
      return;
    }
    String? err;
    try {
      final kept = await lease.run(() => a.writer.keepCopy(lease, 'node/${widget.id}'));
      if (!kept) {
        err = '沒有辦法先留一份副本，所以沒有移除。紀錄維持原樣。';
      } else {
        await lease.run(() => a.writer.remove(lease, 'node/${widget.id}'));
      }
    } catch (e) {
      debugPrint('BMAPP remove node failed: ${e.runtimeType}');
      err = '沒有移除成功，紀錄維持原樣。請再試一次；一直如此請找維修人員。';
    }
    await lease.release();
    if (err == null) {
      await widget.ui.forget(widget.id);
      a.sw.drop(widget.id); // §2.6 (review A m7 / B m6): an update left of it goes too
    }
    if (!mounted) return;
    if (err != null) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(err)));
      return;
    }
    Navigator.of(context).popUntil((r) => r.isFirst);
  }

  @override
  Widget build(BuildContext context) {
    final a = widget.app;
    if (!a.link.core.states.containsKey(widget.id)) {
      return const BatPage(title: Btn.more, body: [Text('這台節點已經不在這支手機上。')]);
    }
    final t = BatTheme.of(context);
    final n = nodeInfo(a, widget.id, widget.ui);
    final v = n.view;
    // §2.6 (review A m9 / B m7): 離開網路 only on a fresh read that says the node can leave
    final canLeave = n.fresh && v != null && v.canLeave;
    return BatPage(title: Btn.more, body: [
      BatCard(children: [
        BatRow(
            icon: Icons.edit_outlined,
            title: '改暱稱',
            sub: n.name,
            onTap: () => _push(NickPage(app: a, ui: widget.ui, id: widget.id, rename: true))),
        BatRow(
            icon: Icons.public,
            title: '國家',
            onTap: () => _push(CountryPage(app: a, ui: widget.ui, id: widget.id, deps: widget.deps))),
        if (canLeave)
          BatRow(
              key: const Key('more-leave'),
              icon: Icons.logout,
              title: Btn.leaveNetwork,
              onTap: () => _push(LeavePage(app: a, ui: widget.ui, id: widget.id, deps: widget.deps))),
      ]),
      // §2.10: the team rows, dev builds only (T-S5)
      if (a.devTrust)
        BatCard(children: [
          SendKeyButton(app: a, id: widget.id, row: true),
          if (a.nets.now.anyMnet)
            BatRow(
                key: const Key('more-paste-key'),
                icon: Icons.content_paste,
                title: '貼上隊長給的新密碼',
                onTap: () => _push(UpdateImportPage(app: a, ui: widget.ui))),
        ]),
      BatCard(children: [
        BatRow(icon: Icons.build_outlined, title: '技術資訊（給維修人員看）', onTap: () => setState(() => _tech = !_tech)),
        if (_tech)
          Padding(
            padding: const EdgeInsets.all(14),
            child: SelectableText(
              [
                '後四碼 ${last4(widget.id)}',
                if (v != null) ...['版本 ${v.version}', if (v.netId.isNotEmpty) '網路 ${v.netId}', ...v.tech],
              ].join('\n'),
              style: TextStyle(fontFamily: 'monospace', fontSize: Fs.meta, height: 1.5, color: t.ink),
            ),
          ),
      ]),
      const BatLabel('會影響這支手機的動作'),
      BatCard(children: [
        BatRow(
          icon: Icons.delete_outline,
          title: '從這支手機移除這台節點',
          sub: '之後要再新增它，只能請維修人員重新燒錄',
          danger: true,
          onTap: () => _remove(n.name),
        ),
      ]),
    ]);
  }
}

/// The parts of a status view the leave page shows (the verdict, the ⚠️ line, the unfinished-change line).
StatusFields leaveFieldsOf(StatusView v) => StatusFields(
    color: v.color,
    sentence: v.sentence,
    warning: v.warning,
    fresh: v.fresh,
    unfinished: v.unfinished,
    unfinishedUnderVerdict: v.unfinishedUnderVerdict);

/// Board 10.3: the confirm (Rust's words, leave v4.1 §2), then the leave and its result.
class LeavePage extends StatefulWidget {
  const LeavePage({super.key, required this.app, required this.ui, required this.id, this.deps});
  final AppLink app;
  final UiState ui;
  final String id;
  final OpDeps? deps;

  @override
  State<LeavePage> createState() => _LeavePageState();
}

class _LeavePageState extends State<LeavePage> {
  // the old status page's ⚠️ line (member_ui.dart StatusPageView; code review B m4)
  static String _warn(StatusFields f) => f.warning.isEmpty ? '' : '⚠️ ${f.warning}';

  late final OpDeps _d = widget.deps ?? opDeps(widget.app);
  List<String>? _dialog; // [title, body]
  bool _running = false, _done = false;
  String _line = '';
  StatusFields? _after;
  bool _stale = false; // left, but the read after it read nothing (LeaveResult.stale)

  AppLink get a => widget.app;

  // the device id's own last four, as Rust's session.last4() gives them to the old console (no case change)
  String get _raw4 => widget.id.length > 4 ? widget.id.substring(widget.id.length - 4) : widget.id;

  @override
  void initState() {
    super.initState();
    _facts();
  }

  /// The dialog's facts (nodes.dart `_netNames`): the network in NodeLink's fresh read (info key 10), whether this
  /// phone has its net/ record APPLIED (NetIndex) and an mnet/ whose own-node entry is this node.
  Future<void> _facts() async {
    final v = nodeInfo(a, widget.id, widget.ui).view;
    final netId = v?.netId ?? '';
    final admin = netId.isNotEmpty && a.nets.now.nets.any((e) => e.id == netId && e.applied);
    var member = false;
    if (netId.isNotEmpty) {
      try {
        final p = await a.nets.src.open('mnet/$netId');
        if (p != null) member = memberEntryOf(mnetSummary(mnetPlain: p), _raw4);
      } catch (_) {
        member = false; // a record that does not open: the neutral sentence (the dialog only picks words)
      }
    }
    if (!mounted) return;
    setState(() =>
        _dialog = leaveConfirmText(last4: _raw4, netId: netId, adminApplied: admin, memberEntry: member));
  }

  Future<void> _leave() async {
    setState(() {
      _running = true;
      _line = '';
    });
    LeaveResult? res;
    final hasNet = a.nets.now.netFiles > 0, hasMnet = a.nets.now.anyMnet;
    final op = await OpSession.once(_d, widget.id, Btn.leaveNetwork, (c, gone) async {
      ConsoleReply? last;
      res = await leaveFlow(
        ask: ({required wait, required retry, required unclear}) async {
          // retry is false (sendLeave): the console never re-sends
          final r = last = await c.leave(wait: wait, unclear: unclear);
          return r.kind == ReplyKind.answer ? r.text : null;
        },
        askEnd: () => last?.text,
        left: () => last?.left ?? false,
        reread: () async {
          // the same console, never a new login: only that session cuts this one read (after_left)
          if (gone() || !c.alive) return null;
          final p = await c.statusPage(hasNet: hasNet, hasMnet: hasMnet);
          final v = p.value;
          return v is StatusView ? leaveFieldsOf(v) : null;
        },
      );
      return last ?? const ConsoleReply(ReplyKind.notSent, leaveNotAsked);
    }, gone: () => !mounted);
    a.link.refresh(); // §2.7 (review D m3): the next round reads this node, the lease being back
    if (!mounted) return;
    final r = res;
    setState(() {
      _running = false;
      _done = true;
      if (op.end == OpEnd.done && r != null) {
        _line = screenText(r.line ?? leaveNotAsked);
        _after = r.fields;
        _stale = r.stale;
      } else {
        _line = opLine(op);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final t = BatTheme.of(context);
    final d = _dialog;
    final f = _after;
    return PopScope(
      canPop: !_running,
      child: BatPage(title: Btn.leaveNetwork, body: [
        if (d != null && !_done) ...[
          Text(d[0], style: TextStyle(fontSize: Fs.title, fontWeight: FontWeight.w700, color: t.ink)),
          Text(d[1], style: TextStyle(fontSize: Fs.body, height: 1.6, color: t.ink)),
        ],
        if (_running) Text('正在離開網路…（最多約 6 分鐘，請不要關掉這個畫面）', style: TextStyle(fontSize: Fs.body, color: t.sub)),
        if (_line.isNotEmpty) Text(_line, key: const Key('leave-line'), style: TextStyle(fontSize: Fs.body, height: 1.6, color: t.ink)),
        if (f != null) ...[
          // leave v4.1 §2: the unfinished-change line right under the verdict when key 10 is absent, else after the ⚠️ line
          Text(f.sentence, key: const Key('leave-after'), style: TextStyle(fontSize: Fs.body, height: 1.6, color: t.ink)),
          for (final l in f.unfinishedUnderVerdict ? [f.unfinished, _warn(f)] : [_warn(f), f.unfinished])
            if (l.isNotEmpty) Text(l, style: TextStyle(fontSize: Fs.body, height: 1.6, color: t.sub)),
        ],
        // leave v4.1 §2 (code review A m10): the old console marks the page stale here
        if (_stale)
          Text('離開後沒有讀到節點的狀態，稍後回節點頁看。', key: const Key('leave-stale'),
              style: TextStyle(fontSize: Fs.body, height: 1.6, color: t.sub)),
      ], foot: [
        if (!_done) ...[
          BatButton(_running ? '正在離開…' : Btn.leaveNetwork,
              kind: BtnKind.danger, onPressed: _running || d == null ? null : _leave),
          BatButton(Btn.cancel, kind: BtnKind.text, onPressed: _running ? null : () => Navigator.of(context).pop()),
        ] else
          BatButton(Btn.done, onPressed: () => Navigator.of(context).pop()),
      ]),
    );
  }
}
