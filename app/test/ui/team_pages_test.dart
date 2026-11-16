// #329 PR 5 plan v16 §2.7 / §6 step 7: the leader's pages (8.1, 7.1, 7.3-7.7, 8.2-8.4) on join_pages_test's fakes
// (a console per login, the real lease registry and RecordWriter, Rust's pure functions and opaque ops faked).
import 'package:batman_app/src/flows/rekey_send.dart' show notThisNodeLine;
import 'package:batman_app/src/nodelink/lease.dart' show LeaseKind;
import 'package:batman_app/src/rust/api/member.dart';
import 'package:batman_app/src/rust/api/owner.dart';
import 'package:batman_app/src/rust/api/rekey.dart';
import 'package:batman_app/src/rust/frb_generated.dart';
import 'package:batman_app/ui/remove_pages.dart';
import 'package:batman_app/ui/rekey_result.dart';
import 'package:batman_app/ui/team_pages.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'join_pages_test.dart' show TeamRust, World, open, paste, platformCalls, settle, step;

const me = 'OWNERME', bob = 'OWNERBOB', bob2 = 'OWNERBOB2';

PersonView person(String owner, String name, String fpr, {bool self = false, List<PersonNode> nodes = const []}) =>
    PersonView(owner: owner, fpr: fpr, name: name, isSelf: self, nodes: nodes, sameName: const []);

PersonNode pnode(String last4, String dac, {String state = 'applied'}) =>
    PersonNode(last4: last4, dacHash: dac, state: state);

/// SignAdmin -> PersistNet -> the answer ([hex] / [detail]).
class FakeNetOp implements NetOp, RemoveOp {
  FakeNetOp({this.hex = '', this.detail = ''});
  final String hex, detail;
  @override
  OwnerStep? signed({required List<int> der}) => step(OwnerKind.persistNet, rel: 'net/nn');
  @override
  OwnerStep? netPersisted() => step(OwnerKind.answer, hex: hex, detail: detail);
  @override
  OwnerStep? persistFailed({required String error}) => step(OwnerKind.answer, detail: '[REQ_FAIL] $error');
  @override
  dynamic noSuchMethod(Invocation i) => throw UnimplementedError('${i.memberName}');
}

class LeadRust extends TeamRust {
  List<PersonView> people = [];
  List<RecipientView> recipients = [];
  List<OwnNodeView> own = [];
  String previous = '';
  List<NodeInfo>? reads;
  final ops = <String>[];

  @override
  List<PersonView> crateApiRekeyNetPeople({required List<int> recordPlain, required List<int> ownerPub}) => people;
  @override
  List<RecipientView> crateApiRekeyNetRecipients({required List<int> recordPlain, required List<int> ownerPub}) =>
      recipients;
  @override
  List<OwnNodeView> crateApiRekeyRemoveOwnNodes({
    required List<int> recordPlain,
    required List<int> ownerPub,
    required String person,
    required String node,
  }) => own;
  @override
  RemovePlanView crateApiRekeyRemoveCheck({
    required List<int> recordPlain,
    required List<int> adminPub,
    required List<int> ownerPub,
    required String person,
    required String node,
    required List<NodeInfo> reads,
  }) {
    this.reads = reads;
    return RemovePlanView(ok: true, text: '移除後要換全隊密碼', unverified: false, nodes: reads.length);
  }

  @override
  String crateApiRekeyRemoveTickText() => '我知道移除後要把更新包交給每位隊員';
  @override
  (RemoveOp, OwnerStep) crateApiRekeyRemoveOpStartRemove({
    required List<int> recordPlain,
    required BigInt recordGen,
    required List<int> adminPub,
    required List<int> ownerPub,
    required String person,
    required String node,
    required List<NodeInfo> reads,
    required bool ticked,
  }) {
    ops.add('remove $person ticked=$ticked');
    return (FakeNetOp(detail: '[REKEY] 已換密碼'), step(OwnerKind.signAdmin));
  }

