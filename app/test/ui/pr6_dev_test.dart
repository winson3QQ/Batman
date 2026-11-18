// #329 PR 6 (plan §7): T6-3 the SSH key page, T6-4 (Dart) 查看節點設定, T6-5 診斷, T6-7 the home status time (D9),
// T6-8 NetFormPage's own subscription (D10), T6-12 the text log (mask, the lease / write events), T6-14 the orphan
// joins (NetIndex and the page). The node side is op_session_test's Fx (a fake console per login); the Rust parts the
// pages call are faked here (their own rules are Rust tests: api/ssh.rs, owner.rs settings_text).

import 'package:batman_app/key_abilities.dart';
import 'package:batman_app/say.dart' show techTitle;
import 'package:batman_app/src/flows/net_index.dart';
import 'package:batman_app/src/nodelink/app_link.dart';
import 'package:batman_app/src/nodelink/core.dart';
import 'package:batman_app/src/nodelink/lease.dart';
import 'package:batman_app/src/nodelink/record_writer.dart';
import 'package:batman_app/src/rust/api/owner.dart';
import 'package:batman_app/src/rust/api/rekey.dart' show PersonNode, PersonView;
import 'package:batman_app/src/rust/frb_generated.dart';
import 'package:batman_app/ui/dev_pages.dart';
import 'package:batman_app/ui/diag_page.dart';
import 'package:batman_app/ui/home_logic.dart';
import 'package:batman_app/ui/net_pages.dart' show NetFormPage;
import 'package:batman_app/ui/remove_pages.dart' show RemoveConfirmPage;
import 'package:batman_app/ui/ui_state.dart';
import 'package:batman_app/ui/widgets.dart' show BatButton, BtnKind;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../flows/op_session_test.dart' show Fx;
import '../flows/owner_console_pr4_test.dart' show P4Session;
import '../support/fake_node.dart' as fake;
import 'home_logic_test.dart' show node;
import 'pages_test.dart' show app, host, id, keys;
import 'ui_state_test.dart' show MemStore;

// ssh-keygen -lf (OpenSSH, WSL Ubuntu 24.04, 2026-11-18): throwaway keys made for the tests (as api/ssh.rs)
const k1 = 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAaL1R+1HSxy0in+JB+NmzAgWcGutvddS5VwtznDJFaC lab@test';
const f1 = 'SHA256:Eg+nWtOYtyqtCfRoM/7tO75hY9WROxklHyY+1YiCXCI';
const k2 = 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIEkZLcMu9wTMEoJgzZvcq3AtMLy8j2y4bm6F/iW6Qz9Z ';
const f2 = 'SHA256:viFJWaOp4vg6jfumspq8LSMb0ChDfnBQjyhjnC7mHGU';

class DevRust extends fake.FakeRust {
  final checked = <String>[]; // every line the page asked Rust about
  final forgot = <String>[]; // dac hashes netForgetJoining was asked to forget
  Object? readThrows; // review pr6 A-7: reading a sealed record throws this (a non-String exception)
  List<PersonView>? people; // review pr6 A-5: netPeople's answer (null = FakeRust's)

  // the two vectors are taken; anything else is refused with the Rust words for its case
  @override
  String? crateApiSshSshLineProblem({required String line}) {
    checked.add(line);
    if (line == k1 || line == k2) return null;
    if (line.contains('\r')) return '行中間有換行字元';
    if (line.length > 256) return '超過 256 個位元組';
    return '不是節點接受的格式：要是 ssh-ed25519 公鑰，後面的註解最多 40 個可列印 ASCII 字元';
  }

  @override
  String? crateApiSshSshFingerprint({required String line}) => switch (line) { k1 => f1, k2 => f2, _ => null };

  @override
  Future<SealedRecord?> crateApiOwnerStoreReadSealed({required String dir, required String rel}) {
    final e = readThrows;
    if (e != null) throw e;
    return super.crateApiOwnerStoreReadSealed(dir: dir, rel: rel);
  }

  @override
  List<PersonView> crateApiRekeyNetPeople({required List<int> recordPlain, required List<int> ownerPub}) =>
      people ?? super.crateApiRekeyNetPeople(recordPlain: recordPlain, ownerPub: ownerPub);

  @override
  OwnerStep crateApiOwnerNetForgetJoining({required List<int> recordPlain, required BigInt recordGen, required String dacHash}) {
    forgot.add(dacHash);
    return super.crateApiOwnerNetForgetJoining(recordPlain: recordPlain, recordGen: recordGen, dacHash: dacHash);
  }
}

String? clip; // what the page put on the clipboard

void mockChannels(WidgetTester t) {
  clip = null;
  final m = t.binding.defaultBinaryMessenger;
  m.setMockMethodCallHandler(SystemChannels.platform, (c) async {
    if (c.method == 'Clipboard.setData') clip = (c.arguments as Map)['text'] as String?;
    return null;
  });
  m.setMockMethodCallHandler(const MethodChannel('dev.batman/platform'), (c) async {
    switch (c.method) {
      case 'appVersion':
        return '1.6.0+12';
      case 'flavor':
        return 'dev';
      case 'open':
        return Uint8List(4);
      case 'seal':
        return Uint8List(3);
      case 'publicKeys':
        return {'owner': Uint8List(65), 'admin': Uint8List(65)};
    }
    return null;
  });
}

