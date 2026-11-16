// #329 design §4.4 RecordWriter: the only way to write or delete a key record. It checks that the caller holds the
// registry's current lease token; anything else is refused and nothing is written (fail-closed). The store calls are
// injected so the gate is testable without the Rust bridge; the app wires them to the bridge functions.
import 'lease.dart';

class RecordStore {
  const RecordStore({required this.writeCas, required this.writeSealed, required this.remove, required this.keepCopy});
  final Future<BigInt> Function(String rel, BigInt expectedGen, List<int> sealed) writeCas;
  final Future<void> Function(String rel, BigInt generation, List<int> sealed) writeSealed;
  final Future<void> Function(String rel) remove;
  final Future<bool> Function(String rel) keepCopy;
}

class NoLease implements Exception {
  NoLease(this.what);
  final String what;
  @override
  String toString() => 'RecordWriter: $what refused (no valid lease)';
}

class RecordWriter {
  RecordWriter(this.reg, this.store, {this.log});
  final LeaseRegistry reg;
  final RecordStore store;
  final void Function(String line)? log;

  Lease _check(Lease? l, String what) {
    if (l == null || !l.valid || !identical(reg.current, l)) {
      log?.call('RecordWriter refused $what');
      throw NoLease(what);
    }
    return l;
  }

  void _note(Lease l, String rel) {
    if (rel.startsWith('node/')) l.writtenNodes.add(rel.substring(5));
  }

  Future<BigInt> writeCas(Lease? l, String rel, BigInt expectedGen, List<int> sealed) async {
    final lease = _check(l, 'writeCas $rel');
    final g = await store.writeCas(rel, expectedGen, sealed);
    _note(lease, rel);
    return g;
  }

  Future<void> writeSealed(Lease? l, String rel, BigInt generation, List<int> sealed) async {
    final lease = _check(l, 'writeSealed $rel');
    await store.writeSealed(rel, generation, sealed);
    _note(lease, rel);
  }

  Future<void> remove(Lease? l, String rel) async {
    final lease = _check(l, 'remove $rel');
    await store.remove(rel);
    _note(lease, rel);
  }

  Future<bool> keepCopy(Lease? l, String rel) async {
    _check(l, 'keepCopy $rel');
    return store.keepCopy(rel);
  }
}
