// #329 §4.3: NodeLink drives the core through BleGate. Fake radio, fake prober, manual clock.
import 'dart:async';

import 'package:batman_app/src/nodelink/ble_gate.dart';
import 'package:batman_app/src/nodelink/core.dart';
import 'package:batman_app/src/nodelink/lease.dart';
import 'package:batman_app/src/nodelink/node_link.dart';
import 'package:flutter_test/flutter_test.dart';

class Clock {
  final List<(int, void Function(), List<bool>)> pending = [];
  int t = 0;
  Cancel after(Duration d, void Function() f) {
    final c = [false];
    pending.add((t + d.inMilliseconds, f, c));
    return () => c[0] = true;
  }

  /// Advance in 100 ms steps, firing due timers and letting futures run.
  Future<void> run(int ms) async {
    final end = t + ms;
    while (t < end) {
      t += 100;
      for (final p in [...pending]) {
        if (p.$1 <= t && !p.$3[0]) {
          p.$3[0] = true;
          p.$2();
        }
      }
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
    }
  }
}

class Radio implements BleBackend {
  final scanCtl = StreamController<String>.broadcast();
  final _states = StreamController<(String, bool)>.broadcast(sync: true);
  int scans = 0, connects = 0, open = 0;
  final Set<String> down = {}; // addresses that never connect

  @override
  Stream<String> scan() {
    scans++;
    return scanCtl.stream;
  }

  @override
  Stream<bool> connect(String address, Duration timeout) {
    connects++;
    late StreamController<bool> c;
    c = StreamController<bool>(onCancel: () {
      if (open > 0) open--;
      _states.add((address, false));
    });
    if (!down.contains(address)) {
      scheduleMicrotask(() {
        open++;
        c.add(true);
      });
    }
    return c.stream;
  }

  @override
  Stream<(String, bool)> get linkStates => _states.stream;
  @override
  Future<int> requestMtu(String address, int mtu) async => 247;
  @override
  Future<List<int>> read(String address, Char c) async => [0];
  @override
  Stream<List<int>> subscribe(String address, Char c) => const Stream.empty();
  @override
  Future<void> write(String address, Char c, List<int> value) async {}
}

/// Answers by address: the record that opens it reads 'green', others are 解不開.
class FakeProber implements Prober {
  FakeProber(this.owner);
  final Map<String, String> owner; // address -> record id
  final List<String> probes = [];
  Completer<void>? hold; // when set, a probe waits for it (or for cancel)

  @override
  Future<Outcome> probe(GateLink link, String id, {required Future<void> due, required Future<void> cancelled}) async {
    probes.add('${link.address}×$id');
    final h = hold;
    if (h != null) await Future.any([h.future, cancelled]);
    return owner[link.address] == id ? const Outcome(Res.body, 'green') : const Outcome(Res.undecryptable);
  }
}

(NodeLink, Clock, Radio, FakeProber, LeaseRegistry, BleGate) setup(List<Rec> recs, Map<String, String> owner) {
  final clock = Clock();
  final reg = LeaseRegistry(after: clock.after);
  final radio = Radio();
  final gate = BleGate(radio, reg, now: () => clock.t, after: clock.after);
  final prober = FakeProber(owner);
  final nl = NodeLink(
    core: NodeLinkCore(recs),
    gate: gate,
    reg: reg,
    prober: prober,
    readRecords: () async => recs,
    now: () => clock.t,
    after: clock.after,
  );
  return (nl, clock, radio, prober, reg, gate);
}

