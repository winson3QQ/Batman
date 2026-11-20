// #329 rotating identifier (329-rotating-id-plan.md v6.1 §8, S1–S6): what a scan result's hint does to the order of
// attempts, in a round and in LoginFor. The hint never sets a memo; a login does.
import 'package:batman_app/src/nodelink/core.dart';
import 'package:flutter_test/flutter_test.dart';

import 'sim.dart';

const s = 1000;

/// Y1 with a 「是 Y1」 memo on the address A, which is not in the air any more (the node's address changed).
NodeLinkCore memoOnOldAddress({List<Rec> recs = const [Rec('Y1', 1)]}) => NodeLinkCore(recs)..isY['A'] = 'Y1';

void main() {
  group('a round', () {
    test('S1: a 「像 Y」 address is tried at once, before the 30 s window, and before an unknown address seen first',
        () {
      final w = World();
      final other = w.dev('C', mode: Mode.foreignUndecryptable); // no hint, scanned first
      final b = w.dev('B', id: 'Y1')..hint = 'Y1';
      final ph = w.phone('p', [const Rec('Y1', 1)]);
      final c = ph.core..isY['A'] = 'Y1';
      c.startup(0, Page.home);
      w.run(20 * s);
      // both are scanned at 3 s (World.see)
      expect(b.handshakeTimes.first, lessThan(4 * s), reason: c.log.join('\n'));
      expect(other.handshakes, 0, reason: 'nothing on C: Y1 was read on B\n${c.log.join('\n')}');
      expect(ph.reads['Y1'], isNotEmpty);
      expect(c.isY['B'], 'Y1');
    });

    test('S1: without a hint the same world waits for the window (the behaviour before the identifier)', () {
      final w = World();
      w.dev('C', mode: Mode.foreignUndecryptable);
      final b = w.dev('B', id: 'Y1');
      final ph = w.phone('p', [const Rec('Y1', 1)]);
      ph.core
        ..isY['A'] = 'Y1'
        ..startup(0, Page.home);
      w.run(29 * s);
      expect(b.handshakes, 0);
      w.run(60 * s);
      expect(ph.reads['Y1'], isNotEmpty);
    });

    test('S2: a replayed identifier costs one attempt; the address becomes 「不是 Y」, never 「是 Y」', () {
      final w = World();
      final fake = w.dev('C', mode: Mode.foreignUndecryptable)..hint = 'Y1'; // replays Y1's advert, scanned first
      final real = w.dev('B', id: 'Y1')..hint = 'Y1';
      final ph = w.phone('p', [const Rec('Y1', 1)]);
      final c = ph.core..isY['A'] = 'Y1';
      c.startup(0, Page.home);
      for (var t = 500; t <= 40 * s; t += 500) {
        w.run(t);
        expect(c.isY['C'], isNull, reason: 'a hint is never a memo (t=$t)\n${c.log.join('\n')}');
      }
      expect(fake.handshakeTimes.first, lessThan(4 * s), reason: 'C was tried first');
      expect(fake.handshakes, 1);
      expect(c.notY['C'], contains('Y1'), reason: c.log.join('\n'));
      expect(real.handshakeTimes.first, lessThan(10 * s), reason: 'B right after C answered 解不開, not at 30 s');
      expect(ph.reads['Y1'], isNotEmpty);
      expect(c.isY['B'], 'Y1');
    });

    test('S3: at most two addresses per target are tried as 「像 Y」 in a round; a third is an unknown address', () {
      final c = memoOnOldAddress();
      c.startup(0, Page.home);
      for (final a in ['H1', 'H2', 'H3']) {
        c.onScan(3 * s, a, hint: 'Y1');
      }
      final tried = <String>[];
      Attempt take(int t) {
        final a = c.next(t)!;
        tried.add(a.addr);
        return a;
      }

      c.result(5 * s, take(3 * s), const Outcome(Res.noResponse));
      c.result(7 * s, take(5 * s), const Outcome(Res.noResponse));
      expect(tried, ['H1', 'H2']);
      // H1 and H2 are inside their 6 s gap; H3 is free, carries the hint, and is not tried
      expect(c.next(7 * s), isNull, reason: 'the third 「像 Y1」 address waits like an unknown one\n${c.log.join('\n')}');
      c.result(13 * s, take(11 * s), const Outcome(Res.noResponse));
      c.result(15 * s, take(13 * s), const Outcome(Res.noResponse));
      expect(tried, ['H1', 'H2', 'H1', 'H2'], reason: 'four attempts on 「像 Y1」 addresses, no more');
      for (var t = 15 * s; t < 30 * s; t += s) {
        expect(c.next(t), isNull, reason: 't=$t');
      }
      // the window is over: H3 is tried as any unknown address is
      expect(take(30 * s).addr, 'H3');
      expect(c.isY.values.where((v) => v == 'Y1').length, 1, reason: 'only the old memo: no hint became one');
    });

    test('S5: a silent 「像 Y」 address is tried once more after the 6 s gap, then no more in this round', () {
      final c = memoOnOldAddress();
      c.startup(0, Page.home);
      c.onScan(3 * s, 'B', hint: 'Y1');
      final a1 = c.next(3 * s)!;
      expect(a1.addr, 'B');
      c.result(5 * s, a1, const Outcome(Res.noResponse));
      expect(c.next(5 * s), isNull);
      expect(c.next(11 * s - 1), isNull, reason: 'inside the 6 s gap');
      final a2 = c.next(11 * s);
      expect(a2?.addr, 'B', reason: 'the second attempt\n${c.log.join('\n')}');
      c.result(13 * s, a2!, const Outcome(Res.noResponse));
      for (final t in [19 * s, 25 * s, 30 * s, 40 * s]) {
        expect(c.next(t), isNull, reason: 'two silences: done with B for this round (t=$t)');
      }
      expect(c.isY['B'], isNull);
    });

    // code review A M-4: after the cap the look-around goes on with the other addresses, and Y's conclusion is the one
    // of the same world without hints
    Kind? roundEnd(bool hinted, List<String> tried) {
      final c = memoOnOldAddress();
      c.startup(0, Page.home);
      c.onScan(3 * s, 'B', hint: hinted ? 'Y1' : null);
      c.onScan(3 * s, 'C'); // no hint
      for (var t = 3 * s; t <= 120 * s; t += 500) {
        final a = c.next(t);
        if (a != null) {
          tried.add('${a.addr}@${t ~/ s}');
          c.result(t + 2 * s, a, const Outcome(Res.noResponse));
        }
      }
      return c.states['Y1']?.kind;
    }

    test('S5: after two silences on the 「像 Y」 address, the unhinted one is tried after the window; Y ends as without hints',
        () {
      final hinted = <String>[], plain = <String>[];
      final k1 = roundEnd(true, hinted), k0 = roundEnd(false, plain);
      expect(hinted, ['B@3', 'B@11', 'C@30'], reason: 'B twice at once, then C when the window opens, no third B');
      expect(plain.toSet(), {'B@30', 'C@30'}, reason: 'the same world without hints: both after the window');
      expect(k1, k0, reason: "Y's conclusion does not depend on the hint");
      expect(k1, isNotNull);
    });

    test('S6: a memo wins over the hint: an address that 「是 Z」 or 「不是 Y」 is no 「像 Y」 candidate', () {
      // B is known to be Y2
      var c = NodeLinkCore([const Rec('Y1', 1), const Rec('Y2', 2)])..isY['B'] = 'Y2';
      c.startup(0, Page.node, node: 'Y1');
      c.onScan(3 * s, 'B', hint: 'Y1');
      expect(c.next(3 * s), isNull, reason: c.log.join('\n'));
      expect(c.next(30 * s), isNull);
      expect(c.isY['B'], 'Y2');
      // B answered 解不開 for Y1 before
      c = NodeLinkCore([const Rec('Y1', 1)])..notY['B'] = {'Y1'};
      c.startup(0, Page.home);
      c.onScan(3 * s, 'B', hint: 'Y1');
      expect(c.next(3 * s), isNull, reason: c.log.join('\n'));
      expect(c.next(30 * s), isNull);
    });

    test('onScan: true for a new address and for a changed hint only; one log line per address, however it flaps', () {
      final c = NodeLinkCore([const Rec('Y1', 1)]);
      c.startup(0, Page.home);
      expect(c.onScan(1 * s, 'B'), isTrue);
      expect(c.onScan(2 * s, 'B'), isFalse);
      expect(c.onScan(3 * s, 'B', hint: 'Y1'), isTrue);
      expect(c.onScan(4 * s, 'B', hint: 'Y1'), isFalse);
      expect(c.onScan(5 * s, 'B'), isTrue, reason: 'the last result counts: no hint now');
      for (var t = 0; t < 50; t++) {
        c.onScan(5 * s, 'B', hint: t.isEven ? 'Y1' : null);
      }
      expect(c.log.where((l) => l.contains('B like')).map((l) => l.split('B like ').last), ['Y1']);
      // a hint for a node this round does not look for changes nothing
      c.onScan(6 * s, 'D', hint: 'Y9');
      expect(c.next(6 * s)?.addr, 'B', reason: 'scan order, as without hints');
    });
  });

  group('LoginFor', () {
    LoginFor login(NodeLinkCore c) {
      c.startup(0, Page.other);
      c.acquireLease(0);
      return c.loginFor(0, 'Y1');
    }

    test('S1L: a 「像 Y」 address is tried at once, before the 30 s window and before an unknown address', () {
      final w = World();
      final other = w.dev('C', mode: Mode.foreignUndecryptable);
      final b = w.dev('B', id: 'Y1')..hint = 'Y1';
      final ph = w.phone('p', [const Rec('Y1', 1)]);
      final c = ph.core..isY['A'] = 'Y1';
      final l = ph.login = login(c);
      w.run(20 * s);
      expect(b.handshakeTimes.first, lessThan(4 * s), reason: c.log.join('\n'));
      expect(other.handshakes, 0);
      expect(l.end, LoginEnd.ok);
      expect(c.isY['B'], 'Y1');
    });

    test('S1L: without a hint it waits for the window', () {
      final w = World();
      w.dev('C', mode: Mode.foreignUndecryptable);
      final b = w.dev('B', id: 'Y1');
      final ph = w.phone('p', [const Rec('Y1', 1)]);
      final c = ph.core..isY['A'] = 'Y1';
      ph.login = login(c);
      w.run(29 * s);
      expect(b.handshakes, 0);
    });

    test('S2L: a replayed identifier becomes 「不是 Y」; the real node is logged in next', () {
      final c = memoOnOldAddress();
      final l = login(c);
      l.onScan(3 * s, 'C', hint: 'Y1');
      l.onScan(3 * s, 'B', hint: 'Y1');
      final a = l.next(3 * s)!;
      expect(a.addr, 'C');
      l.result(20 * s, a, const Outcome(Res.undecryptable)); // after the 10 s N9 window of a fresh record
      expect(c.isY['C'], isNull);
      expect(c.notY['C'], {'Y1'});
      final b = l.next(20 * s)!;
      expect(b.addr, 'B');
      l.result(22 * s, b, const Outcome(Res.body));
      expect((l.end, c.isY['B']), (LoginEnd.ok, 'Y1'));
    });

    test('S3L: at most two addresses are tried as 「像 Y」', () {
      final c = memoOnOldAddress();
      final l = login(c);
      for (final a in ['H1', 'H2', 'H3']) {
        l.onScan(3 * s, a, hint: 'Y1');
      }
      final a1 = l.next(3 * s)!;
      l.result(5 * s, a1, const Outcome(Res.noResponse));
      final a2 = l.next(5 * s)!;
      l.result(7 * s, a2, const Outcome(Res.noResponse));
      expect([a1.addr, a2.addr], ['H1', 'H2']);
      expect(l.next(7 * s), isNull, reason: 'H3 is free and carries the hint, but is the third');
      expect(l.next(30 * s)?.addr, isNot('H3'), reason: 'H1 / H2 still go first');
    });

    test('S5L: after two silences a 「像 Y」 address is not preferred any more', () {
      final c = NodeLinkCore([const Rec('Y1', 1)]);
      final l = login(c);
      l.onScan(3 * s, 'U'); // an unknown address, seen first
      l.onScan(3 * s, 'B', hint: 'Y1');
      final b1 = l.next(3 * s)!;
      expect(b1.addr, 'B', reason: 'the hint goes before scan order');
      l.result(5 * s, b1, const Outcome(Res.noResponse));
      final u = l.next(5 * s)!;
      expect(u.addr, 'U');
      l.result(7 * s, u, const Outcome(Res.noResponse));
      final b2 = l.next(11 * s)!;
      expect(b2.addr, 'B', reason: 'once more after its 6 s gap');
      l.result(13 * s, b2, const Outcome(Res.noResponse));
      // both are free at 19 s: scan order again
      expect(l.next(19 * s)?.addr, 'U', reason: c.log.join('\n'));
    });

    test('S6L: a memo wins over the hint', () {
      var c = NodeLinkCore([const Rec('Y1', 1), const Rec('Y2', 2)])..isY['B'] = 'Y2';
      var l = login(c);
      l.onScan(3 * s, 'B', hint: 'Y1');
      expect(l.next(3 * s), isNull);
      expect(l.next(30 * s), isNull);
      c = NodeLinkCore([const Rec('Y1', 1)])..notY['B'] = {'Y1'};
      l = login(c);
      l.onScan(3 * s, 'B', hint: 'Y1');
      expect(l.next(3 * s), isNull);
      expect(l.next(30 * s), isNull);
    });
  });
}
