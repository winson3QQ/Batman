// #329 PR 3 §2.2: the login of a flow hands its session over (HandoffProber), the frames wait in order (FrameInbox),
// and the `ended` mapping is one function for reads and logins (loginOutcome). Fake Rust session, fake radio.
import 'dart:async';
import 'dart:typed_data';

import 'package:batman_app/src/nodelink/ble_gate.dart';
import 'package:batman_app/src/nodelink/core.dart';
import 'package:batman_app/src/nodelink/handoff.dart';
import 'package:batman_app/src/nodelink/lease.dart';
import 'package:batman_app/src/nodelink/prober.dart';
import 'package:batman_app/src/rust/api/owner.dart';
import 'package:batman_app/src/rust/frb_generated.dart';
import 'package:flutter_test/flutter_test.dart';

import 'prober_test.dart' show FakeRust, FakeSession, Radio, step;

/// A radio whose link reports 「gone」 when the connect is cancelled (so GateLink.close returns at once).
class LinkRadio extends Radio {
  final _gone = StreamController<(String, bool, int?)>.broadcast(sync: true);
  @override
  Stream<(String, bool, int?)> get linkStates => _gone.stream;
  @override
  Stream<bool> connect(String address, Duration timeout) {
    final c = StreamController<bool>(onCancel: () => _gone.add((address, false, null)));
    c.add(true);
    return c.stream;
  }
}

void main() {
  final rust = FakeRust();
  setUpAll(() => RustLib.initMock(api: rust));

  /// Runs [p] on a fresh link; [frames] node frames 1 ms apart, the i-th carrying the byte i+1.
  Future<(Outcome, Radio, BleGate, GateLink)> run(SessionProber p, List<OwnerStep> script, {int frames = 6}) async {
    rust.session = FakeSession([...script]);
    final reg = LeaseRegistry(after: (d, f) => () {});
    final radio = LinkRadio();
    final gate = BleGate(radio, reg, now: () => 0, after: (d, f) => () {});
    final link = gate.connect(reg.token, 'a1');
    await Future<void>.delayed(Duration.zero);
    final f = p.probe(link, 'Y1', due: Future<void>.delayed(const Duration(seconds: 8)), cancelled: Completer<void>().future);
    for (var i = 0; i < frames; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 1));
      radio.tx.add([i + 1]);
    }
    await Future<void>.delayed(const Duration(milliseconds: 5));
    return (await f, radio, gate, link);
  }

  HandoffProber handoff() => HandoffProber(
        openRecord: (id) async => Uint8List(8),
        ownerPub: () async => Uint8List(65),
        signOwner: (input) async => Uint8List(70),
      );

  test('loggedIn hands the session over: a body with a LoginHandoff, nothing disposed or closed', () async {
    final (o, _, gate, link) = await run(handoff(), [step(OwnerKind.loggedIn, loginEnd: 1)]);
    expect(o.res, Res.body, reason: 'LoginFor.result takes a body as ok');
    final h = o.extra;
    expect(h, isA<LoginHandoff>());
    h as LoginHandoff;
    expect((h.id, identical(h.link, link)), ('Y1', true));
    expect(rust.session.disposed, isFalse, reason: 'the session is the flow\x27s now');
    expect((link.open, gate.links), (true, 1), reason: 'the link stays open');
    await h.close();
    expect((rust.session.disposed, link.open, gate.links), (true, false, 0));
    await h.close(); // idempotent
  });

  test('no frame is lost between the login and the flow: the later ones wait, in order', () async {
    // frame 1 = msg2, frame 2 = loggedIn; frames 3..6 arrive after the hand-off
    final (o, _, _, _) = await run(handoff(), [step(OwnerKind.write), step(OwnerKind.loggedIn, loginEnd: 1)]);
    final h = o.extra as LoginHandoff;
    expect(h.inbox.held, 4);
    final got = <int>[];
    h.inbox.handle((f) => got.add(f.first), (_) {});
    expect(got, [3, 4, 5, 6]);
    expect(h.inbox.held, 0);
    await h.close();
  });

  test('a login that does not end logged in disposes and leaves nothing to hand over (same as a read)', () async {
    final (o, _, _, link) = await run(handoff(), [step(OwnerKind.ended, loginEnd: 2)]);
    expect((o.res, o.extra), (Res.undecryptable, null));
    expect(rust.session.disposed, isTrue);
    expect(link.open, isTrue, reason: 'the caller (NodeLink) closes a failed attempt\x27s link');
  });

  test('the read prober still reads the status page after loggedIn (no hand-off)', () async {
    final p = SessionProber(
        openRecord: (id) async => Uint8List(8), ownerPub: () async => Uint8List(65), signOwner: (i) async => Uint8List(70));
    final (o, _, _, _) = await run(p, [step(OwnerKind.loggedIn, loginEnd: 1), step(OwnerKind.answer)]);
    expect((o.res, o.extra is LoginHandoff), (Res.body, false));
    expect(rust.session.disposed, isTrue);
  });

  test('loginOutcome: the ended mapping of a read, unchanged', () {
    expect(loginOutcome(2, 0, loggedIn: false).res, Res.undecryptable);
    expect(loginOutcome(3, 0, loggedIn: false).res, Res.certRejected);
    expect(loginOutcome(4, eForbidden, loggedIn: false).res, Res.refusedForbidden);
    expect(loginOutcome(4, 1, loggedIn: false).res, Res.refusedOther);
    expect(loginOutcome(5, 0, loggedIn: false).res, Res.noResponse);
    expect(loginOutcome(5, 0, loggedIn: true).res, Res.broken);
    expect(loginOutcome(0, 0, loggedIn: false).res, Res.noResponse);
  });

  group('FrameInbox', () {
    test('passes frames straight through while a handler is set', () {
      final i = FrameInbox();
      final got = <int>[];
      i.handle((f) => got.add(f.first), (_) {});
      i.add([1]);
      i.add([2]);
      expect(got, [1, 2]);
      expect(i.held, 0);
    });

    test('holds frames with no handler and hands them over in order, then an error once', () {
      final i = FrameInbox();
      i.add([1]);
      i.addError('gone');
      i.add([2]); // a frame after the error keeps its place before it
      final got = <Object>[];
      i.handle((f) => got.add(f.first), (e) => got.add(e));
      expect(got, [1, 2, 'gone']);
      i.add([3]);
      expect(got, [1, 2, 'gone', 3]);
    });

    test('a handler that replaces itself while draining stops the old one at once', () {
      final i = FrameInbox();
      i.add([1]);
      i.add([2]);
      final a = <int>[], b = <int>[];
      void second(List<int> f) => b.add(f.first);
      i.handle((f) {
        a.add(f.first);
        i.handle(second, (_) {});
      }, (_) {});
      expect(a, [1]);
      expect(b, [2]);
    });
  });
}
