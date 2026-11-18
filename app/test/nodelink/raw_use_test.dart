// #329 PR 7 T12 (#329:113): openRawPage / openRawPageFor give the lease straight back when the navigator that was to
// show the page is gone by the time the lease is granted (the wait: the last release's record read, at most 5 s;
// review pr1 A-m4). Negative control: no `lease.release()` in that branch -> the lease stays held -> FAIL.
import 'dart:async';

import 'package:batman_app/src/nodelink/ble_gate.dart';
import 'package:batman_app/src/nodelink/core.dart' show NodeLinkCore, Rec;
import 'package:batman_app/src/nodelink/lease.dart';
import 'package:batman_app/src/nodelink/node_link.dart';
import 'package:batman_app/src/nodelink/raw_use.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'node_link_test.dart' as nlt show Clock, Radio, FakeProber;

void main() {
  for (final withResult in [false, true]) {
    final name = withResult ? 'openRawPageFor' : 'openRawPage';
    testWidgets('T12 $name: the navigator unmounted while waiting for the lease -> the lease is released, no page',
        (t) async {
      final clock = nlt.Clock();
      final reg = LeaseRegistry(after: clock.after);
      final gate = BleGate(nlt.Radio(), reg, now: () => clock.t, after: clock.after);
      var reads = Completer<List<Rec>>()..complete(const []);
      final nl = NodeLink(
          core: NodeLinkCore(const []),
          gate: gate,
          reg: reg,
          prober: nlt.FakeProber({}),
          readRecords: () => reads.future,
          now: () => clock.t,
          after: clock.after);
      // a lease released just before: its record read is still running, so the next acquire waits for it
      final before = (await t.runAsync(() => nl.acquire('前一個', LeaseKind.session)))!;
      reads = Completer<List<Rec>>();
      await t.runAsync(before.release);
      final released = <String>[];
      reg.listeners.add(_Spy(released));

      await t.pumpWidget(MaterialApp(home: Builder(builder: (c) => const Text('home'))));
      final nav = t.state<NavigatorState>(find.byType(Navigator));
      var built = false;
      Widget page(RawUse u) {
        built = true;
        return const Text('page');
      }

      final opened = withResult
          ? openRawPageFor<int>(nav, nl, gate, '附近的節點', page).then((r) => r.$1)
          : openRawPage(nav, nl, gate, '附近的節點', page);
      await t.pumpWidget(const SizedBox()); // the navigator goes while the lease is waited for
      expect(nav.mounted, isFalse, reason: 'premise');
      expect(released, isEmpty, reason: 'premise: still waiting for the last record read');
      reads.complete(const []);
      final busy = await t.runAsync(() => opened);
      expect(busy, isNull, reason: 'nobody else held the radio');
      expect(released, ['附近的節點'], reason: 'the lease was taken and given straight back');
      expect(reg.current, isNull);
      expect(built, isFalse, reason: 'no page for a gone navigator');
      await t.runAsync(nl.dispose);
    });
  }
}

class _Spy implements LeaseListener {
  _Spy(this.names);
  final List<String> names;
  @override
  void revoked(Token t) {}
  @override
  void released(Lease l, {required bool revoked}) => names.add(l.name);
}
