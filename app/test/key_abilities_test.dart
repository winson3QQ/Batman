// design v8.5.1 §4.1 table: what the live key levels allow. Kotlin decides (KeyPolicy.abilities, KeyPolicyTest) and
// answers `keyLevels`; Dart must obey that answer:
// - record AES not hardware (appUsable false) -> the whole app is off: the start page has no way to a node page;
// - owner signing not hardware -> no claim / login (and so no recovery, no network);
// - admin not hardware -> no network;
// - owner_enc not allowed (field: SOFTWARE) -> no claim / recovery; dev + SOFTWARE owner_enc -> allowed, with the notice;
// - no answer, a missing entry, an entry that is not a bool, a platform error -> nothing allowed (fail closed).
// The gate inside a claim is in claim_target_test; here: the decision and the start page. (The old console's login gate
// 「我的節點: login not allowed」 went with it in #329 PR 6; NodeLink's live key check before a login is login_for_test.)
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_reactive_ble/flutter_reactive_ble.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:batman_app/key_abilities.dart';
import 'package:batman_app/main.dart';
import 'package:batman_app/src/rust/api/claim.dart' show SealParams;
import 'package:batman_app/src/rust/api/owner.dart' show SealedRecord;
import 'package:batman_app/ui/cbor_mini.dart';
import 'package:batman_app/claim.dart';
import 'package:batman_app/scan.dart';
import 'package:batman_app/ui/home_page.dart';
import 'package:batman_app/src/nodelink/app_link.dart';
import 'package:batman_app/src/nodelink/core.dart' show Why;
import 'package:batman_app/src/rust/api/simple.dart';
import 'package:batman_app/src/rust/frb_generated.dart';

const platform = MethodChannel('dev.batman/platform');

/// The `keyLevels` answer (MainActivity): the four levels by role name, then what KeyPolicy allows.
Map<String, Object?> answer(
        {bool appUsable = true,
        bool claim = true,
        bool login = true,
        bool recover = true,
        bool makeNetwork = true,
        bool soft = false,
        Set<String> gone = const {}}) =>
    {
      // a lost key has no level (null)
      'RECORD_AES': gone.contains('RECORD_AES') ? null : (appUsable ? 1 : 0),
      'OWNER_SIGN': gone.contains('OWNER_SIGN') ? null : 1,
      'ADMIN_SIGN': gone.contains('ADMIN_SIGN') ? null : 1,
      'OWNER_ENC': gone.contains('OWNER_ENC') ? null : (soft ? 0 : 1),
      'appUsable': appUsable,
      'claim': claim,
      'login': login,
      'recover': recover,
      'makeNetwork': makeNetwork,
      'softOwnerEnc': soft,
    };

class FakeRust implements RustLibApi {
  bool dev = true; // the build: dev (devTrust) or field; the platform's devTrust answers the same
  @override
  BuildInfo crateApiSimpleBuildInfo() => BuildInfo(devTrust: dev, crateVersion: 'test');

  @override
  String crateApiSimpleSelftest() => 'ok';

  /// thrown by that store call when set (the Rust store's errors reach Dart as plain exceptions, not PlatformException)
  Object? sweepError, markerError;

  @override
  Future<int> crateApiSimpleStoreSweep({required String dir}) async => sweepError == null ? 0 : throw sweepError!;

  String? marker = 'marker';

  @override
  Future<String?> crateApiSimpleStoreReadMarker({required String dir}) async =>
      markerError == null ? marker : throw markerError!;

  /// #329 PR 7 T14: storeHasRecords' error (Rust: the record store could not be read)
  Object? hasRecordsError;

  @override
  Future<bool> crateApiSimpleStoreHasRecords({required String dir}) async =>
      hasRecordsError == null ? false : throw hasRecordsError!;

  List<String> nodes = ['0000000000000c4f2a'];
  bool uiWelcomed = false; // ui/state-v1 holds 「看過歡迎頁」

  @override
  Future<SealedRecord?> crateApiOwnerStoreReadSealed({required String dir, required String rel}) async =>
      rel == 'ui/state-v1' && uiWelcomed
          ? SealedRecord(generation: BigInt.one, sealed: Uint8List.fromList([9]), aad: Uint8List(0))
          : null;
  @override
  Future<List<String>> crateApiOwnerListNodes({required String dir}) async => nodes;

  final uiWrites = <String>[]; // ui/state-v1 writes (CAS)
  @override
  Future<SealParams> crateApiClaimStoreSealParams({required String dir, required String rel}) async =>
      SealParams(generation: BigInt.from(uiWelcomed ? 2 : 1), aad: Uint8List(0));
  @override
  Future<BigInt> crateApiOwnerStoreWriteCas(
      {required String dir, required String rel, required BigInt expectedGen, required List<int> sealed}) async {
    uiWrites.add(rel);
    return expectedGen + BigInt.one;
  }

  @override
  Future<List<String>> crateApiOwnerListPending({required String dir}) async => ['00000000000000beef'];

