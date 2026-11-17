// #329 PR 5 R12 (§2.5, review A M1 / M2): an offline operation revoked at the 60 s cap. The page is released at once
// (「結果不明，等一下再查」 + 「再查一次」, Back works: W-m12); when the work has really ended the result is judged in a new
// lease, row by row: removal (whole owner gone), approval import (prepared again WITHOUT the request, the leftover
// mpend removed), update import (AlreadyImported), dropping a request (mpend gone); busy -> 「再查一次」, no queueing.
import 'dart:async';
import 'dart:typed_data';

import 'package:batman_app/src/flows/offline_op.dart';
import 'package:batman_app/src/nodelink/lease.dart';
import 'package:batman_app/src/nodelink/record_writer.dart';
import 'package:batman_app/src/rust/api/member.dart' show ImportState;
import 'package:batman_app/src/rust/api/rekey.dart' show UpdateState;
import 'package:batman_app/src/rust/frb_generated.dart';
import 'package:batman_app/ui/join_choice.dart' show kNeedNewInvite;
import 'package:batman_app/ui/join_pages.dart';
import 'package:batman_app/ui/remove_pages.dart';
import 'package:batman_app/ui/team_deps.dart';
import 'package:batman_app/ui/ui_state.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'join_pages_test.dart' show World, open, paste, settle;
import 'team_pages_test.dart' show LeadRust, person;
import 'ui_state_test.dart' show MemStore;

const bob = 'OWNERBOB';

