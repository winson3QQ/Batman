// #329 fast retry (docs/design/329-fast-retry.md): a connect whose link fails within 1.5 s is tried once more after
// 400 ms, inside the same 8 s attempt (NodeLink._run and the flows' _lfAttempt); the gate ignores a code-less down on a
// link that is still connecting (§2.1 (b)); every link the attempt opens is closed (§4).
import 'dart:async';
import 'dart:typed_data';

import 'package:batman_app/src/nodelink/ble_gate.dart';
import 'package:batman_app/src/nodelink/core.dart';
import 'package:batman_app/src/nodelink/lease.dart';
import 'package:batman_app/src/nodelink/node_link.dart';
import 'package:flutter_test/flutter_test.dart';

import 'login_for_test.dart' show LoginProber;
import 'node_link_test.dart' show Clock;

const addr = 'AA:BB:CC:DD:EE:01';

/// A radio that decides per connect call: [plan] holds, for each call in turn, the ms after which that connect fails
/// (a 133: `false` on the connect stream, then on the global stream a code-less down and the coded ones in later
/// tasks), or null = it comes up after [upAfter] ms. An empty plan = up. [staleAt]: for the connect call with that
/// index (0-based), a code-less down for the address on the global stream only, [staleDelay] ms after the call —
/// someone else's late DISCONNECTED (§2.1 (b)).
class RetryRadio implements BleBackend {
  RetryRadio(this.clock);
  final Clock clock;
  final scanCtl = StreamController<String>.broadcast();
  final _states = StreamController<(String, bool, int?)>.broadcast(sync: true);
  final List<int?> plan = [];
  int upAfter = 300;
  int? staleAt;
  int staleDelay = 100;
  final List<int> connectTimes = [];
  int mtuCalls = 0;

  @override
  Stream<(String, Uint8List?)> scan() => scanCtl.stream.map<(String, Uint8List?)>((a) => (a, null));

  @override
  Stream<bool> connect(String address, Duration timeout) {
    final i = connectTimes.length;
    connectTimes.add(clock.t);
    final f = plan.isEmpty ? null : plan.removeAt(0);
    // a cancel is seen as down (§4.2), except after a failure: plugin patch 3 sends no DISCONNECTED then
    final c = StreamController<bool>(onCancel: () => f == null ? _states.add((address, false, null)) : null);
    if (staleAt == i) {
      clock.after(Duration(milliseconds: staleDelay), () => _states.add((address, false, null)));
    }
    if (f != null) {
      clock.after(Duration(milliseconds: f), () {
        c.add(false);
        _states.add((address, false, null));
        Timer(Duration.zero, () => _states.add((address, false, 133)));
      });
    } else {
      clock.after(Duration(milliseconds: upAfter), () => c.isClosed ? null : c.add(true));
    }
    return c.stream;
  }

  @override
  Stream<(String, bool, int?)> get linkStates => _states.stream;
  @override
  Future<int> requestMtu(String address, int mtu) async {
    mtuCalls++;
    return 247;
  }

  @override
  Future<List<int>> read(String address, Char c) async => [0];
  @override
  Stream<List<int>> subscribe(String address, Char c) => const Stream.empty();
  @override
  Future<void> write(String address, Char c, List<int> value) async {}
}

/// Makes one GATT call first (review 4 A m2): a link the gate marked down fails it (Refused) -> noResponse.
class GattProber implements Prober {
  @override
  Future<Outcome> probe(GateLink link, String id, {required Future<void> due, required Future<void> cancelled}) async {
    try {
      await link.requestMtu(247);
    } on Refused {
      return const Outcome(Res.noResponse);
    }
    return id == 'Y1' ? const Outcome(Res.body, 'green') : const Outcome(Res.undecryptable);
  }
}

