// #329 re-test, design 329-ble-settle.md v3: a connect that fails ends the attempt at once (not after the full 8 s), and
// the failure status the stack reports is logged by the gate — also when it arrives after the attempt has closed its
// link (a separate platform message: J / I v3 MAJOR). Only the status number and the address's last 2 are logged.
import 'dart:async';

import 'package:batman_app/src/nodelink/ble_backend.dart' show failureCode;
import 'package:batman_app/src/nodelink/ble_gate.dart';
import 'package:batman_app/src/nodelink/core.dart';
import 'package:batman_app/src/nodelink/lease.dart';
import 'package:batman_app/src/nodelink/node_link.dart';
import 'package:flutter_test/flutter_test.dart';

import 'login_for_test.dart' show LoginProber;
import 'node_link_test.dart' show Clock, FakeProber;

const addr = 'AA:BB:CC:DD:EE:01';

/// A radio whose connect to an address in [failAt] reports `false` after that many ms (what the plugin does on a 133),
/// and whose global link stream then carries the failure in later event-loop tasks, as the plugin's separate platform
/// messages do: first a code-less disconnected, then the coded one twice.
class FailRadio implements BleBackend {
  FailRadio(this.clock);
  final Clock clock;
  final scanCtl = StreamController<String>.broadcast();
  final _states = StreamController<(String, bool, int?)>.broadcast(sync: true);
  final Map<String, int> failAt = {};
  /// Addresses whose previous link's synthetic DISCONNECTED comes late: a connect to them within 200 ms of the last
  /// close first gets a code-less false (the plugin, DeviceConnector.kt:68-75; review 3 I).
  final Set<String> staleFalse = {};
  final Map<String, int> closedAt = {};
  int staleHits = 0;
  int code = 133;
  final List<int> connectTimes = [];

  @override
  Stream<String> scan() => scanCtl.stream;

  @override
  Stream<bool> connect(String address, Duration timeout) {
    connectTimes.add(clock.t);
    late StreamController<bool> c;
    c = StreamController<bool>(onCancel: () {
      closedAt[address] = clock.t;
      _states.add((address, false, null)); // a cancel is seen as down (§4.2)
    });
    final f = failAt[address];
    final last = closedAt[address];
    if (staleFalse.contains(address) && last != null && clock.t - last < 200) {
      staleHits++;
      scheduleMicrotask(() => c.add(false));
    } else if (f != null) {
      clock.after(Duration(milliseconds: f), () {
        c.add(false);
        _states.add((address, false, null)); // the code-less one, same task as the connect stream's false
        // the coded ones: later platform messages -> later event-loop tasks
        Timer(Duration.zero, () => _states.add((address, false, code)));
        Timer(Duration.zero, () => _states.add((address, false, code)));
      });
    } else {
      scheduleMicrotask(() => c.add(true));
    }
    return c.stream;
  }

  @override
  Stream<(String, bool, int?)> get linkStates => _states.stream;
  @override
  Future<int> requestMtu(String address, int mtu) async => 247;
  @override
  Future<List<int>> read(String address, Char c) async => [0];
  @override
  Stream<List<int>> subscribe(String address, Char c) => const Stream.empty();
  @override
  Future<void> write(String address, Char c, List<int> value) async {}
}

(NodeLink, Clock, FailRadio, List<String>, List<String>) setup() {
  final clock = Clock();
  final reg = LeaseRegistry(after: clock.after);
  final radio = FailRadio(clock);
  final gateLog = <String>[], nlLog = <String>[];
  final gate = BleGate(radio, reg, now: () => clock.t, after: clock.after, trace: gateLog.add);
  final nl = NodeLink(
    core: NodeLinkCore(const [Rec('Y1', 1)]),
    gate: gate,
    reg: reg,
    prober: FakeProber({addr: 'Y1'}),
    readRecords: () async => const [Rec('Y1', 1)],
    now: () => clock.t,
    after: clock.after,
    trace: nlLog.add,
  );
  return (nl, clock, radio, gateLog, nlLog);
}