MemberView member(String deviceId, String dac, {bool joining = true}) => MemberView(
    name: 'n',
    last4: deviceId.isEmpty ? '' : deviceId.substring(deviceId.length - 4),
    deviceId: deviceId,
    joining: joining,
    prevCountry: '',
    dacHash: dac,
    creator: false,
    approved: false);

NetView net(List<MemberView> ms) =>
    NetView(netId: 'n1', meshId: 'bm-0123', netName: '山隊', applied: true, country: 'US', members: ms);

void main() {
  final rust = DevRust();
  setUpAll(() => RustLib.initMock(api: rust));
  setUp(() {
    rust
      ..checked.clear()
      ..forgot.clear()
      ..readThrows = null
      ..people = null
      ..calls.clear()
      ..records.clear();
  });
  tearDown(AppLink.forgetForTest);

  Future<void> settle(WidgetTester t, Fx f) async {
    for (var i = 0; i < 6; i++) {
      await t.runAsync(() async {
        for (final r in f.rigs) {
          await r.clock.run(500);
        }
      });
      await t.pump(const Duration(milliseconds: 100));
    }
  }

  // ---- T6-3 SSH 金鑰 ---------------------------------------------------------------------------------------------

  group('T6-3 SSH keys page', () {
    Future<(Fx, AppLink)> open(WidgetTester t, {bool dev = true}) async {
      mockChannels(t);
      final f = Fx(rust, logins: 1);
      final a = app()..devTrust = dev;
      t.view.physicalSize = const Size(1080, 4000);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.reset);
      await t.pumpWidget(host(SshKeysPage(app: a, ui: UiState(MemStore()), deps: f.d)));
      await t.tap(find.byKey(const Key('pick-$id')));
      await t.pump();
      return (f, a);
    }

    BatButton send(WidgetTester t) => t.widget<BatButton>(find.byKey(const Key('ssh-send')));
    List<String> asked(Fx f) => (f.rigs[0].session as P4Session).asked;

    // S20 device session 2026-11-18: with the phone's only node the button did nothing until its row was tapped. One
    // node -> picked already; the line goes out without touching the row. Negative control: `_id` starting null -> FAIL.
    testWidgets('one node: picked already, sent without tapping its row', (t) async {
      mockChannels(t);
      final f = Fx(rust, logins: 1);
      final a = app()..devTrust = true;
      expect(a.link.core.states.keys, [id], reason: 'premise: one node');
      t.view.physicalSize = const Size(1080, 4000);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.reset);
      await t.pumpWidget(host(SshKeysPage(app: a, ui: UiState(MemStore()), deps: f.d)));
      await t.enterText(find.byKey(const Key('ssh-lines')), k1);
      await t.pump();
      await t.tap(find.byKey(const Key('ssh-send')));
      await settle(t, f);
      expect(asked(f), ['ssh_keys/set 1: $k1']);
    });

    // CRLF from a clipboard: each line's trailing CR and the blank lines go; the fingerprints are shown; one
    // ssh_keys/set with exactly those lines. Negative control: the page sending without its check -> the next test FAILs.
    testWidgets('two good lines (CRLF, a blank line) -> fingerprints shown, one ssh_keys/set with both', (t) async {
      final (f, _) = await open(t);
      await t.enterText(find.byKey(const Key('ssh-lines')), '$k1\r\n\r\n$k2\r\n');
      await t.pump();
      expect(rust.checked.toSet(), {k1, k2}, reason: 'Rust got the lines without their trailing CR');
      expect(find.text('第 1 行：$f1'), findsOneWidget);
      expect(find.text('第 2 行：$f2'), findsOneWidget);
      expect(find.text(sshReplaceNote), findsOneWidget, reason: 'the replace meaning is always on the page');
      // review pr6 B-2: a key both on the node already and sent by the app goes with any later replace (not only an
      // empty set) — said on the page with 1–8 lines too. Negative control: the old note (no exception) -> FAIL.
      final note = t.widget<Text>(find.byKey(const Key('ssh-replace-note'))).data!;
      expect(note, contains('之後任何一次取代'));
      expect(note, contains('一起移除'));
      expect(note, contains('lab key'));
      expect(note, contains('每一次都放進這一組'));
      expect((send(t).text, send(t).kind), (sshSetButton, BtnKind.primary));
      await t.tap(find.byKey(const Key('ssh-send')));
      await settle(t, f);
      expect(asked(f), ['ssh_keys/set 2: $k1|$k2']);
      expect(find.text(sshDoneLine), findsOneWidget);
    });

    for (final (name, text, row) in [
      ('another key type', '$k1\nssh-rsa AAAAB3NzaC1yc2E x', '第 2 行不合格：不是節點接受的格式：要是 ssh-ed25519 公鑰，後面的註解最多 40 個可列印 ASCII 字元'),
      ('over 256 bytes', 'ssh-ed25519 ${'A' * 300}', '第 1 行不合格：超過 256 個位元組'),
      ('a CR inside the line', 'ssh-ed25519 AAAA\rB x\r', '第 1 行不合格：行中間有換行字元'),
    ]) {
      testWidgets('a bad line ($name) -> which line and why; nothing sent', (t) async {
        final (f, _) = await open(t);
        await t.enterText(find.byKey(const Key('ssh-lines')), text);
        await t.pump();
        expect(find.text(row), findsOneWidget);
        expect(send(t).onPressed, isNull);
        await t.tap(find.byKey(const Key('ssh-send')));
        await settle(t, f);
        expect(asked(f), isEmpty);
        expect(f.logins, 0);
      });
    }

    testWidgets('a CR inside a line is not removed by the page (only the trailing one)', (t) async {
      await open(t);
      await t.enterText(find.byKey(const Key('ssh-lines')), 'ssh-ed25519 AAAA\rB x\r');
      await t.pump();
      expect(rust.checked.last, 'ssh-ed25519 AAAA\rB x');
    });

    testWidgets('more than 8 lines -> said, nothing sent', (t) async {
      final (f, _) = await open(t);
      await t.enterText(find.byKey(const Key('ssh-lines')), List.filled(9, k1).join('\n'));
      await t.pump();
      expect(find.text('最多 8 行（現在 9 行）'), findsOneWidget);
      expect(send(t).onPressed, isNull);
      expect(asked(f), isEmpty);
    });

    // 0 lines = every key an app added is removed: a danger button and a confirm; 取消 sends nothing.
    testWidgets('0 lines -> danger 「移除…」, confirmed first; 取消 sends nothing, 移除 sends an empty set', (t) async {
      final (f, _) = await open(t);
      expect((send(t).text, send(t).kind), (sshRemoveButton, BtnKind.danger));
      await t.tap(find.byKey(const Key('ssh-send')));
      await t.pumpAndSettle();
      expect(find.textContaining('不是 app 加的），也會被一起移除'), findsOneWidget);
      await t.tap(find.text('取消'));
      await settle(t, f);
      expect(asked(f), isEmpty);
      await t.tap(find.byKey(const Key('ssh-send')));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const Key('ssh-remove-yes')));
      await settle(t, f);
      expect(asked(f), ['ssh_keys/set 0: ']);
      expect(find.text(sshRemovedLine), findsOneWidget);
    });

    testWidgets('not a devTrust build: the page sends nothing', (t) async {
      await open(t, dev: false);
      await t.enterText(find.byKey(const Key('ssh-lines')), k1);
      await t.pump();
      expect(send(t).onPressed, isNull);
    });
  });

  // ---- T6-4 (Dart) 查看節點設定 ---------------------------------------------------------------------------------------

  testWidgets('T6-4: 查看節點設定 shows Rust\'s answer text (one OpSession.once), copyable', (t) async {
    mockChannels(t);
    final f = Fx(rust, logins: 1);
    final a = app()..devTrust = true;
    await t.pumpWidget(host(NodeSettingsPage(app: a, ui: UiState(MemStore()), deps: f.d)));
    await t.tap(find.byKey(const Key('pick-$id')));
    await t.pump();
    await t.tap(find.byKey(const Key('settings-read')));
    await settle(t, f);
    expect((f.rigs[0].session as P4Session).asked, ['settings/get']);
    expect(find.text('目前設定：名稱 BCM2711-6c89'), findsOneWidget);
    expect(f.reg.current, isNull, reason: 'the lease went with the read');
    await t.tap(find.text('複製'));
    await t.pump();
    expect(clip, '目前設定：名稱 BCM2711-6c89');
  });

  // ---- D7 on the dev pages: the technical part under 技術資訊, never a raw control character; a copy shows 〔 〕 ------

  /// Every Text / SelectableText on screen: none may hold U+001E / U+001F.
  void noControl(WidgetTester t) {
    final shown = [
      ...t.widgetList<Text>(find.byType(Text)).map((w) => w.data ?? ''),
      ...t.widgetList<SelectableText>(find.byType(SelectableText)).map((w) => w.data ?? ''),
    ];
    for (final s in shown) {
      expect(s.contains('\u001e') || s.contains('\u001f'), isFalse, reason: 'raw control character on screen: $s');
    }
  }

  // Negative control: NodeSettingsPage back to SelectableText(_text) / copying _text -> the raw characters FAIL.
  testWidgets('D7: 查看節點設定 with a technical part -> main on screen, the part under 技術資訊; copy with 〔〕', (t) async {
    mockChannels(t);
    final f = Fx(rust, logins: 1);
    (f.rigs[0].session as P4Session).getDetail = '目前設定：名稱 BCM2711-6c89\u001e原因 7\u001f';
    final a = app()..devTrust = true;
    await t.pumpWidget(host(NodeSettingsPage(app: a, ui: UiState(MemStore()), deps: f.d)));
    await t.tap(find.byKey(const Key('pick-$id')));
    await t.pump();
    await t.tap(find.byKey(const Key('settings-read')));
    await settle(t, f);
    expect(t.widget<SelectableText>(find.byKey(const Key('settings-text'))).data, '目前設定：名稱 BCM2711-6c89');
    expect(find.text(techTitle), findsOneWidget);
    expect(find.byKey(const Key('settings-tech')), findsNothing, reason: 'collapsed');
    noControl(t);
    await t.tap(find.text(techTitle));
    await t.pump();
    expect(t.widget<SelectableText>(find.byKey(const Key('settings-tech'))).data, '原因 7');
    await t.tap(find.byKey(const Key('settings-copy')));
    await t.pump();
    expect(clip, '目前設定：名稱 BCM2711-6c89〔原因 7〕');
  });

  // Negative control: the SSH result line back to Text(_line) -> the code and the control characters show -> FAIL.
  testWidgets('D7: an SSH key refusal -> its words on screen, the code only under 技術資訊', (t) async {
    mockChannels(t);
    final f = Fx(rust, logins: 1);
    (f.rigs[0].session as P4Session).sshDetail = '[REQ_FAIL] SSH 金鑰沒有設定：節點不接受\u001e代碼 2，原因 13\u001f';
    final a = app()..devTrust = true;
    t.view.physicalSize = const Size(1080, 4000);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    await t.pumpWidget(host(SshKeysPage(app: a, ui: UiState(MemStore()), deps: f.d)));
    await t.tap(find.byKey(const Key('pick-$id')));
    await t.pump();
    await t.enterText(find.byKey(const Key('ssh-lines')), k1);
    await t.pump();
    await t.tap(find.byKey(const Key('ssh-send')));
    await settle(t, f);
    expect(find.text('SSH 金鑰沒有設定：節點不接受'), findsOneWidget);
    expect(find.textContaining('代碼'), findsNothing);
    noControl(t);
    await t.tap(find.text(techTitle));
    await t.pump();
    expect(find.text('代碼 2，原因 13'), findsOneWidget);
  });

  // Negative control: diagCopy / the page without logText -> the raw characters FAIL.
  testWidgets('D7: 診斷 shows and copies a technical line\'s markers as 〔〕', (t) async {
    mockChannels(t);
    final a = app();
    a.link.core.states[id]!.extra = StatusView(
        color: 'green', row: '3', sentence: 'x', lagNote: '', warning: '', nodeState: 2, netId: '', version: '',
        tech: const ['回覆\u001e代碼 7\u001f'], fresh: true, rateNote: '', unfinished: '', unfinishedUnderVerdict: false,
        canLeave: false);
    t.view.physicalSize = const Size(1080, 4000);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    await t.pumpWidget(host(DiagPage(app: a, keys: keys())));
    await t.pump();
    expect(find.text('回覆〔代碼 7〕'), findsOneWidget);
    noControl(t);
    await t.tap(find.byKey(const Key('diag-copy')));
    await t.pump();
    expect(clip, contains('  回覆〔代碼 7〕'));
    expect(clip!.contains('\u001e') || clip!.contains('\u001f'), isFalse);
  });

  // ---- T6-12 文字紀錄 ------------------------------------------------------------------------------------------------

  group('T6-12 text log', () {
    // Negative control: logShown without NodeLink.mask -> the full id and address show -> FAIL.
    testWidgets('every line masked (ids / addresses to the last four), markers as 〔〕, copy the same', (t) async {
      mockChannels(t);
      final a = app();
      a.link.core.log
        ..clear()
        ..add('1.0   AA:BB:CC:DD:EE:5F -> body 0000000000000c4f2a7d2c\u001e代碼 3\u001f');
      await t.pumpWidget(host(LogPage(app: a)));
      final shown = t.widget<SelectableText>(find.byKey(const Key('log-text'))).data!;
      expect(shown, '1.0   …5F -> body …7d2c〔代碼 3〕');
      await t.tap(find.byKey(const Key('log-copy')));
      await t.pump();
      expect(clip, shown);
      expect(clip, isNot(contains('0c4f2a')));
    });

    testWidgets('empty -> 還沒有紀錄', (t) async {
      mockChannels(t);
      final a = app();
      a.link.core.log.clear();
      await t.pumpWidget(host(LogPage(app: a)));
      expect(find.text('還沒有紀錄'), findsOneWidget);
    });

    // design :342: a lease taken back (60 / 420 / 900 s) and a refused / failed record write each leave a line in the
    // text log (AppLink wires them to NodeLink.note). Negative control: `reg.log = link.note` (or the writer's `log:`)
    // removed from AppLink.create -> FAIL.
    testWidgets('a lease taken back (60 / 420 / 900 s) leaves one line each', (t) async {
      final a = app();
      a.link.core.log.clear();
      final l1 = a.reg.acquire('放棄這次加入', LeaseKind.session)!;
      l1.revoke(); // OfflineOp's 60 s cap
      final l2 = a.reg.acquire('手機 Wi-Fi', LeaseKind.session)!;
      l2.hold();
      l2.pageGone();
      await t.pump(const Duration(seconds: 421));
      final l3 = a.reg.acquire('新增節點', LeaseKind.raw)!;
      l3.hold();
      l3.pageGone();
      await t.pump(const Duration(seconds: 901));
      final lines = a.link.core.log.where((l) => l.contains('lease taken back')).toList();
      expect(lines.length, 3, reason: lines.join('\n'));
      expect(lines[0], endsWith('lease taken back after 60 s: 放棄這次加入'));
      expect(lines[1], endsWith('lease taken back after 420 s: 手機 Wi-Fi'));
      expect(lines[2], endsWith('lease taken back after 900 s: 新增節點'));
      a.reg.unsavedTodos.clear();
      await a.link.dispose();
      await t.pump(const Duration(seconds: 10)); // NodeLink's round after a release
    });

    testWidgets('a record write refused (no lease) leaves one line, with the last four only', (t) async {
      final a = app();
      a.link.core.log.clear();
      await expectLater(a.writer.writeCas(null, 'node/$id', BigInt.one, [1]), throwsA(isA<NoLease>()));
      final lines = a.link.core.log.where((l) => l.contains('RecordWriter')).toList();
      expect(lines, hasLength(1));
      expect(lines.single, endsWith('RecordWriter refused writeCas node/…7d2c'));
      expect(lines.single, isNot(contains('0c4f2a')));
    });

    test('a store write that fails leaves one line (its type only) and is thrown on', () async {
      final reg = LeaseRegistry(after: (d, f) => () {});
      final lines = <String>[];
      final w = RecordWriter(
          reg,
          RecordStore(
              writeCas: (rel, g, s) async => throw StateError('disk full /data/secret'),
              writeSealed: (rel, g, s) async {},
              remove: (rel) async {},
              keepCopy: (rel) async => true),
          log: lines.add);
      final l = reg.acquire('x', LeaseKind.session)!;
      await expectLater(w.writeCas(l, 'net/abcdef0123456789', BigInt.one, [1]), throwsA(isA<StateError>()));
      expect(lines, ['RecordWriter writeCas net/…6789 failed: StateError']);
    });
  });

  // ---- T6-14 忘記加入中的節點 --------------------------------------------------------------------------------------

  group('T6-14 orphan joins', () {
    NetIndex index(Future<List<String>> Function() nodeIds) => NetIndex(NetSource(
          list: (k) async => k == 'net' ? ['n1'] : const [],
          open: (rel) async => Uint8List(1),
          summary: (p) => net([member('dev0000a', 'dA'), member('dev0000b', 'dB'), member('dev0000c', 'dC', joining: false)]),
          nodeIds: nodeIds,
        ));

    // Negative control: orphanJoins computed with the todos' filter (mine.contains) -> FAIL.
    test('a joining member without its node record is an orphan; one with it is a todo; not joining: neither', () async {
      final s = await index(() async => ['dev0000a']).compute();
      expect(s.todos.map((j) => j.deviceId), ['dev0000a']);
      expect(s.orphanJoins.map((j) => j.deviceId), ['dev0000b']);
      expect(s.orphansUnknown, isFalse);
    });

    test('J MINOR: the node records cannot be listed -> no orphan at all (fail-closed), said as unknown', () async {
      final s = await index(() async => throw StateError('io')).compute();
      expect(s.orphanJoins, isEmpty);
      expect(s.orphansUnknown, isTrue);
    });

    Future<AppLink> openPage(WidgetTester t, NetSnapshot s) async {
      mockChannels(t);
      final a = app()..devTrust = true;
      a.nets.setForTest(s);
      await t.pumpWidget(host(OrphanJoinsPage(app: a, ui: UiState(MemStore()))));
      await t.pump();
      return a;
    }

    testWidgets('the page: unknown -> 「讀不到手機上的節點清單」', (t) async {
      await openPage(t, const NetSnapshot(orphansUnknown: true));
      expect(find.text('讀不到手機上的節點清單'), findsOneWidget);
    });

    testWidgets('the page: 放棄這次加入 -> forgetJoining once under its lease, the record rewritten', (t) async {
      final j = JoinTodo(NetEntry('n1', net(const [])), member('dev0000b', 'dB'));
      rust
        ..records.add('net/n1')
        ..forgetStep = fake.step(OwnerKind.persistNet, rel: 'net/n1', detail: '[FORGOT] 已忘記 …000B 這次的加入\u001eFORGOT\u001f');
      final a = await openPage(t, NetSnapshot(orphanJoins: [j]));
      expect(find.text('「山隊」裡的 …000B'), findsOneWidget);
      await t.tap(find.text('「山隊」裡的 …000B'));
      await t.pumpAndSettle();
      expect(find.textContaining('只改這支手機裡的網路紀錄'), findsOneWidget, reason: 'forgetNotice');
      expect(find.byKey(const Key('orphan-exclude')), findsOneWidget, reason: 'devTrust: 排除這台 offered');
      await t.tap(find.byKey(const Key('orphan-forget')));
      for (var i = 0; i < 5; i++) {
        await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
        await t.pump();
      }
      expect(rust.forgot, ['dB']);
      expect(rust.calls, ['cas net/n1']);
      expect(find.text('已忘記 …000B 這次的加入'), findsOneWidget);
      // D7: the technical part kept under 技術資訊 (negative control: back to screenText(line) -> no 技術資訊 -> FAIL)
      noControl(t);
      expect(find.text(techTitle), findsOneWidget);
      expect(a.reg.current, isNull, reason: 'its lease released');
      await a.link.dispose();
      await t.pumpWidget(const SizedBox());
      await t.pump(const Duration(seconds: 10)); // NodeLink's round after a release
    });

    Future<void> drain(WidgetTester t, AppLink a) async {
      for (var i = 0; i < 5; i++) {
        await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
        await t.pump();
      }
    }

    Future<void> close(WidgetTester t, AppLink a) async {
      await a.link.dispose();
      await t.pumpWidget(const SizedBox());
      await t.pump(const Duration(seconds: 10)); // NodeLink's round after a release
    }

    // review pr6 A-7. Negative control: the catch back to a fixed line without the exception -> no 技術資訊 -> FAIL.
    testWidgets('A-7: 放棄這次加入 that throws a non-String -> the line, and the exception under 技術資訊', (t) async {
      final j = JoinTodo(NetEntry('n1', net(const [])), member('dev0000b', 'dB'));
      rust
        ..records.add('net/n1')
        ..readThrows = StateError('boom');
      final a = await openPage(t, NetSnapshot(orphanJoins: [j]));
      await t.tap(find.text('「山隊」裡的 …000B'));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const Key('orphan-forget')));
      await drain(t, a);
      expect(find.text('忘記沒有成功'), findsOneWidget);
      noControl(t);
      expect(find.text(techTitle), findsOneWidget);
      await t.tap(find.text(techTitle));
      await t.pump();
      expect(find.text('Bad state: boom'), findsOneWidget);
      expect(a.reg.current, isNull, reason: 'its lease released');
      await close(t, a);
    });

    // review pr6 A-5: 「排除這台」 goes straight to the removal of that very node (the old console's
    // `_pendingExclude = (net, m.dacHash)`), with PersonPage's own controller. Negative control: _exclude back to
    // PersonPage (the whole list) -> no RemoveConfirmPage -> FAIL.
    testWidgets('A-5: 排除這台 opens the exclusion of that node (its dac hash), not the whole list', (t) async {
      final j = JoinTodo(NetEntry('n1', net(const [])), member('dev0000b', 'dB'));
      rust
        ..records.add('net/n1')
        ..people = const [
          PersonView(owner: 'me', fpr: 'F', name: '我', isSelf: true, sameName: [], nodes: [
            PersonNode(last4: '000A', dacHash: 'dA', state: 'applied'),
            PersonNode(last4: '000B', dacHash: 'dB', state: 'joining'),
          ]),
        ];
      final a = await openPage(t, NetSnapshot(orphanJoins: [j]));
      await t.tap(find.text('「山隊」裡的 …000B'));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const Key('orphan-exclude')));
      await drain(t, a);
      expect(find.byType(RemoveConfirmPage), findsOneWidget);
      final p = t.widget<RemoveConfirmPage>(find.byType(RemoveConfirmPage));
      expect((p.node, p.owner, p.netId, p.person.isSelf), ('dB', '', 'n1', true));
      await close(t, a);
    });

    // review pr6 A-7 (排除這台). Negative control: the catch back to a fixed line without the exception -> FAIL.
    testWidgets('A-7: 排除這台 whose record read throws a non-String -> the line, the exception under 技術資訊', (t) async {
      final j = JoinTodo(NetEntry('n1', net(const [])), member('dev0000b', 'dB'));
      rust
        ..records.add('net/n1')
        ..readThrows = StateError('boom');
      final a = await openPage(t, NetSnapshot(orphanJoins: [j]));
      await t.tap(find.text('「山隊」裡的 …000B'));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const Key('orphan-exclude')));
      await drain(t, a);
      expect(find.text('讀不到網路紀錄裡的隊員'), findsOneWidget);
      noControl(t);
      await t.tap(find.text(techTitle));
      await t.pump();
      expect(find.text('Bad state: boom'), findsOneWidget);
      await close(t, a);
    });

    testWidgets('A-5: 排除這台 for a node that is not one of this phone\'s own -> said so, nothing opened', (t) async {
      final j = JoinTodo(NetEntry('n1', net(const [])), member('dev0000b', 'dB'));
      rust
        ..records.add('net/n1')
        ..people = const [
          PersonView(owner: 'me', fpr: 'F', name: '我', isSelf: true, sameName: [], nodes: [
            PersonNode(last4: '000A', dacHash: 'dA', state: 'applied'),
          ]),
        ];
      final a = await openPage(t, NetSnapshot(orphanJoins: [j]));
      await t.tap(find.text('「山隊」裡的 …000B'));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const Key('orphan-exclude')));
      await drain(t, a);
      expect(find.byType(RemoveConfirmPage), findsNothing);
      expect(find.text(orphanNotOwnLine), findsOneWidget);
      await close(t, a);
    });
  });

  // ---- T6-5 診斷 ---------------------------------------------------------------------------------------------------

  group('T6-5 diagnostics', () {
    KeyAbilities soft() => KeyAbilities.from({
          'RECORD_AES': 1, 'OWNER_SIGN': 1, 'ADMIN_SIGN': 1, 'OWNER_ENC': 0, 'appUsable': true, 'claim': true,
          'login': true, 'recover': true, 'makeNetwork': true, 'softOwnerEnc': true,
        });

    StatusView withTech(List<String> tech) => StatusView(
        color: 'green', row: '3', sentence: 'x', lagNote: '', warning: '', nodeState: 2, netId: '', version: '',
        tech: tech, fresh: true, rateNote: '', unfinished: '', unfinishedUnderVerdict: false, canLeave: false);

    // Negative controls: the soft warning dropped from keyLines -> the warning row FAILs; diagCopy given one more
    // field (the full device id) -> the whitelist check FAILs.
    testWidgets('version, flavor, the key abilities with the soft warning, each node\'s tech; copy = whitelist only', (t) async {
      mockChannels(t);
      final a = app();
      a.link.core.states[id]!.extra = withTech(['軟體版本 1.4.12', 'mesh bm-0123456789ab']);
      t.view.physicalSize = const Size(1080, 4000);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.reset);
      await t.pumpWidget(host(DiagPage(app: a, keys: soft())));
      await t.pump();
      expect(find.text('1.6.0+12'), findsOneWidget);
      expect(find.text('dev'), findsOneWidget);
      expect(find.byKey(const Key('diag-soft')), findsOneWidget);
      expect(find.text(softKeyWarning), findsOneWidget);
      expect(find.text('節點 …7D2C'), findsOneWidget);
      expect(find.text('軟體版本 1.4.12'), findsOneWidget);
      await t.tap(find.byKey(const Key('diag-copy')));
      await t.pump();
      final allowed = [
        RegExp(r'^app 版本：'),
        RegExp(r'^flavor：'),
        RegExp(r'^金鑰（啟動時的檢查結果）：$'),
        RegExp(r'^  (認領節點|登入節點|接續認領|建立網路)：(可以|不可以)$'),
        RegExp('^  $softKeyWarning\$'),
        RegExp(r'^節點 …[0-9A-F]{4}：$'),
        RegExp(r'^  \S'), // a node's technical line (masked)
      ];
      final lines = clip!.split('\n');
      for (final l in lines) {
        expect(allowed.any((r) => r.hasMatch(l)), isTrue, reason: 'not a whitelisted field: $l');
      }
      expect(clip, isNot(contains(id)), reason: 'never a full device id');
      expect(clip, contains('  mesh bm-…89ab'), reason: 'a long hex run masked');
      expect(lines.first, 'app 版本：1.6.0+12');
    });

    testWidgets('a node not read in this run -> 這次還沒讀到; no startup result -> said', (t) async {
      mockChannels(t);
      final a = app();
      await t.pumpWidget(host(DiagPage(app: a, keys: null)));
      await t.pump();
      expect(find.text(notReadYet), findsOneWidget);
      expect(find.text('金鑰：沒有啟動時的檢查結果'), findsOneWidget);
      expect(find.byKey(const Key('diag-soft')), findsNothing);
    });

    // review pr6 A-8 / B-3: two nodes with the same last four are both there (on the page and in the copy).
    // Negative control: nodeTech keyed by last4(id) again -> one section only -> FAIL.
    testWidgets('two nodes sharing a last four: both sections, both copied', (t) async {
      mockChannels(t);
      final a = app();
      const twin = 'ffffffffffff00000a7d2c'; // the same last four as [id]
      a.link.core.setRecords(const [Rec(id, 1), Rec(twin, 2)]);
      a.link.core.states[id]!.extra = withTech(['軟體版本 1.4.12']);
      a.link.core.states[twin]!.extra = withTech(['軟體版本 1.4.13']);
      t.view.physicalSize = const Size(1080, 4000);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.reset);
      await t.pumpWidget(host(DiagPage(app: a, keys: keys())));
      await t.pump();
      expect(find.text('節點 …7D2C'), findsNWidgets(2));
      expect(find.text('軟體版本 1.4.12'), findsOneWidget);
      expect(find.text('軟體版本 1.4.13'), findsOneWidget);
      await t.tap(find.byKey(const Key('diag-copy')));
      await t.pump();
      expect('節點 …7D2C：'.allMatches(clip!).length, 2);
      expect(clip, allOf(contains('  軟體版本 1.4.12'), contains('  軟體版本 1.4.13')));
      expect(clip, isNot(contains(twin)));
      expect(clip, isNot(contains(id)));
    });

    testWidgets('keys that fit: no soft warning', (t) async {
      mockChannels(t);
      await t.pumpWidget(host(DiagPage(app: app(), keys: keys())));
      await t.pump();
      expect(find.byKey(const Key('diag-soft')), findsNothing);
    });
  });

  // ---- T6-7 the home status time (D9) -----------------------------------------------------------------------------

  group('T6-7 home status time', () {
    final now = DateTime(2026, 11, 15, 23, 0);
    final at = DateTime(2026, 11, 15, 22, 48); // home_logic_test's node() read time
    StatusView v(String c, {int nodeState = 2}) => StatusView(
        color: c, row: '3', sentence: 's', lagNote: '', warning: '', nodeState: nodeState, netId: '', version: '',
        tech: const [], fresh: true, rateNote: '', unfinished: '', unfinishedUnderVerdict: false, canLeave: false);

    // Negative control: heroTime back to 「fresh only」 (null for an older read) -> the 上次讀取 cases FAIL.
    test('about one node: fresh -> 讀取於 HH:MM:SS; older -> 上次讀取 HH:MM + what it said then', () {
      expect(heroTime([node('a1', v: v('green'))], about: 'a1', now: now), '讀取於 22:48:00');
      expect(heroTime([node('a1', v: v('green'), fresh: false)], about: 'a1', now: now), '上次讀取 22:48，當時正常');
      expect(heroTime([node('a1', v: v('yellow'), fresh: false)], about: 'a1', now: now), '上次讀取 22:48，當時要注意');
      expect(heroTime([node('a1', v: v('red'), fresh: false)], about: 'a1', now: now), '上次讀取 22:48，當時有問題');
      expect(heroTime([node('a1', v: v('yellow', nodeState: 1), fresh: false)], about: 'a1', now: now),
          '上次讀取 22:48，當時還沒加入隊伍網路');
    });

    test('about one node with an identity mismatch / a refused login: no 「當時…」 tail', () {
      for (final w in [Why.identity, Why.refused]) {
        final n = node('a1', v: v('green'), fresh: false);
        final m = NodeInfo(id: n.id, name: n.name, state: n.state, fresh: false, shownWhy: w, view: n.view, readWall: at);
        expect(heroTime([m], about: 'a1', now: now), '上次讀取 22:48', reason: '$w');
      }
    });

    test('not about one node: the newest fresh read; none fresh -> the newest read, 上次讀取 without a tail', () {
      final fresh = node('a1', v: v('green'));
      final older = node('b2', v: v('red'), fresh: false);
      expect(heroTime([older, fresh], now: now), '讀取於 22:48:00');
      expect(heroTime([older], now: now), '上次讀取 22:48');
    });

    // plan §11 MINOR: 「之前讀過」 only for an earlier run's time (UiState prev) after now; an earlier run's read with its
    // own kind's tail when this run has none; never read -> nothing.
    test('an earlier run: 上次讀取 + its kind; a time after now -> 之前讀過; never read -> nothing', () {
      NodeInfo prev(String look, DateTime t) => NodeInfo(
          id: 'a1', name: 'n', state: NodeState(), fresh: false, shownWhy: null,
          prev: UiNode(look: look, readAt: t.millisecondsSinceEpoch ~/ 1000));
      expect(heroTime([prev('warn', at)], about: 'a1', now: now), '上次讀取 22:48，當時要注意');
      expect(heroTime([prev('ok', at)], now: now), '上次讀取 22:48');
      final later = now.add(const Duration(hours: 2));
      expect(heroTime([prev('ok', later)], about: 'a1', now: now), '之前讀過');
      expect(heroTime([prev('ok', later)], now: now), '之前讀過');
      expect(heroTime([node('a1', v: v('green'))], about: 'a1', now: at.subtract(const Duration(hours: 1))), '讀取於 22:48:00',
          reason: 'this run''s own time is not 「之前讀過」');
      expect(heroTime([node('a1', v: v('green'), fresh: false)], about: 'a1', now: at.subtract(const Duration(hours: 1))),
          '上次讀取 22:48，當時正常', reason: 'nor an older read of this run');
      expect(heroTime([node('a1')], about: 'a1', now: now), isNull);
      expect(heroTime([node('a1')], now: now), isNull);
    });
  });

  // ---- key_gate_test ported (plan §7 「既有」: key_gate_test.dart:146, the old console's 建立網路 key gate) -----------

  // The new path: OwnerConsole.makeNetwork asks ConsolePlatform.makeNetworkRefusal first and sends nothing when it
  // answers (owner_console_test 'the make-network key check refuses'); here, AppLink's wiring of that check reads the key
  // levels live through KeyAbilities, with the words the old console said. Negative control: AppLink's
  // makeNetworkRefusal answering null -> FAIL.
  group('key gate ported: make-network reads the key levels live', () {
    Map<String, Object?> levels({bool makeNetwork = true, int? admin = 1}) => {
          'RECORD_AES': 1, 'OWNER_SIGN': 1, 'ADMIN_SIGN': admin, 'OWNER_ENC': 1, 'appUsable': true, 'claim': true,
          'login': true, 'recover': true, 'makeNetwork': makeNetwork, 'softOwnerEnc': false,
        };
    for (final (name, answer, want) in [
      ('admin key not hardware', levels(makeNetwork: false, admin: 0), '這支手機的網路管理金鑰不是硬體保護，不能建立網路'),
      ('admin key lost', levels(makeNetwork: false, admin: null), '這支手機的網路管理金鑰不見了，不能建立或更改網路'),
      ('every key fits (control)', levels(), null),
    ]) {
      testWidgets(name, (t) async {
        final asked = <String>[];
        t.binding.defaultBinaryMessenger.setMockMethodCallHandler(const MethodChannel('dev.batman/platform'), (c) async {
          asked.add(c.method);
          return c.method == 'keyLevels' ? answer : null;
        });
        final a = app();
        expect(await a.console.makeNetworkRefusal(), want);
        expect(asked, ['keyLevels'], reason: 'read live; publicKeys / signAdmin never asked here');
      });
    }
  });

  // ---- T6-8 NetFormPage's own subscription (D10) ------------------------------------------------------------------

  // Pumped alone (not through the home page). AppLink keeps a subscription of its own (sw.retain), so the page's is
  // the difference. Negative control: NetFormPage.dispose without `_sub?.cancel()` -> the count stays up -> FAIL.
  testWidgets('T6-8: NetFormPage subscribes to NodeLink.changed while open and cancels on close', (t) async {
    mockChannels(t);
    final a = app();
    final before = a.link.changedListeners;
    await t.pumpWidget(host(NetFormPage(app: a, ui: UiState(MemStore()), makes: true)));
    await t.pump();
    expect(a.link.changedListeners, before + 1, reason: 'open: its own subscription');
    await t.pumpWidget(const SizedBox());
    await t.pump();
    expect(a.link.changedListeners, before, reason: 'closed: cancelled');
  });

}
