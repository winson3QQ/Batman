// (review pr6 A-9) "nodes.dart" / "nodes.dart:<line>" below = the old console, deleted by #329 PR 6: see
// `git show c4905ed:app/lib/nodes.dart` (main before PR 6).
// #329 PR 5 R15 (§2.10 / §2.12): 「隊伍與邀請」 — the old console's member buttons, every row always there (no record
// looked at); the page a row opens says why when the phone holds nothing it can use. Dev builds only (F14 / T-S5).
import 'package:flutter/material.dart';

import '../src/flows/net_index.dart';
import '../src/flows/rekey_send.dart' show rustLast4;
import '../src/nodelink/app_link.dart';
import '../src/nodelink/core.dart' as nl show Page;
import 'join_choice.dart' show NetMode;
import 'join_pages.dart';
import 'net_pages.dart' show NetFormPage;
import 'remove_pages.dart' show RekeyPage;
import 'team_pages.dart';
import 'ui_state.dart';
import 'widgets.dart';

/// R15: the rows, in the order shown (T-P5-E checks every one). #329 PR 6 P2-1: each side's steps first, numbered in
/// the order they are done; the rest under 「其他」.
const kHubLeaderSteps = ['邀請隊員', '收隊員的申請'];
const kHubLeaderOther = ['隊員名單', '產生更新包'];
const kHubMemberSteps = ['收隊長的邀請', '匯入隊長的同意', '讓我的節點加入隊長的網路'];
const kHubMemberOther = ['再顯示申請', '貼上隊長給的新密碼'];
const kHubLeaderRows = [...kHubLeaderSteps, ...kHubLeaderOther];
const kHubMemberRows = [...kHubMemberSteps, ...kHubMemberOther];

/// P2-1: the second line of a step row.
String hubStep(int n, int of) => '第 $n 步（共 $of 步）';

class TeamHubPage extends StatelessWidget {
  const TeamHubPage({super.key, required this.app, required this.ui});
  final AppLink app;
  final UiState ui;

  @override
  Widget build(BuildContext context) {
    void go(Widget page) => Navigator.of(context).push(MaterialPageRoute(builder: (_) => page));
    void net(String title, Widget Function(String netId) next) => go(PickNetPage(app: app, title: title, next: next));
    final leaderSteps = <(String, IconData, VoidCallback)>[
      (kHubLeaderSteps[0], Icons.person_add_alt, () => net(kHubLeaderSteps[0], (id) => InvitePage(app: app, netId: id))),
      (kHubLeaderSteps[1], Icons.how_to_reg_outlined, () => net(kHubLeaderSteps[1], (id) => RequestPage(app: app, netId: id))),
    ];
    final leaderOther = <(String, IconData, VoidCallback)>[
      (kHubLeaderOther[0], Icons.groups_outlined, () => net(kHubLeaderOther[0], (id) => MembersPage(app: app, netId: id))),
      (kHubLeaderOther[1], Icons.key_outlined, () => net(kHubLeaderOther[1], (id) => RekeyPage(app: app, netId: id))),
    ];
    final memberSteps = <(String, IconData, VoidCallback)>[
      (kHubMemberSteps[0], Icons.mail_outline, () => go(JoinTeamPage(app: app, ui: ui))),
      (kHubMemberSteps[1], Icons.verified_outlined, () => go(ImportApprovalPage(app: app, ui: ui))),
      (kHubMemberSteps[2], Icons.hub_outlined, () => go(NetFormPage(app: app, ui: ui, mode: NetMode.member, back: nl.Page.other))),
    ];
    final memberOther = <(String, IconData, VoidCallback)>[
      (kHubMemberOther[0], Icons.hourglass_empty, () => go(PickPendPage(app: app, ui: ui))),
      (kHubMemberOther[1], Icons.vpn_key_outlined, () => go(UpdateImportPage(app: app, ui: ui))),
    ];
    Widget steps(List<(String, IconData, VoidCallback)> rows) => BatCard(children: [
          for (final (n, (t, i, f)) in rows.indexed)
            BatRow(key: Key('hub-$t'), icon: i, title: '${n + 1}　$t', sub: hubStep(n + 1, rows.length), onTap: f),
        ]);
    Widget other(List<(String, IconData, VoidCallback)> rows) =>
        BatCard(children: [for (final (t, i, f) in rows) BatRow(key: Key('hub-$t'), icon: i, title: t, onTap: f)]);
    return BatPage(title: '隊伍與邀請', body: [
      const BatLabel('我是隊長（這支手機建立的網路）：照順序做'),
      steps(leaderSteps),
      const BatLabel('隊長：其他'),
      other(leaderOther),
      const BatLabel('我是隊員（加入隊長的網路）：照順序做'),
      steps(memberSteps),
      const BatLabel('隊員：其他'),
      other(memberOther),
    ]);
  }
}

