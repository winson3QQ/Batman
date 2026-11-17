// #329 PR 5 plan v16 §2.5 (R10–R12): a write that does not reach a node (invite, approve, remove, update bundles,
// imports, dropping a request) still holds the session lease and writes only through RecordWriter (design §4.4).
// The old console's _runOp / _runRemove (nodes.dart:773-795, :1425-1448) are runNetOp here, unchanged in their steps.
import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/services.dart' show PlatformException;

import '../../key_abilities.dart' show KeyAbilities;
import '../nodelink/lease.dart';
import '../nodelink/record_writer.dart';
import '../rust/api/owner.dart' show OwnerKind, OwnerStep;

/// What an offline operation needs from the platform (Kotlin keys, the record store); tests pass fakes.
class OfflinePlatform {
  const OfflinePlatform({required this.seal, required this.signAdmin, required this.ecdh, required this.readRecord, required this.keyError});
  final Future<Uint8List> Function(Uint8List plain, Uint8List aad) seal;
  final Future<Uint8List> Function(Uint8List input) signAdmin;

  /// the platform's bytes; callers copy them before use (R10, the old _ownCopy) and zero their copy in `finally`
  final Future<Uint8List> Function(Uint8List peer) ecdh;

  /// (generation, plain); plain null = none, or it does not open
  final Future<(BigInt, Uint8List?)> Function(String rel) readRecord;

  /// a key use failed: X26's re-check (AppLink wires keyErrorToRadio)
  final void Function(Object e) keyError;
}

/// What OfflineOp needs from the app (NodeLink's registry and writer); injected so it is testable.
class OfflineDeps {
  const OfflineDeps({required this.acquire, required this.busyName, required this.writer, required this.after, this.log});

  /// NodeLink.acquire(name, session): null = another operation holds the lease
  final Future<Lease?> Function(String name) acquire;
  final String? Function() busyName;
  final RecordWriter writer;

  /// a timer (tests drive it): calls [f] after [d] unless cancelled
  final Cancel Function(Duration d, void Function() f) after;

  /// type-only lines (R10: never a code, a name or an exception message)
  final void Function(String line)? log;
}

/// R10 / R12: how an offline operation ended.
sealed class OfflineReply<T> {
  const OfflineReply();
}

class OfflineDone<T> extends OfflineReply<T> {
  const OfflineDone(this.value);
  final T value;
}

/// another operation holds the lease: 「另一個操作還在進行：`name`」
class OfflineBusy<T> extends OfflineReply<T> {
  const OfflineBusy(this.name);
  final String name;
}

/// the work ended without its result: [line] is Rust's own refusal text where there is one (R10)
class OfflineFailed<T> extends OfflineReply<T> {
  const OfflineFailed(this.line);
  final String line;
}

/// R12: the 60 s cap revoked the lease; the work may still land one write. [settled] completes when the work has
/// really ended (done, failed or thrown), so the page re-reads only then (L-m2).
class OfflineUnknown<T> extends OfflineReply<T> {
  const OfflineUnknown(this.settled);
  final Future<void> settled;
}

/// R12: the cap on one offline operation (local signing and writing only; seconds in practice).
const offlineCap = Duration(seconds: 60);

/// R12: the home todo of a revoked offline operation (a whole sentence; it touches no node).
/// A judgement (R12) has no page of its own (review B m2 / C m4): it names the page it came from instead.
String offlineTodoText(String name) => name == kJudgeName
    ? '確認上一個操作的結果沒有在時間內結束，app 已經停止它。請重新打開剛才那一頁看結果，需要的話再做一次。'
    : '這個操作沒有在時間內結束，app 已經停止它。請重新打開「$name」那一頁看結果，需要的話再做一次。';

/// The text a failure shows: Rust's refusal verbatim, the old console's lines for the rest (R10).
String offlineFailLine(Object e) => switch (e) {
      String s => s,
      PlatformException p => '手機的金鑰無法使用：${KeyAbilities.refusedBy(p) ?? p.code}',
      NoLease _ => '另一個操作還在進行',
      _ => '沒有完成，請再試一次',
    };

/// The text of store_write_cas for a generation that moved (owner.rs:65; nodes.dart:58 staleRecordLine).
const kStaleRecordLine = '紀錄已被別處更新，請重新開啟再試';

/// R12 (W-m12): what a page shows while a revoked operation is judged; it can be left meanwhile.
const kUnknownWait = '結果不明，等一下再查';

