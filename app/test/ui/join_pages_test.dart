// #329 PR 5 plan v16 §2.8 / §2.9 / §6 steps 8-9: the member's pages (7.8-7.10, 8.5) and RekeyResult (R14), on fake
// sessions (a console per login), the real lease registry and RecordWriter, and Rust's pure functions faked.

import 'package:batman_app/secure_screen.dart' show secureChannel;
import 'package:batman_app/src/flows/offline_op.dart';
import 'package:batman_app/src/flows/op_session.dart';
import 'package:batman_app/src/flows/owner_console.dart';
import 'package:batman_app/src/flows/rekey_send.dart';
import 'package:batman_app/src/nodelink/app_link.dart';
import 'package:batman_app/src/nodelink/ble_gate.dart' show GateLink;
import 'package:batman_app/src/nodelink/handoff.dart';
import 'package:batman_app/src/nodelink/lease.dart';
import 'package:batman_app/src/nodelink/node_link.dart' show LoginForEnd, LoginForResult;
import 'package:batman_app/src/nodelink/record_writer.dart';
import 'package:batman_app/src/rust/api/member.dart';
import 'package:batman_app/src/rust/api/owner.dart';
import 'package:batman_app/src/rust/api/rekey.dart';
import 'package:batman_app/src/rust/frb_generated.dart';
import 'package:batman_app/ui/join_pages.dart';
import 'package:batman_app/ui/join_choice.dart' show NetMode;
import 'package:batman_app/ui/net_pages.dart' show NetFormPage;
import 'package:batman_app/ui/rekey_result.dart';
import 'package:batman_app/ui/team_deps.dart';
import 'package:batman_app/ui/ui_state.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../nodelink/lease_test.dart' show Clock, setup;
import 'pages_test.dart' show FakeRust, app, host;
import 'ui_state_test.dart' show MemStore;

OwnerStep step(OwnerKind kind, {String detail = '', String rel = '', String hex = '', String sas = ''}) => OwnerStep(
    kind: kind,
    frames: const [],
    signInput: Uint8List(0),
    detail: detail,
    record: Uint8List(2),
    rel: rel,
    generation: BigInt.two,
    aad: Uint8List(1),
    expectedGen: BigInt.one,
    pollLink: false,
    hex: hex,
    sas: sas,
    renewed: false,
    sent: false,
    left: false,
    waitMs: BigInt.zero,
    sendUpdate: false,
    info: Uint8List(0),
    sw: false,
    note: '',
    loginEnd: 0,
    loginCode: BigInt.zero);

class TeamRust extends FakeRust {
  ImportState importState = ImportState.ready;
  UpdateState updateState = UpdateState.advance;
  final seen = <String>[];
  List<int>? z; // the z handed to Rust (the page's own copy: zeroed after, B-m5)

  @override
  InviteView crateApiMemberParseInvite({required String hex}) {
    if (hex == 'bad') throw 'not an invite';
    return const InviteView(netName: '山隊', netIdHex: 'nn', inviteHashHex: 'h');
  }

  @override
  String crateApiMemberApprovalNetId({required String hex}) => 'nn';

  @override
  ImportPrep crateApiMemberMemberImportPrepare(
      {required String hex, required BigInt pendGen, Uint8List? pendPlain, Uint8List? mnetPlain, required bool replace}) {
    seen.add('prepare replace=$replace');
    return ImportPrep(
        state: replace ? ImportState.ready : importState,
        sas: '4821',
        ephPub: Uint8List(1),
        pendGen: pendGen,
        detail: importState == ImportState.replace ? '要換掉舊的網路紀錄嗎' : '[REQ_FAIL] 同意碼已經用過了');
  }

