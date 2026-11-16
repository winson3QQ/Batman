// #329 PR 1 review r6 K-m1 (reviewer K's reproduction, now a regression test): 我的節點 popped while a
// make-network's record write (seal + storeWriteCas) is in flight: the write lands under the lease. Negative control:
// _underLease without the hold -> the write lands with no lease -> FAIL.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:batman_app/nodes.dart';
import 'package:batman_app/src/nodelink/ble_gate.dart';
import 'package:batman_app/src/nodelink/core.dart' show NodeLinkCore;
import 'package:batman_app/src/nodelink/lease.dart';
import 'package:batman_app/src/nodelink/node_link.dart';
import 'package:batman_app/src/nodelink/raw_use.dart';
import 'package:batman_app/src/rust/api/owner.dart';
import 'package:batman_app/src/rust/frb_generated.dart';
import 'package:flutter_reactive_ble/flutter_reactive_ble.dart';

import 'nodes_update_send_test.dart' as u;
import 'nodelink/node_link_test.dart' as nlt show Clock, Radio, FakeProber;

const fMake = 40, fAfter = 50;

class MakeSession extends u.FakeSession {
  MakeSession(super.rust);
  @override
  OwnerStep? onFrame({required List<int> frame}) => switch (frame[0]) {
        const (fMake + 1) => u.step(OwnerKind.persistNet, rel: 'net/${u.netId}'),
        const (fAfter + 1) => u.step(OwnerKind.answer, detail: '[NET_MADE] ok'),
        _ => super.onFrame(frame: frame),
      };
  @override
  OwnerStep requestMakeNetwork(
          {required String netName, required int channel, required List<int> ownerEncPub, required List<int> adminPub}) =>
      u.step(OwnerKind.write, frame: fMake);
  @override
  OwnerStep? netPersisted() => u.step(OwnerKind.write, frame: fAfter);
}

class KRust extends u.FakeRust {
  LeaseRegistry? reg;
  final casUnder = <String>[];
  @override
  (OwnerSession, OwnerStep) crateApiOwnerOwnerSessionStart({required List<int> recordPlain, required List<int> ownerPub, required int frameLimit}) =>
      (MakeSession(this), u.step(OwnerKind.write, frame: u.fLogin));
  @override
  Future<BigInt> crateApiOwnerStoreWriteCas({required String dir, required String rel, required BigInt expectedGen, required List<int> sealed}) async {
    casUnder.add('$rel:${reg?.current?.name ?? 'NO LEASE'}');
    return super.crateApiOwnerStoreWriteCas(dir: dir, rel: rel, expectedGen: expectedGen, sealed: sealed);
  }
}

void main() {
  final rust = KRust();
  final node = u.FakeNode();
  setUpAll(() {
    RustLib.initMock(api: rust);
    ReactiveBlePlatform.instance = node;
  });

  Future<void> settle(WidgetTester t, [int rounds = 25]) async {
    for (var i = 0; i < rounds; i++) {
      await t.runAsync(() => Future<void>.delayed(Duration.zero));
      await t.pump(const Duration(milliseconds: 200));
    }
  }

  testWidgets('K-1: popped while the make-network record is being sealed', (t) async {
    final clock = nlt.Clock();
    final reg = LeaseRegistry(after: clock.after);
    rust.reg = reg;
    final gate = BleGate(nlt.Radio(), reg, now: () => clock.t, after: clock.after);
    final nl = NodeLink(
        core: NodeLinkCore(const []),
        gate: gate,
        reg: reg,
        prober: nlt.FakeProber({}),
        readRecords: () async => const [],
        now: () => clock.t,
        after: clock.after);
    rust
      ..records.clear()
      ..records.addAll({'node/${u.deviceId}'});
    final sealGate = Completer<void>();
    var sealing = false;
    final m = t.binding.defaultBinaryMessenger;
    m.setMockMethodCallHandler(const MethodChannel('dev.batman/platform'), (c) async {
      switch (c.method) {
        case 'filesDir':
          return u.files;
        case 'blePermissions' || 'devTrust':
          return true;
        case 'publicKeys':
          return {'owner': Uint8List(65), 'ownerEnc': Uint8List(65), 'admin': Uint8List(65)};
        case 'signOwner' || 'signAdmin':
          return Uint8List(70);
        case 'seal':
          sealing = true;
          await sealGate.future;
          return Uint8List(3);
        case 'open':
          return Uint8List(4);
        case 'keyLevels':
          return {
            'RECORD_AES': 1, 'OWNER_SIGN': 1, 'ADMIN_SIGN': 1, 'OWNER_ENC': 1, 'appUsable': true, 'claim': true,
            'login': true, 'recover': true, 'makeNetwork': true, 'softOwnerEnc': false,
          };
      }
      return null;
    });
    await t.pumpWidget(MaterialApp(
        home: Builder(
            builder: (c) => TextButton(
                onPressed: () => openRawPage(Navigator.of(c), nl, gate, '我的節點', (use) => NodesPage(use: use)),
                child: const Text('open')))));
    await settle(t, 5);
    await t.tap(find.text('open'));
    await settle(t, 5);
    final lease = reg.current!;
    await t.tap(find.byType(ListTile));
    await settle(t);
    final mk = find.widgetWithText(FilledButton, '建立網路');
    await t.ensureVisible(mk);
    await t.pump();
    await t.tap(mk);
    await settle(t, 10);
    expect(sealing, isTrue, reason: 'the make-network reached its record write');
    expect(reg.current, same(lease));
    t.state<NavigatorState>(find.byType(Navigator)).pop();
    await settle(t, 10);
    expect(find.byType(NodesPage), findsNothing);
    await t.runAsync(() async => sealGate.complete());
    await settle(t, 10);
    expect(rust.casUnder.where((x) => x.endsWith('NO LEASE')), isEmpty, reason: 'a record write after the lease was given up');
  });
}
