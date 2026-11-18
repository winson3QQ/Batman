// #329 PR 6 D5(e)/(f), T6-13(c)/(d): the home entry 「看全隊狀態」 and the whole-team page. Sections come only from
// NodeLink.teams (faked here as a visible TeamView); fresh = the node fresh AND the team from that very read, else the
// whole section is old data with the team's own 「上次讀取 HH:MM」 and no green light. The 254 frozen layout (title, `only`
// above the cards, cards, small print, tech only under 技術資訊) and T-A9 (team content never logged) are ported here
// from the old console's StatusPageView tests (member_ui_test.dart).
import 'package:batman_app/src/flows/net_index.dart';
import 'package:batman_app/src/nodelink/app_link.dart';
import 'package:batman_app/src/nodelink/core.dart';
import 'package:batman_app/src/nodelink/node_link.dart' show TeamRead;
import 'package:batman_app/src/rust/api/owner.dart' show TeamView;
import 'package:batman_app/src/rust/frb_generated.dart';
import 'package:batman_app/ui/home_page.dart';
import 'package:batman_app/ui/team_status_page.dart';
import 'package:batman_app/ui/ui_state.dart';
import 'package:flutter/material.dart' hide Page;
import 'package:flutter_test/flutter_test.dart';

import 'pages_test.dart' show FakeRust, app, host, id, keys, sv;
import 'ui_state_test.dart' show MemStore;

const id2 = '0000000000000c4f2a7dbeef';

TeamView team(
        {String title = '全隊（僅供參考；由『我的節點』看到）',
        String only = '',
        List<String> cards = const ['🟢 『客廳』 在線 · 連線 好（約 14.9 Mbit/s） · 直接連線', '❔ 不明節點 · 最後看到 6 分鐘前\n不在你手機的名單裡（可能是新加入、隊長還沒發新名單的隊員）'],
        String note = '在線 = 這台節點最近 1 分鐘內收得到。',
        List<String> tech = const ['不明節點 …c6d3：400 秒前'],
        bool visible = true}) =>
    TeamView(visible: visible, title: title, only: only, cards: cards, note: note, tech: tech);

/// [i] read just now (fresh) with its team from that read; [teamAt] another readAt makes the team an older one.
void readWith(AppLink a, String i, TeamView v, {int? teamAt, DateTime? teamWall}) {
  final now = a.link.now();
  final c = a.link.core;
  c.states[i]!
    ..kind = Kind.read
    ..view = 'green'
    ..readAt = now
    ..extra = sv('green')
    ..last = Concl.read;
  a.link.readWall[i] = DateTime(2026, 11, 18, 9, 7, 30);
  a.link.teams[i] = TeamRead('aa', v, teamAt ?? now, teamWall ?? DateTime(2026, 11, 18, 9, 7, 30));
}

