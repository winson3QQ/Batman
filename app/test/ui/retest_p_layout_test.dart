// #329 補測 A（PR 2 E-MINOR-8 / F-MINOR-5，2026-11-17）: the T-C2 pages layout_test.dart did not render yet — 1.1 (the
// startup splash), 2.4 (the phone's keys; with and without 再試一次, its 技術資訊 opened), the welcome pages 2 and 3,
// the 「從這支手機移除這台節點」 dialog, 技術資訊 opened on 更多, and long sentences (a 24-character nickname, long
// Rust sentences, warnings and technical lines) on the home page, the node page and 更多.
// The checks are layout_test's T-C2 checks, unchanged: {360×640, 412×915} × text scale {1.0, 1.3, 2.0} × {light,
// dark}: no overflow (an overflow is a test exception), Android's tap-target and text-contrast guidelines, at most one
// primary (filled) button, none of the retired words.
import 'dart:async';

import 'package:batman_app/key_abilities.dart';
import 'package:batman_app/main.dart' show StartupCheck;
import 'package:batman_app/src/nodelink/app_link.dart';
import 'package:batman_app/src/nodelink/core.dart';
import 'package:batman_app/src/rust/api/owner.dart' show StatusView;
import 'package:batman_app/src/rust/frb_generated.dart';
import 'package:batman_app/ui/home_page.dart';
import 'package:batman_app/ui/intro_pages.dart';
import 'package:batman_app/ui/more_pages.dart' show MorePage;
import 'package:batman_app/ui/node_page.dart';
import 'package:batman_app/ui/theme.dart';
import 'package:batman_app/ui/ui_state.dart';
import 'package:batman_app/ui/widgets.dart' show Btn;
import 'package:flutter/material.dart' hide Page;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../key_abilities_test.dart' as ka show FakeRust, answer;
import '../nodelink/app_link_test.dart' show StatusBle;
import 'layout_test.dart' show retired;
import 'ui_state_test.dart' show MemStore;
import '../support/font_levels.dart';

const id = '0000000000000c4f2a7d2c';
const platform = MethodChannel('dev.batman/platform');

// long words, as Rust and the user can make them
const longNick = '台北市大安區第三分隊前進指揮所備援中繼節點一號機'; // 24 characters (nickMax)
const longSentence = '沒有連上隊伍網路：HaLow 無線電已經開啟，但 120 秒內沒有收到任何其他節點的訊號；可能是頻道或國家和隊伍不同，或附近沒有其他節點。';
const longWarning = '這台節點的系統時間和手機相差超過 10 分鐘，部分紀錄的時間可能不準；接上網路或重新開機後會自動校正。';
const longLag = '狀態是 4 分 30 秒前讀的：節點忙著處理別的請求，下一輪會再讀一次。';
const longUnfinished = '上一次的設定變更還沒有做完（國家從 US 改成 TW），節點重新開機後才會生效。';
final longTech = [
  '頻道：42（2 MHz）',
  '網路代號 bm-94676ef40105abcdef0123456789abcdef0123456789abcdef',
  'mesh 位址 fe80::1c4f:2aff:fe7d:2c00%wlan1 / 10.41.80.13',
  '韌體 1.5.14-wsl.26+g4f2a7d2c0123456789abcdef（2026-11-16 建置）',
];

StatusView sv(String color, {int nodeState = 2, bool canLeave = false, bool long = false}) => StatusView(
    color: color,
    row: '3',
    sentence: long ? longSentence : (color == 'green' ? '已連上隊伍網路' : '沒有連上隊伍網路'),
    lagNote: long ? longLag : '',
    warning: long ? longWarning : '',
    nodeState: nodeState,
    netId: long ? 'ab12cd34ef56ab12cd34ef56ab12cd34' : 'ab12',
    version: long ? '1.5.14-wsl.26+g4f2a7d2c0123456789' : '1.5.14',
    tech: long ? longTech : const ['頻道：42'],
    fresh: true,
    rateNote: '',
    unfinished: long ? longUnfinished : '',
    unfinishedUnderVerdict: false,
    canLeave: canLeave);

