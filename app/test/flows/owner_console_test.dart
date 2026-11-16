// #329 PR 3 §2.3: OwnerConsole — the old console's requests on a handed-over session, returning a ConsoleReply.
// The console paths table (console_paths.dart) runs here as on the old console; then each reply rule of the plan's
// table (kind, text without [ANSWER], persistedRel, sessionAlive, keyError) and the close order. Fake Rust session,
// a fake link that answers every frame [n] with [n + 1], a manual clock.
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:batman_app/member_ui.dart' show askNoLink, notSentLine;
import 'package:batman_app/src/flows/owner_console.dart';
import 'package:batman_app/src/nodelink/ble_gate.dart';
import 'package:batman_app/src/nodelink/handoff.dart';
import 'package:batman_app/src/nodelink/lease.dart';
import 'package:batman_app/src/nodelink/record_writer.dart';
import 'package:batman_app/src/rust/api/owner.dart';
import 'package:batman_app/src/rust/frb_generated.dart';
import 'package:flutter/services.dart' show PlatformException;
import 'package:flutter_test/flutter_test.dart';

import '../console_paths.dart';
import '../nodelink/node_link_test.dart' show Clock;
import '../nodes_update_send_test.dart' show FakeRust, FakeSession, fSend, step;

const fMake = 60;

/// The old console's fake session, plus make-network (SignAdmin -> PersistNet -> write -> [NET_MADE]).
class Session extends FakeSession {
  Session(super.rust);
  bool disposed = false;
  final calls = <String>[];
  Object? refuseJoin; // thrown by requestJoinNetwork (a Rust refusal is a String)
  bool signFirst = false; // the confirm starts with an owner signature (code review A M19)

  @override
  OwnerStep requestConfirmNetwork({required List<int> recordPlain, required BigInt recordGen}) =>
      signFirst ? step(OwnerKind.sign) : super.requestConfirmNetwork(recordPlain: recordPlain, recordGen: recordGen);

  @override
  OwnerStep requestJoinNetwork(
      {required List<int> recordPlain,
      required BigInt recordGen,
      required List<int> adminPub,
      required List<int> ownerEncPub,
      required bool removedConfirmed}) {
    final r = refuseJoin;
    if (r != null) throw r;
    return super.requestJoinNetwork(
        recordPlain: recordPlain, recordGen: recordGen, adminPub: adminPub, ownerEncPub: ownerEncPub, removedConfirmed: removedConfirmed);
  }

  @override
  OwnerStep requestMakeNetwork({required String netName, required int channel, required List<int> ownerEncPub, required List<int> adminPub}) {
    calls.add('make $netName $channel');
    return step(OwnerKind.signAdmin);
  }

  @override
  OwnerStep? signed({required List<int> der}) {
    calls.add('signed ${der.length}');
    return der.isEmpty ? step(OwnerKind.answer, detail: '[REQ_FAIL] 手機的管理者金鑰無法簽章') : step(OwnerKind.persistNet, rel: 'net/abc');
  }

  @override
  OwnerStep? netPersisted() {
    calls.add('netPersisted');
    return step(OwnerKind.write, frame: fMake);
  }

  @override
  OwnerStep? persistFailed({required String error}) {
    calls.add('persistFailed $error');
    return step(OwnerKind.answer, detail: '[REQ_FAIL] 網路資料沒有存成功');
  }

  @override
  OwnerStep? onFrame({required List<int> frame}) {
    if (frame[0] == fMake + 1) return step(OwnerKind.answer, detail: '[NET_MADE] 網路已建立');
    if (frame[0] == 99) return step(OwnerKind.ended, detail: '[REQ_FAIL] 節點結束了連線');
    return super.onFrame(frame: frame);
  }

  // the real request marks its frames `sent` (they carry the node's new secrets): a lost link after them is unclear
  @override
  OwnerStep requestSendUpdate({required List<int> recordPlain, required bool member, required List<int> adminPub}) {
    rust.sends.add(member ? 'member' : 'admin');
    return step(OwnerKind.write, frame: fSend, sent: true);
  }

