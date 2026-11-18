// #329 補測 A（T9 / Q1，2026-11-18）: every board the app has, rendered at 412×915, text scale 1.0, light and dark,
// with the same fake data as layout_test.dart (T-C2) plus the flow pages it does not open (3.1, 3.2, 3.5, 3.6, 4.1
// make mode, 4.x working / done / failed, 檢查網路, 離開網路, 選網路, 9.x sending). Each board: no overflow (an overflow
// is a test exception) and, when BOARDS_OUT is set, one PNG ($BOARDS_OUT/<board>_<light|dark>.png) for the user's
// board-by-board look (design T9: the PNGs are not compared; pass / fail is the widget checks).
// The boards of retest_p_layout_test.dart (1.1, 2.4, welcome 2 / 3, dialogs, long sentences) are in
// retest_s_boards_p_test.dart (they need another fake Rust).
import 'dart:async';

import 'package:batman_app/claim.dart';
import 'package:batman_app/secure_screen.dart' show secureChannel;
import 'package:batman_app/src/flows/net_index.dart';
import 'package:batman_app/src/flows/net_run.dart';
import 'package:batman_app/src/flows/offline_op.dart' show offlineTodoText;
import 'package:batman_app/src/nodelink/app_link.dart';
import 'package:batman_app/src/nodelink/core.dart';
import 'package:batman_app/src/nodelink/node_link.dart' show TeamRead;
import 'package:batman_app/src/rust/api/member.dart' show JoinReqView;
import 'package:batman_app/src/rust/api/owner.dart' show StatusView, TeamView;
import 'package:batman_app/src/rust/api/rekey.dart' show OwnNodeView, RecipientView;
import 'package:batman_app/src/rust/api/swupdate.dart';
import 'package:batman_app/src/rust/frb_generated.dart';
import 'package:batman_app/swupdate.dart' show SwFlow, SwHold, SwUpdatePage, swChannel, swPrepared;
import 'package:batman_app/ui/add_pages.dart';
import 'package:batman_app/ui/home_page.dart';
import 'package:batman_app/ui/intro_pages.dart';
import 'package:batman_app/ui/join_choice.dart' show NetMode;
import 'package:batman_app/ui/join_pages.dart';
import 'package:batman_app/ui/more_pages.dart' show LeavePage, MorePage;
import 'package:batman_app/ui/net_pages.dart';
import 'package:batman_app/ui/node_page.dart';
import 'package:batman_app/ui/remove_pages.dart';
import 'package:batman_app/ui/settings_page.dart';
import 'package:batman_app/ui/settings_pages.dart' show CountryPage, WifiPage;
import 'package:batman_app/ui/team_deps.dart' show teamDepsOverride;
import 'package:batman_app/ui/team_hub.dart';
import 'package:batman_app/ui/team_pages.dart';
import 'package:batman_app/ui/team_status_page.dart' show TeamPage;
import 'package:batman_app/ui/theme.dart';
import 'package:batman_app/ui/ui_state.dart';
import 'package:batman_app/ui/widgets.dart' show Btn, Look, LookStyle;
import 'package:flutter/material.dart' hide Page;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'flows/net_run_test.dart' show World, ans;
import 'retest_s_shot.dart';
import 'support/a11y.dart';
import 'support/font_levels.dart';
import 'ui/layout_test.dart' as lt show app;
import 'ui/layout_test.dart' show busy, id, keys, sv;
import 'ui/team_pages_test.dart' as tp;
import 'ui/ui_state_test.dart' show MemStore;

SwAction _sw({SwKind kind = SwKind.show_, String text = '', String note = '', int percent = -1, List<SwButton> buttons = const []}) => SwAction(
    kind: kind,
    waitMs: BigInt.zero,
    note: note,
    text: text,
    tech: 'phase 2',
    percent: percent,
    buttons: buttons,
    ip: '',
    port: 0,
    bearerHex: '',
    size: BigInt.zero,
    payload: 0,
    uploading: false);