/// R12 (U-m / V-m6): judge again when the new lease could not be had.
const kJudgeAgain = '再查一次';

/// R12: the operation name of a judgement (a constant: it goes into the log and a todo).
const kJudgeName = '確認結果';

/// R12: after the revoked work has really ended ([settled], L-m2), [judge] reads the records again in a NEW lease and may
/// tidy up under it (the leftover mpend). No queueing: another operation holding the radio -> [OfflineBusy].
Future<OfflineReply<R>> judgeAfterRevoke<R>(
    OfflineDeps d, Future<void> settled, Future<R> Function(Lease l, RecordWriter w) judge) async {
  await settled;
  return OfflineOp.run(d, kJudgeName, judge);
}

class OfflineOp {
  /// R10: take the session lease, run [work], release; a busy lease, a thrown error and the 60 s cap each end as
  /// their own reply. [name] is a constant (it goes into the log and the todo, R10).
  static Future<OfflineReply<T>> run<T>(OfflineDeps d, String name, Future<T> Function(Lease l, RecordWriter w) work) async {
    final lease = await d.acquire(name);
    if (lease == null) return OfflineBusy<T>(d.busyName() ?? '');
    final settled = Completer<void>();
    final reply = Completer<OfflineReply<T>>();
    final cancel = d.after(offlineCap, () {
      if (reply.isCompleted) return;
      d.log?.call('offline op: $name over ${offlineCap.inSeconds} s, lease revoked');
      lease.revoke(todo: offlineTodoText(name));
      reply.complete(OfflineUnknown<T>(settled.future));
    });
    unawaited(() async {
      try {
        final v = await lease.run(() => work(lease, d.writer));
        if (!reply.isCompleted) reply.complete(OfflineDone<T>(v));
      } catch (e) {
        d.log?.call('offline op: $name ended with ${e.runtimeType}');
        if (!reply.isCompleted) reply.complete(OfflineFailed<T>(offlineFailLine(e)));
      } finally {
        cancel();
        settled.complete();
        if (lease.valid) await lease.release();
      }
    }());
    return reply.future;
  }
}

/// The admin steps of NetOp / RemoveOp (the bridge classes share no interface, so their three calls are passed in).
class NetOpCalls {
  const NetOpCalls({required this.signed, required this.netPersisted, required this.persistFailed});
  final OwnerStep Function(Uint8List der) signed;
  final OwnerStep Function() netPersisted;
  final OwnerStep Function(String error) persistFailed;
}

/// What runNetOp hands back: the code (empty when none), Rust's line, and the duplicate note (254-app-team-status §4.2).
typedef NetOpEnd = ({String hex, String detail, String note});

/// R10: the old _runOp / _runRemove loop: SignAdmin -> PersistNet (sealed, compare-and-swap, through [w] under [l])
/// -> the end. The code is handed out only after the record landed (member.rs op_step). Nothing here copies to the
/// clipboard or opens a dialog: the page does that after OfflineOp returned, outside the lease.
Future<NetOpEnd> runNetOp(OwnerStep? st, NetOpCalls op, Lease l, RecordWriter w, OfflinePlatform p) async {
  while (st != null) {
    switch (st.kind) {
      case OwnerKind.signAdmin:
        Uint8List der;
        try {
          der = await p.signAdmin(st.signInput);
        } on PlatformException catch (e) {
          p.keyError(e);
          der = Uint8List(0); // an empty signature: Rust ends with 管理者金鑰無法簽章
        }
        st = op.signed(der);
      case OwnerKind.persistNet:
        final OwnerStep s = st;
        String? err;
        try {
          final sealed = await p.seal(s.record, s.aad);
          await w.writeCas(l, s.rel, s.expectedGen, sealed);
        } catch (e) {
          if (e is PlatformException) p.keyError(e);
          err = switch (e) {
            String s => s, // store_write_cas's own reason (the "changed elsewhere" line for a generation mismatch)
            PlatformException p => KeyAbilities.refusedBy(p) ?? 'seal ${p.code}',
            NoLease _ => 'no lease',
            _ => '${e.runtimeType}',
          };
        }
        st = err == null ? op.netPersisted() : op.persistFailed(err);
      default:
        return (hex: st.hex, detail: st.detail, note: st.note);
    }
  }
  return (hex: '', detail: '', note: '');
}
