// #254: on the S20 the byte lists a platform-channel call returns are READ-ONLY views on the engine's reply buffer
// (ReadBuffer.getUint8List returns a view, flutter foundation/serialization.dart:228-231). 254-app-replay found it on
// the phone (design §22: `fillRange` on `ecdh`'s z threw 「Cannot modify an unmodifiable list」). nodes.dart did the
// same in the `finally` of both member imports: the import finished, then the zeroing threw. These tests answer every
// platform call with a read-only buffer, as the phone does, and run both imports through the page.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_reactive_ble/flutter_reactive_ble.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:batman_app/nodes.dart';
import 'package:batman_app/member_ui.dart' show SasConfirmView;
import 'package:batman_app/src/rust/api/member.dart';
import 'package:batman_app/src/rust/api/owner.dart';
import 'package:batman_app/src/rust/api/rekey.dart';
import 'package:batman_app/src/rust/frb_generated.dart';

const zBytes = [7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7];

OwnerStep persist(String rel, String detail) => OwnerStep(
    kind: OwnerKind.persistMnet,
    frames: const [],
    signInput: Uint8List(0),
    detail: detail,
    record: Uint8List.fromList([1, 2, 3]),
    rel: rel,
    generation: BigInt.one,
    aad: Uint8List(1),
    expectedGen: BigInt.zero,
    pollLink: false,
    hex: '',
    sas: '',
    renewed: false,
    sent: false,
    left: false,
    waitMs: BigInt.zero,
    sendUpdate: false,
    info: Uint8List(0),
    sw: false);

class FakeRust implements RustLibApi {
  final calls = <String>[];
  List<int>? zSeen; // the very list nodes.dart handed to Rust

  @override
  Future<List<String>> crateApiOwnerListNodes({required String dir}) async => const [];
  @override
  Future<SealedRecord?> crateApiOwnerStoreReadSealed({required String dir, required String rel}) async =>
      rel.startsWith('node/') ? null : SealedRecord(generation: BigInt.one, sealed: Uint8List.fromList([9, 9]), aad: Uint8List(1));
  @override
  Future<BigInt> crateApiOwnerStoreWriteCas(
      {required String dir, required String rel, required BigInt expectedGen, required List<int> sealed}) async {
    calls.add('write $rel');
    return BigInt.two;
  }

  @override
  Future<void> crateApiClaimStoreRemove({required String dir, required String rel}) async => calls.add('remove $rel');

  // member approval (member-join §4 step 7)
  @override
  String crateApiMemberApprovalNetId({required String hex}) => 'n1';
  @override
  ImportPrep crateApiMemberMemberImportPrepare(
          {required String hex, required BigInt pendGen, Uint8List? pendPlain, Uint8List? mnetPlain, required bool replace}) =>
      ImportPrep(state: ImportState.ready, sas: '123456', ephPub: Uint8List(65), pendGen: BigInt.one, detail: '');
  @override
  OwnerStep crateApiMemberMemberImportApproval(
      {required String hex,
      required BigInt pendGen,
      required List<int> pendPlain,
      required BigInt expectedPendGen,
      Uint8List? mnetPlain,
      required BigInt mnetGen,
      required List<int> z,
      required String confirmedSas,
      required bool replace}) {
    zSeen = z;
    calls.add('approval z=${z.join(',') == zBytes.join(',')}');
    return persist('mnet/n1', 'IMPORTED-APPROVAL');
  }

  // member update (remove-member §3.4)
  @override
  String crateApiRekeyUpdateNetId({required String hex}) => 'n1';
  @override
  UpdatePrep crateApiRekeyMemberUpdatePrepare(
          {required String hex, Uint8List? mnetPlain, required BigInt mnetGen, required List<Uint8List> nodeRecords, required List<int> ownerEncPub}) =>
      UpdatePrep(state: UpdateState.advance, ephPub: Uint8List(65), mnetGen: BigInt.one, detail: '');
  @override
  OwnerStep crateApiRekeyMemberUpdateImport(
      {required String hex,
      Uint8List? mnetPlain,
      required BigInt mnetGen,
      required BigInt expectedGen,
      required List<Uint8List> nodeRecords,
      required List<int> ownerEncPub,
      required List<int> z}) {
    zSeen = z;
    calls.add('update z=${z.join(',') == zBytes.join(',')}');
    return persist('mnet/n1', 'IMPORTED-UPDATE');
  }

