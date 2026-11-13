// design 254-app-claim-noover v2.1: pressing 「認領」 first asks Rust what the phone holds for the QR's device id
// (claimTarget), before the BLE permission (the first step towards BLE); nothing is written here (the records are
// decided at PersistPending / CLAIMED: claim_records_test).
// - nothing -> the claim goes on;
// - an unfinished claim of the same QR -> the claim goes on (the recovery's first step, §5.2-1);
// - an unfinished claim of another QR -> R4 dialog; a node record (also with a pending) -> R7 dialog; cancel = nothing;
// - a record that cannot be read, or a pending that cannot be opened (T6) -> no claim, 「讀不到…」.
// The platform channel and the Rust API are fakes; nothing needs BLE.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:batman_app/claim.dart';
import 'package:batman_app/src/rust/api/claim.dart';
import 'package:batman_app/src/rust/api/owner.dart' show SealedRecord;
import 'package:batman_app/src/rust/frb_generated.dart';

const qrText = 'a201726261746d616e2d746573742d71722d303102582000112233445566778899aabbccddeeff0011';
const deviceId = '0000000000000c4f2a';
const files = '/data/user/0/app/files';

class FakeRust implements RustLibApi {
  /// what claimTarget answers; a String is thrown
  Object target = ClaimTarget.nothing;
  bool pendingMatches = true;
  final calls = <String>[];

  @override
  Future<ClaimQr> crateApiClaimParseClaimQr({required String text}) async => ClaimQr(deviceId: deviceId, k: Uint8List(32));

  @override
  Future<ClaimTarget> crateApiClaimClaimTarget({required String dir, required String deviceId}) async {
    calls.add('claimTarget $dir $deviceId');
    final t = target;
    if (t is String) throw t;
    return t as ClaimTarget;
  }

  @override
  Future<SealedRecord?> crateApiOwnerStoreReadSealed({required String dir, required String rel}) async {
    calls.add('read $rel');
    return SealedRecord(generation: BigInt.one, sealed: Uint8List(3), aad: Uint8List(2));
  }

  @override
  Future<bool> crateApiClaimPendingMatchesQr({required List<int> record, required ClaimQr qr}) async {
    calls.add('matches');
    return pendingMatches;
  }

  @override
  dynamic noSuchMethod(Invocation i) => throw UnimplementedError('${i.memberName}');
}

void main() {
  final rust = FakeRust();
  setUpAll(() => RustLib.initMock(api: rust));
  final platform = <String>[];

  Future<void> claim(WidgetTester t, Object target, {bool matches = true, bool openFails = false}) async {
    rust
      ..target = target
      ..pendingMatches = matches
      ..calls.clear();
    platform.clear();
    t.binding.defaultBinaryMessenger.setMockMethodCallHandler(const MethodChannel('dev.batman/platform'), (c) async {
      platform.add(c.method);
      switch (c.method) {
        case 'scanQr':
          return qrText;
        case 'filesDir':
          return files;
        case 'open':
          if (openFails) throw PlatformException(code: 'open', message: 'key gone');
          return Uint8List(4);
        case 'blePermissions':
          return false; // the claim stops here: no BLE in this test
      }
      return null;
    });
    await t.pumpWidget(const MaterialApp(home: ClaimPage()));
    await t.tap(find.text('掃描 QR'));
    await t.pumpAndSettle();
    await t.tap(find.text('認領'));
    await t.pumpAndSettle();
  }

  const noBle = '沒有藍牙權限（請在手機設定裡允許）';
  // T8: the dialog texts, literally (R4 / R7)
  const otherQr = '手機裡有這台節點一次沒完成的認領，用的是另一張 QR 碼。只有在你確定這張 QR 碼才是對的（例如之前貼錯）時才改用它：'
      '舊的認領紀錄會留在手機上，但 App 之後不會再用它。要改用這張 QR 碼嗎？';
  const reclaim = '這台節點已在你的清單裡。只有在你剛把這台節點重置回未認領時才重新認領：舊紀錄會留在手機上，但 App 之後不會再用它、'
      '也不會顯示在清單裡。要重新認領嗎？';
  const reclaimPending = '這台節點已在你的清單裡。手機裡也有這台一次沒完成的認領。只有在你剛把這台節點重置回未認領時才重新認領：'
      '舊紀錄會留在手機上，但 App 之後不會再用它、也不會顯示在清單裡。要重新認領嗎？';

  testWidgets('nothing held: the claim goes on', (t) async {
    await claim(t, ClaimTarget.nothing);
    expect(rust.calls, ['claimTarget $files/records $deviceId']);
    expect(platform, contains('blePermissions'));
    expect(find.text(noBle), findsOneWidget);
  });

  testWidgets('an unfinished claim of the same QR: the claim goes on (recovery §5.2-1), no question', (t) async {
    await claim(t, ClaimTarget.pending);
    expect(rust.calls, ['claimTarget $files/records $deviceId', 'read claim-pending/$deviceId', 'matches']);
    expect(platform, containsAllInOrder(['open', 'blePermissions']));
    expect(find.byType(AlertDialog), findsNothing);
    expect(find.text('手機裡有這台節點一次沒完成的認領，這次接著再試（沿用那次的認領紀錄）'), findsOneWidget);
  });

  for (final (name, target, text, yes, no) in [
    ('an unfinished claim of another QR (R4)', ClaimTarget.pending, otherQr, '改用這張 QR 碼', '沒有改用這張 QR 碼，手機裡的紀錄沒有改動'),
    ('a node record (R7)', ClaimTarget.node, reclaim, '重新認領', '沒有重新認領，手機裡的紀錄沒有改動'),
    ('a node record and a pending (R7 + the pending line)', ClaimTarget.nodeAndPending, reclaimPending, '重新認領', '沒有重新認領，手機裡的紀錄沒有改動'),
  ]) {
    for (final confirm in [false, true]) {
      testWidgets('$name: asked; ${confirm ? 'confirm goes on' : 'cancel goes nowhere'}', (t) async {
        await claim(t, target, matches: false);
        expect(find.text(text), findsOneWidget);
        expect(platform, isNot(contains('blePermissions')), reason: 'nothing before the answer');
        await t.tap(find.text(confirm ? yes : '取消'));
        await t.pumpAndSettle();
        expect(platform.contains('blePermissions'), confirm);
        expect(find.text(confirm ? noBle : no), findsOneWidget);
      });
    }
  }

  testWidgets('a record that cannot be read: no claim', (t) async {
    await claim(t, 'NotARecord');
    expect(platform, isNot(contains('blePermissions')));
    expect(find.text('讀不到手機裡這台節點的紀錄，這次不認領：NotARecord'), findsOneWidget);
  });

  testWidgets('T6: a pending that cannot be opened is unreadable, not "another QR"', (t) async {
    await claim(t, ClaimTarget.pending, openFails: true);
    expect(platform, isNot(contains('blePermissions')));
    expect(find.byType(AlertDialog), findsNothing);
    expect(find.textContaining('讀不到手機裡這台節點的紀錄，這次不認領'), findsOneWidget);
    expect(rust.calls, isNot(contains('matches')));
  });
}
