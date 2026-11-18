// #329 PR 6 D5(c), T6-13(b): NodeLink.teams has one writer, NodeLink._run, after the core accepted the read; the entry
// carries that read's own readAt (the one now() value given to core.result) and readWall. A cancelled round, an
// aborted attempt, an error-code answer and a record gone meanwhile write nothing; a removed record's entry goes; a
// page change keeps it. The fake clock moves 1 ms on every now() call, so a second now() would not match.
import 'dart:async';

import 'package:batman_app/src/nodelink/ble_gate.dart';
import 'package:batman_app/src/nodelink/core.dart';
import 'package:batman_app/src/nodelink/lease.dart';
import 'package:batman_app/src/nodelink/node_link.dart';
import 'package:batman_app/src/rust/api/owner.dart' show TeamView;
import 'package:flutter_test/flutter_test.dart';

import 'node_link_test.dart' show Clock, Radio;

TeamView tv(String title) => TeamView(visible: true, title: title, only: '', cards: const [], note: '', tech: const []);

/// Answers every probe of Y1 on a1 with [res] and, when [team] is set, a team section; [hold] makes it wait.
class TeamProber implements Prober {
  Res res = Res.body;
  String? team = 'T1';
  Completer<void>? hold;
  void Function()? during; // runs while the probe is held (before it answers)
  int probes = 0;

  @override
  Future<Outcome> probe(GateLink link, String id, {required Future<void> due, required Future<void> cancelled}) async {
    probes++;
    final h = hold;
    if (h != null) {
      during?.call();
      await h.future; // answers even after a cancel: a late result must be dropped by NodeLink / the core
    }
    final t = team;
    if (res == Res.errorCode) return Outcome.withTeam(Res.errorCode, '', null, t == null ? null : TeamSeen('aa', tv(t)));
    return t == null ? const Outcome(Res.body, 'green') : Outcome.withTeam(Res.body, 'green', null, TeamSeen('aa', tv(t)));
  }
}

class Rig {
  Rig() {
    reg = LeaseRegistry(after: clock.after);
    gate = BleGate(radio, reg, now: now, after: clock.after);
    nl = NodeLink(
      core: NodeLinkCore(const []),
      gate: gate,
      reg: reg,
      prober: prober,
      readRecords: () async => [...recs],
      now: now,
      after: clock.after,
      wall: () => DateTime(2026, 11, 18, 9, 0, clock.t ~/ 1000),
    );
  }
  final clock = Clock();
  final radio = Radio();
  final prober = TeamProber();
  var recs = [const Rec('Y1', 1)];
  late final LeaseRegistry reg;
  late final BleGate gate;
  late final NodeLink nl;

  /// §14: every now() moves the clock 1 ms, so two calls never give the same time.
  int now() => ++clock.t;

  Future<void> firstRead() async {
    await nl.start(Page.home);
    await clock.run(500);
    radio.scanCtl.add('a1');
    await clock.run(3000);
  }
}

void main() {
  test('positive end-to-end: a normal read -> teams[Y1] with the state\'s very readAt and the read\'s wall time; fresh',
      () async {
    final r = Rig();
    await r.firstRead();
    final s = r.nl.core.states['Y1']!;
    final tr = r.nl.teams['Y1'];
    expect(s.kind, Kind.read);
    expect(tr, isNotNull);
    expect(tr!.readAt, s.readAt, reason: 'one now() for the core and the team (§14)');
    expect(tr.readWall, r.nl.readWall['Y1']);
    expect(tr.netId, 'aa');
    expect(tr.view.title, 'T1');
    expect(r.nl.core.fresh('Y1', r.clock.t) && tr.readAt == s.readAt, isTrue, reason: 'the section is fresh');
  });

  test('a later read without a team (2 s over / cancelled in the prober) -> the old team stays, its readAt no longer '
      'matches: not fresh', () async {
    final r = Rig();
    await r.firstRead();
    final first = r.nl.teams['Y1']!;
    r.prober.team = null; // round 2's record step ran over its budget: Outcome.team null
    r.nl.refresh();
    await r.clock.run(500);
    r.radio.scanCtl.add('a1'); // the node advertises again for round 2
    await r.clock.run(3000);
    final s = r.nl.core.states['Y1']!;
    expect(r.prober.probes, greaterThan(1));
    expect(r.nl.teams['Y1'], same(first));
    expect(s.readAt, isNot(first.readAt));
    expect(r.nl.core.fresh('Y1', r.clock.t), isTrue, reason: 'the node is fresh, the team is not from this read');
  });

  /// After a good read (team T1), round 2's probe of Y1 is held with a team T2; [cut] ends that round meanwhile.
  Future<Rig> secondHeld(void Function(Rig r) cut) async {
    final r = Rig();
    await r.firstRead();
    expect(r.nl.teams['Y1']!.view.title, 'T1');
    r.prober
      ..hold = Completer<void>()
      ..team = 'T2';
    final n = r.prober.probes;
    r.nl.refresh();
    await r.clock.run(500);
    r.radio.scanCtl.add('a1');
    await r.clock.run(1000);
    expect(r.prober.probes, n + 1, reason: 'round 2 is probing Y1');
    cut(r);
    r.prober.hold!.complete();
    await r.clock.run(1000);
    return r;
  }

  test('a cancelled round (background while the probe runs) -> its late team is not written', () async {
    final r = await secondHeld((r) => r.nl.background());
    expect(r.nl.teams['Y1']!.view.title, 'T1');
  });

  test('an attempt aborted by a page change (_abort) -> its late team is not written', () async {
    final r = await secondHeld((r) => r.nl.setPage(Page.other));
    expect(r.nl.teams['Y1']!.view.title, 'T1');
  });

  test("an error-code answer (row 2') carrying a team -> not written", () async {
    final r = Rig();
    await r.firstRead();
    expect(r.nl.teams['Y1']!.view.title, 'T1');
    r.prober
      ..res = Res.errorCode
      ..team = 'T2';
    final n = r.prober.probes;
    r.nl.refresh();
    await r.clock.run(500);
    r.radio.scanCtl.add('a1');
    await r.clock.run(3000);
    expect(r.prober.probes, greaterThan(n));
    expect(r.nl.teams['Y1']!.view.title, 'T1', reason: 'an error-code answer is not a read');
  });

  test('the record gone while its read runs -> the core does not take the read, no team, no crash', () async {
    final r = Rig();
    r.prober.hold = Completer<void>();
    r.prober.during = () => r.nl.core.setRecords(const []); // node/Y1 removed meanwhile
    await r.nl.start(Page.home);
    await r.clock.run(500);
    r.radio.scanCtl.add('a1');
    await r.clock.run(1000);
    r.prober.hold!.complete();
    await r.clock.run(3000);
    expect(r.nl.teams, isEmpty);
  });

  test('node/<id> removed (records read again at a lease release) -> its team goes; a page change keeps it', () async {
    final r = Rig();
    await r.firstRead();
    expect(r.nl.teams.keys, ['Y1']);
    r.nl.setPage(Page.other);
    r.nl.setPage(Page.team);
    expect(r.nl.teams.keys, ['Y1'], reason: 'a page change keeps it');
    final l = (await r.nl.acquire('從這支手機移除', LeaseKind.session))!;
    r.recs = [];
    await l.release();
    await r.clock.run(500);
    expect(r.nl.core.states, isEmpty);
    expect(r.nl.teams, isEmpty);
  });
}
