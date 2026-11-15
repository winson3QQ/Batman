// #329 design §4.3 / §9.1, second batch: memos (T-L11), node behaviour (T-L13/14), two phones (T-L16), many phones
// (T-L11(j)), the flow login (T-L17/18) and rows of the state × event table (T-X).
import 'package:batman_app/src/nodelink/core.dart';
import 'package:flutter_test/flutter_test.dart';

import 'sim.dart';

const s = 1000;
const min = 60 * s;

int t(String l) => (double.parse(l.trim().split(' ').first) * 1000).round();

/// Handshakes on `d` per round of `c`, in round order (rounds with none are skipped).
List<int> perRound(NodeLinkCore c, Dev d) {
  final starts = [for (final l in c.log) if (RegExp(r'round \d+ (full|early) ').hasMatch(l)) t(l)];
  final out = <int>[];
  for (var i = 0; i < starts.length; i++) {
    final hi = i + 1 < starts.length ? starts[i + 1] : 1 << 40;
    final n = d.handshakeTimes.where((h) => h >= starts[i] && h < hi).length;
    if (n > 0) out.add(n);
  }
  return out;
}

void main() {
  test('T-L11(b): 1 unknown address + 5 unreadable records -> 2, 2, 1 handshakes on it, >= 6 s apart', () {
    final w = World();
    final f = w.dev('f0', mode: Mode.foreignUndecryptable);
    final ph = w.phone('p', [for (var i = 0; i < 5; i++) Rec('Y$i', i)]);
    final c = ph.core;
    c.startup(0, Page.home);
    w.run(10 * min);
    expect(perRound(c, f), [2, 2, 1], reason: c.log.join('\n'));
    for (var i = 1; i < f.handshakeTimes.length; i++) {
      expect(f.handshakeTimes[i] - f.handshakeTimes[i - 1], greaterThanOrEqualTo(6 * s));
    }
  });

  test('T-L11(c)(i): 1 unreadable record + 5 fixed foreign addresses for 30 min -> each exactly 1 handshake', () {
    final w = World();
    final fs = [for (var i = 0; i < 5; i++) w.dev('f$i', mode: Mode.foreignUndecryptable)];
    w.dev('a1', id: 'Y1').on = false;
    final ph = w.phone('p', [const Rec('Y1', 1)]);
    final c = ph.core;
    c.startup(0, Page.home);
    w.run(30 * min);
    for (final f in fs) {
      expect(f.handshakes, 1, reason: '${f.addr}\n${c.log.join('\n')}');
    }
    expect(c.states['Y1']!.why, Why.notFound);
  });

  test('T-L11(e): a silent address gets no memo, goes last next round and is still tried', () {
    final w = World();
    final x = w.dev('x0', mode: Mode.foreignSilent);
    w.dev('a1', id: 'Y1').on = false;
    final ph = w.phone('p', [const Rec('Y1', 1)]);
    final c = ph.core;
    c.startup(0, Page.home);
    w.run(5 * min);
    expect(c.notY['x0'], isNull);
    expect(perRound(c, x).length, greaterThanOrEqualTo(3), reason: c.log.join('\n'));
  });

  test('T-L11(f): CertRejected -> identity at once, kept over later 沒找到 rounds, ended by refresh', () {
    final w = World();
    final d = w.dev('a1', id: 'Y1')..force = Res.certRejected;
    final ph = w.phone('p', [const Rec('Y1', 1)]);
    final c = ph.core;
    c.startup(0, Page.home);
    w.run(10 * s);
    expect(c.states['Y1']!.why, Why.identity, reason: c.log.join('\n'));
    final hs = d.handshakes;
    w.run(5 * min);
    expect(c.states['Y1']!.why, Why.identity);
    expect(d.handshakes, hs, reason: 'no more tries of Y1 on that address');
    d.force = null;
    w.at(w.now + 1, () => c.refresh(w.now));
    w.run(w.now + 60 * s);
    expect(c.states['Y1']!.kind, Kind.read, reason: c.log.join('\n'));
  });

  test('T-L11(f): EForbidden -> 登入被拒 at once, 1 handshake per round, read again once the node accepts', () {
    final w = World();
    final d = w.dev('a1', id: 'Y1')..force = Res.refusedForbidden;
    final ph = w.phone('p', [const Rec('Y1', 1)]);
    final c = ph.core;
    c.startup(0, Page.home);
    w.run(10 * s);
    expect(c.states['Y1']!.why, Why.refused);
    w.run(4 * min);
    expect(perRound(c, d).every((n) => n == 1), isTrue, reason: c.log.join('\n'));
    d.force = null;
    w.run(w.now + 2 * min);
    expect(c.states['Y1']!.kind, Kind.read, reason: c.log.join('\n'));
  });

  test('T-L11(f): AuthRefused with another code is not 登入被拒', () {
    final w = World();
    w.dev('a1', id: 'Y1').force = Res.refusedOther;
    final ph = w.phone('p', [const Rec('Y1', 1)]);
    final c = ph.core;
    c.startup(0, Page.home);
    w.run(3 * min);
    expect(c.states['Y1']!.why, isNot(Why.refused), reason: c.log.join('\n'));
  });

  test('T-L11(g): a lease release and a refresh keep 「是 Y」 (1 handshake next round); a write under the lease drops it',
      () {
    final w = World();
    final d = w.dev('a1', id: 'Y1');
    w.dev('a2', id: 'Y2');
    final ph = w.phone('p', [const Rec('Y1', 1), const Rec('Y2', 2)]);
    final c = ph.core;
    c.startup(0, Page.home);
    w.run(2 * min);
    w.at(w.now + 1, () => c.acquireLease(w.now));
    w.at(w.now + 10 * s, () => c.releaseLease(w.now));
    w.run(w.now + 11 * s);
    expect(c.isY['a1'], 'Y1');
    final before = d.handshakes;
    w.run(w.now + 40 * s);
    expect(d.handshakes - before, 1, reason: c.log.join('\n'));
    w.at(w.now + 1, () => c.refresh(w.now));
    w.run(w.now + 2 * s);
    expect(c.isY['a1'], 'Y1');
    expect(c.notY.values.every((v) => v.isEmpty), isTrue);
    w.at(w.now + 30 * s, () => c.acquireLease(w.now));
    w.at(w.now + 40 * s, () => c.releaseLease(w.now, written: {'Y1'}));
    w.run(w.now + 41 * s);
    expect(c.isY.containsValue('Y1'), isFalse);
  });

  test('T-L11(l): a 「是 Y」 address answering 解不開 once -> 「是 Y」 dropped, no 「不是 Y」; twice -> 「不是 Y」', () {
    final w = World();
    final d = w.dev('a1', id: 'Y1');
    final ph = w.phone('p', [const Rec('Y1', 1)]);
    final c = ph.core;
    c.startup(0, Page.home);
    w.run(2 * min);
    expect(c.isY['a1'], 'Y1');
    d.force = Res.undecryptable;
    final h = d.handshakes;
    while (d.handshakes == h) {
      w.run(w.now + s);
    }
    w.run(w.now + 6 * s);
    expect(c.isY['a1'], isNull, reason: c.log.join('\n'));
    expect(c.notY['a1']?.contains('Y1') ?? false, isFalse);
    while (d.handshakes == h + 1) {
      w.run(w.now + s);
    }
    w.run(w.now + 6 * s);
    expect(c.notY['a1']?.contains('Y1') ?? false, isTrue, reason: c.log.join('\n'));
  });

  test('T-L13(a): a node that re-advertises 8 s after a disconnect is never 連不到', () {
    final w = World();
    w.dev('a1', id: 'Y1').readvertise = 8000;
    w.dev('a2', id: 'Y2').readvertise = 8000;
    final ph = w.phone('p', [const Rec('Y1', 1), const Rec('Y2', 2)]);
    final c = ph.core;
    c.startup(0, Page.home);
    w.run(15 * min);
    expect(c.log.where((l) => l.contains('notFound')), isEmpty, reason: c.log.join('\n'));
  });

  test('T-L14: 12 silent addresses + 2 known nodes -> both read within 40 s of every full round start', () {
    final w = World();
    w.dev('a1', id: 'Y1');
    w.dev('a2', id: 'Y2');
    final xs = [for (var i = 0; i < 12; i++) w.dev('x$i', mode: Mode.foreignSilent)..on = false];
    w.at(2 * min, () {
      for (final x in xs) {
        x.on = true;
      }
    });
    final ph = w.phone('p', [const Rec('Y1', 1), const Rec('Y2', 2)]);
    final c = ph.core;
    c.startup(0, Page.home);
    w.run(12 * min);
    final starts = [for (final l in c.log) if (l.contains(' full ')) t(l)].where((x) => x >= 2 * min && x < 11 * min);
    for (final st in starts) {
      for (final id in ['Y1', 'Y2']) {
        expect((ph.reads[id] ?? []).any((r) => r >= st && r <= st + 40 * s), isTrue,
            reason: '$id round at ${st ~/ 1000}\n${c.log.join('\n')}');
      }
    }
  });

  for (final off in [0, 10, 20, 30, 40, 50]) {
    test('T-L16: two phones own one node, offset $off s -> neither shows 連不到, reads <= 300 s apart', () {
      final w = World();
      w.dev('a1', id: 'Y1');
      final p1 = w.phone('p1', [const Rec('Y1', 1)]);
      final p2 = w.phone('p2', [const Rec('Y1', 1)]);
      p1.core.startup(0, Page.home);
      w.at(off * s, () => p2.core.startup(w.now, Page.home));
      w.run(21 * min);
      for (final ph in [p1, p2]) {
        expect(ph.core.log.where((l) => l.contains('Why.notFound')), isEmpty);
        expect(ph.core.states['Y1']!.why, isNot(Why.notFound), reason: ph.core.log.join('\n'));
        expect(maxGap(ph.reads['Y1'] ?? [], from: 2 * min, until: 21 * min), lessThanOrEqualTo(300 * s),
            reason: ph.core.log.join('\n'));
      }
    });
  }

  for (final m in [5, 10]) {
    test('T-L11(j): $m phones, one node each, start together -> each reads its own within 5 min; after a rotation, '
        'a phone whose node is off for 3 min handshakes others <= m-1 times', () {
      final w = World();
      final ds = [for (var i = 0; i < m; i++) w.dev('a$i', id: 'Y$i')];
      final ps = [for (var i = 0; i < m; i++) w.phone('p$i', [Rec('Y$i', 1)])];
      for (final ph in ps) {
        ph.core.startup(0, Page.home);
      }
      w.run(5 * min);
      for (var i = 0; i < m; i++) {
        expect(ps[i].reads['Y$i'], isNotNull, reason: ps[i].core.log.join('\n'));
      }
      for (final d in ds) {
        final hs = d.handshakeTimes;
        for (var i = 0; i < hs.length; i++) {
          expect(hs.where((h) => h >= hs[i] && h < hs[i] + 60 * s).length, lessThanOrEqualTo(20)); // safety only
        }
      }
      // every address rotates; phone 0's node is off for 3 minutes
      final at = w.now;
      for (final d in ds) {
        d.addr = '${d.addr}r';
      }
      ds[0].on = false;
      w.at(at + 3 * min, () => ds[0].on = true);
      final before = {for (var i = 1; i < m; i++) i: ds[i].byPhone['p0'] ?? 0};
      w.run(at + 10 * min);
      final toOthers = [for (var i = 1; i < m; i++) (ds[i].byPhone['p0'] ?? 0) - before[i]!].fold(0, (a, b) => a + b);
      expect(toOthers, lessThanOrEqualTo(m - 1), reason: ps[0].core.log.join('\n'));
      expect(ps[0].reads['Y0']!.any((r) => r > at + 3 * min), isTrue);
    });
  }

  test('T-L17: claim, release, at once a new lease and loginFor -> the N9 window is not memoed, logged in', () {
    final w = World();
    final d = w.dev('a1', id: 'Y1');
    final ph = w.phone('p', [const Rec('Y1', 1)]);
    final c = ph.core;
    c.startup(0, Page.other);
    late LoginFor l;
    w.at(10 * s, () {
      c.acquireLease(w.now);
      d.claimedAt = w.now; // the node learns its owner at its next 4 s poll
      c.releaseLease(w.now, written: {'Y1'});
      c.acquireLease(w.now);
      l = c.loginFor(w.now, 'Y1');
      ph.login = l;
    });
    w.run(10 * s + 59 * s);
    expect(l.end, LoginEnd.ok, reason: c.log.join('\n'));
    expect(c.notY['a1']?.contains('Y1') ?? false, isFalse);
  });

  test('T-L18: loginFor tries the known address first even when unknown ones are scanned before it', () {
    final w = World();
    for (var i = 0; i < 3; i++) {
      w.dev('f$i', mode: Mode.foreignUndecryptable);
    }
    final d = w.dev('a1', id: 'Y1');
    final fs = w.devs.where((x) => x.mode != Mode.own).toList();
    final ph = w.phone('p', [const Rec('Y1', 1)]);
    final c = ph.core;
    c.startup(0, Page.home);
    w.run(3 * min);
    expect(c.isY['a1'], 'Y1');
    final before = fs.map((f) => f.handshakes).fold(0, (a, b) => a + b);
    late LoginFor l;
    w.at(w.now + 1, () {
      c.acquireLease(w.now);
      l = c.loginFor(w.now, 'Y1');
      ph.login = l;
    });
    w.run(w.now + 60 * s);
    expect(l.end, LoginEnd.ok, reason: c.log.join('\n'));
    expect(fs.map((f) => f.handshakes).fold(0, (a, b) => a + b), before, reason: c.log.join('\n'));
    expect(d.logins, greaterThan(0));
  });

  test('T-L18: loginFor right after a read (node quiet 5 s) and with one broken attempt still logs in', () {
    final w = World();
    final d = w.dev('a1', id: 'Y1');
    final fs = [for (var i = 0; i < 3; i++) w.dev('f$i', mode: Mode.foreignUndecryptable)];
    final ph = w.phone('p', [const Rec('Y1', 1)]);
    final c = ph.core;
    c.startup(0, Page.node, node: 'Y1');
    w.run(2 * min);
    // act right when the next read of Y1 has just finished (the node is quiet for ~5 s)
    final n = ph.reads['Y1']!.length;
    while (ph.reads['Y1']!.length == n) {
      w.run(w.now + 100);
    }
    final last = w.now;
    final before = fs.map((f) => f.handshakes).fold(0, (a, b) => a + b);
    c.acquireLease(last);
    d.force = Res.broken;
    final l = c.loginFor(last, 'Y1');
    ph.login = l;
    w.at(last + 12 * s, () => d.force = null);
    w.run(last + 60 * s);
    expect(l.end, LoginEnd.ok, reason: c.log.join('\n'));
    expect(l.handshakes, greaterThanOrEqualTo(2), reason: 'the broken attempt happened\n${c.log.join('\n')}');
    expect(fs.map((f) => f.handshakes).fold(0, (a, b) => a + b), before, reason: c.log.join('\n'));
  });

  test('T-L17 control premise: without the N9 window the same flow would end NOT_FOUND', () {
    final w = World();
    final d = w.dev('a1', id: 'Y1');
    final ph = w.phone('p', [const Rec('Y1', 1)]);
    final c = ph.core;
    c.startup(0, Page.other);
    late LoginFor l;
    w.at(10 * s, () {
      d.claimedAt = w.now;
      c.acquireLease(w.now); // no release with `written`: the core does not know the record is new
      l = c.loginFor(w.now, 'Y1');
      ph.login = l;
    });
    w.run(10 * s + 70 * s);
    expect(l.end, LoginEnd.notFound, reason: c.log.join('\n'));
  });

  group('T-X', () {
    (World, Phone) two() {
      final w = World();
      w.dev('a1', id: 'Y1');
      w.dev('a2', id: 'Y2');
      final ph = w.phone('p', [const Rec('Y1', 1), const Rec('Y2', 2)]);
      ph.core.startup(0, Page.home);
      return (w, ph);
    }

    test('X2: refresh during a full round starts no second round and clears 「不是」', () {
      final (w, ph) = two();
      final c = ph.core;
      w.run(90 * s); // round 2 (85 s) is running
      c.notY['zz'] = {'Y1'};
      final n = c.roundsRun;
      c.refresh(w.now);
      expect(c.roundsRun, n);
      expect(c.notY.values.every((v) => v.isEmpty), isTrue);
    });

    test('X3: opening a node page during a home round cancels it and reads that node', () {
      final (w, ph) = two();
      final c = ph.core;
      w.run(5 * s);
      c.setPage(w.now, Page.node, node: 'Y2');
      expect(c.log.last, contains('[Y2]'));
      w.run(w.now + 30 * s);
      expect(ph.reads['Y2'], isNotNull);
    });

    test('X4/X32: a lease cancels the round and no round runs while it is held; X18: 6 s after release', () {
      final (w, ph) = two();
      final c = ph.core;
      w.run(5 * s);
      c.acquireLease(w.now);
      expect(c.roundActive, isFalse);
      final n = c.roundsRun;
      w.run(w.now + 3 * min);
      expect(c.roundsRun, n);
      final rel = w.now;
      c.releaseLease(rel);
      w.run(rel + 5 * s);
      expect(c.roundsRun, n);
      w.run(rel + 6 * s);
      expect(c.roundsRun, n + 1);
    });

    test('X5/X34: background cancels the round', () {
      final (w, ph) = two();
      final c = ph.core;
      w.run(5 * s);
      c.background(w.now);
      expect(c.roundActive, isFalse);
      final n = c.roundsRun;
      w.run(w.now + 5 * min);
      expect(c.roundsRun, n);
    });

    test('X7/X8: Bluetooth off -> every target unreachable at once, no round; on -> a round at once', () {
      final (w, ph) = two();
      final c = ph.core;
      w.run(60 * s);
      c.setRadio(w.now, bluetooth: false);
      expect(c.states.values.every((s) => s.why == Why.bluetoothOff), isTrue);
      final n = c.roundsRun;
      w.run(w.now + 3 * min);
      expect(c.roundsRun, n);
      c.setRadio(w.now, bluetooth: true);
      expect(c.roundsRun, n + 1);
    });

    test('X27: on another page no round runs; back home after >= 60 s -> a round at once', () {
      final (w, ph) = two();
      final c = ph.core;
      w.run(40 * s);
      c.setPage(w.now, Page.other);
      final n = c.roundsRun;
      w.run(w.now + 3 * min);
      expect(c.roundsRun, n);
      c.setPage(w.now, Page.home);
      expect(c.roundsRun, n + 1);
    });

    test('X29: a lease released in the background -> on return a round at once', () {
      final (w, ph) = two();
      final c = ph.core;
      w.run(40 * s);
      c.acquireLease(w.now);
      c.background(w.now);
      c.releaseLease(w.now + s);
      final n = c.roundsRun;
      w.run(w.now + 2 * min);
      expect(c.roundsRun, n);
      c.foreground(w.now);
      expect(c.roundsRun, n + 1);
    });

    test('X31: keys unusable -> every target unreachable(keys); usable again -> a round at once', () {
      final (w, ph) = two();
      final c = ph.core;
      w.run(40 * s);
      c.setRadio(w.now, keyOk: false);
      expect(c.states.values.every((s) => s.why == Why.keys), isTrue);
      final n = c.roundsRun;
      c.setRadio(w.now, keyOk: true);
      expect(c.roundsRun, n + 1);
    });

    test('X35: opening another page during a round cancels it', () {
      final (w, ph) = two();
      final c = ph.core;
      w.run(5 * s);
      c.setPage(w.now, Page.other);
      expect(c.roundActive, isFalse);
    });
  });
}
