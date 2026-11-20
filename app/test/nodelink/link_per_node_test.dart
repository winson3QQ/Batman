// #329 one kept link per node (docs/design/329-link-per-node.md §7): L1–L19, on the combined rig of
// kept_link_test.dart (one NodeLink, one gate, one lease registry, one radio with a link per address).
import 'dart:async';

import 'package:batman_app/src/flows/op_session.dart';
import 'package:batman_app/src/nodelink/ble_gate.dart';
import 'package:batman_app/src/nodelink/core.dart';
import 'package:batman_app/src/nodelink/lease.dart';
import 'package:batman_app/src/nodelink/node_link.dart';
import 'package:batman_app/src/rust/frb_generated.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fake_node.dart' show fInfo, fStatus;
import 'kept_link_test.dart' show KRig, KRust, KS;

const p = KeptState.parked;

extension on KRig {
  /// The session of [id]'s kept link.
  KS ks(String id) => nl.kept(id)!.session as KS;
  String at(String id) => nl.kept(id)!.link.address;
  int nReads(String id) => ks(id).statusReqs;
  int readAtOf(String id) => nl.core.states[id]!.readAt ?? -1;

  /// Steps the clock (100 ms) until [cond] holds; the time it held first.
  Future<int> step(bool Function() cond, {int max = 70000, bool adv = true, String what = ''}) async {
    await wait(cond, max: max, adv: adv, what: what);
    return clock.t;
  }
}

