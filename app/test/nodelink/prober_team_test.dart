// #329 PR 6 D5(a)/(b), T6-13(a): the team section is worked out on the read's own session, in the same 2 s budget and
// from the same one opening of the network record as the PR 5 hint; only when team_enabled() says so (injected here);
// for every build and page (not behind `wanted`); never after a cancel or the session's disposal; null when the record
// step ran over its budget, was cancelled, or NetIndex is not computed yet (§14).
import 'dart:async';
import 'dart:typed_data';

import 'package:batman_app/src/nodelink/ble_gate.dart';
import 'package:batman_app/src/nodelink/core.dart';
import 'package:batman_app/src/nodelink/lease.dart';
import 'package:batman_app/src/nodelink/node_link.dart' show TeamSeen;
import 'package:batman_app/src/nodelink/prober.dart';
import 'package:batman_app/src/rust/api/owner.dart';
import 'package:batman_app/src/rust/frb_generated.dart';
import 'package:flutter_test/flutter_test.dart';

import 'prober_hint_test.dart' show HintSession, Hints;
import 'prober_test.dart' show FakeRust, Radio, step;

/// A session whose teamView says which input it was given: the record-less versions (as Rust's team_names picks
/// them: NoNet / NoInfo by the info, NoList with a netId) or the record's list. After dispose it throws (R7).
class TeamSession extends HintSession {
  TeamSession(super.script, {super.netId, super.nodeState, this.infoRead = true, this.row = '3'});
  final bool infoRead;
  final String row;
  final teamCalls = <String>[];
  int lateTeam = 0;

  @override
  StatusView statusView({required bool hasNet, required bool hasMnet}) => StatusView(
      color: row == "2'" ? 'gray' : 'green',
      row: row,
      sentence: '',
      lagNote: '',
      warning: '',
      nodeState: nodeState,
      netId: netId,
      version: '',
      tech: const [],
      fresh: true,
      rateNote: '',
      unfinished: '',
      unfinishedUnderVerdict: false,
      canLeave: false);

  @override
  TeamView teamView({List<int>? recordPlain, required bool member}) {
    if (disposed) {
      lateTeam++;
      throw StateError('teamView on a disposed session');
    }
    final what = recordPlain != null
        ? 'LIST member=$member'
        : (!infoRead ? 'NO_INFO' : (netId.isEmpty ? 'NO_NET' : 'NO_LIST'));
    teamCalls.add(recordPlain == null ? 'null' : 'record member=$member');
    return TeamView(visible: true, title: what, only: '', cards: const [], note: '', tech: const []);
  }
}

