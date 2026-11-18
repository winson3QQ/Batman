// #329 PR 5 plan v16 §2.7 (boards 8.1, 7.1, 7.3–7.7, 8.2): the leader's team pages. The steps are the old console's
// (_members, _makeInvite, _checkRequest, SasConfirmView; nodes.dart:1311-1344, :798-864) unchanged: every record
// write is an OfflineOp (R10, re-read under the lease R11), the codes go through CodeView (R1–R4), the confirmation
// code through SasCheck (R3 / D6). Removal is in remove_pages.dart.
import 'dart:async';

import 'package:flutter/material.dart';

import '../member_ui.dart' show sasRule, showDupNote;
import '../say.dart' show SayLine, stripMarkers, tech;
import '../secure_screen.dart';
import '../src/flows/offline_op.dart';
import '../src/nodelink/app_link.dart';
import '../src/rust/api/member.dart' show JoinReqView, NetOp, netCheckJoinreq;
import '../src/rust/api/rekey.dart' show PersonView, netPeople, netRecipients;
import 'code_view.dart';
import 'net_pages.dart' show askYesNo;
import 'remove_pages.dart';
import 'rekey_result.dart' show leaderVersionLine;
import '../src/flows/rekey_send.dart' show VersionRead;
import 'team_deps.dart';
import 'theme.dart';
import 'widgets.dart';

/// The line an offline operation ends with when it has no result of its own (R10 / R12).
String offlineLine(OfflineReply r) => switch (r) {
      OfflineBusy(:final name) => '另一個操作還在進行：$name',
      OfflineFailed(:final line) => stripMarkers(line), // technical parts kept: shown through SayLine
      OfflineUnknown() => '結果不明，請再做一次',
      OfflineDone() => '',
    };

/// 8.1 / F-m5: the other groups with [p]'s name, compared by the whole owner (Rust's sameName compares fingerprints
/// only); one line each, the same fingerprint too -> the plan's extra sentence.
List<String> sameNameLines(PersonView p, List<PersonView> all) => [
      for (final o in all)
        if (o.owner != p.owner && o.name == p.name)
          '另有同名的一組：${o.fpr}（要一起移除得各按一次）${o.fpr == p.fpr ? '。指紋也相同：兩組都移除，再重新邀請要留的那位' : ''}'
    ];

// ---- 8.1 隊員名單 ---------------------------------------------------------------------------------------------------

class MembersPage extends StatefulWidget {
  const MembersPage({super.key, required this.app, required this.netId});
  final AppLink app;
  final String netId;

  @override
  State<MembersPage> createState() => _MembersPageState();
}

class _MembersPageState extends State<MembersPage> {
  VersionRead _ver = VersionRead.pending; // R19
  List<PersonView>? _people;
  Set<String>? _need; // the owners 8.4 lists (netRecipients): the 8.1 count is theirs; null = unreadable, count all
  String _line = '';

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

  /// R19: read the record now (on open and after returning from a page above, AC-M1).
  Future<void> _load() async {
    unawaited(_reread());
    final (_, plain) = await teamDeps(a).readRecord(rel);
    final keys = await teamDeps(a).publicKeys();
    if (!mounted) return;
    if (plain == null) return setState(() => _line = '手機裡的網路紀錄打不開');
    try {
      final p = netPeople(recordPlain: plain, ownerPub: keys['owner']!);
      // device session 2026-11-17: a member admitted after the removal (at the new version) needs no bundle, as 8.4 says.
      // review c15a92d G-3 / H-1: recipients unreadable -> the list still shows, every unticked member is counted
      Set<String>? need;
      try {
        need = {for (final r in netRecipients(recordPlain: plain, ownerPub: keys['owner']!)) r.owner};
      } catch (_) {}
      setState(() {
        _people = [...p.where((x) => x.isSelf), ...p.where((x) => !x.isSelf)];
        _need = need;
      });
    } catch (e) {
      setState(() => _line = '[REQ_FAIL] ${e is String ? e : tech(e.runtimeType)}');
    }
  }