class Rig {
  Rig({Prober? prober, this.page = Page.home}) {
    gate = BleGate(radio, reg, now: () => clock.t, after: clock.after, trace: log.add);
    nl = NodeLink(
      core: NodeLinkCore(const [Rec('Y1', 1)]),
      gate: gate,
      reg: reg,
      prober: prober ?? GattProber(),
      readRecords: () async => const [Rec('Y1', 1)],
      now: () => clock.t,
      after: clock.after,
      loginProber: loginProber,
      keysOk: () async => true,
      trace: log.add,
    );
  }
  final Page page;
  final clock = Clock();
  late final reg = LeaseRegistry(after: clock.after);
  late final radio = RetryRadio(clock);
  late final BleGate gate;
  late final NodeLink nl;
  final loginProber = LoginProber({addr: 'ok'});
  final log = <String>[];

  Future<void> start() async {
    await nl.start(page);
    await clock.run(100);
    radio.scanCtl.add(addr);
  }

  String line(String s) => log.firstWhere((l) => l.contains(s), orElse: () => '');
  int count(String s) => log.where((l) => l.contains(s)).length;
}

void main() {
  test('T1 (_run): a link that fails at 600 ms is connected again 400 ms later and the node is read in that attempt',
      () async {
    final r = Rig();
    r.radio.plan.addAll([600, null]);
    await r.start();
    await r.clock.run(2500);
    final t = r.radio.connectTimes;
    expect(t, hasLength(2), reason: r.log.join('\n'));
    expect(t[1] - t[0], inInclusiveRange(1000, 1100), reason: 'failure at 600 + settle 400');
    expect(r.nl.core.states['Y1']!.kind, Kind.read, reason: r.log.join('\n'));
    expect(r.line('link failed after 600ms, connecting once more'), isNotEmpty, reason: r.log.join('\n'));
    expect(r.line('second connect +400ms'), isNotEmpty, reason: r.log.join('\n'));
    final a = r.line('connected=');
    expect(a, contains('result=body'));
    expect(a, contains(' retried downs=+0'), reason: 'the first failure\'s own code-less down at +0');
    expect(r.count('result='), 1, reason: 'one attempt for the core');
    expect((r.gate.links, r.gate.active), (0, 0), reason: 'every link the attempt opened is closed (§4)');
    expect(r.log.any((l) => l.contains('AA:BB')), isFalse, reason: 'never the full address');
  });

  test('T1 (_lfAttempt): a flow login whose first connect fails fast logs in on the second', () async {
    final r = Rig(page: Page.other);
    r.radio.plan.addAll([600, null]);
    await r.nl.start(Page.other);
    final lease = (await r.nl.acquire('建立網路', LeaseKind.session))!;
    LoginForResult? res;
    unawaited(r.nl.loginFor(lease, 'Y1').then((x) => res = x));
    await r.clock.run(200);
    r.radio.scanCtl.add(addr);
    await r.clock.run(2500);
    expect(res?.end, LoginForEnd.ok, reason: r.log.join('\n'));
    final t = r.radio.connectTimes;
    expect(t, hasLength(2));
    expect(t[1] - t[0], inInclusiveRange(1000, 1100));
    expect(r.line('loginFor …01×Y1 link failed after 600ms'), isNotEmpty, reason: r.log.join('\n'));
    expect(r.line('result=body'), contains(' retried'), reason: r.log.join('\n'));
    await res!.handoff!.close();
    expect((r.gate.links, r.gate.active), (0, 0));
    lease.release();
  });

  test('T2: a second fast failure ends the attempt; no third connect in it (the next attempt waits the 6 s gap)',
      () async {
    final r = Rig();
    r.radio.plan.addAll([600, 600, null]);
    await r.start();
    await r.clock.run(1900);
    expect(r.radio.connectTimes, hasLength(2));
    expect(r.line('connected=-1ms result=noResponse'), contains(' retried'), reason: r.log.join('\n'));
    expect((r.gate.links, r.gate.active), (0, 0));
    for (var i = 0; i < 30 && r.radio.connectTimes.length < 3; i++) { // the next round (the address is spent in this one)
      r.radio.scanCtl.add(addr);
      await r.clock.run(2000);
    }
    await r.clock.run(2000);
    final t = r.radio.connectTimes;
    expect(t.length, greaterThanOrEqualTo(3), reason: r.log.join('\n'));
    expect(r.nl.core.states['Y1']!.kind, Kind.read, reason: r.log.join('\n'));
    expect(t[2] - (t[1] + 600), greaterThanOrEqualTo(6000), reason: 'the core\'s gap, unchanged');
  });

  test('T3: a slow failure (1.6 s) is not retried', () async {
    final r = Rig();
    r.radio.plan.addAll([1600, null]);
    await r.start();
    await r.clock.run(3000);
    expect(r.radio.connectTimes, hasLength(1), reason: r.log.join('\n'));
    expect(r.count('connecting once more'), 0);
    expect(r.line('connected=-1ms'), isNot(contains('retried')));
  });

  test('T4: leaving the page (the round cancelled) in the 400 ms wait: no second connect', () async {
    final r = Rig();
    r.radio.plan.addAll([600, null]);
    await r.start();
    await r.clock.run(800); // failed at ~700, in the wait
    expect(r.radio.connectTimes, hasLength(1));
    r.nl.setPage(Page.other);
    await r.clock.run(1500);
    expect(r.radio.connectTimes, hasLength(1), reason: r.log.join('\n'));
    expect(r.count('second connect'), 0);
    expect((r.gate.links, r.gate.active), (0, 0));
  });

  test('T4: dispose in the 400 ms wait: no second connect', () async {
    final r = Rig();
    r.radio.plan.addAll([600, null]);
    await r.start();
    await r.clock.run(800);
    await r.nl.dispose();
    await r.clock.run(1500);
    expect(r.radio.connectTimes, hasLength(1), reason: r.log.join('\n'));
  });

  test('T5: Bluetooth off in the 400 ms wait: no second connect; read again once it is on', () async {
    final r = Rig();
    r.radio.plan.addAll([600]);
    await r.start();
    await r.clock.run(800);
    r.nl.radio(bluetooth: false);
    await r.clock.run(1500);
    expect(r.radio.connectTimes, hasLength(1), reason: r.log.join('\n'));
    expect(r.nl.core.shownWhy('Y1'), Why.bluetoothOff);
    r.nl.radio(bluetooth: true);
    await r.clock.run(300);
    r.radio.scanCtl.add(addr);
    await r.clock.run(3000);
    expect(r.nl.core.states['Y1']!.kind, Kind.read, reason: r.log.join('\n'));
    expect((r.gate.links, r.gate.active), (0, 0));
  });

  test('T5 (_lfAttempt): the lease taken back in the 400 ms wait: no second connect', () async {
    final r = Rig(page: Page.other);
    r.radio.plan.addAll([600, null]);
    await r.nl.start(Page.other);
    final lease = (await r.nl.acquire('建立網路', LeaseKind.session))!;
    unawaited(r.nl.loginFor(lease, 'Y1'));
    await r.clock.run(200);
    r.radio.scanCtl.add(addr);
    await r.clock.run(900); // failed, in the wait
    expect(r.radio.connectTimes, hasLength(1));
    lease.release();
    await r.clock.run(1500);
    expect(r.radio.connectTimes, hasLength(1), reason: r.log.join('\n'));
    expect(r.count('second connect'), 0);
  });

  test('T6: the node page opens in the 400 ms wait: the attempt is taken over, the retry goes on and its read counts',
      () async {
    final r = Rig();
    r.radio.plan.addAll([600, null]);
    await r.start();
    await r.clock.run(800);
    expect(r.radio.connectTimes, hasLength(1));
    r.nl.setPage(Page.node, node: 'Y1');
    await r.clock.run(1500);
    expect(r.radio.connectTimes.length, greaterThanOrEqualTo(2), reason: r.log.join('\n'));
    expect(r.radio.connectTimes[1] - r.radio.connectTimes[0], inInclusiveRange(1000, 1100),
        reason: 'the same attempt\'s retry, not a new attempt: ${r.log.join('\n')}');
    expect(r.nl.core.states['Y1']!.kind, Kind.read, reason: r.log.join('\n'));
  });

  test('§2.1 (b): someone else\'s late code-less down on the retry\'s link before it is up does not end the read',
      () async {
    final r = Rig();
    r.radio
      ..plan.addAll([600, null])
      ..staleAt = 1; // 100 ms after the second connect, before its `true` at 300
    await r.start();
    await r.clock.run(2500);
    final a = r.line('connected=');
    expect(a, contains('result=body'), reason: r.log.join('\n'));
    expect(a, contains('downs=+0,+500'), reason: 'the stale down is in the trace (§7 signature computable)');
    expect(r.radio.mtuCalls, greaterThan(0), reason: 'the prober made its GATT call on the second link');
  });

  group('BleGate §2.1 (b) alone', () {
    (BleGate, Clock, StreamController<bool>, StreamController<(String, bool, int?)>) gateRig() {
      final clock = Clock();
      final reg = LeaseRegistry(after: clock.after);
      final conn = StreamController<bool>();
      final states = StreamController<(String, bool, int?)>.broadcast(sync: true);
      final b = _Backend(conn, states);
      return (BleGate(b, reg, now: () => clock.t, after: clock.after), clock, conn, states);
    }

    test('a code-less down on a connecting link does not mark it down; it comes up and works', () async {
      final (g, _, conn, states) = gateRig();
      final l = g.connect(g.reg.nodeLinkToken, addr);
      states.add((addr, false, null));
      conn.add(true);
      await Future<void>.delayed(Duration.zero);
      expect(l.up, isTrue);
      expect(await l.requestMtu(247), 247);
    });

    test('a coded down on a connecting link marks it down', () async {
      final (g, _, _, states) = gateRig();
      final l = g.connect(g.reg.nodeLinkToken, addr);
      states.add((addr, false, 133));
      expect(l.up, isFalse);
    });

    test('a code-less down on an up link marks it down (as before)', () async {
      final (g, _, conn, states) = gateRig();
      final l = g.connect(g.reg.nodeLinkToken, addr);
      conn.add(true);
      await Future<void>.delayed(Duration.zero);
      states.add((addr, false, null));
      expect(l.up, isFalse);
    });

    test('a code-less down on a connecting link, then close: the close ends on the cancel\'s own down, not at 5 s',
        () async {
      final (g, clock, _, states) = gateRig();
      final l = g.connect(g.reg.nodeLinkToken, addr);
      states.add((addr, false, null));
      var closed = false;
      unawaited(l.close().then((_) => closed = true));
      await clock.run(200);
      expect(closed, isTrue);
      expect(g.links, 0);
    });

    test('codelessDowns keeps the last 4 per address and at most 16 addresses', () async {
      final (g, clock, _, states) = gateRig();
      for (var i = 0; i < 6; i++) {
        states.add((addr, false, null));
        await clock.run(100);
      }
      expect(g.codelessDowns(addr), [200, 300, 400, 500]);
      states.add((addr, false, 133));
      expect(g.codelessDowns(addr), hasLength(4), reason: 'a coded down is not noted');
      for (var i = 0; i < 16; i++) {
        states.add(('AA:BB:CC:DD:EF:${i.toString().padLeft(2, '0')}', false, null));
      }
      expect(g.codelessDowns(addr), isEmpty, reason: 'the oldest address went');
    });
  });
}

class _Backend implements BleBackend {
  _Backend(this.conn, this.states);
  final StreamController<bool> conn;
  final StreamController<(String, bool, int?)> states;
  @override
  Stream<(String, Uint8List?)> scan() => const Stream.empty();
  @override
  Stream<bool> connect(String address, Duration timeout) {
    conn.onCancel = () => states.add((address, false, null));
    return conn.stream;
  }

  @override
  Stream<(String, bool, int?)> get linkStates => states.stream;
  @override
  Future<int> requestMtu(String address, int mtu) async => 247;
  @override
  Future<List<int>> read(String address, Char c) async => [0];
  @override
  Stream<List<int>> subscribe(String address, Char c) => const Stream.empty();
  @override
  Future<void> write(String address, Char c, List<int> value) async {}
}
