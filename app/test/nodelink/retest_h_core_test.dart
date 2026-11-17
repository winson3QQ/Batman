// #329 re-test (2026-11-17 audit): the core-level parts of T-H2 (design §9.1, §4.3.1) that no test named.
// T-H2(d): an error-code answer (Rust row 2', E_RATE / EBusy on a new session) is 「不變」, not a read: the node's
// state and readAt stay, no early re-read is triggered; a node never read stays unk 「有回應，還沒拿到狀態」.
// T-H2(f) last clause: an unreachable(找不到) node that logs in this round but answers an error code is no longer
// 連不到.
// The prober half of (d) (a row 2' answer with fresh == true is errorCode, not a read) is prober_test.dart:158.
import 'package:batman_app/src/nodelink/core.dart';
import 'package:batman_app/ui/home_logic.dart';
import 'package:batman_app/ui/widgets.dart' show Look;
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

NodeInfo info(NodeLinkCore c, String id, int now) => NodeInfo(
    id: id,
    name: '節點 ${last4(id)}',
    state: c.states[id]!,
    fresh: c.fresh(id, now),
    shownWhy: c.shownWhy(id),
    view: null,
    readWall: null);

void main() {
  test('T-H2(d): a read, then a round of error codes -> state, view and readAt unchanged; no early re-read', () {
    final w = World();
    final d = w.dev('a1', id: 'Y1');
    final ph = w.phone('p', [const Rec('Y1', 1)]);
    final c = ph.core;
    c.startup(0, Page.home);
    untilEnd(w, c);
    final st = c.states['Y1']!;
    expect((st.kind, st.view), (Kind.read, 'green'), reason: c.log.join('\n'));
    final readAt = st.readAt!;
    // the next full round: every login answers an error code (E_RATE / EBusy on the node's side)
    d.statusScript = List.filled(4, Res.errorCode, growable: true);
    final logins = d.logins;
    w.run(c.fullDue! - 1);
    untilEnd(w, c);
    expect(d.logins, greaterThan(logins), reason: 'the second round did log in\n${c.log.join('\n')}');
    final endedAt = w.now;
    expect((st.kind, st.view, st.readAt), (Kind.read, 'green', readAt), reason: c.log.join('\n'));
    expect(c.earlyDue, isNull, reason: 'an error code triggers no early re-read\n${c.log.join('\n')}');
    // nothing until the next full round, 60 s after this one
    final hs = d.handshakes;
    w.run(endedAt + 50 * s);
    expect(d.handshakes, hs, reason: c.log.join('\n'));
    expect(c.log.where((l) => l.contains(' early ')), isEmpty, reason: c.log.join('\n'));
  });

  test('T-H2(d): a node never read that answers an error code -> unk 「有回應，還沒拿到狀態」, not gray after one round', () {
    final w = World();
    w.dev('a1', id: 'Y1').statusScript = List.filled(100, Res.errorCode, growable: true);
    final ph = w.phone('p', [const Rec('Y1', 1)]);
    final c = ph.core;
    c.startup(0, Page.home);
    untilEnd(w, c);
    final st = c.states['Y1']!;
    expect((st.kind, st.responded, st.readAt), (Kind.unread, true, null), reason: c.log.join('\n'));
    final row = nodeRowWords(info(c, 'Y1', w.now), firstRounds: false);
    expect((row.$1, row.$2), (Look.unk, '有回應，還沒拿到狀態'));
  });

  test('T-H2(f): an unreachable(找不到) node that logs in this round but answers an error code is no longer 連不到', () {
    final w = World();
    final d = w.dev('a1', id: 'Y1')..on = false;
    final ph = w.phone('p', [const Rec('Y1', 1)]);
    final c = ph.core;
    c.startup(0, Page.home);
    w.run(4 * min);
    expect((c.states['Y1']!.kind, c.shownWhy('Y1')), (Kind.unreachable, Why.notFound), reason: c.log.join('\n'));
    d
      ..on = true
      ..statusScript = List.filled(100, Res.errorCode, growable: true);
    final logins = d.logins;
    w.run(c.fullDue! - 1);
    untilEnd(w, c);
    expect(d.logins, greaterThan(logins), reason: c.log.join('\n'));
    expect(c.shownWhy('Y1'), isNull, reason: c.log.join('\n'));
    expect(c.states['Y1']!.kind, isNot(Kind.unreachable), reason: c.log.join('\n'));
  });
}
