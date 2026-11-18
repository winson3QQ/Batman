// #329 design §9.1 T-C2 (with T-C3 and the rendered half of T-C4a): every new page at {360×640, 412×915} × text
// scale {1.0, 1.3, 2.0} × {light, dark}: no overflow (an overflow is a test exception), Android's tap-target and
// text-contrast guidelines, at most one primary (filled) button, and none of the retired words on screen.
import 'package:batman_app/key_abilities.dart';
import 'package:batman_app/src/nodelink/app_link.dart';
import 'package:batman_app/src/nodelink/core.dart';
import 'package:batman_app/src/rust/api/owner.dart' show StatusView;
import 'package:batman_app/ui/home_page.dart';
import 'package:batman_app/ui/intro_pages.dart';
import 'package:batman_app/ui/node_page.dart';
import 'package:batman_app/ui/settings_page.dart';
import 'package:batman_app/ui/theme.dart';
import 'package:batman_app/ui/ui_state.dart';
import 'package:batman_app/ui/more_pages.dart' show MorePage;
import 'package:batman_app/ui/settings_pages.dart' show CountryPage, WifiPage;
import 'package:batman_app/src/flows/op_session.dart' show OpDeps;
import 'package:batman_app/src/flows/offline_op.dart' show offlineTodoText;
import 'package:batman_app/src/rust/api/swupdate.dart';
import 'package:batman_app/swupdate.dart' show SwFlow, SwHold, SwUpdatePage;
import 'package:batman_app/secure_screen.dart' show secureChannel;
import 'package:batman_app/src/flows/net_index.dart';
import 'package:batman_app/src/rust/api/member.dart' show JoinReqView;
import 'package:batman_app/src/rust/api/rekey.dart' show OwnNodeView, RecipientView;
import 'package:batman_app/src/rust/frb_generated.dart';
import 'package:batman_app/ui/join_choice.dart' show NetMode;
import 'package:batman_app/ui/join_pages.dart';
import 'package:batman_app/ui/net_pages.dart' show NetFormPage;
import 'package:batman_app/ui/remove_pages.dart';
import 'package:batman_app/ui/team_deps.dart' show teamDepsOverride;
import 'package:batman_app/ui/team_hub.dart';
import 'package:batman_app/ui/team_pages.dart';
import 'package:flutter/material.dart' hide Page;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../nodelink/app_link_test.dart' show StatusBle;
import 'join_pages_test.dart' as jp;
import 'team_pages_test.dart' as tp;
import 'ui_state_test.dart' show MemStore;
import '../support/font_levels.dart';

const id = '0000000000000c4f2a7d2c';

/// rust/batman-proto/src/statuspage.rs S9C, word for word (a red node in a network that has not linked to the others).
const kRedS9C = '還沒連上其他隊員 — 請確認隊員的節點已開機、在附近；等一分鐘再按「重新整理」，仍然如此請重新開機；仍然如此請找維修人員';

StatusView sv(String color, {int nodeState = 2, bool canLeave = false}) => StatusView(
    color: color,
    row: '3',
    // #329 PR 7 (p1p2-check node_page_red): a red node in a network says what Rust says (statuspage.rs S9C: the reason
    // and its next step), not an invented 「沒有連上隊伍網路」 without one
    sentence: color == 'green' ? '已連上隊伍網路' : (nodeState == 1 ? '沒有連上隊伍網路' : kRedS9C),
    lagNote: '',
    warning: '',
    nodeState: nodeState,
    netId: 'ab12',
    version: '1.5.14',
    tech: const ['頻道：42'],
    fresh: true,
    rateNote: '',
    unfinished: '',
    unfinishedUnderVerdict: false,
    canLeave: canLeave);

KeyAbilities keys() => KeyAbilities.from({
      'RECORD_AES': 1,
      'OWNER_SIGN': 1,
      'ADMIN_SIGN': 1,
      'OWNER_ENC': 1,
      'appUsable': true,
      'claim': true,
      'login': true,
      'recover': true,
      'makeNetwork': true,
      'softOwnerEnc': false,
    });

