// #329 A2 (docs/design/329-takeover.md §7): T1–T17, the attempt in flight taken over by its node's page (§1.1 (a)) and
// waited for by an operation of that page (§1.1 (b)). On the combined rig of kept_link_test.dart. Every node answers
// its login late ([KRadio.hold]), so "mid-attempt" is: the connect is up, the login frame is out, no answer yet.
// T13 is not here: its two conditions (a kept link of the same node, or no room, when a detached attempt ends) cannot
// be reached through NodeLink's interface (one attempt at a time; a lease aborts the attempt), and the line it would
// pin is the one that was there before the change.
import 'dart:async';

import 'package:batman_app/src/flows/op_session.dart';
import 'package:batman_app/src/nodelink/core.dart';
import 'package:batman_app/src/nodelink/lease.dart';
import 'package:batman_app/src/nodelink/node_link.dart';
import 'package:batman_app/src/rust/frb_generated.dart';
import 'package:batman_app/ui/settings_pages.dart' show opAcquire, opBusyName;
import 'package:flutter_test/flutter_test.dart';

import '../support/fake_node.dart' show fLogin, fStatus;
import 'kept_link_test.dart' show KRig, KRust;

const p = KeptState.parked;

/// One call of `acquire`, left running.
class Acq {
  Lease? lease;
  bool done = false;
  int at = -1; // the fake clock when it returned
  (int, void Function(), List<bool>)? timer; // the wait's own timer on the fake clock (null: the call did not wait)

  /// The wait's timer was stopped or has fired.
  bool get timerOver => timer == null || timer!.$3[0];
}

extension on KRig {
  /// The lines of the core's log and NodeLink's trace that say what became of an attempt or a read.
  int n(String part) => trace.where((x) => x.contains(part)).length;
  int get aborted => n('result=noResponse');
  Kind kindOf(String id) => nl.core.states[id]!.kind;

  Acq acquire(String name, {LeaseKind kind = LeaseKind.session, String? forNode, bool Function()? gone}) {
    final a = Acq();
    final i = clock.pending.length;
    unawaited(nl.acquire(name, kind, forNode: forNode, gone: gone).then((l) {
      a.lease = l;
      a.done = true;
      a.at = clock.t;
    }));
    // acquire runs to its wait synchronously (nothing is releasing): the timer it made is the wait's
    if (clock.pending.length > i) {
      a.timer = clock.pending[i];
      expect(a.timer!.$1, clock.t + NodeLink.takeoverWait.inMilliseconds);
    }
    return a;
  }
}