void main() {
  test('a round scans through the gate, tries an address, and the node is read', () async {
    final (nl, clock, radio, prober, _, gate) = setup([const Rec('Y1', 1)], {'a1': 'Y1'});
    await nl.start(Page.home);
    await clock.run(500);
    expect(radio.scans, 1);
    radio.scanCtl.add('a1');
    await clock.run(2000);
    expect(prober.probes, ['a1×Y1']);
    expect(nl.core.states['Y1']!.kind, Kind.read);
    expect(nl.core.fresh('Y1', clock.t), isTrue);
    expect(gate.links, 0, reason: 'the link is closed after the read');
  });

  test('one link at a time: a wrong record first, then the right one, never two links open', () async {
    final (nl, clock, radio, prober, _, gate) =
        setup([const Rec('Y1', 2), const Rec('Y2', 1)], {'a1': 'Y2', 'a2': 'Y1'});
    await nl.start(Page.home);
    await clock.run(500);
    var maxOpen = 0;
    final sub = Stream<void>.periodic(Duration.zero).listen((_) {
      if (radio.open > maxOpen) maxOpen = radio.open;
    });
    radio.scanCtl.add('a1');
    radio.scanCtl.add('a2');
    await clock.run(20000);
    await sub.cancel();
    expect(nl.core.states['Y1']!.kind, Kind.read);
    expect(nl.core.states['Y2']!.kind, Kind.read);
    expect(maxOpen, lessThanOrEqualTo(1));
    expect(gate.refused, isEmpty, reason: 'NodeLink never asks the gate for a second link');
  });

  test('a node that never connects is 沒有回應 within 8 s, not a hang', () async {
    final (nl, clock, radio, _, _, _) = setup([const Rec('Y1', 1)], {});
    radio.down.add('a1');
    await nl.start(Page.home);
    await clock.run(500);
    radio.scanCtl.add('a1');
    await clock.run(9000);
    expect(nl.core.log.where((l) => l.contains('a1×Y1 -> noResponse')), isNotEmpty, reason: nl.core.log.join('\n'));
  });

  test('§4.4: acquiring a lease cancels the round, drops its link, and no round runs while it is held', () async {
    final (nl, clock, radio, prober, reg, gate) = setup([const Rec('Y1', 1)], {'a1': 'Y1'});
    prober.hold = Completer<void>(); // the probe hangs
    await nl.start(Page.home);
    await clock.run(500);
    radio.scanCtl.add('a1');
    await clock.run(1000);
    expect(gate.links, 1);
    final l = await nl.acquire('建立網路', LeaseKind.session);
    expect(l, isNotNull);
    expect((gate.links, gate.scans), (0, 0));
    final n = nl.core.roundsRun;
    await clock.run(120000);
    expect(nl.core.roundsRun, n);
    expect(await nl.acquire('另一個', LeaseKind.raw), isNull);
    await l!.release();
    await clock.run(7000); // 6 s after the release
    expect(nl.core.roundsRun, n + 1);
  });

  test('a lease release reads the records again: a claimed node becomes a target', () async {
    final recs = [const Rec('Y1', 1)];
    final clock = Clock();
    final reg = LeaseRegistry(after: clock.after);
    final radio = Radio();
    final gate = BleGate(radio, reg, now: () => clock.t, after: clock.after);
    final nl = NodeLink(
      core: NodeLinkCore(const []),
      gate: gate,
      reg: reg,
      prober: FakeProber({'a1': 'Y1', 'a2': 'Y2'}),
      readRecords: () async => [...recs],
      now: () => clock.t,
      after: clock.after,
    );
    await nl.start(Page.home);
    expect(nl.core.states.keys, ['Y1']);
    final l = (await nl.acquire('新增節點', LeaseKind.raw))!;
    l.writtenNodes.add('Y2');
    recs.add(const Rec('Y2', 2));
    await l.release();
    await clock.run(500);
    expect(nl.core.states.keys.toSet(), {'Y1', 'Y2'});
  });

  test('background cancels the round and its link; foreground starts one at once', () async {
    final (nl, clock, radio, prober, _, gate) = setup([const Rec('Y1', 1)], {'a1': 'Y1'});
    prober.hold = Completer<void>();
    await nl.start(Page.home);
    await clock.run(500);
    radio.scanCtl.add('a1');
    await clock.run(1000);
    nl.background();
    await clock.run(200);
    expect((gate.links, gate.scans, nl.core.roundActive), (0, 0, false));
    prober.hold = null;
    nl.foreground();
    await clock.run(500);
    expect(nl.core.roundActive, isTrue);
  });
}
