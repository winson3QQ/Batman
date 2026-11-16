// #329 PR 5 plan v16 §2.5 / §6 step 3: OfflineOp (R10–R12) and runNetOp, with the lease registry and a manual clock.
import 'dart:async';
import 'dart:io';

import 'package:batman_app/src/flows/offline_op.dart';
import 'package:batman_app/src/nodelink/lease.dart';
import 'package:batman_app/src/nodelink/record_writer.dart';
import 'package:batman_app/src/rust/api/owner.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../nodelink/lease_test.dart' show Clock, setup;

OwnerStep st(OwnerKind kind, {String hex = '', String detail = '', String note = '', String rel = 'net/aa'}) => OwnerStep(
    kind: kind,
    frames: const [],
    signInput: Uint8List(1),
    detail: detail,
    record: Uint8List(2),
    rel: rel,
    generation: BigInt.two,
    aad: Uint8List(1),
    expectedGen: BigInt.one,
    pollLink: false,
    hex: hex,
    sas: '',
    renewed: false,
    sent: false,
    left: false,
    waitMs: BigInt.zero,
    sendUpdate: false,
    info: Uint8List(0),
    sw: false,
    note: note,
    loginEnd: 0,
    loginCode: BigInt.zero);

OfflineDeps deps(LeaseRegistry reg, Clock clock, RecordWriter w, {List<String>? log}) => OfflineDeps(
      acquire: (name) async => reg.acquire(name, LeaseKind.session),
      busyName: () => reg.current?.name,
      writer: w,
      after: clock.after,
      log: log?.add,
    );

OfflinePlatform platform({List<Object>? keyErrors, Object? signThrows}) => OfflinePlatform(
      seal: (plain, aad) async => Uint8List.fromList([9, ...plain]),
      signAdmin: (input) async {
        if (signThrows != null) throw signThrows;
        return Uint8List.fromList([7]);
      },
      ecdh: (peer) async => Uint8List(32),
      readRecord: (rel) async => (BigInt.one, Uint8List(1)),
      keyError: (e) => keyErrors?.add(e),
    );

