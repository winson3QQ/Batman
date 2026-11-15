// #329 §4.3, fifth batch: the rules code review 1 (B-M5) still found unguarded after the third and fourth batches.
import 'package:batman_app/src/nodelink/core.dart';
import 'package:flutter_test/flutter_test.dart';

import 'sim.dart';

const s = 1000;
const min = 60 * s;

int ends(NodeLinkCore c) => c.log.where((l) => l.contains(' end ')).length;

void untilEnd(World w, NodeLinkCore c, {int limit = 5 * min}) {
  final n = ends(c), stop = w.now + limit;
  while (ends(c) == n && w.now < stop) {
    w.run(w.now + 500);
  }
}

void main() {
  test('R1 / T-H2(b): a read goes unknown 300 s after it when no later round reads the node', () {
    final w = World();
    final d = w.dev('a1', id: 'Y1');
    final ph = w.phone('p', [const Rec('Y1', 1)]);
    final c = ph.core;
    c.startup(0, Page.home);
    untilEnd(w, c);
    final at = c.states['Y1']!.readAt!;
    d.on = false;
    c.setPage(w.now, Page.other); // no later round: only time passes
    w.run(at + 299 * s);
    expect(c.fresh('Y1', w.now), isTrue);
    w.run(at + 301 * s);
    expect(c.fresh('Y1', w.now), isFalse, reason: c.log.join('\n'));
  });

  test('R8 / X34: background on a settings page, then back home -> a round at once (the last-round time is gone)',
      () {
    final w = World();
    w.dev('a1', id: 'Y1');
    final ph = w.phone('p', [const Rec('Y1', 1)]);
    final c = ph.core;
    c.startup(0, Page.home);
    untilEnd(w, c);
    c.setPage(w.now, Page.other);
    c.background(w.now + s);
    c.foreground(w.now + 2 * s);
    final n = c.roundsRun;
    c.setPage(w.now + 3 * s, Page.home); // well under 60 s after the last full round
    expect(c.roundsRun, n + 1, reason: c.log.join('\n'));
  });

  test('R12: 登入被拒 never covers 身分不符', () {
    final w = World();
    w.dev('aX', id: 'Y1').force = Res.certRejected; // a clone, scanned first
    w.dev('a1', id: 'Y1').force = Res.refusedForbidden;
    final ph = w.phone('p', [const Rec('Y1', 1)]);
    final c = ph.core;
    c.startup(0, Page.home);
    w.run(4 * min);
    expect(c.shownWhy('Y1'), Why.identity, reason: c.log.join('\n'));
  });

  test('R29: among targets still looking, one not read in this run goes before one read before', () {
    final c = NodeLinkCore([const Rec('Y1', 1), const Rec('Y2', 2)]);
    c.startup(0, Page.home);
    c.onScan(3 * s, 'a1');
    final first = c.next(3 * s)!;
    expect(first.id, 'Y2', reason: 'newer record file first');
    c.result(14 * s, first, const Outcome(Res.body, 'green')); // a1 is Y2
    c.tick(31 * s); // Y1 has nothing left to try: the round ends
    expect(c.roundActive, isFalse);
    c.refresh(40 * s); // a new full round
    c.isY.clear(); // Y2's address changed: both are looking now, on one unknown address
    c.onScan(43 * s, 'z9');
    final a = c.next(43 * s)!;
    expect(a.id, 'Y1', reason: 'not read in this run goes before read (Y2 was read)\n${c.log.join('\n')}');
  });

  test('6 s gap: an address is not tried again within 6 s of its last attempt ending', () {
    final c = NodeLinkCore([const Rec('Y1', 1), const Rec('Y2', 2)]);
    c.startup(0, Page.home);
    c.onScan(3 * s, 'z1');
    final a = c.next(3 * s)!;
    c.result(8 * s, a, const Outcome(Res.undecryptable)); // z1 is not that record; the other record may try z1
    expect(c.next(8 * s), isNull, reason: 'z1 is the only address and it is inside its 6 s gap');
    expect(c.next(13 * s), isNull);
    expect(c.next(14 * s)?.addr, 'z1');
  });

  test('a loginFor result that arrives after its lease was taken back writes nothing', () {
    final c = NodeLinkCore([const Rec('Y1', 1)]);
    c.startup(0, Page.other);
    c.acquireLease(0);
    final l = c.loginFor(0, 'Y1');
    l.onScan(3 * s, 'a1');
    final a = l.next(3 * s)!;
    c.releaseLease(10 * s); // the lease was taken back (§4.4 420 s) before the answer
    l.result(14 * s, a, const Outcome(Res.body, 'green'));
    expect(c.isY['a1'], isNull);
    expect(l.done, isFalse);
  });

  test('R36 / X20: while a lease is held no event starts a round', () {
    final w = World();
    w.dev('a1', id: 'Y1');
    final ph = w.phone('p', [const Rec('Y1', 1)]);
    final c = ph.core;
    c.startup(0, Page.home);
    untilEnd(w, c);
    c.acquireLease(w.now);
    final n = c.roundsRun;
    c.setPage(w.now, Page.other);
    c.setPage(w.now, Page.home);
    c.background(w.now);
    c.foreground(w.now);
    c.refresh(w.now);
    c.setRadio(w.now, bluetooth: false);
    c.setRadio(w.now, bluetooth: true);
    w.run(w.now + 5 * min);
    expect(c.roundsRun, n, reason: c.log.join('\n'));
  });

  test('R50 / X7: Bluetooth off cancels the round in progress', () {
    final w = World();
    w.dev('a1', id: 'Y1');
    final ph = w.phone('p', [const Rec('Y1', 1)]);
    final c = ph.core;
    c.startup(0, Page.home);
    w.run(2 * s);
    expect(c.roundActive, isTrue);
    c.setRadio(w.now, bluetooth: false);
    expect(c.roundActive, isFalse);
  });

  test('T-L13(a) sharpened: another phone holds the node at every round start and it re-advertises 8 s later -> '
      'never 沒找到', () {
    final w = World();
    final d = w.dev('a1', id: 'Y1')..readvertise = 8000;
    final ph = w.phone('p', [const Rec('Y1', 1)]);
    final c = ph.core;
    c.startup(0, Page.home);
    untilEnd(w, c);
    for (var k = 0; k < 8; k++) {
      final due = c.fullDue!;
      w.run(due - s);
      d
        ..busyUntil = due + 2 * s
        ..quietUntil = due + 10 * s;
      untilEnd(w, c);
    }
    expect(c.log.where((l) => l.contains(' end ') && l.contains('notFound')), isEmpty, reason: c.log.join('\n'));
    expect((ph.reads['Y1'] ?? []).length, greaterThanOrEqualTo(8));
  });
}