void main() {
  setUpAll(() => RustLib.initMock(api: FakeRust()));

  Future<AppLink> page(WidgetTester t, void Function(AppLink a) set) async {
    t.view.physicalSize = const Size(1080, 5000);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    final a = app();
    set(a);
    await t.pumpWidget(host(TeamPage(app: a, ui: UiState(MemStore()..ids = [id]))));
    await t.pump();
    return a;
  }

  Future<void> finish(WidgetTester t, AppLink a) async {
    await t.pumpWidget(const SizedBox());
    await a.link.dispose();
    await t.pump(const Duration(seconds: 10));
    AppLink.forgetForTest();
  }

  double y(WidgetTester t, Finder f) => t.getTopLeft(f.first).dy;

  testWidgets('the page reads like home (Page.team); one section: Rust title as is, only above cards, cards, note; '
      'tech only under 技術資訊', (t) async {
    final a = await page(t, (a) => readWith(a, id, team(only: '這台目前沒連上網路，下面是最後看到的狀態')));
    expect(a.link.core.page, Page.team);
    expect(find.byKey(Key('teamSection-$id')), findsOneWidget);
    expect(find.text('全隊（僅供參考；由『我的節點』看到）'), findsOneWidget, reason: 'the title is Rust\'s, nothing added to it');
    expect(find.text('讀取於 09:07:30'), findsOneWidget);
    expect(find.byKey(const Key('teamCard')), findsNWidgets(2));
    expect(find.text('🟢 『客廳』 在線 · 連線 好（約 14.9 Mbit/s） · 直接連線'), findsOneWidget);
    expect(find.text('不在你手機的名單裡（可能是新加入、隊長還沒發新名單的隊員）'), findsOneWidget);
    expect(y(t, find.byKey(const Key('teamTitle'))), lessThan(y(t, find.byKey(const Key('teamOnly')))));
    expect(y(t, find.byKey(const Key('teamOnly'))), lessThan(y(t, find.byKey(const Key('teamCard')))),
        reason: '254 v2.4 §6 (b): the line above the cards');
    expect(y(t, find.byKey(const Key('teamCard')).last), lessThan(y(t, find.byKey(const Key('teamNote')))));
    expect(find.byKey(const Key('teamCardUnk')), findsNothing);
    expect(find.textContaining('…c6d3'), findsNothing, reason: 'the tail only inside the collapsed list');
    await t.tap(find.text('技術資訊（給維修人員看）'));
    await t.pump();
    expect(find.textContaining('…c6d3'), findsOneWidget);
    expect(y(t, find.byKey(const Key('teamTech'))), greaterThan(y(t, find.byKey(const Key('teamNote')))));
    await finish(t, a);
  });

  // review pr6 B-4: Rust's `only` and every card line go through SayLine (a technical part under 技術資訊, never raw
  // U+001E / U+001F). Negative control: `only` or a card line back to Text(...) -> the raw characters FAIL.
  testWidgets('B-4: a technical part in only / a card is split, never shown raw', (t) async {
    final a = await page(
        t,
        (a) => readWith(
            a,
            id,
            team(
                only: '這台沒連上\u001e代碼 4\u001f',
                cards: const ['🟢 『客廳』 在線\u001e原因 2\u001f', '❔ 不明節點\n不在名單裡\u001e代碼 5\u001f'],
                tech: const [])));
    final shown = t.widgetList<Text>(find.byType(Text)).map((w) => w.data ?? '').toList();
    for (final s in shown) {
      expect(s.contains('\u001e') || s.contains('\u001f'), isFalse, reason: 'raw control character on screen: $s');
    }
    expect(find.text('這台沒連上'), findsOneWidget);
    expect(find.text('🟢 『客廳』 在線'), findsOneWidget);
    expect(find.text('不在名單裡'), findsOneWidget);
    expect(find.text('技術資訊（給維修人員看）'), findsNWidgets(3), reason: 'one fold per line with a technical part');
    await finish(t, a);
  });

  testWidgets('one section per own node, never merged: two nodes of one network -> two sections, each its title',
      (t) async {
    final a = await page(t, (a) {
      a.link.core.setRecords(const [Rec(id, 1), Rec(id2, 1)]);
      readWith(a, id, team(title: '全隊（僅供參考；由『客廳』看到）'));
      readWith(a, id2, team(title: '全隊（僅供參考；由『書房』看到）', cards: const ['⚪ 『客廳』 離線 · 最後看到 4 分鐘前']));
    });
    expect(find.byKey(Key('teamSection-$id')), findsOneWidget);
    expect(find.byKey(Key('teamSection-$id2')), findsOneWidget);
    expect(find.text('全隊（僅供參考；由『客廳』看到）'), findsOneWidget);
    expect(find.text('全隊（僅供參考；由『書房』看到）'), findsOneWidget);
    await finish(t, a);
  });

  testWidgets('the team is from an older read than the state (round 2\'s record step late / cancelled): the whole '
      'section is old data, its own 上次讀取, no green light', (t) async {
    final a = await page(t, (a) => readWith(a, id, team(), teamAt: -5000, teamWall: DateTime(2026, 11, 18, 8, 59, 1)));
    expect(a.link.core.fresh(id, a.link.now()), isTrue, reason: 'the node itself is fresh');
    expect(find.text('上次讀取 08:59'), findsOneWidget, reason: 'the team\'s own wall time, not the state\'s 09:07');
    expect(find.text('讀取於 09:07:30'), findsNothing);
    expect(find.byKey(const Key('teamCardUnk')), findsNWidgets(2));
    expect(find.textContaining('🟢'), findsNothing, reason: 'no stale green');
    await finish(t, a);
  });

  testWidgets('back from the background (core not fresh, same read): old data', (t) async {
    final a = await page(t, (a) {
      readWith(a, id, team());
      a.link.core.background(a.link.now());
    });
    expect(find.text('上次讀取 09:07'), findsOneWidget);
    expect(find.textContaining('🟢'), findsNothing);
    await finish(t, a);
  });

  testWidgets('no visible section (none read, hidden, or the record gone) -> 全隊狀態目前不可用; 重新整理 = link.refresh',
      (t) async {
    final a = await page(t, (a) {
      readWith(a, id, team(visible: false));
      a.link.teams['gone'] = TeamRead('aa', team(), 0, DateTime(2026)); // not a record of this phone
    });
    expect(find.text(teamUnavailable), findsOneWidget);
    expect(find.byKey(const Key('teamTitle')), findsNothing);
    a.link.core.notY['zz'] = {id}; // refresh clears the 「不是」 memos first (core.refresh)
    await t.tap(find.text('重新整理'));
    await t.pump();
    expect(a.link.core.notY.values.every((v) => v.isEmpty), isTrue);
    await finish(t, a);
  });

  testWidgets('重新整理 above the sections calls link.refresh', (t) async {
    final a = await page(t, (a) => readWith(a, id, team()));
    a.link.core.notY['zz'] = {id};
    await t.tap(find.byKey(const Key('teamRefresh')));
    await t.pump();
    expect(a.link.core.notY.values.every((v) => v.isEmpty), isTrue);
    await finish(t, a);
  });

  // 254-app-team-status T-A9, ported from member_ui_test (the old console's team section): nothing of a team section
  // reaches any log — logcat (debugPrint: NodeLink's trace and the app's lines), core.log (the text log's source). A
  // sentinel address sits in every team string. Negative control: the page printing a card -> FAIL.
  group('T-A9 the team page and the logs', () {
    const colon = 'de:ad:be:ef:00:01';
    final forms = [colon, colon.toUpperCase(), colon.replaceAll(':', ''), colon.replaceAll(':', '').toUpperCase()];
    final sentinel = team(
        title: '全隊（僅供參考；由『$colon』看到）',
        only: 'only $colon',
        cards: ['🟢 『$colon』 在線', '❔ 不明節點 · ${colon.toUpperCase()}\n${colon.replaceAll(':', '')}'],
        note: 'note $colon',
        tech: ['不明節點 …0001：3 秒前 ${colon.replaceAll(':', '').toUpperCase()}']);
    bool leaks(Iterable<String> ls) => ls.any((l) => forms.any(l.contains));

    testWidgets('open, expand, refresh, background / foreground: no log line carries it', (t) async {
      final lines = <String>[];
      final old = debugPrint;
      debugPrint = (String? m, {int? wrapWidth}) => lines.add(m ?? '');
      try {
        final a = await page(t, (a) => readWith(a, id, sentinel));
        expect(find.text('only $colon'), findsOneWidget, reason: 'the sentinel is on screen');
        await t.tap(find.text('技術資訊（給維修人員看）'));
        await t.pump();
        await t.tap(find.byKey(const Key('teamRefresh')));
        await t.pump();
        a.link.background();
        a.link.foreground();
        await t.pump();
        a.link.core.log.add('a line'); // the scan must see something in each log
        lines.add('BMAPP marker');
        expect(leaks(lines), isFalse, reason: lines.join('\n'));
        expect(leaks(a.link.core.log), isFalse, reason: a.link.core.log.join('\n'));
        expect(leaks(a.link.core.log.map((l) => l)), isFalse);
        await finish(t, a);
      } finally {
        debugPrint = old;
      }
    });

    test('the scan catches a leaked address (negative control of the scan)', () {
      expect(leaks(['team ${sentinel.cards.first}']), isTrue);
    });
  });

  group('T6-13(c) the home entry', () {
    Future<AppLink> home(WidgetTester t, void Function(AppLink a) set, {bool dev = false}) async {
      t.view.physicalSize = const Size(1080, 5000);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.reset);
      final a = app();
      a.nets.setForTest(const NetSnapshot());
      set(a);
      await t.pumpWidget(host(HomePage(app: a, ui: UiState(MemStore()..ids = [id]), devTrust: dev, keys: keys())));
      await t.pump();
      return a;
    }

    testWidgets('no team section anywhere (version N) -> no entry', (t) async {
      final a = await home(t, (a) {});
      expect(find.text('看全隊狀態'), findsNothing);
      await finish(t, a);
    });

    testWidgets('a section that is not visible -> no entry', (t) async {
      final a = await home(t, (a) => readWith(a, id, team(visible: false)));
      expect(find.text('看全隊狀態'), findsNothing);
      await finish(t, a);
    });

    testWidgets('any visible section (even with no netId, field build) -> 看全隊狀態, which opens the team page; back '
        'home the scheduler page is home again', (t) async {
      final a = await home(t, (a) {
        readWith(a, id, team());
        a.link.teams[id] = TeamRead('', a.link.teams[id]!.view, a.link.teams[id]!.readAt, a.link.teams[id]!.readWall);
      });
      expect(find.text('看全隊狀態'), findsOneWidget);
      await t.tap(find.text('看全隊狀態'));
      await t.pumpAndSettle();
      expect(find.byType(TeamPage), findsOneWidget);
      expect(a.link.core.page, Page.team);
      Navigator.of(t.element(find.byType(TeamPage))).pop();
      await t.pumpAndSettle();
      expect(a.link.core.page, Page.home);
      await finish(t, a);
    });
  });
}
