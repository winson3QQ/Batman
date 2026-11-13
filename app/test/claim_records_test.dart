// design 254-app-claim-noover v2.1 §8: what PersistPending and CLAIMED do on disk (ClaimRecords), against an
// in-memory store that logs every call. T3: a re-claim never touches the node record before CLAIMED; at CLAIMED:
// copy(node) -> write(node) -> remove(pending). T4: the cached-state window (finish 9 after PersistPending) leaves the
// node record. T5: a pending of another K is copied aside before it is replaced. T11: a failed copy at CLAIMED still
// writes the node record (and logs it). T12: a failed copy at PersistPending writes nothing.
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:batman_app/claim_records.dart';
import 'package:batman_app/src/rust/api/claim.dart';
import 'package:batman_app/src/rust/api/owner.dart' show SealedRecord;

const id = '0000000000000c4f2a';
const node = 'node/$id', pending = 'claim-pending/$id';

/// records are plain bytes here: byte 0 = "K" of a pending (matches = same first byte as the QR's K)
class FakeStore implements ClaimStore {
  final disk = <String, Uint8List>{};
  final calls = <String>[];
  bool copyFails = false;

  @override
  Future<SealedRecord?> readSealed(String rel) async {
    final b = disk[rel];
    return b == null ? null : SealedRecord(generation: BigInt.one, sealed: b, aad: Uint8List(0));
  }

  @override
  Future<Uint8List> open(SealedRecord s) async => s.sealed;

  @override
  Future<bool> matches(Uint8List plain, ClaimQr qr) async => plain[0] == qr.k[0];

  @override
  Future<bool> keepCopy(String rel) async {
    calls.add('copy $rel');
    if (copyFails) throw 'Io(StorageFull)';
    if (!disk.containsKey(rel)) return false;
    var n = 1;
    while (disk.containsKey('forgotten-${rel.split('/')[0] == 'node' ? 'node' : 'pending'}/$id-$n')) {
      n++;
    }
    disk['forgotten-${rel.split('/')[0] == 'node' ? 'node' : 'pending'}/$id-$n'] = disk[rel]!;
    return true;
  }

  @override
  Future<void> sealWrite(String rel, Uint8List record) async {
    calls.add('write $rel');
    disk[rel] = record;
  }

  @override
  Future<void> remove(String rel) async {
    calls.add('remove $rel');
    disk.remove(rel);
  }
}

ClaimQr qr(int k) => ClaimQr(deviceId: id, k: Uint8List.fromList(List.filled(32, k)));
Uint8List rec(int b) => Uint8List.fromList([b, 0xaa]);

void main() {
  late FakeStore store;
  late List<String> logs;
  ClaimRecords records(int k) => ClaimRecords(store, qr(k), logs.add);
  setUp(() {
    store = FakeStore();
    logs = [];
  });

  test('T3: a re-claim over a node record: PersistPending leaves it; CLAIMED copies, writes, then removes the pending',
      () async {
    store.disk[node] = rec(0x11);
    final r = records(7);
    await r.persistPending(pending, rec(7));
    expect(store.calls, ['write $pending'], reason: 'the node record is not touched before CLAIMED');
    expect(store.disk[node], rec(0x11));
    await r.claimed(node, rec(0x22), pending);
    expect(store.calls, ['write $pending', 'copy $node', 'write $node', 'remove $pending']);
    expect(store.disk['forgotten-node/$id-1'], rec(0x11), reason: 'the old record is kept');
    expect(store.disk[node], rec(0x22));
    expect(store.disk.containsKey(pending), isFalse);
  });

  test('T4: the cached-state window: PersistPending, then finish 9 (no CLAIMED) -> the node record stays', () async {
    store.disk[node] = rec(0x11);
    await records(7).persistPending(pending, rec(7));
    // finish 9 = TryReplay: Ended, nothing more is written
    expect(store.disk[node], rec(0x11), reason: 'still listed, still logs in');
    expect(store.calls.where((c) => c.contains(node)), isEmpty);
  });

  test('T5: a pending of another K is copied aside before it is replaced (also beside a node record)', () async {
    store.disk[node] = rec(0x11);
    store.disk[pending] = rec(1);
    await records(2).persistPending(pending, rec(2));
    expect(store.calls, ['copy $pending', 'write $pending']);
    expect(store.disk['forgotten-pending/$id-1'], rec(1));
    expect(store.disk[pending], rec(2));
    expect(store.disk[node], rec(0x11));
  });

  test('T5: a pending of the same K is replaced without a copy (§5.2-1); no pending -> no copy', () async {
    store.disk[pending] = rec(2);
    await records(2).persistPending(pending, rec(2));
    expect(store.calls, ['write $pending']);
    store.calls.clear();
    store.disk.clear();
    await records(2).persistPending(pending, rec(2));
    expect(store.calls, ['write $pending']);
  });

  test('T11: the copy fails at CLAIMED -> the node record is still written, the pending removed, the loss logged',
      () async {
    store.disk[node] = rec(0x11);
    store.disk[pending] = rec(7);
    store.copyFails = true;
    await records(7).claimed(node, rec(0x22), pending);
    expect(store.calls, ['copy $node', 'write $node', 'remove $pending']);
    expect(store.disk[node], rec(0x22));
    expect(logs, ['[OLD_NOT_KEPT] 舊紀錄沒有保留下來（Io(StorageFull)）']);
  });

  test('T12: the copy fails at PersistPending -> no pending is written (and the claim stops: it throws)', () async {
    store.disk[pending] = rec(1);
    store.copyFails = true;
    await expectLater(records(2).persistPending(pending, rec(2)), throwsA('Io(StorageFull)'));
    expect(store.calls, ['copy $pending']);
    expect(store.disk[pending], rec(1), reason: 'the old pending is untouched');
  });

  test('a pending that cannot be opened at PersistPending -> nothing written (R5)', () async {
    store.disk[pending] = rec(1);
    final s = _OpenFails(store);
    await expectLater(ClaimRecords(s, qr(2), logs.add).persistPending(pending, rec(2)), throwsA(isA<PlatformException>()));
    expect(store.calls, isEmpty);
  });
}

class _OpenFails implements ClaimStore {
  _OpenFails(this.s);
  final FakeStore s;
  @override
  Future<SealedRecord?> readSealed(String rel) => s.readSealed(rel);
  @override
  Future<Uint8List> open(SealedRecord x) async => throw PlatformException(code: 'open');
  @override
  Future<bool> matches(Uint8List p, ClaimQr q) => s.matches(p, q);
  @override
  Future<bool> keepCopy(String rel) => s.keepCopy(rel);
  @override
  Future<void> sealWrite(String rel, Uint8List r) => s.sealWrite(rel, r);
  @override
  Future<void> remove(String rel) => s.remove(rel);
}
