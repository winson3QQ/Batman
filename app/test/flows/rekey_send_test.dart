// #329 PR 5 plan v16 §2.9 / §6 step 9: R14 rekeyEnd and R17 sendNewKey (the only send flow of the new pages).
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:batman_app/src/flows/op_session.dart';
import 'package:batman_app/src/flows/owner_console.dart';
import 'package:batman_app/src/flows/rekey_send.dart';
import 'package:batman_app/src/nodelink/lease.dart';
import 'package:batman_app/src/nodelink/node_link.dart' show LoginForEnd, LoginForResult;
import 'package:batman_app/src/rust/api/owner.dart';
import 'package:batman_app/src/rust/frb_generated.dart';
import 'package:flutter_test/flutter_test.dart';

import '../nodes_update_send_test.dart' show FakeRust, fSend, netId, step;
import 'owner_console_test.dart' show Rig, Session;

/// The node answers a send with [sendText].
class SendSession extends Session {
  SendSession(super.rust);
  static String sendText = '[UPDATED] 節點 …0001 已換成新密碼';

  @override
  OwnerStep? onFrame({required List<int> frame}) =>
      frame[0] == fSend + 1 ? step(OwnerKind.answer, detail: sendText) : super.onFrame(frame: frame);
}

class SendFx {
  SendFx(this.rust) {
    rigs = [for (var i = 0; i < 2; i++) Rig(rust, make: SendSession.new)];
    reg = rigs.first.reg;
  }
  final FakeRust rust;
  late final List<Rig> rigs;
  late final LeaseRegistry reg;
  int logins = 0, consoles = 0, confirms = 0;
  bool? confirmAnswer = true;
  final records = <String, Object>{};
  late Lease? _first = rigs.first.lease;

  late final SendDeps d = SendDeps(
    op: OpDeps(
      acquire: (name) async {
        final l = _first;
        if (l != null) {
          _first = null;
          return l;
        }
        return reg.acquire(name, LeaseKind.session);
      },
      busyName: () => '',
      login: (lease, id) async => LoginForResult(LoginForEnd.ok, rigs[logins++].h),
      console: (lease, h) => rigs[consoles++].c,
      keepScreen: (on) async {},
    ),
    readRecord: (rel) async => (BigInt.one, records[rel]),
    confirm: () async {
      confirms++;
      return confirmAnswer;
    },
  );

  Future<T> run<T>(Future<T> Function() f) async {
    T? r;
    var done = false;
    unawaited(f().then((x) {
      r = x;
      done = true;
    }));
    for (var t = 0; t < 400 && !done; t++) {
      for (final g in rigs) {
        await g.clock.run(500);
      }
    }
    expect(done, isTrue, reason: 'sendNewKey did not end');
    return r as T;
  }
}

