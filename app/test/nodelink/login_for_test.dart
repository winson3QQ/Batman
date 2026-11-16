// #329 PR 3 §2.1: NodeLink.loginFor drives core.LoginFor under a session lease — its own scan (woken by new
// addresses, rescanned when the radio ends it, the 60 s from the scan's real start), one link at a time, the 60 s cut,
// the preconditions, the hand-off. Fake radio, fake login prober, manual clock.
import 'dart:async';

import 'package:batman_app/src/nodelink/ble_gate.dart';
import 'package:batman_app/src/nodelink/core.dart';
import 'package:batman_app/src/nodelink/handoff.dart';
import 'package:batman_app/src/nodelink/lease.dart';
import 'package:batman_app/src/nodelink/node_link.dart';
import 'package:flutter_test/flutter_test.dart';

import 'node_link_test.dart' show Clock, Radio, FakeProber;

/// By address: `ok` logs in (a hand-off), `not` is 解不開, `cert` is 身分不符, `hang` waits until cancelled.
class LoginProber implements Prober {
  LoginProber(this.by);
  final Map<String, String> by;
  final List<String> probes = [];
  void Function()? beforeOk; // runs just before an ok hand-off (e.g. the lease taken back)
  final handed = <LoginHandoff>[];

  @override
  Future<Outcome> probe(GateLink link, String id, {required Future<void> due, required Future<void> cancelled}) async {
    probes.add(link.address);
    switch (by[link.address]) {
      case 'ok':
        beforeOk?.call();
        final h = LoginHandoff(id: id, link: link, inbox: FrameInbox());
        handed.add(h);
        return Outcome(Res.body, '', h);
      case 'cert':
        return const Outcome(Res.certRejected);
      case 'hang':
        await cancelled;
        return const Outcome(Res.noResponse);
      default:
        return const Outcome(Res.undecryptable);
    }
  }
}

class Rig {
  Rig(this.by, {this.keys = true, Future<List<Rec>> Function()? read}) {
    reg = LeaseRegistry(after: clock.after);
    gate = BleGate(radio, reg, now: () => clock.t, after: clock.after);
    nl = NodeLink(
      core: NodeLinkCore(const [Rec('Y1', 1)]),
      gate: gate,
      reg: reg,
      prober: FakeProber({}),
      readRecords: read ?? () async => const [Rec('Y1', 1)],
      now: () => clock.t,
      after: clock.after,
      loginProber: prober,
      keysOk: () async => keys,
    );
  }
  final Map<String, String> by;
  bool keys;
  final clock = Clock();
  final radio = Radio();
  late final LoginProber prober = LoginProber(by);
  late final LeaseRegistry reg;
  late final BleGate gate;
  late final NodeLink nl;

  Future<Lease> lease() async {
    await nl.start(Page.other);
    return (await nl.acquire('建立網路', LeaseKind.session))!;
  }

  /// Starts loginFor, sends [addrs] from the scan, and runs the clock until it ends (or [ms] passes).
  Future<LoginForResult?> login(Lease l, {List<String> addrs = const [], int ms = 70000, bool clearNotY = false}) async {
    LoginForResult? r;
    unawaited(nl.loginFor(l, 'Y1', clearNotY: clearNotY).then((x) => r = x));
    await clock.run(300);
    for (final a in addrs) {
      radio.scanCtl.add(a);
    }
    for (var t = 0; t < ms && r == null; t += 500) {
      await clock.run(500);
    }
    return r;
  }
}