void main() {
  final rust = LeadRust();
  setUpAll(() => RustLib.initMock(api: rust));
  setUp(() {
    rust
      ..importState = ImportState.ready
      ..updateState = UpdateState.advance
      ..preparePend.clear()
      ..people = [person('OWNERME', '隊長', 'f0', self: true), person(bob, '小明', 'a1')];
  });

  /// The cap fires; the hung seal then goes on (its write is refused: the lease is revoked) and the work ends.
  Future<void> capThenEnd(WidgetTester t, World w) async {
    w.clock.advance(offlineCap);
    await settle(t);
    w.sealGate!.complete();
    await settle(t);
  }

  Finder judgeAgain(String key) => find.byKey(Key(key));

  group('8.3 removal', () {
    Future<World> start(WidgetTester t) async {
      final w = World([], {})
        ..records['net/nn'] = Uint8List(5)
        ..sealGate = Completer<void>();
      await open(t, w, (a) => RemoveConfirmPage(app: a, netId: 'nn', person: rust.people[1], owner: bob, node: ''));
      await t.tap(find.byKey(const Key('remove-tick')));
      await settle(t);
      await t.tap(find.byKey(const Key('remove-go')));
      await settle(t);
      return w;
    }

    testWidgets('M1 / W-m12: at the cap the page is released at once, the work still hanging', (t) async {
      final w = await start(t);
      w.clock.advance(offlineCap);
      await settle(t);
      expect(find.text(kUnknownWait), findsOneWidget);
      expect(judgeAgain('remove-judge'), findsOneWidget);
      expect(t.widget<PopScope>(find.byType(PopScope).first).canPop, isTrue, reason: 'Back works while the work still hangs');
    });

    testWidgets('the person gone from the record (the write landed) -> 已經移除: RemoveTicks.removed, 8.4', (t) async {
      final w = await start(t);
      rust.people = [rust.people[0]]; // what the record holds once the removal landed
      await capThenEnd(t, w);
      expect(find.byType(RekeyPage), findsOneWidget);
      expect(t.widget<RekeyPage>(find.byType(RekeyPage)).removal, isTrue);
    });

    testWidgets('still in the record -> 結果不明 with 到換密碼檢查清單 and 到隊員名單確認 (T-m4)', (t) async {
      final w = await start(t);
      await capThenEnd(t, w);
      expect(find.text('結果不明'), findsOneWidget);
      expect(find.text('到換密碼檢查清單'), findsOneWidget);
      expect(find.text('到隊員名單確認'), findsOneWidget);
      expect(find.byType(RekeyPage), findsNothing);
    });

    testWidgets('U-m / V-m6: another operation holds the radio at judging -> 再查一次, no queueing; then judged', (t) async {
      final w = await start(t);
      w.clock.advance(offlineCap);
      await settle(t);
      final other = w.reg.acquire('軟體更新', LeaseKind.session)!; // taken before the work ends
      w.sealGate!.complete();
      await settle(t);
      expect(find.text(kUnknownWait), findsOneWidget);
      expect(judgeAgain('remove-judge'), findsOneWidget);
      await other.release();
      rust.people = [rust.people[0]];
      await t.tap(judgeAgain('remove-judge'));
      await settle(t);
      expect(find.byType(RekeyPage), findsOneWidget);
    });
  });

  group('7.10 approval import', () {
    Future<World> start(WidgetTester t) async {
      final w = World([], {})..sealGate = Completer<void>();
      await open(t, w, (a) => ImportApprovalPage(app: a, ui: UiState(MemStore())));
      await paste(t, 'APPROVAL');
      await t.tap(find.byKey(const Key('sasConfirm')));
      await settle(t);
      return w;
    }

    testWidgets('W-m1: prepared again WITHOUT the request; AlreadyImported -> 已經匯入, the leftover mpend removed',
        (t) async {
      final w = await start(t);
      rust.importState = ImportState.alreadyImported; // the mnet write had landed
      await capThenEnd(t, w);
      expect(rust.preparePend.last, isFalse, reason: 'with the request prepare would bind and say Ready');
      expect(find.text('已經匯入'), findsOneWidget);
      expect(w.disk, contains('rm mpend/nn'), reason: 'or the home todo stays for ever');
      expect(find.byKey(const Key('import-join')), findsOneWidget);
    });

    testWidgets('Y-m9: NeedsNewInvite -> 結果不明 and why; nothing removed', (t) async {
      final w = await start(t);
      rust.importState = ImportState.needsNewInvite;
      await capThenEnd(t, w);
      expect(find.text('結果不明\n$kNeedNewInvite'), findsOneWidget);
      expect(w.disk, isNot(contains('rm mpend/nn')));
    });
  });

  testWidgets('8.5: AlreadyImported after the revoke -> 已經匯入 and the nodes listed; else 結果不明', (t) async {
    final w = World(['0000aa01'], {'0000aa01': 'nn'})..sealGate = Completer<void>();
    await open(t, w, (a) => UpdateImportPage(app: a, ui: UiState(MemStore())));
    await paste(t, 'UPDATE');
    expect(find.byKey(const Key('judge-again')), findsNothing);
    rust.updateState = UpdateState.alreadyImported;
    await capThenEnd(t, w);
    expect(find.text('已經匯入'), findsOneWidget);
    expect(find.byKey(const Key('update-node-0000aa01')), findsOneWidget);
  });

  testWidgets('7.9 放棄申請: mpend gone after the revoke -> 已經放棄', (t) async {
    final w = World([], {});
    final gate = Completer<void>();
    final removed = <String>[];
    // the removal itself hangs past the cap, then lands
    final writer = RecordWriter(
        w.reg,
        RecordStore(
          writeCas: (rel, g, s) async => g,
          writeSealed: (rel, g, s) async {},
          remove: (rel) async {
            await gate.future;
            removed.add(rel);
            w.records.remove(rel);
          },
          keepCopy: (rel) async => true,
        ));
    await open(t, w, (a) => MyRequestPage(app: a, ui: UiState(MemStore()), netId: 'nn'));
    teamDepsOverride = (a) {
      final d = w.deps(a);
      return TeamDeps(
          offline: OfflineDeps(acquire: d.offline.acquire, busyName: d.offline.busyName, writer: writer, after: w.clock.after),
          platform: d.platform,
          op: d.op,
          publicKeys: d.publicKeys,
          nodeIds: d.nodeIds,
          send: d.send,
          netVersion: d.netVersion,
          mnetVersion: d.mnetVersion);
    };
    await t.tap(find.text('放棄申請'));
    await settle(t);
    await t.tap(find.text('放棄申請').last);
    await settle(t);
    w.clock.advance(offlineCap);
    await settle(t);
    expect(find.text(kUnknownWait), findsOneWidget);
    // the write was already in flight before the cap: the store removes it once released (the lease check came first)
    gate.complete();
    await settle(t);
    expect(removed, ['mpend/nn']);
    expect(find.text('已經放棄'), findsOneWidget);
  });
}
