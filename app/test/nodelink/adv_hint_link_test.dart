// #329 rotating identifier (329-rotating-id-plan.md v6.1 §8, S7 / S9): NodeLink hands every scan result's hint to
// the scheduler, and rebuilds the resolver when the record list was read again. Fake radio, fake prober, manual clock;
// the resolver here reads the first byte of the Manufacturer Data (1 -> Y1, 2 -> Y2) for the records it was built for.
import 'dart:async';
import 'dart:typed_data';

import 'package:batman_app/src/nodelink/ble_gate.dart';
import 'package:batman_app/src/nodelink/core.dart';
import 'package:batman_app/src/nodelink/lease.dart';
import 'package:batman_app/src/nodelink/node_link.dart';
import 'package:flutter_test/flutter_test.dart';

import 'login_for_test.dart' show LoginProber;
import 'node_link_test.dart' show Clock, Radio, FakeProber;

Uint8List adv(int n) => Uint8List.fromList([n]);

/// [closed] gets the ids of a resolver that NodeLink closed.
Resolver byFirstByte(List<String> ids, [List<List<String>>? closed]) => Resolver((mfr) {
      final id = 'Y${mfr[0]}';
      return ids.contains(id) ? id : null;
    }, () => closed?.add(ids));

/// A radio whose scan gives [first] the moment it is listened to (before the caller's `await` of the scan start ends).
class EagerRadio extends Radio {
  final List<String> first = [];
  @override
  Stream<(String, Uint8List?)> scan() {
    scans++;
    late final StreamController<(String, Uint8List?)> c;
    c = StreamController<(String, Uint8List?)>(
        sync: true,
        onListen: () {
          for (final a in first) {
            c.add((a, mfr[a]));
          }
        });
    return c.stream;
  }
}

class Rig {
  Rig(this.recs, {Map<String, String> owner = const {}, Map<String, String> login = const {}, Radio? radio, ResolverBuilder? build})
      : radio = radio ?? Radio() {
    reg = LeaseRegistry(after: clock.after);
    gate = BleGate(this.radio, reg, now: () => clock.t, after: clock.after);
    prober = FakeProber(owner);
    loginProber = LoginProber(login);
    nl = NodeLink(
      core: NodeLinkCore(recs),
      gate: gate,
      reg: reg,
      prober: prober,
      readRecords: () async => recs,
      now: () => clock.t,
      after: clock.after,
      trace: traces.add,
      loginProber: loginProber,
      keysOk: () async => true,
      buildResolver: build ?? (ids) async => byFirstByte(ids),
    );
  }
  List<Rec> recs;
  final clock = Clock();
  final Radio radio;
  final traces = <String>[];
  late final LeaseRegistry reg;
  late final BleGate gate;
  late final FakeProber prober;
  late final LoginProber loginProber;
  late final NodeLink nl;
}

