// #329 PR 1 review (review-pr1-A.md / review-pr1-B.md): each finding's scenario as a regression test. RA-* / RB-* are
// the reviewers' negative controls (they failed on 75683ab); the rest guard rules whose mutations survived.
import 'dart:async';

import 'package:batman_app/src/nodelink/app_link.dart' show bleStatusToRadio, wireRadio, keyErrorToRadio;
import 'package:batman_app/src/nodelink/ble_gate.dart';
import 'package:batman_app/src/nodelink/core.dart';
import 'package:batman_app/src/nodelink/lease.dart';
import 'package:batman_app/src/nodelink/node_link.dart';
import 'package:flutter/material.dart' hide Page, Radio;
import 'package:flutter/services.dart' show PlatformException;
import 'package:batman_app/src/nodelink/raw_use.dart';
import 'package:flutter_reactive_ble/flutter_reactive_ble.dart' show BleStatus;
import 'package:flutter_test/flutter_test.dart';

import 'node_link_test.dart' show Clock, Radio, FakeProber;

/// The first probe sits in a platform call that ignores `cancelled` (Keystore), then touches its closed link; later
/// probes hold until released or cancelled.
class StickyProber implements Prober {
  final calls = <String>[];
  final keystore = Completer<void>();
  final links = <GateLink>[];
  Completer<void> hold = Completer<void>();
  @override
  Future<Outcome> probe(GateLink link, String id, {required Future<void> due, required Future<void> cancelled}) async {
    calls.add('${link.address}×$id');
    links.add(link);
    if (calls.length == 1) {
      await keystore.future;
      await link.requestMtu(517); // Refused: the link was dropped by the cancel
      return const Outcome(Res.body, 'green');
    }
    await Future.any([hold.future, cancelled]);
    return link.open ? const Outcome(Res.body, 'green') : const Outcome(Res.noResponse);
  }
}

class MapProber implements Prober {
  Map<String, Outcome> out = {};
  @override
  Future<Outcome> probe(GateLink link, String id, {required Future<void> due, required Future<void> cancelled}) async =>
      out['${link.address}|$id'] ?? const Outcome(Res.undecryptable);
}

/// Holds the attempt on [holdAddr] until cancelled.
class HoldOn implements Prober {
  HoldOn(this.holdAddr, this.owner);
  final String holdAddr;
  final Map<String, String> owner;
  @override
  Future<Outcome> probe(GateLink link, String id, {required Future<void> due, required Future<void> cancelled}) async {
    if (link.address == holdAddr) {
      await cancelled;
      return const Outcome(Res.noResponse);
    }
    return owner[link.address] == id ? const Outcome(Res.body, 'green') : const Outcome(Res.undecryptable);
  }
}

/// The stack reports a disconnect 300 ms after the cancel (M-1 measured 3-14 ms).
class SlowDiscRadio extends Radio {
  SlowDiscRadio(this.clock);
  final Clock clock;
  final _st = StreamController<(String, bool)>.broadcast(sync: true);
  @override
  Stream<(String, bool)> get linkStates => _st.stream;
  @override
  Stream<bool> connect(String address, Duration timeout) {
    connects++;
    late StreamController<bool> c;
    c = StreamController<bool>(onCancel: () {
      clock.after(const Duration(milliseconds: 300), () => _st.add((address, false)));
    });
    scheduleMicrotask(() => c.add(true));
    return c.stream;
  }
}

/// A scan whose cancel takes 20 ms on the platform.
class SlowStopRadio extends Radio {
  @override
  Stream<String> scan() {
    scans++;
    return StreamController<String>(onCancel: () => Future<void>.delayed(const Duration(milliseconds: 20))).stream;
  }
}

/// Scans fail at once (Bluetooth off).
class FailingScanRadio extends Radio {
  @override
  Stream<String> scan() {
    scans++;
    return Stream<String>.error(Exception('bluetooth off'));
  }
}

(NodeLink, Clock, LeaseRegistry, BleGate) make(BleBackend radio, Prober p, ReadRecords read,
    {List<Rec> recs = const [Rec('Y1', 1)], Clock? clock}) {
  final c = clock ?? Clock();
  final reg = LeaseRegistry(after: c.after);
  final gate = BleGate(radio, reg, now: () => c.t, after: c.after);
  final nl = NodeLink(
      core: NodeLinkCore(recs), gate: gate, reg: reg, prober: p, readRecords: read, now: () => c.t, after: c.after);
  return (nl, c, reg, gate);
}

