// 254-app-member-join v6.1 §7: M14 (paste refused in a field build), M17 (SAS screens), M18 (network name), and the
// log interceptor; 254-app-status-page v8.1 §5: T8 (status page) and T9 (My nodes layout). The widgets get their actions passed in, so nothing here needs BLE, Rust or the platform channel.
import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:batman_app/member_ui.dart';
import 'package:batman_app/src/rust/api/owner.dart' show OwnerStep, OwnerKind;

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

    testWidgets('a second tap while a read is in flight does nothing; the button shows it is busy', (t) async {
      final pending = Completer<StatusFields?>();
      var calls = 0;
      await t.pumpWidget(page(joined, refresh: () {
        calls++;
        return pending.future;
      }));
      // two taps before the frame that redraws the button
      await t.tap(find.byKey(const Key('refresh')));
      await t.tap(find.byKey(const Key('refresh')));
      await t.pump();
      expect(calls, 1, reason: 'one read at a time');
      expect(t.widget<FilledButton>(find.byKey(const Key('refresh'))).onPressed, isNull, reason: 'visibly disabled');
      expect(find.text('讀取中…'), findsOneWidget);
      expect(find.text('沒有讀到，請再按一次'), findsNothing, reason: 'the second tap is not a missed read');
      pending.complete(const StatusFields(color: 'red', sentence: '之前連上的隊員現在收不到'));
      await t.pumpAndSettle();
      expect(t.widget<FilledButton>(find.byKey(const Key('refresh'))).onPressed, isNotNull);
      expect(find.text('重新整理'), findsOneWidget);
      expect(find.byKey(const Key('color:red')), findsOneWidget);
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

  // 254-app-leave v4.1 §6 T3 (the page side; the outcome texts are Rust's, T1 / T2).
  group('S6 leave', () {
    // a Write step as Rust makes it (only `sent` and `frames` matter to the run loop's bookkeeping)
    OwnerStep step({required bool sent}) => OwnerStep(
        kind: OwnerKind.write,
        frames: [Uint8List(3)],
        signInput: Uint8List(0),
        detail: '',
        record: Uint8List(0),
        rel: '',
        generation: BigInt.zero,
        aad: Uint8List(0),
        expectedGen: BigInt.zero,
        pollLink: false,
        hex: '',
        sas: '',
        renewed: false,
        sent: sent,
        left: false,
        waitMs: BigInt.zero,
        sendUpdate: false,
        info: Uint8List(0));
    const member = StatusFields(
        color: 'green',
        sentence: '已連上隊伍網路',
        warning: '節點回報異常（可能是手機 Wi-Fi 還沒設定）— 設好仍然如此請找維修人員',
        membership: '網路：家裡網路（已是成員）',
        canLeave: true,
        leaveTitle: '要讓節點 …2233 離開隊伍網路嗎？',
        leaveBody: '離開後這台的 HaLow 無線電會關閉… 之後可以按「加入網路／繼續加入」再加入。');
    final at = DateTime(2026, 11, 10, 9, 5, 7);
    Widget page(StatusFields f, {Future<LeaveResult> Function()? leave}) => app(StatusPageView(
        initial: f, initialAt: at, onRefresh: () async => null, onLeave: leave, clock: () => DateTime(2026, 11, 10, 9, 6, 0)));

    testWidgets('the button shows only when the page says it can leave', (t) async {
      await t.pumpWidget(page(member, leave: () async => const LeaveResult(null, null)));
      expect(find.byKey(const Key('leave')), findsOneWidget);
      await t.pumpWidget(const SizedBox());
      await t.pumpWidget(page(const StatusFields(sentence: '這台還沒加入隊伍網路 — 請按「加入網路／繼續加入」'), leave: () async => const LeaveResult(null, null)));
      expect(find.byKey(const Key('leave')), findsNothing);
      // the k10-absent / k11-true case: Rust says canLeave (bridge view_unfinished_and_leave_button)
      await t.pumpWidget(const SizedBox());
      await t.pumpWidget(page(const StatusFields(sentence: '這台還沒加入隊伍網路', canLeave: true, unfinished: 'u', unfinishedUnderVerdict: true),
          leave: () async => const LeaveResult(null, null)));
      expect(find.byKey(const Key('leave')), findsOneWidget);
    });

    testWidgets('cancel sends nothing; confirm sends once and shows the answer and the re-read page', (t) async {
      var calls = 0;
      await t.pumpWidget(page(member, leave: () async {
        calls++;
        return const LeaveResult('[ANSWER] [LEFT] 已離開隊伍網路', StatusFields(color: 'red', sentence: '這台還沒加入隊伍網路'));
      }));
      await t.scrollUntilVisible(find.byKey(const Key('leave')), 100);
      await t.tap(find.byKey(const Key('leave')));
      await t.pumpAndSettle();
      expect(find.text('要讓節點 …2233 離開隊伍網路嗎？'), findsOneWidget);
      expect(find.textContaining('之後可以按「加入網路／繼續加入」再加入。'), findsOneWidget);
      await t.tap(find.byKey(const Key('leaveCancel')));
      await t.pumpAndSettle();
      expect(calls, 0, reason: 'cancel sends nothing');
      await t.tap(find.byKey(const Key('leave')));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const Key('leaveConfirm')));
      await t.pumpAndSettle();
      expect(calls, 1);
      expect(find.text('已離開隊伍網路'), findsOneWidget, reason: 'the answer without its markers');
      expect(find.text('這台還沒加入隊伍網路'), findsOneWidget, reason: 'the page re-read after a reply 0');
      expect(find.text('讀取於 09:06:00'), findsOneWidget);
    });

    testWidgets('the unfinished line: under the verdict without key 10, after the ⚠️ line with it', (t) async {
      double y(Finder f) => t.getTopLeft(f).dy;
      await t.pumpWidget(page(const StatusFields(sentence: '這台還沒加入隊伍網路', unfinished: '節點上還有沒完成的網路變更', unfinishedUnderVerdict: true)));
      expect(y(find.byKey(const Key('sentence'))), lessThan(y(find.byKey(const Key('unfinished')))));
      expect(y(find.byKey(const Key('unfinished'))), lessThan(y(find.byKey(const Key('readAt')))));
      await t.pumpWidget(const SizedBox());
      await t.pumpWidget(page(const StatusFields(
          sentence: '已連上隊伍網路', warning: 'w', membership: 'm', unfinished: '節點上還有沒完成的網路變更', unfinishedUnderVerdict: false)));
      expect(y(find.byKey(const Key('readAt'))), lessThan(y(find.byKey(const Key('unfinished')))));
      expect(y(find.byKey(const Key('warning'))), lessThan(y(find.byKey(const Key('unfinished')))));
      expect(y(find.byKey(const Key('unfinished'))), lessThan(y(find.byKey(const Key('membership')))));
      await t.pumpWidget(const SizedBox());
      await t.pumpWidget(page(const StatusFields(sentence: '已連上隊伍網路')));
      expect(find.byKey(const Key('unfinished')), findsNothing);
    });

    // code review B-M1: the run loop's write throws AFTER the network/leave write was marked sent; _ask says the unclear
    // line and returns null; the page shows that line (it used to show nothing — the line was under the pushed route)
    testWidgets('a write that throws after the leave went out: the page says 結果不明', (t) async {
      final track = SendTrack();
      String? said;
      Future<String?> ask({required Duration wait, required bool retry, required String unclear}) async {
        try {
          stepFrames(track, step(sent: false)); // op/nonce
          stepFrames(track, step(sent: true)); // network/leave: marked before it goes out
          throw Exception('GATT write failed half-way');
        } catch (_) {
          said = track.unclearNow(unclear); // what _ask says on a throw with an unclear line
          return null;
        }
      }

      await t.pumpWidget(page(member,
          leave: () => leaveFlow(ask: ask, askEnd: () => said, left: () => false, reread: () async => null)));
      await t.scrollUntilVisible(find.byKey(const Key('leave')), 100);
      await t.tap(find.byKey(const Key('leave')));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const Key('leaveConfirm')));
      await t.pumpAndSettle();
      expect(find.text('結果不明 — 請重新連線後看狀態頁'), findsOneWidget);
      expect(find.textContaining('還沒有寫入或送出'), findsNothing);
    });

    test('leaveFlow: no answer and nothing said -> not sent; left but the re-read failed -> stale', () async {
      Future<String?> none({required Duration wait, required bool retry, required String unclear}) async => null;
      final r = await leaveFlow(ask: none, askEnd: () => null, left: () => false, reread: () async => null);
      expect(r.line, leaveNotAsked);
      Future<String?> ok({required Duration wait, required bool retry, required String unclear}) async => '[ANSWER] [LEFT] 已離開隊伍網路';
      var reads = 0;
      final s = await leaveFlow(ask: ok, askEnd: () => null, left: () => true, reread: () async {
        reads++;
        return null;
      });
      expect((s.line, s.fields, s.stale, reads), ('[ANSWER] [LEFT] 已離開隊伍網路', null, true, 1));
      final n = await leaveFlow(ask: ok, askEnd: () => null, left: () => false, reread: () async => const StatusFields());
      expect((n.stale, n.fields), (false, null), reason: 'not a reply 0: no re-read');
      // r2 B-m1: a re-read that throws (a corrupt record) still shows the leave line, page stale
      final x = await leaveFlow(ask: ok, askEnd: () => null, left: () => true, reread: () async => throw Exception('corrupt record'));
      expect((x.line, x.fields, x.stale), ('[ANSWER] [LEFT] 已離開隊伍網路', null, true));
      // r2 A-m2: the request's own end line, not some later line
      final e = await leaveFlow(ask: none, askEnd: () => askNoLink, left: () => false, reread: () async => null);
      expect(e.line, askNoLink);
    });

    testWidgets('left but the re-read failed: the page is marked stale; the next good refresh clears the leave line', (t) async {
      await t.pumpWidget(app(StatusPageView(
          initial: member,
          initialAt: at,
          onRefresh: () async => const StatusFields(sentence: '這台還沒加入隊伍網路'),
          onLeave: () async => const LeaveResult('[ANSWER] [LEFT] 已離開隊伍網路', null, stale: true),
          clock: () => DateTime(2026, 11, 10, 9, 6, 0))));
      await t.scrollUntilVisible(find.byKey(const Key('leave')), 100);
      await t.tap(find.byKey(const Key('leave')));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const Key('leaveConfirm')));
      await t.pumpAndSettle();
      expect(find.text('已離開隊伍網路'), findsOneWidget);
      expect(find.text('沒有讀到，請再按一次'), findsOneWidget, reason: 'stale');
      await t.scrollUntilVisible(find.byKey(const Key('refresh')), -100);
      await t.tap(find.byKey(const Key('refresh')));
      await t.pumpAndSettle();
      expect(find.text('已離開隊伍網路'), findsNothing);
      expect(find.text('沒有讀到，請再按一次'), findsNothing);
    });

    test("stepFrames: the step's own sent flag is marked before its frames go out (r2 A-m1 = B-m4)", () {
      final a = SendTrack();
      stepFrames(a, step(sent: false));
      expect(a.unclearNow(leaveUnclear), notSentLine);
      stepFrames(a, step(sent: true));
      expect(a.unclearNow(leaveUnclear), leaveUnclear);
      final b = SendTrack();
      expect(stepFrames(b, step(sent: true)).frames.single.length, 3, reason: 'the frames of the step');
      expect(b.wrote, isTrue);
    });

    testWidgets('a leave without a re-read keeps the stale marker (r2 A-m3 = B-m2)', (t) async {
      await t.pumpWidget(app(StatusPageView(
          initial: member,
          initialAt: at,
          onRefresh: () async => null,
          onLeave: () async => const LeaveResult('[ANSWER] [LEFT] 這台已經不在隊伍網路裡', null),
          clock: () => DateTime(2026, 11, 10, 9, 6, 0))));
      await t.tap(find.byKey(const Key('refresh')));
      await t.pumpAndSettle();
      expect(find.text('沒有讀到，請再按一次'), findsOneWidget);
      await t.scrollUntilVisible(find.byKey(const Key('leave')), 100);
      await t.tap(find.byKey(const Key('leave')));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const Key('leaveConfirm')));
      await t.pumpAndSettle();
      expect(find.text('這台已經不在隊伍網路裡'), findsOneWidget);
      await t.scrollUntilVisible(find.byKey(const Key('refresh')), -100);
      expect(find.text('沒有讀到，請再按一次'), findsOneWidget, reason: 'still stale: nothing was read');
    });

    testWidgets('a double tap opens one dialog (r2 B-m3)', (t) async {
      await t.pumpWidget(page(member, leave: () async => const LeaveResult(null, null)));
      await t.scrollUntilVisible(find.byKey(const Key('leave')), 100);
      await t.tap(find.byKey(const Key('leave')));
      // the second tap of a double tap: the button's handler runs again while the first dialog is opening / open
      t.widget<TextButton>(find.byKey(const Key('leave'))).onPressed!();
      await t.pumpAndSettle();
      expect(find.byType(AlertDialog), findsOneWidget);
    });

    test('an Ended step: the bridge leave line as is, anything else = the link ended', () {
      expect(endedLine('[REQ_FAIL] 結果不明 — 請重新連線後看狀態頁'), '[REQ_FAIL] 結果不明 — 請重新連線後看狀態頁');
      expect(endedLine('連線出錯（Decrypt）'), '[REQ_FAIL] 連線已結束：連線出錯（Decrypt）');
    });

    test('the leave request: wait 360 s, never re-sent, the unclear line', () async {
      Duration? w;
      bool? r;
      String? u;
      await sendLeave(({required wait, required retry, required unclear}) async {
        (w, r, u) = (wait, retry, unclear);
        return null;
      });
      expect(w, const Duration(seconds: 360));
      expect(r, isFalse);
      expect(u, '[REQ_FAIL] 結果不明 — 請重新連線後看狀態頁');
    });

    test('SendTrack: only a landed record write or a step Rust marked sent counts', () {
      // a leave: op/nonce write (not sent), then the network/leave write (sent) -> a lost link is "unknown"
      final leave = SendTrack()
        ..write(sent: false)
        ..write(sent: true);
      expect(leave.unclearNow(leaveUnclear), leaveUnclear);
      // lost before the network/leave write: nothing went out
      final early = SendTrack()..write(sent: false);
      expect(early.unclearNow(leaveUnclear), notSentLine);
      // a join that drops after its owner signature but before the record write: still "not sent"
      final join = SendTrack()
        ..write(sent: false) // op/nonce
        ..write(sent: false); // anything before the Persist step
      expect(join.unclearNow('[JOIN_STATE] 結果不明'), notSentLine);
      final joined = SendTrack()..persisted();
      expect(joined.unclearNow('[JOIN_STATE] 結果不明'), '[JOIN_STATE] 結果不明');
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

  // 254-app-remove-member v6.4 §3.5 (the page side; the line and the button come from Rust: bridge status_line_rules)
  group('S6 remove member', () {
    final at = DateTime(2026, 11, 11, 9, 5, 7);
    testWidgets('the send button shows only when the page says so, sends once and shows the re-read page', (t) async {
      var calls = 0;
      Widget page(StatusFields f) => app(StatusPageView(
          initial: f,
          initialAt: at,
          onRefresh: () async => null,
          onSendUpdate: () async {
            calls++;
            return const StatusFields(sentence: '已連上隊伍網路');
          },
          clock: () => DateTime(2026, 11, 11, 9, 6, 0)));
      await t.pumpWidget(page(const StatusFields(sentence: 's', updateLine: '這台還在舊密碼 — 把新密碼送給節點', canSendUpdate: true)));
      expect(find.text('這台還在舊密碼 — 把新密碼送給節點'), findsOneWidget);
      await t.tap(find.byKey(const Key('sendUpdate')));
      await t.pumpAndSettle();
      expect(calls, 1);
      expect(find.byKey(const Key('sendUpdate')), findsNothing, reason: 'the re-read page has no button');
      // a line without the button (the member phone lacks this node's secrets / an excluded node)
      await t.pumpWidget(const SizedBox());
      await t.pumpWidget(page(const StatusFields(sentence: 's', updateLine: '這台還在舊密碼，這支手機沒有它的新密碼 — 請網主重新產生你的更新包')));
      expect(find.byKey(const Key('updateLine')), findsOneWidget);
      expect(find.byKey(const Key('sendUpdate')), findsNothing);
    });
  });
}
