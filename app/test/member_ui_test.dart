// 254-app-member-join v6.1 §7: M14 (paste refused in a field build), M17 (SAS screens), M18 (network name), and the
// log interceptor; 254-app-status-page v8.1 §5: T8 (status page) and T9 (My nodes layout). The widgets get their actions passed in, so nothing here needs BLE, Rust or the platform channel.
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

  group('M18 network name', () {
    const id = 'a5faaf844ee7c02b2909617cadbbd809';
    test('only from a record on this phone, never the id', () {
      expect(networkName(id, {'00': '別的'}), isNull);
      expect(networkName(id, {id: '家裡網路'}), '家裡網路');
      expect(networkName('', {'': 'x'}), isNull, reason: 'no key 10: no name');
    });
  });

  // 254-app-status-page v8.1 §5 T8: the page lays out what Rust decided (T1-T6 test the decision itself).
  group('T8 status page', () {
    const joined = StatusFields(
        color: 'green',
        sentence: '已連上隊伍網路',
        lagNote: '隊員剛離開或關機時，這裡最多約 4 分鐘後才會改變',
        warning: '節點回報異常（可能是手機 Wi-Fi 還沒設定）— 設好仍然如此請找維修人員',
        membership: '網路：家裡網路（已是成員）',
        version: '1.5.14-wsl.24',
        tech: ['未入網代碼（key 5）：7 NOT_JOINED SEARCHING', '上游映像（image）：OpenMANET 1.8.0', '手機 Wi-Fi 名稱尚未存檔（ssid_unsaved）']);
    final at = DateTime(2026, 11, 10, 9, 5, 7);
    Widget page(StatusFields f, {Future<StatusFields?> Function()? refresh, DateTime Function()? clock}) => app(StatusPageView(
        initial: f, initialAt: at, onRefresh: refresh ?? () async => null, clock: clock ?? () => DateTime(2026, 11, 10, 9, 6, 0)));
    double y(WidgetTester t, Finder f) => t.getTopLeft(f).dy;

    testWidgets('the verdict is the first line; 讀取於, the small print and the lines follow in order', (t) async {
      await t.pumpWidget(page(joined));
      expect(find.byKey(const Key('color:green')), findsOneWidget);
      expect(find.text('已連上隊伍網路'), findsOneWidget);
      expect(find.text('讀取於 09:05:07'), findsOneWidget);
      expect(find.text('隊員剛離開或關機時，這裡最多約 4 分鐘後才會改變'), findsOneWidget);
      final order = ['sentence', 'readAt', 'lagNote', 'warning', 'membership', 'version', 'refresh', 'tech'].map((k) => y(t, find.byKey(Key(k)))).toList();
      for (var i = 1; i < order.length; i++) {
        expect(order[i], greaterThan(order[i - 1]), reason: 'line $i below line ${i - 1}');
      }
      final firstY = y(t, find.byType(ListView).first);
      expect(y(t, find.byKey(const Key('verdict'))) - firstY, lessThan(20), reason: 'nothing above the verdict');
    });

    testWidgets('rows 3 / 4 carry the lag small print; other rows do not', (t) async {
      await t.pumpWidget(page(joined));
      expect(find.textContaining('最多約 4 分鐘'), findsOneWidget);
      await t.pumpWidget(const SizedBox());
      await t.pumpWidget(page(const StatusFields(color: 'red', sentence: '附近沒有收到其他節點的訊號')));
      expect(find.textContaining('最多約 4 分鐘'), findsNothing);
    });

    testWidgets('node English and image only in the collapsed technical list', (t) async {
      await t.pumpWidget(page(joined));
      expect(find.textContaining('SEARCHING'), findsNothing);
      expect(find.textContaining('OpenMANET'), findsNothing);
      expect(find.textContaining('ssid_unsaved'), findsNothing);
      await t.tap(find.text('技術資訊（給維修人員看）'));
      await t.pumpAndSettle();
      expect(find.textContaining('SEARCHING'), findsOneWidget);
      expect(find.text('上游映像（image）：OpenMANET 1.8.0'), findsOneWidget);
      expect(find.text('手機 Wi-Fi 名稱尚未存檔（ssid_unsaved）'), findsOneWidget);
      expect(find.textContaining('電量'), findsNothing, reason: 'the node never sends a battery level');
    });

    testWidgets('重新整理 reads again; a fresh read shows the new time', (t) async {
      var calls = 0;
      await t.pumpWidget(page(joined, refresh: () async {
        calls++;
        return const StatusFields(color: 'red', sentence: '之前連上的隊員現在收不到');
      }));
      await t.tap(find.byKey(const Key('refresh')));
      await t.pumpAndSettle();
      expect(calls, 1);
      expect(find.byKey(const Key('color:red')), findsOneWidget);
      expect(find.text('讀取於 09:06:00'), findsOneWidget);
    });

    testWidgets('E_RATE keeps the earlier verdict and its read time, with the note', (t) async {
      // Rust keeps the earlier verdict on E_RATE (bridge status_page_rate_limit_keeps_the_earlier_read): fresh false
      await t.pumpWidget(page(joined, refresh: () async => const StatusFields(
          color: 'green', sentence: '已連上隊伍網路', lagNote: '隊員剛離開或關機時，這裡最多約 4 分鐘後才會改變', rateNote: '太快了，請稍等一秒', fresh: false)));
      await t.tap(find.byKey(const Key('refresh')));
      await t.pumpAndSettle();
      expect(find.text('已連上隊伍網路'), findsOneWidget);
      expect(find.text('讀取於 09:05:07'), findsOneWidget, reason: 'the earlier read time, not the refresh time');
      expect(find.text('太快了，請稍等一秒'), findsOneWidget);
    });

    testWidgets('a refresh that reads nothing says so; the next read clears it', (t) async {
      StatusFields? next;
      await t.pumpWidget(page(joined, refresh: () async => next));
      expect(find.text('沒有讀到，請再按一次'), findsNothing);
      await t.tap(find.byKey(const Key('refresh')));
      await t.pumpAndSettle();
      expect(find.text('沒有讀到，請再按一次'), findsOneWidget);
      expect(find.text('已連上隊伍網路'), findsOneWidget, reason: 'the earlier verdict stays');
      expect(find.text('讀取於 09:05:07'), findsOneWidget);
      next = const StatusFields(color: 'red', sentence: '之前連上的隊員現在收不到');
      await t.tap(find.byKey(const Key('refresh')));
      await t.pumpAndSettle();
      expect(find.text('沒有讀到，請再按一次'), findsNothing);
    });

    test('reopening within the quota keeps the last fresh read time (ReadClock)', () {
      final c = ReadClock();
      final t1 = DateTime(2026, 11, 10, 9, 0, 0), t2 = DateTime(2026, 11, 10, 9, 0, 1), t3 = DateTime(2026, 11, 10, 9, 0, 5);
      expect(c.stamp(fresh: true, now: t1), t1);
      expect(c.stamp(fresh: false, now: t2), t1, reason: 'E_RATE on reopening: the earlier verdict keeps its time');
      expect(c.last, t1);
      expect(c.stamp(fresh: true, now: t3), t3);
      expect(ReadClock().stamp(fresh: false, now: t2), t2, reason: 'no earlier read to keep');
    });

    test('readTime', () {
      final now = DateTime(2026, 1, 1, 1, 1, 1);
      expect(readTime(fresh: true, now: now, previous: at), now);
      expect(readTime(fresh: false, now: now, previous: at), at);
      expect(readTime(fresh: false, now: now), now, reason: 'nothing earlier to keep');
      expect(hms(DateTime(2026, 1, 1, 7, 8, 9)), '07:08:09');
    });
  });

  // §5 T9 (f139951): on a 360 x 640 phone the last control (「加入隊伍網路」) can be scrolled to and pressed.
  group('T9 My nodes layout', () {
    testWidgets('360 x 640: 加入隊伍網路 scrolls into view and is pressed', (t) async {
      t.view.physicalSize = const Size(360, 640);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.reset);
      var pressed = 0;
      // the same kinds of rows as My nodes (nodes.dart build), as many as a logged-in phone with an invite shows
      final controls = <Widget>[
        for (var i = 0; i < 3; i++) ListTile(title: Text('節點 …000$i'), subtitle: const Text('點一下連線')),
        for (var i = 0; i < 6; i++)
          Row(children: [
            Expanded(child: TextField(decoration: InputDecoration(labelText: '欄位 $i'))),
            OutlinedButton(onPressed: () {}, child: Text('動作 $i')),
          ]),
        const Text('遠端邀請（開發版）'),
        Wrap(spacing: 8, children: [for (var i = 0; i < 4; i++) OutlinedButton(onPressed: () {}, child: Text('貼上 $i'))]),
        TextButton(onPressed: () {}, child: const Text('再顯示申請')),
        Align(alignment: Alignment.centerLeft, child: OutlinedButton(onPressed: () => pressed++, child: const Text('加入隊伍網路'))),
      ];
      await t.pumpWidget(MaterialApp(
          home: Scaffold(
              appBar: AppBar(title: const Text('我的節點')),
              body: Padding(padding: const EdgeInsets.all(12), child: ControlsAndLog(controls: controls, log: [for (var i = 0; i < 40; i++) 'line $i'])))));
      final target = find.text('加入隊伍網路');
      await t.scrollUntilVisible(target, 120, scrollable: find.byType(Scrollable).first);
      await t.pumpAndSettle();
      final r = t.getRect(target);
      expect(r.height, greaterThan(10), reason: 'laid out, not squeezed');
      expect(r.bottom, lessThanOrEqualTo(640));
      await t.tap(target);
      expect(pressed, 1);
      expect(t.takeException(), isNull, reason: 'no overflow');
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
