// #329 PR 5 §5 T-P5-L: the team flows run with marked codes, confirmation codes and names, and with the app's own
// loggers (offlineDeps' log, OpSession's debugPrint); nothing marked reaches debugPrint or a todo. Covers a Rust
// sentence carrying a name (Z-m7), joinreq's value (AB-m7) and an exception carrying a code (T-m7).
import 'package:batman_app/src/flows/offline_op.dart';
import 'package:batman_app/src/nodelink/app_link.dart';
import 'package:batman_app/src/rust/frb_generated.dart';
import 'package:batman_app/ui/join_pages.dart';
import 'package:batman_app/ui/team_deps.dart';
import 'package:batman_app/ui/team_pages.dart';
import 'package:batman_app/ui/ui_state.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'join_pages_test.dart' show World, open, paste, settle;
import 'team_pages_test.dart' show LeadRust;
import 'ui_state_test.dart' show MemStore;

/// Every value a flow below handles that must never be logged: the pasted codes, the codes and confirmation codes the
/// fakes answer with, a member's name, a name inside a Rust sentence, a code inside an exception.
const marks = [
  'INVITE',
  'APPROVAL',
  'UPDATE',
  'REQHEX',
  'PENDHEX',
  'INVHEX',
  'APPHEX',
  'BUNDLEHEX',
  '5678',
  '4821',
  '7777',
  '小明LOG',
  '王LOGNAME',
  'CODEINERR',
];

void main() {
  final rust = LeadRust();
  setUpAll(() => RustLib.initMock(api: rust));
  final lines = <String>[];
  setUp(() {
    lines.clear();
    rust.approveThrows = null;
  });

  /// [body] with debugPrint captured (given back inside the test: flutter_test checks it before the tear-downs).
  Future<void> captured(Future<void> Function() body) async {
    final old = debugPrint;
    debugPrint = (String? m, {int? wrapWidth}) => lines.add(m ?? '');
    try {
      await body();
    } finally {
      debugPrint = old;
    }
  }

  /// The fake world, but with the app's own offline logger (offlineDeps(a).log) and an ECDH that may throw [ecdhError].
  void wire(World w, {Object? ecdhError}) => teamDepsOverride = (a) {
    final d = w.deps(a);
    final real = offlineDeps(a);
    return TeamDeps(
      offline: OfflineDeps(
        acquire: d.offline.acquire,
        busyName: d.offline.busyName,
        writer: d.offline.writer,
        after: d.offline.after,
        log: real.log,
      ),
      platform: OfflinePlatform(
        seal: d.platform.seal,
        signAdmin: d.platform.signAdmin,
        ecdh: (p) => ecdhError != null ? Future.error(ecdhError) : d.platform.ecdh(p),
        readRecord: d.platform.readRecord,
        keyError: d.platform.keyError,
      ),
      op: d.op,
      publicKeys: d.publicKeys,
      nodeIds: d.nodeIds,
      send: d.send,
    );
  };

  void clean(AppLink a, String what) {
    final logged = lines.join('\n');
    for (final m in marks) {
      expect(logged.contains(m), isFalse, reason: '$what: "$m" in the log:\n$logged');
      for (final t in a.reg.unsavedText.values) {
        expect(t.contains(m), isFalse, reason: '$what: "$m" in a todo');
      }
    }
  }

  testWidgets('member: an invite, a request (joinreq value, AB-m7), an approval imported', (
    t,
  ) async {
    await captured(() async {
      final w = World(['0000aa01'], {'0000aa01': ''});
      final store = MemStore()..ids = ['0000aa01'];
      final ui = UiState(store); // T-U6 / B-m10: the team pages never write it, so no name or code can be in it
      final a = await open(t, w, (a) => JoinTeamPage(app: a, ui: ui));
      wire(w);
      await paste(t, 'INVITE');
      await t.enterText(find.byKey(const Key('join-name')), '小明LOG');
      await settle(t);
      await t.tap(find.byKey(const Key('join-go')));
      await settle(t);
      expect(find.byType(MyRequestPage), findsOneWidget, reason: 'the flow ran');
      await t.pumpWidget(const SizedBox());
      final b = await open(t, w, (a) => ImportApprovalPage(app: a, ui: ui));
      wire(w);
      await paste(t, 'APPROVAL');
      await t.tap(find.byKey(const Key('sasConfirm')));
      await settle(t);
      expect(w.disk, contains('cas mnet/nn'), reason: 'the flow ran');
      clean(a, 'member');
      clean(b, 'import');
      await t.runAsync(ui.background);
      expect([store.writes, store.removes], [0, 0], reason: 'T-U6: ui/state-v1 untouched by the team flows');
    });
  });

  testWidgets('Z-m7: Rust refuses with a sentence carrying a name -> on screen, not in the log or a todo', (t) async {
    await captured(() async {
      rust.approveThrows = '[REQ_FAIL] 王LOGNAME 的申請已經被別人同意了';
      final w = World([], {});
      final a = await open(t, w, (a) => ImportApprovalPage(app: a, ui: UiState(MemStore())));
      wire(w);
      await paste(t, 'APPROVAL');
      await t.tap(find.byKey(const Key('sasConfirm')));
      await settle(t);
      expect(find.textContaining('王LOGNAME'), findsOneWidget, reason: 'the user sees it');
      expect(lines.where((l) => l.contains('offline op')), isNotEmpty, reason: 'the logger ran');
      clean(a, 'refusal');
    });
  });

  testWidgets('T-m7: an exception carrying a code -> its type only', (t) async {
    await captured(() async {
      final w = World([], {});
      final a = await open(t, w, (a) => ImportApprovalPage(app: a, ui: UiState(MemStore())));
      wire(w, ecdhError: StateError('CODEINERR APPROVAL'));
      await paste(t, 'APPROVAL');
      await t.tap(find.byKey(const Key('sasConfirm')));
      await settle(t);
      expect(lines.where((l) => l.contains('StateError')), isNotEmpty, reason: 'logged, as a type');
      clean(a, 'exception');
    });
  });

  testWidgets('leader: an invite, a request checked and approved', (t) async {
    await captured(() async {
      final w = World([], {})..records['net/nn'] = Uint8List(5);
      final a = await open(t, w, (a) => InvitePage(app: a, netId: 'nn'));
      wire(w);
      await t.tap(find.text('在旁邊'));
      await settle(t);
      expect(find.byType(InviteCodePage), findsOneWidget, reason: 'the flow ran');
      await t.tap(find.text('下一步：收隊員的申請'));
      await settle(t);
      await paste(t, 'REQ');
      await t.tap(find.byKey(const Key('sasConfirm')));
      await settle(t);
      expect(find.byType(ApprovalCodePage), findsOneWidget, reason: 'the flow ran');
      clean(a, 'leader');
    });
  });
}