  Future<void> _go(Widget page) async {
    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => page));
    if (mounted) await _load();
  }

  @override
  Widget build(BuildContext context) {
    final t = BatTheme.of(context);
    final note = TextStyle(fontSize: Fs.note, height: 1.55, color: t.sub);
    final people = _people;
    final left = people == null ? 0 : people.where((p) => !p.isSelf && (_need?.contains(p.owner) ?? true) && !a.ticks.handed(widget.netId, p.owner)).length;
    return BatPage(title: '隊員名單', body: [
      Text(leaderVersionLine(_ver), key: const Key('net-version'), style: TextStyle(fontSize: Fs.body, color: t.ink)),
      if (a.ticks.removedThisRun(widget.netId) && left > 0)
        BatBanner(look: Look.warn, title: '還有 $left 位隊員沒交更新包'),
      Text('移除隊員之後，要用「產生更新包」把新密碼交給每位留下的隊員，並把新密碼送到你的每台節點。', key: const Key('members-rule'), style: note),
      if (_line.isNotEmpty) SayLine(_line, style: note),
      if (people != null)
        BatCard(children: [
          for (final p in people)
            BatRow(
              key: Key('person-${p.owner}'),
              icon: p.isSelf ? Icons.star_outline : Icons.person_outline,
              title: p.isSelf ? '我（隊長）' : p.name,
              sub: [
                '指紋 ${p.fpr}',
                if (p.nodes.isNotEmpty) p.nodes.map((n) => '…${n.last4}${n.state == 'joining' ? '（加入中）' : ''}').join('、'),
                ...sameNameLines(p, people),
              ].join('\n'),
              onTap: () => _go(PersonPage(app: a, netId: widget.netId, person: p, all: people)),
            ),
        ]),
    ], foot: [
      BatButton('邀請隊員', onPressed: () => _go(InvitePage(app: a, netId: widget.netId))),
      BatButton('收隊員的申請', kind: BtnKind.secondary, onPressed: () => _go(RequestPage(app: a, netId: widget.netId))),
      BatButton('產生更新包', kind: BtnKind.text, onPressed: () => _go(RekeyPage(app: a, netId: widget.netId))),
    ]);
  }
}

// ---- 8.2 單一隊員 ---------------------------------------------------------------------------------------------------

class PersonPage extends StatelessWidget {
  const PersonPage({super.key, required this.app, required this.netId, required this.person, required this.all});
  final AppLink app;
  final String netId;
  final PersonView person;
  final List<PersonView> all;

  @override
  Widget build(BuildContext context) {
    final t = BatTheme.of(context);
    final note = TextStyle(fontSize: Fs.note, height: 1.55, color: t.sub);
    final same = sameNameLines(person, all);
    // review C m7: once 8.3 has removed (it hands over to 8.4 with `true`), this page is taken out from under 8.4: back
    // goes to the list, never to a person or node that is gone
    Future<void> go(String p, String n) async {
      final route = ModalRoute.of(context);
      final removed = await Navigator.of(context).push<Object?>(MaterialPageRoute(
          builder: (_) => RemoveConfirmPage(app: app, netId: netId, person: person, node: n, owner: p, same: same)));
      if (removed == true && route != null && route.isActive && context.mounted) Navigator.of(context).removeRoute(route);
    }
    return BatPage(title: person.isSelf ? '我（隊長）' : person.name, body: [
      Text('指紋 ${person.fpr}', style: note),
      for (final s in same) Text(s, key: const Key('same-name'), style: note),
      // old _members (nodes.dart:1334-1338): others are removed as a person; your own nodes are excluded one by one
      if (person.isSelf)
        BatCard(children: [
          for (final n in person.nodes)
            BatRow(
                icon: Icons.block,
                danger: true,
                title: '排除 …${n.last4}（遺失 / 被抓；換全隊密碼）',
                sub: n.state == 'joining' ? '加入中' : null,
                onTap: () => go('', n.dacHash)),
        ]),
    ], foot: [
      if (!person.isSelf) BatButton('移除${person.name}，全隊換密碼', kind: BtnKind.danger, onPressed: () => go(person.owner, '')),
    ]);
  }
}