  @override
  dynamic noSuchMethod(Invocation i) => throw UnimplementedError('${i.memberName}');
}

void main() {
  final rust = FakeRust();
  setUpAll(() => RustLib.initMock(api: rust));
  setUp(() {
    rust.marker = 'marker';
    rust.sweepError = null;
    rust.markerError = null;
    rust.hasRecordsError = null;
  });
  final calls = <String>[];

  /// [keys]: the `keyLevels` answer; a PlatformException is thrown
  void mock(WidgetTester t, Object? keys) {
    calls.clear();
    t.binding.defaultBinaryMessenger.setMockMethodCallHandler(platform, (c) async {
      calls.add(c.method);
      switch (c.method) {
        case 'devTrust':
          return rust.dev;
        case 'seal':
          return Uint8List.fromList([7]);
        case 'filesDir':
          return '/data/user/0/app/files';
        case 'keyLevels':
          if (keys is PlatformException) throw keys;
          return keys;
        case 'open': // the ui record (the only sealed record these start-page tests read)
          return cborEncode(<Object, Object>{1: 1, 2: true});
        case 'firstRun':
          throw PlatformException(code: 'firstRun', message: 'no StrongBox, no TEE');
      }
      return null;
    });
  }

  group('the decision', () {
    void all(KeyAbilities a, bool want) {
      for (final u in KeyUse.values) {
        expect(a.allows(u), want, reason: '$u');
        expect(a.refusal(u) == null, want, reason: '$u');
      }
    }

    test('every key fits: everything on, nothing to say', () {
      final a = KeyAbilities.from(answer());
      expect(a.appUsable, true);
      expect(a.softOwnerEnc, false);
      all(a, true);
    });

    test('record AES not hardware: the app is off, every use refused with that reason', () {
      // the emulator's answer (2026-11-14, API 37, all SOFTWARE)
      final a = KeyAbilities.from(answer(appUsable: false, claim: false, login: false, recover: false, makeNetwork: false, soft: true));
      expect(a.appUsable, false);
      all(a, false);
      for (final u in KeyUse.values) {
        expect(a.refusal(u), KeyAbilities.appOff);
      }
    });

    test('record AES not hardware wins over a use the answer leaves on', () {
      final a = KeyAbilities.from(answer(appUsable: false));
      all(a, false);
    });

    test('owner signing not hardware: no claim / login / recovery / network, the owner key named', () {
      final a = KeyAbilities.from(answer(claim: false, login: false, recover: false, makeNetwork: false));
      expect(a.appUsable, true);
      all(a, false);
      for (final u in KeyUse.values) {
        expect(a.refusal(u), contains('擁有者金鑰不是硬體保護'));
      }
    });

    test('admin not hardware: only the network is off', () {
      final a = KeyAbilities.from(answer(makeNetwork: false));
      expect(a.appUsable && a.claim && a.login && a.recover, true);
      expect(a.makeNetwork, false);
      expect(a.refusal(KeyUse.makeNetwork), contains('網路管理金鑰不是硬體保護，不能建立網路'));
      expect(a.refusal(KeyUse.login), isNull);
    });

    test('owner_enc not allowed (field build, SOFTWARE): no claim / recovery; login and network stay', () {
      final a = KeyAbilities.from(answer(claim: false, recover: false));
      expect(a.appUsable && a.login && a.makeNetwork, true);
      expect(a.claim || a.recover, false);
      expect(a.refusal(KeyUse.claim), contains('復原／隊員金鑰不是硬體保護，不能認領節點'));
      expect(a.refusal(KeyUse.recover), contains('復原／隊員金鑰不是硬體保護'));
    });

    test('dev build with a SOFTWARE owner_enc (S20): everything on, the notice flag set', () {
      final a = KeyAbilities.from(answer(soft: true));
      expect(a.appUsable, true);
      expect(a.softOwnerEnc, true);
      all(a, true);
    });

    // design §4.1 「單一金鑰遺失」: a key with no Keystore entry (level null)
    test('a lost key: its uses are off whatever the six say, and the words say it is lost', () {
      // the booleans left on: the level decides (fail closed)
      var a = KeyAbilities.from(answer(gone: {'OWNER_SIGN'}));
      expect(a.appUsable, true);
      all(a, false);
      for (final u in KeyUse.values) {
        expect(a.refusal(u), KeyAbilities.ownerGone);
      }
      expect(KeyAbilities.ownerGone, allOf(contains('不能登入、認領或接續認領'), contains('紀錄還讀得到'), contains('節點需要重燒卡回收')));

      a = KeyAbilities.from(answer(gone: {'ADMIN_SIGN'}));
      expect(a.claim && a.login && a.recover, true);
      expect(a.makeNetwork, false);
      expect(a.refusal(KeyUse.makeNetwork), '這支手機的網路管理金鑰不見了，不能建立或更改網路');

      a = KeyAbilities.from(answer(gone: {'OWNER_ENC'}));
      expect(a.login && a.makeNetwork, true);
      expect(a.claim || a.recover, false);
      expect(a.refusal(KeyUse.recover), allOf(contains('復原／隊員金鑰不見了，不能接續沒完成的認領'), contains('需要重燒卡')));
      expect(a.refusal(KeyUse.claim), contains('復原／隊員金鑰不見了，不能認領節點'));

      a = KeyAbilities.from(answer(gone: {'RECORD_AES'}));
      expect(a.appUsable, false);
      expect(a.unread, false);
      all(a, false);
      expect(a.offReason, KeyAbilities.aesGone);
      expect(KeyAbilities.aesGone, contains('紀錄沒有刪除'));

      a = KeyAbilities.from(answer(gone: {'RECORD_AES', 'OWNER_SIGN', 'ADMIN_SIGN', 'OWNER_ENC'}));
      all(a, false);
      expect(a.offReason, KeyAbilities.allGone);
      expect(KeyAbilities.allGone, allOf(contains('清除 App 資料或重新安裝'), contains('節點需要重燒卡回收')));
    });

    test('the three reasons the app is off are told apart', () {
      expect(KeyAbilities.none.offReason, KeyAbilities.unreadOff);
      expect(KeyAbilities.from(null).unread, true);
      expect(KeyAbilities.from(answer(gone: {'RECORD_AES'})).offReason, KeyAbilities.aesGone);
      final soft = KeyAbilities.from(answer(appUsable: false));
      expect(soft.unread, false);
      expect(soft.offReason, KeyAbilities.appOff);
      expect({KeyAbilities.unreadOff, KeyAbilities.aesGone, KeyAbilities.appOff, KeyAbilities.allGone}.length, 4);
    });

    // Kotlin's own gate (MainActivity.gate -> KeyPolicy.refused): code keyLevel, message = role, details = level / null
    test('a Kotlin key refusal is turned into the same words; anything else is not one', () {
      String? by(String role, Object? level) => KeyAbilities.refusedBy(PlatformException(code: 'keyLevel', message: role, details: level));
      expect(by('RECORD_AES', 0), KeyAbilities.appOff);
      expect(by('RECORD_AES', null), KeyAbilities.aesGone);
      expect(by('OWNER_SIGN', 0), contains('擁有者金鑰不是硬體保護'));
      expect(by('OWNER_SIGN', null), KeyAbilities.ownerGone);
      expect(by('ADMIN_SIGN', -1), contains('網路管理金鑰不是硬體保護'));
      expect(by('ADMIN_SIGN', null), KeyAbilities.adminGone);
      expect(by('OWNER_ENC', 0), contains('復原／隊員金鑰不是硬體保護'));
      expect(by('OWNER_ENC', null), KeyAbilities.encGone);
      expect(by('SOMETHING_NEW', 1), isNotNull, reason: 'an unknown role is still a refusal');
      expect(KeyAbilities.refusedBy(PlatformException(code: 'keystore', message: 'OWNER_SIGN')), isNull);
      expect(KeyAbilities.refusedBy('keyLevel'), isNull);
    });

    test('unreadable answers allow nothing', () {
      final bad = <Map<Object?, Object?>?>[
        null,
        {},
        answer()..remove('appUsable'),
        answer()..remove('makeNetwork'),
        answer()..remove('softOwnerEnc'),
        answer()..['appUsable'] = 1,
        answer()..['claim'] = 'true',
        answer()..['login'] = null,
        answer()..remove('RECORD_AES'), // a level that is not there at all (not the same as null = lost)
        answer()..remove('OWNER_ENC'),
        answer()..['ADMIN_SIGN'] = 'TEE',
        answer()..['OWNER_SIGN'] = true,
        {'APPUSABLE': true, 'Claim': true, 'login': true, 'recover': true, 'makeNetwork': true, 'softOwnerEnc': false},
      ];
      for (final m in bad) {
        final a = KeyAbilities.from(m);
        expect(a.unread, true, reason: '$m');
        expect(a.appUsable, false, reason: '$m');
        expect(a.softOwnerEnc, false, reason: '$m');
        all(a, false);
      }
    });

    testWidgets('the live read: an answer, a platform error, an answer that is not a map, no answer', (t) async {
      final detail = <String>[];
      mock(t, answer());
      expect((await KeyAbilities.read(platform, detail: detail.add)).claim, true);
      expect(detail.single, contains('appUsable: true'));

      detail.clear();
      mock(t, PlatformException(code: 'keystore', message: 'KeyStoreException'));
      var a = await KeyAbilities.read(platform, detail: detail.add);
      expect(a.appUsable, false);
      all(a, false);
      expect(detail.single, contains('keystore KeyStoreException'));

      mock(t, 'yes');
      a = await KeyAbilities.read(platform);
      expect(a.appUsable, false);
      all(a, false);

      mock(t, null);
      a = await KeyAbilities.read(platform);
      expect(a.appUsable, false);
      all(a, false);
    });
  });

  group('the start page', () {
    Future<void> start(WidgetTester t, Object? keys) async {
      mock(t, keys);
      await t.pumpWidget(const BatmanApp());
      await t.pumpAndSettle();
      expect(find.byType(CircularProgressIndicator), findsNothing, reason: 'the check ended');
    }

    /// every button of the page that is on
    Iterable<ButtonStyleButton> live(WidgetTester t) =>
        t.widgetList<ButtonStyleButton>(find.bySubtype<ButtonStyleButton>()).where((b) => b.onPressed != null);

    // #329 PR 1 review r3 E-M1 (E6 / E8): the start page opens an older page under a raw lease and hands it to the
    // page (its busy work holds it); the lease goes when the page is gone. Negative controls: _open without the lease
    // (page(a, null)) or without openRawPage -> FAIL.
    // PR 2: 新增節點 is on the home page; the older console and the BLE test page are in 設定 -> 開發者選項
    for (final (button, lease, Type type, viaSettings) in [
      ('新增節點', '新增節點', ClaimPage, false),
      ('附近的節點（藍牙測試）', '附近的節點', ScanPage, true),
    ]) {
      testWidgets('r3 E-M1 / r4 G-M1: $button opens its page under a raw lease handed to the page; back releases it',
          (t) async {
        mock(t, answer());
        AppLink.forgetForTest();
        final ble = _ScanBle();
        await t.pumpWidget(BatmanApp(makeLink: (dir) => AppLink.create(platform: platform, filesDir: dir, ble: ble)));
        await t.pumpAndSettle();
        final a = AppLink.instance!;
        addTearDown(() {
          a.link.dispose();
          AppLink.forgetForTest();
        });
        expect(find.byType(HomePage), findsOneWidget, reason: 'the start page hands over to the home page');
        expect(a.reg.current, isNull);
        if (viaSettings) {
          await t.tap(find.byTooltip('設定'));
          await t.pumpAndSettle();
        }
        await t.ensureVisible(find.text(button).last); // #329 PR 6: the settings page is longer now
        await t.pumpAndSettle();
        await t.tap(find.text(button).last);
        await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
        await t.pumpAndSettle();
        expect(find.byType(type), findsOneWidget);
        expect(a.reg.current?.name, lease);
        final use = switch (t.widget(find.byType(type))) {
          final ClaimPage p => p.use,
          final ScanPage p => p.use,
          _ => null,
        };
        expect(use?.lease, same(a.reg.current), reason: 'the page holds the lease it runs under');
        t.state<NavigatorState>(find.byType(Navigator)).pop();
        await t.pumpAndSettle();
        expect(a.reg.current, isNull, reason: 'idle page gone: released');
        await t.runAsync(a.link.dispose);
      });
    }

    // r4 G1: the start page passes the app's lifecycle state: started in the background -> no reading until back
    testWidgets('r4: the start page started while the app is in the background does not read', (t) async {
      mock(t, answer());
      AppLink.forgetForTest();
      // the user leaves while the startup check runs, just before AppLink and its observer exist
      await t.pumpWidget(BatmanApp(makeLink: (dir) {
        t.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
        return AppLink.create(platform: platform, filesDir: dir, ble: _ScanBle());
      }));
      addTearDown(() => t.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed));
      for (var i = 0; i < 20 && AppLink.instance == null; i++) {
        await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
        await t.pump(const Duration(milliseconds: 100));
      }
      await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      final a = AppLink.instance!;
      addTearDown(() {
        a.link.dispose();
        AppLink.forgetForTest();
      });
      expect(a.link.core.fg, isFalse);
      expect(a.link.core.roundActive, isFalse);
      await t.runAsync(a.link.dispose);
    });

    // r3 F-M1: the startup key check is NodeLink's key precondition (login not allowed -> 2.4 overlay, no reading)
    testWidgets('r3: login not allowed at startup -> NodeLink holds the key precondition', (t) async {
      mock(t, answer(login: false));
      AppLink.forgetForTest();
      await t.pumpWidget(BatmanApp(makeLink: (dir) => AppLink.create(platform: platform, filesDir: dir, ble: _ScanBle())));
      await t.pumpAndSettle();
      final a = AppLink.instance!;
      expect(a.link.core.blocked, Why.keys);
      await t.runAsync(a.link.dispose);
      AppLink.forgetForTest();
    });

    // #329 §5.2 T-U3: the welcome pages only when never seen AND the phone holds no node record (an upgrading user
    // never sees them). Negative control: drop the record check -> the upgrading user sees the welcome -> FAIL.
    for (final (records, seen, welcome) in [(true, false, false), (false, false, true), (false, true, false)]) {
      testWidgets('T-U3: records $records, seen $seen -> welcome $welcome', (t) async {
        mock(t, answer());
        rust
          ..nodes = records ? ['0000000000000c4f2a'] : []
          ..uiWelcomed = seen;
        addTearDown(() => rust.uiWelcomed = false);
        AppLink.forgetForTest();
        await t.pumpWidget(BatmanApp(makeLink: (dir) => AppLink.create(platform: platform, filesDir: dir, ble: _ScanBle())));
        await t.pumpAndSettle();
        expect(find.text('歡迎'), welcome ? findsOneWidget : findsNothing);
        expect(find.byType(HomePage), welcome ? findsNothing : findsOneWidget); // #329 PR 6: no node -> no 「可以做的事」 (one 新增節點)
        await t.runAsync(AppLink.instance!.link.dispose);
        rust.nodes = ['0000000000000c4f2a'];
        AppLink.forgetForTest();
      });
    }


    // PR 2 review r3 E-MINOR-1 (E, V16) / F-MINOR-2 (Md, Mq): 跳過說明 and 開始 both end the welcome, open the home
    // page and write 「看過歡迎頁」 to ui/state-v1. Negative controls: no setWelcomed / no page change -> FAIL.
    for (final skip in [true, false]) {
      testWidgets('r3: the welcome ended by ${skip ? '跳過說明' : '開始'} -> the home page, the flag written', (t) async {
        mock(t, answer());
        rust
          ..nodes = []
          ..uiWelcomed = false
          ..uiWrites.clear();
        addTearDown(() => rust.nodes = ['0000000000000c4f2a']);
        AppLink.forgetForTest();
        await t.pumpWidget(BatmanApp(makeLink: (dir) => AppLink.create(platform: platform, filesDir: dir, ble: _ScanBle())));
        await t.pumpAndSettle();
        if (skip) {
          await t.tap(find.text('跳過說明'));
        } else {
          for (var i = 0; i < 2; i++) {
            await t.tap(find.text('下一步'));
            await t.pumpAndSettle();
          }
          await t.tap(find.text('開始'));
        }
        await t.pumpAndSettle();
        expect(find.byType(HomePage), findsOneWidget);
        expect(rust.uiWrites, ['ui/state-v1']);
        await t.runAsync(AppLink.instance!.link.dispose);
        AppLink.forgetForTest();
      });
    }

    // r3 E-MINOR-1 (O / O2, Y): the build's devTrust reaches the settings page (開發者選項) and the F48 todo (an
    // unfinished claim) through main -> HomePage. Negative controls: devTrust not passed on -> FAIL.
    for (final dev in [true, false]) {
      testWidgets('r3: a ${dev ? 'dev' : 'field'} build -> 開發者選項 and 上次新增節點沒有做完 ${dev ? 'shown' : 'not shown'}',
          (t) async {
        rust.dev = dev;
        addTearDown(() => rust.dev = true);
        mock(t, answer());
        rust.uiWelcomed = true;
        addTearDown(() => rust.uiWelcomed = false);
        AppLink.forgetForTest();
        await t.pumpWidget(BatmanApp(makeLink: (dir) => AppLink.create(platform: platform, filesDir: dir, ble: _ScanBle())));
        await t.pumpAndSettle();
        expect(find.text('上次新增節點沒有做完'), dev ? findsOneWidget : findsNothing);
        await t.tap(find.byTooltip('設定'));
        await t.pumpAndSettle();
        expect(find.text('開發者選項'), dev ? findsOneWidget : findsNothing);
        await t.runAsync(AppLink.instance!.link.dispose);
        AppLink.forgetForTest();
      });
    }
    testWidgets('every key fits: the entries are there and on; no 我的節點 (#329 PR 6 D1)', (t) async {
      await start(t, answer());
      expect(find.textContaining('啟動檢查：正常'), findsOneWidget);
      expect(find.text('我的節點'), findsNothing);
      expect(find.text('認領節點'), findsOneWidget);
      expect(live(t).length, 2, reason: '#329 PR 6 D1: 認領節點 and (dev) 附近的節點');
    });

    // #329 PR 6 D1 / T6-2: the older start page is only what is left when the check passed and NodeLink did not start:
    // the reason, 「請完全關閉 app 再開…」, the exception only in the technical detail; no 「我的節點」 (the old console is
    // gone), no 「再試一次」 (F15: a second start on the same AppLink), 附近的節點 only in a dev build. Negative controls:
    // the 我的節點 button put back, or 附近的節點 without its devTrust gate -> FAIL.
    for (final dev in [true, false]) {
      testWidgets('T6-2: NodeLink does not start (${dev ? 'dev' : 'field'}) -> reason + restart line, no 我的節點 / retry',
          (t) async {
        rust.dev = dev;
        addTearDown(() => rust.dev = true);
        mock(t, answer());
        AppLink.forgetForTest();
        await t.pumpWidget(BatmanApp(makeLink: (dir) => throw StateError('no radio')));
        await t.pumpAndSettle();
        expect(find.byType(HomePage), findsNothing);
        expect(find.textContaining('節點自動讀取沒有啟動'), findsOneWidget);
        expect(find.text(restartLine), findsOneWidget);
        expect(find.textContaining('no radio'), findsNothing, reason: 'the exception is technical detail (folded)');
        expect(find.text('我的節點'), findsNothing);
        expect(find.text('再試一次'), findsNothing);
        expect(find.text('認領節點'), findsOneWidget);
        expect(find.text('附近的節點（開發用：藍牙測試）'), dev ? findsOneWidget : findsNothing);
        await t.tap(find.text('技術資訊（給維修人員看）'));
        await t.pumpAndSettle();
        expect(find.textContaining('NodeLink start: Bad state: no radio'), findsOneWidget);
      });
    }

    // design §8 test row: an emulator (all SOFTWARE) -> the app is off
    testWidgets('record AES not hardware: said so, and no button leads anywhere', (t) async {
      await start(t, answer(appUsable: false, claim: false, login: false, recover: false, makeNetwork: false, soft: true));
      expect(find.textContaining('啟動檢查：${KeyAbilities.appOff}'), findsOneWidget);
      expect(find.textContaining('啟動檢查：正常'), findsNothing);
      expect(find.text('我的節點'), findsNothing);
      expect(find.text('認領節點'), findsNothing);
      expect(find.bySubtype<ButtonStyleButton>(), findsNothing);
      // design §4: the plaintext index stays on screen (file names only: nothing is opened, nothing deleted — any
      // other store call of the fake throws)
      expect(find.text('這些節點需要重燒卡回收：'), findsOneWidget);
      expect(find.text('節點 4F2A') /* #329 PR 6 P1-3: the last four */, findsOneWidget);
    });

    // #329 PR 6 T6-11 (board 2.4): a title bar; no retry -> the next step is the repair person; the technical
    // information, once opened, says to give it to them and copies it (the whole node id is there, not on the list).
    // Negative controls: the title '' / the next step / the copy dropped -> FAIL.
    testWidgets('2.4: title bar, next step without a retry, the technical information copied', (t) async {
      String? copied;
      t.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (c) async {
        if (c.method == 'Clipboard.setData') copied = (c.arguments as Map)['text'] as String?;
        return null;
      });
      addTearDown(() => t.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));
      await start(t, answer(appUsable: false, claim: false, login: false, recover: false, makeNetwork: false, soft: true));
      expect(find.descendant(of: find.byType(AppBar), matching: find.text(startupKeysTitle)), findsOneWidget);
      expect(find.textContaining(startupNoRetryNext), findsOneWidget);
      expect(find.textContaining('0000000000000c4f2a'), findsNothing, reason: 'the whole id only in 技術資訊');
      await t.tap(find.text('技術資訊（給維修人員看）'));
      await t.pumpAndSettle();
      expect(find.text(startupTechAsk), findsOneWidget);
      expect(find.textContaining('節點紀錄：0000000000000c4f2a'), findsOneWidget);
      await t.ensureVisible(find.text('複製文字'));
      await t.pumpAndSettle();
      await t.tap(find.text('複製文字'));
      await t.pump();
      expect(copied, contains('節點紀錄：0000000000000c4f2a'));
      expect(copied, contains('啟動檢查：'));
    });

    // review pr6 B-1: the startup line in logcat carries the node ids' last four only (the whole id stays in 技術資訊).
    // Negative control: main.dart's debugPrint without NodeLink.mask -> the whole id in the line -> FAIL.
    testWidgets('B-1: the logcat startup line has no whole device id', (t) async {
      final printed = <String>[];
      final old = debugPrint;
      debugPrint = (String? m, {int? wrapWidth}) => printed.add(m ?? '');
      try {
        await start(t, answer(appUsable: false, claim: false, login: false, recover: false, makeNetwork: false, soft: true));
      } finally {
        debugPrint = old;
      }
      final startup = printed.where((l) => l.startsWith('BMAPP ') && l.contains('節點紀錄：')).toList();
      expect(startup, hasLength(1), reason: printed.join('\n'));
      expect(startup.single, isNot(contains('0000000000000c4f2a')));
      expect(startup.single, contains('節點紀錄：…'));
    });

    // design §4 / §4.1 「單一金鑰遺失」: record AES lost. Negative control: the index not built -> FAIL
    testWidgets('record AES lost: said so (not "not hardware"), the node index shown, no button', (t) async {
      await start(t, answer(appUsable: false, claim: false, login: false, recover: false, makeNetwork: false, gone: {'RECORD_AES'}));
      expect(find.textContaining('啟動檢查：${KeyAbilities.aesGone}'), findsOneWidget);
      expect(find.textContaining(KeyAbilities.appOff), findsNothing);
      expect(find.text('這些節點需要重燒卡回收：'), findsOneWidget);
      expect(find.text('節點 4F2A') /* #329 PR 6 P1-3: the last four */, findsOneWidget);
      // review round 2 MINOR 3: an unfinished claim is listed too, said as not confirmed (full device_id).
      // Negative control: claim-pending not listed -> FAIL
      expect(find.text('節點 BEEF（認領沒有確認）'), findsOneWidget);
      expect(find.bySubtype<ButtonStyleButton>(), findsNothing);
      expect(calls, isNot(contains('open')));
    });

    testWidgets('all four keys lost (marker there): the only way out is said, the node index shown', (t) async {
      await start(
          t,
          answer(
              appUsable: false,
              claim: false,
              login: false,
              recover: false,
              makeNetwork: false,
              gone: {'RECORD_AES', 'OWNER_SIGN', 'ADMIN_SIGN', 'OWNER_ENC'}));
      expect(find.textContaining('啟動檢查：${KeyAbilities.allGone}'), findsOneWidget);
      expect(find.text('節點 4F2A') /* #329 PR 6 P1-3: the last four */, findsOneWidget);
      expect(find.bySubtype<ButtonStyleButton>(), findsNothing);
      expect(calls, isNot(contains('firstRun')), reason: 'with a marker the keys are never made again');
    });

    // the first run was cut short (no marker, no record; Kotlin deleted what it made): not "clear the app data"
    testWidgets('first run failed: said so, with a retry; not the "all keys lost" way out', (t) async {
      rust.marker = null;
      await start(
          t,
          answer(
              appUsable: false,
              claim: false,
              login: false,
              recover: false,
              makeNetwork: false,
              gone: {'RECORD_AES', 'OWNER_SIGN', 'ADMIN_SIGN', 'OWNER_ENC'}));
      expect(calls, contains('firstRun'));
      expect(find.textContaining('啟動檢查：金鑰沒有建立成功，App 暫時不能使用'), findsOneWidget);
      expect(find.textContaining('清除 App 資料'), findsNothing);
      expect(find.text('這些節點需要重燒卡回收：'), findsNothing);
      expect(find.widgetWithText(FilledButton, '再試一次'), findsOneWidget);
      expect(find.bySubtype<ButtonStyleButton>(), findsOneWidget);
    });

    for (final (name, keys) in <(String, Object?)>[
      ('a platform error', PlatformException(code: 'keystore', message: 'KeyStoreException')),
      ('no answer', null),
      ('an entry that is not a bool', answer()..['appUsable'] = 'true'),
    ]) {
      // may be transient: its own words and a retry, never "not hardware" / "lost", and no "re-flash these nodes".
      // Negative control: the unreadable case told like "not hardware" again -> FAIL
      testWidgets('the key levels cannot be read ($name): the app is off, said as unreadable, with a retry', (t) async {
        await start(t, keys);
        expect(find.textContaining('啟動檢查：${KeyAbilities.unreadOff}'), findsOneWidget);
        expect(find.textContaining(KeyAbilities.appOff), findsNothing);
        expect(find.textContaining('不見了'), findsNothing);
        expect(find.textContaining('重燒卡'), findsNothing);
        expect(find.text('我的節點'), findsNothing);
        // review round 2 MINOR 4: the plaintext index is there while the levels cannot be read (listing needs no key),
        // without any re-flash advice. Negative control: the index only when not unreadable -> FAIL
        expect(find.text('手機裡有這些節點的紀錄（沒有打開，也沒有刪除）：'), findsOneWidget);
        expect(find.text('節點 4F2A') /* #329 PR 6 P1-3: the last four */, findsOneWidget);
        expect(find.text('節點 BEEF（認領沒有確認）'), findsOneWidget);
        expect(find.widgetWithText(FilledButton, '再試一次'), findsOneWidget);
        expect(find.bySubtype<ButtonStyleButton>(), findsOneWidget, reason: 'the retry is the only button');
        // the retry reads again: this time the keys answer
        mock(t, answer());
        await t.tap(find.text('再試一次'));
        await t.pumpAndSettle();
        expect(calls, contains('keyLevels'));
        expect(find.textContaining('啟動檢查：正常'), findsOneWidget);
        expect(find.text('再試一次'), findsNothing);
        expect(live(t).length, 2, reason: '#329 PR 6 D1: 認領節點 and (dev) 附近的節點');
      });
    }

    // review round 2 MINOR 5: a start step that throws something other than a PlatformException (the Rust store) ends
    // the check with its reason and a retry. Negative control: the catch in _run removed -> FAIL (endless spinner)
    for (final (name, fail) in <(String, void Function(Object))>[
      ('the sweep', (e) => rust.sweepError = e),
      ('the install marker read', (e) => rust.markerError = e),
    ]) {
      testWidgets('start: $name fails -> 「啟動檢查失敗」 with the reason and a retry; the retry starts again', (t) async {
        fail('store: disk I/O error');
        mock(t, answer());
        await t.pumpWidget(const BatmanApp());
        await t.pumpAndSettle();
        expect(find.byType(CircularProgressIndicator), findsNothing, reason: 'the check ended');
        expect(find.textContaining('啟動檢查失敗：store: disk I/O error'), findsOneWidget);
        expect(find.textContaining('啟動檢查：正常'), findsNothing);
        expect(find.text('我的節點'), findsNothing);
        expect(find.widgetWithText(FilledButton, '再試一次'), findsOneWidget);
        expect(find.bySubtype<ButtonStyleButton>(), findsOneWidget, reason: 'the retry is the only button');
        rust.sweepError = null;
        rust.markerError = null;
        await t.tap(find.text('再試一次'));
        await t.pumpAndSettle();
        expect(find.textContaining('啟動檢查：正常'), findsOneWidget);
        expect(live(t).length, 2, reason: '#329 PR 6 D1: 認領節點 and (dev) 附近的節點');
      });
    }

    // #329 PR 7 T14: no install marker and the record store cannot be read (Rust storeHasRecords -> Err: a kind's path
    // is a plain file, a folder or an entry unreadable). Records may be there: firstRun is not called (it would make
    // them unopenable for good), the app stays off even though every key fits, the reason with the store's technical
    // part folded, the next step that warns against clearing data, and a retry. The negative controls of the root fix
    // are the Rust tests (simple.rs t14_*); here the negative control is the dedicated branch in _install removed (the
    // error then reaches _run's catch: 「啟動檢查失敗」 without 「金鑰保持原樣」 or the next step) -> FAIL.
    testWidgets('T14: no marker, the record store unreadable -> no firstRun, keys kept, retry; never home', (t) async {
      rust.marker = null;
      rust.hasRecordsError = '讀不到手機裡的紀錄\u001erecord store unreadable: node: Not a directory (os error 20)\u001f';
      mock(t, answer()); // every key fits (RECORD_AES too): only the store keeps the app off
      AppLink.forgetForTest();
      addTearDown(() {
        AppLink.instance?.link.dispose();
        AppLink.forgetForTest();
      });
      await t.pumpWidget(BatmanApp(makeLink: (dir) => AppLink.create(platform: platform, filesDir: dir, ble: _ScanBle())));
      await t.pumpAndSettle();
      expect(calls, isNot(contains('firstRun')), reason: 'no key is made over records the store could not show');
      expect(find.byType(HomePage), findsNothing);
      expect(AppLink.instance, isNull, reason: 'no NodeLink: the app is off');
      expect(find.text('啟動檢查：讀不到手機裡的紀錄$recordsUnreadKept'), findsOneWidget);
      expect(find.text('啟動檢查：讀不到手機裡的紀錄，金鑰保持原樣，沒有重建'), findsOneWidget, reason: 'the words themselves');
      expect(find.text('關掉 App 再開、重開手機；仍然如此請找維修人員，不要清除資料或重裝'), findsOneWidget);
      expect(find.textContaining('請清除'), findsNothing, reason: 'never advice to clear the data');
      expect(find.textContaining('啟動檢查失敗'), findsNothing);
      expect(find.widgetWithText(FilledButton, '再試一次'), findsOneWidget);
      // the hero's own fold: the store's technical part
      await t.tap(find.descendant(of: find.byKey(const Key('hero-tech')), matching: find.byType(InkWell)));
      await t.pumpAndSettle();
      expect(find.textContaining('record store unreadable: node: Not a directory'), findsWidgets);
      // the retry checks again: the store reads now (no record) -> the first run, as on a first install (this mock's
      // firstRun fails and Kotlin deletes what it made: no key)
      rust.hasRecordsError = null;
      mock(
          t,
          answer(
              appUsable: false,
              claim: false,
              login: false,
              recover: false,
              makeNetwork: false,
              gone: {'RECORD_AES', 'OWNER_SIGN', 'ADMIN_SIGN', 'OWNER_ENC'}));
      await t.tap(find.widgetWithText(FilledButton, '再試一次'));
      await t.pumpAndSettle();
      expect(calls, contains('firstRun'));
      expect(find.textContaining('啟動檢查：金鑰沒有建立成功'), findsOneWidget);
    });

    testWidgets('claim not allowed: 「認領節點」 is off with its reason; the restart line stays', (t) async {
      await start(t, answer(claim: false, recover: false));
      expect(find.textContaining('復原／隊員金鑰不是硬體保護，不能認領節點'), findsOneWidget);
      expect(t.widget<OutlinedButton>(find.widgetWithText(OutlinedButton, '認領節點')).onPressed, isNull);
      expect(find.text(restartLine), findsOneWidget);
    });

    testWidgets('dev build with a SOFTWARE owner_enc (S20): usable, with the notice', (t) async {
      await start(t, answer(soft: true));
      expect(find.textContaining('啟動檢查：正常'), findsOneWidget);
      expect(find.textContaining('只有軟體保護，只適合開發使用'), findsOneWidget);
      expect(live(t).length, 2, reason: '#329 PR 6 D1: 認領節點 and (dev) 附近的節點');
    });
  });
}

/// A radio for the start page's NodeLink: a status stream and a scan that never reports anything.
class _ScanBle implements FlutterReactiveBle {
  @override
  Stream<BleStatus> get statusStream => const Stream.empty();
  @override
  Stream<ConnectionStateUpdate> get connectedDeviceStream => const Stream.empty();
  @override
  Stream<DiscoveredDevice> scanForDevices(
          {required List<Uuid> withServices, ScanMode scanMode = ScanMode.balanced, bool requireLocationServicesEnabled = true}) =>
      StreamController<DiscoveredDevice>().stream;
  @override
  dynamic noSuchMethod(Invocation i) => throw UnimplementedError('${i.memberName}');
}
