// #329 §4.3, fourth batch: real-use scenarios written by reviewer B in code review 1 (RB-*), adopted after the fixes.
// RB-FIX-* failed on 236ea4b (each was a finding) and pass now; RB-OK-* print numbers for the design back-fill.
import 'package:batman_app/src/nodelink/core.dart';
import 'package:flutter_test/flutter_test.dart';

import 'sim.dart';

const s = 1000;
const min = 60 * s;

int t(String l) => (double.parse(l.trim().split(' ').first) * 1000).round();

// ignore: avoid_print
void say(String x) => print('[RB] $x');

/// Sample `f` every second from `from` to `to` (events are added to the world).
void every(World w, int from, int to, void Function() f) {
  for (var x = from; x <= to; x += s) {
    w.at(x, f);
  }
}

(World, Phone, List<Dev>) settled(int n, {bool foreign = false}) {
  final w = World();
  final ds = [for (var i = 0; i < n; i++) w.dev('a$i', id: 'Y$i')];
  if (foreign) w.dev('f0', mode: Mode.foreignUndecryptable);
  final ph = w.phone('p', [for (var i = 0; i < n; i++) Rec('Y$i', i)]);
  ph.core.startup(0, Page.home);
  while (w.now < 30 * min && ph.reads.length < n) {
    w.run(w.now + 10 * s);
  }
  return (w, ph, ds);
}