/// An AppLink with one node record, read now with [view] (null = not read).
AppLink app(StatusView? view) {
  AppLink.forgetForTest();
  final a = AppLink.create(platform: const MethodChannel('dev.batman/platform'), filesDir: '/x', ble: StatusBle());
  final c = a.link.core;
  c.setRecords(const [Rec(id, 1)]);
  if (view != null) {
    c.states[id]!
      ..kind = Kind.read
      ..view = view.color
      ..readAt = a.link.now()
      ..extra = view
      ..last = Concl.read;
    a.link.readWall[id] = DateTime(2026, 11, 16, 1, 30);
  }
  return a;
}

final retired = RegExp(r'網主|末四碼|管理者(?!金鑰)|成員|(?<![A-Za-z_])SAS(?![A-Za-z_])|StrongBox|ownerEnc|#\d');

/// #329 PR 4: a session that is always taken (no login is tried in a layout test)
final busy = OpDeps(
    acquire: (_) async => null,
    busyName: () => '建立網路',
    login: (_, _) => throw StateError('no login'),
    console: (_, _) => throw StateError('no console'),
    keepScreen: (_) async {});

final _ready = SwAction(
    kind: SwKind.show_,
    waitMs: BigInt.zero,
    note: '套用後節點會重開，大約 2 分鐘連不到。',
    text: '更新已經準備好',
    tech: 'phase 2',
    percent: -1,
    buttons: const [SwButton.apply, SwButton.abandon],
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

void main() {
  // #329 PR 5: the team pages read through TeamDeps (join_pages_test's fakes) and Rust's pure functions (faked)
  final rust = tp.LeadRust()
    ..people = [
      tp.person('OWNERME', '隊長', 'ffff0000', self: true, nodes: [tp.pnode('7d2c', 'd1')]),
      tp.person('OWNERBOB', '王小明', 'aaaa1111', nodes: [tp.pnode('bb02', 'd2', state: 'joining')]),
      tp.person('OWNERBOB2', '王小明', 'aaaa1111'),
    ]
    ..recipients = [const RecipientView(owner: 'OWNERBOB', fpr: 'aaaa1111', name: '王小明', nodes: ['bb02'], note: '')]
    ..own = [const OwnNodeView(deviceId: id, dacHash: 'd1')];
  setUpAll(() => RustLib.initMock(api: rust));
  setUp(() {
    final m = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    m.setMockMethodCallHandler(secureChannel, (c) async => true);
    m.setMockMethodCallHandler(const MethodChannel('dev.batman/platform'), (c) async => null);
    teamDepsOverride = jp.World(const [id], const {id: 'nn'}).deps;
  });
  tearDown(() => teamDepsOverride = null);
  final people = rust.people;
  const jr = JoinReqView(
      sas: '4821', name: '王小明', deviceSuffix: 'BB02', replacesApproved: false, joinreqHash: 'h', previous: '', updateFirst: true);
  const code = 'A2010203040506070809A0B0C0D0E0F0A2010203040506070809A0B0C0D0E0F0';
  final pages = <String, Widget Function(UiState ui)>{
    'home, all fine': (ui) => HomePage(app: app(sv('green')), ui: ui, devTrust: true, keys: keys()),
    'home, not in a network': (ui) => HomePage(app: app(sv('red', nodeState: 1)), ui: ui, devTrust: true, keys: keys()),
    'home, not read yet': (ui) => HomePage(app: app(null), ui: ui, devTrust: false, keys: keys()),
    'home, a to-do banner': (ui) {
      final a = app(sv('green'));
      a.reg.unsavedTodos.add('上一個操作可能沒有存完：新增節點');
      return HomePage(app: a, ui: ui, devTrust: true, keys: keys());
    },
    'home, an offline to-do banner (PR 5 R12)': (ui) {
      final a = app(sv('green'));
      a.reg.unsavedTodos.add('上一個操作可能沒有存完：移除隊員');
      a.reg.unsavedText['上一個操作可能沒有存完：移除隊員'] = offlineTodoText('移除隊員');
      return HomePage(app: a, ui: ui, devTrust: true, keys: keys());
    },
    'node page': (ui) => NodePage(app: app(sv('red')), id: id, ui: ui),
    'home, Bluetooth off': (ui) {
      final a = app(sv('green'));
      a.link.radio(bluetooth: false);
      return HomePage(app: a, ui: ui, devTrust: true, keys: keys());
    },
    'home, identity mismatch': (ui) {
      final a = app(null);
      a.link.core.states[id]!
        ..kind = Kind.unreachable
        ..why = Why.identity;
      return HomePage(app: a, ui: ui, devTrust: true, keys: keys());
    },
    'home, unreachable': (ui) {
      final a = app(null);
      a.link.core.states[id]!
        ..kind = Kind.unreachable
        ..why = Why.notFound
        ..last = Concl.notFound;
      return HomePage(app: a, ui: ui, devTrust: true, keys: keys());
    },
    'home, no node': (ui) {
      final a = app(null);
      a.link.core.setRecords(const []);
      return HomePage(app: a, ui: ui, devTrust: true, keys: keys());
    },
    'node page, identity': (ui) {
      final a = app(null);
      a.link.core.states[id]!
        ..kind = Kind.unreachable
        ..why = Why.identity;
      return NodePage(app: a, id: id, ui: ui);
    },
    'settings (dev)': (ui) => SettingsPage(app: app(null), ui: ui, devTrust: true),
    'about': (ui) => const AboutPage(),
    'intro': (ui) => IntroPages(onDone: () {}),
    'permissions': (ui) => PermissionsPage(ask: () async => false),
    // #329 PR 4: the new pages (5.6 / 5.8 with a session that is busy: they show their read-failed state)
    'more': (ui) => MorePage(app: app(sv('green', canLeave: true)), ui: ui, id: id),
    'phone Wi-Fi': (ui) => WifiPage(app: app(sv('green')), ui: ui, id: id, deps: busy),
    'country': (ui) => CountryPage(app: app(sv('red', nodeState: 1)), ui: ui, id: id, deps: busy),
    'help': (ui) => const HelpPage(),
    'phone lost': (ui) => const PhoneLostPage(),
    'software update, prepared': (ui) => SwUpdatePage(hold: SwHold(_Flow()), ask: (_) async => _ready, onSetAp: () {}),
    // #329 PR 5: the team pages (boards 7.1, 7.3-7.10, 8.1-8.5, the hub, 4.1 member mode)
    'team hub': (ui) => TeamHubPage(app: app(null), ui: ui),
    '8.1 members': (ui) => MembersPage(app: app(sv('green')), netId: 'nn'),
    '8.2 person': (ui) => PersonPage(app: app(sv('green')), netId: 'nn', person: people[1], all: people),
    '8.2 me': (ui) => PersonPage(app: app(sv('green')), netId: 'nn', person: people[0], all: people),
    '8.3 remove': (ui) => RemoveConfirmPage(
        app: app(sv('green')), netId: 'nn', person: people[1], owner: 'OWNERBOB', node: '', same: const ['另有同名的一組：aaaa1111']),
    '8.4 new secrets': (ui) => RekeyPage(app: app(sv('green')), netId: 'nn', removal: true),
    '7.1 invite': (ui) => InvitePage(app: app(sv('green')), netId: 'nn'),
    '7.3 invite code': (ui) => InviteCodePage(app: app(sv('green')), netId: 'nn', hex: code, inPerson: false),
    '7.4 request': (ui) => RequestPage(app: app(sv('green')), netId: 'nn'),
    '7.5 approve': (ui) => ApprovePage(app: app(sv('green')), netId: 'nn', hex: code, jr: jr, previousOk: false),
    '7.6 approval code': (ui) => const ApprovalCodePage(hex: code, name: '王小明'),
    '7.7 mismatch': (ui) => const MismatchPage(),
    '7.8 join team': (ui) => JoinTeamPage(app: app(sv('green')), ui: ui),
    '7.9 my request': (ui) => MyRequestPage(app: app(sv('green')), ui: ui, netId: 'nn', hex: code, sas: '4821', renewed: true),
    '7.10 import': (ui) => ImportApprovalPage(app: app(sv('green')), ui: ui),
    '8.5 new key': (ui) => UpdateImportPage(app: app(sv('green')), ui: ui),
    '4.1 member mode': (ui) {
      final a = app(sv('green'));
      a.nets.setForTest(const NetSnapshot(
          anyMnet: true, mnetIds: ['m1'], mnets: [MnetEntry('m1', name: '山隊', entryLast4: '7d2c')]));
      return NetFormPage(app: a, ui: ui, mode: NetMode.member);
    },
  };
  for (final size in const [Size(360, 640), Size(412, 915)]) {
    for (final scale in const [1.0, 1.3, 2.0]) {
      for (final dark in [false, true]) {
        for (final e in pages.entries) {
          testWidgets('T-C2 ${e.key} ${size.width.toInt()}x${size.height.toInt()} ×$scale ${dark ? 'dark' : 'light'}', (t) async {
            t.view.physicalSize = size;
            t.view.devicePixelRatio = 1;
            addTearDown(t.view.reset);
            final ui = UiState(MemStore());
            await t.pumpWidget(MaterialApp(
              theme: batThemeData(Brightness.light),
              darkTheme: batThemeData(Brightness.dark),
              themeMode: dark ? ThemeMode.dark : ThemeMode.light,
              builder: (c, child) =>
                  MediaQuery(data: MediaQuery.of(c).copyWith(textScaler: TextScaler.linear(scale)), child: child!),
              home: e.value(ui),
            ));
            await t.pump(const Duration(milliseconds: 100));
            expect(t.takeException(), isNull, reason: 'no overflow');
            await expectLater(t, meetsGuideline(androidTapTargetGuideline));
            await expectLater(t, meetsGuideline(textContrastGuideline));
            expect(find.byType(FilledButton).evaluate().length, lessThanOrEqualTo(1), reason: 'T-C3: one primary button');
            for (final w in t.widgetList<Text>(find.byType(Text))) {
              final s = w.data ?? w.textSpan?.toPlainText() ?? '';
              expect(retired.hasMatch(s), isFalse, reason: 'T-C4a: "$s"');
            }
            expectSixLevels(t); // #329 PR 7 T8 (b)
            await t.pumpWidget(const SizedBox()); // the pages' timers go with them
            AppLink.forgetForTest();
          });
        }
      }
    }
  }

  testWidgets('PR 5 R12: an offline operation\'s todo shows its own sentence; a node one keeps the node sentence', (t) async {
    final a = app(sv('green'));
    a.reg.unsavedTodos.add('上一個操作可能沒有存完：新增節點');
    a.reg.unsavedTodos.add('上一個操作可能沒有存完：移除隊員');
    a.reg.unsavedText['上一個操作可能沒有存完：移除隊員'] = offlineTodoText('移除隊員');
    await t.pumpWidget(MaterialApp(
        theme: batThemeData(Brightness.light), home: HomePage(app: a, ui: UiState(MemStore()), devTrust: true, keys: keys())));
    await t.pump(const Duration(milliseconds: 100));
    expect(find.text(offlineTodoText('移除隊員')), findsOneWidget);
    expect(find.textContaining('請到那台節點的頁面'), findsOneWidget, reason: 'the node todo keeps its sentence');
    await t.pumpWidget(const SizedBox());
    AppLink.forgetForTest();
  });
}