void main() {
  test('logs in: the scan finds the node, the session is handed over, its link stays open; nothing else is', () async {
    final rig = Rig({'a1': 'ok'});
    final l = await rig.lease();
    final r = await rig.login(l, addrs: ['a1']);
    expect(r!.end, LoginForEnd.ok);
    expect(r.handoff!.id, 'Y1');
    expect((rig.gate.links, rig.gate.scans), (1, 0), reason: 'the hand-off keeps its link; the scan is stopped');
    await r.handoff!.close();
    expect(rig.gate.links, 0);
  });

  test('a wrong node first: its link is closed before the next attempt, never two links', () async {
    final rig = Rig({'a1': 'not', 'a2': 'ok'});
    final l = await rig.lease();
    var maxOpen = 0;
    final sub = Stream<void>.periodic(Duration.zero).listen((_) {
      if (rig.radio.open > maxOpen) maxOpen = rig.radio.open;
    });
    final r = await rig.login(l, addrs: ['a1', 'a2']);
    await sub.cancel();
    expect(r!.end, LoginForEnd.ok);
    expect(rig.prober.probes, ['a1', 'a2']);
    expect(maxOpen, lessThanOrEqualTo(1));
    expect(rig.gate.refused, isEmpty);
    await r.handoff!.close();
  });

  test('a new address wakes the login at once (not at the next deadline)', () async {
    final rig = Rig({'a1': 'ok'});
    final l = await rig.lease();
    LoginForResult? r;
    unawaited(rig.nl.loginFor(l, 'Y1').then((x) => r = x));
    await rig.clock.run(5000);
    expect(r, isNull);
    rig.radio.scanCtl.add('a1');
    await rig.clock.run(200);
    expect(r?.end, LoginForEnd.ok);
    await r!.handoff!.close();
  });

  test('60 s with no node: notFound, the scan stopped, no link left', () async {
    final rig = Rig({});
    final l = await rig.lease();
    LoginForResult? r;
    unawaited(rig.nl.loginFor(l, 'Y1').then((x) => r = x));
    await rig.clock.run(59000);
    expect(r, isNull, reason: 'not before 60 s');
    await rig.clock.run(2000);
    expect(r?.end, LoginForEnd.notFound);
    expect((rig.gate.scans, rig.gate.links), (0, 0));
  });

  test('the 60 s start when the scan really starts: a wait for a scan slot is not counted', () async {
    final rig = Rig({});
    final l = await rig.lease();
    for (var i = 0; i < 4; i++) {
      rig.gate.noteScanStart(); // 4 starts in the last 30 s: the next waits ~30 s
    }
    LoginForResult? r;
    unawaited(rig.nl.loginFor(l, 'Y1').then((x) => r = x));
    await rig.clock.run(75000);
    expect(r, isNull, reason: '30 s waiting for the slot + less than 60 s');
    await rig.clock.run(20000);
    expect(r?.end, LoginForEnd.notFound);
  });

  test('60 s cut the running attempt and close its link', () async {
    final rig = Rig({'a1': 'hang'});
    final l = await rig.lease();
    final r = await rig.login(l, addrs: ['a1']);
    expect(r!.end, LoginForEnd.notFound);
    expect(rig.gate.links, 0);
  });

  test('Bluetooth off during the login: precondition at once, the attempt cut', () async {
    final rig = Rig({'a1': 'hang'});
    final l = await rig.lease();
    LoginForResult? r;
    unawaited(rig.nl.loginFor(l, 'Y1').then((x) => r = x));
    await rig.clock.run(300);
    rig.radio.scanCtl.add('a1');
    await rig.clock.run(1000);
    expect(rig.gate.links, 1);
    rig.nl.radio(bluetooth: false);
    await rig.clock.run(300);
    expect(r?.end, LoginForEnd.precondition);
    expect(rig.gate.links, 0);
  });

  test('keys read live before the login: unusable -> precondition, and 2.4 shown', () async {
    final rig = Rig({'a1': 'ok'}, keys: false);
    final l = await rig.lease();
    final r = await rig.login(l, addrs: ['a1']);
    expect(r!.end, LoginForEnd.precondition);
    expect(rig.nl.core.blocked, Why.keys);
    expect(rig.prober.probes, isEmpty);
  });

  test('身分不符 ends the login (identity), its link closed', () async {
    final rig = Rig({'a1': 'cert'});
    final l = await rig.lease();
    final r = await rig.login(l, addrs: ['a1']);
    expect(r!.end, LoginForEnd.identity);
    expect(rig.gate.links, 0);
  });

  test('the radio ends the scan: a new one is started and the login goes on', () async {
    final rig = Rig({'a1': 'ok'});
    final l = await rig.lease();
    LoginForResult? r;
    unawaited(rig.nl.loginFor(l, 'Y1').then((x) => r = x));
    await rig.clock.run(300);
    final n = rig.radio.scans;
    rig.radio.scanCtl.addError('scan failed');
    await rig.clock.run(3000);
    expect(rig.radio.scans, n + 1);
    rig.radio.scanCtl.add('a1');
    await rig.clock.run(500);
    expect(r?.end, LoginForEnd.ok);
    await r!.handoff!.close();
  });

  test('clearNotY: a node memoed 「不是 Y1」 is tried again (再試這一台)', () async {
    final rig = Rig({'a1': 'ok'});
    final l = await rig.lease();
    (rig.nl.core.notY['a1'] ??= {}).add('Y1');
    final r1 = await rig.login(l, addrs: ['a1'], ms: 70000);
    expect(r1?.end, LoginForEnd.notFound, reason: 'without clearNotY the memo keeps a1 out');
    expect(rig.prober.probes, isEmpty);
    final r2 = await rig.login(l, addrs: ['a1'], clearNotY: true);
    expect(r2!.end, LoginForEnd.ok);
    await r2.handoff!.close();
  });

  test('not the current session lease -> noLease; a raw lease too', () async {
    final rig = Rig({'a1': 'ok'});
    await rig.nl.start(Page.other);
    final raw = (await rig.nl.acquire('新增節點', LeaseKind.raw))!;
    expect((await rig.nl.loginFor(raw, 'Y1')).end, LoginForEnd.noLease);
    await raw.release();
    await rig.clock.run(500);
    expect((await rig.nl.loginFor(raw, 'Y1')).end, LoginForEnd.noLease, reason: 'a released lease');
  });

  test('the lease taken back during the login -> noLease, no link left', () async {
    final rig = Rig({'a1': 'hang'});
    final l = await rig.lease();
    LoginForResult? r;
    unawaited(rig.nl.loginFor(l, 'Y1').then((x) => r = x));
    await rig.clock.run(300);
    rig.radio.scanCtl.add('a1');
    await rig.clock.run(1000);
    l.pageGone(); // idle: released at once
    await rig.clock.run(500);
    expect(r?.end, LoginForEnd.noLease);
    expect(rig.gate.links, 0);
  });


  test('code review A M03: a login handed over after its lease ended is closed, never returned', () async {
    final rig = Rig({'a1': 'ok'});
    final l = await rig.lease();
    rig.prober.beforeOk = l.pageGone; // idle: released now
    final r = await rig.login(l, addrs: ['a1']);
    expect(r!.end, LoginForEnd.noLease);
    expect(rig.prober.handed.single.closed, isTrue, reason: 'the session handed over too late is closed by loginFor');
  });
  test("P7: acquire waits for the last release's record read (at most 5 s) before taking the radio", () async {
    final slow = Completer<List<Rec>>();
    var reads = 0;
    final rig = Rig({}, read: () {
      reads++;
      return reads == 1 ? Future.value(const [Rec('Y1', 1)]) : slow.future;
    });
    final l = await rig.lease();
    await l.release();
    Lease? next;
    var done = false;
    unawaited(rig.nl.acquire('加入網路', LeaseKind.session).then((x) {
      next = x;
      done = true;
    }));
    await rig.clock.run(500);
    expect(done, isFalse, reason: 'the record read of the release has not ended');
    slow.complete(const [Rec('Y1', 1)]);
    await rig.clock.run(200);
    expect(next, isNotNull);
  });
}