void main() {
  test('RA-1 / RB-2: a cut attempt that returns late does not close the next attempt\x27s link', () async {
    final radio = Radio();
    final p = StickyProber();
    final (nl, clock, _, gate) = make(radio, p, () async => const [Rec('Y1', 1)]);
    await nl.start(Page.home);
    await clock.run(500);
    radio.scanCtl.add('a1');
    await clock.run(1000);
    expect(p.calls, hasLength(1));
    nl.background(); // attempt A cut while it sits in Keystore
    await clock.run(200);
    nl.foreground();
    await clock.run(500);
    radio.scanCtl.add('a1');
    await clock.run(1000);
    expect(p.calls, hasLength(2), reason: nl.core.log.join('\n'));
    final b = p.links[1];
    p.keystore.complete(); // A ends now
    await clock.run(300);
    expect((b.open, gate.links), (true, 1), reason: 'A must not close the link of B');
    p.hold.complete();
    await clock.run(300);
    expect(nl.core.states['Y1']!.kind, Kind.read);
  });

  test('RA-2 / A-M2: a record rewritten under a raw lease (not reported by the page) ends 身分不符', () async {
    var recs = [const Rec('Y1', 1)];
    final radio = Radio();
    final p = MapProber()..out = {'a1|Y1': const Outcome(Res.certRejected)};
    final (nl, clock, _, _) = make(radio, p, () async => recs, recs: recs);
    await nl.start(Page.home);
    await clock.run(500);
    radio.scanCtl.add('a1');
    await clock.run(2000);
    expect(nl.core.states['Y1']!.why, Why.identity);
    // ClaimPage re-claims the re-flashed node: a new record file (new time); the page reports nothing
    final l = (await nl.acquire('新增節點', LeaseKind.raw))!;
    recs = [const Rec('Y1', 2)];
    p.out = {'a1|Y1': const Outcome(Res.body, 'green')};
    l.pageGone();
    await clock.run(7000);
    radio.scanCtl.add('a1');
    await clock.run(2000);
    expect(nl.core.states['Y1']!.kind, Kind.read, reason: nl.core.log.join('\n'));
  });

  test('RA-3 / B-M5 / T-L4: Bluetooth off -> 2.3 at once, the scan error is handled, no tight loop', () async {
    final errors = <Object>[];
    late NodeLink nl;
    late FailingScanRadio radio;
    await runZonedGuarded(() async {
      radio = FailingScanRadio();
      final r = make(radio, MapProber(), () async => const [Rec('Y1', 1)]);
      nl = r.$1;
      final clock = r.$2;
      await nl.start(Page.home);
      await clock.run(3000);
      final (bt, perm) = bleStatusToRadio(BleStatus.poweredOff); // AppLink's status stream
      nl.radio(bluetooth: bt, permission: perm);
      expect(nl.core.shownWhy('Y1'), Why.bluetoothOff);
      await clock.run(60000);
      expect(nl.core.shownWhy('Y1'), Why.bluetoothOff);
      final (bt2, perm2) = bleStatusToRadio(BleStatus.ready);
      nl.radio(bluetooth: bt2, permission: perm2);
      expect(nl.core.roundActive, isTrue, reason: 'Bluetooth back on: a round at once');
    }, (e, s) => errors.add(e));
    expect(errors, isEmpty, reason: 'a scan error is never an uncaught error');
    expect(radio.scans, lessThan(40), reason: 'a failing scan is retried after 2 s, not in a loop');
  });

  test('T-L5: permission withdrawn -> 2.2; unknown / location states change nothing', () async {
    final (nl, clock, _, _) = make(Radio(), MapProber(), () async => const [Rec('Y1', 1)]);
    await nl.start(Page.home);
    await clock.run(500);
    for (final s in [BleStatus.unknown, BleStatus.locationServicesDisabled, BleStatus.unsupported]) {
      expect(bleStatusToRadio(s), (null, null));
    }
    final (bt, perm) = bleStatusToRadio(BleStatus.unauthorized);
    nl.radio(bluetooth: bt, permission: perm);
    expect(nl.core.shownWhy('Y1'), Why.noPermission);
    expect(nl.core.roundActive, isFalse);
  });

  test('RA-5 / RB-1: a release whose record read lands after the next lease was taken keeps NodeLink out', () async {
    final radio = Radio();
    Completer<List<Rec>>? pending;
    const recs = [Rec('Y1', 1)];
    final (nl, clock, reg, gate) =
        make(radio, FakeProber({'a1': 'Y1'}), () => pending?.future ?? Future.value(recs));
    await nl.start(Page.home);
    await clock.run(500);
    final l1 = (await nl.acquire('我的節點', LeaseKind.raw))!;
    final read = pending = Completer<List<Rec>>();
    await l1.release();
    final l2 = await nl.acquire('新增節點', LeaseKind.raw);
    expect(l2, isNotNull);
    final scans = radio.scans;
    read.complete(recs);
    await clock.run(10000);
    expect((nl.core.lease, radio.scans), (true, scans));
    expect(reg.nodeLinkToken, isNull, reason: 'NodeLink has no token while a lease is held');
    pending = null;
    await l2!.release();
    await clock.run(7000);
    expect(nl.core.lease, isFalse);
    expect(gate.scans, 1, reason: 'after the last release NodeLink reads again');
  });

  test('A-m6: records that cannot be read after a release: the old list, NodeLink goes on', () async {
    var fail = false;
    final (nl, clock, _, _) =
        make(Radio(), FakeProber({}), () async => fail ? throw StateError('io') : const [Rec('Y1', 1)]);
    await nl.start(Page.home);
    final l = (await nl.acquire('x', LeaseKind.raw))!;
    fail = true;
    await l.release();
    await clock.run(7000);
    expect(nl.core.lease, isFalse);
    expect(nl.core.states.keys, ['Y1']);
    expect(nl.core.roundActive, isTrue);
  });

  test('RB-3 / B-m1: an attempt never starts while the cut attempt\x27s link is still closing', () async {
    final clock = Clock();
    final radio = SlowDiscRadio(clock);
    const recs = [Rec('Y1', 2), Rec('Y2', 1)];
    final (nl, _, _, gate) = make(radio, HoldOn('a3', {'a1': 'Y1'}), () async => recs, recs: recs, clock: clock);
    await nl.start(Page.home);
    await clock.run(500);
    radio.scanCtl.add('a1');
    await clock.run(42000); // Y1 read, Y2 not found -> an early round 10 s later
    radio.scanCtl.add('a3');
    await clock.run(2000);
    expect(nl.core.roundIsEarly, isTrue, reason: nl.core.log.join('\n'));
    expect(gate.links, 1);
    nl.refresh(); // the early round is cut, a full round starts
    radio.scanCtl.add('a1');
    await clock.run(1000);
    expect(gate.refused, isEmpty, reason: '${gate.refused}\n${nl.core.log.join('\n')}');
  });

  test('RB-5 / B-M4: a refused scan start is retried later, never in the same microtask', () async {
    final radio = SlowStopRadio();
    final (nl, clock, _, gate) = make(radio, FakeProber({}), () async => const [Rec('Y1', 1)]);
    await nl.start(Page.home);
    await clock.run(500);
    nl.background();
    nl.foreground();
    final sw = Stopwatch()..start();
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(sw.elapsedMilliseconds, lessThan(1000));
    expect(gate.refused.length, lessThan(5));
    await clock.run(2000);
    expect(gate.scans, 1, reason: 'the scan starts once the old one is stopped');
  });

  test('B-M6a: acquire returns only once the round\x27s link is gone (the stack says so)', () async {
    final clock = Clock();
    final radio = SlowDiscRadio(clock);
    final p = StickyProber()..keystore.complete();
    final (nl, _, _, gate) = make(radio, HoldOn('a1', {}), () async => const [Rec('Y1', 1)], clock: clock);
    await nl.start(Page.home);
    await clock.run(500);
    radio.scanCtl.add('a1');
    await clock.run(1000);
    expect(gate.links, 1);
    var done = false;
    final f = nl.acquire('建立網路', LeaseKind.session).then((l) {
      done = true;
      return l;
    });
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect((done, gate.links), (false, 1), reason: 'the disconnect has not been reported yet');
    await clock.run(400);
    final l = await f;
    expect((l != null, gate.links), (true, 0));
    expect(p.calls, isEmpty);
  });

  test('A-M4: one 8 s budget from the connect to msg2 (a 7 s connect leaves 1 s)', () async {
    final clock = Clock();
    final radio = _LateConnect(clock, const Duration(seconds: 7));
    var sawDue = -1;
    final p = _DueWatch(() => sawDue = clock.t);
    final (nl, _, _, _) = make(radio, p, () async => const [Rec('Y1', 1)], clock: clock);
    await nl.start(Page.home);
    await clock.run(500);
    final start = clock.t;
    radio.scanCtl.add('a1');
    await clock.run(10000);
    expect(sawDue - start, inInclusiveRange(7900, 8300), reason: 'the deadline counts from the connect');
  });

  test('B-m5 / M10 / M14: the gate checks the token on GATT and after a scan-slot wait', () async {
    final clock = Clock();
    final reg = LeaseRegistry(after: clock.after);
    final radio = Radio();
    final gate = BleGate(radio, reg, now: () => clock.t, after: clock.after);
    final link = gate.connect(reg.nodeLinkToken, 'a1');
    await clock.run(100);
    final l = reg.acquire('建立網路', LeaseKind.session)!; // the link is not closed yet
    expect(() => link.read(Char.ctrl), throwsA(isA<Refused>()));
    await link.close();
    await l.release();
    for (var i = 0; i < 4; i++) {
      gate.noteScanStart(); // an older page's scans count (A-m7)
    }
    final waiting = expectLater(gate.scan(reg.nodeLinkToken, (_) {}), throwsA(isA<Refused>()));
    reg.acquire('新增節點', LeaseKind.raw);
    await clock.run(31000);
    await waiting;
    expect(radio.scans, 0);
  });

  test('A-m9 / B-m3: repeated advertisements of an address do not re-plan or redraw', () async {
    final radio = Radio();
    final (nl, clock, _, _) = make(radio, FakeProber({}), () async => const [Rec('Y1', 1)]);
    await nl.start(Page.home);
    await clock.run(500);
    radio.scanCtl.add('b1'); // a foreign device: two tries, then nothing to do (no attempt running)
    await clock.run(20000);
    expect(nl.core.roundActive, isTrue);
    var n = 0;
    final sub = nl.changed.listen((_) => n++);
    for (var i = 0; i < 200; i++) {
      radio.scanCtl.add('b1');
    }
    await Future<void>.delayed(Duration.zero);
    expect(n, 0, reason: 'repeats of a known address change nothing');
    radio.scanCtl.add('b2');
    await Future<void>.delayed(Duration.zero);
    expect(n, greaterThan(0), reason: 'a new address is planned');
    await sub.cancel();
  });

  test('T20: lifecycle mapping — inactive is not the background', () async {
    final (nl, clock, _, _) = make(Radio(), FakeProber({}), () async => const [Rec('Y1', 1)]);
    await nl.start(Page.home);
    await clock.run(500);
    nl.lifecycle(AppLifecycleState.inactive);
    expect(nl.core.roundActive, isTrue);
    for (final s in [AppLifecycleState.paused, AppLifecycleState.hidden, AppLifecycleState.detached]) {
      nl.lifecycle(AppLifecycleState.resumed);
      expect(nl.core.roundActive, isTrue);
      nl.lifecycle(s);
      expect(nl.core.roundActive, isFalse, reason: '$s');
    }
  });

  testWidgets('A-M1: an older page that is gone while busy releases the lease when its work ends', (t) async {
    final (nl, clock, reg, gate) = make(Radio(), FakeProber({}), () async => const [Rec('Y1', 1)]);
    await t.runAsync(() => nl.start(Page.home));
    final l = (await t.runAsync(() => nl.acquire('新增節點', LeaseKind.raw)))!;
    await t.pumpWidget(_Busy(RawUse(l, gate)));
    final s = t.state<BusyState>(find.byType(_Busy));
    s.rawBusy = true; // the claim starts
    await t.pumpWidget(const SizedBox()); // the page is popped
    l.pageGone();
    expect(reg.current, l, reason: 'busy: still held');
    s.rawIdle(); // the claim ends after the page is gone
    expect(reg.current, isNull);
  });

  test('T-S4: the trace never carries a full id or address', () async {
    final lines = <String>[];
    const id = '0123456789abcdef0123456789abcdef';
    final clock = Clock();
    final reg = LeaseRegistry(after: clock.after);
    final radio = Radio();
    final gate = BleGate(radio, reg, now: () => clock.t, after: clock.after);
    final nl = NodeLink(
        core: NodeLinkCore(const [Rec(id, 1)]),
        gate: gate,
        reg: reg,
        prober: FakeProber({'AA:BB:CC:DD:EE:F1': id}),
        readRecords: () async => const [Rec(id, 1)],
        now: () => clock.t,
        after: clock.after,
        trace: lines.add);
    await nl.start(Page.home);
    await clock.run(500);
    radio.scanCtl.add('AA:BB:CC:DD:EE:F1');
    await clock.run(3000);
    expect(lines.where((l) => l.contains('attempt')), isNotEmpty, reason: lines.join(' | '));
    expect(lines.any((l) => l.contains('round 0')), isTrue, reason: 'the core log is forwarded');
    for (final l in lines) {
      expect(l, isNot(matches(RegExp(r'[0-9a-fA-F]{8,}'))), reason: l);
      expect(l, isNot(contains('AA:BB')), reason: l);
    }
  });

  test('r2 X12 / X9: records written under a lease released while the next was taken are applied at the next release, once', () async {
    var recs = [const Rec('Y1', 1)];
    Completer<void>? slow;
    final radio = Radio();
    final p = MapProber()..out = {'a1|Y1': const Outcome(Res.certRejected)};
    final (nl, clock, _, _) = make(radio, p, () async {
      final s = slow;
      if (s != null) await s.future;
      return recs;
    }, recs: recs);
    await nl.start(Page.home);
    await clock.run(500);
    radio.scanCtl.add('a1');
    await clock.run(2000);
    expect(nl.core.states['Y1']!.why, Why.identity);
    final l1 = (await nl.acquire('新增節點', LeaseKind.raw))!;
    recs = [const Rec('Y1', 2)]; // re-claimed under l1
    final read = slow = Completer<void>();
    await l1.release();
    final l2 = (await nl.acquire('我的節點', LeaseKind.raw))!; // taken while l1's read is slow
    slow = null;
    read.complete();
    await clock.run(100);
    expect(nl.core.states['Y1']!.why, Why.identity, reason: 'l2 is held: nothing applied yet');
    await l2.release();
    await clock.run(100);
    expect(nl.core.states['Y1']!.why, isNull, reason: 'l1''s write applied at l2''s release');
    await clock.run(7000);
    radio.scanCtl.add('a1');
    await clock.run(2000);
    expect(nl.core.states['Y1']!.why, Why.identity, reason: 'still the wrong node: identity again');
    final l3 = (await nl.acquire('x', LeaseKind.raw))!;
    await l3.release(); // nothing written this time
    await clock.run(100);
    expect(nl.core.states['Y1']!.why, Why.identity, reason: 'the waiting ids were applied once, not again');
  });

  test('r2 D11: a hold ends once; a second call never ends another hold', () async {
    final (nl, clock, reg, _) = make(Radio(), FakeProber({}), () async => const [Rec('Y1', 1)]);
    await nl.start(Page.home);
    final l = (await nl.acquire('x', LeaseKind.raw))!;
    final a = l.hold();
    l.hold(); // a second piece of work
    l.pageGone();
    a();
    a();
    await clock.run(100);
    expect(reg.current, same(l), reason: 'the second hold is still running');
  });

  test('r2 D14 / D17: GATT on a link the stack reported down is refused; a scan the radio ends is closed', () async {
    final clock = Clock();
    final reg = LeaseRegistry(after: clock.after);
    final radio = _EndingRadio();
    final gate = BleGate(radio, reg, now: () => clock.t, after: clock.after);
    final link = gate.connect(reg.nodeLinkToken, 'a1');
    await Future<void>.delayed(Duration.zero);
    radio.goDown('a1');
    expect(() => link.read(Char.ctrl), throwsA(isA<Refused>()));
    await link.close();
    Object? ended = 0;
    await gate.scan(reg.nodeLinkToken, (_) {}, ended: (e) => ended = e);
    expect(gate.scans, 1);
    radio.endScan();
    await Future<void>.delayed(Duration.zero);
    expect((gate.scans, ended), (0, null));
  });

  test('r2 C-M1: the status stream and key refusals reach NodeLink', () async {
    final (nl, clock, _, _) = make(Radio(), FakeProber({}), () async => const [Rec('Y1', 1)]);
    await nl.start(Page.home);
    final status = StreamController<BleStatus>();
    wireRadio(status.stream, nl);
    status.add(BleStatus.poweredOff);
    await Future<void>.delayed(Duration.zero);
    expect(nl.core.shownWhy('Y1'), Why.bluetoothOff);
    status.add(BleStatus.ready);
    await Future<void>.delayed(Duration.zero);
    expect(nl.core.blocked, isNull);
    keyErrorToRadio(StateError('disk'), nl);
    expect(nl.core.blocked, isNull, reason: 'not a key refusal');
    keyErrorToRadio(PlatformException(code: 'keyLevel', message: 'OWNER_SIGN', details: 0), nl);
    expect(nl.core.blocked, Why.keys);
    await status.close();
  });

  testWidgets('r2 C-m2 / D-10: the lease is given up at the page''s dispose, after its exit animation', (t) async {
    final radio = Radio();
    final (nl, _, reg, gate) = make(radio, FakeProber({}), () async => const [Rec('Y1', 1)]);
    await t.runAsync(() => nl.start(Page.home));
    late BuildContext home;
    await t.pumpWidget(MaterialApp(home: Builder(builder: (c) {
      home = c;
      return const SizedBox();
    })));
    unawaited(openRawPage(Navigator.of(home), nl, gate, '我的節點', (u) => _Busy(u)));
    await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
    await t.pumpAndSettle();
    final l = reg.current!;
    final st = t.state<BusyState>(find.byType(_Busy));
    Navigator.of(home).pop();
    await t.pump(const Duration(milliseconds: 50)); // the exit animation runs: still mounted
    expect(st.mounted, isTrue);
    st.rawBusy = true; // work the page starts now (e.g. the next dialog)
    expect(reg.current, same(l), reason: 'not given up yet');
    await t.pumpAndSettle(); // disposed
    expect(reg.current, same(l), reason: 'busy: still held after the dispose');
    st.rawIdle();
    expect(reg.current, isNull);
  });

  test('r3 E-m1: started while the app is already in the background, NodeLink reads only once it comes back', () async {
    final radio = Radio();
    final (nl, clock, _, _) = make(radio, FakeProber({}), () async => const [Rec('Y1', 1)]);
    await nl.start(Page.home, life: AppLifecycleState.paused);
    await clock.run(1000);
    expect(radio.scans, 0, reason: 'background: no scan');
    nl.lifecycle(AppLifecycleState.resumed);
    await clock.run(500);
    expect(radio.scans, 1);
  });

  test('r4 G-m1: back in the foreground while start() reads the records -> NodeLink reads', () async {
    final radio = Radio();
    final read = Completer<List<Rec>>();
    var first = true;
    final (nl, clock, _, _) = make(radio, FakeProber({}), () {
      if (first) {
        first = false;
        return read.future;
      }
      return Future.value(const [Rec('Y1', 1)]);
    });
    final f = nl.start(Page.home, life: AppLifecycleState.paused);
    nl.lifecycle(AppLifecycleState.resumed); // the user is back while the records are read
    read.complete(const [Rec('Y1', 1)]);
    await f;
    await clock.run(2000);
    expect(nl.core.fg, isTrue);
    expect(radio.scans, 1);
  });

  testWidgets('r2 D-3: a page whose lease is gone cannot start busy work (fail-closed)', (t) async {
    final (nl, _, _, gate) = make(Radio(), FakeProber({}), () async => const [Rec('Y1', 1)]);
    await t.runAsync(() => nl.start(Page.home));
    final l = (await t.runAsync(() => nl.acquire('x', LeaseKind.raw)))!;
    await t.pumpWidget(_Busy(RawUse(l, gate)));
    final st = t.state<BusyState>(find.byType(_Busy));
    await t.runAsync(l.release); // taken back
    expect(() => st.rawBusy = true, throwsStateError);
  });

  test('r3 F-m2: an attempt''s exception reaches the trace masked', () async {
    final lines = <String>[];
    final clock = Clock();
    final reg = LeaseRegistry(after: clock.after);
    final radio = Radio();
    final gate = BleGate(radio, reg, now: () => clock.t, after: clock.after);
    final nl = NodeLink(
        core: NodeLinkCore(const [Rec('Y1', 1)]),
        gate: gate,
        reg: reg,
        prober: _Throws(),
        readRecords: () async => const [Rec('Y1', 1)],
        now: () => clock.t,
        after: clock.after,
        trace: lines.add);
    await nl.start(Page.home);
    await clock.run(500);
    radio.scanCtl.add('AA:BB:CC:DD:EE:F1');
    await clock.run(2000);
    final e = lines.where((l) => l.contains('StateError')).toList();
    expect(e, isNotEmpty, reason: lines.join(' | '));
    expect(e.first, isNot(matches(RegExp(r'[0-9a-fA-F]{8,}'))));
  });

  group('A-M1 / B-M1: an older page\x27s busy work holds the raw lease past the pop', () {
    test('popped while busy: the lease stays until the work ends; no NodeLink scan meanwhile', () async {
      final radio = Radio();
      final (nl, clock, reg, _) = make(radio, FakeProber({}), () async => const [Rec('Y1', 1)]);
      await nl.start(Page.home);
      await clock.run(500);
      final l = (await nl.acquire('新增節點', LeaseKind.raw))!;
      final scans = radio.scans;
      final end = l.hold(); // the claim starts
      l.pageGone(); // the user presses back
      await clock.run(30000);
      expect((reg.current, radio.scans), (l, scans), reason: 'still held, NodeLink waits');
      end(); // the claim ends
      end(); // a second call does nothing
      await clock.run(7000);
      expect(reg.current, isNull);
      expect(radio.scans, scans + 1);
    });

    test('a busy older page that never ends: the raw lease is taken back 900 s after the pop (r4 H-M1), not at 420 s',
        () async {
      final (nl, clock, reg, _) = make(Radio(), FakeProber({}), () async => const [Rec('Y1', 1)]);
      await nl.start(Page.home);
      final l = (await nl.acquire('我的節點', LeaseKind.raw))!;
      l.hold();
      l.pageGone();
      await clock.run(600000); // a slow claim with its recovery: still held, NodeLink stays out
      expect(reg.current, l);
      await clock.run(299000);
      expect(reg.current, l);
      await clock.run(2000);
      expect(reg.current, isNull);
      expect(reg.unsavedTodos, ['上一個操作可能沒有存完：我的節點']);
    });

    test('hold on a lease that was taken back throws (the page then holds nothing)', () async {
      final (nl, clock, _, _) = make(Radio(), FakeProber({}), () async => const [Rec('Y1', 1)]);
      await nl.start(Page.home);
      final l = (await nl.acquire('x', LeaseKind.raw))!;
      await l.release();
      expect(l.hold, throwsStateError);
    });
  });
}