void main() {
  // ---------------------------------------------------------------------------------------------------------------
  test('RB-FIX-1: 12 own nodes all healthy, settled -> no round concludes 沒找到 for anyone (cut at the cap = 沒試過)', () {
    final (w, ph, _) = settled(12);
    final c = ph.core;
    final from = w.now + 3 * min;
    w.run(from + 15 * min);
    final bad = c.log.where((l) => t(l) >= from && l.contains(' end ') && l.contains('notFound')).toList();
    final cuts = c.log.where((l) => t(l) >= from && l.contains('cut at the cap')).toList();
    say(
      'RB-FIX-1 cuts=${cuts.length} rounds-with-notFound=${bad.length}\n${cuts.take(3).join('\n')}\n'
      '${bad.take(3).join('\n')}',
    );
    expect(bad, isEmpty, reason: '§4.3.4: the attempt cut at 90 s counts as not tried -> 排隊中/還沒輪到, not 沒找到');
  });

  test('RB-FIX-2: 12 own nodes settled, one goes off -> an early re-read of it (§4.3.2 T14), not only full rounds', () {
    final (w, ph, ds) = settled(12);
    final c = ph.core;
    w.run(w.now + 3 * min);
    final off = w.now;
    ds[5].on = false;
    var shownAt = -1;
    every(w, off, off + 10 * min, () {
      if (shownAt < 0 && c.states['Y5']!.why == Why.notFound) shownAt = w.now;
    });
    w.run(off + 10 * min);
    final early = c.log.where((l) => t(l) >= off && l.contains(' early ')).toList();
    say(
      'RB-FIX-2 earlyCount=${c.earlyCount} early rounds after off=${early.length}; '
      'Y5 連不到 after ${shownAt < 0 ? 'never' : '${(shownAt - off) ~/ 1000} s'}',
    );
    expect(early.any((l) => l.contains('[Y5]')), isTrue, reason: c.log.where((l) => t(l) >= off).join('\n'));
  });

  // ---------------------------------------------------------------------------------------------------------------
  test('RB-FIX-3: 身分不符 survives Bluetooth off/on (only a later read, refresh or a record write end it)', () {
    final w = World();
    w.dev('a1', id: 'Y1').force = Res.certRejected;
    final ph = w.phone('p', [const Rec('Y1', 1)]);
    final c = ph.core;
    c.startup(0, Page.home);
    w.run(20 * s);
    expect(c.shownWhy('Y1'), Why.identity);
    w.at(w.now + 1, () {
      c.setRadio(w.now, bluetooth: false);
      c.setRadio(w.now + 1, bluetooth: true);
    });
    w.run(w.now + 5 * min);
    say('RB-FIX-3 after BT off/on: kind=${c.states['Y1']!.kind} why=${c.states['Y1']!.why}');
    expect(c.shownWhy('Y1'), Why.identity, reason: c.log.join('\n'));
  });

  test('RB-FIX-3b: 身分不符 survives keys unusable -> usable (X26/X31)', () {
    final w = World();
    w.dev('a1', id: 'Y1').force = Res.certRejected;
    final ph = w.phone('p', [const Rec('Y1', 1)]);
    final c = ph.core;
    c.startup(0, Page.home);
    w.run(20 * s);
    c.setRadio(w.now, keyOk: false);
    c.setRadio(w.now, keyOk: true);
    w.run(w.now + 5 * min);
    expect(c.shownWhy('Y1'), Why.identity, reason: c.log.join('\n'));
  });

  test('RB-FIX-8: BT turned back on while another page is on top -> back home within 60 s: rows are not left as '
      '「藍牙關閉」 while Bluetooth is on', () {
    final w = World();
    w.dev('a1', id: 'Y1');
    final ph = w.phone('p', [const Rec('Y1', 1)]);
    final c = ph.core;
    c.startup(0, Page.home);
    w.run(40 * s); // round 1 ended at ~14 s
    c.setPage(w.now, Page.other); // settings page
    c.setRadio(w.now, bluetooth: false);
    c.setRadio(w.now + s, bluetooth: true);
    c.setPage(w.now + 2 * s, Page.home); // back home < 60 s after the last full round
    w.run(w.now + 3 * s);
    say(
      'RB-FIX-8 back home with BT on: Y1 = ${c.states['Y1']!.kind}/${c.states['Y1']!.why}, round active = ${c.roundActive}',
    );
    expect(c.shownWhy('Y1'), isNot(Why.bluetoothOff));
  });

  // ---------------------------------------------------------------------------------------------------------------
  test('RB-REPLAY-a: Y1 rotates its address, a silent device replays the OLD address -> is Y1 read again?', () {
    final w = World();
    final x = w.dev('zz', mode: Mode.foreignSilent)..on = false;
    final d = w.dev('a1', id: 'Y1');
    final ph = w.phone('p', [const Rec('Y1', 1)]);
    final c = ph.core;
    c.startup(0, Page.home);
    w.run(2 * min);
    expect(c.isY['a1'], 'Y1');
    final at = w.now;
    d.addr = 'a1n';
    x
      ..addr = 'a1'
      ..on = true;
    w.run(at + 15 * min);
    final after = (ph.reads['Y1'] ?? []).where((r) => r > at).toList();
    say(
      'RB-REPLAY-a reads after rotation=${after.length} state=${c.states['Y1']!.kind}/${c.states['Y1']!.why} '
      'handshakes on a1n=${d.handshakes}',
    );
    expect(after, isNotEmpty, reason: c.log.where((l) => t(l) > at).take(40).join('\n'));
  });

  test('RB-REPLAY-b: Y1 already read at its NEW address; a silent replay of the old one is scanned first', () {
    final w = World();
    final x = w.dev('zz', mode: Mode.foreignSilent)..on = false;
    final d = w.dev('a1', id: 'Y1');
    final ph = w.phone('p', [const Rec('Y1', 1)]);
    final c = ph.core;
    c.startup(0, Page.home);
    w.run(2 * min);
    d.addr = 'a1n';
    w.run(w.now + 4 * min);
    expect(c.isY['a1n'], 'Y1', reason: c.log.join('\n'));
    expect(c.isY['a1'], 'Y1'); // the old memo is still there (< 20 min)
    final at = w.now;
    x
      ..addr = 'a1'
      ..on = true;
    w.run(at + 10 * min);
    final after = (ph.reads['Y1'] ?? []).where((r) => r > at).toList();
    say('RB-REPLAY-b reads after replay=${after.length} state=${c.states['Y1']!.kind}/${c.states['Y1']!.why}');
    expect(after, isNotEmpty, reason: c.log.where((l) => t(l) > at).take(40).join('\n'));
  });

  test('RB-REPLAY-c: loginFor (flow) while a silent device replays the old 「是 Y」 address', () {
    final w = World();
    final x = w.dev('zz', mode: Mode.foreignSilent)..on = false;
    final d = w.dev('a1', id: 'Y1');
    final ph = w.phone('p', [const Rec('Y1', 1)]);
    final c = ph.core;
    c.startup(0, Page.home);
    w.run(2 * min);
    d.addr = 'a1n';
    x
      ..addr = 'a1'
      ..on = true;
    late LoginFor l;
    w.at(w.now + 1, () {
      c.acquireLease(w.now);
      l = c.loginFor(w.now, 'Y1', clearNotY: true);
      ph.login = l;
    });
    w.run(w.now + 95 * s);
    say('RB-REPLAY-c loginFor end=${l.end} handshakes=${l.handshakes}');
    expect(l.end, LoginEnd.ok, reason: c.log.join('\n'));
  });

  // ---------------------------------------------------------------------------------------------------------------
  test("RB-FIX-5: 不變, 登入被拒, 不變 -> not gray 2' (a round that is not 不變 resets the count, §4.3.4)", () {
    final c = NodeLinkCore([const Rec('Y1', 1)]);
    var now = 0;
    void errRound() {
      c.onScan(now + 3 * s, 'a1');
      var a = c.next(now + 3 * s)!;
      c.result(now + 14 * s, a, const Outcome(Res.errorCode));
      a = c.next(now + 20 * s)!;
      c.result(now + 31 * s, a, const Outcome(Res.errorCode));
      c.tick(now + 31 * s);
      expect(c.roundActive, isFalse);
    }

    c.startup(now, Page.home);
    errRound();
    expect(c.states['Y1']!.last, Concl.unchanged);
    now = c.fullDue!;
    c.tick(now);
    c.onScan(now + 3 * s, 'a1');
    final a = c.next(now + 3 * s)!;
    c.result(now + 8 * s, a, const Outcome(Res.refusedForbidden));
    c.tick(now + 8 * s);
    expect(c.states['Y1']!.last, Concl.reason);
    now = c.fullDue!;
    c.tick(now);
    errRound();
    say(
      "RB-FIX-5 after 不變/被拒/不變: kind=${c.states['Y1']!.kind} view=${c.states['Y1']!.view} same=${c.states['Y1']!.same}",
    );
    expect(c.states['Y1']!.view, isNot("2'"), reason: c.log.join('\n'));
  });

  // ---------------------------------------------------------------------------------------------------------------
  test('RB-FIX-6: a second foreground() without a background (first resumed) does not start a second round', () {
    final c = NodeLinkCore([const Rec('Y1', 1)]);
    c.startup(0, Page.home);
    c.onScan(3 * s, 'a1');
    final a = c.next(3 * s)!;
    c.foreground(4 * s);
    c.result(14 * s, a, const Outcome(Res.body, 'green'));
    say('RB-FIX-6 roundsRun=${c.roundsRun} Y1=${c.states['Y1']!.kind}');
    expect(c.roundsRun, 1, reason: c.log.join('\n'));
  });

  // ---------------------------------------------------------------------------------------------------------------
  test('RB-FIX-7: a record created by a claim is unknown to the core: releaseLease(written) ignores it', () {
    final c = NodeLinkCore([const Rec('Y1', 1)]);
    c.startup(0, Page.home);
    c.acquireLease(1000);
    c.releaseLease(2000, written: {'Y2'}, recs: const [Rec('Y1', 1), Rec('Y2', 2)]);
    c.tick(8000);
    say('RB-FIX-7 home targets after the claim: ${c.states.keys.toList()} / ${c.log.last}');
    expect(c.states.containsKey('Y2'), isTrue);
  });

  for (final pre in [false, true]) {
    for (final nf in [0, 3, 6, 8]) {
      test(
        'RB-CLAIM-$nf-pre=$pre: claim a new node (address changes to an RPA after the claim), at once loginFor to make the '
        'network; Y1 known nearby, $nf foreign nodes',
        () {
          final w = World();
          for (var i = 0; i < nf; i++) {
            w.dev('f$i', mode: Mode.foreignUndecryptable);
          }
          w.dev('a1', id: 'Y1');
          final n2 = w.dev('u2', id: 'Y2');
          final ph = w.phone('p', [const Rec('Y1', 1), if (pre) const Rec('Y2', 2)]);
          final c = ph.core;
          n2.on = false;
          c.startup(0, Page.home);
          w.run(3 * min);
          late LoginFor l;
          final at = w.now + 1;
          w.at(at, () {
            n2.on = true;
            c.acquireLease(w.now); // claim flow (raw lease; it writes node/Y2)
          });
          w.at(at + 12 * s, () {
            n2.claimedAt = w.now; // the node learns its owner at its next 4 s poll
            n2.addr = 'r2'; // claimed nodes advertise an RPA (N7)
            c.releaseLease(w.now, written: {'Y2'}, recs: const [Rec('Y1', 1), Rec('Y2', 2)]);
            c.acquireLease(w.now); // the make-network flow
            l = c.loginFor(w.now, 'Y2');
            ph.login = l;
          });
          w.run(at + 12 * s + 95 * s);
          final took = l.done ? 'done' : 'running';
          say('RB-CLAIM-$nf-pre=$pre loginFor end=${l.end} ($took) handshakes=${l.handshakes}');
          expect(l.end, LoginEnd.ok, reason: c.log.where((x) => t(x) >= at).join('\n'));
        },
      );
    }
  }

  for (final nf in [8, 10, 12]) {
    test('RB-CLAIM-RETRY-$nf: claim, loginFor fails, the user presses 再試一次 (clears 不是 Y) up to 3 times', () {
      final w = World();
      for (var i = 0; i < nf; i++) {
        w.dev('f$i', mode: Mode.foreignUndecryptable);
      }
      w.dev('a1', id: 'Y1');
      final n2 = w.dev('u2', id: 'Y2')..on = false;
      final ph = w.phone('p', [const Rec('Y1', 1), const Rec('Y2', 2)]);
      final c = ph.core;
      c.startup(0, Page.home);
      w.run(3 * min);
      final at = w.now + 1;
      w.at(at, () {
        n2.on = true;
        c.acquireLease(w.now);
      });
      final ends = <String>[];
      w.at(at + 12 * s, () {
        n2.claimedAt = w.now;
        n2.addr = 'r2';
        c.releaseLease(w.now, written: {'Y2'}, recs: const [Rec('Y1', 1), Rec('Y2', 2)]);
        c.acquireLease(w.now);
        ph.login = c.loginFor(w.now, 'Y2');
      });
      w.run(at + 12 * s + 70 * s);
      for (var k = 0; k < 3 && ph.login!.end != LoginEnd.ok; k++) {
        ends.add('${ph.login!.end}@${w.now ~/ 1000}');
        ph.login = c.loginFor(w.now + 3 * s, 'Y2', clearNotY: true);
        w.run(w.now + 3 * s + 70 * s);
      }
      ends.add('${ph.login!.end}@${w.now ~/ 1000}');
      say('RB-CLAIM-RETRY-$nf ends: $ends');
      // accepted limit (to back-fill in the design): right after a claim the new node cannot be told from the others
      // (all answer 解不開 inside the N9 window), so with more than 8 others the first minute may not reach it;
      // one 再試一次 does
      if (nf <= 8) expect(ends.first, startsWith('LoginEnd.ok'));
      expect(ends.length, lessThanOrEqualTo(2), reason: '$ends');
      expect(ends.last, startsWith('LoginEnd.ok'));
    });
  }

  // ---------------------------------------------------------------------------------------------------------------
  for (final off in [0, 10, 20, 30, 40, 50]) {
    test('RB-T-L16-monitored: two phones own one node, offset $off s -> 連不到 never shown (sampled every 1 s)', () {
      final w = World();
      w.dev('a1', id: 'Y1');
      final p1 = w.phone('p1', [const Rec('Y1', 1)]);
      final p2 = w.phone('p2', [const Rec('Y1', 1)]);
      p1.core.startup(0, Page.home);
      w.at(off * s, () => p2.core.startup(w.now, Page.home));
      var shown = 0, notFoundRounds = 0;
      every(w, 0, 21 * min, () {
        for (final ph in [p1, p2]) {
          if (ph.core.states['Y1']!.kind == Kind.unreachable) shown++;
        }
      });
      w.run(21 * min);
      for (final ph in [p1, p2]) {
        notFoundRounds += ph.core.log.where((l) => l.contains(' end ') && l.contains('notFound')).length;
      }
      say(
        'RB-T-L16 off=$off noResponse=${[p1, p2].map((p) => p.core.log.where((l) => l.contains("noResponse")).length).toList()} notFound rounds=$notFoundRounds 連不到 seconds=$shown',
      );
      expect(shown, 0);
    });
  }

  // ---------------------------------------------------------------------------------------------------------------
  for (final n in [2, 7, 8]) {
    test('RB-OK-cold-$n: $n own nodes + 1 foreign, cold start -> time until all read; then rotation of one', () {
      final (w, ph, ds) = settled(n, foreign: true);
      final c = ph.core;
      final all = w.now;
      w.run(w.now + 3 * min);
      final at = w.now;
      ds[n - 1].addr = 'rot';
      var unk = 0;
      every(w, at, at + 10 * min, () {
        for (var i = 0; i < n; i++) {
          if (!c.fresh('Y$i', w.now)) unk++;
        }
      });
      w.run(at + 10 * min);
      final after = (ph.reads['Y${n - 1}'] ?? []).where((r) => r > at).toList();
      say(
        'RB-OK-cold-$n all read after ~${all ~/ 1000} s; rotated node read again after '
        '${after.isEmpty ? 'never' : '${(after.first - at) ~/ 1000} s'}; not-fresh node-seconds in 10 min=$unk',
      );
      expect(after, isNotEmpty);
    });
  }

  test('RB-OK-cold-silent: 2 own nodes + 12 silent addresses scanned first, cold start -> time until both read', () {
    final w = World();
    for (var i = 0; i < 12; i++) {
      w.dev('x$i', mode: Mode.foreignSilent);
    }
    w.dev('a1', id: 'Y1');
    w.dev('a2', id: 'Y2');
    final ph = w.phone('p', [const Rec('Y1', 1), const Rec('Y2', 2)]);
    ph.core.startup(0, Page.home);
    while (w.now < 20 * min && ph.reads.length < 2) {
      w.run(w.now + 5 * s);
    }
    say('RB-OK-cold-silent both read after ${w.now ~/ 1000} s (reads=${ph.reads.keys})');
    expect(ph.reads.length, 2);
  });

  test('RB-OK-e: Y1 read, Y2 off, 10 stale records, 12 foreign -> when does Y2 show 連不到', () {
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
    var y2 = -1, s0 = -1;
    every(w, 0, 30 * min, () {
      if (y2 < 0 && c.states['Y2']!.why == Why.notFound) y2 = w.now;
      if (s0 < 0 && c.states['S0']!.why == Why.notFound) s0 = w.now;
    });
    w.run(30 * min);
    say(
      'RB-OK-e Y2 連不到 at ${y2 < 0 ? 'never' : '${y2 ~/ 1000} s'}; S0 at ${s0 < 0 ? 'never' : '${s0 ~/ 1000} s'}; '
      'Y1 max gap ${maxGap(ph.reads['Y1'] ?? [], until: 30 * min) ~/ 1000} s; handshakes per foreign = '
      '${w.devs.where((d) => d.mode != Mode.own).map((d) => d.handshakes).toList()}',
    );
    expect(y2, greaterThan(0));
  });
}
