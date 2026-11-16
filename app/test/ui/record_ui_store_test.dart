// #329 PR 2 review r3 (E-m8): RecordUiStore, the app's `ui/state-v1` store — the record store's header errors become
// UiHeaderBad, a record that does not open is (generation, null), and a write at the wrong generation is refused
// before anything is sealed.
import 'package:batman_app/src/rust/api/claim.dart' show SealParams;
import 'package:batman_app/src/rust/api/owner.dart' show SealedRecord;
import 'package:batman_app/src/rust/frb_generated.dart';
import 'package:batman_app/ui/ui_state.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

class FakeRust implements RustLibApi {
  Object? readError, paramsError;
  SealedRecord? sealed;
  BigInt nextGen = BigInt.one;
  final calls = <String>[];

  @override
  Future<SealedRecord?> crateApiOwnerStoreReadSealed({required String dir, required String rel}) async {
    calls.add('read $rel');
    if (readError != null) throw readError!;
    return sealed;
  }

  @override
  Future<SealParams> crateApiClaimStoreSealParams({required String dir, required String rel}) async {
    calls.add('params $rel');
    if (paramsError != null) throw paramsError!;
    return SealParams(generation: nextGen, aad: Uint8List.fromList([9]));
  }

  @override
  Future<BigInt> crateApiOwnerStoreWriteCas(
      {required String dir, required String rel, required BigInt expectedGen, required List<int> sealed}) async {
    calls.add('cas $rel $expectedGen');
    return expectedGen + BigInt.one;
  }

  @override
  dynamic noSuchMethod(Invocation i) => throw UnimplementedError('${i.memberName}');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final rust = FakeRust();
  setUpAll(() => RustLib.initMock(api: rust));
  const ch = MethodChannel('dev.batman/platform');
  final platform = <String>[];
  var opens = true;
  setUp(() {
    rust
      ..readError = null
      ..paramsError = null
      ..sealed = null
      ..nextGen = BigInt.one
      ..calls.clear();
    platform.clear();
    opens = true;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(ch, (c) async {
      platform.add(c.method);
      if (c.method == 'open') {
        if (!opens) throw PlatformException(code: 'AEADBadTag');
        return Uint8List.fromList([1, 2]);
      }
      if (c.method == 'seal') return Uint8List.fromList([7]);
      return null;
    });
  });
  final s = RecordUiStore('/r', ch);

  test('no record -> null; a record -> its generation and the opened bytes, under ui/state-v1', () async {
    expect(await s.read(), isNull);
    rust.sealed = SealedRecord(generation: BigInt.from(5), sealed: Uint8List(3), aad: Uint8List(1));
    final r = await s.read();
    expect(r!.$1, 5);
    expect(r.$2, [1, 2]);
    expect(rust.calls.every((c) => c.endsWith(uiRel)), isTrue);
  });

  test('a record that does not open (a new install\'s key) -> (generation, null), not an error', () async {
    rust.sealed = SealedRecord(generation: BigInt.from(4), sealed: Uint8List(3), aad: Uint8List(1));
    opens = false;
    final r = await s.read();
    expect((r!.$1, r.$2), (4, null));
  });

  for (final e in ['NotARecord', 'UnknownVersion']) {
    test('$e on read or write -> UiHeaderBad (F39: removed before the next write)', () async {
      rust.readError = Exception('store: $e');
      await expectLater(s.read(), throwsA(isA<UiHeaderBad>()));
      rust.paramsError = Exception('store: $e');
      await expectLater(s.write(0, Uint8List(1)), throwsA(isA<UiHeaderBad>()));
      expect(platform, isNot(contains('seal')));
    });
  }

  test('another error stays itself (not a header problem)', () async {
    rust.readError = Exception('io: disk');
    await expectLater(s.read(), throwsA(isNot(isA<UiHeaderBad>())));
  });

  test('a write at the expected generation is sealed and written by CAS; at another it is refused, nothing sealed', () async {
    rust.nextGen = BigInt.from(3);
    expect(await s.write(2, Uint8List(1)), 3);
    expect(platform, ['seal']);
    expect(rust.calls.last, 'cas $uiRel 2');
    platform.clear();
    await expectLater(s.write(5, Uint8List(1)), throwsStateError);
    expect(platform, isEmpty);
  });
}