/// R13: a network told apart from the others by its name and mesh id, plus the last four of its id when names repeat.
/// NetView carries no creation date (D14), so the date the plan names cannot be shown.
String netPickLabel(NetEntry n, List<NetEntry> all) {
  final name = n.view.netName.isEmpty ? '網路' : n.view.netName;
  final same = all.where((x) => x.view.netName == n.view.netName).length > 1;
  return '$name ${n.view.meshId}${same ? '（代號 …${rustLast4(n.id).toUpperCase()}）' : ''}';
}

/// R13 / S-m7: the leader's rows list only applied networks (nodes.dart:802, :1313).
class PickNetPage extends StatelessWidget {
  const PickNetPage({super.key, required this.app, required this.title, required this.next});
  final AppLink app;
  final String title;
  final Widget Function(String netId) next;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
      listenable: app.nets,
      builder: (context, _) {
        final s = app.nets.now;
        final nets = s.nets.where((n) => n.applied).toList();
        return BatPage(title: title, body: [
          if (s.computing)
            const StatusHero(look: Look.busy, text: '正在讀取網路紀錄')
          else if (s.listFailed)
            StatusHero(look: Look.bad, text: '讀不到手機裡的網路紀錄', extra: [BatButton(Btn.tryAgain, onPressed: app.nets.recompute)])
          else if (nets.isEmpty)
            const StatusHero(look: Look.unk, text: '這支手機沒有已建立的網路', next: '隊長要先在首頁按「建立網路」，網路建立完成後才能用這裡。')
          else ...[
            const BatLabel('哪一個網路'),
            BatCard(children: [
              for (final n in nets)
                BatRow(
                    key: Key('pick-${n.id}'),
                    icon: Icons.hub_outlined,
                    title: netPickLabel(n, nets),
                    onTap: () => Navigator.of(context).pushReplacement(MaterialPageRoute(builder: (_) => next(n.id)))),
            ]),
          ],
        ]);
      });
}

/// 「再顯示申請」 (nodes.dart:926-954): the requests waiting on this phone; several -> picked first.
class PickPendPage extends StatelessWidget {
  const PickPendPage({super.key, required this.app, required this.ui});
  final AppLink app;
  final UiState ui;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
      listenable: app.nets,
      builder: (context, _) {
        final s = app.nets.now;
        return BatPage(title: '再顯示申請', body: [
          if (s.computing)
            const StatusHero(look: Look.busy, text: '正在讀取網路紀錄')
          else if (s.mpendIds.isEmpty)
            const StatusHero(look: Look.unk, text: '這支手機沒有待處理的申請', next: '要加入隊長的網路，先「收隊長的邀請」。')
          else
            BatCard(children: [
              for (final id in s.mpendIds)
                BatRow(
                    key: Key('pend-$id'),
                    icon: Icons.hourglass_empty,
                    title: '網路 ${id.length > 12 ? id.substring(0, 12) : id}… 的申請',
                    onTap: () => Navigator.of(context)
                        .pushReplacement(MaterialPageRoute(builder: (_) => MyRequestPage(app: app, ui: ui, netId: id)))),
            ]),
        ]);
      });
}
