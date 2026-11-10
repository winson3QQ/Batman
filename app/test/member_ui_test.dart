// 254-app-member-join v6.1 §7: M14 (paste refused in a field build), M17 (SAS screens), M18 (status page), and the
// log interceptor. The widgets get their actions passed in, so nothing here needs BLE, Rust or the platform channel.
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:batman_app/member_ui.dart';

Widget app(Widget w) => MaterialApp(home: Scaffold(body: w));

void main() {
  group('M14 paste gate', () {
    testWidgets('a field build refuses before reading the clipboard', (t) async {
      var read = 0, got = <String>[], why = <String>[];
      await t.pumpWidget(app(PasteButton(
          label: '貼上邀請',
          devTrust: () async => false,
          readClipboard: () async {
            read++;
            return 'a201';
          },
          onText: got.add,
          onRefused: why.add)));
      await t.tap(find.text('貼上邀請'));
      await t.pumpAndSettle();
      expect(read, 0, reason: 'the clipboard is never read in a field build');
      expect(got, isEmpty);
      expect(why, ['只有開發版可以貼上']);
    });

    testWidgets('a dev build reads it', (t) async {
      final got = <String>[];
      await t.pumpWidget(app(PasteButton(
          label: '貼上邀請', devTrust: () async => true, readClipboard: () async => ' a201 ', onText: got.add, onRefused: (_) {})));
      await t.tap(find.text('貼上邀請'));
      await t.pumpAndSettle();
      expect(got, ['a201']);
    });
  });

  group('M17 SAS screens', () {
    for (final notice in [null, '申請已換新，要重新核對 SAS']) {
      testWidgets('the rule is on the screen and the action runs only on the button (notice: $notice)', (t) async {
        final calls = <String>[];
        await t.pumpWidget(MaterialApp(
            home: SasConfirmView(
                title: '核對管理者的同意',
                sas: '260515',
                notice: notice,
                confirmLabel: '確認碼相同，匯入',
                onConfirm: (s) async => calls.add(s))));
        await t.pumpAndSettle();
        expect(find.text(sasRule), findsOneWidget);
        expect(find.text('260515'), findsOneWidget);
        if (notice != null) expect(find.text(notice), findsOneWidget);
        expect(calls, isEmpty, reason: 'nothing runs before the button');
        await t.tap(find.byKey(const Key('sasConfirm')));
        await t.pumpAndSettle();
        expect(calls, ['260515'], reason: 'called once, with the SAS on the screen');
        await t.tap(find.byKey(const Key('sasConfirm')));
        await t.pumpAndSettle();
        expect(calls.length, 1, reason: 'not twice');
      });
    }

    testWidgets('the request SAS carries the rule too', (t) async {
      await t.pumpWidget(app(const SasShowView(sas: '260515', notice: '申請已換新，要重新核對 SAS')));
      expect(find.text(sasRule), findsOneWidget);
      expect(find.text('確認碼 260515'), findsOneWidget);
    });
  });

  group('M18 status page', () {
    const id = 'a5faaf844ee7c02b2909617cadbbd809';
    testWidgets('no matching record: no network name, never the id', (t) async {
      await t.pumpWidget(app(const StatusPageView(fields: StatusFields(state: '已加入網路', netId: id), names: {'00': '別的'})));
      expect(find.textContaining(id), findsNothing);
      expect(find.text('網路名稱：（不是這支手機的網路）'), findsOneWidget);
      expect(networkName(id, {'00': '別的'}), isNull);
    });
    testWidgets('a matching record: its netcfg name', (t) async {
      await t.pumpWidget(app(const StatusPageView(fields: StatusFields(state: '已加入網路', netId: id), names: {id: '家裡網路'})));
      expect(find.text('網路名稱：家裡網路'), findsOneWidget);
      expect(find.textContaining('電量'), findsNothing, reason: 'the node never sends a battery level');
    });
    testWidgets('not in a network: no name line', (t) async {
      await t.pumpWidget(app(const StatusPageView(fields: StatusFields(state: '已認領（還沒加入網路）'), names: {id: '家裡網路'})));
      expect(find.textContaining('網路名稱'), findsNothing);
    });
  });

  // HONEST SCOPE: this covers only the SAS widgets of member_ui.dart. The flows that carry z / net_root (nodes.dart:
  // ECDH, import, records) call Rust and the platform channel and are not run by `flutter test`; their log lines were
  // checked by reading them (no record bytes, z, ephemeral key or code is ever passed to _log / _say).
  group('log interceptor (SAS widgets only)', () {
    // what the SAS widgets log must never carry a secret: the interceptor sees every debugPrint line
    const secrets = ['b4d6cea19858b3a7e30115b5ca07f1138233b1e48e683c0caaa802737a647c4b', 'correct-horse-battery'];
    List<String> capture(void Function() body) {
      final lines = <String>[];
      final old = debugPrint;
      debugPrint = (String? m, {int? wrapWidth}) => lines.add(m ?? '');
      try {
        body();
      } finally {
        debugPrint = old;
      }
      return lines;
    }

    bool leaks(List<String> lines) => lines.any((l) => secrets.any(l.contains));

    test('the interceptor catches an injected secret (negative control)', () {
      final lines = capture(() => debugPrint('BMAPP owner z=${secrets[0]}'));
      expect(leaks(lines), isTrue);
    });

    testWidgets('the screens log nothing secret', (t) async {
      final lines = <String>[];
      final old = debugPrint;
      debugPrint = (String? m, {int? wrapWidth}) => lines.add(m ?? '');
      try {
        await t.pumpWidget(MaterialApp(home: SasConfirmView(title: 't', sas: '260515', confirmLabel: 'ok', onConfirm: (_) async {})));
        await t.tap(find.byKey(const Key('sasConfirm')));
        await t.pumpAndSettle();
      } finally {
        debugPrint = old;
      }
      expect(leaks(lines), isFalse);
    });
  });
}