  @override
  dynamic noSuchMethod(Invocation i) => throw UnimplementedError('${i.memberName}');
}

class NoBle implements FlutterReactiveBle {
  @override
  dynamic noSuchMethod(Invocation i) => throw UnimplementedError('${i.memberName}');
}

/// every platform reply as an unmodifiable buffer, as the S20 delivers it
void mockPlatformReadOnly(WidgetTester t, Future<Object?> Function(MethodCall c) handle) {
  const codec = StandardMethodCodec();
  t.binding.defaultBinaryMessenger.setMockMessageHandler('dev.batman/platform', (ByteData? msg) async {
    final call = codec.decodeMethodCall(msg);
    try {
      return codec.encodeSuccessEnvelope(await handle(call)).asUnmodifiableView();
    } on PlatformException catch (e) {
      return codec.encodeErrorEnvelope(code: e.code, message: e.message, details: e.details).asUnmodifiableView();
    }
  });
}

void main() {
  final rust = FakeRust();
  setUpAll(() => RustLib.initMock(api: rust));
  setUp(() {
    rust.calls.clear();
    rust.zSeen = null;
  });

  Future<void> paste(WidgetTester t, String label) async {
    mockPlatformReadOnly(t, (c) async {
      switch (c.method) {
        case 'filesDir':
          return '/data/user/0/app/files';
        case 'devTrust':
          return true;
        case 'open':
          return Uint8List.fromList([5, 5, 5]);
        case 'seal':
          return Uint8List.fromList([6, 6]);
        case 'publicKeys':
          return {'owner': Uint8List(65), 'ownerEnc': Uint8List(65), 'admin': Uint8List(65)};
        case 'ecdh':
          return Uint8List.fromList(zBytes);
      }
      return null;
    });
    t.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (c) async {
      if (c.method == 'Clipboard.getData') return {'text': 'a1b2'};
      return null;
    });
    await t.pumpWidget(MaterialApp(home: NodesPage(ble: NoBle())));
    await t.pumpAndSettle();
    final b = find.byKey(Key('paste:$label'));
    await t.ensureVisible(b);
    await t.pumpAndSettle();
    await t.tap(b);
    await t.pumpAndSettle();
  }

  // member approval import (main nodes.dart:960-996): the import completes, the page says so, and the zeroing of z
  // does not throw on a read-only channel list; the list Rust got is zeroed afterwards (it is the page's own copy).
  // Negative control = main's code (fillRange on the channel's list) -> FAIL "Cannot modify an unmodifiable list".
  testWidgets('member approval import: read-only ecdh reply -> imported, no exception, z zeroed', (t) async {
    await paste(t, '貼上同意碼');
    await t.tap(find.byKey(const Key('sasConfirm')));
    await t.pumpAndSettle();
    expect(t.takeException(), isNull);
    expect(rust.calls, ['approval z=true', 'write mnet/n1', 'remove mpend/n1']);
    expect(find.textContaining('IMPORTED-APPROVAL'), findsOneWidget);
    expect(find.byType(SasConfirmView), findsNothing, reason: 'the SAS page was popped after the import (on main it stayed up: the throw came before pop)');
    expect(rust.zSeen, everyElement(0), reason: 'the page zeroes its own copy of z');
  });

  // member update import (main nodes.dart:1417-1456): same. Negative control = main's code -> FAIL.
  testWidgets('member update import: read-only ecdh reply -> imported, no exception, z zeroed', (t) async {
    await paste(t, '貼上更新包');
    expect(t.takeException(), isNull);
    expect(rust.calls, ['update z=true', 'write mnet/n1']);
    expect(find.textContaining('IMPORTED-UPDATE'), findsOneWidget);
    expect(rust.zSeen, everyElement(0), reason: 'the page zeroes its own copy of z');
  });
}