void main() {
  final rust = FakeRust();
  setUpAll(() => RustLib.initMock(api: rust));

  final read = [step(OwnerKind.loggedIn, loginEnd: 1), step(OwnerKind.answer)];

  Future<(Outcome, TeamSession, List<String>)> probe(Hints h,
      {bool team = true,
      bool Function()? teamFlag,
      bool ready = true,
      String netId = 'aa',
      int nodeState = 2,
      bool infoRead = true,
      String row = '3',
      Future<void>? cancelled}) async {
    final s = TeamSession([...read], netId: netId, nodeState: nodeState, infoRead: infoRead, row: row);
    rust.session = s;
    final reg = LeaseRegistry(after: (d, f) => () {});
    final radio = Radio();
    final gate = BleGate(radio, reg, now: () => 0, after: (d, f) => () {});
    final link = gate.connect(reg.token, 'a1');
    await Future<void>.delayed(Duration.zero);
    final logs = <String>[];
    final src = h.source;
    final p = SessionProber(
      openRecord: (id) async => Uint8List(8),
      ownerPub: () async => Uint8List(65),
      signOwner: (input) async => Uint8List(70),
      log: logs.add,
      hint: HintSource(
          wanted: src.wanted, netKnown: src.netKnown, openNet: src.openNet, onHint: src.onHint, netReady: () => ready),
      teamEnabled: teamFlag ?? () => team,
    );
    final f = p.probe(link, 'Y1', due: Future<void>.delayed(const Duration(seconds: 8)), cancelled: cancelled ?? Completer<void>().future);
    for (var i = 0; i < 3; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 1));
      radio.tx.add([1]);
    }
    return (await f, s, logs);
  }

  TeamSeen? seen(Outcome o) => o.team as TeamSeen?;

  test('enabled, a body read: ONE record opening serves the hint and the team; Outcome.team carries netId + view',
      () async {
    final h = Hints();
    final (o, s, _) = await probe(h);
    expect(o.res, Res.body);
    expect(h.opened, ['net/aa'], reason: 'one openNet for both');
    expect(s.hintCalls, ['member=false']);
    expect(s.teamCalls, ['null', 'record member=false'], reason: 'first without a record, then the record over it');
    expect(seen(o)!.netId, 'aa');
    expect(seen(o)!.view.title, 'LIST member=false');
    expect(s.lateTeam + s.lateCalls, 0);
  });

  test('field build / no node page (wanted false): the team is still worked out, no hint', () async {
    final h = Hints()..wanted = false;
    final (o, s, _) = await probe(h);
    expect(h.opened, ['net/aa']);
    expect(h.got, isEmpty, reason: 'the hint only when wanted');
    expect(s.hintCalls, isEmpty);
    expect(seen(o)!.view.title, 'LIST member=false');
  });

  test('disabled (version N): no record opened when not wanted, teamView never called, no team', () async {
    final h = Hints()..wanted = false;
    final (o, s, _) = await probe(h, team: false);
    expect(h.opened, isEmpty);
    expect(s.teamCalls, isEmpty);
    expect(o.team, isNull);
    // the PR 5 hint path is unchanged when wanted
    final h2 = Hints();
    final (o2, s2, _) = await probe(h2, team: false);
    expect(h2.opened, ['net/aa']);
    expect(s2.hintCalls, ['member=false']);
    expect(s2.teamCalls, isEmpty);
    expect(o2.team, isNull);
  });

  test('team_enabled() throwing (a bridge without it) is no team, the read unchanged', () async {
    final h = Hints()..wanted = false;
    final (o, s, logs) = await probe(h, teamFlag: () => throw StateError('no such symbol'));
    expect(o.res, Res.body);
    expect(o.team, isNull);
    expect(s.teamCalls, isEmpty);
    expect(logs.join(' '), isNot(contains('no such symbol')));
  });

  test('the node is in no network (netId empty): the NO_NET version, no record opened', () async {
    final h = Hints();
    final (o, s, _) = await probe(h, netId: '', nodeState: 1);
    expect(h.opened, isEmpty);
    expect(s.teamCalls, ['null']);
    expect(seen(o)!.view.title, 'NO_NET');
    expect(seen(o)!.netId, '');
  });

  test('info not read: the NO_INFO version', () async {
    final h = Hints();
    final (o, _, _) = await probe(h, netId: '', infoRead: false);
    expect(seen(o)!.view.title, 'NO_INFO');
    expect(h.got, isEmpty, reason: 'the last hint stays (PR 5 R8)');
  });

  test('no record opens: the record-less (NO_LIST) version; net then mnet tried', () async {
    final h = Hints()..open = (rel) async => null;
    final (o, s, _) = await probe(h);
    expect(h.opened, ['net/aa', 'mnet/aa']);
    expect(s.teamCalls, ['null']);
    expect(seen(o)!.view.title, 'NO_LIST');
  });

  test('mnet opens: the member list', () async {
    final h = Hints()..open = (rel) async => rel.startsWith('net/') ? null : Uint8List(4);
    final (o, _, _) = await probe(h);
    expect(seen(o)!.view.title, 'LIST member=true');
  });

  test('netKnown false: the record-less (NO_LIST) version, no record opened', () async {
    final h = Hints()..known = false;
    final (o, _, _) = await probe(h);
    expect(h.opened, isEmpty);
    expect(seen(o)!.view.title, 'NO_LIST');
  });

  test('§14 cold start: NetIndex not computed yet -> no team (not a wrong 「沒有名單」), no record opened', () async {
    final h = Hints()..known = false;
    final (o, _, _) = await probe(h, ready: false);
    expect(h.opened, isEmpty);
    expect(o.team, isNull);
  });

  test('the record step over 2 s: the read after about 2 s, no team, nothing called after the session is gone',
      () async {
    final h = Hints()..open = (rel) => Future.delayed(const Duration(seconds: 3), () => Uint8List(4));
    final sw = Stopwatch()..start();
    final (o, s, _) = await probe(h);
    expect(o.res, Res.body);
    expect(sw.elapsedMilliseconds, lessThan(2900));
    expect(o.team, isNull, reason: 'I MINOR-1: no NoList version when the record step did not finish');
    await Future<void>.delayed(const Duration(milliseconds: 1500));
    expect(s.teamCalls, ['null'], reason: 'no teamView after the budget');
    expect(s.lateTeam, 0);
  });

  test('cancelled after openNet started: the read kept, no team, teamView never called after the cancel', () async {
    final gate = Completer<Uint8List?>();
    final cancel = Completer<void>();
    final h = Hints()
      ..open = (rel) {
        cancel.complete();
        return gate.future;
      };
    final (o, s, _) = await probe(h, cancelled: cancel.future);
    expect(o.res, Res.body);
    expect(o.team, isNull);
    gate.complete(Uint8List(4));
    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(s.teamCalls, ['null'], reason: 'the record arrived after the cancel: no teamView with it');
    expect(s.lateTeam + s.lateCalls, 0);
  });

  test("an error-code answer (row 2'): no team, no record opened, teamView never called", () async {
    final h = Hints()..wanted = false;
    final (o, s, _) = await probe(h, row: "2'");
    expect(o.res, Res.errorCode);
    expect(o.team, isNull);
    expect(s.teamCalls, isEmpty);
    expect(h.opened, isEmpty);
  });
}
