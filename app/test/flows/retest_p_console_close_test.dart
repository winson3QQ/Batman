// #329 補測 A（PR 3 小修正「關閉時取消狀態訂閱」，2026-11-17）: OwnerConsole.close() stops listening to the link's
// state (owner_console.dart _close: `_stateSub?.cancel()`). A link that outlives the console (a fake GateLink whose
// state stream is not closed by close()) must have no listener left once the console is closed.
import 'dart:async';
import 'dart:typed_data';

import 'package:batman_app/src/flows/owner_console.dart';
import 'package:batman_app/src/nodelink/ble_gate.dart';
import 'package:batman_app/src/nodelink/handoff.dart';
import 'package:batman_app/src/nodelink/lease.dart';
import 'package:batman_app/src/nodelink/record_writer.dart';
import 'package:flutter_test/flutter_test.dart';

/// A link whose state stream stays open whatever is done to it.
class StayLink implements GateLink {
  final ctl = StreamController<bool>.broadcast(sync: true);
  @override
  Stream<bool> get state => ctl.stream;
  @override
  Future<void> close() async {}
  @override
  dynamic noSuchMethod(Invocation i) => throw UnimplementedError('${i.memberName}');
}

void main() {
  test('retest-p PR3 取消狀態訂閱: OwnerConsole.close() leaves no listener on the link state', () async {
    final reg = LeaseRegistry(after: (d, f) => () {});
    final lease = reg.acquire('建立網路', LeaseKind.session)!;
    final link = StayLink();
    var lost = 0;
    final c = OwnerConsole(
      LoginHandoff(id: 'Y1', link: link, inbox: FrameInbox()),
      lease,
      RecordWriter(
          reg,
          RecordStore(
              writeCas: (r, g, s) async => g + BigInt.one,
              writeSealed: (r, g, s) async {},
              remove: (r) async {},
              keepCopy: (r) async => true)),
      ConsolePlatform(
        seal: (p, a) async => Uint8List(3),
        signOwner: (i) async => Uint8List(70),
        signAdmin: (i) async => Uint8List(70),
        publicKeys: () async => {},
        readRecord: (rel) async => (BigInt.one, Uint8List(4)),
        makeNetworkRefusal: () async => null,
      ),
      after: (d, f) => () {},
      nowMs: () => 0,
      askCountry: (_) async => false,
      askRemoved: (_) async => false,
      onLost: () => lost++,
    );
    expect(link.ctl.hasListener, isTrue, reason: 'the console listens while it is open');
    link.ctl.add(false);
    expect(lost, 1, reason: 'a drop while open is the console\'s onLost');
    await c.close();
    expect(lost, 2, reason: 'close tells it once');
    expect(link.ctl.hasListener, isFalse, reason: 'closed: no subscription left on the link');
    await lease.release();
  });
}