  @override
  String nodeDacHash() => 'ab' * 32;

  @override
  void dispose() {
    calls.add('dispose');
    disposed = true;
  }
}

/// A link whose node answers each frame [n] with [n + 1] (unless [silent]); its state reports a drop.
class EchoRadio implements BleBackend {
  final tx = StreamController<List<int>>.broadcast(sync: true);
  final _st = StreamController<(String, bool)>.broadcast(sync: true);
  final written = <int>[];
  bool silent = false;
  Object? failWrite;
  StreamController<bool>? conn;

  @override
  Stream<String> scan() => const Stream.empty();
  @override
  Stream<bool> connect(String address, Duration timeout) {
    final c = conn = StreamController<bool>(onCancel: () => _st.add((address, false)));
    c.add(true);
    return c.stream;
  }

  void drop() => conn?.add(false);

  @override
  Stream<(String, bool)> get linkStates => _st.stream;
  @override
  Future<int> requestMtu(String address, int mtu) async => 247;
  @override
  Future<List<int>> read(String address, Char c) async => [0];
  @override
  Stream<List<int>> subscribe(String address, Char c) => tx.stream;
  @override
  Future<void> write(String address, Char c, List<int> value) async {
    final f = failWrite;
    if (f != null) throw f;
    written.add(value[0]);
    if (!silent) scheduleMicrotask(() => tx.add([value[0] + 1]));
  }
}

class Rig {
  Rig(this.rust, {Session Function(FakeRust)? make}) {
    reg = LeaseRegistry(after: clock.after);
    gate = BleGate(radio, reg, now: () => clock.t, after: clock.after);
    lease = reg.acquire('建立網路', LeaseKind.session)!;
    link = gate.connect(lease.token, 'a1');
    session = (make ?? Session.new)(rust); // #329 PR 4: a session with more requests (owner_console_pr4_test)
    final inbox = FrameInbox();
    h = LoginHandoff(id: 'Y1', link: link, inbox: inbox, session: session, sub: radio.tx.stream.listen(inbox.add));
    writer = RecordWriter(
        reg,
        RecordStore(
          writeCas: (rel, g, s) async {
            final f = casFail;
            if (f != null) throw f;
            final w = slowCas;
            if (w != null) await w.future;
            cas.add(rel);
            return g + BigInt.one;
          },
          writeSealed: (rel, g, s) async {},
          remove: (rel) async {},
          keepCopy: (rel) async => true,
        ));
  }
  final FakeRust rust;
  final clock = Clock();
  final radio = EchoRadio();
  late final LeaseRegistry reg;
  late final BleGate gate;
  late final Lease lease;
  late final GateLink link;
  late final Session session;
  late final LoginHandoff h;
  late final RecordWriter writer;
  final cas = <String>[];
  Object? casFail, sealFail, signFail, signOwnerFail;
  int lost = 0;
  Completer<void>? slowCas, slowSeal;
  String? makeRefusal;
  final keyErrors = <Object>[];
  String? countryAnswer, removedAnswer;
  final logs = <String>[]; // #329 PR 4 security review LOW-2: the console's log lines

  late final OwnerConsole c = OwnerConsole(
    h,
    lease,
    writer,
    ConsolePlatform(
      seal: (p, a) async {
        final w = slowSeal;
        if (w != null) await w.future;
        final f = sealFail;
        if (f != null) throw f;
        return Uint8List(3);
      },
      signOwner: (i) async {
        final f = signOwnerFail;
        if (f != null) throw f;
        return Uint8List(70);
      },
      signAdmin: (i) async {
        final f = signFail;
        if (f != null) throw f;
        return Uint8List(70);
      },
      publicKeys: () async => {'owner': Uint8List(65), 'ownerEnc': Uint8List(65), 'admin': Uint8List(65)},
      readRecord: (rel) async => (BigInt.one, Uint8List(4)),
      makeNetworkRefusal: () async => makeRefusal,
    ),
    after: clock.after,
    nowMs: () => clock.t,
    askCountry: (q) async => countryAnswer == '改',
    askRemoved: (q) async => removedAnswer == '確定，加回',
    keyError: keyErrors.add,
    log: logs.add,
    onLost: () => lost++,
  );

