// #329 PR 5 §2.10 / R16 / R17 / T-S5: the node page's team entries. The new-key hint card sits right under the verdict,
// before every group, whatever the node's state (E-M1); its button asks first (R17) and sends nothing on 取消. The
// member's 加入網路 is there on the entry node of a team network even when it is already in a network, not on another
// node. 「隊員」 and 更多's rows. None of it in the field build.
import 'package:batman_app/src/flows/net_index.dart';
import 'package:batman_app/src/flows/rekey_send.dart';
import 'package:batman_app/src/nodelink/app_link.dart';
import 'package:batman_app/src/nodelink/core.dart';
import 'package:batman_app/src/rust/api/owner.dart' show NetView, StatusView;
import 'package:batman_app/src/rust/api/rekey.dart' show UpdateHint;
import 'package:batman_app/src/rust/frb_generated.dart';
import 'package:batman_app/ui/join_choice.dart' show NetMode;
import 'package:batman_app/ui/more_pages.dart' show MorePage;
import 'package:batman_app/ui/net_pages.dart' show NetFormPage;
import 'package:batman_app/ui/node_page.dart';
import 'package:batman_app/ui/team_deps.dart';
import 'package:batman_app/ui/team_pages.dart' show MembersPage;
import 'package:batman_app/ui/ui_state.dart';
import 'package:batman_app/ui/widgets.dart' show Btn;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'join_pages_test.dart' as jp;
import 'pages_test.dart' show app, host, id;
import 'ui_state_test.dart' show MemStore;

StatusView view({int nodeState = 2, String netId = 'aa11'}) => StatusView(
    color: 'green',
    row: '3',
    sentence: '已連上隊伍網路',
    lagNote: '',
    warning: '',
    nodeState: nodeState,
    netId: netId,
    version: 'v',
    tech: const [],
    fresh: true,
    rateNote: '',
    unfinished: '',
    unfinishedUnderVerdict: false,
    canLeave: false);

void read(AppLink a, StatusView v) => a.link.core.states[id]!
  ..kind = Kind.read
  ..view = 'green'
  ..readAt = a.link.now()
  ..extra = v
  ..last = Concl.read;

NetEntry net(String nid) => NetEntry(
    nid, NetView(netId: nid, meshId: 'bm-aa', netName: 'Own', applied: true, country: 'US', members: const []));

const hintLine = '這台節點的網路密碼還是舊的：被移除的人仍可能連得上';

