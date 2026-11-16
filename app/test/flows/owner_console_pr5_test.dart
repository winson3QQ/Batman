// #329 PR 5 plan v16 §2.3 / §6 step 4: OwnerConsole's joinreq / memberJoin / info, on the PR 3 rig.
import 'dart:async';
import 'dart:typed_data';

import 'package:batman_app/member_ui.dart' show joinreqLostLine, notSentLine;
import 'package:batman_app/src/flows/owner_console.dart';
import 'package:batman_app/src/rust/api/owner.dart';
import 'package:batman_app/src/rust/frb_generated.dart';
import 'package:flutter_test/flutter_test.dart';

import '../nodes_update_send_test.dart' show FakeRust, step;
import 'owner_console_test.dart' show Rig, Session;

const fJr = 90, fJr2 = 92;

OwnerStep answerOf(String hex, String sas, bool renewed) => OwnerStep(
    kind: OwnerKind.answer,
    frames: const [],
    signInput: Uint8List(1),
    detail: '[JOINREQ] 申請（名稱「小陳」）',
    record: Uint8List(0),
    rel: '',
    generation: BigInt.zero,
    aad: Uint8List(0),
    expectedGen: BigInt.zero,
    pollLink: false,
    hex: hex,
    sas: sas,
    renewed: renewed,
    sent: false,
    left: false,
    waitMs: BigInt.zero,
    sendUpdate: false,
    info: Uint8List(0),
    sw: false,
    note: '',
    loginEnd: 0,
    loginCode: BigInt.zero);

/// A join request: a write, the node's answer -> PersistPend -> one more write -> the answer with the code.
class P5Session extends Session {
  P5Session(super.rust);
  final asked = <String>[];
  bool inJr = false;

  @override
  OwnerStep requestJoinreq(
      {required String inviteHex, required String name, required BigInt pendGen, Uint8List? pendPlain, required List<int> ownerEncPub}) {
    asked.add('joinreq $name gen=$pendGen');
    inJr = true;
    return step(OwnerKind.write, frame: fJr);
  }

  bool memberSent = false; // the real member join marks its write `sent` once it carries the secrets

  @override
  OwnerStep requestMemberJoin({required List<int> mnetPlain, required BigInt mnetGen}) {
    rust.sends.add('memberJoin');
    return step(OwnerKind.write, frame: 20, sent: memberSent);
  }

  @override
  OwnerStep? netPersisted() {
    if (!inJr) return super.netPersisted();
    return step(OwnerKind.write, frame: fJr2);
  }

  @override
  OwnerStep? onFrame({required List<int> frame}) => switch (frame[0]) {
        const (fJr + 1) => step(OwnerKind.persistPend, rel: 'mpend/aa'),
        const (fJr2 + 1) => answerOf('a20102', '483921', true),
        _ => super.onFrame(frame: frame),
      };
}

void main() {
  final rust = FakeRust();
  setUpAll(() => RustLib.initMock(api: rust));
  setUp(() => rust.sends.clear());

  Rig rig() => Rig(rust, make: P5Session.new);
  P5Session ses(Rig r) => r.session as P5Session;

  group('joinreq', () {
    test('the answer\'s value is the code, the confirmation code and renewed; the request record is written', () async {
      final r = rig();
      final a = await r.run(() => r.c.joinreq(inviteHex: 'a201', name: '小陳', pendRel: 'mpend/aa'));
      expect(a.kind, ReplyKind.answer);
      final v = a.value as JoinreqOut;
      expect((v.hex, v.sas, v.renewed), ('a20102', '483921', true));
      expect(r.cas, ['mpend/aa']);
      expect(ses(r).asked, ['joinreq 小陳 gen=1'], reason: 'the mpend record is read under the lease (R11)');
      await r.c.close();
    });

    test('the link lost after the request record landed -> joinreqLostLine(saved: true)', () async {
      final r = rig();
      final hold = r.slowCas = Completer<void>();
      final f = r.run(() => r.c.joinreq(inviteHex: 'a201', name: '小陳', pendRel: 'mpend/aa'));
      // the first exchange goes through; the record write waits; then the node goes silent before the second write
      await r.clock.run(500);
      r.radio.silent = true;
      hold.complete();
      while (r.cas.isEmpty) {
        await r.clock.run(100);
      }
      await r.clock.run(1000);
      r.radio.drop();
      final a = await f;
      expect(a.text, joinreqLostLine(saved: true));
      expect(a.sessionAlive, isFalse);
      await r.c.close();
    });

    test('the link lost before anything was saved -> joinreqLostLine(saved: false)', () async {
      final r = rig();
      r.radio.silent = true;
      final f = r.run(() => r.c.joinreq(inviteHex: 'a201', name: '小陳', pendRel: 'mpend/aa'));
      await r.clock.run(1000);
      r.radio.drop();
      final a = await f;
      expect(a.text, joinreqLostLine(saved: false));
      expect(r.cas, isEmpty);
      await r.c.close();
    });

    test('a second request on the same console starts with saved = false again', () async {
      final r = rig();
      await r.run(() => r.c.joinreq(inviteHex: 'a201', name: '小陳', pendRel: 'mpend/aa'));
      r.radio.silent = true;
      final f = r.run(() => r.c.joinreq(inviteHex: 'a201', name: '小陳', pendRel: 'mpend/aa'));
      await r.clock.run(1000);
      r.radio.drop();
      expect((await f).text, joinreqLostLine(saved: false));
      await r.c.close();
    });
  });

  group('memberJoin / info', () {
    test('memberJoin sends the member join and answers', () async {
      final r = rig();
      final a = await r.run(() => r.c.memberJoin('mnet/aa'));
      expect(a.kind, ReplyKind.answer);
      expect(rust.sends, ['memberJoin']);
      await r.c.close();
    });

    test('memberJoin: the link lost before anything was sent -> not sent', () async {
      final r = rig();
      r.radio.silent = true;
      final f = r.run(() => r.c.memberJoin('mnet/aa'));
      await r.clock.run(1000);
      r.radio.drop();
      expect((await f).text, notSentLine);
      await r.c.close();
    });

    test('memberJoin: the link lost after a sent write -> the join\'s unclear line', () async {
      final r = rig();
      ses(r).memberSent = true;
      r.radio.silent = true;
      final f = r.run(() => r.c.memberJoin('mnet/aa'));
      await r.clock.run(1000);
      r.radio.drop();
      final a = await f;
      expect(a.text, joinUnclearLine, reason: 'the old _joinUnclear (nodes.dart:49)');
      await r.c.close();
    });

    test('info: the value is the node\'s info bytes', () async {
      final r = rig();
      final a = await r.run(r.c.info);
      expect(a.kind, ReplyKind.answer);
      expect(a.value, Uint8List.fromList([7]));
      await r.c.close();
    });
  });
}
