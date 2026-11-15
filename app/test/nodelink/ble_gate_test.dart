// #329 §4.2 / §9.1 T-G1: BleGate with a fake radio and a manual clock.
import 'dart:async';

import 'package:batman_app/src/nodelink/ble_gate.dart';
import 'package:batman_app/src/nodelink/lease.dart';
import 'package:flutter_test/flutter_test.dart';

class Clock {
  final List<(int, void Function(), List<bool>)> pending = [];
  int t = 0;
  Cancel after(Duration d, void Function() f) {
    final c = [false];
    pending.add((t + d.inMilliseconds, f, c));
    return () => c[0] = true;
  }

  void advance(int ms) {
    t += ms;
    for (final p in [...pending]) {
      if (p.$1 <= t && !p.$3[0]) {
        p.$3[0] = true;
        p.$2();
      }
    }
  }
}

class FakeRadio implements BleBackend {
  int scanStarts = 0, scanStops = 0, connects = 0, disconnects = 0;
  final _states = StreamController<(String, bool)>.broadcast(sync: true);
  @override
  Stream<(String, bool)> get linkStates => _states.stream;
  final List<StreamController<bool>> links = [];
  bool reportDisconnect = true;

  @override
  Stream<String> scan() {
    scanStarts++;
    late StreamController<String> c;
    c = StreamController<String>(onCancel: () => scanStops++);
    return c.stream;
  }

  @override
  Stream<bool> connect(String address, Duration timeout) {
    connects++;
    late StreamController<bool> c;
    c = StreamController<bool>(onCancel: () {
      disconnects++;
      if (reportDisconnect) _states.add((address, false)); // seen on the global stream only
    });
    links.add(c);
    scheduleMicrotask(() => c.add(true));
    return c.stream;
  }
}

(LeaseRegistry, BleGate, FakeRadio, Clock) setup() {
  final clock = Clock();
  final reg = LeaseRegistry(after: clock.after);
  final radio = FakeRadio();
  final gate = BleGate(radio, reg, now: () => clock.t, after: clock.after);
  return (reg, gate, radio, clock);
}

void main() {
  test('T-G1: a second scan and a second link are refused and counted; the radio sees one of each', () async {
    final (reg, gate, radio, _) = setup();
    final t = reg.token;
    await gate.scan(t, (_) {});
    await expectLater(gate.scan(t, (_) {}), throwsA(isA<Refused>()));
    gate.connect(t, 'a1');
    expect(() => gate.connect(t, 'a2'), throwsA(isA<Refused>()));
    expect((gate.scans, gate.links, radio.scanStarts, radio.connects), (1, 1, 1, 1));
    expect(gate.refused.length, 2);
  });

  test('a token that is not the current one is refused', () async {
    final (reg, gate, radio, _) = setup();
    final old = reg.token;
    reg.acquire('x', LeaseKind.raw);
    await expectLater(gate.scan(old, (_) {}), throwsA(isA<Refused>()));
    expect(() => gate.connect(old, 'a1'), throwsA(isA<Refused>()));
    expect(radio.scanStarts + radio.connects, 0);
  });

  test('revoking a lease closes its scan and its link (not by the holder)', () async {
    final (reg, gate, radio, clock) = setup();
    final l = reg.acquire('建立網路', LeaseKind.session)!;
    await gate.scan(l.token, (_) {});
    gate.connect(l.token, 'a1');
    await Future<void>.delayed(Duration.zero);
    final work = l.run(() => Completer<void>().future); // never ends
    l.pageGone();
    clock.advance(420 * 1000);
    await Future<void>.delayed(Duration.zero);
    expect((gate.scans, gate.links), (0, 0));
    expect((radio.scanStops, radio.disconnects), (1, 1));
    expect(reg.valid(l.token), isFalse);
    work.ignore();
  });

  test('a release closes anything its holder left open, so the next holder finds the gate free', () async {
    final (reg, gate, _, _) = setup();
    final l = reg.acquire('a', LeaseKind.raw)!;
    gate.connect(l.token, 'a1');
    await l.release();
    await Future<void>.delayed(Duration.zero);
    expect(gate.links, 0);
    final m = reg.acquire('b', LeaseKind.raw)!;
    expect(() => gate.connect(m.token, 'a2'), returnsNormally);
  });

  test('at most 4 scan starts in any 30 s: the 5th waits inside the gate until the window allows it', () async {
    final (reg, gate, radio, clock) = setup();
    for (var i = 0; i < 4; i++) {
      final s = await gate.scan(reg.token, (_) {});
      await s.stop();
      clock.advance(1000);
    }
    var started = false;
    final f = gate.scan(reg.token, (_) {}).then((_) => started = true);
    await Future<void>.delayed(Duration.zero);
    expect((started, radio.scanStarts), (false, 4));
    clock.advance(25999); // t = 29.999 s: the first start (t = 0) is still in the window
    await Future<void>.delayed(Duration.zero);
    expect(started, isFalse);
    clock.advance(1);
    await f;
    expect((started, radio.scanStarts), (true, 5));
  });

  test('close() waits for the disconnected report, or 5 s when it never comes', () async {
    final (reg, gate, radio, clock) = setup();
    final l1 = gate.connect(reg.token, 'a1');
    await Future<void>.delayed(Duration.zero);
    await l1.close(); // the fake reports disconnected on cancel
    expect(gate.links, 0);
    radio.reportDisconnect = false;
    final l2 = gate.connect(reg.token, 'a2');
    await Future<void>.delayed(Duration.zero);
    var done = false;
    final f = l2.close().then((_) => done = true);
    await Future<void>.delayed(Duration.zero);
    expect(done, isFalse);
    expect(gate.links, 1, reason: 'still counted until disconnected or 5 s');
    clock.advance(5000);
    await f;
    expect((done, gate.links), (true, 0));
  });
}