void main() {
  setUpAll(() => RustLib.initMock(api: jp.TeamRust()));

  Future<void> settle(WidgetTester t) async {
    for (var i = 0; i < 4; i++) {
      await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 5)));
      await t.pump(const Duration(milliseconds: 300));
    }
  }

  /// The node page of `id` (read as [v]) with [s] as the phone's records, the dev build unless [dev] is false.
  Future<AppLink> open(WidgetTester t,
      {StatusView? v, NetSnapshot s = const NetSnapshot(), bool dev = true, UpdateHint? hint, Widget? page}) async {
    t.view.physicalSize = const Size(1080, 5000);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    final a = app();
    a.devTrust = dev;
    a.nets.setForTest(s);
    read(a, v ?? view());
    if (hint != null) a.link.hints[id] = hint;
    await t.pumpWidget(host(page ?? NodePage(app: a, id: id, ui: UiState(MemStore()))));
    await settle(t);
    return a;
  }

  group('the hint card (E-M1)', () {
    testWidgets('a node already in a network: the card right under the verdict, before every group', (t) async {
      await open(t, hint: const UpdateHint(line: hintLine, button: true), s: NetSnapshot(netFiles: 1, nets: [net('aa11')]));
      expect(find.byKey(const Key('node-hint')), findsOneWidget);
      final cardY = t.getTopLeft(find.byKey(const Key('node-hint'))).dy;
      for (final label in ['隊員', '手機 Wi-Fi', '軟體更新']) {
        expect(cardY < t.getTopLeft(find.text(label).first).dy, isTrue, reason: 'before $label');
      }
    });

    testWidgets('R17: its button asks first; 取消 -> nothing sent', (t) async {
      final w = jp.World([id], {id: 'aa11'})..records['net/aa11'] = jp.World([], {}).records['mnet/nn']!;
      teamDepsOverride = (a) {
        final d = w.deps(a);
        // the app's own question (sendDeps), on the fake sessions
        return TeamDeps(
            offline: d.offline,
            platform: d.platform,
            op: d.op,
            publicKeys: d.publicKeys,
            nodeIds: d.nodeIds,
            send: (c) => SendDeps(op: d.op, readRecord: d.send(c).readRecord, confirm: sendDeps(c, a).confirm));
      };
      addTearDown(() => teamDepsOverride = null);
      await open(t, hint: const UpdateHint(line: hintLine, button: true));
      await t.tap(find.byKey(Key('send-key-$id')));
      await settle(t);
      expect(find.text('把新密碼送給這台節點？'), findsOneWidget);
      await t.tap(find.text('取消'));
      await settle(t);
      expect(w.log.where((l) => l.startsWith('send')), isEmpty);
      expect(find.text(cancelledLine), findsOneWidget);
      await t.tap(find.byKey(Key('send-key-$id')));
      await settle(t);
      await t.tap(find.text('送出'));
      await settle(t);
      expect(w.log.where((l) => l.startsWith('send')), ['send $id net/aa11 member=false']);
    });

    testWidgets('no button when Rust says none; no card without a hint', (t) async {
      await open(t, hint: const UpdateHint(line: hintLine, button: false));
      expect(find.byKey(const Key('node-hint')), findsOneWidget);
      expect(find.byKey(Key('send-key-$id')), findsNothing);
      await open(t);
      expect(find.byKey(const Key('node-hint')), findsNothing);
    });
  });

  group('R16: the member\'s 加入網路', () {
    const entry = MnetEntry('m1', name: '山隊', entryLast4: '7D2C');
    NetSnapshot mnet(MnetEntry m) => NetSnapshot(anyMnet: true, mnetIds: [m.id], mnets: [m]);

    testWidgets('the entry node, already in a network: there -> 4.1 member mode on that network', (t) async {
      await open(t, v: view(nodeState: 2), s: mnet(entry));
      expect(find.byKey(const Key('node-join')), findsOneWidget);
      await t.tap(find.byKey(const Key('node-join')));
      await settle(t);
      final f = t.widget<NetFormPage>(find.byType(NetFormPage));
      expect([f.mode, f.memberNet], [NetMode.member, 'm1']);
    });

    testWidgets('another node (not the entry) -> no member branch', (t) async {
      await open(t, v: view(nodeState: 2), s: mnet(const MnetEntry('m1', name: '山隊', entryLast4: '99ff')));
      expect(find.byKey(const Key('node-join')), findsNothing);
    });
  });

  group('「隊員」 and 更多', () {
    testWidgets('隊員 with a network made here: the node\'s own applied network opens directly', (t) async {
      teamDepsOverride = jp.World(const [], const {}).deps;
      addTearDown(() => teamDepsOverride = null);
      await open(t, v: view(netId: 'aa11'), s: NetSnapshot(netFiles: 1, nets: [net('aa11')]));
      await t.tap(find.byKey(const Key('node-team')));
      await settle(t);
      expect(t.widget<MembersPage>(find.byType(MembersPage)).netId, 'aa11');
    });

    testWidgets('更多: 把新密碼送給節點 always (dev); 貼上隊長給的新密碼 only with a team network', (t) async {
      var a = await open(t, page: null);
      await t.pumpWidget(host(MorePage(app: a, ui: UiState(MemStore()), id: id)));
      await settle(t);
      expect(find.byKey(Key('send-key-$id')), findsOneWidget);
      expect(find.byKey(const Key('more-paste-key')), findsNothing);
      a = await open(t, s: const NetSnapshot(anyMnet: true, mnetIds: ['m1']));
      await t.pumpWidget(host(MorePage(app: a, ui: UiState(MemStore()), id: id)));
      await settle(t);
      expect(find.byKey(const Key('more-paste-key')), findsOneWidget);
    });
  });

  testWidgets('T-S5: the field build has none of it', (t) async {
    final s = NetSnapshot(
        netFiles: 1,
        nets: [net('aa11')],
        anyMnet: true,
        mnetIds: const ['m1'],
        mnets: const [MnetEntry('m1', name: '山隊', entryLast4: '7d2c')]);
    final a = await open(t, dev: false, s: s, hint: const UpdateHint(line: hintLine, button: true));
    expect(find.byKey(const Key('node-hint')), findsNothing);
    expect(find.byKey(const Key('node-team')), findsNothing);
    expect(find.byKey(const Key('node-join')), findsNothing, reason: 'nodeState 2: no leader branch either');
    await t.pumpWidget(host(MorePage(app: a, ui: UiState(MemStore()), id: id)));
    await settle(t);
    expect(find.byKey(Key('send-key-$id')), findsNothing);
    expect(find.byKey(const Key('more-paste-key')), findsNothing);
    expect(find.text(Btn.more), findsWidgets);
  });
}