void main() {
  final rust = FakeRust();
  setUpAll(() => RustLib.initMock(api: rust));
  setUp(() {
    rust.sends.clear();
    SendSession.sendText = '[UPDATED] 節點 …0001 已換成新密碼';
  });

  group('R14: rekeyEnd', () {
    const id = 'bcm2711-6c89ab0001';
    test('the two success sentences, for this node only, whatever the case of the last four (R18)', () {
      expect(rekeyEnd('[UPDATED] 節點 …0001 已是新密碼', ReplyKind.answer, id), RekeyEnd.current);
      expect(rekeyEnd('[UPDATED] 節點 …0001 已換成新密碼', ReplyKind.answer, id), RekeyEnd.current);
      expect(rekeyEnd('[UPDATED] 節點 …ab01 已換成新密碼', ReplyKind.answer, 'x-AB01'), RekeyEnd.current);
      expect(rekeyEnd('[UPDATED] 節點 …0002 已換成新密碼', ReplyKind.answer, id), RekeyEnd.failed, reason: 'another node');
    });
    test('正在套用 is applying, 還有沒完成的變更 is unfinished, the unclear line wins over its [REQ_FAIL] prefix', () {
      expect(rekeyEnd('[UPDATED] 節點 …0001 正在套用新密碼，稍後再看狀態頁', ReplyKind.answer, id), RekeyEnd.applying);
      expect(rekeyEnd(unfinishedLine, ReplyKind.answer, id), RekeyEnd.unfinished);
      expect(rekeyEnd(sendUnclearLine, ReplyKind.answer, id), RekeyEnd.unclear);
      expect(rekeyEnd('anything', ReplyKind.unclear, id), RekeyEnd.unclear);
    });
    test('anything else is failed (fail-closed), an [UPDATED] with extra words included', () {
      expect(rekeyEnd('[REQ_FAIL] 沒有送出：這台在別的隊伍網路', ReplyKind.answer, id), RekeyEnd.failed);
      expect(rekeyEnd('[UPDATED] 節點 …0001 已換成新密碼（假）', ReplyKind.answer, id), RekeyEnd.failed);
      expect(rekeyEnd('', ReplyKind.answer, id), RekeyEnd.failed);
    });
    test('the literals are the ones the Rust test pins (rekey_texts_are_pinned)', () {
      final rs = File('rust/bridge/src/api/rekey.rs').readAsStringSync();
      for (final s in ['已是新密碼"', '已換成新密碼"', '正在套用新密碼，稍後再看狀態頁"', unfinishedLine.substring('[REQ_FAIL] 沒有送出：'.length)]) {
        expect(rs.contains(s), isTrue, reason: s);
      }
    });
  });

  group('R17: sendNewKey', () {
    test('a leader: info -> its net record -> the confirmation outside the lease -> the send; current', () async {
      final f = SendFx(rust)..records['net/$netId'] = Uint8List(4);
      final r = await f.run(() => sendNewKey(f.d, 'bcm-0001', gone: () => false));
      expect((r.end, r.member, f.confirms), (RekeyEnd.current, false, 1));
      expect(rust.sends, ['admin']);
      expect(f.reg.current, isNull, reason: 'both leases released');
    });

    test('the leader says no -> nothing is sent', () async {
      final f = SendFx(rust)
        ..records['net/$netId'] = Uint8List(4)
        ..confirmAnswer = false;
      final r = await f.run(() => sendNewKey(f.d, 'bcm-0001', gone: () => false));
      expect((r.end, r.line), (RekeyEnd.failed, cancelledLine));
      expect(rust.sends, isEmpty);
    });

    test('a member (only an mnet record): no confirmation, sent as a member', () async {
      final f = SendFx(rust)..records['mnet/$netId'] = Uint8List(4);
      final r = await f.run(() => sendNewKey(f.d, 'bcm-0001', gone: () => false));
      expect((r.member, f.confirms), (true, 0));
      expect(rust.sends, ['member']);
    });

    test('Applying is not current', () async {
      SendSession.sendText = '[UPDATED] 節點 …0001 正在套用新密碼，稍後再看狀態頁';
      final f = SendFx(rust)..records['net/$netId'] = Uint8List(4);
      expect((await f.run(() => sendNewKey(f.d, 'bcm-0001', gone: () => false))).end, RekeyEnd.applying);
    });

    test('expectDac / expectNet that do not match, or no record -> not sent, the old sentences', () async {
      final f1 = SendFx(rust)..records['net/$netId'] = Uint8List(4);
      final r1 = await f1.run(() => sendNewKey(f1.d, 'bcm-0001', expectDac: 'cd' * 32, gone: () => false));
      expect(r1.line, notThisNodeLine);
      final f2 = SendFx(rust)..records['net/$netId'] = Uint8List(4);
      final r2 = await f2.run(() => sendNewKey(f2.d, 'bcm-0001', expectNet: 'ff' * 16, gone: () => false));
      expect(r2.line, notThisNetLine);
      final f3 = SendFx(rust);
      final r3 = await f3.run(() => sendNewKey(f3.d, 'bcm-0001', gone: () => false));
      expect(r3.line, noRecordLine);
      expect(rust.sends, isEmpty);
    });

    // #329 PR 5 R18 (review A M3): a last four from Rust (`.last4`, `entryLast4`, `deviceLast4`) is never compared with
    // == / != or through last4(); only sameLast4 (case-insensitive). The old console nodes.dart is the stated exception.
    test('source check R18: Rust last-four fields compared only through sameLast4', () {
      final bad = RegExp(r'(\.last4|entryLast4|deviceLast4)\b\s*[=!]=|[=!]=\s*[\w.!?]*(\.last4|entryLast4|deviceLast4)\b|\blast4\([^)]*\)\s*[=!]=');
      final hits = <String>[];
      var uses = 0;
      for (final f in Directory('lib').listSync(recursive: true).whereType<File>().where((f) => f.path.endsWith('.dart'))) {
        final p = f.path.replaceAll(r'\', '/');
        if (p.endsWith('lib/nodes.dart') || p.contains('/src/rust/')) continue;
        final lines = f.readAsLinesSync();
        for (var i = 0; i < lines.length; i++) {
          if (lines[i].trimLeft().startsWith('//')) continue;
          if (bad.hasMatch(lines[i])) hits.add('$p:${i + 1}: ${lines[i].trim()}');
          if (lines[i].contains('sameLast4(')) uses++;
        }
      }
      expect(uses, greaterThan(3), reason: 'found the compares to check (nothing to check is not a pass)');
      expect(hits, isEmpty);
    });

    // #329 PR 5 R14 (review A M3): a send's result (RekeySent.line, RunRow.sendLine) reaches the screen only through
    // RekeyResult. The one exception is B8: a stop before the record was known (nothing sent) shows its own line.
    test('source check R14: send results shown only through RekeyResult', () {
      final hits = <String>[];
      var results = 0;
      for (final name in ['send_key.dart', 'join_pages.dart', 'remove_pages.dart', 'net_pages.dart']) {
        final lines = File('lib/ui/$name').readAsLinesSync();
        for (var i = 0; i < lines.length; i++) {
          final l = lines[i];
          if (l.trimLeft().startsWith('//')) continue;
          if (l.contains('RekeyResult(')) results++;
          final shows = RegExp(r'Text\(.*\.sendLine\b').hasMatch(l) ||
              (name != 'net_pages.dart' && RegExp(r'Text\(.*\b(s|sent|res)\.line\b').hasMatch(l));
          if (shows && !l.contains("Key('send-key-line')")) hits.add('$name:${i + 1}: ${l.trim()}');
        }
      }
      expect(results, greaterThanOrEqualTo(4), reason: 'every send result place found');
      expect(hits, isEmpty);
    });

    test('source check: sendUpdateFor only in its definition, sendNewKey and NetRun; nobody passes confirm:', () {
      final hits = <String>[], confirms = <String>[];
      for (final f in Directory('lib').listSync(recursive: true).whereType<File>().where((f) => f.path.endsWith('.dart'))) {
        final p = f.path.replaceAll(r'\', '/');
        if (p.endsWith('lib/nodes.dart') || p.contains('/src/rust/')) continue; // the old console: PR 6 removes it
        final lines = f.readAsLinesSync();
        for (var i = 0; i < lines.length; i++) {
          if (lines[i].trimLeft().startsWith('//')) continue;
          if (lines[i].contains('sendUpdateFor(')) hits.add(p);
          if (RegExp(r'sendNewKey\([^)]*confirm:').hasMatch(lines[i])) confirms.add('$p:${i + 1}');
        }
      }
      expect(hits.toSet(), {'lib/src/flows/owner_console.dart', 'lib/src/flows/rekey_send.dart', 'lib/src/flows/net_run.dart'});
      expect(confirms, isEmpty);
    });
  });
}
