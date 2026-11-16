// #329 §4.4 / §9.1 T-G*, T-K*: the lease registry and RecordWriter, with a manual clock.
import 'dart:async';

import 'package:batman_app/src/nodelink/lease.dart';
import 'package:batman_app/src/nodelink/record_writer.dart';
import 'package:flutter_test/flutter_test.dart';

class Clock {
  final List<(Duration, void Function(), List<bool>)> pending = [];
  Duration t = Duration.zero;
  Cancel after(Duration d, void Function() f) {
    final cancelled = [false];
    pending.add((t + d, f, cancelled));
    return () => cancelled[0] = true;
  }

  void advance(Duration d) {
    t += d;
    for (final p in [...pending]) {
      if (p.$1 <= t && !p.$3[0]) {
        p.$3[0] = true;
        p.$2();
      }
    }
  }
}

class Spy implements LeaseListener {
  final List<String> events = [];
  @override
  void revoked(Token t) => events.add('revoked ${t.owner}');
  @override
  void released(Lease l, {required bool revoked}) =>
      events.add('released ${l.name}${revoked ? ' (revoked)' : ''} nodes=${l.writtenNodes.toList()..sort()}');
}

(LeaseRegistry, Clock, Spy, RecordWriter, List<String>) setup() {
  final clock = Clock();
  final reg = LeaseRegistry(after: clock.after);
  final spy = Spy();
  reg.listeners.add(spy);
  final disk = <String>[];
  final store = RecordStore(
    writeCas: (rel, g, s) async {
      disk.add('cas $rel');
      return g + BigInt.one;
    },
    writeSealed: (rel, g, s) async => disk.add('sealed $rel'),
    remove: (rel) async => disk.add('rm $rel'),
    keepCopy: (rel) async {
      disk.add('keep $rel');
      return true;
    },
  );
  return (reg, clock, spy, RecordWriter(reg, store), disk);
}

void main() {
  test('one lease at a time: a second acquire is refused and names the holder', () {
    final (reg, _, _, _, _) = setup();
    final a = reg.acquire('建立網路', LeaseKind.session);
    expect(a, isNotNull);
    expect(reg.acquire('新增節點', LeaseKind.raw), isNull);
    expect(reg.current!.name, '建立網路');
  });

  test('T-K: RecordWriter refuses without a valid lease and writes nothing', () async {
    final (reg, _, _, w, disk) = setup();
    await expectLater(w.writeCas(null, 'node/Y1', BigInt.zero, [1]), throwsA(isA<NoLease>()));
    final l = reg.acquire('x', LeaseKind.session)!;
    await w.writeCas(l, 'node/Y1', BigInt.zero, [1]);
    await l.release();
    await expectLater(w.remove(l, 'node/Y1'), throwsA(isA<NoLease>()));
    expect(disk, ['cas node/Y1']);
  });

  test('writes under a lease are reported on release (node ids only)', () async {
    final (reg, _, spy, w, _) = setup();
    final l = reg.acquire('移除', LeaseKind.session)!;
    await w.writeSealed(l, 'node/Y1', BigInt.one, [1]);
    await w.writeCas(l, 'net/abc', BigInt.zero, [1]);
    await w.remove(l, 'node/Y2');
    await l.release();
    expect(spy.events, ['released 移除 nodes=[Y1, Y2]']);
  });

  test('the token changes on every acquire and release; an old token is never valid again', () async {
    final (reg, _, _, _, _) = setup();
    final t0 = reg.token;
    final l = reg.acquire('x', LeaseKind.raw)!;
    expect(reg.valid(t0), isFalse);
    expect(reg.valid(l.token), isTrue);
    await l.release();
    expect(reg.valid(l.token), isFalse);
    expect(reg.valid(t0), isFalse);
    expect(reg.token.owner, 'NodeLink');
  });

  test('pageGone while idle releases at once', () {
    final (reg, _, spy, _, _) = setup();
    reg.acquire('設定', LeaseKind.session)!.pageGone();
    expect(reg.current, isNull);
    expect(spy.events, ['released 設定 nodes=[]']);
  });

  test('X19: pageGone while busy keeps the lease until the work ends, then releases', () async {
    final (reg, clock, spy, w, disk) = setup();
    final l = reg.acquire('加入', LeaseKind.session)!;
    final c = Completer<void>();
    final work = l.run(() async {
      await c.future;
      await w.writeCas(l, 'mnet/n1', BigInt.zero, [1]);
    });
    l.pageGone();
    expect(reg.current, same(l));
    clock.advance(const Duration(seconds: 100));
    c.complete();
    await work;
    expect(disk, ['cas mnet/n1']);
    expect(reg.current, isNull);
    expect(spy.events.single, startsWith('released 加入'));
  });

  test('420 s after pageGone a busy lease is revoked: token invalid, later writes refused, a todo is shown', () async {
    final (reg, clock, spy, w, disk) = setup();
    final l = reg.acquire('建立網路', LeaseKind.session)!;
    final c = Completer<void>();
    final work = l.run(() async {
      await c.future;
      await w.writeCas(l, 'net/n1', BigInt.zero, [1]);
    });
    l.pageGone();
    clock.advance(const Duration(seconds: 419));
    expect(reg.current, same(l));
    clock.advance(const Duration(seconds: 1));
    expect(reg.current, isNull);
    expect(spy.events, ['revoked 建立網路', 'released 建立網路 (revoked) nodes=[]']);
    expect(reg.unsavedTodos, ['上一個操作可能沒有存完：建立網路']);
    c.complete();
    await expectLater(work, throwsA(isA<NoLease>()));
    expect(disk, isEmpty);
    expect(spy.events.length, 2, reason: 'no second release when the revoked work ends');
  });

  test('run() on a released lease is refused', () async {
    final (reg, _, _, _, _) = setup();
    final l = reg.acquire('x', LeaseKind.raw)!;
    await l.release();
    expect(() => l.run(() async {}), throwsStateError);
  });
}