// ---- 7.1 邀請隊員 ---------------------------------------------------------------------------------------------------

class InvitePage extends StatefulWidget {
  const InvitePage({super.key, required this.app, required this.netId});
  final AppLink app;
  final String netId;

  @override
  State<InvitePage> createState() => _InvitePageState();
}

class _InvitePageState extends State<InvitePage> {
  bool _running = false;
  String _line = '';

  Future<void> _make(bool inPerson) async {
    final a = widget.app;
    final p = teamDeps(a).platform;
    setState(() {
      _running = true;
      _line = '';
    });
    final keys = await teamDeps(a).publicKeys();
    final r = await OfflineOp.run(teamDeps(a).offline, '邀請隊員', (l, w) async {
      final (gen, plain) = await p.readRecord('net/${widget.netId}'); // R11
      if (plain == null) throw '[REQ_FAIL] 手機裡的網路紀錄打不開';
      final (op, st) = NetOp.makeInvite(recordPlain: plain, recordGen: gen, adminPub: keys['admin']!);
      return runNetOp(st, NetOpCalls(signed: (d) => op.signed(der: d)!, netPersisted: () => op.netPersisted()!, persistFailed: (e) => op.persistFailed(error: e)!), l, w, p);
    });
    if (!mounted) return;
    setState(() => _running = false);
    if (r case OfflineDone(:final value) when value.hex.isNotEmpty) {
      // 7.1 owns the chain 7.3 -> 7.4 (device session 2026-11-17: with pushReplacement 8.1's push ended at once and it
      // re-read before the member was approved). 7.3 closes itself before 7.4 opens (R4's reminder and its secure
      // screen end there, as before); this page leaves last, by its own route (review c15a92d G-1 / H-2 / H-3)
      final route = ModalRoute.of(context);
      final next = await Navigator.of(context)
          .push<bool>(MaterialPageRoute(builder: (_) => InviteCodePage(app: a, netId: widget.netId, hex: value.hex, inPerson: inPerson)));
      if (next == true && mounted) {
        await Navigator.of(context).push(MaterialPageRoute(builder: (_) => RequestPage(app: a, netId: widget.netId)));
      }
      if (route != null && route.isActive && mounted) Navigator.of(context).removeRoute(route);
      return;
    }
    setState(() => _line = r is OfflineDone<NetOpEnd> ? stripMarkers(r.value.detail) : offlineLine(r));
  }

  @override
  Widget build(BuildContext context) => PopScope(
        canPop: !_running, // R10: no leaving while the work runs
        child: BatPage(title: '邀請隊員', body: [
          const BatLabel('隊員現在在你旁邊嗎？'),
          BatCard(children: [
            BatRow(icon: Icons.qr_code, title: '在旁邊', sub: '讓隊員掃我的畫面', enabled: !_running, onTap: () => _make(true)),
            BatRow(icon: Icons.ios_share, title: '不在旁邊', sub: '用訊息把文字傳給他，再用電話核對確認碼', enabled: !_running, onTap: () => _make(false)),
          ]),
          if (_line.isNotEmpty) SayLine(_line, key: const Key('invite-line')),
        ]),
      );
}

// ---- 7.3 顯示邀請碼 ---------------------------------------------------------------------------------------------------

class InviteCodePage extends StatelessWidget {
  const InviteCodePage({super.key, required this.app, required this.netId, required this.hex, required this.inPerson});
  final AppLink app;
  final String netId, hex;
  final bool inPerson;

  @override
  Widget build(BuildContext context) => BatPage(title: '邀請碼', body: [
        Text(inPerson ? '請隊員掃這個畫面' : '用訊息把文字傳給隊員，再用電話核對確認碼'),
        CodeView(hex: hex),
      ], foot: [
        BatButton('下一步：收隊員的申請', onPressed: () {
          // 7.1 opens 7.4 once this page is gone; a second tap while it closes pops nothing more
          if (ModalRoute.of(context)?.isCurrent ?? false) Navigator.of(context).pop(true);
        }),
      ]);
}

// ---- 7.4 收申請 → 7.5 核對 → 7.6 同意碼 / 7.7 不同 ----------------------------------------------------------------

