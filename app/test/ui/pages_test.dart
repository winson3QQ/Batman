// #329 §9.1 for the new pages: T-N1 (「從這支手機移除這台節點」), T-H4 (an entry a key cannot serve is grey with its
// reason), T-U5 (a stored read time in the future says only 「之前讀過」).
import 'package:batman_app/key_abilities.dart';
import 'package:batman_app/src/nodelink/app_link.dart';
import 'package:batman_app/src/nodelink/core.dart';
import 'package:batman_app/src/rust/frb_generated.dart';
import 'package:batman_app/ui/home_logic.dart';
import 'package:batman_app/ui/home_page.dart';
import 'package:batman_app/ui/node_page.dart';
import 'package:batman_app/ui/theme.dart';
import 'package:batman_app/ui/ui_state.dart';
import 'package:flutter/material.dart' hide Page;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../nodelink/app_link_test.dart' show StatusBle;
import 'ui_state_test.dart' show MemStore;

const id = '0000000000000c4f2a7d2c';

class FakeRust implements RustLibApi {
  final calls = <String>[];
  bool copyOk = true;
  @override
  Future<bool> crateApiClaimStoreKeepCopy({required String dir, required String rel}) async {
    calls.add('copy $rel');
    return copyOk;
  }

  @override
  Future<void> crateApiClaimStoreRemove({required String dir, required String rel}) async => calls.add('remove $rel');
  @override
  Future<List<String>> crateApiOwnerListNodes({required String dir}) async => const [];
  @override
  dynamic noSuchMethod(Invocation i) => throw UnimplementedError('${i.memberName}');
}

KeyAbilities keys({bool claim = true}) => KeyAbilities.from({
      'RECORD_AES': 1,
      'OWNER_SIGN': 1,
      'ADMIN_SIGN': 1,
      'OWNER_ENC': claim ? 1 : 0,
      'appUsable': true,
      'claim': claim,
      'login': true,
      'recover': claim,
      'makeNetwork': true,
      'softOwnerEnc': false,
    });

AppLink app() {
  AppLink.forgetForTest();
  final a = AppLink.create(platform: const MethodChannel('dev.batman/platform'), filesDir: '/x', ble: StatusBle());
  a.link.core.setRecords(const [Rec(id, 1)]);
  return a;
}

Widget host(Widget w) => MaterialApp(theme: batThemeData(Brightness.light), home: w);

void main() {
  final rust = FakeRust();
  setUpAll(() => RustLib.initMock(api: rust));
  setUp(() => rust
    ..calls.clear()
    ..copyOk = true);

  group('T-N1 remove from this phone', () {
    Future<(AppLink, UiState, MemStore)> open(WidgetTester t) async {
      final a = app();
      final store = MemStore()..ids = [id];
      final ui = UiState(store);
      await t.runAsync(ui.load);
      await t.runAsync(() => ui.noteReads({id: ('ok', DateTime.utc(2026))}));
      await t.pumpWidget(host(NodePage(app: a, id: id, ui: ui)));
      await t.tap(find.text('從這支手機移除這台節點'));
      await t.pumpAndSettle();
      return (a, ui, store);
    }

    testWidgets('confirmed: a copy, then the record goes, UiState forgets it, no Bluetooth', (t) async {
      final (a, ui, _) = await open(t);
      await t.tap(find.widgetWithText(FilledButton, '移除'));
      await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
      await t.pumpAndSettle();
      expect(rust.calls, ['copy node/$id', 'remove node/$id']);
      expect(ui.nodes.containsKey(id), isFalse);
      expect((a.gate.links, a.gate.scans), (0, 0));
      expect(a.reg.current, isNull, reason: 'the lease is released');
      a.link.dispose();
      await t.pumpWidget(const SizedBox());
      AppLink.forgetForTest();
    });

    testWidgets('cancelled: nothing changes', (t) async {
      final (_, ui, _) = await open(t);
      await t.tap(find.text('取消'));
      await t.pumpAndSettle();
      expect(rust.calls, isEmpty);
      expect(ui.nodes.containsKey(id), isTrue);
      AppLink.forgetForTest();
    });

    testWidgets('no copy could be kept: nothing is deleted, the user is told', (t) async {
      rust.copyOk = false;
      final (_, ui, _) = await open(t);
      await t.tap(find.widgetWithText(FilledButton, '移除'));
      await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
      await t.pumpAndSettle();
      expect(rust.calls, ['copy node/$id']);
      expect(ui.nodes.containsKey(id), isTrue);
      expect(find.textContaining('沒有移除'), findsOneWidget);
      AppLink.instance!.link.dispose();
      await t.pumpWidget(const SizedBox());
      AppLink.forgetForTest();
    });
  });

  testWidgets('T-H4: 新增節點 is grey with the key\'s own reason when the keys cannot claim', (t) async {
    final ui = UiState(MemStore());
    final k = keys(claim: false);
    await t.pumpWidget(host(HomePage(app: app(), ui: ui, devTrust: false, keys: k)));
    await t.pump();
    expect(find.text(k.refusal(KeyUse.claim)!), findsOneWidget);
    await t.tap(find.text('新增節點').last);
    await t.pump();
    expect(find.text('認領節點'), findsNothing, reason: 'the older claim page does not open');
    await t.pumpWidget(const SizedBox());
    await t.pumpWidget(host(HomePage(app: app(), ui: ui, devTrust: false, keys: keys())));
    await t.pump();
    expect(find.text('把另一台節點加入這支手機'), findsOneWidget, reason: 'allowed: the plain line');
    await t.pumpWidget(const SizedBox());
    AppLink.forgetForTest();
  });

  test('T-U5: an earlier run\'s read time in the future says only 之前讀過', () {
    final s = NodeState();
    NodeInfo n(int at) => NodeInfo(
        id: id,
        name: '節點 7D2C',
        state: s,
        fresh: false,
        shownWhy: null,
        prev: UiNode(look: 'ok', readAt: at));
    final now = DateTime.now().toUtc().millisecondsSinceEpoch ~/ 1000;
    expect(nodeRowWords(n(now + 3600), firstRounds: false).$2, '之前讀過');
    expect(nodeRowWords(n(now - 60), firstRounds: false).$2, startsWith('上次讀取 '));
    expect(nodeRowWords(n(now - 60), firstRounds: false).$2, endsWith('，當時正常'));
    expect(nodeRowWords(n(now - 60), firstRounds: false).$1.name, 'unk', reason: 'T2: old data only in the unk style');
  });
}
