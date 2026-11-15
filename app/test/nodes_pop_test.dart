// #329 PR 1 review r5 I-m1 / I-m3 (reviewer I's reproduction, now the regression test): 我的節點 popped while a
// request waits for the node. The pop drops the link, so the wait ends as 「結果不明」 at once and the lease goes (not
// 360 s later); a page that is gone sends no new request. Negative controls: dispose without ending the wait, or _ask
// without the `!mounted` stop -> FAIL.
import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_reactive_ble/flutter_reactive_ble.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:batman_app/nodes.dart';
import 'package:batman_app/src/nodelink/ble_gate.dart';
import 'package:batman_app/src/nodelink/core.dart' show NodeLinkCore;
import 'package:batman_app/src/nodelink/lease.dart';
import 'package:batman_app/src/nodelink/node_link.dart';
import 'package:batman_app/src/nodelink/raw_use.dart';
import 'package:batman_app/src/rust/frb_generated.dart';
// ignore: depend_on_referenced_packages
import 'package:reactive_ble_platform_interface/reactive_ble_platform_interface.dart' show CharacteristicInstance;

import 'nodes_update_send_test.dart' as u;
import 'nodelink/node_link_test.dart' as nlt show Clock, Radio, FakeProber;

class SlowSendNode extends u.FakeNode {
  Completer<void>? holdSend;
  LeaseRegistry? reg;
  final log = <String>[]; // frame -> who held the radio then
  @override
  Future<WriteCharacteristicInfo> writeCharacteristicWithoutResponse(CharacteristicInstance characteristic, List<int> value) async {
    log.add('${value[0]}:${reg?.current?.name ?? 'NO LEASE'}');
    if (value[0] == u.fSend && holdSend != null) {
      written.add(value[0]);
      final h = holdSend!;
      h.future.then((_) => values.add(CharacteristicValue(characteristic: tx!, result: Result.success([value[0] + 1]))));
      return WriteCharacteristicInfo(characteristic: characteristic, result: const Result.success(Unit()));
    }
    return super.writeCharacteristicWithoutResponse(characteristic, value);
  }
}

void main() {
  final rust = u.FakeRust();
  final node = SlowSendNode();
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

  Future<void> press(WidgetTester t, Finder f) async {
    await t.ensureVisible(f);
    await t.pump();
    await t.tap(f);
    await settle(t);
  }

  testWidgets('r5 I-m1 / I-m3: popped mid-request: the wait ends, the lease goes, nothing more is sent', (t) async {
    final clock = nlt.Clock();
    final reg = LeaseRegistry(after: clock.after);
    node.reg = reg;
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
      ..records.addAll({'node/${u.deviceId}', 'mnet/${u.netId}'});
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
    m.setMockMethodCallHandler(SystemChannels.platform, (c) async => c.method == 'Clipboard.getData' ? {'text': 'a1'} : null);
    await t.pumpWidget(MaterialApp(
        home: Builder(
            builder: (c) => TextButton(
                onPressed: () => openRawPage(Navigator.of(c), nl, gate, '我的節點', (use) => NodesPage(use: use)),
                child: const Text('open')))));
    await settle(t, 5);
    await t.tap(find.text('open'));
    await settle(t, 5);
    final lease = reg.current!;
    await press(t, find.byType(ListTile)); // log in
    await press(t, find.byKey(const Key('paste:貼上更新包'))); // import an update (mnet)
    await press(t, find.widgetWithText(TextButton, u.statusLabel)); // the status page (a route over 我的節點)
    node.holdSend = Completer<void>();
    node.disconnects.clear();
    node.log.clear();
    await t.tap(find.byKey(const Key('sendUpdate')));
    await settle(t, 5);
    expect(node.log, ['${u.fSend}:我的節點'], reason: 'the send went out under the lease');
    // the user goes back twice while the send waits for the node
    t.state<NavigatorState>(find.byType(Navigator)).pop();
    await settle(t, 5);
    t.state<NavigatorState>(find.byType(Navigator)).pop();
    await settle(t, 5);
    expect(find.byType(NodesPage), findsNothing);
    await settle(t, 25);
    expect(node.disconnects, isNotEmpty, reason: 'dispose dropped the link');
    expect(reg.current, isNull, reason: 'I-m1: the link is gone, so the lease goes at once (not after the 360 s wait)');
    await t.pump(const Duration(minutes: 7));
    await settle(t, 5);
    expect(node.log, ['${u.fSend}:我的節點'], reason: 'I-m3: nothing went out after the pop');
  });
}
