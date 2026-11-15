// #329 §4.3, third batch: one test per rule that code review 1 (A-M4) found no test for. Each names the rule it locks;
// its negative control is the mutation of the same name in the mutation script.
import 'package:batman_app/src/nodelink/core.dart';
import 'package:flutter_test/flutter_test.dart';

import 'sim.dart';

const s = 1000;
const min = 60 * s;

int t(String l) => (double.parse(l.trim().split(' ').first) * 1000).round();
int ends(NodeLinkCore c) => c.log.where((l) => l.contains(' end ')).length;

/// Run until `c` ends one more round (at most `limit` ms from now).
void untilEnd(World w, NodeLinkCore c, {int limit = 5 * min}) {
  final n = ends(c), stop = w.now + limit;
  while (ends(c) == n && w.now < stop) {
    w.run(w.now + 500);
  }
}

List<int> fullStarts(NodeLinkCore c) => [for (final l in c.log) if (l.contains(' full ')) t(l)];

void main() {
  test('a: a memo of an address not seen for 20 minutes is dropped', () {
    final w = World();
    final d = w.dev('a1', id: 'Y1');
    final ph = w.phone('p', [const Rec('Y1', 1)]);
    final c = ph.core;
    c.startup(0, Page.home);
    w.run(2 * min);
    expect(c.isY['a1'], 'Y1');
    d.on = false;
    w.run(w.now + 21 * min);
    expect(c.isY['a1'], isNull, reason: c.log.join('\n'));
  });

  test('c: no response on the known address -> retried in the same round, read in it', () {
    final w = World();
    final d = w.dev('a1', id: 'Y1');
    final ph = w.phone('p', [const Rec('Y1', 1)]);
    final c = ph.core;
    c.startup(0, Page.home);
    w.run(2 * min);
    final next = c.fullDue!;
    w.at(next - 1, () => d.force = Res.noResponse);
    w.at(next + 6 * s, () => d.force = null);
    w.run(next + 45 * s);
    final r = (ph.reads['Y1'] ?? []).where((x) => x > next);
    expect(r, isNotEmpty, reason: c.log.join('\n'));
    expect(r.first, lessThan(next + 30 * s), reason: 'read inside that round\n${c.log.join('\n')}');
  });

  test('d: logged in this round (an error code twice) -> its record is never tried on another address', () {
    final w = World();
    final f = w.dev('f0', mode: Mode.foreignUndecryptable);
    w.dev('a1', id: 'Y1').statusScript = [Res.errorCode, Res.errorCode];
    final ph = w.phone('p', [const Rec('Y1', 1)]);
    final c = ph.core;
    c.startup(0, Page.home);
    w.run(60 * s);
    expect(c.states['Y1']!.responded, isTrue, reason: c.log.join('\n'));
    final logF = c.log.where((l) => l.contains('f0×Y1'));
    final logA = c.log.where((l) => l.contains('a1×Y1 -> errorCode'));
    expect(logA.length, 2, reason: c.log.join('\n'));
    // f0 may only have been tried before the first login, never after it
    final firstLogin = t(logA.first);
    expect(logF.where((l) => t(l) > firstLogin), isEmpty, reason: c.log.join('\n'));
    expect(f.handshakes, lessThanOrEqualTo(1));
  });

  test('h/i: 不變 resets the miss count and ends 找不到', () {
    final w = World();
    final d = w.dev('a1', id: 'Y1')..on = false;
    final ph = w.phone('p', [const Rec('Y1', 1)]);
    final c = ph.core;
    c.startup(0, Page.home);
    // two misses -> 找不到
    untilEnd(w, c);
    untilEnd(w, c);
    expect(c.states['Y1']!.why, Why.notFound, reason: c.log.join('\n'));
    // it answers, with an error code only
    d
      ..on = true
      ..statusScript = [Res.errorCode, Res.errorCode];
    untilEnd(w, c);
    expect(c.states['Y1']!.last, Concl.unchanged, reason: c.log.join('\n'));
    expect(c.states['Y1']!.kind, isNot(Kind.unreachable), reason: 'i: 不變 ends 找不到\n${c.log.join('\n')}');
    // one miss right after: not 連不到 again (h: the miss count was reset)
    d.on = false;
    untilEnd(w, c);
    expect(c.states['Y1']!.kind, isNot(Kind.unreachable), reason: 'h\n${c.log.join('\n')}');
  });

  test("k: 2' never covers 身分不符", () {
    final w = World();
    w.dev('aX', id: 'Y1').force = Res.certRejected; // a clone, scanned first
    w.dev('a1', id: 'Y1').statusScript = List.filled(50, Res.errorCode, growable: true);
    final ph = w.phone('p', [const Rec('Y1', 1)]);
    final c = ph.core;
    c.startup(0, Page.home);
    w.run(8 * min);
    expect(c.shownWhy('Y1'), Why.identity, reason: c.log.join('\n'));
  });

  test('m: a lease that rewrites the record ends 身分不符', () {
    final w = World();
    final d = w.dev('a1', id: 'Y1')..force = Res.certRejected;
    final ph = w.phone('p', [const Rec('Y1', 1)]);
    final c = ph.core;
    c.startup(0, Page.home);
    w.run(20 * s);
    expect(c.shownWhy('Y1'), Why.identity);
    d.force = null;
    c.acquireLease(w.now);
    c.releaseLease(w.now + s, written: {'Y1'});
    expect(c.shownWhy('Y1'), isNull, reason: c.log.join('\n'));
  });

  test('refresh keeps 身分不符 until a read (the code is stricter than v12.1 prose; back-filled)', () {
    final w = World();
    final d = w.dev('a1', id: 'Y1')..force = Res.certRejected;
    final ph = w.phone('p', [const Rec('Y1', 1)]);
    final c = ph.core;
    c.startup(0, Page.home);
    w.run(20 * s);
    d.on = false;
    c.refresh(w.now);
    w.run(w.now + 5 * min);
    expect(c.shownWhy('Y1'), Why.identity, reason: c.log.join('\n'));
  });

  test('o: back home from another page before 60 s -> no read until 60 s after the last full round', () {
    final w = World();
    w.dev('a1', id: 'Y1');
    final ph = w.phone('p', [const Rec('Y1', 1)]);
    final c = ph.core;
    c.startup(0, Page.home);
    untilEnd(w, c);
    final end = w.now;
    c.setPage(w.now, Page.other);
    w.run(end + 20 * s);
    final n = c.roundsRun;
    c.setPage(w.now, Page.home);
    expect(c.roundsRun, n, reason: 'not at once');
    w.run(end + 59 * s);
    expect(c.roundsRun, n);
    w.run(end + 60 * s);
    expect(c.roundsRun, n + 1, reason: c.log.join('\n'));
  });

  test('p: a node-page round does not count as 「上一輪結束」 for the home page', () {
    final w = World();
    w.dev('a1', id: 'Y1');
    w.dev('a2', id: 'Y2');
    final ph = w.phone('p', [const Rec('Y1', 1), const Rec('Y2', 2)]);
    final c = ph.core;
    c.startup(0, Page.home);
    untilEnd(w, c);
    final homeEnd = t(c.log.lastWhere((l) => l.contains(' end ')));
    c.setPage(w.now, Page.node, node: 'Y1');
    untilEnd(w, c);
    c.setPage(w.now, Page.home);
    w.run(homeEnd + 60 * s);
    expect(fullStarts(c).last, homeEnd + 60 * s, reason: c.log.join('\n'));
  });

  test('u: an early re-read does not count toward the two 不變 rounds', () {
    final w = World();
    final d = w.dev('a1', id: 'Y1')..on = false;
    final ph = w.phone('p', [const Rec('Y1', 1)]);
    final c = ph.core;
    c.startup(0, Page.home);
    untilEnd(w, c); // a first 沒找到 -> early re-read in 10 s
    d
      ..on = true
      ..statusScript = List.filled(50, Res.errorCode, growable: true);
    untilEnd(w, c); // the early round: 不變 (not counted)
    expect(c.log.last, contains('unchanged'), reason: c.log.join('\n'));
    untilEnd(w, c); // first full 不變
    expect(c.states['Y1']!.view, isNot("2'"), reason: c.log.join('\n'));
    untilEnd(w, c); // second full 不變 -> gray
    expect(c.states['Y1']!.view, "2'", reason: c.log.join('\n'));
  });

  group('loginFor', () {
    (World, Phone, NodeLinkCore) setup() {
      final w = World();
      final ph = w.phone('p', [const Rec('Y1', 1), const Rec('Y2', 2)]);
      return (w, ph, ph.core);
    }

    LoginFor start(World w, Phone ph, NodeLinkCore c, {bool clear = false}) {
      c.acquireLease(w.now);
      final l = c.loginFor(w.now, 'Y1', clearNotY: clear);
      ph.login = l;
      return l;
    }

    test('v: 身分不符 in loginFor reaches the home state', () {
      final (w, ph, c) = setup();
      w.dev('a1', id: 'Y1').force = Res.certRejected;
      c.startup(0, Page.other);
      final l = start(w, ph, c);
      w.run(60 * s);
      expect(l.end, LoginEnd.identity);
      expect(c.shownWhy('Y1'), Why.identity);
    });

    test('w: 「再試一次」 clears a wrong 「不是 Y」 first', () {
      final (w, ph, c) = setup();
      w.dev('a1', id: 'Y1');
      c.startup(0, Page.other);
      c.notY['a1'] = {'Y1'}; // a wrong memo (e.g. from a replay)
      final l = start(w, ph, c, clear: true);
      w.run(60 * s);
      expect(l.end, LoginEnd.ok, reason: c.log.join('\n'));
    });

    test('ll: a failed precondition ends loginFor at once, no scan', () {
      final (w, ph, c) = setup();
      final d = w.dev('a1', id: 'Y1');
      c.startup(0, Page.other);
      c.setRadio(0, bluetooth: false);
      final l = start(w, ph, c);
      w.run(60 * s);
      expect(l.end, LoginEnd.precondition);
      expect(d.handshakes, 0);
    });

    test('mm: EForbidden ends loginFor with 登入被拒', () {
      final (w, ph, c) = setup();
      final d = w.dev('a1', id: 'Y1')..force = Res.refusedForbidden;
      c.startup(0, Page.other);
      final l = start(w, ph, c);
      w.run(60 * s);
      expect(l.end, LoginEnd.refused);
      expect(d.handshakes, 1);
    });

    test('kk: loginFor never tries an address that is another node\x27s', () {
      final (w, ph, c) = setup();
      final d2 = w.dev('a2', id: 'Y2');
      w.dev('a1', id: 'Y1').on = false;
      c.startup(0, Page.home);
      w.run(2 * min);
      expect(c.isY['a2'], 'Y2');
      final h = d2.handshakes;
      final l = start(w, ph, c);
      w.run(w.now + 70 * s);
      expect(l.end, LoginEnd.notFound);
      expect(d2.handshakes, h, reason: c.log.join('\n'));
    });

    test('loginFor ends at 60 s even with an attempt running', () {
      final (w, ph, c) = setup();
      w.dev('a1', id: 'Y1');
      c.startup(0, Page.other);
      final l = start(w, ph, c);
      final t0 = w.now;
      w.at(t0 + 55 * s, () {}); // nothing; the node is busy elsewhere for the whole minute:
      w.devs.first.busyUntil = t0 + 10 * min;
      w.run(t0 + 61 * s);
      expect(l.end, LoginEnd.notFound);
    });
  });

  test('y: going to the background resets the early re-read count', () {
    final w = World();
    w.dev('a1', id: 'Y1');
    w.dev('a2', id: 'Y2').on = false;
    for (var i = 0; i < 12; i++) {
      w.dev('f$i', mode: Mode.foreignUndecryptable);
    }
    final ph = w.phone('p', [for (var i = 0; i < 10; i++) Rec('S$i', 100 + i), const Rec('Y1', 1000), const Rec('Y2', 999)]);
    final c = ph.core;
    c.startup(0, Page.home);
    while (c.earlyCount < 3 && w.now < 20 * min) {
      w.run(w.now + s);
    }
    expect(c.earlyCount, 3);
    c.background(w.now);
    c.foreground(w.now + s);
    final n = c.log.where((l) => l.contains(' early ')).length;
    untilEnd(w, c);
    w.run(w.now + 11 * s);
    expect(c.log.where((l) => l.contains(' early ')).length, n + 1, reason: c.log.join('\n'));
  });

  test('hh: a round with no trigger resets the early count: a second outage gets its early re-read too', () {
    final w = World();
    final d = w.dev('a1', id: 'Y1');
    final ph = w.phone('p', [const Rec('Y1', 1)]);
    final c = ph.core;
    c.startup(0, Page.home);
    for (var k = 0; k < 4; k++) {
      d.on = false;
      untilEnd(w, c);
      untilEnd(w, c);
      d.on = true;
      untilEnd(w, c);
      untilEnd(w, c);
    }
    // every outage: a full round 沒找到, then an early re-read [Y1]
    expect(c.log.where((l) => l.contains(' early [Y1]')).length, greaterThanOrEqualTo(4), reason: c.log.join('\n'));
  });

  test('rr: the N9 window covers only the record written under the lease', () {
    final w = World();
    final f = w.dev('f0', mode: Mode.foreignUndecryptable);
    w.dev('a1', id: 'Y1').on = false;
    w.dev('a2', id: 'Y2').on = false;
    final ph = w.phone('p', [const Rec('Y1', 1), const Rec('Y2', 2)]);
    final c = ph.core;
    c.startup(0, Page.other);
    c.acquireLease(0);
    c.releaseLease(s, written: {'Y1'});
    c.setPage(s, Page.home);
    w.run(28 * s);
    expect(f.handshakes, greaterThan(0));
    expect(c.notY['f0']?.contains('Y2') ?? false, isTrue, reason: c.log.join('\n'));
  });

  test('T-L11(e): a silent address goes last the next round', () {
    final w = World();
    final x = w.dev('x0', mode: Mode.foreignSilent);
    final d = w.dev('a1', id: 'Y1');
    final ph = w.phone('p', [const Rec('Y1', 1)]);
    final c = ph.core;
    c.startup(0, Page.home);
    untilEnd(w, c);
    expect(x.handshakes, 1, reason: c.log.join('\n'));
    // Y1's address changes: next round both addresses are unknown; the new one is tried first
    d.addr = 'a1new';
    final h = x.handshakes;
    w.run(c.fullDue! + 50 * s); // it waits 30 s for its known address first, then looks
    expect(x.handshakes, h, reason: c.log.join('\n'));
    expect(ph.reads['Y1']!.length, 2);
  });

  test('T-L14 sharpened: 12 silent addresses scanned first every round, one own address just changed -> '
      'the known node is read within 40 s of every full round', () {
    final w = World();
    final d1 = w.dev('a1', id: 'Y1');
    final d2 = w.dev('a2', id: 'Y2');
    final ph = w.phone('p', [const Rec('Y1', 1), const Rec('Y2', 2)]);
    final c = ph.core;
    c.startup(0, Page.home);
    w.run(2 * min);
    // silent ones appear (scanned before the nodes from now on: they are listed first) and Y2 rotates
    final xs = [for (var i = 0; i < 12; i++) Dev('x$i', mode: Mode.foreignSilent)];
    w.devs.insertAll(0, xs);
    d2.addr = 'a2new';
    final from = w.now;
    w.run(from + 8 * min);
    for (final st in fullStarts(c).where((x) => x > from && x < from + 7 * min)) {
      expect((ph.reads['Y1'] ?? []).any((r) => r >= st && r <= st + 40 * s), isTrue,
          reason: 'round at ${st ~/ 1000}\n${c.log.join('\n')}');
    }
    expect((ph.reads['Y2'] ?? []).any((r) => r > from), isTrue, reason: c.log.join('\n'));
    expect(d1.on, isTrue);
  });

  test('T-L2(e) premise: the first 4 full rounds really run to the 90 s cap', () {
    final w = World();
    w.dev('a1', id: 'Y1');
    w.dev('a2', id: 'Y2').on = false;
    for (var i = 0; i < 12; i++) {
      w.dev('f$i', mode: Mode.foreignUndecryptable);
    }
    final ph = w.phone('p', [for (var i = 0; i < 10; i++) Rec('S$i', 100 + i), const Rec('Y1', 1000), const Rec('Y2', 999)]);
    final c = ph.core;
    c.startup(0, Page.home);
    w.run(10 * min);
    final starts = <String, int>{};
    final lens = <int>[];
    for (final l in c.log) {
      final m = RegExp(r'round (\d+) (full|end)').firstMatch(l);
      if (m == null) continue;
      if (m.group(2) == 'full') starts[m.group(1)!] = t(l);
      if (m.group(2) == 'end' && starts.containsKey(m.group(1))) lens.add(t(l) - starts[m.group(1)]!);
    }
    expect(lens.take(4), everyElement(90 * s), reason: c.log.join('\n'));
  });
}
