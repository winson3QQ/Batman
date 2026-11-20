// #329 PR 5 plan v16 §2.4 / §6 step 5 (T-P5-H): the remove-member §3.5 hint worked out on the read's own session.
// R6 when it is computed, R7 before done() and never after the session is disposed, bounded, cancel-safe; R8 what
// is handed to NodeLink.
import 'dart:async';
import 'dart:typed_data';

import 'package:batman_app/src/nodelink/ble_gate.dart';
import 'package:batman_app/src/nodelink/core.dart';
import 'package:batman_app/src/nodelink/lease.dart';
import 'package:batman_app/src/nodelink/prober.dart';
import 'package:batman_app/src/rust/api/owner.dart';
import 'package:batman_app/src/rust/api/rekey.dart' show UpdateHint;
import 'package:batman_app/src/rust/frb_generated.dart';
import 'package:flutter_test/flutter_test.dart';

import 'node_link_test.dart' show setup;
import 'prober_test.dart' show FakeRust, FakeSession, Radio, step;

/// A session whose status page names [netId]; updateHint after dispose throws (the FRB object is gone, R7).
class HintSession extends FakeSession {
  HintSession(super.script, {this.netId = 'aa', this.nodeState = 2});
  final String netId;
  final int nodeState;
  final hintCalls = <String>[];
  int lateCalls = 0; // updateHint called after dispose (must stay 0, R7)

  @override
  StatusView statusView({required bool hasNet, required bool hasMnet}) => StatusView(
      color: 'green',
      row: '3',
      sentence: '',
      lagNote: '',
      warning: '', note: '',
      nodeState: nodeState,
      netId: netId,
      version: '',
      tech: const [],
      fresh: true,
      rateNote: '',
      unfinished: '',
      unfinishedUnderVerdict: false,
      canLeave: false);

  @override
  UpdateHint updateHint({required List<int> recordPlain, required bool member}) {
    if (disposed) {
      lateCalls++;
      throw StateError('updateHint on a disposed session');
    }
    hintCalls.add('member=$member');
    return const UpdateHint(line: '這台還在舊密碼 — 把新密碼送給節點', button: true);
  }
}

class Hints {
  bool wanted = true, known = true;
  final opened = <String>[];
  final got = <(String, String)>[];
  Future<Uint8List?> Function(String rel)? open;

  HintSource get source => HintSource(
        wanted: (id) => wanted,
        netKnown: (n) => known,
        openNet: (rel) {
          opened.add(rel);
          final o = open;
          return o != null ? o(rel) : Future.value(Uint8List(4));
        },
        onHint: (id, h) => got.add((id, h.line)),
      );
}