  @override
  (RemoveOp, OwnerStep) crateApiRekeyRemoveOpStartBundle({
    required List<int> recordPlain,
    required List<int> adminPub,
    required List<int> ownerPub,
    required String person,
  }) {
    ops.add('bundle $person');
    return (FakeNetOp(hex: 'BUNDLEHEX'), step(OwnerKind.signAdmin));
  }

  @override
  JoinReqView crateApiMemberNetCheckJoinreq({required List<int> recordPlain, required String hex}) => JoinReqView(
    sas: '7777',
    name: '小華',
    deviceSuffix: 'BB02',
    replacesApproved: false,
    joinreqHash: 'jh',
    previous: previous,
    updateFirst: false,
  );

  @override
  (NetOp, OwnerStep) crateApiMemberNetOpMakeInvite({
    required List<int> recordPlain,
    required BigInt recordGen,
    required List<int> adminPub,
  }) {
    ops.add('invite');
    return (FakeNetOp(hex: 'INVHEX'), step(OwnerKind.signAdmin));
  }

  @override
  (NetOp, OwnerStep) crateApiMemberNetOpApprove({
    required List<int> recordPlain,
    required BigInt recordGen,
    required String hex,
    required String joinreqHash,
    required List<int> adminPub,
    required bool previousConfirmed,
  }) {
    ops.add('approve previous=$previousConfirmed');
    return (FakeNetOp(hex: 'APPHEX'), step(OwnerKind.signAdmin));
  }
}

World leader(List<String> ids, Map<String, String> nets) => World(ids, nets)..records['net/nn'] = Uint8List(5);