class _Flow implements SwFlow {
  @override
  SwAction start() => SwAction(
      kind: SwKind.send, waitMs: BigInt.one, note: '', text: '', tech: '', percent: -1, buttons: const [], ip: '', port: 0, bearerHex: '', size: BigInt.zero, payload: 0, uploading: false);
  @override
  dynamic noSuchMethod(Invocation i) => throw UnimplementedError('${i.memberName}');
}

/// The AppLinks this board made (disposed after it: their NodeLink timers).
final made = <AppLink>[];
AppLink app(StatusView? v) {
  final a = lt.app(v)..devTrust = true; // the dev build: the only one with the team pages (F14)
  made.add(a);
  return a;
}


/// #329 PR 6 D5(f): an app whose node was read with a visible team section (version N never shows one: faked here);
/// [fresh] false = the team is from an older read than the state.
AppLink _teamApp({required bool fresh}) {
  final a = app(sv('green'));
  final at = a.link.core.states[id]!.readAt!;
  a.link.teams[id] = TeamRead(
      'nn',
      const TeamView(
          visible: true,
          title: '全隊（僅供參考；由『客廳』看到）',
          only: '這台目前沒連上網路，下面是最後看到的狀態',
          cards: [
            '🟢 『書房』 在線 · 連線 好（約 14.9 Mbit/s） · 直接連線',
            '⚪ 『王小明的節點』 離線 · 最後看到 4 分鐘前',
            '❔ 不明節點 · 最後看到 6 分鐘前\n不在你手機的名單裡（可能是新加入、隊長還沒發新名單的隊員）',
          ],
          note: '在線 = 這台節點最近 1 分鐘內收得到。離線不一定是關機，也可能是太遠或被擋住。節點重開後『最後看到』會歸零。名稱僅供參考：有網路密碼的人可以假冒別台。',
          tech: ['不明節點 …c6d3：400 秒前']),
      fresh ? at : at - 120000,
      DateTime(2026, 11, 16, 1, 28));
  return a;
}

class _Rust extends tp.LeadRust {
  @override
  List<String> crateApiOwnerLeaveConfirmText(
          {required String last4, required String netId, required bool adminApplied, required bool memberEntry}) =>
      ['要讓節點 …$last4 離開隊伍網路嗎？', '離開後這台的 HaLow 無線電會關閉。'];
}

class B {
  const B(this.build, {this.act, this.check});
  final Widget Function(UiState ui) build;
  final Future<void> Function(WidgetTester t)? act;

  /// #329 PR 6 T6-11: what the board must show (after [act])
  final void Function(WidgetTester t)? check;
}

/// #329 PR 6 T6-11: the board's primary buttons (their words), and whether a widget is in the scrolling content (a
/// page's main action belongs in the foot, at the bottom: 7.4 / 7.5 / 7.8).
List<String> primaries() => [
      for (final e in find.byType(FilledButton).evaluate())
        if ((e.widget as FilledButton).style?.backgroundColor?.resolve({}) != BatTheme.light.danger &&
            (e.widget as FilledButton).style?.backgroundColor?.resolve({}) != BatTheme.dark.danger)
          ((e.widget as FilledButton).child as Row).children.whereType<Flexible>().map((f) => (f.child as Text).data).join()
    ];
bool inContent(Finder f) => find.descendant(of: find.byType(ListView), matching: f).evaluate().isNotEmpty;

Future<void> settle(WidgetTester t) async {
  for (var i = 0; i < 6; i++) {
    await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
    await t.pump(const Duration(milliseconds: 200));
  }
}

/// 4.1 make mode for [id] whose 開始 runs [w]; [gate] holds the login (the run stays 「working」 while it is open).
Widget makeForm(World w, {Completer<void>? gate}) {
  final a = app(sv('red', nodeState: 1));
  a.nets.setForTest(const NetSnapshot());
  return NetFormPage(
    app: a,
    ui: UiState(MemStore()..ids = [id]),
    makes: true,
    ticked: const {id},
    compute: () async => const NetSnapshot(),
    runFlow: (l, go, _, _, _) {
      final d = w.deps;
      return NetRun(
          FlowDeps(
            login: (i, {bool clearNotY = false}) async {
              if (gate != null) await gate.future;
              return d.login(i, clearNotY: clearNotY);
            },
            console: d.console,
            applied: d.applied,
            blocked: d.blocked,
            leaseValid: () => l.valid,
          ),
          ids: const [id],
          makes: true,
          askGoOn: go);
    },
  );
}