/// The ms after which the first attempt on [addr] ended, from NodeLink's trace.
int attemptMs(List<String> log) {
  final l = log.firstWhere((l) => l.contains('attempt') && l.contains('connected=-1'), orElse: () => '');
  final m = RegExp(r'after (\d+)ms').firstMatch(l);
  return m == null ? -1 : int.parse(m.group(1)!);
}

void main() {
  test('failureCode: the status number only; none -> -1; no message -> null', () {
    expect(failureCode('Disconnected from AA:BB:CC:DD:EE:01 with status 133 (GATT_ERROR)'), 133);
    expect(failureCode('Unknown error'), -1);
    expect(failureCode('Device is not in queue'), -1);
    expect(failureCode(null), isNull);
  });

  test('§2.1: a failing connect ends the attempt when the failure comes (2 s), not after the 8 s budget', () async {
    final (nl, clock, radio, _, nlLog) = setup();
    radio.failAt[addr] = 2000;
    await nl.start(Page.home);
    await clock.run(500);
    radio.scanCtl.add(addr);
    await clock.run(9000);
    final ms = attemptMs(nlLog);
    expect(ms, inInclusiveRange(1900, 2500), reason: nlLog.join('\n'));
  });

  test('§2.2: the failure code is logged by the gate although it arrives after the attempt closed its link', () async {
    final (nl, clock, radio, gateLog, nlLog) = setup();
    radio.failAt[addr] = 2000;
    await nl.start(Page.home);
    await clock.run(500);
    radio.scanCtl.add(addr);
    await clock.run(3000);
    await Future<void>.delayed(const Duration(milliseconds: 5)); // let the later tasks run
    expect(gateLog, contains('link …01 down fail=133'), reason: 'gate: $gateLog\nnl: ${nlLog.join('\n')}');
    expect([...gateLog, ...nlLog].any((l) => l.contains('AA:BB')), isFalse, reason: 'never the full address');
  });

  test('§2.2: a failure without a status number is logged as fail=?', () async {
    final (nl, clock, radio, gateLog, _) = setup();
    radio
      ..failAt[addr] = 2000
      ..code = -1;
    await nl.start(Page.home);
    await clock.run(500);
    radio.scanCtl.add(addr);
    await clock.run(3000);
    await Future<void>.delayed(const Duration(milliseconds: 5));
    expect(gateLog, contains('link …01 down fail=?'));
    expect(gateLog.any((l) => l.contains('AA:BB')), isFalse, reason: 'never the full address');
  });

  test('§6: after a failure the same address is tried again only ≥ 6 s later; no 「連不到」 from one failure', () async {
    final (nl, clock, radio, _, nlLog) = setup();
    radio.failAt[addr] = 2000;
    await nl.start(Page.home);
    await clock.run(500);
    radio.scanCtl.add(addr);
    await clock.run(3000); // the first attempt has failed
    expect(radio.connectTimes, hasLength(1));
    expect(nl.core.states['Y1']!.kind, isNot(Kind.unreachable), reason: 'one failure is not 連不到 (two-round rule)');
    for (var i = 0; i < 16; i++) { // the node keeps advertising
      radio.scanCtl.add(addr);
      await clock.run(5000);
    }
    expect(radio.connectTimes.length, greaterThanOrEqualTo(2), reason: nlLog.join('\n'));
    expect(radio.connectTimes[1] - (radio.connectTimes[0] + 2000), greaterThanOrEqualTo(6000));
  });

  test('§6: Bluetooth turned off right after a failed connect -> 2.3 (Bluetooth off), and read again once it is on',
      () async {
    final (nl, clock, radio, _, nlLog) = setup();
    radio.failAt[addr] = 2000;
    await nl.start(Page.home);
    await clock.run(500);
    radio.scanCtl.add(addr);
    await clock.run(2001); // the failure has come
    nl.radio(bluetooth: false);
    await clock.run(1000);
    expect(nl.core.shownWhy('Y1'), Why.bluetoothOff);
    radio.failAt.remove(addr);
    nl.radio(bluetooth: true);
    await clock.run(500);
    radio.scanCtl.add(addr);
    await clock.run(30000);
    expect(nl.core.states['Y1']!.kind, Kind.read, reason: nlLog.join('\n'));
  });

  test('§2.1 (review 4 I-M1): a flow login (loginFor) also ends a failing connect at once, then logs in elsewhere',
      () async {
    const other = 'AA:BB:CC:DD:EE:02';
    final clock = Clock();
    final reg = LeaseRegistry(after: clock.after);
    final radio = FailRadio(clock)..failAt[addr] = 2000;
    final gate = BleGate(radio, reg, now: () => clock.t, after: clock.after);
    final log = <String>[];
    final prober = LoginProber({other: 'ok'});
    final nl = NodeLink(
      core: NodeLinkCore(const [Rec('Y1', 1)]),
      gate: gate,
      reg: reg,
      prober: FakeProber({}),
      readRecords: () async => const [Rec('Y1', 1)],
      now: () => clock.t,
      after: clock.after,
      loginProber: prober,
      keysOk: () async => true,
      trace: log.add,
    );
    await nl.start(Page.other);
    final lease = (await nl.acquire('建立網路', LeaseKind.session))!;
    LoginForResult? r;
    unawaited(nl.loginFor(lease, 'Y1').then((x) => r = x));
    await clock.run(300);
    radio.scanCtl.add(addr);
    for (var t = 0; t < 40000 && r == null; t += 500) {
      if (t == 3000) radio.scanCtl.add(other);
      await clock.run(500);
    }
    final first = log.firstWhere((l) => l.contains('loginFor') && l.contains('result=noResponse'), orElse: () => '');
    final ms = int.tryParse(RegExp(r'after (\d+)ms').firstMatch(first)?.group(1) ?? '') ?? -1;
    expect(ms, inInclusiveRange(1900, 2500), reason: log.join('\n'));
    expect(r?.end, LoginForEnd.ok);
    await r!.handoff!.close();
  });

  test('§6 (review 4 I-m1 / J m-2): the late code-less false only reaches a connect to the same address within ~200 ms; '
      'NodeLink never retries that soon (≥ 6 s), so it is never hit and the next attempt reads', () async {
    final (nl, clock, radio, _, nlLog) = setup();
    radio.failAt[addr] = 2000;
    await nl.start(Page.home);
    await clock.run(500);
    radio.scanCtl.add(addr);
    await clock.run(3000); // failed and closed
    radio
      ..failAt.remove(addr)
      ..staleFalse.add(addr); // the next connect first sees the previous link's late DISCONNECTED
    for (var i = 0; i < 16; i++) {
      radio.scanCtl.add(addr);
      await clock.run(5000);
    }
    expect(radio.connectTimes.length, greaterThanOrEqualTo(2), reason: nlLog.join('\n'));
    expect(radio.connectTimes[1] - (radio.connectTimes[0] + 2000), greaterThanOrEqualTo(6000));
    expect(radio.staleHits, 0, reason: 'no retry within the 200 ms the late DISCONNECTED can reach');
    expect(nl.core.states['Y1']!.kind, Kind.read, reason: nlLog.join('\n'));
  });

  test('§6 (the fake itself): a connect within 200 ms of the close does get the late false and ends as noResponse',
      () async {
    final clock = Clock();
    final reg = LeaseRegistry(after: clock.after);
    final radio = FailRadio(clock)..staleFalse.add(addr);
    final gate = BleGate(radio, reg, now: () => clock.t, after: clock.after);
    final t = reg.nodeLinkToken;
    final l1 = gate.connect(t, addr);
    await clock.run(100);
    await l1.close();
    final l2 = gate.connect(t, addr); // 0 ms later: the window the plugin's late DISCONNECTED reaches
    final first = await l2.state.first.then((s) => s, onError: (Object _) => false);
    expect((first, radio.staleHits), (false, 1));
    await l2.close();
  });
}