void main() {
  group('R10: OfflineOp', () {
    test('busy: another operation holds the lease -> its name, nothing runs', () async {
      final (reg, clock, _, w, disk) = setup();
      reg.acquire('軟體更新', LeaseKind.session);
      var ran = false;
      final r = await OfflineOp.run(deps(reg, clock, w), '邀請隊員', (l, w) async => ran = true);
      expect(r, isA<OfflineBusy<bool>>().having((b) => b.name, 'name', '軟體更新'));
      expect(ran, isFalse);
      expect(disk, isEmpty);
    });

    test('done: the write lands under the lease, the lease is released', () async {
      final (reg, clock, _, w, disk) = setup();
      final r = await OfflineOp.run(deps(reg, clock, w), '邀請隊員', (l, w) async {
        await w.writeCas(l, 'net/aa', BigInt.one, [1]);
        return 'hex';
      });
      expect(r, isA<OfflineDone<String>>().having((d) => d.value, 'value', 'hex'));
      expect(disk, ['cas net/aa']);
      await Future<void>.delayed(Duration.zero);
      expect(reg.current, isNull);
    });

    test('failed: Rust\'s refusal text verbatim, a key error in the old words; the log has the type only', () async {
      final (reg, clock, _, w, _) = setup();
      final log = <String>[];
      final r1 = await OfflineOp.run<void>(deps(reg, clock, w, log: log), '同意加入', (l, w) async => throw '[REQ_FAIL] 申請不能用：名字太長');
      expect(r1, isA<OfflineFailed<void>>().having((f) => f.line, 'line', '[REQ_FAIL] 申請不能用：名字太長'));
      await Future<void>.delayed(Duration.zero);
      final r2 = await OfflineOp.run<void>(deps(reg, clock, w, log: log), '同意加入', (l, w) async => throw PlatformException(code: 'keystore'));
      expect(r2, isA<OfflineFailed<void>>().having((f) => f.line, 'line', startsWith('手機的金鑰無法使用：')));
      expect(log.join('\n'), isNot(contains('名字太長')), reason: 'R10: the log carries the type, never the message');
      await Future<void>.delayed(Duration.zero);
      expect(reg.current, isNull);
    });

    test('T-P5-2: the work finishes and writes even if nobody awaits it any more', () async {
      final (reg, clock, _, w, disk) = setup();
      final gate = Completer<void>();
      final reply = OfflineOp.run(deps(reg, clock, w), '移除隊員', (l, w) async {
        await gate.future;
        await w.writeCas(l, 'net/aa', BigInt.one, [1]);
      });
      // the page is gone; the work goes on
      gate.complete();
      expect(await reply, isA<OfflineDone<void>>());
      expect(disk, ['cas net/aa']);
    });
  });

  group('R12: the 60 s cap', () {
    test('revoked: unknown, the todo with its own sentence, later writes refused, settled when the work ends', () async {
      final (reg, clock, spy, w, disk) = setup();
      final gate = Completer<void>();
      Object? lateWrite;
      final reply = OfflineOp.run<void>(deps(reg, clock, w), '移除隊員', (l, w) async {
        await gate.future;
        try {
          await w.writeCas(l, 'net/aa', BigInt.one, [1]);
        } catch (e) {
          lateWrite = e;
        }
      });
      await Future<void>.delayed(Duration.zero);
      clock.advance(const Duration(seconds: 59));
      expect(reg.unsavedTodos, isEmpty, reason: 'not before 60 s');
      clock.advance(const Duration(seconds: 1));
      final r = await reply;
      expect(r, isA<OfflineUnknown<void>>());
      expect(reg.unsavedTodos, ['上一個操作可能沒有存完：移除隊員']);
      expect(reg.unsavedText['上一個操作可能沒有存完：移除隊員'], offlineTodoText('移除隊員'));
      expect(spy.events.first, 'revoked 移除隊員');
      final u = r as OfflineUnknown<void>;
      var settled = false;
      unawaited(u.settled.then((_) => settled = true));
      await Future<void>.delayed(Duration.zero);
      expect(settled, isFalse, reason: 'the work has not ended yet');
      gate.complete();
      await u.settled;
      expect(lateWrite, isA<NoLease>(), reason: 'RecordWriter refuses the revoked lease (fail-closed)');
      expect(disk, isEmpty);
    });

    test('a work that ends in time is not revoked by the timer firing later', () async {
      final (reg, clock, _, w, _) = setup();
      final r = await OfflineOp.run(deps(reg, clock, w), '邀請隊員', (l, w) async => 1);
      expect(r, isA<OfflineDone<int>>());
      clock.advance(const Duration(seconds: 61));
      expect(reg.unsavedTodos, isEmpty);
    });

    test('Lease.revoke without a sentence keeps the node todo (PR 1 behaviour)', () {
      final (reg, _, _, _, _) = setup();
      reg.acquire('建立網路', LeaseKind.session)!.revoke();
      expect(reg.unsavedTodos, ['上一個操作可能沒有存完：建立網路']);
      expect(reg.unsavedText, isEmpty);
    });

    test('source check: only OfflineOp calls Lease.revoke in lib/', () {
      final hits = <String>[];
      for (final f in Directory('lib').listSync(recursive: true).whereType<File>().where((f) => f.path.endsWith('.dart'))) {
        final p = f.path.replaceAll(r'\', '/');
        if (p.endsWith('src/nodelink/lease.dart') || p.contains('/src/rust/')) continue;
        final lines = f.readAsLinesSync();
        for (var i = 0; i < lines.length; i++) {
          final code = lines[i].trimLeft();
          if (code.startsWith('//')) continue;
          if (RegExp(r'\.revoke\(').hasMatch(lines[i])) hits.add('$p:${i + 1}');
        }
      }
      expect(hits, isNotEmpty, reason: 'OfflineOp itself must be found (nothing to check is not a pass)');
      expect(hits.where((h) => !h.startsWith('lib/src/flows/offline_op.dart')), isEmpty);
    });
  });

  group('R10: runNetOp', () {
    NetOpCalls calls(List<String> seen, {required OwnerStep afterPersist}) => NetOpCalls(
          signed: (der) {
            seen.add('signed ${der.length}');
            return st(OwnerKind.persistNet);
          },
          netPersisted: () {
            seen.add('persisted');
            return afterPersist;
          },
          persistFailed: (e) {
            seen.add('persistFailed $e');
            return st(OwnerKind.answer, detail: '[REQ_FAIL] 沒有存好');
          },
        );

    test('SignAdmin -> PersistNet -> the code, handed out only after the write', () async {
      final (reg, _, _, w, disk) = setup();
      final l = reg.acquire('邀請隊員', LeaseKind.session)!;
      final seen = <String>[];
      final end = await runNetOp(st(OwnerKind.signAdmin), calls(seen, afterPersist: st(OwnerKind.answer, hex: 'a201', detail: '[INVITE] ok', note: 'dup')), l, w, platform());
      expect(seen, ['signed 1', 'persisted']);
      expect(disk, ['cas net/aa']);
      expect(end, (hex: 'a201', detail: '[INVITE] ok', note: 'dup'));
    });

    test('a key that cannot sign: X26 is told, Rust gets an empty signature', () async {
      final (reg, _, _, w, _) = setup();
      final l = reg.acquire('邀請隊員', LeaseKind.session)!;
      final seen = <String>[], keys = <Object>[];
      await runNetOp(st(OwnerKind.signAdmin), calls(seen, afterPersist: st(OwnerKind.answer)), l, w,
          platform(keyErrors: keys, signThrows: PlatformException(code: 'keystore')));
      expect(seen.first, 'signed 0');
      expect(keys, hasLength(1));
    });

    test('a write refused (no lease) -> persistFailed, no code', () async {
      final (reg, _, _, w, disk) = setup();
      final l = reg.acquire('邀請隊員', LeaseKind.session)!;
      l.revoke();
      final seen = <String>[];
      final end = await runNetOp(st(OwnerKind.persistNet), calls(seen, afterPersist: st(OwnerKind.answer, hex: 'a201')), l, w, platform());
      expect(seen, ['persistFailed no lease']);
      expect(end.hex, isEmpty);
      expect(disk, isEmpty);
    });
  });
}