Future<void> start(WidgetTester t) async {
  await t.tap(find.widgetWithText(FilledButton, Btn.start));
  await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
  await t.pump();
  await t.pump(const Duration(milliseconds: 400));
}

void main() {
  final rust = _Rust()
    ..people = [
      tp.person('OWNERME', '隊長', 'ffff0000', self: true, nodes: [tp.pnode('7d2c', 'd1')]),
      tp.person('OWNERBOB', '王小明', 'aaaa1111', nodes: [tp.pnode('bb02', 'd2', state: 'joining')]),
      tp.person('OWNERBOB2', '王小明', 'aaaa1111'),
    ]
    ..recipients = [const RecipientView(owner: 'OWNERBOB', fpr: 'aaaa1111', name: '王小明', nodes: ['bb02'], note: '')]
    ..own = [const OwnNodeView(deviceId: id, dacHash: 'd1')];
  setUpAll(() async {
    RustLib.initMock(api: rust);
    await loadFonts();
    // ignore: avoid_print
    print('retest-s boards: fonts ${loadedFonts.isEmpty ? 'NONE (box font)' : loadedFonts.join(', ')}');
  });
  var dev = true;
  setUp(() {
    final m = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    m.setMockMethodCallHandler(secureChannel, (c) async => true);
    m.setMockMethodCallHandler(swChannel, (c) async => null);
    m.setMockMethodCallHandler(const MethodChannel('dev.batman/platform'),
        (c) async => switch (c.method) { 'devTrust' => dev, 'filesDir' => '/x', _ => null });
    teamDepsOverride = tp.leader(const [id], const {id: 'nn'}).deps; // with a net/nn record (team_pages_test)
  });
  tearDown(() => teamDepsOverride = null);
  final people = rust.people;
  const jr = JoinReqView(
      sas: '4821', name: '王小明', deviceSuffix: 'BB02', replacesApproved: false, joinreqHash: 'h', previous: '', updateFirst: true);
  const code = 'A2010203040506070809A0B0C0D0E0F0A2010203040506070809A0B0C0D0E0F0';
  // #329 PR 7 §4: a new World per board (one script answers once: the dark board got the generic 「操作沒有成功」)
  World failed() => World()..script('make', [ans('[REQ_FAIL] 建立網路沒有成功：節點拒絕\u001e代碼 11，原因 14\u001f') /* #329 PR 6 D7: Rust's shape */]);
  final gate = Completer<void>();

  // file name (ASCII) -> board
  final boards = <String, B>{
    // layout_test.dart's pages (the same fake data)
    'home_all_fine': B((ui) => HomePage(app: app(sv('green')), ui: ui, devTrust: true, keys: keys()), check: (t) {
      // #329 PR 6 T6-11: the tip card's 「知道了」 is a text button, as the todo banners' (was an outlined one)
      expect(find.widgetWithText(TextButton, Btn.gotIt), findsOneWidget);
      expect(find.widgetWithText(OutlinedButton, Btn.gotIt), findsNothing);
    }),
    'home_not_in_network': B((ui) => HomePage(app: app(sv('red', nodeState: 1)), ui: ui, devTrust: true, keys: keys())),
    'home_not_read_yet': B((ui) => HomePage(app: app(null), ui: ui, devTrust: false, keys: keys())),
    'home_todo_banner': B((ui) {
      final a = app(sv('green'));
      a.reg.unsavedTodos.add('上一個操作可能沒有存完：新增節點');
      return HomePage(app: a, ui: ui, devTrust: true, keys: keys());
    }),
    'home_offline_todo_banner': B((ui) {
      final a = app(sv('green'));
      a.reg.unsavedTodos.add('上一個操作可能沒有存完：移除隊員');
      a.reg.unsavedText['上一個操作可能沒有存完：移除隊員'] = offlineTodoText('移除隊員');
      return HomePage(app: a, ui: ui, devTrust: true, keys: keys());
    }),
    'home_bluetooth_off': B((ui) {
      final a = app(sv('green'));
      a.link.radio(bluetooth: false);
      return HomePage(app: a, ui: ui, devTrust: true, keys: keys());
    }),
    'home_identity_mismatch': B((ui) {
      final a = app(null);
      a.link.core.states[id]!
        ..kind = Kind.unreachable
        ..why = Why.identity;
      return HomePage(app: a, ui: ui, devTrust: true, keys: keys());
    }),
    'home_unreachable': B((ui) {
      final a = app(null);
      a.link.core.states[id]!
        ..kind = Kind.unreachable
        ..why = Why.notFound
        ..last = Concl.notFound;
      return HomePage(app: a, ui: ui, devTrust: true, keys: keys());
    }),
    'home_no_node': B((ui) {
      final a = app(null);
      a.link.core.setRecords(const []);
      return HomePage(app: a, ui: ui, devTrust: true, keys: keys());
    }, check: (t) {
      // #329 PR 6 T6-11 (home_no_node): one 「新增節點」 (the status area's), no 「可以做的事」 copy of it
      expect(find.text(Btn.addNode), findsOneWidget);
      expect(find.text('可以做的事'), findsNothing);
    }),
    'node_page_red': B((ui) => NodePage(app: app(sv('red')), id: id, ui: ui)),
    'node_page_green': B((ui) => NodePage(app: app(sv('green')), id: id, ui: ui)),
    // every group of the node page (網路 / 隊員 show only with a network record on the phone, 隊員 in a dev build)
    'node_page_all_groups': B((ui) {
      final a = app(sv('yellow', nodeState: 1))..devTrust = true;
      a.nets.setForTest(const NetSnapshot(netFiles: 1));
      return NodePage(app: a, id: id, ui: ui);
    }),
    'node_page_identity': B((ui) {
      final a = app(null);
      a.link.core.states[id]!
        ..kind = Kind.unreachable
        ..why = Why.identity;
      return NodePage(app: a, id: id, ui: ui);
    }),
    'settings_dev': B((ui) => SettingsPage(app: app(null), ui: ui, devTrust: true)),
    'settings_field': B((ui) => SettingsPage(app: app(null), ui: ui, devTrust: false)),
    'about': B((ui) => const AboutPage()),
    'intro_1': B((ui) => IntroPages(onDone: () {})),
    'permissions': B((ui) => PermissionsPage(ask: () async => false)),
    'more': B((ui) => MorePage(app: app(sv('green', canLeave: true)), ui: ui, id: id)),
    'phone_wifi': B((ui) => WifiPage(app: app(sv('green')), ui: ui, id: id, deps: busy)),
    'country': B((ui) => CountryPage(app: app(sv('red', nodeState: 1)), ui: ui, id: id, deps: busy),
        // #329 PR 6 T6-11: one colon (was 「讀不到目前的國家：另一個操作還在進行：建立網路」)
        check: (t) => expect(find.text('讀不到目前的國家（另一個操作還在進行：建立網路）'), findsOneWidget)),
    'help': B((ui) => const HelpPage()),
    'phone_lost': B((ui) => const PhoneLostPage()),
    'swupdate_prepared': B((ui) => SwUpdatePage(
        hold: SwHold(_Flow()),
        ask: (_) async => _sw(
            text: '更新已經準備好', note: '套用後節點會重開，大約 2 分鐘連不到。', buttons: const [SwButton.apply, SwButton.abandon]),
        onSetAp: () {}), check: (t) {
      // #329 PR 6 T6-11 (swupdate): a status area (prepared = ok) on top, the fold named as everywhere
      expect(find.descendant(of: find.byKey(const Key('sw-hero')), matching: find.text(swPrepared)), findsOneWidget);
      expect(find.descendant(of: find.byKey(const Key('sw-hero')), matching: find.byIcon(Look.ok.icon)), findsOneWidget);
      expect(find.text('技術資訊（給維修人員看）'), findsOneWidget);
      expect(find.text('技術資訊'), findsNothing);
    }),
    'swupdate_writing': B((ui) => SwUpdatePage(
        hold: SwHold(_Flow()),
        ask: (_) async => _sw(text: '正在寫入更新', note: '請留在這個畫面。', percent: 40),
        onSetAp: () {})),
    // #329 PR 6 P2-5 (9.2): 「開始傳送」 — danger, with what it starts written next to it (T_CONFIRM, swupd.rs:66)
    '9.2_start': B((ui) => SwUpdatePage(
        hold: SwHold(_Flow()),
        ask: (_) async => _sw(
            text: '更新檔已準備好傳送',
            note: '開始傳送後請留在這個畫面，不要離開、不要關螢幕。寫入開始後不能取消；寫好後舊版本的退路已失效。',
            buttons: const [SwButton.start, SwButton.cancel]),
        onSetAp: () {}), check: (t) {
      final b = t.widget<FilledButton>(find.widgetWithText(FilledButton, '開始傳送'));
      expect(b.style?.backgroundColor?.resolve({}), anyOf(BatTheme.light.danger, BatTheme.dark.danger), reason: 'danger');
      expect(primaries(), isEmpty, reason: 'no plain primary next to it');
      expect(find.textContaining('寫入開始後不能取消'), findsOneWidget, reason: 'the consequence is written');
      expect(find.widgetWithText(TextButton, '取消'), findsOneWidget);
    }),
    // #329 PR 7 §4 (9.x): the update over — done (swupd.rs:1084), reverted (T_REVERTED, :1086); the hero says which
    '9.x_done': B((ui) => SwUpdatePage(
        hold: SwHold(_Flow()), ask: (_) async => _sw(kind: SwKind.done, text: '更新完成：1.5.14-wsl.30'), onSetAp: () {}), check: (t) {
      expect(find.descendant(of: find.byKey(const Key('sw-hero')), matching: find.byIcon(Look.ok.icon)), findsOneWidget);
      expect(find.widgetWithText(FilledButton, '關閉'), findsOneWidget);
    }),
    '9.x_reverted': B((ui) => SwUpdatePage(
        hold: SwHold(_Flow()), ask: (_) async => _sw(kind: SwKind.done, text: '新版不健康，已退回原本的版本'), onSetAp: () {}), check: (t) {
      expect(find.descendant(of: find.byKey(const Key('sw-hero')), matching: find.text('更新沒有成功，已回到原本的版本')), findsOneWidget);
      expect(find.descendant(of: find.byKey(const Key('sw-hero')), matching: find.byIcon(Look.bad.icon)), findsOneWidget);
    }),
    'team_hub': B((ui) => TeamHubPage(app: app(null), ui: ui), check: (t) {
      // #329 PR 6 T6-11 (P2-1): each side's steps numbered, in order, before 「其他」
      for (final (n, of, s) in [(1, 2, '邀請隊員'), (2, 2, '收隊員的申請'), (1, 3, '收隊長的邀請'), (2, 3, '匯入隊長的同意'), (3, 3, '讓我的節點加入隊長的網路')]) {
        expect(find.text('$n　$s'), findsOneWidget, reason: s);
        expect(find.descendant(of: find.byKey(Key('hub-$s')), matching: find.text(hubStep(n, of))), findsOneWidget, reason: s);
      }
      double y(String k) => t.getTopLeft(find.byKey(Key('hub-$k'))).dy;
      expect(y('收隊員的申請'), lessThan(y('隊員名單')));
      expect(y('讓我的節點加入隊長的網路'), lessThan(y('再顯示申請')));
    }),
    '8.1_members': B((ui) => MembersPage(app: app(sv('green')), netId: 'nn')),
    '8.2_person': B((ui) => PersonPage(app: app(sv('green')), netId: 'nn', person: people[1], all: people)),
    '8.2_me': B((ui) => PersonPage(app: app(sv('green')), netId: 'nn', person: people[0], all: people)),
    '8.3_remove': B((ui) => RemoveConfirmPage(
        app: app(sv('green')), netId: 'nn', person: people[1], owner: 'OWNERBOB', node: '', same: const ['另有同名的一組：aaaa1111'])),
    '8.4_new_secrets': B((ui) => RekeyPage(app: app(sv('green')), netId: 'nn', removal: true)),
    '7.1_invite': B((ui) => InvitePage(app: app(sv('green')), netId: 'nn')),
    '7.3_invite_code': B((ui) => InviteCodePage(app: app(sv('green')), netId: 'nn', hex: code, inPerson: false)),
    '7.4_request': B((ui) => RequestPage(app: app(sv('green')), netId: 'nn'), check: (t) {
      // #329 PR 6 T6-11: the main action at the bottom (the foot), not in the content
      expect(primaries(), [Btn.scanQr]);
      expect(inContent(find.byKey(const Key('code-scan'))), isFalse);
    }),
    '7.5_approve': B((ui) => ApprovePage(app: app(sv('green')), netId: 'nn', hex: code, jr: jr, previousOk: false), check: (t) {
      // #329 PR 6 T6-11: the main action at the bottom, above 「數字不一樣」
      expect(primaries(), [kApproveSame]);
      expect(inContent(find.byKey(const Key('sasConfirm'))), isFalse);
      expect(t.getTopLeft(find.byKey(const Key('sasConfirm'))).dy, lessThan(t.getTopLeft(find.text('數字不一樣')).dy));
    }),
    '7.6_approval_code': B((ui) => const ApprovalCodePage(hex: code, name: '王小明')),
    '7.7_mismatch': B((ui) => const MismatchPage()),
    '7.8_join_team': B((ui) => JoinTeamPage(app: app(sv('green')), ui: ui)),
    '7.9_my_request': B((ui) => MyRequestPage(app: app(sv('green')), ui: ui, netId: 'nn', hex: code, sas: '4821', renewed: true)),
    '7.10_import': B((ui) => ImportApprovalPage(app: app(sv('green')), ui: ui)),
    '8.5_new_key': B((ui) => UpdateImportPage(app: app(sv('green')), ui: ui)),
    '4.1_member_mode': B((ui) {
      final a = app(sv('green'));
      a.nets.setForTest(const NetSnapshot(
          anyMnet: true, mnetIds: ['m1'], mnets: [MnetEntry('m1', name: '山隊', entryLast4: '7d2c')]));
      return NetFormPage(app: a, ui: ui, mode: NetMode.member);
    }),
    // the flow pages layout_test does not open
    '3.1_claim_dev': B((ui) {
      dev = true;
      return const ClaimPage(key: ValueKey('dev'));
    }),
    '3.1_claim_field': B((ui) {
      dev = false;
      return const ClaimPage(key: ValueKey('field'));
    }),
    '3.2_nick': B((ui) => NickPage(app: app(sv('green')), ui: UiState(MemStore()..ids = [id]), id: id)),
    '3.5_added_no_network': B((ui) {
      final a = app(sv('red', nodeState: 1));
      a.nets.setForTest(const NetSnapshot());
      return AddedPage(app: a, ui: UiState(MemStore()..ids = [id]), id: id, devTrust: true);
    }),
    '3.6_added_two_nodes': B((ui) {
      final a = app(sv('red', nodeState: 1));
      a.link.core.setRecords(const [Rec(id, 1), Rec('other1', 1)]);
      a.nets.setForTest(const NetSnapshot());
      return AddedPage(app: a, ui: UiState(MemStore()..ids = [id, 'other1']), id: id, devTrust: true);
    }),
    '4.1_make_mode': B((ui) => makeForm(World())),
    '4.x_working': B((ui) => makeForm(World()..script('make', [ans('[NET_MADE] 網路已建立', rel: 'net/n1')]), gate: gate),
        act: start, check: (t) => expect(find.textContaining('最多 6 分鐘'), findsOneWidget)), // #329 PR 6 T6-11 (S5): the limit once, on the step's line
    '4.x_done': B((ui) => makeForm(World()..script('make', [ans('[NET_MADE] 網路已建立', rel: 'net/n1')])), act: (t) async {
      await start(t);
      await settle(t);
    }),
    '4.x_failed': B((ui) => makeForm(failed()), act: (t) async {
      await start(t);
      await settle(t);
    }, check: (t) => expect(find.text('建立網路沒有成功：節點拒絕'), findsOneWidget)),
    '4.x_check_network': B((ui) => CheckNetPage(app: app(sv('green')), ui: UiState(MemStore()..ids = [id]), preselect: id)),
    '10.3_leave': B((ui) => LeavePage(app: app(sv('green', canLeave: true)), ui: ui, id: id, deps: busy)),
    'pick_network': B((ui) {
      final a = app(sv('green'));
      return PickNetPage(app: a, title: '隊員名單', next: (id) => Text('next $id'));
    }),
    // #329 PR 6 D5(f): the whole-team page (6.1–6.3) with a visible team, fresh / old data / none; the home entry
    'team_fresh': B((ui) => TeamPage(app: _teamApp(fresh: true), ui: ui)),
    'team_old': B((ui) => TeamPage(app: _teamApp(fresh: false), ui: ui)),
    'team_none': B((ui) => TeamPage(app: app(sv('green')), ui: ui)),
    'home_team_entry': B((ui) => HomePage(app: _teamApp(fresh: true), ui: ui, devTrust: true, keys: keys())),
  };

  // #329 PR 7 T8 (b): every board also at text scale 2.0 (design §3.1 T-C2: no overflow; its checks and PNG at 1.0)
  for (final (dark, scale) in const [(false, 1.0), (true, 1.0), (false, 2.0), (true, 2.0)]) {
    for (final e in boards.entries) {
      final file = '${e.key}_${dark ? 'dark' : 'light'}';
      testWidgets('retest-s board $file${scale == 1.0 ? '' : ' ×2.0'}', (t) async {
        sizeView(t);
        final sem = t.ensureSemantics(); // #329 PR 7 §4: the guidelines read the semantics tree
        final ui = UiState(MemStore());
        await t.pumpWidget(frame(MaterialApp(
          theme: batThemeData(Brightness.light),
          darkTheme: batThemeData(Brightness.dark),
          themeMode: dark ? ThemeMode.dark : ThemeMode.light,
          debugShowCheckedModeBanner: false,
          builder: (c, child) => MediaQuery(data: MediaQuery.of(c).copyWith(textScaler: scale == 1.0 ? TextScaler.noScaling : TextScaler.linear(scale)), child: child!),
          home: e.value.build(ui),
        )));
        for (var i = 0; i < 3; i++) {
          await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
          await t.pump(const Duration(milliseconds: 100));
        }
        expect(t.takeException(), isNull, reason: 'no overflow');
        final check0 = e.value.check;
        final act = e.value.act;
        if (act != null) {
          await act(t);
          expect(t.takeException(), isNull, reason: 'no overflow after the step');
        }
        if (scale == 1.0) check0?.call(t); // the checks look at the 1.0 layout (lazily built lists)
        expectSixLevels(t);
        if (scale == 1.0) await expectA11y(t, file); // #329 PR 7 §4: 48 dp, contrast, one solid button
        if (scale == 1.0) await shoot(t, file);
        await t.pumpWidget(const SizedBox()); // the pages' timers go with them
        sem.dispose();
        for (final a in made) {
          await a.link.dispose();
        }
        made.clear();
        await t.pump(const Duration(minutes: 8)); // past a lease's 7-minute timer (4.x working)
        AppLink.forgetForTest();
        dev = true;
      });
    }
  }
}
