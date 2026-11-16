// #329 PR 3 v18 §2.9 (AG-M1, code review A m-4): Kotlin's `open` answers every failure with the code "keystore", so a
// record that does not open is 「這筆打不開」 — never a key error, never an exception out of the flows. The app's two
// readers: ConsolePlatform.readRecord (the console's requests) and flowDeps.applied (a record read again under the
// lease). Real AppLink, fake Rust store, mocked platform channel.

import 'package:batman_app/src/nodelink/app_link.dart';
import 'package:batman_app/src/nodelink/ble_gate.dart';
import 'package:batman_app/src/nodelink/handoff.dart';
import 'package:batman_app/src/nodelink/lease.dart';
import 'package:batman_app/src/rust/api/owner.dart';
import 'package:batman_app/src/rust/frb_generated.dart';
import 'package:batman_app/src/flows/net_index.dart';
import 'package:batman_app/src/flows/net_run.dart';
import 'package:batman_app/ui/net_pages.dart';
import 'package:batman_app/ui/ui_state.dart';
import 'package:batman_app/ui/widgets.dart' show Btn;
import 'package:flutter/material.dart' hide Page;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../nodelink/node_link_test.dart' as nlt show Radio;
import '../flows/net_run_test.dart' show World, ans, pend;
import 'net_pages_test.dart' as npt show deps;
import 'pages_test.dart' show FakeRust, app, host, id;
import 'ui_state_test.dart' show MemStore;

class StoreRust extends FakeRust {
  SealedRecord? sealed;
  bool applied = true;
  @override
  Future<SealedRecord?> crateApiOwnerStoreReadSealed({required String dir, required String rel}) async => sealed;
  @override
  NetView crateApiOwnerNetSummary({required List<int> recordPlain}) =>
      NetView(netId: 'n', meshId: 'bm', netName: 'n', applied: applied, country: 'US', members: const []);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final rust = StoreRust();
  setUpAll(() => RustLib.initMock(api: rust));

  Object? openFails; // what the platform's `open` throws (null = it opens)
  setUp(() {
    rust
      ..sealed = SealedRecord(generation: BigInt.from(7), sealed: Uint8List(3), aad: Uint8List(1))
      ..applied = true;
    openFails = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('dev.batman/platform'), (c) async {
      if (c.method != 'open') return null;
      final f = openFails;
      if (f != null) throw f;
      return Uint8List(4);
    });
  });
  tearDown(AppLink.forgetForTest);

  test('readRecord: a record that does not open (keystore) -> its generation and no bytes, not an error', () async {
    final a = app();
    openFails = PlatformException(code: 'keystore', message: 'AEADBadTagException');
    final (gen, plain) = await a.console.readRecord('net/n');
    expect((gen, plain), (BigInt.from(7), null));
    openFails = null;
    final (_, ok) = await a.console.readRecord('net/n');
    expect(ok, isNotNull);
    rust.sealed = null;
    final (g0, none) = await a.console.readRecord('net/n');
    expect((g0, none), (BigInt.zero, null), reason: 'no record');
  });

  test('flowDeps.applied: opens -> the record\'s applied; does not open / no record -> false (檢查網路), never a throw',
      () async {
    final a = app();
    final l = a.reg.acquire('建立網路', LeaseKind.session)!;
    final applied = flowDeps(a, l, askCountry: (_) async => false, askRemoved: (_) async => false).applied;
    expect(await applied('net/n'), isTrue);
    rust.applied = false;
    expect(await applied('net/n'), isFalse);
    rust.applied = true;
    openFails = PlatformException(code: 'keystore');
    expect(await applied('net/n'), isFalse);
    openFails = null;
    rust.sealed = null;
    expect(await applied('net/n'), isFalse);
    await l.release();
  });

  test('code review C N-5: flowDeps hands the page\'s onLost to the console it builds (§2.9 wiring)', () async {
    final a = app();
    final l = a.reg.acquire('建立網路', LeaseKind.session)!;
    final reg = LeaseRegistry(after: (d, f) => () {});
    final gate = BleGate(nlt.Radio(), reg, now: () => 0, after: (d, f) => () {});
    final link = gate.connect(reg.token, 'a1');
    void lost() {}
    final c = flowDeps(a, l, askCountry: (_) async => false, askRemoved: (_) async => false, onLost: lost)
        .console(LoginHandoff(id: 'Y1', link: link, inbox: FrameInbox()));
    expect(identical(c.onLost, lost), isTrue);
    await l.release();
  });

  testWidgets('code review D m-1: a result row made good by 檢查網路 no longer reads 「網路沒有建立完成」', (t) async {
    final a = app();
    final l = (await t.runAsync(() => a.link.acquire('建立網路', LeaseKind.session)))!;
    final w = World()
      ..appliedAfterMake = false
      ..dac[id] = 'd4'
      ..script('make', [ans('[NET_STATE] 結果不明', rel: 'net/n1')])
      ..script('confirm', [ans('[NET_STATE] 沒有套用'), ans('[NET_STATE] 網路已建立')]);
    await t.pumpWidget(host(NetRunPage(
      app: a,
      ui: UiState(MemStore()..ids = [id]),
      lease: l,
      ids: const [id],
      makes: true,
      flow: (go, _, _, _) => NetRun(npt.deps(w, l), ids: const [id], makes: true, askGoOn: go),
      checkFlow: (lease, i) => CheckRun(npt.deps(w, lease), id: i, snapshot: () async => NetSnapshot(netFiles: 1, nets: [pend('n1', 'd4')])),
    )));
    for (var i = 0; i < 6; i++) {
      await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
      await t.pump(const Duration(milliseconds: 200));
    }
    expect(find.textContaining('網路沒有建立完成'), findsOneWidget);
    await t.tap(find.widgetWithText(OutlinedButton, Btn.checkNetwork));
    await t.pumpAndSettle();
    w.confirmApplies.add('net/n1'); // now the node has it: the check upgrades the record
    await t.tap(find.widgetWithText(FilledButton, Btn.start));
    for (var i = 0; i < 6; i++) {
      await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
      await t.pump(const Duration(milliseconds: 200));
    }
    await t.tap(find.widgetWithText(FilledButton, Btn.done));
    await t.pumpAndSettle();
    for (var i = 0; i < 6; i++) {
      await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
      await t.pump(const Duration(milliseconds: 200));
    }
    expect(find.text('網路已建立'), findsWidgets, reason: 'the row read again from its record (StoreRust: applied)');
    expect(find.textContaining('網路沒有建立完成'), findsNothing);
    await t.pumpWidget(const SizedBox());
    await a.link.dispose();
    await t.pump(const Duration(seconds: 10));
  });
}
