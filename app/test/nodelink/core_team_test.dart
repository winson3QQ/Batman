// #329 PR 6 D5(d), T6-13(e) and the team variant of the state × event table's H0 rows (design §4.3.6: 「H0 首頁 /
// 全隊頁在最上層」): the team page reads like the home page (every record, a full round 60 s after the last, nothing
// in the background), and home <-> team is a no-op for the scheduler (no cancel, no due reset).
import 'package:batman_app/src/nodelink/core.dart';
import 'package:flutter_test/flutter_test.dart';

import 'sim.dart';

const s = 1000;
const min = 60 * s;

void main() {
  (World, Phone) two(Page page) {
    final w = World();
    w.dev('a1', id: 'Y1');
    w.dev('a2', id: 'Y2');
    final ph = w.phone('p', [const Rec('Y1', 1), const Rec('Y2', 2)]);
    ph.core.startup(0, page);
    return (w, ph);
  }

  List<String> fullRounds(NodeLinkCore c) => [for (final l in c.log) if (RegExp(r'round \d+ full ').hasMatch(l)) l];

  group('T6-13(e) the team page', () {
    test('on top: every record is a target, a full round 60 s after the last, both nodes read', () {
      final (w, ph) = two(Page.team);
      final c = ph.core;
      w.run(5 * min);
      final rounds = fullRounds(c);
      expect(rounds.first, contains('[Y1, Y2]'));
      expect(rounds.length, greaterThanOrEqualTo(3), reason: c.log.join('\n'));
      expect(ph.reads['Y1'], isNotNull);
      expect(ph.reads['Y2'], isNotNull);
      expect(c.fresh('Y1', w.now) && c.fresh('Y2', w.now), isTrue);
    });

    test('in the background nothing is read', () {
      final (w, ph) = two(Page.team);
      final c = ph.core;
      w.run(70 * s);
      c.background(w.now);
      final n = c.roundsRun;
      w.run(w.now + 5 * min);
      expect(c.roundsRun, n);
    });

    test('home -> team during a round: the round goes on (not cancelled), the dues are kept; team -> home the same',
        () {
      final (w, ph) = two(Page.home);
      final c = ph.core;
      w.run(5 * s);
      expect(c.roundActive, isTrue);
      final n = c.roundsRun;
      final due = (c.fullDue, c.earlyDue, c.leaseDue);
      c.setPage(w.now, Page.team);
      expect(c.roundActive, isTrue, reason: 'not cancelled');
      expect(c.log.where((l) => l.contains('cancelled')), isEmpty);
      expect((c.fullDue, c.earlyDue, c.leaseDue), due);
      expect(c.page, Page.team);
      c.setPage(w.now, Page.home);
      expect(c.roundActive, isTrue);
      expect(c.roundsRun, n);
      expect(c.log.where((l) => l.contains('cancelled')), isEmpty);
    });

    test('home -> team between rounds: the full-round due stays, no extra round', () {
      final (w, ph) = two(Page.home);
      final c = ph.core;
      w.run(40 * s); // round 1 over, the next one due 60 s after it ended
      expect(c.roundActive, isFalse);
      final due = c.fullDue;
      expect(due, isNotNull);
      final n = c.roundsRun;
      c.setPage(w.now, Page.team);
      expect(c.fullDue, due);
      expect(c.roundsRun, n);
    });
  });

  // design §4.3.6: every H0 row holds with the team page on top, as with the home page
  for (final page in [Page.home, Page.team]) {
    group('T-X H0 (${page.name} on top)', () {
      test('X1: the timer starts a round 60 s after the last ended; 重新整理 starts one and clears 「不是」', () {
        final (w, ph) = two(page);
        final c = ph.core;
        w.run(40 * s);
        expect(c.roundActive, isFalse);
        final n = c.roundsRun;
        w.run(c.fullDue! + 1);
        expect(c.roundsRun, n + 1);
        w.run(w.now + 40 * s);
        c.notY['zz'] = {'Y1'};
        final m = c.roundsRun;
        c.refresh(w.now);
        expect(c.roundsRun, m + 1);
        expect(c.notY.values.every((v) => v.isEmpty), isTrue);
      });

      test('X4/X32: a lease: no round while held; X18: 6 s after release', () {
        final (w, ph) = two(page);
        final c = ph.core;
        w.run(40 * s);
        c.acquireLease(w.now);
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

      test('X5/X6: background: no rounds; foreground: a round at once', () {
        final (w, ph) = two(page);
        final c = ph.core;
        w.run(40 * s);
        c.background(w.now);
        final n = c.roundsRun;
        w.run(w.now + 5 * min);
        expect(c.roundsRun, n);
        c.foreground(w.now);
        expect(c.roundsRun, n + 1);
      });

      test('X7/X8: Bluetooth off -> unreachable at once, no round; on -> a round at once', () {
        final (w, ph) = two(page);
        final c = ph.core;
        w.run(40 * s);
        c.setRadio(w.now, bluetooth: false);
        expect(c.states.keys.every((id) => c.shownWhy(id) == Why.bluetoothOff), isTrue);
        final n = c.roundsRun;
        w.run(w.now + 3 * min);
        expect(c.roundsRun, n);
        c.setRadio(w.now, bluetooth: true);
        expect(c.roundsRun, n + 1);
      });

      test('X27: another page on top: no round; back after >= 60 s -> a round at once', () {
        final (w, ph) = two(page);
        final c = ph.core;
        w.run(40 * s);
        c.setPage(w.now, Page.other);
        final n = c.roundsRun;
        w.run(w.now + 3 * min);
        expect(c.roundsRun, n);
        c.setPage(w.now, page);
        expect(c.roundsRun, n + 1);
      });

      test('X29: a lease released in the background -> on return a round at once', () {
        final (w, ph) = two(page);
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

      test('X31: keys unusable -> unreachable(keys); usable again -> a round at once', () {
        final (w, ph) = two(page);
        final c = ph.core;
        w.run(40 * s);
        c.setRadio(w.now, keyOk: false);
        expect(c.states.keys.every((id) => c.shownWhy(id) == Why.keys), isTrue);
        final n = c.roundsRun;
        c.setRadio(w.now, keyOk: true);
        expect(c.roundsRun, n + 1);
      });

      test('X33: opening a node page reads that node', () {
        final (w, ph) = two(page);
        final c = ph.core;
        w.run(40 * s);
        final n = c.roundsRun;
        c.setPage(w.now, Page.node, node: 'Y2');
        expect(c.roundsRun, n + 1);
        expect(c.log.last, contains('[Y2]'));
      });
    });
  }
}