void main() {
  late KRust rust;
  setUp(() {
    rust = KRust();
    RustLib.initMock(api: rust);
  });
  tearDown(() {
    RustLib.dispose();
    expect(rust.late, isEmpty, reason: 'a call into a disposed session');
  });

  KRig make(int n, int ms, int status, Params params, bool wrap) {
    final rig = KRig(rust, recs: [for (var i = 1; i <= n; i++) Rec('Y$i', 1)], params: params, wrap: wrap);
    rig.radio.hold[fLogin] = [ms];
    if (status != 0) rig.radio.hold[fStatus] = [status];
    return rig;
  }

  Future<KRig> mid(KRig rig) async {
    await rig.wait(() => rig.radio.written.contains(fLogin), what: 'the login frame is out');
    expect((rig.nl.core.running?.id, rig.radio.connects), ('Y1', 1), reason: rig.tr);
    return rig;
  }

  /// Home, [n] records, only Y1 (a1) advertises; Y1 answers its login after [ms]. Returns mid-attempt to Y1.
  Future<KRig> home({int n = 2, int ms = 3000, int status = 0, Params params = const Params(), bool wrap = false}) async {
    final rig = make(n, ms, status, params, wrap);
    await rig.nl.start(Page.home);
    return mid(rig);
  }

  /// Y1's page, its own round's attempt mid-login.
  Future<KRig> page({int n = 2, int ms = 3000, int status = 0, Params params = const Params(), bool wrap = false}) async {
    final rig = make(n, ms, status, params, wrap);
    await rig.nl.start(Page.node, node: 'Y1');
    return mid(rig);
  }

  /// Home, 3 records, Y1 and Y2 kept; then a3 advertises too and a closed link is reported gone after 2 s: the next
  /// attempt (to Y3) waits in `_makeRoom` for the link it closes there. Y3 answers its login after 3 s.
  Future<KRig> room() async {
    final rig = KRig(rust, recs: [for (var i = 1; i <= 3; i++) Rec('Y$i', 1)]);
    rig.advs = ['a1', 'a2'];
    await rig.nl.start(Page.home);
    await rig.wait(() => !rig.nl.core.roundActive, what: 'round 1 ended');
    expect((rig.nl.keptState('Y1'), rig.nl.keptState('Y2'), rig.radio.connects), (p, p, 2), reason: rig.tr);
    rig.advs = ['a1', 'a2', 'a3'];
    rig.radio.goneMs = 2000;
    rig.radio.hold[fLogin] = [3000];
    return rig;
  }

  group('T1: the node page opens mid-attempt (connect started) -> one connect, the body in the page\'s round, parked', () {
    test('(a) from home; the other node of the home round is unreachable', () async {
      final rig = await home();
      final t0 = rig.clock.t;
      rig.nl.setPage(Page.node, node: 'Y1');
      expect(rig.nl.core.running, isNull, reason: 'the page\'s round has no attempt of its own');
      expect(rig.nl.core.roundTargets, {'Y1'});
      await rig.wait(() => rig.nl.keptState('Y1') == p, what: 'parked');
      expect(rig.clock.t - t0, lessThan(3500), reason: rig.tr);
      expect((rig.radio.connects, rig.aborted, rig.gate.links), (1, 0, 1), reason: rig.tr);
      expect(rig.kindOf('Y1'), Kind.read);
      expect(rig.nl.readWall['Y1'], isNotNull, reason: '_noteRead');
      expect(rig.n('kept Y1 -> body'), 1, reason: rig.tr);
      expect(rig.kindOf('Y2'), isNot(Kind.read));
      await rig.run(20000);
      expect((rig.radio.connects, rig.gate.links), (1, 1), reason: rig.tr);
    });

    test('(b) back from a net page: Page.node -> Page.home (net_pages.dart:203) -> Page.node (:224)', () async {
      final rig = KRig(rust, readFinds: false);
      await rig.openPage(); // nothing advertises: no link
      expect(rig.radio.connects, 0);
      rig.radio.hold[fLogin] = [3000];
      rig.nl.setPage(Page.home);
      await mid(rig);
      rig.nl.setPage(Page.node, node: 'Y1');
      await rig.wait(() => rig.nl.keptState('Y1') == p, what: 'parked');
      expect((rig.radio.connects, rig.aborted, rig.n('kept Y1 -> body')), (1, 0, 1), reason: rig.tr);
      expect(rig.kindOf('Y1'), Kind.read);
    });
  });

  test('T1b: the node page opens while the attempt waits in _makeRoom (no connect yet) -> aborted, not taken over',
      () async {
    final rig = await room();
    rig.nl.refresh();
    await rig.wait(() => rig.nl.core.running?.id == 'Y3', what: 'the attempt to Y3');
    expect((rig.radio.connects, rig.gate.active), (2, 1), reason: 'not in _makeRoom\n${rig.tr}');
    rig.nl.setPage(Page.node, node: 'Y3');
    await rig.wait(() => rig.nl.keptState('Y3') == p, what: 'Y3 parked');
    expect(rig.n('kept Y3 -> body'), 0, reason: 'read by the attempt taken over\n${rig.tr}');
    expect((rig.radio.connects, rig.kindOf('Y3')), (3, Kind.read), reason: rig.tr);
  });

  test('T2: another node\'s page opens mid-attempt -> aborted', () async {
    final rig = await home();
    rig.nl.setPage(Page.node, node: 'Y2');
    await rig.run(200, adv: false);
    expect((rig.aborted, rig.gate.links, rig.s0.disposed), (1, 0, true), reason: rig.tr);
    await rig.run(5000, adv: false);
    expect(rig.n('kept Y1'), 0, reason: rig.tr);
    expect(rig.kindOf('Y1'), isNot(Kind.read));
  });

  group('T3: acquire(forNode) on the node\'s page mid-attempt -> returns after the attempt; its read is recorded; '
      'loginFor is given the kept link; one connect', () {
    Future<void> rest(KRig rig, int t0) async {
      final a = rig.acquire('操作', forNode: 'Y1', gone: () => false);
      expect(rig.nl.waitingName, '操作');
      await rig.wait(() => a.done, what: 'acquire returned');
      expect(a.lease, isNotNull, reason: rig.tr);
      expect(a.at - t0, inInclusiveRange(2500, 3500), reason: rig.tr);
      expect((rig.nl.waitingName, a.timerOver), (null, true));
      expect((rig.kindOf('Y1'), rig.nl.keptState('Y1'), rig.aborted), (Kind.read, p, 0), reason: rig.tr);
      late LoginForResult r;
      var done = false;
      unawaited(rig.nl.loginFor(a.lease!, 'Y1').then((x) {
        r = x;
        done = true;
      }));
      await rig.wait(() => done, what: 'loginFor ended');
      expect(r.end, LoginForEnd.ok, reason: rig.tr);
      expect(identical(r.handoff!.session, rig.s0), isTrue);
      expect((rig.radio.connects, rig.nSessions, rig.n('ok (kept link)')), (1, 1, 1), reason: rig.tr);
    }

    test('(a) the attempt of the page\'s own round', () async {
      final rig = await page();
      await rest(rig, rig.clock.t);
    });
    test('(b) the attempt taken over from the home round', () async {
      final rig = await home();
      final t0 = rig.clock.t;
      rig.nl.setPage(Page.node, node: 'Y1');
      await rig.run(300, adv: false);
      await rest(rig, t0);
    });
  });

  group('T4: no wait, and the attempt is aborted', () {
    Future<void> row(KRig rig, {LeaseKind kind = LeaseKind.session, String? forNode}) async {
      final t0 = rig.clock.t;
      final a = rig.acquire('操作', kind: kind, forNode: forNode, gone: () => false);
      expect((a.timer, rig.nl.waitingName), (null, null));
      await rig.wait(() => a.done, what: 'acquire returned');
      expect(a.lease, isNotNull);
      expect(a.at - t0, lessThan(1000), reason: rig.tr);
      expect((rig.aborted, rig.gate.links, rig.s0.disposed), (1, 0, true), reason: rig.tr);
      expect(rig.kindOf('Y1'), isNot(Kind.read));
    }

    test('(a) no forNode, a session lease', () async => row(await page()));
    test('(b) no forNode, a raw lease', () async => row(await page(), kind: LeaseKind.raw));
    test('(c) forNode is another node', () async => row(await page(), forNode: 'Y2'));
    test('(d) forNode is the attempt\'s node, but home is open', () async => row(await home(), forNode: 'Y1'));
    test('(e) forNode is the attempt\'s node, but another node\'s page is open (the attempt is already aborted)',
        () async {
      final rig = await home();
      rig.nl.setPage(Page.node, node: 'Y2');
      await row(rig, forNode: 'Y1');
    });
  });

  group('T4b: a call without forNode during another call\'s wait -> the attempt is aborted; one of the two gets the '
      'lease, the other null; no waiter, no timer', () {
    for (final held in [false, true]) {
      // held: the aborted attempt's probe returns late (the abort itself ends the wait, not the attempt's _run)
      test(held ? '(b) the aborted probe slow to return' : '(a)', () async {
        final rig = await page(wrap: held);
        final hold = held ? (rig.wrapped!.hold = Completer<void>()) : null;
        final a = rig.acquire('甲', forNode: 'Y1', gone: () => false);
        await rig.run(500, adv: false);
        expect((a.done, rig.nl.waitingName), (false, '甲'));
        final t0 = rig.clock.t;
        final b = rig.acquire('乙');
        await rig.wait(() => a.done && b.done, max: 3000, what: 'both returned');
        expect([a.lease, b.lease].where((l) => l != null).length, 1, reason: rig.tr);
        expect((rig.nl.waitingName, a.timerOver, b.timer), (null, true, null), reason: rig.tr);
        expect(a.at - t0, lessThan(1000));
        hold?.complete();
        await rig.run(200, adv: false);
        expect((rig.aborted, rig.kindOf('Y1') == Kind.read), (1, false), reason: rig.tr);
      });
    }
  });

  test('T5: the attempt fails during the wait -> the lease at its end (before the 8 s bound); no second wait',
      () async {
    final rig = await page(ms: 6000);
    final t0 = rig.clock.t;
    final a = rig.acquire('操作', forNode: 'Y1', gone: () => false);
    await rig.run(1000, adv: false);
    expect(a.done, isFalse);
    // the prober notices the dropped link when the held answer is due (6 s after the login frame): result=broken
    rig.radio.drop();
    await rig.wait(() => a.done, what: 'acquire returned');
    expect(a.lease, isNotNull, reason: rig.tr);
    expect(rig.n('result=broken'), 1, reason: rig.tr);
    expect(a.at - t0, inInclusiveRange(5500, 6500), reason: 'not at the attempt\'s end\n${rig.tr}');
    expect((rig.nl.waitingName, a.timerOver, rig.gate.links), (null, true, 0), reason: rig.tr);
    expect(rig.kindOf('Y1'), isNot(Kind.read));
  });

  test('T6: connected, then silent -> the lease 8 s after the call; the attempt is aborted', () async {
    final rig = await page(ms: 5000, status: -1);
    await rig.run(4000, adv: false);
    final t0 = rig.clock.t;
    final a = rig.acquire('操作', forNode: 'Y1', gone: () => false);
    await rig.wait(() => a.done, what: 'acquire returned');
    expect(rig.n('result=noResponse after 12000ms'), 1, reason: 'not aborted at the lease\n${rig.tr}');
    expect(a.lease, isNotNull, reason: rig.tr);
    expect(a.at - t0, inInclusiveRange(8000, 8300), reason: rig.tr);
    expect((rig.nl.waitingName, a.timerOver, rig.gate.links, rig.radio.connects), (null, true, 0, 1), reason: rig.tr);
  });

  test('T6b: acquire(forNode) while the attempt waits in _makeRoom -> no wait', () async {
    final rig = await room();
    rig.nl.setPage(Page.node, node: 'Y3');
    await rig.wait(() => rig.nl.core.running?.id == 'Y3', what: 'the attempt to Y3');
    expect((rig.radio.connects, rig.gate.active), (2, 1), reason: 'not in _makeRoom\n${rig.tr}');
    final a = rig.acquire('操作', forNode: 'Y3', gone: () => false);
    expect((a.timer, rig.nl.waitingName), (null, null));
    // the lease waits in _dropAll for the closing link, in real time (100 ms steps the fake clock does not drive)
    await rig.wait(() => rig.gate.active == 0, what: 'the closed link gone');
    await Future<void>.delayed(const Duration(milliseconds: 300));
    await rig.run(100);
    expect((a.done, a.lease != null), (true, true), reason: rig.tr);
    expect(rig.radio.connects, 2, reason: 'the attempt went on to its connect\n${rig.tr}');
  });

  /// Home, then Y1's page: the attempt to Y1 detached and still running (not aborted).
  Future<KRig> detached({int ms = 3000, Params params = const Params(), bool wrap = false}) async {
    final rig = await home(ms: ms, params: params, wrap: wrap);
    rig.nl.setPage(Page.node, node: 'Y1');
    await rig.run(300, adv: false);
    expect((rig.aborted, rig.gate.links), (0, 1), reason: 'not detached\n${rig.tr}');
    return rig;
  }

  final events = <String, void Function(KRig)>{
    'background': (rig) => rig.nl.background(),
    'Bluetooth off': (rig) => rig.nl.radio(bluetooth: false),
  };

  group('T7 / T8: background, or the radio blocked', () {
    for (final e in events.entries) {
      test('${e.key} while detached -> aborted at once', () async {
        final rig = await detached();
        e.value(rig);
        await rig.run(100, adv: false);
        expect((rig.aborted, rig.gate.links, rig.s0.disposed), (1, 0, true), reason: rig.tr);
        await rig.run(5000, adv: false);
        expect(rig.n('kept Y1'), 0, reason: rig.tr);
      });
      test('${e.key} during the wait -> the wait ends within one tick', () async {
        final rig = await page();
        final a = rig.acquire('操作', forNode: 'Y1', gone: () => false);
        await rig.run(500, adv: false);
        final t0 = rig.clock.t;
        e.value(rig);
        await rig.wait(() => a.done, max: 300, adv: false, what: 'acquire returned');
        expect(a.at - t0, lessThanOrEqualTo(100), reason: rig.tr);
        expect((rig.nl.waitingName, a.timerOver, rig.aborted, rig.gate.links), (null, true, 1, 0), reason: rig.tr);
      });
    }
  });

  test('T9: the record gone while detached -> aborted at the next pump', () async {
    final rig = await detached();
    rig.nl.core.setRecords([const Rec('Y2', 1)]);
    rig.nl.refresh();
    await rig.run(100, adv: false);
    expect((rig.aborted, rig.gate.links, rig.s0.disposed), (1, 0, true), reason: rig.tr);
  });

  test('T10: back to home while detached -> aborted', () async {
    final rig = await detached();
    rig.nl.setPage(Page.home);
    await rig.run(100, adv: false);
    expect((rig.aborted, rig.s0.disposed), (1, true), reason: rig.tr);
    expect(rig.n('kept Y1'), 0, reason: rig.tr);
  });

  test('T11: dispose while detached -> the link closed, the session disposed (as before the change)', () async {
    final rig = await detached();
    await rig.nl.dispose();
    await rig.run(200, adv: false); // the cancelled probe returns on the next tick and disposes its session
    expect((rig.gate.links, rig.s0.disposed, rig.n('kept Y1')), (0, true, 0), reason: rig.tr);
  });

  test('T11b: dispose during the wait -> null, no timer, no waiter', () async {
    final rig = await page();
    final a = rig.acquire('操作', forNode: 'Y1', gone: () => false);
    await rig.run(500, adv: false);
    final f = rig.nl.dispose();
    await rig.wait(() => a.done, max: 300, adv: false, what: 'acquire returned');
    expect((a.lease, rig.nl.waitingName, a.timerOver), (null, null, true), reason: rig.tr);
    await f;
  });

  group('T12: the detached attempt ends without a body', () {
    int attempts(KRig rig) => rig.n('attempt a1×Y1 connected=');

    test('(a) an error code -> recorded, not parked; then the round\'s own login; as many attempts in all as a round '
        'whose own first login got the error code', () async {
      final rig = await home();
      rig.s0.row = "2'";
      rig.nl.setPage(Page.node, node: 'Y1');
      await rig.wait(() => !rig.nl.core.roundActive, what: 'the page round ended');
      expect((rig.n('kept Y1 -> errorCode'), rig.s0.disposed), (1, true), reason: rig.tr);
      // the same round without the detached attempt: its own first login answers with the error code
      final c = await page();
      c.s0.row = "2'";
      await c.wait(() => !c.nl.core.roundActive, what: 'the control round ended');
      expect(attempts(c), 2, reason: c.tr);
      expect((attempts(rig), rig.radio.connects, rig.kindOf('Y1')), (attempts(c), c.radio.connects, Kind.read),
          reason: rig.tr);
      expect(rig.n('a1×Y1 -> body'), 1, reason: rig.tr);
    });
    test('(b) no response -> nothing recorded; the round\'s own attempt starts at once', () async {
      final rig = await home(ms: -1);
      rig.nl.setPage(Page.node, node: 'Y1');
      await rig.wait(() => rig.n('result=noResponse') == 1, adv: false, what: 'the detached attempt ended');
      final t0 = rig.clock.t;
      await rig.wait(() => rig.kindOf('Y1') == Kind.read, what: 'read by the round\'s own attempt');
      expect(rig.clock.t - t0, lessThan(1000), reason: rig.tr);
      expect((rig.n('kept Y1'), attempts(rig), rig.radio.connects), (0, 2, 2), reason: rig.tr);
    });
  });

  test('T14: the page round\'s own attempt cut at the cap -> aborted', () async {
    final rig = await page(ms: 5000, params: const Params(cap: 2000));
    await rig.run(2200, adv: false);
    expect((rig.aborted, rig.gate.links, rig.s0.disposed), (1, 0, true), reason: rig.tr);
    expect(rig.n('cut at the cap'), 1, reason: rig.tr);
  });

  test('T14b: refresh on the node page while detached -> no new round, not aborted, its body in the page\'s round',
      () async {
    final rig = await detached();
    final rounds = rig.n(' full [');
    rig.nl.refresh();
    await rig.wait(() => rig.nl.keptState('Y1') == p, what: 'parked');
    expect((rig.n(' full ['), rig.aborted, rig.radio.connects), (rounds, 0, 1), reason: rig.tr);
    expect((rig.n('kept Y1 -> body'), rig.kindOf('Y1')), (1, Kind.read), reason: rig.tr);
  });

  group('T14c: the page\'s round ended (cap) before the detached attempt answers', () {
    const cap = Params(cap: 1000);
    test('(a) no round active -> nothing recorded, the session destroyed', () async {
      final rig = await detached(params: cap);
      await rig.wait(() => !rig.nl.core.roundActive, max: 1500, adv: false, what: 'the page round ended');
      await rig.wait(() => rig.n('result=body') == 1, adv: false, what: 'the detached attempt answered');
      await rig.run(200, adv: false);
      expect((rig.n('kept Y1'), rig.gate.links, rig.s0.disposed), (0, 0, true), reason: rig.tr);
      expect(rig.kindOf('Y1'), isNot(Kind.read));
    });
    test('(b) a next round for the node active -> recorded there, parked', () async {
      final rig = await detached(params: cap);
      await rig.wait(() => !rig.nl.core.roundActive, max: 1500, adv: false, what: 'the page round ended');
      await rig.until(2400, adv: false); // the next round (1 s, cap) is active when the answer comes (3.1 s)
      rig.nl.refresh();
      expect(rig.nl.core.roundTargets, {'Y1'}, reason: rig.tr);
      await rig.wait(() => rig.nl.keptState('Y1') == p, adv: false, what: 'parked');
      expect((rig.n('kept Y1 -> body'), rig.kindOf('Y1'), rig.radio.connects), (1, Kind.read, 1), reason: rig.tr);
    });
  });

  group('T15: a second acquire(forNode) during the wait', () {
    test('(T15) the first gone -> the first null, the second the lease', () async {
      final rig = await page();
      var g1 = false;
      final a = rig.acquire('甲', forNode: 'Y1', gone: () => g1);
      await rig.run(500, adv: false);
      g1 = true;
      final b = rig.acquire('乙', forNode: 'Y1', gone: () => false);
      expect((b.timer != null, rig.nl.waitingName), (true, '乙'));
      await rig.wait(() => a.done && b.done, what: 'both returned');
      expect((a.lease, b.lease != null, rig.nl.waitingName), (null, true, null), reason: rig.tr);
      expect((rig.aborted, rig.kindOf('Y1'), rig.nl.keptState('Y1')), (0, Kind.read, p), reason: rig.tr);
    });
    test('(T15b) the first not gone -> the second null at once, the first the lease', () async {
      final rig = await page();
      final a = rig.acquire('甲', forNode: 'Y1', gone: () => false);
      await rig.run(500, adv: false);
      final b = rig.acquire('乙', forNode: 'Y1', gone: () => false);
      await rig.run(100, adv: false);
      expect((b.done, b.lease, b.timer, rig.nl.waitingName, a.done), (true, null, null, '甲', false), reason: rig.tr);
      await rig.wait(() => a.done, what: 'the first returned');
      expect((a.lease != null, rig.aborted, rig.kindOf('Y1')), (true, 0, Kind.read), reason: rig.tr);
    });
    test('(T15c) the only waiter gone during the wait -> null on wake; no cancel, no lease', () async {
      final rig = await page();
      var g = false;
      final a = rig.acquire('甲', forNode: 'Y1', gone: () => g);
      await rig.run(500, adv: false);
      g = true;
      final cancelled = rig.n('cancelled');
      await rig.wait(() => a.done, what: 'acquire returned');
      await rig.run(200, adv: false);
      expect((a.lease, rig.nl.waitingName, rig.reg.current, a.timerOver), (null, null, null, true), reason: rig.tr);
      expect((rig.n('cancelled'), rig.aborted, rig.nl.keptState('Y1'), rig.kindOf('Y1')), (cancelled, 0, p, Kind.read),
          reason: rig.tr);
    });
  });

  test('T16: after a detached attempt was aborted, the next attempt\'s result goes through the core as usual',
      () async {
    final rig = await detached();
    rig.nl.setPage(Page.home);
    await rig.run(100, adv: false);
    expect(rig.aborted, 1, reason: rig.tr);
    await rig.wait(() => rig.kindOf('Y1') == Kind.read, what: 'Y1 read again');
    expect((rig.n('kept Y1'), rig.n('a1×Y1 -> body'), rig.radio.connects), (0, 1, 2), reason: rig.tr);
  });

  test('T17: an aborted attempt\'s late end leaves the next, detached attempt and its waiter alone', () async {
    final rig = await home(wrap: true);
    final late = rig.wrapped!.hold = Completer<void>();
    rig.nl.setPage(Page.node, node: 'Y2'); // A aborted; its probe returns into the hold
    await rig.run(300, adv: false);
    expect(rig.gate.links, 0, reason: rig.tr);
    rig.radio.hold[fLogin] = [3000];
    rig.nl.setPage(Page.home);
    await rig.wait(() => rig.radio.written.where((f) => f == fLogin).length == 2, what: 'B\'s login frame');
    rig.nl.setPage(Page.node, node: 'Y1'); // B detached
    var g1 = false;
    final w1 = rig.acquire('甲', forNode: 'Y1', gone: () => g1);
    await rig.run(300, adv: false);
    late.complete(); // A's _run ends now
    await rig.run(200, adv: false);
    expect((w1.done, rig.nl.waitingName, rig.gate.links, rig.radio.connects), (false, '甲', 1, 2), reason: rig.tr);
    g1 = true;
    final w2 = rig.acquire('乙', forNode: 'Y1', gone: () => false);
    expect(w2.timer, isNotNull, reason: 'B no longer waited for\n${rig.tr}');
    await rig.wait(() => w1.done && w2.done, what: 'both returned');
    expect((w1.lease, w2.lease != null, rig.n('kept Y1 -> body'), rig.kindOf('Y1')), (null, true, 1, Kind.read),
        reason: rig.tr);
  });

  // O3 (§7): the app's busy name (opBusyName, what opDeps prints) of a call refused during a wait; the rig's own
  // busyName would hide it. The "lease held" half passes on main (a regression pin).
  test('O3: a once refused during another call\'s wait, page alive -> busy with the waiter\'s name', () async {
    final rig = await page();
    final d = OpDeps(
        acquire: rig.d.acquire,
        busyName: () => opBusyName(rig.reg, rig.nl),
        login: rig.d.login,
        console: rig.d.console,
        keepScreen: rig.d.keepScreen);
    final w = rig.acquire('手機 Wi-Fi', forNode: 'Y1', gone: () => false);
    await rig.run(300, adv: false);
    final r = <OpReply>[];
    unawaited(OpSession.once(d, 'Y1', '國家', (c, gone) => c.settings(), gone: () => false).then(r.add));
    await rig.run(100, adv: false);
    expect((r.single.end, r.single.busyName, w.done), (OpEnd.busy, '手機 Wi-Fi', false), reason: rig.tr);
    await rig.wait(() => w.done, what: 'the waiter got the lease');
    unawaited(OpSession.once(d, 'Y1', '國家', (c, gone) => c.settings(), gone: () => false).then(r.add));
    await rig.run(100, adv: false);
    expect((r.length, r.last.end, r.last.busyName), (2, OpEnd.busy, '手機 Wi-Fi'), reason: rig.tr);
    await w.lease!.release();
  });

  // Review A M1: the app's acquire (opAcquire, what opDeps passes) forwards the node and gone to the wait.
  // Negative control: opAcquire calling `link.acquire(name, LeaseKind.session)` -> FAIL.
  test('O3b: the app\'s acquire waits for the attempt to the page\'s node', () async {
    final rig = await page();
    final r = <Lease?>[];
    unawaited(opAcquire(rig.nl)('手機 Wi-Fi', forNode: 'Y1', gone: () => false).then(r.add));
    await rig.run(300, adv: false);
    expect((rig.nl.waitingName, r.length, rig.aborted), ('手機 Wi-Fi', 0, 0), reason: rig.tr);
    await rig.wait(() => r.isNotEmpty, what: 'the lease after the attempt');
    expect((r.single != null, rig.kindOf('Y1'), rig.nl.keptState('Y1')), (true, Kind.read, p), reason: rig.tr);
    await r.single!.release();
  });
}