class _LateConnect extends Radio {
  _LateConnect(this.clock, this.delay);
  final Clock clock;
  final Duration delay;
  @override
  Stream<bool> connect(String address, Duration timeout) {
    final c = StreamController<bool>();
    clock.after(delay, () => c.add(true));
    return c.stream;
  }
}

class _DueWatch implements Prober {
  _DueWatch(this.onDue);
  final void Function() onDue;
  @override
  Future<Outcome> probe(GateLink link, String id, {required Future<void> due, required Future<void> cancelled}) async {
    await Future.any([due, cancelled]);
    onDue();
    return const Outcome(Res.noResponse);
  }
}

class _Busy extends StatefulWidget {
  const _Busy(this.use);
  final RawUse use;
  @override
  State<_Busy> createState() => BusyState();
}

class BusyState extends State<_Busy> with RawBusy<_Busy> {
  @override
  RawUse? get rawUse => widget.use;
  @override
  Widget build(BuildContext context) => const SizedBox();
}

class _EndingRadio extends Radio {
  final _scan = StreamController<String>();
  final _st2 = StreamController<(String, bool)>.broadcast(sync: true);
  void goDown(String a) => _st2.add((a, false));
  void endScan() => _scan.close();
  @override
  Stream<(String, bool)> get linkStates => _st2.stream;
  @override
  Stream<String> scan() => _scan.stream;
}

class _Throws implements Prober {
  @override
  Future<Outcome> probe(GateLink link, String id, {required Future<void> due, required Future<void> cancelled}) async =>
      throw StateError('bad record 0123456789abcdef0123456789abcdef');
}
