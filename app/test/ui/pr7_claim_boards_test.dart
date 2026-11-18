// #329 PR 7 §4: the boards no file rendered before — 3.3 認領進行中, 3.4 認領失敗 (no unclaimed node found; the node
// refused), 3.7 從認領暫存恢復 (the entry, the pick, the confirmation, recovering) and the developer page 附近的節點
// (ScanPage, before and after a search) — with the claim page's fakes (claim_replay_page_test.dart / replay_fakes.dart:
// a fake BLE node, a fake recovery field, a fake Rust). 412×915, light and dark, text scale 1.0 and 2.0; each board:
// no overflow, its check, the six sizes, and at 1.0 the §4 rules (support/a11y.dart) and its PNG when BOARDS_OUT is set.

import 'package:batman_app/claim.dart';
import 'package:batman_app/scan.dart';
import 'package:batman_app/src/rust/api/claim.dart';
import 'package:batman_app/src/rust/frb_generated.dart';
import 'package:batman_app/ui/theme.dart';
import 'package:batman_app/ui/widgets.dart' show Btn, Look, LookStyle;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_reactive_ble/flutter_reactive_ble.dart';
import 'package:flutter_test/flutter_test.dart';

import '../claim_replay_page_test.dart' show FakeRust, FakeBle, cstep, qrText, files;
import '../replay_fakes.dart';
import '../retest_s_shot.dart';
import '../scan_page_test.dart' show SlowBle;
import '../support/a11y.dart';
import '../support/font_levels.dart';

/// The node never answers msg1: the claim stays in progress (3.3).
class _SilentBle extends FakeBle {
  @override
  Future<void> writeCharacteristicWithoutResponse(QualifiedCharacteristic c, {required List<int> value}) async => written.add(value);
}

/// The node refuses the claim (bridge api/claim.rs ClaimStep::ended's shape: the words, then the case as technical part).
class _Refused implements ClaimSession {
  @override
  ClaimStep? onFrame({required List<int> frame}) => cstep(StepKind.ended, detail: '節點拒絕開始認領\u001eBeginRefused：Busy\u001f');
  @override
  bool replayDue() => false;
  @override
  bool finishedWith9() => false;
  @override
  dynamic noSuchMethod(Invocation i) => null;
}

class ClaimBoardRust extends FakeRust {
  bool refuse = false;
  @override
  (ClaimSession, ClaimStep) crateApiClaimClaimSessionStart(
          {required ClaimQr qr, required List<int> ownerPub, required List<int> ownerEncPub, required List<int> sigEnc, required int frameLimit, required bool devSoftEnc}) =>
      refuse
          ? (_Refused(), cstep(StepKind.write, frames: [[1]]))
          : super.crateApiClaimClaimSessionStart(
              qr: qr, ownerPub: ownerPub, ownerEncPub: ownerEncPub, sigEnc: sigEnc, frameLimit: frameLimit, devSoftEnc: devSoftEnc);
}

/// A board: how the fakes are set, the page, the steps after the first frames, what it must show.
class C {
  const C(this.setUp, this.build, {this.act, required this.check});
  final void Function(ClaimBoardRust r, FakeField f) setUp;
  final Widget Function(FakeBle ble, FakeField f) build;
  final Future<void> Function(WidgetTester t)? act;
  final void Function(WidgetTester t) check;
}

Future<void> run(WidgetTester t, {int n = 12, int realMs = 5}) async {
  for (var i = 0; i < n; i++) {
    await t.runAsync(() => Future<void>.delayed(Duration(milliseconds: realMs))); // the search window is wall-clock
    await t.pump(const Duration(milliseconds: 250));
  }
}

Future<void> tapText(WidgetTester t, String s) async {
  await t.tap(find.text(s));
  await run(t, n: 4);
}

/// #329 PR 7 (p1p2-check 3.3 / 3.4 / 3.7): the claim page's status area shows [look] (its icon) and [words] (each).
void expectHero(Look look, List<String> words) {
  final hero = find.byKey(claimHeroKey);
  expect(find.descendant(of: hero, matching: find.byIcon(look.icon)), findsOneWidget, reason: 'status area look $look');
  for (final w in words) {
    expect(find.descendant(of: hero, matching: find.textContaining(w)), findsWidgets, reason: 'status area says $w');
  }
}

bool isDanger(Finder f) =>
    [BatTheme.light.danger, BatTheme.dark.danger].contains(f.evaluate().isEmpty ? null : (f.evaluate().first.widget as FilledButton).style?.backgroundColor?.resolve({}));

/// 掃描 QR, then 認領, then the claim runs (wall-clock search of 800 ms).
Future<void> claim(WidgetTester t) async {
  await tapText(t, '掃描 QR');
  await tapText(t, '認領');
  await run(t, n: 24, realMs: 50);
}

