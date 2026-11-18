// #329 PR 7 T8 (a) (plan §2 / §10, review E m-11 / F m-8): 「頭兩輪」 per node. `NodeState.roundsEnded` counts this
// run's rounds that ended normally and reached the node; a cancelled round and a target still 排隊中 at the end do not
// count; `startup()` sets it to 0. Negative controls (the PR body): firstRounds by `roundsRun < 3` -> the cancelled
// rounds test FAILs; 排隊中 counted -> the queued test FAILs; no reset in startup() -> the reset test FAILs.
import 'package:batman_app/src/nodelink/core.dart';
import 'package:flutter_test/flutter_test.dart';

import 'sim.dart';

const s = 1000;

void main() {
  test('T8: a node that is read is in its first rounds until its second round ends', () {
    final w = World();
    w.dev('a1', id: 'Y1');
    final ph = w.phone('p', [const Rec('Y1', 1)]);
    final c = ph.core;
    c.startup(0, Page.home);
    w.run(30 * s);
    expect(c.states['Y1']!.last, Concl.read, reason: c.log.join('\n'));
    expect(c.states['Y1']!.roundsEnded, 1);
    expect(c.firstRounds('Y1'), isTrue, reason: 'one round ended');
    w.run(120 * s);
    expect(c.states['Y1']!.roundsEnded, 2, reason: c.log.join('\n'));
    expect(c.firstRounds('Y1'), isFalse, reason: 'two rounds ended');
  });

  test('T8: cancelled rounds do not count (three rounds started, one ended -> still the first rounds)', () {
    final w = World();
    w.dev('a1', id: 'Y1');
    final ph = w.phone('p', [const Rec('Y1', 1)]);
    final c = ph.core;
    c.startup(0, Page.home);
    // two rounds cancelled by leaving the page before they end, then a third that ends
    w.at(1 * s, () => c.setPage(w.now, Page.other));
    w.at(2 * s, () => c.setPage(w.now, Page.home));
    w.at(3 * s, () => c.setPage(w.now, Page.other));
    w.at(4 * s, () => c.setPage(w.now, Page.home));
    w.run(40 * s);
    expect(c.log.where((l) => l.contains('cancelled')).length, 2, reason: c.log.join('\n'));
    expect(c.roundsRun, 3, reason: 'three rounds started');
    expect(c.states['Y1']!.roundsEnded, 1, reason: c.log.join('\n'));
    expect(c.firstRounds('Y1'), isTrue, reason: 'only one round that reached it ended');
  });

  test('T8 (E m-11): a target still 排隊中 when its rounds end does not count', () {
    // its address is known (a memo) but each login takes longer than the 90 s cap: cut at the cap = not tried
    final w = World(a1: 100 * s);
    w.dev('a1', id: 'Y1');
    final ph = w.phone('p', [const Rec('Y1', 1)]);
    final c = ph.core;
    c.isY['a1'] = 'Y1';
    c.lastSeen['a1'] = 0;
    c.startup(0, Page.home);
    w.run(260 * s);
    final ends = c.log.where((l) => RegExp(r'round \d+ end').hasMatch(l)).toList();
    expect(ends.length, greaterThanOrEqualTo(2), reason: c.log.join('\n'));
    expect(ends.every((l) => l.contains('Y1: queued')), isTrue, reason: c.log.join('\n'));
    expect(c.states['Y1']!.roundsEnded, 0, reason: c.log.join('\n'));
    expect(c.firstRounds('Y1'), isTrue);
  });

  test('T8: startup() starts the count again; a node without a state is not in its first rounds', () {
    final c = NodeLinkCore(const [Rec('Y1', 1)]);
    c.states['Y1']!.roundsEnded = 5;
    expect(c.firstRounds('Y1'), isFalse);
    c.startup(0, Page.other);
    expect(c.states['Y1']!.roundsEnded, 0);
    expect(c.firstRounds('Y1'), isTrue);
    expect(c.firstRounds('gone'), isFalse);
  });
}