void main() {
  test('S7: every scan result reaches the scheduler with its hint: B first without one (resolver not built yet), then '
      'with one -> tried at once', () async {
    final built = Completer<void>();
    final rig = Rig([const Rec('Y1', 1)], owner: {'B': 'Y1'}, build: (ids) async {
      await built.future;
      return byFirstByte(ids);
    });
    rig.nl.core.isY['A'] = 'Y1'; // its last address, not in the air: an unknown address waits for the 30 s window
    rig.radio.mfr['B'] = adv(1);
    await rig.nl.start(Page.home);
    await rig.clock.run(500);
    rig.radio.scanCtl.add('B');
    await rig.clock.run(3000);
    expect(rig.prober.probes, isEmpty, reason: 'no hint yet: B is an unknown address');
    built.complete();
    await rig.clock.run(200);
    rig.radio.scanCtl.add('B'); // the same address again, as a scan reports it over and over
    await rig.clock.run(1000);
    expect(rig.prober.probes, ['B×Y1'], reason: rig.nl.core.log.join('\n'));
    expect(rig.clock.t, lessThan(6000));
    expect(rig.nl.core.states['Y1']!.kind, Kind.read);
    expect(rig.traces.where((t) => t.startsWith('adv resolver 1: 1 record(s)')), hasLength(1));
  });

  test('S7: Manufacturer Data that resolves to none, or none at all, changes nothing', () async {
    final rig = Rig([const Rec('Y1', 1)], owner: {'B': 'Y1'});
    rig.nl.core.isY['A'] = 'Y1';
    rig.radio.mfr['B'] = adv(7); // not a node of this phone
    await rig.nl.start(Page.home);
    await rig.clock.run(500);
    rig.radio.scanCtl.add('B');
    rig.radio.scanCtl.add('C');
    await rig.clock.run(3000);
    expect(rig.prober.probes, isEmpty);
    expect(rig.nl.core.log.where((l) => l.contains(' like ')), isEmpty);
  });

  test('S7: loginFor: a hint seen before the login object exists is replayed into it', () async {
    final radio = EagerRadio()
      ..first.add('B')
      ..mfr['B'] = adv(1);
    final rig = Rig([const Rec('Y1', 1)], login: {'B': 'ok'}, radio: radio);
    rig.nl.core.isY['A'] = 'Y1';
    await rig.nl.start(Page.other);
    await rig.clock.run(200); // the resolver is built
    final lease = (await rig.nl.acquire('建立網路', LeaseKind.session))!;
    LoginForResult? r;
    unawaited(rig.nl.loginFor(lease, 'Y1').then((x) => r = x));
    await rig.clock.run(2000);
    expect(rig.loginProber.probes, ['B'], reason: 'B was seen once, at the scan start, with its hint\n${rig.nl.core.log.join('\n')}');
    expect(r?.end, LoginForEnd.ok);
    await r!.handoff!.close();
  });

  test('S7: loginFor: a hint that arrives later is planned at once', () async {
    final rig = Rig([const Rec('Y1', 1)], login: {'B': 'ok'});
    rig.nl.core.isY['A'] = 'Y1';
    await rig.nl.start(Page.other);
    await rig.clock.run(200);
    final lease = (await rig.nl.acquire('建立網路', LeaseKind.session))!;
    LoginForResult? r;
    unawaited(rig.nl.loginFor(lease, 'Y1').then((x) => r = x));
    await rig.clock.run(300);
    rig.radio.scanCtl.add('B'); // no Manufacturer Data in this result
    await rig.clock.run(3000);
    expect(rig.loginProber.probes, isEmpty);
    rig.radio.mfr['B'] = adv(1);
    rig.radio.scanCtl.add('B');
    await rig.clock.run(1000);
    expect(rig.loginProber.probes, ['B']);
    expect(r?.end, LoginForEnd.ok);
    await r!.handoff!.close();
  });

  test('S9: a record written under a lease: the resolver is rebuilt at the release and the new node resolves',
      () async {
    final closed = <List<String>>[];
    final rig = Rig([const Rec('Y1', 1)], owner: {'B': 'Y2'}, build: (ids) async => byFirstByte(ids, closed));
    rig.radio.mfr['B'] = adv(2);
    await rig.nl.start(Page.home);
    await rig.clock.run(500);
    rig.radio.scanCtl.add('B');
    await rig.clock.run(500);
    expect(rig.nl.core.log.where((l) => l.contains('B like')), isEmpty, reason: 'Y2 is no record of this phone yet');
    expect(closed, isEmpty);
    final lease = (await rig.nl.acquire('認領', LeaseKind.session))!;
    rig.recs = [const Rec('Y1', 1), const Rec('Y2', 2)]; // the claim wrote node/Y2
    await lease.release();
    await rig.clock.run(7000); // the round 6 s after the release
    rig.radio.scanCtl.add('B');
    await rig.clock.run(1000);
    expect(rig.nl.core.log.where((l) => l.contains('B like Y2')), hasLength(1), reason: rig.nl.core.log.join('\n'));
    expect(rig.traces.where((t) => t.startsWith('adv resolver 2: 2 record(s)')), hasLength(1), reason: '${rig.traces}');
    expect(closed, [
      ['Y1']
    ], reason: 'the replaced resolver was closed (its keys wiped), the new one not');
    await rig.nl.dispose();
    expect(closed, [
      ['Y1'],
      ['Y1', 'Y2']
    ], reason: 'dispose closes the installed one');
  });

  test('S9: a build that fails keeps the last resolver; the trace names the error type only', () async {
    var n = 0;
    final rig = Rig([const Rec('Y1', 1)], owner: {'B': 'Y1'}, build: (ids) async {
      if (++n > 1) throw StateError('secret detail');
      return byFirstByte(ids);
    });
    rig.nl.core.isY['A'] = 'Y1';
    rig.radio.mfr['B'] = adv(1);
    await rig.nl.start(Page.home);
    await rig.clock.run(500);
    final lease = (await rig.nl.acquire('設定', LeaseKind.session))!;
    await lease.release();
    await rig.clock.run(7000);
    expect(n, 2);
    rig.radio.scanCtl.add('B');
    await rig.clock.run(1000);
    expect(rig.prober.probes, ['B×Y1'], reason: 'the resolver of the first build still gives the hint');
    expect(rig.traces.where((t) => t.contains('adv resolver 2 failed (StateError)')), hasLength(1));
    expect(rig.traces.where((t) => t.contains('secret detail')), isEmpty);
  });

  test('S9: two builds overlap: the one of the newer record list stays, whichever ends last', () async {
    final slow = Completer<void>();
    var n = 0;
    final closed = <List<String>>[];
    final rig = Rig([const Rec('Y1', 1)], owner: {'B': 'Y2'}, build: (ids) async {
      if (++n == 1) await slow.future; // the build at start is still opening records
      return byFirstByte(ids, closed);
    });
    rig.radio.mfr['B'] = adv(2);
    await rig.nl.start(Page.home);
    await rig.clock.run(500);
    final lease = (await rig.nl.acquire('認領', LeaseKind.session))!;
    rig.recs = [const Rec('Y1', 1), const Rec('Y2', 2)];
    await lease.release();
    await rig.clock.run(1000);
    slow.complete(); // the older build (Y1 only) ends after the newer one
    await rig.clock.run(6000);
    rig.radio.scanCtl.add('B');
    await rig.clock.run(1000);
    expect(rig.nl.core.log.where((l) => l.contains('B like Y2')), hasLength(1), reason: rig.nl.core.log.join('\n'));
    expect(rig.traces.where((t) => t.startsWith('adv resolver 1:')), isEmpty, reason: 'the older build was not installed');
    expect(closed, [
      ['Y1']
    ], reason: 'and it was closed');
  });

  test('S9: a resolver that throws gives no hint, and the scan goes on', () async {
    final rig = Rig([const Rec('Y1', 1)], owner: {'B': 'Y1'}, build: (ids) async => Resolver((mfr) => throw StateError('x')));
    rig.radio.mfr['B'] = adv(1);
    await rig.nl.start(Page.home);
    await rig.clock.run(500);
    rig.radio.scanCtl.add('B');
    await rig.clock.run(2000);
    expect(rig.prober.probes, ['B×Y1'], reason: 'tried as an unknown address (Y1 has no memo)');
    expect(rig.nl.core.log.where((l) => l.contains(' like ')), isEmpty);
  });
}