void main() {
  late KRust rust;
  setUp(() {
    rust = KRust();
    RustLib.initMock(api: rust);
  });
  tearDown(() {
    RustLib.dispose();
    expect(rust.late, isEmpty, reason: 'a call into a disposed session');
  });

  /// The home page with [n] records Y1..Yn, node Yi on address ai; the first round is over.
  Future<KRig> home(int n, {int? advertising, int subCancelMs = 0}) async {
    final rig = KRig(rust, recs: [for (var i = 1; i <= n; i++) Rec('Y$i', 1)]);
    rig.radio.subCancelMs = subCancelMs;
    rig.advs = [for (var i = 1; i <= (advertising ?? n); i++) 'a$i'];
    await rig.nl.start(Page.home);
    await rig.wait(() => !rig.nl.core.roundActive, what: 'round 1 ended');
    return rig;
  }

  /// [home] with 2 records, both links kept: Y1 on a1, Y2 on a2.
  Future<KRig> home2({int subCancelMs = 0}) async {
    final rig = await home(2, subCancelMs: subCancelMs);
    expect((rig.nl.keptState('Y1'), rig.nl.keptState('Y2'), rig.gate.links, rig.radio.connects), (p, p, 2, 2),
        reason: rig.tr);
    expect((rig.at('Y1'), rig.at('Y2')), ('a1', 'a2'));
    return rig;
  }

  test('L1: home, 2 records: round 1 = 2 connects; round 2 = no scan, no connect, 2 reads on the kept links', () async {
    final rig = await home2();
    final t0 = rig.clock.t;
    final scans = rig.radio.scans;
    expect((rig.nReads('Y1'), rig.nReads('Y2'), rig.radio.maxOpen), (1, 1, 2));
    await rig.run(61000);
    expect((rig.radio.connects, rig.radio.scans, rig.gate.links), (2, scans, 2), reason: rig.tr);
    expect((rig.nReads('Y1'), rig.nReads('Y2')), (2, 2));
    expect(rig.readAtOf('Y1'), greaterThan(t0));
    expect(rig.readAtOf('Y2'), greaterThan(t0));
    expect((rig.nl.core.states['Y1']!.kind, rig.nl.core.states['Y2']!.kind), (Kind.read, Kind.read));
    expect(rig.gate.refused, isEmpty);
  });

  test('L2: a link kept by a home read, then the node page and an operation: no new connect, the link is lent', () async {
    final rig = await home2();
    final s = rig.ks('Y1');
    rig.nl.setPage(Page.node, node: 'Y1');
    await rig.run(1500, adv: false);
    final (l, h) = await rig.lend();
    expect((rig.nl.keptState('Y1'), rig.radio.connects), (KeptState.lent, 2), reason: rig.tr);
    expect(identical(h.session, s), isTrue);
    await h.close(reusable: true);
    await l.release();
    expect((rig.nl.keptState('Y1'), rig.nl.keptState('Y2'), s.disposed, rig.radio.connects), (p, p, false, 2));
  });

  test('L3: on node page Y1 the link of Y2 is closed by the gate 120 s after its last read; Y1 stays kept', () async {
    final rig = await home2();
    final t0 = rig.clock.t; // Y2 was parked within the last second
    final s2 = rig.ks('Y2');
    rig.nl.setPage(Page.node, node: 'Y1');
    await rig.until(t0 + 118000, adv: false);
    expect((rig.gate.links, rig.nl.keptState('Y2'), s2.disposed), (2, p, false), reason: rig.tr);
    await rig.until(t0 + 130000, adv: false);
    expect((rig.gate.links, rig.nl.keptState('Y1'), rig.nl.keptState('Y2'), s2.disposed), (1, p, null, true),
        reason: rig.tr);
    expect(rig.radio.connects, 2);
  });

  test('L4: Page.other: nothing reads; both links are closed by the gate after 120 s', () async {
    final rig = await home2();
    final t0 = rig.clock.t;
    rig.nl.setPage(Page.other);
    await rig.until(t0 + 118000, adv: false);
    expect((rig.gate.links, rig.nl.keptCount), (2, 2), reason: rig.tr);
    await rig.until(t0 + 121000, adv: false);
    expect((rig.gate.links, rig.nl.keptCount, rig.radio.open), (0, 0, 0), reason: rig.tr);
  });

  group('L5: the background closes every kept link at once; the foreground reads by new connects', () {
    test('2 parked', () async {
      final rig = await home2();
      final (s1, s2) = (rig.ks('Y1'), rig.ks('Y2'));
      rig.nl.background();
      await rig.run(100, adv: false);
      expect((rig.gate.links, rig.nl.keptCount, s1.disposed, s2.disposed), (0, 0, true, true), reason: rig.tr);
      rig.nl.foreground();
      await rig.wait(() => rig.nl.keptCount == 2, what: 'both read again');
      expect((rig.radio.connects, rig.radio.maxOpen), (4, 2));
    });
    test('1 reading, 1 parked', () async {
      final rig = await home2();
      final (s1, s2) = (rig.ks('Y1'), rig.ks('Y2'));
      rig.radio.hold[fInfo] = [-1];
      await rig.wait(() => rig.nl.keptState('Y1') == KeptState.reading || rig.nl.keptState('Y2') == KeptState.reading,
          what: 'the 60 s read');
      rig.nl.background();
      await rig.run(100, adv: false);
      expect((rig.gate.links, rig.nl.keptCount, s1.disposed, s2.disposed), (0, 0, true, true), reason: rig.tr);
      rig.nl.foreground();
      await rig.wait(() => rig.nl.keptCount == 2, what: 'both read again');
      expect(rig.radio.connects, 4);
    });
  });

  test('L6: Y1 lent for 30 s under a session lease: Y2 stays parked; the next home round reads Y2 on its link', () async {
    final rig = await home2();
    final s2 = rig.ks('Y2');
    rig.nl.setPage(Page.node, node: 'Y1');
    await rig.run(1500, adv: false);
    final (l, h) = await rig.lend();
    await rig.run(30000, adv: false);
    expect((rig.nl.keptState('Y1'), rig.nl.keptState('Y2'), rig.gate.links), (KeptState.lent, p, 2), reason: rig.tr);
    await h.close(reusable: true);
    await l.release();
    final n = s2.statusReqs;
    rig.nl.setPage(Page.home);
    await rig.run(10000, adv: false);
    expect((s2.statusReqs, s2.disposed, rig.radio.connects, rig.nl.keptState('Y1'), rig.nl.keptState('Y2')),
        (n + 1, false, 2, p, p),
        reason: rig.tr);
  });

  test('L6b: on home, an operation on Y1 with Y1 and Y2 parked: Y1 by a new connect, Y2 still parked', () async {
    final rig = await home2();
    final (s1, s2) = (rig.ks('Y1'), rig.ks('Y2'));
    final a = await rig.op((c, gone) => c.settings());
    expect(a.end, OpEnd.done, reason: '$a\n${rig.tr}');
    expect((s1.disposed, s2.disposed, rig.radio.connects, rig.radio.maxOpen), (true, false, 3, 2), reason: rig.tr);
    expect(rig.radio.order, ['a1', 'a2', 'a1']);
    expect((rig.nl.keptState('Y1'), rig.nl.keptState('Y2')), (p, p));
    expect(rig.gate.refused, isEmpty);
  });

  test('L7: a raw lease with 2 parked: no link is left when acquire returns', () async {
    final rig = await home2();
    final (s1, s2) = (rig.ks('Y1'), rig.ks('Y2'));
    final l = (await rig.nl.acquire('舊頁', LeaseKind.raw))!;
    expect((rig.gate.links, rig.radio.open, rig.nl.keptCount, s1.disposed, s2.disposed), (0, 0, 0, true, true),
        reason: rig.tr);
    await l.release();
  });

  test('L7: the same when the unsubscribe of tx takes 300 ms', () async {
    final rig = await home2(subCancelMs: 300);
    final (s1, s2) = (rig.ks('Y1'), rig.ks('Y2'));
    final f = rig.nl.acquire('舊頁', LeaseKind.raw);
    await rig.run(1000, adv: false);
    final l = (await f)!;
    expect((rig.gate.links, rig.radio.open, rig.nl.keptCount, s1.disposed, s2.disposed), (0, 0, 0, true, true),
        reason: rig.tr);
    await l.release();
  });

  test('L20: a kept link being closed is gone from the gate before its unsubscribe returns', () async {
    final rig = await home2(subCancelMs: 2000);
    rig.nl.background();
    await rig.run(300, adv: false);
    expect((rig.gate.links, rig.gate.active, rig.radio.open, rig.nl.keptCount), (0, 0, 0, 0), reason: rig.tr);
  });

  test('L8: Bluetooth off with 2 parked: both closed', () async {
    final rig = await home2();
    final (s1, s2) = (rig.ks('Y1'), rig.ks('Y2'));
    rig.nl.radio(bluetooth: false);
    await rig.run(100, adv: false);
    expect((rig.gate.links, rig.nl.keptCount, s1.disposed, s2.disposed), (0, 0, true, true), reason: rig.tr);
  });

  test('L9: link down on Y1: Y1 is forgotten; the next round reads Y2 on its link and Y1 by scan + connect', () async {
    final rig = await home2();
    final (s1, s2) = (rig.ks('Y1'), rig.ks('Y2'));
    rig.radio.drop('a1');
    await rig.run(100, adv: false);
    expect((rig.nl.keptState('Y1'), rig.nl.keptState('Y2'), s1.disposed, s2.disposed, rig.gate.links),
        (null, p, true, false, 1),
        reason: rig.tr);
    final scans = rig.radio.scans;
    await rig.run(61000);
    expect((s2.statusReqs, s2.disposed), (2, false), reason: rig.tr);
    expect(rig.radio.order, ['a1', 'a2', 'a1'], reason: rig.tr);
    expect(rig.radio.scans, scans + 1);
    expect((rig.nl.keptState('Y1'), rig.nl.keptState('Y2')), (p, p));
    expect(rig.gate.refused, isEmpty);
  });

  test('L10: the record of Y1 is removed: its link is closed, the link of Y2 stays', () async {
    final rig = await home2();
    final (s1, s2) = (rig.ks('Y1'), rig.ks('Y2'));
    rig.recs = [const Rec('Y2', 1)];
    final l = (await rig.nl.acquire('移除', LeaseKind.session))!;
    await l.release();
    await rig.run(300, adv: false);
    expect((rig.nl.keptState('Y1'), rig.nl.keptState('Y2'), s1.disposed, s2.disposed, rig.gate.links),
        (null, p, true, false, 1),
        reason: rig.tr);
  });

  test('L10: the record of Y2 is removed: its link is closed, the link of Y1 stays', () async {
    final rig = await home2();
    final (s1, s2) = (rig.ks('Y1'), rig.ks('Y2'));
    rig.recs = [const Rec('Y1', 1)];
    final l = (await rig.nl.acquire('移除', LeaseKind.session))!;
    await l.release();
    await rig.run(300, adv: false);
    expect((rig.nl.keptState('Y1'), rig.nl.keptState('Y2'), s1.disposed, s2.disposed, rig.gate.links),
        (p, null, false, true, 1),
        reason: rig.tr);
  });

  group('L11: 3 records, keptMax 2', () {
    test('never 3 links; each round after the first = 2 reads on kept links + 1 close + 1 connect', () async {
      final rig = await home(3);
      expect((rig.radio.connects, rig.radio.maxOpen, rig.nl.keptCount, rig.gate.links), (3, 2, 2, 2), reason: rig.tr);
      for (var round = 2; round <= 3; round++) {
        final before = {for (final id in ['Y1', 'Y2', 'Y3']) if (rig.nl.kept(id) != null) id: rig.ks(id)};
        final n = {for (final e in before.entries) e.key: e.value.statusReqs};
        final t0 = rig.clock.t;
        await rig.run(61000);
        expect((rig.radio.connects, rig.radio.maxOpen, rig.nl.keptCount, rig.gate.links), (round + 2, 2, 2, 2),
            reason: 'round $round\n${rig.tr}');
        expect([for (final e in before.entries) e.value.statusReqs - n[e.key]!], [1, 1], reason: 'round $round');
        expect(before.values.where((s) => s.disposed).length, 1, reason: 'round $round');
        for (final id in ['Y1', 'Y2', 'Y3']) {
          expect(rig.readAtOf(id), greaterThan(t0), reason: '$id in round $round\n${rig.tr}');
        }
      }
      expect(rig.gate.refused, isEmpty);
    });

    test('2 parked, an operation on the third from home: one is closed first, never 3 links', () async {
      final rig = await home(3);
      final out = ['Y1', 'Y2', 'Y3'].singleWhere((id) => rig.nl.kept(id) == null);
      final a = await rig.op((c, gone) => c.settings(), id: out);
      expect(a.end, OpEnd.done, reason: '$a\n${rig.tr}');
      expect((rig.radio.connects, rig.radio.maxOpen, rig.nl.keptCount, rig.gate.links), (4, 2, 2, 2), reason: rig.tr);
      expect(rig.nl.keptState(out), p);
      expect(rig.gate.refused, isEmpty);
    });

    test('a round cancelled while it waits for the closed link to go: no connect follows', () async {
      final rig = await home(3);
      rig.radio.goneMs = 2000;
      // round 2: two reads on the kept links, then one of them is closed for the third node's attempt
      await rig.wait(() => rig.nl.core.roundActive && rig.radio.open == 1 && rig.gate.links == 2,
          what: 'a kept link is closing for the attempt');
      expect(rig.radio.connects, 3);
      rig.nl.setPage(Page.other); // the round is cancelled
      await rig.run(5000);
      expect((rig.radio.connects, rig.gate.links, rig.nl.keptCount), (3, 1, 1), reason: rig.tr);
      expect(rig.gate.refused, isEmpty);
    });
  });

  test('L12: gate: a connect is refused for an address that has a link and while another link is connecting, in use '
      'or closing; allowed beside 2 parked links', () async {
    final rig = await home2();
    rig.nl.setPage(Page.other); // no round
    await rig.run(100, adv: false);
    final gate = rig.gate;
    final t = rig.reg.nodeLinkToken;
    expect(gate.active, 0);
    expect(() => gate.connect(t, 'a1'), throwsA(isA<Refused>()), reason: 'the address has a parked link');
    final l3 = gate.connect(t, 'a3'); // allowed beside 2 parked
    expect((gate.links, gate.active), (3, 1));
    expect(() => gate.connect(t, 'a4'), throwsA(isA<Refused>()), reason: 'another link is connecting');
    await rig.run(100, adv: false);
    expect(l3.up, isTrue);
    expect(() => gate.connect(t, 'a4'), throwsA(isA<Refused>()), reason: 'another link is in use');
    rig.radio.goneMs = 1000;
    unawaited(l3.close());
    await rig.run(500, adv: false);
    expect((gate.links, gate.active), (3, 1));
    expect(() => gate.connect(t, 'a4'), throwsA(isA<Refused>()), reason: 'another link is closing');
    await rig.run(600, adv: false);
    expect((gate.links, gate.active), (2, 0));
    final l4 = gate.connect(t, 'a4');
    await rig.run(100, adv: false);
    gate.pass(l4, null);
    expect((gate.links, gate.active), (3, 0), reason: 'the gate itself has no limit; keptMax is NodeLink\'s');
    rig.radio.goneMs = 0;
    await l4.close();
  });

  test('L13: a round begun 0.3 s after Y1 was parked, Y2 not kept: the attempt for Y2 waits for the read on Y1', () async {
    final rig = await home(2, advertising: 1); // Y2 is not there in round 1, which ended at 30 s
    expect((rig.nl.keptState('Y1'), rig.nl.keptState('Y2'), rig.radio.connects), (p, null, 1), reason: rig.tr);
    rig.nl.setPage(Page.other);
    await rig.until(95000);
    final r = rig.fly((c, gone) => c.settings()); // not from Y1's page: by a new connect, parked when it ends
    final t0 = await rig.step(() => r.isNotEmpty && rig.nl.keptState('Y1') == p, what: 'given back');
    expect(rig.radio.connects, 2, reason: rig.tr);
    final s1 = rig.ks('Y1');
    final n = s1.statusReqs;
    rig.advs = ['a1', 'a2'];
    await rig.until(t0 + 300);
    rig.nl.setPage(Page.home); // the last full round ended over 60 s ago: one begins now
    expect(rig.nl.core.roundTargets, {'Y1', 'Y2'});
    await rig.until(t0 + 900); // a2 was seen in the scan
    expect((rig.radio.connects, s1.statusReqs - n), (2, 0), reason: 'an attempt before the read on Y1\n${rig.tr}');
    await rig.wait(() => s1.statusReqs == n + 1, max: 400, what: 'the read on Y1 started');
    await rig.wait(() => rig.nl.keptState('Y2') == p, what: 'Y2 read');
    expect((rig.radio.order.last, rig.radio.connects, rig.radio.maxOpen, s1.disposed), ('a2', 3, 2, false));
    expect(rig.gate.refused, isEmpty);
  });

  test('L14: all targets kept: the round starts no scan; the link of Y1 dies in the round -> the scan starts', () async {
    final rig = await home2();
    final scans = rig.radio.scans;
    rig.radio.hold[fStatus] = [-1]; // the first kept read of round 2 gets no answer: closed after 5 s
    final t0 = await rig.step(() => rig.nl.core.roundActive, what: 'round 2');
    await rig.until(t0 + 4000);
    expect((rig.radio.scans, rig.radio.connects, rig.gate.links), (scans, 2, 2), reason: rig.tr);
    await rig.until(t0 + 10000);
    expect((rig.radio.scans, rig.radio.connects, rig.nl.keptCount), (scans + 1, 3, 2), reason: rig.tr);
  });

  test('L15: a kept read of Y1 fails: its link is closed; the attempt starts only when that link is gone and is not '
      'refused; Y2 is untouched', () async {
    final rig = await home2();
    final (s1, s2) = (rig.ks('Y1'), rig.ks('Y2'));
    rig.radio.hold[fStatus] = [-1];
    rig.radio.goneMs = 1500;
    await rig.wait(() => rig.radio.open == 1, what: 'the kept read failed and its link is closing');
    final t0 = rig.clock.t;
    final dead = rig.radio.linked.contains('a1') ? 'Y2' : 'Y1', live = dead == 'Y1' ? 'Y2' : 'Y1';
    expect((s1.disposed, s2.disposed), (false, false), reason: 'disposed when the link is gone');
    await rig.until(t0 + 1000);
    expect((rig.radio.connects, rig.gate.links), (2, 2), reason: 'an attempt while the link was closing\n${rig.tr}');
    await rig.wait(() => rig.nl.keptState(dead) == p, what: 'read by a new connect');
    expect(rig.radio.connects, 3, reason: rig.tr);
    expect(rig.gate.refused, isEmpty, reason: rig.tr);
    expect((rig.nl.keptState(live), rig.ks(live).disposed, rig.ks(live).statusReqs), (p, false, 2));
    expect(rig.nl.core.states[dead]!.kind, Kind.read);
  });

  test('L16: a kept read of Y1 ends with an error code while Y2 is looked for and Y1\'s address is seen in the scan: '
      'no attempt for Y1; the round ends at its window', () async {
    final rig = await home(2, advertising: 1);
    expect((rig.nl.keptState('Y1'), rig.nl.keptState('Y2')), (p, null), reason: rig.tr);
    final s1 = rig.ks('Y1');
    s1.row = "2'";
    final t0 = await rig.step(() => rig.nl.core.roundTargets.contains('Y1'), what: 'the next full round');
    for (var i = 0; i < 350; i++) {
      if (i % 5 == 0) rig.radio.scanCtl.add('a1'); // a stack that still reports the held node's address
      await rig.run(100, adv: false);
    }
    expect((s1.statusReqs, rig.radio.connects, rig.nl.keptState('Y1'), s1.disposed), (2, 1, p, false), reason: rig.tr);
    expect(rig.gate.refused, isEmpty);
    expect(rig.nl.core.roundActive, isFalse, reason: 'the round ended at its window (${rig.clock.t - t0} ms)');
  });

  group('L17: a kept link is read again no sooner than 1.1 s after it was parked', () {
    /// A new round starts at t0 + 300 by [go]; the read on the kept link starts at t0 + 1100.
    Future<void> check(KRig rig, int t0, void Function() go, {bool pumpInWait = false}) async {
      final s = rig.ks('Y1');
      final n = s.statusReqs;
      await rig.until(t0 + 300, adv: false);
      go();
      if (pumpInWait) {
        await rig.until(t0 + 600, adv: false);
        rig.nl.radio(); // nothing changed: only a pump
      }
      await rig.until(t0 + 1000, adv: false);
      expect(s.statusReqs, n, reason: 'read before 1.1 s\n${rig.tr}');
      await rig.until(t0 + 1300, adv: false);
      expect((s.statusReqs, rig.radio.connects, s.disposed), (n + 1, 1, false), reason: rig.tr);
    }

    /// One record; the step in which Y1 was parked ends at the returned time (the park itself: up to 100 ms before).
    Future<(KRig, int)> parkedByAttempt() async {
      final rig = KRig(rust, recs: [const Rec('Y1', 1)]);
      await rig.nl.start(Page.home);
      final t0 = await rig.step(() => rig.nl.keptState('Y1') == p, what: 'parked');
      return (rig, t0);
    }

    test('after an attempt', () async {
      final (rig, t0) = await parkedByAttempt();
      await check(rig, t0, () => rig.nl.setPage(Page.node, node: 'Y1'));
    });
    test('after an attempt; a pump during the wait does not lose the wake-up', () async {
      final (rig, t0) = await parkedByAttempt();
      await check(rig, t0, () => rig.nl.setPage(Page.node, node: 'Y1'), pumpInWait: true);
    });
    test('after a kept read', () async {
      final (rig, _) = await parkedByAttempt();
      final s = rig.ks('Y1');
      await rig.wait(() => s.statusReqs == 2, what: 'the 60 s read', adv: false);
      final t0 = await rig.step(() => rig.nl.keptState('Y1') == p, adv: false, what: 'parked again');
      await check(rig, t0, () => rig.nl.setPage(Page.node, node: 'Y1'));
    });
    test('after give-back', () async {
      final (rig, _) = await parkedByAttempt();
      rig.nl.setPage(Page.node, node: 'Y1');
      await rig.run(2000, adv: false);
      final r = rig.fly((c, gone) => c.settings());
      final t0 = await rig.step(() => r.isNotEmpty && rig.nl.keptState('Y1') == p, adv: false, what: 'given back');
      await check(rig, t0, () {
        rig.nl.setPage(Page.home);
        rig.nl.setPage(Page.node, node: 'Y1'); // the page again: a new round for Y1
      });
    });
  });

  test('L18: home -> node page while the kept link is being read: the read ends, the link is parked, the page has '
      'the body', () async {
    final rig = await home2();
    final s1 = rig.ks('Y1');
    rig.radio.hold[fInfo] = [1000];
    await rig.wait(() => rig.nl.keptState('Y1') == KeptState.reading && rig.radio.written.last == fInfo,
        what: 'the 60 s read of Y1 asked for info');
    final t0 = rig.clock.t;
    rig.nl.setPage(Page.node, node: 'Y1');
    await rig.run(1500, adv: false);
    expect((rig.nl.keptState('Y1'), s1.disposed, rig.radio.connects), (p, false, 2), reason: rig.tr);
    expect(rig.readAtOf('Y1'), greaterThan(t0), reason: rig.tr);
    expect(rig.nl.core.states['Y1']!.kind, Kind.read);
  });

  test('L19: a node held and read for 21 min, then lost: its address memo lives 20 min from the last kept read', () async {
    final rig = KRig(rust, recs: [const Rec('Y1', 1)]);
    await rig.nl.start(Page.home);
    await rig.until(21 * 60000);
    final core = rig.nl.core;
    expect((rig.radio.connects, rig.nl.keptState('Y1'), core.isY['a1']), (1, p, 'Y1'), reason: 'held for 21 min');
    final last = core.lastSeen['a1']!;
    expect(rig.clock.t - last, lessThan(61000), reason: 'the memo ages from the last kept read');
    rig.quiet = true;
    rig.radio.drop('a1');
    await rig.until(last + 19 * 60000, adv: false);
    expect((core.isY['a1'], core.lastSeen.containsKey('a1')), ('Y1', true));
    await rig.until(last + 21 * 60000 + 31000, adv: false);
    expect((core.isY['a1'], core.lastSeen.containsKey('a1')), (null, false), reason: 'dropped after 20 min');
  });
}