  @override
  OwnerStep crateApiMemberMemberImportApproval(
      {required String hex,
      required BigInt pendGen,
      required List<int> pendPlain,
      required BigInt expectedPendGen,
      Uint8List? mnetPlain,
      required BigInt mnetGen,
      required List<int> z,
      required String confirmedSas,
      required bool replace}) {
    seen.add('approve sas=$confirmedSas replace=$replace');
    this.z = z;
    return step(OwnerKind.persistMnet, detail: '[IMPORT] 已匯入網路「山隊」', rel: 'mnet/nn');
  }

  @override
  OwnerStep crateApiMemberMemberPendView({required List<int> pendPlain}) =>
      step(OwnerKind.answer, hex: 'PENDHEX', sas: '5678');

  @override
  String crateApiRekeyUpdateNetId({required String hex}) => 'nn';

  @override
  UpdatePrep crateApiRekeyMemberUpdatePrepare(
      {required String hex,
      Uint8List? mnetPlain,
      required BigInt mnetGen,
      required List<Uint8List> nodeRecords,
      required List<int> ownerEncPub}) {
    seen.add('uprep nodes=${nodeRecords.length}');
    return UpdatePrep(state: updateState, ephPub: Uint8List(1), mnetGen: mnetGen, detail: '更新到第 3 版');
  }

  @override
  OwnerStep crateApiRekeyMemberUpdateImport(
      {required String hex,
      Uint8List? mnetPlain,
      required BigInt mnetGen,
      required BigInt expectedGen,
      required List<Uint8List> nodeRecords,
      required List<int> ownerEncPub,
      required List<int> z}) {
    seen.add('uimport z=${z.length}');
    this.z = z;
    return step(OwnerKind.persistMnet, detail: '[IMPORT] 已存好新密碼', rel: 'mnet/nn');
  }

  @override
  String crateApiRekeyInfoNetId({required List<int> info}) => String.fromCharCodes(info);
}

class FakeGate implements GateLink {
  @override
  Future<void> close() async {}
  @override
  dynamic noSuchMethod(Invocation i) => throw UnimplementedError('${i.memberName}');
}

/// One login's console: the node's network from [World.nets], its answers logged.
class FakeConsole implements OwnerConsole {
  FakeConsole(this.w, this.id);
  final World w;
  final String id;

  @override
  Future<ConsoleReply> info() async =>
      ConsoleReply(ReplyKind.answer, '', value: Uint8List.fromList(w.nets[id]!.codeUnits));

  @override
  Future<ConsoleReply> joinreq({required String inviteHex, required String name, required String pendRel}) async {
    w.log.add('joinreq $id $name $pendRel');
    return const ConsoleReply(ReplyKind.answer, '[JOINREQ]', value: JoinreqOut('REQHEX', '5678', false));
  }

  @override
  String nodeDacHash() => w.dacs[id] ?? '';

  @override
  Future<ConsoleReply> sendUpdateFor(String rel, {bool member = false}) async {
    w.log.add('send $id $rel member=$member');
    return ConsoleReply(ReplyKind.answer, '[UPDATED] 節點 …${rustLast4(id)} 已換成新密碼');
  }

  @override
  Future<void> close() async {}
  @override
  dynamic noSuchMethod(Invocation i) => throw UnimplementedError('${i.memberName}');
}

/// The phone and its nodes: node records [ids]; each node's network in [nets] (missing = its login fails).
class World {
  World(this.ids, this.nets) {
    final (r, c, _, wr, d) = setup();
    reg = r;
    clock = c;
    writer = wr;
    disk = d;
  }
  final List<String> ids;
  final Map<String, String> nets;
  final log = <String>[];
  final records = <String, Uint8List>{'mpend/nn': Uint8List(3), 'mnet/nn': Uint8List(4)};
  final dacs = <String, String>{}; // each node's dac hash (sendNewKey's expectDac)
  final ecdh = <Uint8List>[];
  late final LeaseRegistry reg;
  late final Clock clock;
  late final RecordWriter writer;
  late final List<String> disk;

