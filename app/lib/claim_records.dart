// #254 app — the record writes of one claim attempt (design 254-app-claim-noover v2.1, FROZEN): what PersistPending and
// CLAIMED do on disk, out of the claim page so their order can be tested. A valid record never moves before CLAIMED;
// a record about to be replaced is copied aside first (forgotten-node/ or forgotten-pending/, kept, not listed).
// Nothing secret is logged.
import 'package:flutter/services.dart';

import 'src/rust/api/claim.dart';
import 'src/rust/api/owner.dart' show SealedRecord, storeReadSealed;

const _platform = MethodChannel('dev.batman/platform');

/// The store operations a claim attempt uses (the claim page: [RustClaimStore]; tests: a fake).
abstract class ClaimStore {
  Future<SealedRecord?> readSealed(String rel);

  /// Kotlin opens the record (Keystore AES-GCM); throws when it cannot
  Future<Uint8List> open(SealedRecord s);
  Future<bool> matches(Uint8List pendingPlain, ClaimQr qr);

  /// copies `rel` aside (R8); false = nothing there; throws on failure
  Future<bool> keepCopy(String rel);

  /// Kotlin seals, the Rust store writes (atomic, synced)
  Future<void> sealWrite(String rel, Uint8List record);
  Future<void> remove(String rel);
}

class RustClaimStore implements ClaimStore {
  RustClaimStore(this.dir);
  final String dir;

  @override
  Future<SealedRecord?> readSealed(String rel) => storeReadSealed(dir: dir, rel: rel);

  @override
  Future<Uint8List> open(SealedRecord s) async =>
      (await _platform.invokeMethod<Uint8List>('open', {'sealed': s.sealed, 'aad': s.aad}))!;

  @override
  Future<bool> matches(Uint8List pendingPlain, ClaimQr qr) => pendingMatchesQr(record: pendingPlain, qr: qr);

  @override
  Future<bool> keepCopy(String rel) => storeKeepCopy(dir: dir, rel: rel);

  @override
  Future<void> sealWrite(String rel, Uint8List record) async {
    final p = await storeSealParams(dir: dir, rel: rel);
    final sealed = (await _platform.invokeMethod<Uint8List>('seal', {'plain': record, 'aad': p.aad}))!;
    await storeWriteSealed(dir: dir, rel: rel, generation: p.generation, sealed: sealed);
  }

  @override
  Future<void> remove(String rel) => storeRemove(dir: dir, rel: rel);
}

/// The line logged when the old node record could not be copied before the new one replaced it (R1).
const oldNotKept = '[OLD_NOT_KEPT] 舊紀錄沒有保留下來';

class ClaimRecords {
  ClaimRecords(this.store, this.qr, this.log);
  final ClaimStore store;
  /// null = a recovery from a pending without a QR (254-app-replay T4): it never persists a pending
  final ClaimQr? qr;
  final void Function(String) log;

  /// PersistPending (R4): decided from disk, whatever was asked before. A pending already there for another K is
  /// copied aside first; if it cannot be opened or copied this throws and the new pending is not written (no begin).
  Future<void> persistPending(String path, Uint8List record) async {
    final q = qr;
    if (q == null) throw StateError('no QR: a recovery without a QR never writes a pending');
    final old = await store.readSealed(path);
    if (old != null && !await store.matches(await store.open(old), q)) {
      await store.keepCopy(path);
    }
    await store.sealWrite(path, record);
  }

  /// CLAIMED (R1): copy the node record there (if any) aside, write the new one, then remove the pending. A failed copy
  /// does not stop the write: the new credentials are only in memory, and CLAIMED shows the old record is dead.
  Future<void> claimed(String nodePath, Uint8List record, String pendingPath) async {
    // any failure of the copy lands here, not only disk full / EIO (bad path, unknown record version, a platform
    // error): all of them are logged and none stops the write, for the same reason (R1).
    try {
      await store.keepCopy(nodePath);
    } catch (e) {
      log('$oldNotKept（$e）');
    }
    await store.sealWrite(nodePath, record);
    try {
      await store.remove(pendingPath);
    } catch (e) {
      throw PendingNotRemoved(e); // the node record IS written (254-app-replay review A-m2)
    }
  }
}

/// [ClaimRecords.claimed] wrote the node record, but the pending could not be removed. The node record counts (a
/// node record beside a pending = node record, noover R2); the leftover pending is harmless.
class PendingNotRemoved implements Exception {
  PendingNotRemoved(this.cause);
  final Object cause;
  @override
  String toString() => '節點紀錄已寫好，但沒能刪掉這次的認領暫存紀錄（$cause）';
}
