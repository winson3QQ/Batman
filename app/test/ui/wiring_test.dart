// #329 PR 3 step 7: the entries of the new network pages. Home row 6 (建立網路 / 加入網路 -> 4.1; a team network
// only -> the older console, D3), the 「節點加入網路沒有做完」 todo (-> 4.1 with that network), and the node page's
// network group (加入網路 / 檢查網路, never 建立網路: §2.4, D8).
import 'package:batman_app/src/flows/net_index.dart';
import 'package:batman_app/src/nodelink/app_link.dart';
import 'package:batman_app/src/nodelink/core.dart';
import 'package:batman_app/src/rust/api/owner.dart' show MemberView, NetView;
import 'package:batman_app/src/rust/frb_generated.dart';
import 'package:batman_app/ui/home_page.dart';
import 'package:batman_app/ui/net_pages.dart';
import 'package:batman_app/ui/node_page.dart';
import 'package:batman_app/ui/ui_state.dart';
import 'package:batman_app/ui/widgets.dart' show Btn;
import 'package:flutter/material.dart' hide Page;
import 'package:flutter_test/flutter_test.dart';

import 'pages_test.dart' show FakeRust, app, host, id, keys, sv;
import 'ui_state_test.dart' show MemStore;

MemberView mem(String name, {String deviceId = '', bool joining = false, bool creator = false}) =>
    MemberView(name: name, last4: '', deviceId: deviceId, joining: joining, prevCountry: '', dacHash: '', creator: creator, approved: false);
NetEntry entry(String nid, {bool applied = true, List<MemberView> members = const []}) =>
    NetEntry(nid, NetView(netId: nid, meshId: 'bm', netName: '小隊', applied: applied, country: 'US', members: members));