void main() {
  final rust = FakeRust();
  setUpAll(() => RustLib.initMock(api: rust));

  final read = [step(OwnerKind.loggedIn, loginEnd: 1), step(OwnerKind.answer)];

  Future<(Outcome, HintSession, List<String>)> probe(Hints h,
      {String netId = 'aa', int nodeState = 2, Future<void>? cancelled, Duration answerMax = const Duration(seconds: 20)}) async {
    final s = HintSession([...read], netId: netId, nodeState: nodeState);
    rust.session = s;
    final reg = LeaseRegistry(after: (d, f) => () {});
    final radio = Radio();
    final gate = BleGate(radio, reg, now: () => 0, after: (d, f) => () {});
    final link = gate.connect(reg.token, 'a1');
    await Future<void>.delayed(Duration.zero);
    final logs = <String>[];
    final p = SessionProber(
      openRecord: (id) async => Uint8List(8),
      ownerPub: () async => Uint8List(65),
      signOwner: (input) async => Uint8List(70),
      log: logs.add,
      hint: h.source,
      answerMax: answerMax,
    );
    final f = p.probe(link, 'Y1', due: Future<void>.delayed(const Duration(seconds: 8)), cancelled: cancelled ?? Completer<void>().future);
    for (var i = 0; i < 3; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 1));
      radio.tx.add([1]);
    }
    return (await f, s, logs);
  }

  test('R7: the hint is worked out on the live session, before done(); the read is unchanged', () async {
    final h = Hints();
    final (o, s, _) = await probe(h);
    expect(o.res, Res.body);
    expect(s.hintCalls, ['member=false'], reason: 'net first; called before the session was disposed');
    expect(h.got, [('Y1', '這台還在舊密碼 — 把新密碼送給節點')]);
    expect(s.disposed, isTrue);
  });

  test('R6: not wanted (field build / page not open) -> no record is opened', () async {
    final h = Hints()..wanted = false;
    final (o, _, _) = await probe(h);
    expect(o.res, Res.body);
    expect(h.opened, isEmpty);
    expect(h.got, isEmpty);
  });

  test('R6: a network the phone has no record of -> no record is opened', () async {
    final h = Hints()..known = false;
    await probe(h);
    expect(h.opened, isEmpty);
  });

  test('net does not open, mnet does -> the member hint (the old loop: first that opens)', () async {
    final h = Hints()..open = (rel) async => rel.startsWith('net/') ? null : Uint8List(4);
    final (_, s, _) = await probe(h);
    expect(h.opened, ['net/aa', 'mnet/aa']);
    expect(s.hintCalls, ['member=true']);
  });

  test('R7: openNet throws -> the read is still a body, no hint, the log has the type only', () async {
    final h = Hints()..open = (rel) async => throw StateError('secret-ish detail');
    final (o, _, logs) = await probe(h);
    expect(o.res, Res.body);
    expect(h.got, isEmpty);
    expect(logs.join(' '), isNot(contains('secret-ish detail')));
  });

  test('R7: openNet slower than 2 s -> the read comes back after about 2 s, without a hint', () async {
    final h = Hints()..open = (rel) => Future.delayed(const Duration(seconds: 3), () => Uint8List(4));
    final sw = Stopwatch()..start();
    final (o, s, _) = await probe(h);
    expect(o.res, Res.body);
    expect(sw.elapsedMilliseconds, lessThan(2900));
    await Future<void>.delayed(const Duration(milliseconds: 1500)); // the record arrives after the read ended
    expect(s.hintCalls, isEmpty, reason: 'the session is disposed: updateHint is never called');
    expect(s.lateCalls, 0);
  });

  test('R7: cancelled while the hint waits -> the status page already read, not noResponse; no call into the session', () async {
    final gate = Completer<Uint8List?>();
    final cancel = Completer<void>();
    final h = Hints()
      ..open = (rel) {
        cancel.complete(); // the round is cancelled while this record is being opened
        return gate.future;
      };
    final (o, s, _) = await probe(h, cancelled: cancel.future);
    expect(o.res, Res.body);
    gate.complete(Uint8List(4));
    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(s.hintCalls, isEmpty);
    expect(s.lateCalls, 0, reason: 'cleaning is set: no call into the disposed session');
  });

  test('R8: the node says it is in no network -> the hint is cleared; info not read (netId empty) -> kept', () async {
    final left = Hints();
    await probe(left, netId: '', nodeState: 1);
    expect(left.got, [('Y1', '')]);
    final unread = Hints();
    await probe(unread, netId: '', nodeState: 2);
    expect(unread.got, isEmpty, reason: 'the last hint stays');
  });

  test('R7 (K-m2): the 20 s answer timer is stopped at the answer; a slow hint does not make the read broken', () async {
    final h = Hints()..open = (rel) => Future.delayed(const Duration(milliseconds: 800), () => Uint8List(4));
    final (o, _, _) = await probe(h, answerMax: const Duration(milliseconds: 300));
    expect(o.res, Res.body);
    expect(h.got, hasLength(1));
  });

  group('R8: NodeLink.hints', () {
    const old = UpdateHint(line: '這台還在舊密碼 — 把新密碼送給節點', button: true);

    test('kept only while that node\'s page is open; a late one for another page is dropped', () async {
      final (nl, _, _, _, _, _) = setup([const Rec('Y1', 1), const Rec('Y2', 1)], {});
      await nl.start(Page.node, node: 'Y1');
      var fired = 0;
      final sub = nl.changed.listen((_) => fired++);
      nl.setHint('Y2', old);
      expect(nl.hints, isEmpty, reason: 'Y2\'s page is not open');
      await Future<void>.delayed(Duration.zero);
      var before = fired;
      nl.setHint('Y1', old);
      expect(nl.hints['Y1']?.line, old.line);
      await Future<void>.delayed(Duration.zero);
      expect(fired, before + 1, reason: 'a new hint fires changed');
      before = fired;
      nl.setHint('Y1', old);
      await Future<void>.delayed(Duration.zero);
      expect(fired, before, reason: 'the same hint does not fire again');
      await sub.cancel();
    });

    test('an empty line removes it; leaving the page clears it', () async {
      final (nl, _, _, _, _, _) = setup([const Rec('Y1', 1)], {});
      await nl.start(Page.node, node: 'Y1');
      nl.setHint('Y1', old);
      nl.setHint('Y1', const UpdateHint(line: '', button: false));
      expect(nl.hints, isEmpty);
      nl.setHint('Y1', old);
      nl.setPage(Page.home);
      expect(nl.hints, isEmpty, reason: 'no stale card when the page opens again');
    });
  });
}
