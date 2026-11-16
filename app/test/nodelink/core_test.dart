// #329 design §4.3 / §9.1: the NodeLink scheduler against a simulated BLE world (virtual time).
// Each test names the design item it locks; the negative control for each is run by mutating core.dart (see the PR).
import 'package:batman_app/src/nodelink/core.dart';
import 'package:flutter_test/flutter_test.dart';

import 'sim.dart';

const s = 1000;
const min = 60 * s;

void main() {
  test('T-L11(a): two own nodes, no memo, scan order opposite to record order -> both read in round 1, 3 handshakes',
      () {
    final w = World();
    final d2 = w.dev('a1', id: 'Y2'); // scanned first, opens Y2
    final d1 = w.dev('a2', id: 'Y1');
    final ph = w.phone('p', [const Rec('Y1', 2), const Rec('Y2', 1)]); // Y1 newer -> tried first
    ph.core.startup(0, Page.home);
    w.run(60 * s);
    final c = ph.core;
    expect(c.states['Y1']!.kind, Kind.read, reason: c.log.join('\n'));
    expect(c.states['Y2']!.kind, Kind.read, reason: c.log.join('\n'));
    expect(ph.reads['Y1']!.first < 60 * s && ph.reads['Y2']!.first < 60 * s, isTrue);
    expect(d1.handshakes + d2.handshakes, 3, reason: c.log.join('\n'));
  });

  test('T-L11(h): cold start, 12 records (10 stale, older files) + 2 nodes -> both read in round 1, 3 handshakes',
      () {
    final w = World();
    final d1 = w.dev('a1', id: 'Y1');
    final d2 = w.dev('a2', id: 'Y2');
    final ph = w.phone('p', [
      for (var i = 0; i < 10; i++) Rec('S$i', 100 + i), // stale: listed first, older files
      const Rec('Y1', 1000),
      const Rec('Y2', 1001),
    ]);
    ph.core.startup(0, Page.home);
    w.run(90 * s);
    final c = ph.core;
    expect(ph.reads['Y1'], isNotNull, reason: c.log.join('\n'));
    expect(ph.reads['Y2'], isNotNull, reason: c.log.join('\n'));
    expect(d1.handshakes + d2.handshakes, 3, reason: c.log.join('\n'));
  });

  test('T-L2: a node that does not advertise -> early re-read of it only, then 找不到; it comes back -> read', () {
    final w = World();
    w.dev('a1', id: 'Y1');
    final d2 = w.dev('a2', id: 'Y2')..on = false;
    final ph = w.phone('p', [const Rec('Y1', 1), const Rec('Y2', 2)]);
    ph.core.startup(0, Page.home);
    w.run(45 * s);
    final c = ph.core;
    expect(c.states['Y2']!.kind, isNot(Kind.unreachable), reason: 'one 沒找到 is not 連不到\n${c.log.join('\n')}');
    w.run(150 * s);
    expect(c.states['Y2']!.why, Why.notFound, reason: c.log.join('\n'));
    expect(c.log.where((l) => l.contains('early [Y2]')).length, 1, reason: c.log.join('\n'));
    d2.on = true;
    w.run(400 * s);
    expect(c.states['Y2']!.kind, Kind.read, reason: c.log.join('\n'));
  });

  test(
      'T-L2(e) / round-12 M1: Y1 known, Y2 off, 10 stale records, 12 foreign undecryptable addresses -> '
      'Y1 never goes stale (gap <= 300 s), the first 4 full rounds run to the 90 s cap', () {
    final w = World();
    w.dev('a1', id: 'Y1');
    w.dev('a2', id: 'Y2').on = false;
    for (var i = 0; i < 12; i++) {
      w.dev('f$i', mode: Mode.foreignUndecryptable);
    }
    final ph = w.phone('p', [
      for (var i = 0; i < 10; i++) Rec('S$i', 100 + i),
      const Rec('Y1', 1000),
      const Rec('Y2', 999),
    ]);
    final c = ph.core;
    c.startup(0, Page.home);
    w.run(10 * min);
    final reads = ph.reads['Y1'] ?? [];
    expect(reads, isNotEmpty, reason: c.log.join('\n'));
    expect(maxGap(reads, until: 10 * min), lessThanOrEqualTo(300 * s), reason: c.log.join('\n'));
    // the precondition of the control: rounds really are long
    final ends = c.log.where((l) => l.contains(' end ')).toList();
    expect(ends.length, greaterThanOrEqualTo(4));
  });

  test(
      'round-12 M1 (attack): Y1 known, Y2 never read and off, 12 silent addresses -> '
      'Y1 is read within 40 s of every full round start once it is known', () {
    final w = World();
    w.dev('a1', id: 'Y1');
    w.dev('a2', id: 'Y2').on = false;
    final xs = [for (var i = 0; i < 12; i++) w.dev('x$i', mode: Mode.foreignSilent)..on = false];
    w.at(2 * min, () {
      for (final x in xs) {
        x.on = true;
      }
    });
    final ph = w.phone('p', [const Rec('Y1', 1), const Rec('Y2', 2)]);
    final c = ph.core;
    c.startup(0, Page.home);
    w.run(10 * min);
    final fullStarts = <int>[];
    for (final l in c.log.where((l) => l.contains(' full '))) {
      fullStarts.add((double.parse(l.split(' ').first) * 1000).round());
    }
    final reads = ph.reads['Y1'] ?? [];
    for (final st in fullStarts.where((t) => t >= 2 * min && t < 9 * min)) {
      expect(reads.any((r) => r >= st && r <= st + 40 * s), isTrue,
          reason: 'round at ${st ~/ 1000} s: Y1 not read within 40 s\n${c.log.join('\n')}');
    }
    expect(maxGap(reads, until: 10 * min), lessThanOrEqualTo(300 * s));
  });

  test('turns: cold start, Y2 off, 12 silent addresses scanned first -> Y1 still read within two full rounds', () {
    final w = World();
    for (var i = 0; i < 12; i++) {
      w.dev('x$i', mode: Mode.foreignSilent);
    }
    w.dev('a1', id: 'Y1');
    w.dev('a2', id: 'Y2').on = false;
    final ph = w.phone('p', [const Rec('Y1', 1), const Rec('Y2', 2)]); // Y2 newer: first in its queue
    final c = ph.core;
    c.startup(0, Page.home);
    w.run(150 * s + 90 * s);
    expect(ph.reads['Y1'], isNotNull, reason: c.log.join('\n'));
  });

  test('X28: an early re-read never delays the full round: each full round starts 60 s after the last one ended', () {
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
    int t(String l) => (double.parse(l.trim().split(' ').first) * 1000).round();
    int? lastFullEnd;
    String? open;
    var checked = 0;
    for (final l in c.log) {
      final m = RegExp(r'round (\d+) (full|early|end|cancelled)').firstMatch(l);
      if (m == null) continue;
      if (m.group(2) == 'full') {
        if (lastFullEnd != null) {
          expect(t(l) - lastFullEnd, 60 * s, reason: c.log.join('\n'));
          checked++;
        }
        open = m.group(1);
      } else if (m.group(2) == 'end' && m.group(1) == open) {
        lastFullEnd = t(l);
      }
    }
    expect(c.log.any((l) => l.contains(' early ')), isTrue, reason: 'the control needs early re-reads');
    expect(checked, greaterThanOrEqualTo(3));
  });

  test('wait for the known address: Y1 known but busy at the round start, a foreign node near -> no handshake to it',
      () {
    final w = World();
    final d = w.dev('a1', id: 'Y1');
    final f = w.dev('f0', mode: Mode.foreignUndecryptable);
    final ph = w.phone('p', [const Rec('Y1', 1)]);
    final c = ph.core;
    c.startup(0, Page.home);
    w.run(2 * min);
    expect(c.isY['a1'], 'Y1');
    final before = f.handshakes;
    // another phone holds Y1 for 20 s across the next full round start
    final next = c.fullDue!;
    w.at(next - 2 * s, () {
      d.busyUntil = next + 18 * s;
      d.quietUntil = next + 23 * s;
    });
    w.run(next + 60 * s);
    expect(f.handshakes, before, reason: c.log.join('\n'));
    expect((ph.reads['Y1'] ?? []).any((r) => r > next), isTrue, reason: c.log.join('\n'));
  });

  test('round-12 A-M2: a status error then a body in the same round -> read in that round, never gray', () {
    final w = World();
    final d = w.dev('a1', id: 'Y1')..statusScript = [Res.errorCode];
    final ph = w.phone('p', [const Rec('Y1', 1)]);
    final c = ph.core;
    c.startup(0, Page.home);
    w.run(60 * s);
    expect(c.states['Y1']!.kind, Kind.read, reason: c.log.join('\n'));
    expect(c.states['Y1']!.view, 'green');
    expect(d.logins, 2);
  });

  test("T-H2(e): an error code on every read -> gray 2' after two full rounds, not after one", () {
    final w = World();
    final d = w.dev('a1', id: 'Y1')..statusScript = List.filled(100, Res.errorCode, growable: true);
    final ph = w.phone('p', [const Rec('Y1', 1)]);
    final c = ph.core;
    c.startup(0, Page.home);
    w.run(40 * s); // end of round 1
    expect(c.states['Y1']!.kind, Kind.unread, reason: c.log.join('\n'));
    expect(c.states['Y1']!.responded, isTrue);
    w.run(5 * min);
    expect(c.states['Y1']!.kind, Kind.read, reason: c.log.join('\n'));
    expect(c.states['Y1']!.view, "2'");
    expect(d.logins, greaterThanOrEqualTo(4));
  });

  test("T-H2(f): gray 2' -> background -> foreground -> gray again after the next rounds, not stuck unknown", () {
    final w = World();
    w.dev('a1', id: 'Y1').statusScript = List.filled(100, Res.errorCode, growable: true);
    final ph = w.phone('p', [const Rec('Y1', 1)]);
    final c = ph.core;
    c.startup(0, Page.home);
    w.run(5 * min);
    expect(c.fresh('Y1', w.now), isTrue);
    w.at(w.now + 1, () => c.background(w.now));
    w.at(w.now + 30 * s, () => c.foreground(w.now));
    w.run(w.now + 31 * s);
    expect(c.fresh('Y1', w.now), isFalse);
    w.run(w.now + 3 * min);
    expect(c.fresh('Y1', w.now), isTrue, reason: c.log.join('\n'));
    expect(c.states['Y1']!.view, "2'");
  });

  test('T-L3: background marks every read node not fresh; foreground reads at once', () {
    final w = World();
    w.dev('a1', id: 'Y1');
    w.dev('a2', id: 'Y2');
    final ph = w.phone('p', [const Rec('Y1', 1), const Rec('Y2', 2)]);
    final c = ph.core;
    c.startup(0, Page.home);
    w.run(50 * s);
    expect(c.fresh('Y1', w.now) && c.fresh('Y2', w.now), isTrue);
    final bg = w.now + 1;
    w.at(bg, () => c.background(w.now));
    w.at(bg + 5 * s, () => c.foreground(w.now)); // monotonic clock barely moved: the screen was off
    w.run(bg + 5 * s);
    expect(c.fresh('Y1', w.now) || c.fresh('Y2', w.now), isFalse);
    expect(c.roundActive, isTrue, reason: 'a round starts at once on return');
    w.run(bg + 60 * s);
    expect(c.fresh('Y1', w.now) && c.fresh('Y2', w.now), isTrue, reason: c.log.join('\n'));
  });

  for (final n in [7, 8, 12]) {
    test('T-L21: $n own nodes + 1 foreign address -> no early re-read, each read at most 300 s apart', () {
      final w = World();
      for (var i = 0; i < n; i++) {
        w.dev('a$i', id: 'Y$i');
      }
      w.dev('f0', mode: Mode.foreignUndecryptable);
      final ph = w.phone('p', [for (var i = 0; i < n; i++) Rec('Y$i', i)]);
      final c = ph.core;
      c.startup(0, Page.home);
      // settle: every node read once (a cold start must try records against addresses: about n^2/2 handshakes)
      while (w.now < 30 * min && ph.reads.length < n) {
        w.run(w.now + 10 * s);
      }
      expect(ph.reads.length, n, reason: c.log.join('\n'));
      // ignore: avoid_print
      print('$n nodes: all read after ${w.now ~/ 1000} s');
      final from = w.now;
      final earlyBefore = c.log.where((l) => l.contains(' early ')).length;
      w.run(from + 10 * min);
      for (var i = 0; i < n; i++) {
        expect(maxGap(ph.reads['Y$i'] ?? [], from: from, until: from + 10 * min), lessThanOrEqualTo(300 * s),
            reason: 'Y$i\n${c.log.join('\n')}');
        expect(c.states['Y$i']!.kind, isNot(Kind.unreachable));
      }
      expect(c.log.where((l) => l.contains(' early ')).length, earlyBefore, reason: c.log.join('\n'));
      // not vacuous: no round after settling concludes 沒找到 or 還沒輪到 for anyone (an early re-read would be due)
      final ends = c.log.where((l) => l.contains(' end ') && double.parse(l.trim().split(' ').first) * 1000 > from);
      expect(ends.where((l) => l.contains('notFound') || l.contains('notYet')), isEmpty, reason: c.log.join('\n'));
    });
  }

  test('T-L21(d): 12 own nodes, one changes its address -> read again within 2 cycles, never 連不到', () {
    final w = World();
    final ds = [for (var i = 0; i < 12; i++) w.dev('a$i', id: 'Y$i')];
    w.dev('f0', mode: Mode.foreignUndecryptable);
    final ph = w.phone('p', [for (var i = 0; i < 12; i++) Rec('Y$i', i)]);
    final c = ph.core;
    c.startup(0, Page.home);
    while (w.now < 30 * min && ph.reads.length < 12) {
      w.run(w.now + 10 * s);
    }
    w.run(w.now + 3 * min);
    final at = w.now;
    ds[3].addr = 'a3-new';
    w.run(at + 10 * min);
    final after = (ph.reads['Y3'] ?? []).where((r) => r > at).toList();
    expect(after, isNotEmpty, reason: c.log.join('\n'));
    expect(after.first - at, lessThanOrEqualTo(2 * 155 * s), reason: c.log.join('\n'));
    expect(c.states['Y3']!.kind, isNot(Kind.unreachable));
  });

  test('N9: claimed under a lease, released, next round: the first 4 s of 解不開 are not memoed -> read', () {
    final w = World();
    final d = w.dev('a1', id: 'Y1');
    final ph = w.phone('p', [const Rec('Y1', 1)]);
    final c = ph.core;
    c.startup(0, Page.home);
    w.at(1, () => c.acquireLease(w.now));
    w.at(20 * s, () {
      d.claimedAt = w.now + 6 * s; // the node only learns its owner after its next 4 s poll
      c.releaseLease(w.now, written: {'Y1'});
    });
    w.run(90 * s);
    expect(c.states['Y1']!.kind, Kind.read, reason: c.log.join('\n'));
    expect(c.notY['a1']?.contains('Y1') ?? false, isFalse);
  });
}
