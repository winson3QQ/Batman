// #329 §4.3, sixth batch: code review 2 (A-M1, B-M1, B-M2 and the MINORs with a behaviour). G-B5 / G-B7 / S7c / S11
// are reviewer B's scenarios, ported to this simulator.
import 'package:batman_app/src/nodelink/core.dart';
import 'package:flutter_test/flutter_test.dart';

import 'sim.dart';

const s = 1000;
const min = 60 * s;

int t(String l) => (double.parse(l.trim().split(' ').first) * 1000).round();
int ends(NodeLinkCore c) => c.log.where((l) => l.contains(' end ')).length;

void untilEnd(World w, NodeLinkCore c, {int limit = 5 * min}) {
  final n = ends(c), stop = w.now + limit;
  while (ends(c) == n && w.now < stop) {
    w.run(w.now + 500);
  }
}

void main() {
  test('G-B5 / T-L2(c): a target that stays 還沒輪到 gets at most 3 early re-reads in a row', () {
    final w = World();
    w.dev('a1', id: 'Y1');
    for (var i = 0; i < 12; i++) {
      w.dev('f$i', mode: Mode.foreignUndecryptable);
    }
    final ph = w.phone('p', [for (var i = 0; i < 10; i++) Rec('S$i', 100 + i), const Rec('Y1', 1000)]);
    final c = ph.core;
    c.startup(0, Page.home);
    w.run(15 * min);
    // the count is not reset by full rounds, only by a round with no trigger: while every round has one, at most 3
    final noTrigger = c.log.where((l) => l.contains(' end ') && !l.contains('notYet') && !l.contains('notFound'));
    expect(noTrigger, isEmpty, reason: 'premise: every round has a trigger, so the count never resets');
    expect(c.log.where((l) => l.contains(' early ')).length, 3, reason: c.log.join('\n'));
  });

  test('G-B7: a node already shown 連不到 does not trigger early re-reads, even with untried foreign addresses', () {
    final w = World();
    w.dev('a1', id: 'Y1');
    final d2 = w.dev('a2', id: 'Y2');
    final ph = w.phone('p', [const Rec('Y1', 1), const Rec('Y2', 2)]);
    final c = ph.core;
    c.startup(0, Page.home);
    w.run(3 * min);
    d2.on = false;
    while (c.states['Y2']!.why != Why.notFound && w.now < 20 * min) {
      w.run(w.now + s);
    }
    final at = w.now;
    for (var i = 0; i < 20; i++) {
      w.dev('f$i', mode: Mode.foreignUndecryptable);
    }
    w.run(at + 10 * min);
    expect(c.log.where((l) => t(l) > at && l.contains('Y2: notYet')), isNotEmpty, reason: 'premise');
    expect(c.log.where((l) => t(l) > at && l.contains(' early ')), isEmpty, reason: c.log.join('\n'));
  });

  test('refresh while an early re-read runs cancels it and starts a full round at once', () {
    final w = World();
    w.dev('a1', id: 'Y1');
    w.dev('a2', id: 'Y2').on = false;
    final ph = w.phone('p', [const Rec('Y1', 1), const Rec('Y2', 2)]);
    final c = ph.core;
    c.startup(0, Page.home);
    while (!c.roundIsEarly && w.now < 5 * min) {
      w.run(w.now + 500);
    }
    expect(c.roundIsEarly, isTrue);
    c.refresh(w.now);
    expect(c.roundActive, isTrue);
    expect(c.roundIsEarly, isFalse, reason: c.log.join('\n'));
  });

  test('notYetRun counts consecutive 還沒輪到 rounds and resets on another conclusion', () {
    final w = World();
    w.dev('a1', id: 'Y1');
    for (var i = 0; i < 12; i++) {
      w.dev('f$i', mode: Mode.foreignUndecryptable);
    }
    final ph = w.phone('p', [for (var i = 0; i < 10; i++) Rec('S$i', 100 + i), const Rec('Y1', 1000)]);
    final c = ph.core;
    c.startup(0, Page.home);
    untilEnd(w, c);
    untilEnd(w, c);
    expect(c.states['S0']!.notYetRun, 2, reason: c.log.join('\n'));
    w.run(30 * min);
    expect(c.states['S0']!.last, Concl.notFound);
    expect(c.states['S0']!.notYetRun, 0);
  });

  test('a lease that writes a record clears that record\x27s 「不是」 memos (and only that record\x27s)', () {
    final c = NodeLinkCore([const Rec('Y1', 1), const Rec('Y2', 2)]);
    c.startup(0, Page.home);
    c.notY['z1'] = {'Y1', 'Y2'};
    c.acquireLease(1);
    c.releaseLease(2, written: {'Y1'});
    expect(c.notY['z1'], {'Y2'});
  });

  test('loginFor never tries an address with a 「不是 Y」 memo (without 再試一次)', () {
    final w = World();
    final d = w.dev('a1', id: 'Y1');
    final ph = w.phone('p', [const Rec('Y1', 1)]);
    final c = ph.core;
    c.startup(0, Page.other);
    c.notY['a1'] = {'Y1'};
    c.acquireLease(w.now);
    final l = c.loginFor(w.now, 'Y1');
    ph.login = l;
    w.run(70 * s);
    expect(l.end, LoginEnd.notFound);
    expect(d.handshakes, 0);
  });

  test('F-b2: 沒找到, 登入被拒, 沒找到 -> not 找不到 (the two are not consecutive)', () {
    final w = World();
    final d = w.dev('a1', id: 'Y1')..on = false;
    final ph = w.phone('p', [const Rec('Y1', 1)]);
    final c = ph.core;
    c.startup(0, Page.home);
    untilEnd(w, c); // 沒找到 (1)
    d
      ..on = true
      ..force = Res.refusedForbidden;
    untilEnd(w, c); // the early re-read: 登入被拒
    expect(c.states['Y1']!.why, Why.refused, reason: c.log.join('\n'));
    d.on = false;
    untilEnd(w, c); // 沒找到 again: one, not two in a row
    expect(c.states['Y1']!.why, Why.refused, reason: c.log.join('\n'));
  });

  test('Bluetooth off: no node is fresh (no green row while Bluetooth is off)', () {
    final w = World();
    w.dev('a1', id: 'Y1');
    final ph = w.phone('p', [const Rec('Y1', 1)]);
    final c = ph.core;
    c.startup(0, Page.home);
    untilEnd(w, c);
    expect(c.fresh('Y1', w.now), isTrue);
    c.setRadio(w.now, bluetooth: false);
    expect(c.fresh('Y1', w.now), isFalse);
    c.setRadio(w.now, bluetooth: true);
    expect(c.fresh('Y1', w.now), isTrue);
  });

  test('a late result of a cancelled attempt is dropped, also when a new round runs the same pair', () {
    final c = NodeLinkCore([const Rec('Y1', 1)]);
    c.startup(0, Page.home);
    c.onScan(3 * s, 'a1');
    final old = c.next(3 * s)!;
    c.refresh(4 * s); // no-op for a full round; cancel it another way:
    c.setPage(5 * s, Page.other);
    c.setPage(6 * s, Page.home); // < 60 s: no round yet
    c.refresh(7 * s); // a new full round
    c.onScan(10 * s, 'a1');
    final cur = c.next(10 * s)!;
    expect(cur.addr, old.addr);
    c.result(11 * s, old, const Outcome(Res.body, 'green')); // the old attempt answers late
    expect(c.states['Y1']!.kind, Kind.unread, reason: 'not counted for the new attempt');
    c.result(21 * s, cur, const Outcome(Res.body, 'green'));
    expect(c.states['Y1']!.kind, Kind.read);
  });

  test('loginFor ends at once (precondition) when Bluetooth goes off during it', () {
    final w = World();
    w.dev('a1', id: 'Y1').busyUntil = 1 << 40; // never answers
    final ph = w.phone('p', [const Rec('Y1', 1)]);
    final c = ph.core;
    c.startup(0, Page.other);
    c.acquireLease(0);
    final l = c.loginFor(0, 'Y1');
    ph.login = l;
    w.run(10 * s);
    c.setRadio(w.now, bluetooth: false);
    expect(l.end, LoginEnd.precondition);
  });

  test('the node page of a record just removed starts no round', () {
    final c = NodeLinkCore([const Rec('Y1', 1)]);
    c.startup(0, Page.node, node: 'Y1');
    c.acquireLease(1);
    c.releaseLease(2, written: {'Y1'}, recs: const []);
    final n = c.roundsRun;
    c.tick(9 * s);
    expect(c.roundsRun, n);
  });

  for (final nf in [4, 6, 8, 10]) {
    test('S7c: claim, at once loginFor; the claimed node is scanned first, $nf idle foreign nodes -> ok first time', () {
      final w = World();
      final n2 = w.dev('u2', id: 'Y2');
      for (var i = 0; i < nf; i++) {
        w.dev('f$i', mode: Mode.foreignUndecryptable);
      }
      final ph = w.phone('p', const []);
      final c = ph.core;
      c.startup(0, Page.home);
      w.run(1 * min);
      late LoginFor l;
      final at = w.now + 1;
      w.at(at, () => c.acquireLease(w.now));
      w.at(at + 12 * s, () {
        n2.claimedAt = w.now;
        c.releaseLease(w.now, written: {'Y2'}, recs: const [Rec('Y2', 2)]);
        c.acquireLease(w.now);
        l = c.loginFor(w.now, 'Y2');
        ph.login = l;
      });
      w.run(at + 12 * s + 70 * s);
      expect(l.end, LoginEnd.ok, reason: c.log.join('\n'));
    });
  }

  for (final m in [4, 7, 10]) {
    test('S11: $m team members in one room each claim a node 3 s apart, then at once loginFor -> all ok first time', () {
      final w = World();
      final ds = [for (var i = 0; i < m; i++) w.dev('a$i', id: 'Y$i')..on = false];
      final ps = [for (var i = 0; i < m; i++) w.phone('p$i', const [])];
      for (final p in ps) {
        p.core.startup(0, Page.home);
      }
      for (var i = 0; i < m; i++) {
        final i0 = i;
        w.at(i * 3 * s, () {
          ds[i0].on = true;
          ps[i0].core.acquireLease(w.now);
        });
        w.at(i * 3 * s + 12 * s, () {
          ds[i0].claimedAt = w.now;
          ps[i0].core.releaseLease(w.now, written: {'Y$i0'}, recs: [Rec('Y$i0', 1)]);
          ps[i0].core.acquireLease(w.now);
          ps[i0].login = ps[i0].core.loginFor(w.now, 'Y$i0');
        });
      }
      w.run(m * 3 * s + 12 * s + 70 * s);
      final ends = [for (final p in ps) p.login!.end?.name ?? 'running'];
      expect(ends.where((e) => e != 'ok'), isEmpty, reason: '$ends');
    });
  }
}