void main() {
  final rust = ClaimBoardRust();
  var devTrust = false;
  setUpAll(() async {
    RustLib.initMock(api: rust);
    await loadFonts();
  });

  ClaimPage page(FakeBle ble, FakeField f) => ClaimPage(ble: ble, recoveryBle: f, findFor: const Duration(milliseconds: 800));

  // file name (ASCII) -> board
  final boards = <String, C>{
    // 3.3: found, connected, msg1 sent, no answer yet — the steps so far, 認領 off while it runs
    '3.3_claiming': C((r, f) {
      r
        ..target = ClaimTarget.nothing
        ..statusState = 'unclaimed'
        ..statusLast4 = '4f2a';
    }, (ble, f) => page(_SilentBle(), f), act: claim, check: (t) {
      expect(find.textContaining('已送出認領要求'), findsOneWidget);
      expectHero(Look.busy, ['正在新增節點 …4F2A', '已經過', '等節點回應最多 90 秒']);
      expect(find.textContaining('4F2A…'), findsNothing, reason: 'no 「…」 after the hex (rendered as three dots)');
      expect(t.widget<FilledButton>(find.widgetWithText(FilledButton, '認領')).onPressed, isNull, reason: 'busy');
    }),
    // 3.4: no unclaimed node with this tail, a claimed node nearby (the common field case)
    '3.4_not_found': C((r, f) {
      r
        ..target = ClaimTarget.nothing
        ..statusState = 'member'
        ..statusLast4 = null;
    }, (ble, f) => page(ble, f), act: claim, check: (t) {
      expect(find.textContaining('秒內沒找到編號後四碼'), findsOneWidget);
      expect(find.textContaining('已經被認領的節點不能再認領'), findsOneWidget);
      expectHero(Look.bad, ['沒有新增節點 …4F2A', '確認之後再按「認領」']);
      expect(find.textContaining('----'), findsNothing, reason: 'no placeholder for a last four the node does not publish');
      expect(find.textContaining('找到一台節點（已認領的節點不公開後四碼）'), findsOneWidget);
    }),
    // 3.4: the node refused the claim (its case under 技術資訊)
    '3.4_refused': C((r, f) {
      r
        ..target = ClaimTarget.nothing
        ..statusState = 'unclaimed'
        ..statusLast4 = '4f2a'
        ..refuse = true;
    }, (ble, f) => page(ble, f), act: claim, check: (t) {
      expect(find.textContaining('認領沒有完成：節點拒絕開始認領'), findsOneWidget);
      expect(find.textContaining('BeginRefused'), findsNothing, reason: 'the case only under 技術資訊');
      expectHero(Look.bad, ['沒有新增節點 …4F2A', '可以再按「認領」試一次']);
    }),
    // 3.7 (dev builds with a claim-pending): the entry, the pick, the confirmation, recovering
    '3.7_entry': C((r, f) => r.pendingIds.add(deviceId), (ble, f) => page(ble, f),
        check: (t) => expect(find.text('從認領暫存恢復'), findsOneWidget)),
    '3.7_pick': C((r, f) => r.pendingIds.add(deviceId), (ble, f) => page(ble, f),
        act: (t) => tapText(t, '從認領暫存恢復'), check: (t) {
      expect(find.text('節點 …4F2A'), findsOneWidget);
      expect(find.textContaining('0c4f2a'), findsNothing, reason: 'the standard last four, upper case');
      expect(find.widgetWithText(TextButton, Btn.cancel), findsOneWidget, reason: 'a 取消 text button, not only a tap outside');
    }),
    '3.7_confirm': C((r, f) => r.pendingIds.add(deviceId), (ble, f) => page(ble, f), act: (t) async {
      await tapText(t, '從認領暫存恢復');
      await tapText(t, '節點 …4F2A');
    }, check: (t) {
      expect(find.text('要恢復節點 …4F2A 嗎？'), findsOneWidget);
      expect(isDanger(find.widgetWithText(FilledButton, Btn.recoverCut)), isTrue, reason: 'it cuts the node off: danger, its consequence in its words');
      expect(find.widgetWithText(TextButton, Btn.cancel), findsOneWidget);
    }),
    '3.7_recovering': C((r, f) {
      r.pendingIds.add(deviceId);
      for (var i = 0; i < 3; i++) {
        f.add(Dev('X$i', -20 - i)..msg2Silent = true); // nothing answers: the recovery keeps trying
      }
    }, (ble, f) => page(ble, f), act: (t) async {
      await tapText(t, '從認領暫存恢復');
      await tapText(t, '節點 …4F2A');
      await tapText(t, '恢復，中斷它所有的連線');
      await run(t, n: 8);
    }, check: (t) {
      expect(find.widgetWithText(FilledButton, '停止恢復'), findsOneWidget);
      expect(find.textContaining('從認領暫存恢復節點 …4F2A'), findsOneWidget);
      expectHero(Look.busy, ['正在恢復節點 …4F2A', '已經過', '恢復最多 5 分鐘']);
      expect(find.textContaining('0c4f2a'), findsNothing, reason: 'the standard last four, upper case');
    }),
    // developer options: 附近的節點 (the older BLE test page), before and after 搜尋
    'dev_scan': C((r, f) {}, (ble, f) => ScanPage(ble: SlowBle()), check: (t) => expect(find.text('搜尋'), findsOneWidget)),
    'dev_scan_found': C((r, f) {
      r
        ..statusState = 'unclaimed'
        ..statusLast4 = '4f2a';
    }, (ble, f) => ScanPage(ble: SlowBle()), act: (t) => tapText(t, '搜尋'), check: (t) => expect(find.text('AA  訊號 -40 dBm'), findsOneWidget)),
  };

  Future<void> pumpBoard(WidgetTester t, C c, {required bool dev, bool dark = false, double scale = 1.0}) async {
    sizeView(t);
    final t0 = t.binding.clock.now();
    now = () => t.binding.clock.now().difference(t0);
    rust
      ..calls.clear()
      ..disk.clear()
      ..disk[pendPath] = Uint8List.fromList(pendingBytes)
      ..target = ClaimTarget.pending
      ..statusState = 'claimed'
      ..statusLast4 = null
      ..due = false
      ..pendingIds.clear()
      ..refuse = false;
    final field = FakeField();
    final ble = FakeBle();
    c.setUp(rust, field);
    devTrust = dev;
    mockPlatformReadOnly(t, (c) async {
      switch (c.method) {
        case 'scanQr':
          return qrText;
        case 'devTrust':
          return devTrust;
        case 'filesDir':
          return files;
        case 'blePermissions':
          return true;
        case 'publicKeys':
          return {'owner': Uint8List(65), 'ownerEnc': Uint8List(65), 'admin': Uint8List(65)};
        case 'open':
          return Uint8List.fromList((c.arguments as Map)['sealed'] as Uint8List);
        case 'seal':
          return Uint8List.fromList((c.arguments as Map)['plain'] as Uint8List);
      }
      return FakePlatform().handle(c);
    });
    await t.pumpWidget(frame(MaterialApp(
      theme: batThemeData(Brightness.light),
      darkTheme: batThemeData(Brightness.dark),
      themeMode: dark ? ThemeMode.dark : ThemeMode.light,
      debugShowCheckedModeBanner: false,
      builder: (c, child) => MediaQuery(data: MediaQuery.of(c).copyWith(textScaler: scale == 1.0 ? TextScaler.noScaling : TextScaler.linear(scale)), child: child!),
      home: c.build(ble, field),
    )));
    await run(t, n: 4);
  }

  Future<void> settleAway(WidgetTester t) async {
    await t.pumpWidget(const SizedBox());
    for (var i = 0; i < 40; i++) {
      await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 5)));
      await t.pump(const Duration(seconds: 30));
    }
  }

  // code review A-m3: 「從認領暫存恢復」 then 取消 (in the pick or in the confirmation) leaves the last claim's failure as it
  // was — its sentence 「沒有新增節點 …4F2A」 and its next step — not a recovery's. Negative control: the flags set before
  // the pick (the code before the fix) -> FAIL.
  for (final how in ['pick', 'confirm']) {
    testWidgets('A-m3: a failed claim, then 從認領暫存恢復 and 取消 in the $how -> the claim\'s failure as it was', (t) async {
      final failed = C((r, f) {
        r
          ..target = ClaimTarget.nothing
          ..statusState = 'member'
          ..statusLast4 = null
          ..pendingIds.add('0000000000000c9b1e');
      }, (ble, f) => page(ble, f), check: (t) {});
      await pumpBoard(t, failed, dev: true);
      await claim(t);
      expectHero(Look.bad, ['沒有新增節點 …4F2A', '確認之後再按「認領」']);
      await tapText(t, '從認領暫存恢復');
      if (how == 'confirm') await tapText(t, '節點 …9B1E');
      await tapText(t, Btn.cancel);
      expect(find.byType(Dialog), findsNothing);
      expectHero(Look.bad, ['沒有新增節點 …4F2A', '確認之後再按「認領」']);
      expect(find.descendant(of: find.byKey(claimHeroKey), matching: find.textContaining('恢復')), findsNothing,
          reason: 'not a recovery\'s sentence or next step');
      await settleAway(t);
    });
  }

  for (final (dark, scale) in const [(false, 1.0), (true, 1.0), (false, 2.0), (true, 2.0)]) {
    for (final e in boards.entries) {
      final file = '${e.key}_${dark ? 'dark' : 'light'}';
      testWidgets('pr7 claim board $file${scale == 1.0 ? '' : ' ×2.0'}', (t) async {
        final sem = t.ensureSemantics();
        await pumpBoard(t, e.value, dev: e.key.startsWith('3.7') || e.key.startsWith('dev_'), dark: dark, scale: scale);
        expect(t.takeException(), isNull, reason: 'no overflow');
        final act = e.value.act;
        if (act != null) {
          await act(t);
          expect(t.takeException(), isNull, reason: 'no overflow after the step');
        }
        if (scale == 1.0) e.value.check(t);
        expectSixLevels(t);
        if (scale == 1.0) await expectA11y(t, file);
        if (scale == 1.0) await shoot(t, file);
        await t.pumpWidget(const SizedBox()); // the page goes; its claim / recovery / scan run out on the fake clock
        sem.dispose();
        for (var i = 0; i < 40; i++) {
          await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 5)));
          await t.pump(const Duration(seconds: 30));
        }
      });
    }
  }
}
