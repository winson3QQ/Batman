// #329 §4.3.3-4: SessionProber maps every OwnerSession ending to the core's outcome. Fake Rust session, fake radio.
import 'dart:async';
import 'dart:typed_data';

import 'package:batman_app/src/nodelink/ble_gate.dart';
import 'package:batman_app/src/nodelink/core.dart';
import 'package:batman_app/src/nodelink/lease.dart';
import 'package:batman_app/src/nodelink/prober.dart';
import 'package:batman_app/src/rust/api/owner.dart';
import 'package:batman_app/src/rust/frb_generated.dart';
import 'package:flutter_test/flutter_test.dart';

OwnerStep step(OwnerKind kind, {int loginEnd = 0, int code = 0}) => OwnerStep(
    kind: kind,
    frames: [Uint8List(1)],
    signInput: Uint8List(4),
    detail: '',
    record: Uint8List(0),
    rel: '',
    generation: BigInt.zero,
    aad: Uint8List(0),
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
    sw: false,
    note: '',
    loginEnd: loginEnd,
    loginCode: BigInt.from(code));

StatusView view(String row, String color) => StatusView(
    color: color,
    row: row,
    sentence: '',
    lagNote: '',
    warning: '',
    nodeState: 2,
    netId: '',
    version: '',
    tech: const [],
    fresh: true,
    rateNote: '',
    unfinished: '',
    unfinishedUnderVerdict: false,
    canLeave: false);

/// Each frame from the node pops the next scripted step; the status page request answers with [statusRow].
class FakeSession implements OwnerSession {
  bool disposed = false;
  @override
  void dispose() {
    disposed = true;
    if (throwOnDispose) throw StateError('disposed twice');
  }
  FakeSession(this.script, {this.statusRow = '3', this.color = 'green'});
  final List<OwnerStep> script;
  final String statusRow, color;
  final signs = <int>[];

  @override
  OwnerStep? onFrame({required List<int> frame}) => script.isEmpty ? null : script.removeAt(0);
  @override
  OwnerStep? signed({required List<int> der}) {
    signs.add(der.length);
    return null; // the next frame carries what follows
  }

  bool throwOnStatus = false;
  bool throwOnDispose = false;
  @override
  OwnerStep requestStatusPage() => throwOnStatus ? throw StateError('bridge') : step(OwnerKind.write);
  @override
  StatusView statusView({required bool hasNet, required bool hasMnet}) => view(statusRow, color);
  @override
  dynamic noSuchMethod(Invocation i) => throw UnimplementedError('${i.memberName}');
}

class FakeRust implements RustLibApi {
  FakeSession session = FakeSession([]);
  bool throwOnStatus = false;
  bool throwOnDispose = false;
  @override
  Future<int> crateApiClaimFrameLimit({required List<int> ctrl, required int mtu}) async => 244;
  @override
  (OwnerSession, OwnerStep) crateApiOwnerOwnerSessionStart(
          {required List<int> recordPlain, required List<int> ownerPub, required int frameLimit}) =>
      (session
        ..throwOnStatus = throwOnStatus
        ..throwOnDispose = throwOnDispose, step(OwnerKind.write));
  @override
  dynamic noSuchMethod(Invocation i) => throw UnimplementedError('${i.memberName}');
}

class Radio implements BleBackend {
  final tx = StreamController<List<int>>.broadcast();
  final writes = <int>[];
  final _states = StreamController<(String, bool)>.broadcast(sync: true);
  @override
  Stream<String> scan() => const Stream.empty();
  @override
  Stream<bool> connect(String address, Duration timeout) => (StreamController<bool>()..add(true)).stream; // open while connected
  @override
  Stream<(String, bool)> get linkStates => _states.stream;
  @override
  Future<int> requestMtu(String address, int mtu) async => 247;
  @override
  Future<List<int>> read(String address, Char c) async => [0];
  @override
  Stream<List<int>> subscribe(String address, Char c) => tx.stream;
  @override
  Future<void> write(String address, Char c, List<int> value) async => writes.add(value.length);
}