  /// Runs [f] while the clock goes on (the console's waits and the link check are on it).
  Future<T> run<T>(Future<T> Function() f, {int ms = 200000}) async {
    T? r;
    var done = false;
    unawaited(f().then((x) {
      r = x;
      done = true;
    }));
    for (var t = 0; t < ms && !done; t += 500) {
      await clock.run(500);
    }
    expect(done, isTrue, reason: 'the request did not end');
    return r as T;
  }
}

void main() {
  final rust = FakeRust();
  setUpAll(() => RustLib.initMock(api: rust));
  setUp(() {
    rust
      ..sends.clear()
      ..joinMode = 'plain'
      ..pollAfterJoin = false;
  });

  group('the console paths table, as on the old console', () {
    for (final p in consolePaths) {
      test(p.name, () async {
        rust.joinMode = p.joinMode;
        rust.pollAfterJoin = p.poll;
        final rig = Rig(rust)
          ..countryAnswer = p.answer
          ..removedAnswer = p.answer;
        var r = await rig.run(() => p.action == 'join' ? rig.c.joinNetwork('net/x') : rig.c.confirmNetwork('net/x'));
        if (p.poll) {
          expect(r.pollLink, isTrue);
          r = await rig.run(rig.c.linkCheck);
        }
        expect(rust.sends, p.sends);
        if (p.answer == '改') expect(rig.radio.written, contains(fSend));
        if (p.answer == '不要') expect(rig.radio.written, isNot(contains(fSend)));
        expect(r.text, contains(p.ends));
        await rig.c.close();
      });
    }
  });

  test('an answer is Rust\'s detail without the old [ANSWER] mark; joined / connected read by their start', () async {
    final rig = Rig(rust);
    final r = await rig.run(() => rig.c.confirmNetwork('net/x'));
    expect((r.kind, r.text), (ReplyKind.answer, '[NET_OK] 網路已套用'));
    expect(r.starts('[NET_OK] '), isTrue);
    expect(r.text.startsWith('[ANSWER]'), isFalse);
    await rig.c.close();
  });

  test('ConfirmCountry 不要 is the node\'s answer (not notSent): the page asks continue / stop', () async {
    rust.joinMode = 'country';
    final rig = Rig(rust)..countryAnswer = '不要';
    final r = await rig.run(() => rig.c.joinNetwork('net/x'));
    expect(r.kind, ReplyKind.answer);
    expect(r.starts('[JOINED] '), isFalse);
    await rig.c.close();
  });

  test('ConfirmRemoved 取消 -> notSent with the old line, the join not started again', () async {
    rust.joinMode = 'removed';
    final rig = Rig(rust)..removedAnswer = null;
    final r = await rig.run(() => rig.c.joinNetwork('net/x'));
    expect((r.kind, r.text), (ReplyKind.notSent, joinCancelledLine));
    expect(rust.sends, ['join removed=false']);
    await rig.c.close();
  });

  test('make network: persistedRel only once its record is written; the [NET_MADE] answer', () async {
    final rig = Rig(rust);
    final r = await rig.run(() => rig.c.makeNetwork(name: ' Team ', channel: 42));
    expect((r.kind, r.persistedRel, r.sessionAlive), (ReplyKind.answer, 'net/abc', true));
    expect(r.starts('[NET_MADE] '), isTrue);
    expect(rig.cas, ['net/abc']);
    expect(rig.session.calls.first, 'make Team 42');
    await rig.c.close();
  });

  test('a record write that fails: Rust\'s [REQ_FAIL] answer, no persistedRel, the session still usable', () async {
    final rig = Rig(rust)..casFail = '紀錄已被別處更新，請重新開啟再試';
    final r = await rig.run(() => rig.c.makeNetwork(name: 'n', channel: 40));
    expect((r.kind, r.persistedRel, r.sessionAlive), (ReplyKind.answer, null, true));
    expect(r.text, startsWith('[REQ_FAIL] '));
    expect(rig.session.calls, contains('persistFailed 紀錄已被別處更新，請重新開啟再試'));
    await rig.c.close();
  });

  test('a GATT write that fails: one try only (no resend), unclear / notSent, the session given up', () async {
    final rig = Rig(rust)..radio.failWrite = Exception('GATT 133');
    final r = await rig.run(() => rig.c.joinNetwork('net/x'));
    expect(r.kind, ReplyKind.notSent, reason: 'nothing was written before the join went out');
    expect(r.text, notSentLine);
    expect(r.sessionAlive, isFalse);
    expect(rust.sends, ['join removed=false'], reason: 'the old resend branch is not copied');
    final again = await rig.run(() => rig.c.confirmNetwork('net/x'));
    expect((again.kind, again.text), (ReplyKind.notSent, askNoLink), reason: 'ask never logs in itself');
    await rig.c.close();
  });

  test('a Rust refusal -> refused with its line, the session still usable', () async {
    final rig = Rig(rust)..session.refuseJoin = '這台節點已經在別的網路裡';
    final r = await rig.run(() => rig.c.joinNetwork('net/x'));
    expect((r.kind, r.text, r.sessionAlive), (ReplyKind.refused, '這台節點已經在別的網路裡', true));
    await rig.c.close();
  });

  test('Rust ends the session -> ended, sessionAlive false', () async {
    final rig = Rig(rust);
    final f = rig.run(() => rig.c.confirmNetwork('net/x'));
    rig.radio.silent = true;
    await rig.clock.run(100);
    rig.radio.tx.add([99]);
    final r = await f;
    expect((r.kind, r.sessionAlive), (ReplyKind.ended, false));
    await rig.c.close();
  });

  test('confirm unanswered: 15 s, then unclear with the old wait line, the session given up', () async {
    final rig = Rig(rust)..radio.silent = true;
    final t0 = rig.clock.t;
    final r = await rig.run(() => rig.c.confirmNetwork('net/x'));
    expect(rig.clock.t - t0, inInclusiveRange(15000, 16000));
    expect((r.kind, r.sessionAlive), (ReplyKind.unclear, false));
    expect(r.text, contains('15 秒內節點沒有回應'));
    await rig.c.close();
  });

  test('send update unanswered: 360 s (the join wait) and the old send line', () async {
    final rig = Rig(rust)..radio.silent = true;
    final t0 = rig.clock.t;
    final r = await rig.run(() => rig.c.sendUpdateFor('net/x'), ms: 400000);
    expect(rig.clock.t - t0, inInclusiveRange(360000, 361000));
    expect((r.kind, r.text), (ReplyKind.unclear, sendUnclearLine));
    expect(rust.sends, ['admin'], reason: 'member: false');
    await rig.c.close();
  });

  test('make network after its record was written, the link lost -> unclear (檢查網路) with persistedRel', () async {
    final rig = Rig(rust)..radio.silent = true;
    final f = rig.run(() => rig.c.makeNetwork(name: 'n', channel: 40));
    await rig.clock.run(500);
    expect(rig.cas, ['net/abc']);
    rig.radio.drop();
    final r = await f;
    expect((r.kind, r.text, r.persistedRel, r.sessionAlive), (ReplyKind.unclear, makeUnclearLine, 'net/abc', false));
    await rig.c.close();
  });

  test('review v17 AH m1: the link lost while the record write runs -> the reply waits for it (persistedRel set)', () async {
    final rig = Rig(rust)..radio.silent = true;
    rig.slowCas = Completer<void>();
    final f = rig.run(() => rig.c.makeNetwork(name: 'n', channel: 40));
    await rig.clock.run(300);
    rig.radio.drop(); // during the CAS
    await rig.clock.run(300);
    rig.slowCas!.complete();
    final r = await f;
    expect((r.kind, r.text, r.persistedRel), (ReplyKind.unclear, makeUnclearLine, 'net/abc'));
    await rig.c.close();
  });

  test('a key the gate refused while signing -> keyError, reported, the flow ends (no record write)', () async {
    final rig = Rig(rust)..signFail = PlatformException(code: 'keyLevel', message: 'ADMIN_SIGN');
    final r = await rig.run(() => rig.c.makeNetwork(name: 'n', channel: 40));
    expect((r.keyError, r.persistedRel), (true, null));
    expect(rig.keyErrors, hasLength(1));
    expect(rig.cas, isEmpty);
    await rig.c.close();
  });

  test('a key error while sealing keeps keyError and calls persistFailed', () async {
    final rig = Rig(rust)..sealFail = PlatformException(code: 'keystore');
    final r = await rig.run(() => rig.c.makeNetwork(name: 'n', channel: 40));
    expect((r.keyError, r.persistedRel), (true, null));
    expect(rig.session.calls.where((c) => c.startsWith('persistFailed')), hasLength(1));
    await rig.c.close();
  });

  test('the make-network key check refuses -> notSent + keyError, nothing sent', () async {
    final rig = Rig(rust)..makeRefusal = '管理者金鑰不能用';
    final r = await rig.run(() => rig.c.makeNetwork(name: 'n', channel: 40));
    expect((r.kind, r.keyError, r.text), (ReplyKind.notSent, true, '[REQ_FAIL] [KEY_LEVEL] 管理者金鑰不能用'));
    expect(rig.session.calls, isEmpty);
    await rig.c.close();
  });

  test('the lease taken back before the record write: leaseLost, persistFailed called, nothing written', () async {
    final rig = Rig(rust);
    rig.slowSeal = Completer<void>(); // RecordWriter checks the lease when the write starts (PR 1)
    final f = rig.run(() => rig.c.makeNetwork(name: 'n', channel: 40));
    await rig.clock.run(100);
    await rig.lease.release();
    rig.slowSeal!.complete();
    final r = await f;
    expect(r.kind, ReplyKind.leaseLost);
    expect(rig.cas, isEmpty);
    expect(rig.session.calls.where((c) => c.startsWith('persistFailed')), hasLength(1));
  });

  test('the link check stops at the first end that is not an answer and never logs in again', () async {
    rust.pollAfterJoin = true;
    final rig = Rig(rust);
    final j = await rig.run(() => rig.c.joinNetwork('net/x'));
    expect(j.pollLink, isTrue);
    rig.radio.silent = true;
    final r = await rig.run(rig.c.linkCheck);
    expect((r.kind, r.text), (ReplyKind.unclear, linkUnknownLine));
    expect(rust.sends.where((s) => s == 'link'), hasLength(1));
    await rig.c.close();
  });

  test('close waits for the record write in progress before disposing (no netPersisted after dispose)', () async {
    final rig = Rig(rust);
    rig.slowCas = Completer<void>();
    unawaited(rig.c.makeNetwork(name: 'n', channel: 40));
    await rig.clock.run(100);
    var closed = false;
    unawaited(rig.c.close().then((_) => closed = true));
    await rig.clock.run(100);
    expect(closed, isFalse, reason: 'the CAS still runs');
    rig.slowCas!.complete();
    await rig.clock.run(200);
    expect(closed, isTrue);
    expect(rig.session.calls.last, 'dispose');
    expect(rig.session.calls.indexOf('dispose'), greaterThan(rig.session.calls.indexOf('netPersisted').clamp(-1, 1 << 30)));
    await rig.c.close(); // idempotent
    expect(rig.session.calls.where((c) => c == 'dispose'), hasLength(1));
  });


  test('code review A M19: the owner key refused while signing -> keyError, reported', () async {
    final rig = Rig(rust)
      ..session.signFirst = true
      ..signOwnerFail = PlatformException(code: 'keyLevel', message: 'OWNER_SIGN');
    final r = await rig.run(() => rig.c.confirmNetwork('net/x'));
    expect(r.keyError, isTrue);
    expect(rig.keyErrors, hasLength(1));
    await rig.c.close();
  });

  test('code review B M4: the link lost -> onLost (the page closes the open question); close -> onLost once', () async {
    final rig = Rig(rust)..radio.silent = true;
    final f = rig.run(() => rig.c.confirmNetwork('net/x'));
    await rig.clock.run(100);
    rig.radio.drop();
    await f;
    expect(rig.lost, 1);
    await rig.c.close();
    expect(rig.lost, 2, reason: 'close tells it too');
    await rig.c.close();
    expect(rig.lost, 2, reason: 'idempotent');
  });

  test('code review C N-2: a second close waits for the first (the link is gone before either returns)', () async {
    final rig = Rig(rust);
    rig.slowCas = Completer<void>();
    unawaited(rig.c.makeNetwork(name: 'n', channel: 40));
    await rig.clock.run(100);
    var first = false, second = false;
    unawaited(rig.c.close().then((_) => first = true));
    unawaited(rig.c.close().then((_) => second = true));
    await rig.clock.run(100);
    expect((first, second), (false, false), reason: 'the record write still runs');
    rig.slowCas!.complete();
    await rig.clock.run(200);
    expect((first, second), (true, true));
  });
  test('nodeDacHash comes from the session', () async {
    final rig = Rig(rust);
    expect(rig.c.nodeDacHash(), 'ab' * 32);
    await rig.c.close();
  });

  group('forgetJoining', () {
    test('writes through RecordWriter under its lease and returns Rust\'s line', () async {
      final rig = Rig(rust);
      // the real netForgetJoining is Rust; the fake api answers it
      rust.forgetStep = step(OwnerKind.persistNet, rel: 'net/x', detail: '已忘記');
      final line = await forgetJoining(rig.lease, rig.writer,
          rel: 'net/x', plain: Uint8List(4), gen: BigInt.one, dacHash: 'cd' * 32, seal: (p, a) async => Uint8List(3));
      expect(line, '已忘記');
      expect(rig.cas, ['net/x']);
    });

    test('no lease -> refused, nothing written', () async {
      final rig = Rig(rust);
      rust.forgetStep = step(OwnerKind.persistNet, rel: 'net/x', detail: '已忘記');
      await rig.lease.release();
      await expectLater(
          forgetJoining(rig.lease, rig.writer,
              rel: 'net/x', plain: Uint8List(4), gen: BigInt.one, dacHash: 'cd' * 32, seal: (p, a) async => Uint8List(3)),
          throwsA(isA<String>().having((s) => s, 'line', startsWith('[REQ_FAIL] 忘記沒有成功'))));
      expect(rig.cas, isEmpty);
    });
  });

  test('source lock: new flows and new screens never write a record except through RecordWriter', () {
    final files = [
      ...Directory('lib/src/flows').listSync(recursive: true),
      if (Directory('lib/ui').existsSync()) ...Directory('lib/ui').listSync(recursive: true),
    ].whereType<File>().where((f) => f.path.endsWith('.dart') && !f.path.replaceAll('\\', '/').endsWith('lib/ui/ui_state.dart')).toList();
    expect(files, isNotEmpty, reason: 'nothing to check is a failure, not a pass');
    final bad = RegExp(r'\b(storeWriteCas|storeWriteSealed|storeRemove|storeKeepCopy)\b');
    for (final f in files) {
      expect(bad.hasMatch(f.readAsStringSync()), isFalse, reason: f.path);
    }
  });
}
