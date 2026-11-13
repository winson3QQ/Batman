// design v8.5.1 §5.1: a device id this phone already holds is never claimed over without asking. Pressing 「認領」 first
// asks Rust what the phone holds for the QR's device id (claimTarget), before the BLE permission (the first step that
// leads to BLE) and before anything is written:
// - nothing -> the claim goes on;
// - an unfinished claim (claim-pending) for the same QR -> the claim goes on: that is the recovery's first step
//   (§5.2-1, the new pending reuses K); for another QR -> no claim, the pending stays;
// - a node record (with or without a pending beside it: the node record wins) -> a dialog; cancel = nothing written,
//   nothing sent; confirm = the claim goes on, the old record moves aside only when the new pending is written;
// - a record that cannot be read -> no claim.
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
  Future<void> crateApiClaimStoreForgetNode({required String dir, required String deviceId}) async => calls.add('forget');

  @override
  dynamic noSuchMethod(Invocation i) => throw UnimplementedError('${i.memberName}');
}

void main() {
  final rust = FakeRust();
  setUpAll(() => RustLib.initMock(api: rust));
  final platform = <String>[];

  Future<void> claim(WidgetTester t, Object target, {bool matches = true}) async {
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
          return Uint8List(4);
        case 'blePermissions':
          return false; // the claim stops here: no BLE in a widget test
      }
      return null;
    });
    await t.pumpWidget(const MaterialApp(home: ClaimPage()));
    await t.tap(find.text('掃描 QR'));
    await t.pumpAndSettle();
    await t.tap(find.text('認領'));
    await t.pumpAndSettle();
  }

  const noBle = '[CLAIM_FAIL] 沒有藍牙權限（請在手機設定裡允許）';
  const ask = '這台節點已在你的清單裡。若節點已重燒或重置回未認領，可以重新認領：舊紀錄會保留在手機上（不會刪除），不再顯示在清單裡。要重新認領嗎？';
  const otherQr = '[CLAIM_FAIL] 手機裡有這台節點（…4f2a）一次沒完成的認領，但用的是另一張 QR 碼。為了不蓋掉那次的紀錄，這次不認領；'
      '請用那次的 QR 碼再按「認領」。';

  testWidgets('nothing held: the claim goes on', (t) async {
    await claim(t, ClaimTarget.nothing);
    expect(rust.calls, ['claimTarget $files/records $deviceId']);
    expect(platform, contains('blePermissions'));
    expect(find.text('沒有藍牙權限（請在手機設定裡允許）'), findsOneWidget);
  });

  testWidgets('an unfinished claim with the same QR: the claim goes on (recovery §5.2-1)', (t) async {
    await claim(t, ClaimTarget.pending);
    expect(rust.calls, ['claimTarget $files/records $deviceId', 'read claim-pending/$deviceId', 'matches']);
    expect(platform, containsAllInOrder(['open', 'blePermissions']));
    expect(find.text('手機裡有這台節點一次沒完成的認領，這次接著再試（沿用那次的認領紀錄）'), findsOneWidget);
    expect(find.text('沒有藍牙權限（請在手機設定裡允許）'), findsOneWidget);
  });

  testWidgets('an unfinished claim with another QR: no claim, nothing written', (t) async {
    await claim(t, ClaimTarget.pending, matches: false);
    expect(platform, isNot(contains('blePermissions')), reason: 'nothing goes towards BLE');
    expect(rust.calls, ['claimTarget $files/records $deviceId', 'read claim-pending/$deviceId', 'matches']);
    expect(find.text(otherQr.substring('[CLAIM_FAIL] '.length)), findsOneWidget);
  });

  for (final confirm in [false, true]) {
    testWidgets('a node record: the user is asked; ${confirm ? 'confirm goes on' : 'cancel writes and sends nothing'}', (t) async {
      await claim(t, ClaimTarget.node);
      expect(find.text(ask), findsOneWidget);
      expect(platform, isNot(contains('blePermissions')), reason: 'nothing before the answer');
      await t.tap(find.text(confirm ? '重新認領' : '取消'));
      await t.pumpAndSettle();
      expect(rust.calls, ['claimTarget $files/records $deviceId'], reason: 'the old record moves only with the new pending');
      if (confirm) {
        expect(platform, contains('blePermissions'));
        expect(find.text(noBle.substring('[CLAIM_FAIL] '.length)), findsOneWidget);
      } else {
        expect(platform, isNot(contains('blePermissions')));
        expect(find.text('沒有重新認領，手機裡的紀錄沒有改動'), findsOneWidget);
      }
    });
  }

  testWidgets('a record that cannot be read: no claim', (t) async {
    await claim(t, 'NotARecord');
    expect(platform, isNot(contains('blePermissions')));
    expect(find.text('讀不到手機裡這台節點的紀錄，這次不認領：NotARecord'), findsOneWidget);
  });
}