void main() {
  final rust = FakeRust();
  setUpAll(() => RustLib.initMock(api: rust));

  Future<Outcome> probe(List<OwnerStep> script,
      {String row = '3',
      String color = 'green',
      int frames = 99,
      Duration msg2 = const Duration(seconds: 8),
      Future<void>? cancelled,
      BleBackend? backend,
      SessionProber? prober}) async {
    rust.session = FakeSession([...script], statusRow: row, color: color);
    final reg = LeaseRegistry(after: (d, f) => () {});
    final radio = Radio();
    final gate = BleGate(backend ?? radio, reg, now: () => 0, after: (d, f) => () {});
    final link = gate.connect(reg.token, 'a1');
    await Future<void>.delayed(Duration.zero);
    final p = prober ??
        SessionProber(
          openRecord: (id) async => Uint8List(8),
          ownerPub: () async => Uint8List(65),
          signOwner: (input) async => Uint8List(70),
        );
    final f = p.probe(link, 'Y1', due: Future<void>.delayed(msg2), cancelled: cancelled ?? Completer<void>().future);
    for (var i = 0; i < frames; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 1));
      radio.tx.add([1]);
    }
    return f;
  }

  test('LoggedIn then a status body -> read, with Rust\x27s colour', () async {
    final o = await probe([step(OwnerKind.loggedIn, loginEnd: 1), step(OwnerKind.answer)], color: 'yellow');
    expect((o.res, o.view), (Res.body, 'yellow'));
  });

  test("a status answer that is an error code (row 2') -> errorCode, not a read", () async {
    final o = await probe([step(OwnerKind.loggedIn, loginEnd: 1), step(OwnerKind.answer)], row: "2'");
    expect(o.res, Res.errorCode);
  });

  test('E_UNSUPPORTED (row 1) is a definite answer -> read', () async {
    final o = await probe([step(OwnerKind.loggedIn, loginEnd: 1), step(OwnerKind.answer)], row: '1', color: 'gray');
    expect(o.res, Res.body);
  });

  test('login ends map to the core: 2 undecryptable, 3 identity, 4 EForbidden / other, 5 noResponse', () async {
    expect((await probe([step(OwnerKind.ended, loginEnd: 2)])).res, Res.undecryptable);
    expect((await probe([step(OwnerKind.ended, loginEnd: 3)])).res, Res.certRejected);
    expect((await probe([step(OwnerKind.ended, loginEnd: 4, code: eForbidden)])).res, Res.refusedForbidden);
    expect((await probe([step(OwnerKind.ended, loginEnd: 4, code: 11)])).res, Res.refusedOther);
    expect((await probe([step(OwnerKind.ended, loginEnd: 5)])).res, Res.noResponse,
        reason: 'a Broken login never plants a 「是 Y」');
  });

  test('a session that ends after the login (not a login end) -> broken', () async {
    final o = await probe([step(OwnerKind.loggedIn, loginEnd: 1), step(OwnerKind.ended)]);
    expect(o.res, Res.broken);
  });

  test('a sign step signs with the owner key and goes on', () async {
    final o = await probe([step(OwnerKind.sign), step(OwnerKind.loggedIn, loginEnd: 1), step(OwnerKind.answer)]);
    expect(o.res, Res.body);
    expect(rust.session.signs, [70]);
  });

  test('no frame from the node within the msg2 budget -> noResponse at the budget, not at the 20 s answer limit', () async {
    final sw = Stopwatch()..start();
    final o = await probe([], frames: 0, msg2: const Duration(milliseconds: 50));
    expect(o.res, Res.noResponse);
    expect(sw.elapsedMilliseconds, lessThan(1000), reason: 'review pr1 B-M6b: the msg2 budget itself ends it');
  });

  test('a step that would write a record in a read -> the node is given up, nothing written', () async {
    final o = await probe([step(OwnerKind.loggedIn, loginEnd: 1), step(OwnerKind.persistNet)]);
    expect(o.res, Res.broken);
  });

  // ---- review pr1 (A-M4 / B-M3, B-m2, A-m10, B-M5, B-m6, A-m2 M9) ----------------------------------------------

  test('RB-4 / RA-4: a device that never answers the MTU exchange ends at the msg2 budget', () async {
    final sw = Stopwatch()..start();
    final o = await probe([], frames: 0, msg2: const Duration(milliseconds: 50), backend: StallRadio());
    expect(o.res, Res.noResponse);
    expect(sw.elapsedMilliseconds, lessThan(1000), reason: 'msg2 budget 50 ms');
  });

  test('a probe stuck in Keystore stops when the attempt is cancelled (M9)', () async {
    final cancel = Completer<void>();
    final p = SessionProber(
        openRecord: (id) => Completer<Uint8List?>().future, // never returns
        ownerPub: () async => Uint8List(65),
        signOwner: (i) async => Uint8List(70));
    final f = probe([], frames: 0, prober: p, cancelled: cancel.future);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    cancel.complete();
    final o = await f.timeout(const Duration(seconds: 1), onTimeout: () => const Outcome(Res.body, 'HUNG'));
    expect((o.res, o.view), (Res.noResponse, ''));
  });

  test('B-m2: the session is disposed when the attempt ends', () async {
    final o = await probe([step(OwnerKind.loggedIn, loginEnd: 1), step(OwnerKind.answer)]);
    expect(o.res, Res.body);
    expect(rust.session.disposed, isTrue);
  });

  test('S20: a read-only record buffer (platform channel) and a dispose that throws never change the outcome', () async {
    final p = SessionProber(
        openRecord: (id) async => Uint8List.fromList(List.filled(8, 7)).asUnmodifiableView(),
        ownerPub: () async => Uint8List(65),
        signOwner: (i) async => Uint8List(70));
    rust.throwOnDispose = true;
    try {
      final o = await probe([step(OwnerKind.loggedIn, loginEnd: 1), step(OwnerKind.answer)], prober: p);
      expect(o.res, Res.body);
      expect((await probe([step(OwnerKind.ended, loginEnd: 2)], prober: p)).res, Res.undecryptable);
    } finally {
      rust.throwOnDispose = false;
    }
  });

  test('A-m10: an exception after the login is broken, before it no answer', () async {
    rust.throwOnStatus = true;
    try {
      expect((await probe([step(OwnerKind.loggedIn, loginEnd: 1)])).res, Res.broken);
    } finally {
      rust.throwOnStatus = false;
    }
    final p = SessionProber(
        openRecord: (id) async => throw StateError('store'), ownerPub: () async => Uint8List(65), signOwner: (i) async => Uint8List(70));
    expect((await probe([], frames: 0, prober: p)).res, Res.noResponse);
  });

  test('B-M5: a key refused while signing is reported (2.4), and the attempt ends', () async {
    final errors = <Object>[];
    final p = SessionProber(
        openRecord: (id) async => Uint8List(8),
        ownerPub: () async => Uint8List(65),
        signOwner: (i) async => throw StateError('keyLevel'),
        keyError: errors.add);
    final o = await probe([step(OwnerKind.sign), step(OwnerKind.ended, loginEnd: 5)], prober: p);
    expect(o.res, Res.noResponse);
    expect(errors, hasLength(1));
  });

  test('B-m6: before the login an unexpected step or an ended without a login end is no answer', () async {
    expect((await probe([step(OwnerKind.persistNet)])).res, Res.noResponse);
    expect((await probe([step(OwnerKind.ended)])).res, Res.noResponse);
  });
  test('r2 D-2: fragments that never make a msg2 end at the msg2 budget, not at the 20 s answer limit', () async {
    final sw = Stopwatch()..start();
    final o = await probe([], frames: 99, msg2: const Duration(milliseconds: 50)); // every frame: no step yet
    expect(o.res, Res.noResponse);
    expect(sw.elapsedMilliseconds, lessThan(1000));
  });

  test('r2 D21: after msg2, silence ends the attempt at answerMax', () async {
    final p = SessionProber(
        openRecord: (id) async => Uint8List(8),
        ownerPub: () async => Uint8List(65),
        signOwner: (i) async => Uint8List(70),
        answerMax: const Duration(milliseconds: 100));
    final sw = Stopwatch()..start();
    final o = await probe([step(OwnerKind.sign)], frames: 1, prober: p); // msg2 -> sign, then nothing
    expect(o.res, Res.noResponse);
    expect(sw.elapsedMilliseconds, inInclusiveRange(90, 1500));
  });

  test('r2 X13: a key error while opening the record is reported', () async {
    final errors = <Object>[];
    final p = SessionProber(
        openRecord: (id) async => throw StateError('keyLevel'),
        ownerPub: () async => Uint8List(65),
        signOwner: (i) async => Uint8List(70),
        keyError: errors.add);
    expect((await probe([], frames: 0, prober: p)).res, Res.noResponse);
    expect(errors, hasLength(1));
  });
  test('r3 F-m1: once msg2 arrived, the 8 s deadline no longer ends the attempt', () async {
    rust.session = FakeSession([step(OwnerKind.sign), step(OwnerKind.loggedIn, loginEnd: 1), step(OwnerKind.answer)]);
    final reg = LeaseRegistry(after: (d, f) => () {});
    final radio = Radio();
    final gate = BleGate(radio, reg, now: () => 0, after: (d, f) => () {});
    final link = gate.connect(reg.token, 'a1');
    await Future<void>.delayed(Duration.zero);
    final p = SessionProber(
        openRecord: (id) async => Uint8List(8), ownerPub: () async => Uint8List(65), signOwner: (i) async => Uint8List(70));
    final due = Completer<void>();
    final f = p.probe(link, 'Y1', due: due.future, cancelled: Completer<void>().future);
    await Future<void>.delayed(const Duration(milliseconds: 5));
    radio.tx.add([1]); // msg2
    await Future<void>.delayed(const Duration(milliseconds: 5));
    due.complete(); // the 8 s are over, after msg2
    await Future<void>.delayed(const Duration(milliseconds: 5));
    radio.tx.add([1]); // logged in
    radio.tx.add([1]); // the answer
    expect((await f).res, Res.body);
  });
}

class StallRadio extends Radio {
  @override
  Future<int> requestMtu(String address, int mtu) => Completer<int>().future; // never answers
}
