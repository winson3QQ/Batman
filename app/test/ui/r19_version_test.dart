// #329 PR 5 R19 (§2.9.1): every version number on screen is read from the record itself. Leader (8.1, 8.4): on open,
// on returning from a page above (AC-M1) and whenever NetIndex notifies; reading shows no number, unreadable says so.
// Member (8.5, sendNewKey, the member run): the record this import / send used, with the network's name (AB-m1).
// Until the codegen runs, the app's bridge does not carry the field (always 「讀不到」); these tests drive the readers.
import 'dart:async';
import 'dart:typed_data';

import 'package:batman_app/src/flows/net_index.dart';
import 'package:batman_app/src/flows/rekey_send.dart';
import 'package:batman_app/src/rust/frb_generated.dart';
import 'package:batman_app/ui/join_pages.dart';
import 'package:batman_app/ui/remove_pages.dart';
import 'package:batman_app/ui/team_pages.dart';
import 'package:batman_app/ui/ui_state.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'join_pages_test.dart' show World, open, paste, settle;
import 'team_pages_test.dart' show LeadRust, person;
import 'ui_state_test.dart' show MemStore;

void main() {
  final rust = LeadRust();
  setUpAll(() => RustLib.initMock(api: rust));
  setUp(() => rust.people = [person('OWNERME', '隊長', 'f0', self: true), person('OWNERBOB', '小明', 'a1')]);

  String shown(WidgetTester t, String key) => t.widget<Text>(find.byKey(Key(key))).data!;

  group('leader (8.1 / 8.4)', () {
    testWidgets('8.1: reading -> no number; then the record\'s; NetIndex notifies -> read again', (t) async {
      final w = World([], {})..versionGate = Completer<void>();
      w.versions['net/nn'] = const VersionRead(4);
      final a = await open(t, w, (a) => MembersPage(app: a, netId: 'nn'));
      expect(shown(t, 'net-version'), '正在讀取版本');
      w.versionGate!.complete();
      await settle(t);
      expect(shown(t, 'net-version'), '目前是第 4 版');
      w.versions['net/nn'] = const VersionRead(5);
      a.nets.setForTest(const NetSnapshot()); // a recomputation ended: only the trigger
      await settle(t);
      expect(shown(t, 'net-version'), '目前是第 5 版');
    });

    testWidgets('AC-M1: back on 8.1 from a page above (e.g. after a removal) -> the new number', (t) async {
      final w = World([], {})..records['net/nn'] = Uint8List(5);
      w.versions['net/nn'] = const VersionRead(4);
      await open(t, w, (a) => MembersPage(app: a, netId: 'nn'));
      expect(shown(t, 'net-version'), '目前是第 4 版');
      await t.tap(find.byKey(const Key('person-OWNERBOB')));
      await settle(t);
      w.versions['net/nn'] = const VersionRead(5); // the removal wrote version 5
      await t.state<NavigatorState>(find.byType(Navigator)).maybePop();
      await settle(t);
      expect(shown(t, 'net-version'), '目前是第 5 版');
    });

    testWidgets('8.4: the record\'s number; unreadable -> 版本讀不到 (never 0)', (t) async {
      final w = World([], {});
      w.versions['net/nn'] = const VersionRead(7);
      await open(t, w, (a) => RekeyPage(app: a, netId: 'nn'));
      expect(shown(t, 'net-version'), '目前是第 7 版');
      await t.pumpWidget(const SizedBox()); // a fresh 8.4
      final w2 = World([], {});
      await open(t, w2, (a) => RekeyPage(app: a, netId: 'nn'));
      expect(shown(t, 'net-version'), '版本讀不到');
    });
  });

  group('member (8.5 / sendNewKey)', () {
    testWidgets('8.5: the only team network before a paste; the imported one after (Z-m4); the send\'s own record',
        (t) async {
      final w = World(['0000aa01'], {'0000aa01': 'nn'});
      w.versions['mnet/nn'] = const VersionRead(2, name: '山隊');
      await open(t, w, (a) {
        a.nets.setForTest(const NetSnapshot(anyMnet: true, mnetIds: ['nn']));
        return UpdateImportPage(app: a, ui: UiState(MemStore()));
      });
      expect(shown(t, 'update-version'), '這支手機是第 2 版（網路「山隊」）');
      w.versions['mnet/nn'] = const VersionRead(3, name: '山隊'); // the import writes version 3
      await paste(t, 'UPDATE');
      expect(shown(t, 'update-version'), '這支手機是第 3 版（網路「山隊」）');
      w.versionReads.clear();
      w.versions['mnet/nn'] = const VersionRead(4, name: '山隊'); // what the record holds when step 3 hands it over
      await t.tap(find.descendant(of: find.byKey(const Key('update-node-0000aa01')), matching: find.text('送出')));
      await settle(t);
      await t.tap(find.text('送出').last);
      await settle(t);
      expect(w.versionReads, ['mnet/nn'], reason: 'AD-m2: read once, in step 3, the record handed to Rust');
      expect(shown(t, 'rekey-version'), '這支手機是第 4 版（網路「山隊」）', reason: "the send's own record, not the page's");
    });

    testWidgets('a leader\'s send reads no member version', (t) async {
      final w = World(['0000aa01'], {'0000aa01': 'nn'})..records['net/nn'] = Uint8List(5);
      final a = await open(t, w, (a) => const SizedBox());
      // sendNewKey on the same fake deps the pages use (a leader's record: net/nn)
      final r = await t.runAsync(
          () => sendNewKey(w.deps(a).send(t.element(find.byType(SizedBox))), '0000aa01', gone: () => false));
      expect(r!.member, isFalse);
      expect(w.versionReads, isEmpty, reason: "only a member's send reads a version");
    });
  });
}