  late final OpDeps op = OpDeps(
    acquire: (name) async => reg.acquire(name, LeaseKind.session),
    busyName: () => reg.current?.name ?? '',
    login: (lease, id) async {
      log.add('login $id');
      if (!nets.containsKey(id)) return const LoginForResult(LoginForEnd.notFound);
      return LoginForResult(LoginForEnd.ok, LoginHandoff(id: id, link: FakeGate(), inbox: FrameInbox()));
    },
    console: (lease, h) => FakeConsole(this, h.id),
    keepScreen: (on) async {},
  );

  TeamDeps deps(AppLink a) => TeamDeps(
        offline: OfflineDeps(
            acquire: (name) async => reg.acquire(name, LeaseKind.session),
            busyName: () => reg.current?.name,
            writer: writer,
            after: clock.after),
        platform: OfflinePlatform(
          seal: (plain, aad) async => Uint8List.fromList([9, ...plain]),
          signAdmin: (input) async => Uint8List(1),
          ecdh: (peer) async {
            final z = Uint8List.fromList(List.filled(32, 7));
            ecdh.add(z);
            return z;
          },
          readRecord: (rel) async => (BigInt.one, records[rel]),
          keyError: (e) {},
        ),
        op: op,
        publicKeys: () async => {'ownerEnc': Uint8List(1), 'owner': Uint8List(1), 'admin': Uint8List(1)},
        nodeIds: () async => ids,
        send: (c) => SendDeps(
            op: op, readRecord: (rel) async => (BigInt.one, records[rel] as Object?), confirm: () async => true),
      );
}

const _platform = MethodChannel('dev.batman/platform');
String _clip = '';

/// the methods asked of the app's platform channel since [open]
final platformCalls = <String>[];

/// [page] over the real AppLink, the team pages' parts from [w], the paste path on.
Future<AppLink> open(WidgetTester t, World w, Widget Function(AppLink a) page) async {
  t.view.physicalSize = const Size(1080, 6000);
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.reset);
  addTearDown(() => teamDepsOverride = null);
  final m = t.binding.defaultBinaryMessenger;
  m.setMockMethodCallHandler(secureChannel, (c) async => true);
  platformCalls.clear();
  m.setMockMethodCallHandler(_platform, (c) async {
    platformCalls.add(c.method);
    return null; // clearClip: done; qrMatrix: none
  });
  m.setMockMethodCallHandler(SystemChannels.platform, (c) async {
    if (c.method == 'Clipboard.getData') return {'text': _clip};
    return null;
  });
  final a = app();
  a.devTrust = true; // the paste path (R5)
  teamDepsOverride = w.deps;
  await t.pumpWidget(host(page(a)));
  await settle(t);
  return a;
}

/// 貼上 with [text] on the clipboard.
Future<void> paste(WidgetTester t, String text) async {
  _clip = text;
  await t.tap(find.byKey(const Key('code-paste')));
  await settle(t);
}