void main() {
  final rust = FakeRust();
  setUpAll(() => RustLib.initMock(api: rust));

  /// The node read fresh, [nodeState] 1 = not in a network (home row 6).
  AppLink read(AppLink a, {int nodeState = 1}) {
    a.link.core.states[id]!
      ..kind = Kind.read
      ..view = 'red'
      ..readAt = a.link.now()
      ..extra = sv('red', nodeState: nodeState)
      ..last = Concl.read;
    a.link.readWall[id] = DateTime.utc(2026, 11, 16);
    return a;
  }

  Future<void> finish(WidgetTester t, AppLink a) async {
    await t.pumpWidget(const SizedBox());
    await a.link.dispose();
    await t.pump(const Duration(seconds: 10));
    AppLink.forgetForTest();
  }

  Future<AppLink> home(WidgetTester t, NetSnapshot s) async {
    final a = read(app());
    a.nets.setForTest(s);
    await t.pumpWidget(host(HomePage(app: a, ui: UiState(MemStore()..ids = [id]), devTrust: true, keys: keys())));
    await t.pump();
    return a;
  }

  testWidgets('row 6, no network record: 建立網路 opens 4.1 in make mode with the node ticked', (t) async {
    final a = await home(t, const NetSnapshot());
    await t.tap(find.widgetWithText(FilledButton, Btn.makeNetwork));
    await t.pumpAndSettle();
    final f = t.widget<NetFormPage>(find.byType(NetFormPage));
    expect(f.makes, isTrue);
    expect(f.ticked, {id});
    await finish(t, a);
  });

  testWidgets('row 6, a network record: 加入網路 opens 4.1 in join mode', (t) async {
    final a = await home(t, NetSnapshot(netFiles: 1, nets: [entry('n1')]));
    await t.tap(find.widgetWithText(FilledButton, Btn.joinNetwork));
    await t.pumpAndSettle();
    expect(t.widget<NetFormPage>(find.byType(NetFormPage)).makes, isFalse);
    await finish(t, a);
  });

  testWidgets('row 6, only a team network (mnet): 加入網路 is the older console\'s member join (D3)', (t) async {
    final a = await home(t, const NetSnapshot(anyMnet: true));
    await t.tap(find.widgetWithText(FilledButton, Btn.joinNetwork));
    await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await t.pump();
    expect(find.byType(NetFormPage), findsNothing);
    expect(a.reg.current?.name, '我的節點', reason: 'the older console under its raw lease');
    await finish(t, a);
  });

  testWidgets('「節點加入網路沒有做完」: 繼續完成 opens 4.1 on that network with the todo', (t) async {
    final n = entry('q', members: [mem('node-x', deviceId: id, joining: true)]);
    final a = await home(t, NetSnapshot(netFiles: 1, nets: [n], todos: [JoinTodo(n, n.view.members.single)]));
    await t.tap(find.text(Btn.finishIt));
    await t.pumpAndSettle();
    final f = t.widget<NetFormPage>(find.byType(NetFormPage));
    expect(f.todo?.net.rel, 'net/q');
    expect(f.makes, isFalse);
    await finish(t, a);
  });

  group('node page network group (§2.4, design §5.5)', () {
    Future<AppLink> node(WidgetTester t, NetSnapshot s, {int nodeState = 1}) async {
      final a = read(app(), nodeState: nodeState);
      a.nets.setForTest(s);
      await t.pumpWidget(host(NodePage(app: a, id: id, ui: UiState(MemStore()..ids = [id]))));
      await t.pump();
      return a;
    }

    final me = 'node-${id.substring(id.length - 4)}';

    testWidgets('not in a network, the phone has one: 加入網路 -> 4.1 join mode, this node, back to its page', (t) async {
      final a = await node(t, NetSnapshot(netFiles: 1, nets: [entry('n1')]));
      expect(find.text(Btn.makeNetwork), findsNothing, reason: 'never 建立網路 on the node page');
      await t.tap(find.text(Btn.joinNetwork));
      await t.pumpAndSettle();
      final f = t.widget<NetFormPage>(find.byType(NetFormPage));
      expect((f.makes, f.back, f.backNode), (false, Page.node, id));
      expect(f.ticked, {id});
      await finish(t, a);
    });

    testWidgets('no network on the phone: no network group at all (建立網路 is the home page\'s)', (t) async {
      final a = await node(t, const NetSnapshot());
      expect(find.text(Btn.joinNetwork), findsNothing);
      expect(find.text(Btn.makeNetwork), findsNothing);
      await finish(t, a);
    });

    testWidgets('a pending network this node made: 檢查網路 -> the check page on this node', (t) async {
      final a = await node(t, NetSnapshot(netFiles: 1, nets: [entry('p1', applied: false, members: [mem(me.toUpperCase(), joining: true, creator: true)])]),
          nodeState: 2);
      await t.tap(find.text(Btn.checkNetwork));
      await t.pumpAndSettle();
      final c = t.widget<CheckNetPage>(find.byType(CheckNetPage));
      expect(c.preselect, id);
      expect(c.nets?.map((e) => e.rel), ['net/p1']);
      expect(a.reg.current, isNull, reason: 'the node is chosen; no lease before 開始');
      await finish(t, a);
    });


    testWidgets('code review A M-1 / B M2: 建立網路 on the check page opened from the node page -> 4.1 make mode', (t) async {
      final a = await node(t, NetSnapshot(netFiles: 1, nets: [entry('p1', applied: false, members: [mem(me, joining: true, creator: true)])]),
          nodeState: 2);
      await t.tap(find.text(Btn.checkNetwork));
      await t.pumpAndSettle();
      t.state<NavigatorState>(find.byType(Navigator)).pop(goMake); // the check page's 建立網路
      await t.pumpAndSettle();
      final f = t.widget<NetFormPage>(find.byType(NetFormPage));
      expect(f.makes, isTrue);
      expect(f.ticked, {id});
      expect((f.back, f.backNode), (Page.node, id));
      await finish(t, a);
    });
    testWidgets('a pending network another node made: no 檢查網路 here', (t) async {
      final a = await node(t, NetSnapshot(netFiles: 1, nets: [entry('p1', applied: false, members: [mem('node-zzzz', joining: true, creator: true)])]),
          nodeState: 2);
      expect(find.text(Btn.checkNetwork), findsNothing);
      await finish(t, a);
    });
  });
}