/// 7.5's main button.
const kApproveSame = '數字一樣，同意加入';

class RequestPage extends StatefulWidget {
  const RequestPage({super.key, required this.app, required this.netId});
  final AppLink app;
  final String netId;

  @override
  State<RequestPage> createState() => _RequestPageState();
}

class _RequestPageState extends State<RequestPage> {
  String _line = '';

  Future<void> _got(String hex) async {
    final a = widget.app;
    final (_, plain) = await teamDeps(a).readRecord('net/${widget.netId}');
    if (!mounted) return;
    if (plain == null) return setState(() => _line = '手機裡的網路紀錄打不開');
    final JoinReqView jr;
    try {
      jr = netCheckJoinreq(recordPlain: plain, hex: hex);
    } catch (e) {
      return setState(() => _line = '[REQ_FAIL] 申請不能用：${e is String ? e : tech(e.runtimeType)}');
    }
    var previousOk = false;
    if (jr.previous.isNotEmpty) {
      previousOk = await askYesNo(context, '這台或這個人之前被移出過', jr.previous, '確定，繼續核對', '取消');
      if (!mounted) return; // review B m1
      if (!previousOk) return setState(() => _line = '[REQ_FAIL] 沒有同意（之前被移出過）');
    }
    if (!mounted) return;
    await Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => ApprovePage(app: a, netId: widget.netId, hex: hex, jr: jr, previousOk: previousOk)));
  }

  @override
  Widget build(BuildContext context) => BatPage(title: '收隊員的申請', body: [
        const Text('掃描隊員的申請 QR，或貼上他用訊息傳來的文字。一張邀請可以收多份申請。'),
        if (_line.isNotEmpty) SayLine(_line, key: const Key('request-line')),
      ], foot: [
        // #329 PR 6 (7.4): the main action at the bottom
        CodeInput(devTrust: widget.app.devTrust, onText: _got, onError: (w) => setState(() => _line = w)),
      ]);
}

/// The confirmation code, big, with the rule and one button (the old SasConfirmView's behaviour: one press only),
/// on a page that cannot be captured; where it cannot be protected the code still shows (D6), with a warning.
class SasCheck extends StatefulWidget {
  const SasCheck(
      {super.key, required this.sas, required this.confirmLabel, required this.onConfirm, this.notice, this.withButton = true});
  final String sas, confirmLabel;
  final String? notice;

  /// false: the page puts the confirm button in its foot itself (#329 PR 6, 7.5: the main action at the bottom)
  final bool withButton;

  /// called once per build of this widget (a busy / failed reply rebuilds it with a new key: B-m7)
  final Future<void> Function() onConfirm;

  @override
  State<SasCheck> createState() => _SasCheckState();
}

class _SasCheckState extends State<SasCheck> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final t = BatTheme.of(context);
    Widget code() => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          if (widget.notice != null) Text(widget.notice!, style: TextStyle(color: Look.warn.ink(t))),
          Text(widget.sas,
              key: const Key('sas'),
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 44, fontFamily: 'monospace', letterSpacing: 6, color: t.ink)),
        ]);
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      SecureScreen(
          fallback: Column(children: [code(), Text('這支手機無法防止截圖', style: TextStyle(color: Look.warn.ink(t)))]),
          child: code()),
      const SizedBox(height: 8),
      Text(sasRule, key: const Key('sasRule'), style: TextStyle(fontWeight: FontWeight.bold, color: t.ink)),
      if (widget.withButton) ...[
        const SizedBox(height: 16),
        BatButton(widget.confirmLabel,
            key: const Key('sasConfirm'),
            onPressed: _pressed
                ? null
                : () async {
                    setState(() => _pressed = true);
                    await widget.onConfirm();
                  }),
      ],
    ]);
  }
}

class ApprovePage extends StatefulWidget {
  const ApprovePage({super.key, required this.app, required this.netId, required this.hex, required this.jr, required this.previousOk});
  final AppLink app;
  final String netId, hex;
  final JoinReqView jr;
  final bool previousOk;

  @override
  State<ApprovePage> createState() => _ApprovePageState();
}

