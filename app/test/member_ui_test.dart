// 254-app-member-join v6.1 §7: M14 (paste refused in a field build), M17 (SAS screens), M18 (network name), and the
// log interceptor; the leave / send steps of 254-app-leave / remove-member. The widgets get their actions passed in, so
// nothing here needs BLE, Rust or the platform channel. (#329 PR 6: the old status page and My nodes layout tests went
// with the old console; their equivalents are listed in the PR 6 migration table.)

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
                title: '核對隊長的同意',
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
        info: Uint8List(0),
        sw: false,
        note: "",
        loginEnd: 0,
        loginCode: BigInt.zero);

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

  // HONEST SCOPE: this covers only the SAS widgets of member_ui.dart. The flows that carry z / net_root (join_pages.dart:
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

  // 254-app-team-status §4.2 (B-M2): the duplicate-address line of an approval / removal is shown in a dialog; no
  // dialog without a line. Negative control: showDupNote returning early -> FAIL.
  group('duplicate address hint', () {
    Widget host(String note) => app(Builder(builder: (c) => TextButton(onPressed: () => showDupNote(c, note), child: const Text('go'))));
    testWidgets('the line from Rust is shown, nothing when there is none', (t) async {
      const line = '『客廳』和『書房』的網路位址相同，兩台都沒有登記 — 全隊狀態會顯示「沒有登記網路位址」';
      await t.pumpWidget(host(line));
      await t.tap(find.text('go'));
      await t.pumpAndSettle();
      expect(find.text(dupNoteTitle), findsOneWidget);
      expect(find.text(line), findsOneWidget);
      await t.tap(find.text('好'));
      await t.pumpAndSettle();
      expect(find.text(dupNoteTitle), findsNothing);
      await t.pumpWidget(host(''));
      await t.tap(find.text('go'));
      await t.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
    });
  });
}
