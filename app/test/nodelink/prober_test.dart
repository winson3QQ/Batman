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

  @override
  OwnerStep requestStatusPage() => step(OwnerKind.write);
  @override
  StatusView statusView({required bool hasNet, required bool hasMnet}) => view(statusRow, color);
  @override
  dynamic noSuchMethod(Invocation i) => throw UnimplementedError('${i.memberName}');
}

class FakeRust implements RustLibApi {
  FakeSession session = FakeSession([]);
  @override
  Future<int> crateApiClaimFrameLimit({required List<int> ctrl, required int mtu}) async => 244;
  @override
  (OwnerSession, OwnerStep) crateApiOwnerOwnerSessionStart(
          {required List<int> recordPlain, required List<int> ownerPub, required int frameLimit}) =>
      (session, step(OwnerKind.write));
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
      {String row = '3', String color = 'green', int frames = 99, Duration msg2 = const Duration(seconds: 8)}) async {
    rust.session = FakeSession([...script], statusRow: row, color: color);
    final reg = LeaseRegistry(after: (d, f) => () {});
    final radio = Radio();
    final gate = BleGate(radio, reg, now: () => 0, after: (d, f) => () {});
    final link = gate.connect(reg.token, 'a1');
    await Future<void>.delayed(Duration.zero);
    final p = SessionProber(
      openRecord: (id) async => Uint8List(8),
      ownerPub: () async => Uint8List(65),
      signOwner: (input) async => Uint8List(70),
    );
    final f = p.probe(link, 'Y1', msg2: msg2, cancelled: Completer<void>().future);
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

  test('no frame from the node within the msg2 budget -> noResponse', () async {
    final o = await probe([], frames: 0, msg2: const Duration(milliseconds: 50));
    expect(o.res, Res.noResponse);
  });

  test('a step that would write a record in a read -> the node is given up, nothing written', () async {
    final o = await probe([step(OwnerKind.loggedIn, loginEnd: 1), step(OwnerKind.persistNet)]);
    expect(o.res, Res.broken);
  });
}