KeyAbilities keys() => KeyAbilities.from(ka.answer());

/// An AppLink with one node record, read now with [view] (null = not read).
AppLink app(StatusView? view) {
  AppLink.forgetForTest();
  final a = AppLink.create(platform: platform, filesDir: '/x', ble: StatusBle());
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

UiState longNamed() => UiState(MemStore()..ids = [id])..nodes[id] = const UiNode(nick: longNick, look: 'bad', readAt: 1763256600);

/// The platform for the startup check: [keyLevels] answers (a PlatformException is thrown); [never]: the check
/// never gets past its first question (board 1.1 stays).
void startup({Object? keyLevels, bool never = false}) {
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(platform, (c) async {
    switch (c.method) {
      case 'devTrust':
        if (never) return Completer<bool>().future;
        return true;
      case 'filesDir':
        return '/data/user/0/app/files';
      case 'keyLevels':
        final k = keyLevels;
        if (k is PlatformException) throw k;
        return k;
    }
    return null;
  });
}

class P {
  const P(this.build, {this.act});
  final Widget Function(UiState ui) build;

  /// What the user does before the page is checked (open a dialog, a page, a fold).
  final Future<void> Function(WidgetTester t)? act;
}

Future<void> tapText(WidgetTester t, String s) async {
  if (find.text(s).evaluate().isEmpty) {
    // a ListView builds what is near the screen only: scroll until it is built
    await t.scrollUntilVisible(find.text(s), 200, scrollable: find.byType(Scrollable).first);
  }
  final f = find.text(s).last;
  await t.ensureVisible(f);
  await t.pump(const Duration(milliseconds: 100));
  await t.tap(f);
  await t.pump();
  await t.pump(const Duration(milliseconds: 500));
}

void main() {
  final rust = ka.FakeRust()..nodes = ['0000000000000c4f2a', '00000000000000beef0000000000c4f2a7d2c'];
  setUpAll(() => RustLib.initMock(api: rust));
  setUp(() => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(platform, (c) async => null));

  final pages = <String, P>{
    '1.1 startup splash': P((ui) {
      startup(never: true);
      return const StartupCheck();
    }),
    '2.4 keys not hardware': P((ui) {
      startup(keyLevels: ka.answer(appUsable: false));
      return const StartupCheck();
    }),
    '2.4 keys unreadable (再試一次)': P((ui) {
      startup(keyLevels: PlatformException(code: 'keystore', message: 'KeyStoreException'));
      return const StartupCheck();
    }),
    '2.4 技術資訊 opened': P((ui) {
      startup(keyLevels: ka.answer(appUsable: false));
      return const StartupCheck();
    }, act: (t) => tapText(t, '技術資訊（給維修人員看）')),
    'welcome page 2': P((ui) => IntroPages(onDone: () {}), act: (t) => tapText(t, Btn.next)),
    'welcome page 3': P((ui) => IntroPages(onDone: () {}), act: (t) async {
      await tapText(t, Btn.next);
      await tapText(t, Btn.next);
    }),
    'remove dialog': P((ui) => MorePage(app: app(sv('green', canLeave: true)), ui: ui, id: id),
        act: (t) => tapText(t, '從這支手機移除這台節點')),
    'more, 技術資訊 opened (long lines)': P((ui) => MorePage(app: app(sv('green', canLeave: true, long: true)), ui: ui, id: id),
        act: (t) => tapText(t, '技術資訊（給維修人員看）')),
    'long sentences: home, one node with a problem': P(
        (ui) => HomePage(app: app(sv('red', long: true)), ui: longNamed(), devTrust: true, keys: keys())),
    'long sentences: home, not read yet': P(
        (ui) => HomePage(app: app(null), ui: longNamed(), devTrust: true, keys: keys())),
    'long sentences: node page': P((ui) => NodePage(app: app(sv('red', long: true)), id: id, ui: longNamed())),
    'long sentences: remove dialog with a 24-character nickname': P(
        (ui) => MorePage(app: app(sv('green', canLeave: true, long: true)), ui: longNamed(), id: id),
        act: (t) => tapText(t, '從這支手機移除這台節點')),
  };
  for (final size in const [Size(360, 640), Size(412, 915)]) {
    for (final scale in const [1.0, 1.3, 2.0]) {
      for (final dark in [false, true]) {
        for (final e in pages.entries) {
          testWidgets('retest-p T-C2 ${e.key} ${size.width.toInt()}x${size.height.toInt()} ×$scale ${dark ? 'dark' : 'light'}',
              (t) async {
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
              home: e.value.build(ui),
            ));
            for (var i = 0; i < 5; i++) {
              await t.pump(const Duration(milliseconds: 100)); // the startup check's answers
            }
            expect(t.takeException(), isNull, reason: 'no overflow');
            final act = e.value.act;
            if (act != null) {
              await act(t);
              expect(t.takeException(), isNull, reason: 'no overflow after the user\'s step');
            }
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

  // the pages above really are the boards they are named after (a page that never opened would pass every check)
  testWidgets('retest-p T-C2 the rendered boards are the ones named', (t) async {
    Future<void> open(P p) async {
      await t.pumpWidget(MaterialApp(theme: batThemeData(Brightness.light), home: p.build(UiState(MemStore()))));
      for (var i = 0; i < 5; i++) {
        await t.pump(const Duration(milliseconds: 100));
      }
      final act = p.act;
      if (act != null) await act(t);
    }

    Future<void> done() async {
      await t.pumpWidget(const SizedBox());
      AppLink.forgetForTest();
    }

    await open(pages['1.1 startup splash']!);
    expect(find.text('正在檢查這支手機…'), findsOneWidget);
    await done();
    await open(pages['2.4 keys not hardware']!);
    expect(find.textContaining('手機裡有這些節點的紀錄').evaluate().isNotEmpty || find.textContaining('這些節點需要重燒卡回收').evaluate().isNotEmpty,
        isTrue);
    expect(find.text('技術資訊（給維修人員看）'), findsOneWidget);
    await done();
    await open(pages['2.4 keys unreadable (再試一次)']!);
    expect(find.text(Btn.tryAgain), findsOneWidget);
    await done();
    await open(pages['2.4 技術資訊 opened']!);
    expect(find.textContaining('金鑰保護等級'), findsOneWidget, reason: 'the fold is open');
    await done();
    await open(pages['welcome page 2']!);
    expect(find.text('開始之前，請準備三樣東西'), findsOneWidget);
    await done();
    await open(pages['welcome page 3']!);
    expect(find.text('三個步驟就能使用'), findsOneWidget);
    await done();
    await open(pages['remove dialog']!);
    expect(find.byType(AlertDialog), findsOneWidget);
    expect(find.widgetWithText(FilledButton, Btn.remove), findsOneWidget);
    await done();
    await open(pages['more, 技術資訊 opened (long lines)']!);
    expect(find.textContaining('網路代號 bm-94676ef40105'), findsOneWidget);
    await done();
    await open(pages['long sentences: home, one node with a problem']!);
    expect(find.textContaining(longSentence), findsWidgets);
    expect(find.textContaining(longNick), findsWidgets);
    await done();
    await open(pages['long sentences: node page']!);
    expect(find.textContaining(longWarning), findsOneWidget);
    expect(find.text(longNick), findsWidgets);
    await done();
    await open(pages['long sentences: remove dialog with a 24-character nickname']!);
    expect(find.text('要從這支手機移除$longNick嗎？'), findsOneWidget);
    await done();
  });
}
