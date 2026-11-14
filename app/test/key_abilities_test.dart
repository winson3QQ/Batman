// design v8.5.1 §4.1 table: what the live key levels allow. Kotlin decides (KeyPolicy.abilities, KeyPolicyTest) and
// answers `keyLevels`; Dart must obey that answer:
// - record AES not hardware (appUsable false) -> the whole app is off: the start page has no way to a node page;
// - owner signing not hardware -> no claim / login (and so no recovery, no network);
// - admin not hardware -> no network;
// - owner_enc not allowed (field: SOFTWARE) -> no claim / recovery; dev + SOFTWARE owner_enc -> allowed, with the notice;
// - no answer, a missing entry, an entry that is not a bool, a platform error -> nothing allowed (fail closed).
// The gate inside a claim is in claim_target_test; here: the decision, the start page, and the login of 「我的節點」.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_reactive_ble/flutter_reactive_ble.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:batman_app/key_abilities.dart';
import 'package:batman_app/main.dart';
import 'package:batman_app/nodes.dart';
import 'package:batman_app/src/rust/api/simple.dart';
import 'package:batman_app/src/rust/frb_generated.dart';

const platform = MethodChannel('dev.batman/platform');

/// The `keyLevels` answer (MainActivity): the four levels by role name, then what KeyPolicy allows.
Map<String, Object?> answer(
        {bool appUsable = true, bool claim = true, bool login = true, bool recover = true, bool makeNetwork = true, bool soft = false}) =>
    {
      'RECORD_AES': appUsable ? 1 : 0,
      'OWNER_SIGN': 1,
      'ADMIN_SIGN': 1,
      'OWNER_ENC': soft ? 0 : 1,
      'appUsable': appUsable,
      'claim': claim,
      'login': login,
      'recover': recover,
      'makeNetwork': makeNetwork,
      'softOwnerEnc': soft,
    };

class FakeRust implements RustLibApi {
  @override
  BuildInfo crateApiSimpleBuildInfo() => const BuildInfo(devTrust: true, crateVersion: 'test');

  @override
  String crateApiSimpleSelftest() => 'ok';

  @override
  Future<int> crateApiSimpleStoreSweep({required String dir}) async => 0;

  @override
  Future<String?> crateApiSimpleStoreReadMarker({required String dir}) async => 'marker';

  @override
  Future<List<String>> crateApiOwnerListNodes({required String dir}) async => ['0000000000000c4f2a'];

  @override
  dynamic noSuchMethod(Invocation i) => throw UnimplementedError('${i.memberName}');
}

/// never reached: the login is refused before BLE
class NoBle implements FlutterReactiveBle {
  @override
  dynamic noSuchMethod(Invocation i) => throw UnimplementedError('${i.memberName}');
}

void main() {
  setUpAll(() => RustLib.initMock(api: FakeRust()));
  final calls = <String>[];

  /// [keys]: the `keyLevels` answer; a PlatformException is thrown
  void mock(WidgetTester t, Object? keys) {
    calls.clear();
    t.binding.defaultBinaryMessenger.setMockMethodCallHandler(platform, (c) async {
      calls.add(c.method);
      switch (c.method) {
        case 'devTrust':
          return true;
        case 'filesDir':
          return '/data/user/0/app/files';
        case 'keyLevels':
          if (keys is PlatformException) throw keys;
          return keys;
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
      expect(a.refusal(KeyUse.claim), contains('復原／成員金鑰不是硬體保護，不能認領節點'));
      expect(a.refusal(KeyUse.recover), contains('復原／成員金鑰不是硬體保護'));
    });

    test('dev build with a SOFTWARE owner_enc (S20): everything on, the notice flag set', () {
      final a = KeyAbilities.from(answer(soft: true));
      expect(a.appUsable, true);
      expect(a.softOwnerEnc, true);
      all(a, true);
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
        {'APPUSABLE': true, 'Claim': true, 'login': true, 'recover': true, 'makeNetwork': true, 'softOwnerEnc': false},
      ];
      for (final m in bad) {
        final a = KeyAbilities.from(m);
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

    testWidgets('every key fits: the three entries are there and on', (t) async {
      await start(t, answer());
      expect(find.textContaining('啟動檢查：正常'), findsOneWidget);
      expect(find.text('我的節點'), findsOneWidget);
      expect(find.text('認領節點'), findsOneWidget);
      expect(live(t).length, 3);
    });

    // design §8 test row: an emulator (all SOFTWARE) -> the app is off
    testWidgets('record AES not hardware: said so, and no button leads anywhere', (t) async {
      await start(t, answer(appUsable: false, claim: false, login: false, recover: false, makeNetwork: false, soft: true));
      expect(find.textContaining('啟動檢查：${KeyAbilities.appOff}'), findsOneWidget);
      expect(find.textContaining('啟動檢查：正常'), findsNothing);
      expect(find.text('我的節點'), findsNothing);
      expect(find.text('認領節點'), findsNothing);
      expect(find.bySubtype<ButtonStyleButton>(), findsNothing);
    });

    for (final (name, keys) in <(String, Object?)>[
      ('a platform error', PlatformException(code: 'keystore', message: 'KeyStoreException')),
      ('no answer', null),
      ('an entry that is not a bool', answer()..['appUsable'] = 'true'),
    ]) {
      testWidgets('the key levels cannot be read ($name): the app is off', (t) async {
        await start(t, keys);
        expect(find.textContaining(KeyAbilities.appOff), findsOneWidget);
        expect(find.bySubtype<ButtonStyleButton>(), findsNothing);
      });
    }

    testWidgets('claim not allowed: 「認領節點」 is off with its reason; 「我的節點」 stays', (t) async {
      await start(t, answer(claim: false, recover: false));
      expect(find.textContaining('復原／成員金鑰不是硬體保護，不能認領節點'), findsOneWidget);
      expect(t.widget<OutlinedButton>(find.widgetWithText(OutlinedButton, '認領節點')).onPressed, isNull);
      expect(t.widget<FilledButton>(find.widgetWithText(FilledButton, '我的節點')).onPressed, isNotNull);
    });

    testWidgets('dev build with a SOFTWARE owner_enc (S20): usable, with the notice', (t) async {
      await start(t, answer(soft: true));
      expect(find.textContaining('啟動檢查：正常'), findsOneWidget);
      expect(find.textContaining('只有軟體保護，只適合開發使用'), findsOneWidget);
      expect(live(t).length, 3);
    });
  });

  // the records stay readable when the owner key does not fit (§4.1 單一金鑰遺失), so the page opens: the login itself refuses
  testWidgets('我的節點: login not allowed -> refused before the record or BLE is touched', (t) async {
    mock(t, answer(claim: false, login: false, recover: false, makeNetwork: false));
    await t.pumpWidget(MaterialApp(home: NodesPage(ble: NoBle())));
    await t.pumpAndSettle();
    await t.tap(find.text('節點 …4f2a'));
    await t.pumpAndSettle();
    expect(find.textContaining('擁有者金鑰不是硬體保護，不能認領或登入節點'), findsOneWidget);
    expect(calls, isNot(contains('blePermissions')));
    expect(calls, isNot(contains('open')));
  });
}