void main() {
  final rust = TeamRust();
  setUpAll(() => RustLib.initMock(api: rust));
  setUp(() {
    rust
      ..seen.clear()
      ..z = null
      ..importState = ImportState.ready
      ..updateState = UpdateState.advance;
  });

  Finder sendOf(String id) => find.descendant(of: find.byKey(Key('update-node-$id')), matching: find.text('送出'));

  group('7.8 join team', () {
    test('T-V1 / T-V2: 32 UTF-8 bytes, the count and its CJK estimate', () {
      expect(kNameMaxBytes, 32);
      expect(nameBytes('一' * 10), 30);
      expect(nameBytes('一' * 11), 33);
      expect(nameLeft(''), '還可以輸入 32 個位元組（約 10 個中文字）');
      expect(nameLeft('ab'), '還可以輸入 30 個位元組（約 10 個中文字）');
      expect(nameLeft('一' * 11), '超過 1 個位元組，請改短');
    });

    testWidgets('O-m5: every node record listed, one already in a network too; the name gates the request', (t) async {
      final w = World(['0000aa01', '0000bb02'], {'0000aa01': 'old', '0000bb02': ''});
      final a = await open(t, w, (a) => JoinTeamPage(app: a, ui: UiState(MemStore())));
      await paste(t, 'INVITE');
      expect(find.text('邀請：網路「山隊」'), findsOneWidget);
      expect(find.byKey(const Key('join-node-0000aa01')), findsOneWidget);
      expect(find.byKey(const Key('join-node-0000bb02')), findsOneWidget);
      await t.tap(find.byKey(const Key('join-node-0000aa01')));
      await settle(t);
      expect(goEnabled(t), isFalse, reason: 'the name is required');
      await t.enterText(find.byKey(const Key('join-name')), '一' * 11);
      await settle(t);
      expect(goEnabled(t), isFalse, reason: 'T-V1: 33 bytes');
      expect(find.text('超過 1 個位元組，請改短'), findsOneWidget);
      await t.enterText(find.byKey(const Key('join-name')), '一' * 10);
      await settle(t);
      expect(find.text('還可以輸入 2 個位元組（約 0 個中文字）'), findsOneWidget);
      expect(goEnabled(t), isTrue);
      await t.tap(find.byKey(const Key('join-go')));
      await settle(t);
      expect(w.log, ['login 0000aa01', 'joinreq 0000aa01 ${'一' * 10} mpend/nn']);
      expect(find.byType(MyRequestPage), findsOneWidget, reason: '-> 7.9');
      expect(a.invite.held, isNull, reason: 'the invite is dropped once the request is out');
      expect(find.textContaining('5678'), findsWidgets);
    });

    testWidgets('one node: used without a pick; a bad invite says so and holds nothing', (t) async {
      final w = World(['0000aa01'], {'0000aa01': ''});
      final a = await open(t, w, (a) => JoinTeamPage(app: a, ui: UiState(MemStore())));
      await paste(t, 'bad');
      expect(find.textContaining('邀請不能用'), findsOneWidget);
      expect(a.invite.held, isNull);
      await paste(t, 'INVITE');
      expect(a.invite.held, isNotNull);
      await t.enterText(find.byKey(const Key('join-name')), '小明');
      await settle(t);
      expect(goEnabled(t), isTrue, reason: 'the only node is picked');
      await t.tap(find.text('不用這份邀請'));
      await settle(t);
      expect(a.invite.held, isNull);
    });
  });

  group('7.9 my request', () {
    testWidgets('shown again from mpend; 放棄申請 removes mpend under the lease after the question', (t) async {
      final w = World(['0000aa01'], {});
      await open(t, w, (a) => MyRequestPage(app: a, ui: UiState(MemStore()), netId: 'nn'));
      expect(find.textContaining('5678'), findsOneWidget);
      expect(find.text('不要用傳邀請的同一個聊天室核對'), findsOneWidget);
      await t.tap(find.text('放棄申請'));
      await settle(t);
      expect(find.textContaining('同意碼都不能再匯入'), findsOneWidget);
      expect(w.disk, isEmpty, reason: 'nothing before the yes');
      await t.tap(find.text('取消'));
      await settle(t);
      expect(w.disk, isEmpty, reason: '取消 -> nothing');
      await t.tap(find.text('放棄申請'));
      await settle(t);
      await t.tap(find.text('放棄申請').last); // the dialog's button
      await settle(t);
      expect(w.disk, ['rm mpend/nn']);
    });

    testWidgets('renewed: the notice', (t) async {
      final w = World([], {});
      await open(t, w, (a) => MyRequestPage(app: a, ui: UiState(MemStore()), netId: 'nn', hex: 'H', sas: '1111', renewed: true));
      expect(find.text('申請已換新，要重新核對確認碼'), findsOneWidget);
    });
  });

  group('7.10 import the approval', () {
    testWidgets('SAS -> ECDH, mnet written, mpend removed, z zeroed; the join waits for the button (Y-m8)', (t) async {
      final w = World([], {});
      final joins = <String>[];
      await open(t, w, (a) => ImportApprovalPage(app: a, ui: UiState(MemStore()), onJoin: (_, id) => joins.add(id)));
      await paste(t, 'APPROVAL');
      expect(find.text('4821'), findsWidgets);
      expect(w.ecdh, isEmpty, reason: 'no ECDH before the user pressed');
      await t.tap(find.byKey(const Key('sasConfirm')));
      await settle(t);
      expect(rust.seen, ['prepare replace=false', 'approve sas=4821 replace=false']);
      expect(w.disk, ['cas mnet/nn', 'rm mpend/nn']);
      expect(rust.z, hasLength(32));
      expect(rust.z, everyElement(0), reason: 'B-m5: z zeroed');
      expect(find.textContaining('已匯入網路「山隊」'), findsOneWidget);
      expect(joins, isEmpty);
      await t.tap(find.byKey(const Key('import-join')));
      expect(joins, ['nn']);
    });

    testWidgets('AC-m3: the default 讓這台加入 -> 4.1 in member mode on the network just imported', (t) async {
      final w = World([], {});
      await open(t, w, (a) => ImportApprovalPage(app: a, ui: UiState(MemStore())));
      await paste(t, 'APPROVAL');
      await t.tap(find.byKey(const Key('sasConfirm')));
      await settle(t);
      await t.tap(find.byKey(const Key('import-join')));
      await settle(t);
      final f = t.widget<NetFormPage>(find.byType(NetFormPage));
      expect([f.mode, f.memberNet, f.makes], [NetMode.member, 'nn', false]);
    });

    testWidgets('replace: asked first; 取消 -> nothing written; 換成新的 -> prepared again with replace', (t) async {
      rust.importState = ImportState.replace;
      final w = World([], {});
      await open(t, w, (a) => ImportApprovalPage(app: a, ui: UiState(MemStore())));
      await paste(t, 'APPROVAL');
      expect(find.text('要換掉舊的網路紀錄嗎'), findsOneWidget);
      await t.tap(find.text('取消'));
      await settle(t);
      expect(find.textContaining('保留舊紀錄'), findsOneWidget);
      expect(w.disk, isEmpty);
      expect(find.byKey(const Key('sasConfirm')), findsNothing);
      await paste(t, 'APPROVAL');
      await t.tap(find.text('換成新的'));
      await settle(t);
      await t.tap(find.byKey(const Key('sasConfirm')));
      await settle(t);
      expect(rust.seen.last, 'approve sas=4821 replace=true');
    });

    testWidgets('not ready: Rust\'s line as is, no SAS', (t) async {
      rust.importState = ImportState.alreadyImported;
      final w = World([], {});
      await open(t, w, (a) => ImportApprovalPage(app: a, ui: UiState(MemStore())));
      await paste(t, 'APPROVAL');
      expect(find.textContaining('同意碼已經用過了'), findsOneWidget);
      expect(find.byKey(const Key('sasConfirm')), findsNothing);
    });
  });

  group('8.5 new key', () {
    testWidgets('paste only; Advance: ECDH, Rust lines as is; this network + unread listed; asked, sent, no tick',
        (t) async {
      final w = World(['0000aa01', '0000bb02', '0000cc03'], {'0000aa01': 'nn', '0000bb02': 'other'});
      await open(t, w, (a) => UpdateImportPage(app: a, ui: UiState(MemStore())));
      expect(find.byKey(const Key('code-scan')), findsNothing, reason: 'T10: paste only');
      await paste(t, 'UPDATE');
      expect(rust.seen.first, 'uprep nodes=0', reason: 'node records read through readRecord (none stored here)');
      expect(w.ecdh, hasLength(1));
      expect(rust.z, everyElement(0));
      expect(w.disk, ['cas mnet/nn']);
      expect(find.textContaining('更新到第 3 版'), findsOneWidget);
      expect(find.byKey(const Key('update-node-0000aa01')), findsOneWidget);
      expect(find.byKey(const Key('update-node-0000bb02')), findsNothing, reason: 'another network');
      expect(find.byKey(const Key('update-node-0000cc03')), findsOneWidget, reason: 'unread: listed');
      expect(find.text('讀不到，不知道是不是這個網路'), findsOneWidget);
      w.log.clear();
      await t.tap(sendOf('0000aa01'));
      await settle(t);
      expect(find.text(kMemberSendAsk), findsOneWidget);
      await t.tap(find.text('取消'));
      await settle(t);
      expect(w.log, isEmpty, reason: 'T30: no send without the yes');
      await t.tap(sendOf('0000aa01'));
      await settle(t);
      await t.tap(find.text('送出').last); // the dialog's button
      await settle(t);
      expect(w.log, contains('send 0000aa01 mnet/nn member=true'));
      expect(find.byType(RekeyResult), findsOneWidget);
      expect(find.byKey(const Key('rekey-tick')), findsNothing, reason: 'T-M1: never a tick on the member side');
    });

    testWidgets('AddSecrets: no ECDH (S-m8)', (t) async {
      rust.updateState = UpdateState.addSecrets;
      final w = World([], {});
      await open(t, w, (a) => UpdateImportPage(app: a, ui: UiState(MemStore())));
      await paste(t, 'UPDATE');
      expect(w.ecdh, isEmpty);
      expect(rust.seen, contains('uimport z=0'));
      expect(w.disk, ['cas mnet/nn']);
    });

    testWidgets('already imported: the warning, nothing written', (t) async {
      rust.updateState = UpdateState.alreadyImported;
      final w = World([], {});
      await open(t, w, (a) => UpdateImportPage(app: a, ui: UiState(MemStore())));
      await paste(t, 'UPDATE');
      expect(find.textContaining('這份更新包你之前匯入過了，可能不是最新的'), findsOneWidget);
      expect(w.disk, isEmpty);
      expect(w.ecdh, isEmpty);
    });
  });

  group('R14 RekeyResult', () {
    Future<void> show(WidgetTester t, RekeyEnd end, bool member, {int? version}) => t.pumpWidget(host(Scaffold(
        body: RekeyResult(end: end, line: '[UPDATED] 節點 …01 已換成新密碼', member: member, version: version))));

    testWidgets('leader: the tick only on current', (t) async {
      await show(t, RekeyEnd.current, false);
      expect(find.byKey(const Key('rekey-tick')), findsOneWidget);
      expect(find.text(kRekeyDoneRule), findsOneWidget);
      await show(t, RekeyEnd.applying, false);
      expect(find.byKey(const Key('rekey-tick')), findsNothing);
      expect(find.text('狀態頁就是那台的節點頁'), findsOneWidget);
    });

    testWidgets('T-M1 member: never a tick; the version line; 換好 only on current', (t) async {
      await show(t, RekeyEnd.current, true, version: 3);
      expect(find.byKey(const Key('rekey-tick')), findsNothing);
      expect(find.text('這支手機是第 3 版'), findsOneWidget);
      expect(find.text('這台節點已換成這支手機的版本'), findsOneWidget);
      expect(find.text(kMemberRekeyRule), findsOneWidget);
      await show(t, RekeyEnd.applying, true);
      expect(find.text('這支手機的版本讀不到'), findsOneWidget);
      expect(find.text('這台還沒換好，先不要跟隊長說換好了'), findsOneWidget);
    });
  });
}

bool goEnabled(WidgetTester t) {
  final b = t.widget<ButtonStyleButton>(
      find.descendant(of: find.byKey(const Key('join-go')), matching: find.bySubtype<ButtonStyleButton>()));
  return b.onPressed != null;
}

/// Lets the fakes' futures run, then the frames.
Future<void> settle(WidgetTester t) async {
  for (var i = 0; i < 6; i++) {
    await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 5)));
    await t.pump(const Duration(milliseconds: 400));
  }
}