void main() {
  final rust = LeadRust();
  setUpAll(() => RustLib.initMock(api: rust));
  setUp(() {
    rust
      ..people = []
      ..recipients = []
      ..own = []
      ..previous = ''
      ..reads = null
      ..ops.clear();
  });

  group('8.1 members', () {
    testWidgets('me first; fingerprints; same name by the whole owner, same fingerprint too; the rule', (t) async {
      rust.people = [
        person(bob, '小明', 'aaaa1111', nodes: [pnode('BB02', 'd2', state: 'joining')]),
        person(me, '隊長', 'ffff0000', self: true, nodes: [pnode('AA01', 'd1')]),
        person(bob2, '小明', 'aaaa1111'),
      ];
      await open(t, leader([], {}), (a) => MembersPage(app: a, netId: 'nn'));
      final rows = t.widgetList(
        find.byWidgetPredicate(
          (w) => w.key is ValueKey<String> && '${(w.key as ValueKey<String>).value}'.startsWith('person-'),
        ),
      );
      expect(rows.map((w) => (w.key as ValueKey<String>).value), ['person-$me', 'person-$bob', 'person-$bob2']);
      expect(find.textContaining('我（隊長）'), findsOneWidget);
      expect(find.textContaining('…BB02（加入中）'), findsOneWidget);
      expect(find.textContaining('另有同名的一組：aaaa1111（要一起移除得各按一次）。指紋也相同，請用加入時間分辨'), findsNWidgets(2));
      expect(find.byKey(const Key('members-rule')), findsOneWidget);
    });

    testWidgets('after a removal in this run: 還有 N 位隊員沒交更新包 until each is ticked', (t) async {
      rust.people = [person(me, '隊長', 'f0', self: true), person(bob, '小明', 'a1'), person(bob2, '小華', 'b2')];
      final a = await open(t, leader([], {}), (a) => MembersPage(app: a, netId: 'nn'));
      expect(find.textContaining('沒交更新包'), findsNothing);
      a.ticks.removed('nn');
      await settle(t);
      expect(find.text('還有 2 位隊員沒交更新包'), findsOneWidget);
      a.ticks.tick('nn', bob, true);
      a.ticks.tick('nn', bob2, true);
      await settle(t);
      expect(find.textContaining('沒交更新包'), findsNothing);
    });
  });

  group('7.1 / 7.3 invite', () {
    testWidgets('在旁邊 -> signed, the record written under the lease, then the code page', (t) async {
      final w = leader([], {});
      await open(t, w, (a) => InvitePage(app: a, netId: 'nn'));
      await t.tap(find.text('在旁邊'));
      await settle(t);
      expect(rust.ops, ['invite']);
      expect(w.disk, ['cas net/nn']);
      expect(find.byType(InviteCodePage), findsOneWidget);
      expect(find.text('請隊員掃這個畫面'), findsOneWidget);
    });

    testWidgets('busy: another operation holds the lease -> its name, nothing written', (t) async {
      final w = leader([], {});
      await open(t, w, (a) => InvitePage(app: a, netId: 'nn'));
      w.reg.acquire('軟體更新', LeaseKind.session);
      await t.tap(find.text('不在旁邊'));
      await settle(t);
      expect(find.text('另一個操作還在進行：軟體更新'), findsOneWidget);
      expect(w.disk, isEmpty);
      expect(rust.ops, isEmpty);
    });
  });

  group('7.4-7.7 a request', () {
    testWidgets('removed before: asked; 取消 -> no SAS page', (t) async {
      rust.previous = '這個人之前被移出過';
      await open(t, leader([], {}), (a) => RequestPage(app: a, netId: 'nn'));
      await paste(t, 'REQ');
      expect(find.text('這個人之前被移出過'), findsOneWidget);
      await t.tap(find.text('取消'));
      await settle(t);
      expect(find.byType(ApprovePage), findsNothing);
      expect(find.textContaining('沒有同意（之前被移出過）'), findsOneWidget);
    });

    testWidgets('7.5: busy -> a new SasCheck, pressable again; then approved -> 7.6, previousOk passed', (t) async {
      rust.previous = '之前被移出過';
      final w = leader([], {});
      await open(t, w, (a) => RequestPage(app: a, netId: 'nn'));
      await paste(t, 'REQ');
      await t.tap(find.text('確定，繼續核對'));
      await settle(t);
      expect(find.byType(ApprovePage), findsOneWidget);
      expect(find.text('7777'), findsWidgets);
      final hold = w.reg.acquire('軟體更新', LeaseKind.session)!;
      await t.tap(find.byKey(const Key('sasConfirm')));
      await settle(t);
      expect(find.text('另一個操作還在進行：軟體更新'), findsOneWidget);
      expect(
        t
            .widget<ButtonStyleButton>(
              find.descendant(of: find.byKey(const Key('sasConfirm')), matching: find.bySubtype<ButtonStyleButton>()),
            )
            .onPressed,
        isNotNull,
        reason: 'B-m7: pressable again',
      );
      await hold.release();
      await t.tap(find.byKey(const Key('sasConfirm')));
      await settle(t);
      expect(rust.ops, ['approve previous=true']);
      expect(w.disk, ['cas net/nn']);
      expect(find.byType(ApprovalCodePage), findsOneWidget);
    });

    testWidgets('7.7 數字不一樣: nothing written', (t) async {
      final w = leader([], {});
      await open(t, w, (a) => RequestPage(app: a, netId: 'nn'));
      await paste(t, 'REQ');
      await t.tap(find.text('數字不一樣'));
      await settle(t);
      expect(find.byType(MismatchPage), findsOneWidget);
      expect(find.text('不要同意這份申請'), findsOneWidget);
      expect(w.disk, isEmpty);
      expect(rust.ops, isEmpty);
    });
  });

  group('8.2 / 8.3 remove', () {
    testWidgets('8.2 others: one remove button; me: one exclude row per node, joining ones too', (t) async {
      final all = [
        person(
          me,
          '隊長',
          'f0',
          self: true,
          nodes: [
            pnode('AA01', 'd1'),
            pnode('BB02', 'd2', state: 'joining'),
          ],
        ),
        person(bob, '小明', 'a1'),
      ];
      await open(t, leader([], {}), (a) => PersonPage(app: a, netId: 'nn', person: all[1], all: all));
      expect(find.text('移除小明，全隊換密碼'), findsOneWidget);
      await open(t, leader([], {}), (a) => PersonPage(app: a, netId: 'nn', person: all[0], all: all));
      expect(find.textContaining('排除 …'), findsNWidgets(2));
      expect(find.text('加入中'), findsOneWidget);
      expect(find.textContaining('，全隊換密碼'), findsNothing, reason: 'no remove button for me');
    });

    testWidgets('P19: node 1 unreadable, node 2 still read; every own node in reads; the tick gates; -> 8.4', (
      t,
    ) async {
      rust.own = [
        const OwnNodeView(deviceId: '0000aa01', dacHash: 'd1'),
        const OwnNodeView(deviceId: '0000bb02', dacHash: 'd2'),
        const OwnNodeView(deviceId: '0000cc03', dacHash: 'd3'), // not on this phone
      ];
      rust.people = [person(me, '隊長', 'f0', self: true)];
      final w = leader(['0000aa01', '0000bb02'], {'0000bb02': 'nn'}); // aa01: its login fails
      final p = person(bob, '小明', 'a1');
      final a = await open(
        t,
        w,
        (a) => RemoveConfirmPage(app: a, netId: 'nn', person: p, owner: bob, node: '', same: const ['另有同名的一組：x']),
      );
      expect(w.log.where((l) => l.startsWith('login')), ['login 0000aa01', 'login 0000bb02']);
      expect(find.textContaining('節點 …aa01 讀不到（不檢查這台）'), findsOneWidget);
      expect(rust.reads!.map((r) => '${r.dacHash}:${r.info.length}'), ['d1:0', 'd2:2', 'd3:0'], reason: 'AA-m4');
      expect(find.byKey(const Key('remove-same')), findsOneWidget, reason: '8.3 step 4');
      expect(find.text('移除後要換全隊密碼'), findsOneWidget);
      final go = find.descendant(of: find.byKey(const Key('remove-go')), matching: find.bySubtype<ButtonStyleButton>());
      expect(t.widget<ButtonStyleButton>(go).onPressed, isNull, reason: 'F32: the tick first');
      await t.tap(find.byKey(const Key('remove-tick')));
      await settle(t);
      await t.tap(find.byKey(const Key('remove-go')));
      await settle(t);
      expect(rust.ops, ['remove $bob ticked=true']);
      expect(w.disk, ['cas net/nn']);
      expect(a.ticks.removedThisRun('nn'), isTrue);
      expect(find.byType(RekeyPage), findsOneWidget);
    });
  });

  group('8.4 new secrets', () {
    testWidgets('a bundle as text only, the memory-only mark; own nodes by last 4 with expectDac; no record -> why', (
      t,
    ) async {
      rust.recipients = [
        const RecipientView(owner: bob, fpr: 'a1', name: '小明', nodes: ['BB02'], note: ''),
      ];
      rust.people = [
        person(me, '隊長', 'f0', self: true, nodes: [pnode('AA01', 'dA'), pnode('CC03', 'dC')]),
      ];
      final w = leader(['0000aa01', '9999aa01'], {'0000aa01': 'nn', '9999aa01': 'nn'})
        ..dacs['0000aa01'] = 'other'
        ..dacs['9999aa01'] = 'dA';
      final a = await open(t, w, (a) => RekeyPage(app: a, netId: 'nn', removal: true));
      await t.tap(find.text('複製更新包'));
      await settle(t);
      expect(rust.ops, ['bundle $bob']);
      expect(find.byKey(const Key('code-qr')), findsNothing, reason: 'T10');
      expect(platformCalls, isNot(contains('qrMatrix')), reason: 'T10: never asked for a QR');
      expect(find.byKey(const Key('code-copy')), findsOneWidget);
      expect(a.ticks.handed('nn', bob), isFalse);
      await t.tap(find.byKey(const Key('handed-$bob')));
      await settle(t);
      expect(a.ticks.handed('nn', bob), isTrue);
      expect(find.textContaining('手機沒有這台的紀錄'), findsOneWidget, reason: 'CC03 has no record here');
      await t.tap(find.descendant(of: find.byKey(const Key('own-dA')), matching: find.text('送出')));
      await settle(t);
      expect(w.log.where((l) => l.startsWith('send')), [
        'send 9999aa01 net/nn member=false',
      ], reason: 'X-m1: the first candidate is not this node (its dac hash), the second is');
      expect(find.byType(RekeyResult), findsOneWidget);
      expect(find.byKey(const Key('rekey-tick')), findsOneWidget);
      expect(notThisNodeLine, isNotEmpty);
    });
  });
}