class _ApprovePageState extends State<ApprovePage> {
  bool _running = false;
  String _line = '';
  int _tries = 0;

  Future<void> _approve() async {
    final a = widget.app;
    final p = teamDeps(a).platform;
    setState(() {
      _running = true;
      _line = '';
    });
    final keys = await teamDeps(a).publicKeys();
    final r = await OfflineOp.run(teamDeps(a).offline, '同意加入', (l, w) async {
      final (gen, plain) = await p.readRecord('net/${widget.netId}'); // R11: approve re-checks what is on disk now
      if (plain == null) throw '[REQ_FAIL] 手機裡的網路資料打不開';
      final (op, st) = NetOp.approve(
          recordPlain: plain,
          recordGen: gen,
          hex: widget.hex,
          joinreqHash: widget.jr.joinreqHash,
          adminPub: keys['admin']!,
          previousConfirmed: widget.previousOk);
      return runNetOp(st, NetOpCalls(signed: (d) => op.signed(der: d)!, netPersisted: () => op.netPersisted()!, persistFailed: (e) => op.persistFailed(error: e)!), l, w, p);
    });
    if (!mounted) return;
    if (r case OfflineDone(:final value) when value.hex.isNotEmpty) {
      if (value.note.isNotEmpty) await showDupNote(context, value.note); // after the lease (A-m3)
      if (!mounted) return;
      await Navigator.of(context).pushReplacement(MaterialPageRoute(builder: (_) => ApprovalCodePage(hex: value.hex, name: widget.jr.name)));
      return;
    }
    setState(() {
      _running = false;
      _tries++; // B-m7: a new SasCheck, its button pressable again
      _line = r is OfflineDone<NetOpEnd> ? stripMarkers(r.value.detail) : offlineLine(r);
    });
  }

  @override
  Widget build(BuildContext context) {
    final jr = widget.jr;
    return PopScope(
      canPop: !_running,
      child: BatPage(title: '核對確認碼', body: [
        Text('核對隊員的申請：${jr.name}（…${jr.deviceSuffix}）${jr.replacesApproved ? '，重新同意' : ''}', key: const Key('approve-title')),
        if (jr.updateFirst) const Text('這個人還有沒換的版本：請他先貼更新包，再貼這份同意'),
        SasCheck(key: ValueKey(_tries), sas: jr.sas, confirmLabel: kApproveSame, onConfirm: _approve, withButton: false),
        if (_line.isNotEmpty) SayLine(_line, key: const Key('approve-line')),
      ], foot: [
        // #329 PR 6 (7.5): the main action at the bottom, above 「數字不一樣」; one press until the reply (B-m7: a failed
        // reply makes it pressable again)
        BatButton(kApproveSame, key: const Key('sasConfirm'), onPressed: _running ? null : _approve),
        BatButton('數字不一樣',
            kind: BtnKind.secondary, // T-C3: one primary (確認碼的按鈕)
            onPressed: _running
                ? null
                : () => Navigator.of(context).pushReplacement(MaterialPageRoute(builder: (_) => const MismatchPage()))),
      ]),
    );
  }
}

class ApprovalCodePage extends StatelessWidget {
  const ApprovalCodePage({super.key, required this.hex, required this.name});
  final String hex, name;

  @override
  Widget build(BuildContext context) => BatPage(title: '同意碼', body: [
        Text('已同意$name加入。最後一步：把同意碼交給他，他匯入後節點才會連上。'),
        CodeView(hex: hex),
      ], foot: [
        BatButton(Btn.done, onPressed: () => Navigator.of(context).pop()),
      ]);
}

class MismatchPage extends StatelessWidget {
  const MismatchPage({super.key});

  @override
  Widget build(BuildContext context) => BatPage(title: '確認碼不同', body: const [
        // D7: nothing is cancelled (Rust has no way to revoke an invite); the request is simply not approved
        StatusHero(look: Look.bad, text: '不要同意這份申請', next: '請重新邀請，並換一種方式傳送。能當面最好。'),
      ], foot: [
        BatButton('重新邀請', onPressed: () => Navigator.of(context).pop()),
      ]);
}
