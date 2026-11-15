// #329 design §4.6 `ui/state-v1`: every row of the contract (T-U*). A map-backed store stands in for the record store.
import 'dart:typed_data';

import 'package:batman_app/ui/cbor_mini.dart';
import 'package:batman_app/ui/ui_state.dart';
import 'package:flutter_test/flutter_test.dart';

class MemStore implements UiStore {
  int gen = 0;
  Uint8List? plain; // what is stored (null with gen > 0 = a record that does not open)
  bool header = false; // NotARecord / UnknownVersion
  bool failWrite = false;
  int writes = 0, removes = 0;
  List<String> ids = [];

  @override
  Future<(int, Uint8List?)?> read() async {
    if (header) throw UiHeaderBad();
    return gen == 0 ? null : (gen, plain);
  }

  @override
  Future<int> write(int expectedGen, Uint8List p) async {
    if (header) throw UiHeaderBad();
    if (failWrite) throw StateError('Keystore');
    if (expectedGen != gen) throw StateError('stale');
    writes++;
    plain = p;
    return ++gen;
  }

  @override
  Future<void> remove() async {
    removes++;
    header = false;
    gen = 0;
    plain = null;
  }

  @override
  Future<List<String>> nodeIds() async => ids;
}

Future<UiState> loaded(MemStore s) async {
  final u = UiState(s);
  await u.load();
  return u;
}

void main() {
  test('cbor: round trip, strict about everything outside the subset', () {
    final v = <Object, Object>{1: 1, 2: true, 4: <Object, Object>{'abc': <Object, Object>{1: '小隊一', 4: 1763200000}}};
    expect(cborDecode(cborEncode(v)), v);
    expect(() => cborDecode(Uint8List.fromList([0x81, 0x01])), throwsFormatException, reason: 'an array');
    expect(() => cborDecode(Uint8List.fromList([0x01, 0x01])), throwsFormatException, reason: 'trailing bytes');
    expect(() => cborDecode(Uint8List.fromList([0x63, 0x61])), throwsFormatException, reason: 'truncated');
    expect(() => cborDecode(Uint8List.fromList([0x20])), throwsFormatException, reason: 'a negative int');
    expect(() => cborDecode(Uint8List.fromList([0xa2, 0x01, 0x01, 0x01, 0x02])), throwsFormatException, reason: 'dup key');
  });

  test('absent: defaults', () async {
    final u = await loaded(MemStore());
    expect((u.welcomed, u.homeTip), (false, false));
    expect(u.nodes, isEmpty);
  });

  test('flags and nodes survive a write and a new load; a write replaces the whole record (CAS, +1)', () async {
    final s = MemStore()..ids = ['n1'];
    final u = await loaded(s);
    await u.setWelcomed();
    await u.noteReads({'n1': ('ok', DateTime.utc(2026, 11, 15, 5))});
    expect((s.gen, s.writes), (2, 2));
    final v = await loaded(s);
    expect((v.welcomed, v.nodes['n1']!.look, v.nodes['n1']!.readAt), (true, 'ok', DateTime.utc(2026, 11, 15, 5).millisecondsSinceEpoch ~/ 1000));
  });

  test('a round writes only when a kind changed; the background writes once when a read time is newer', () async {
    final s = MemStore()..ids = ['n1'];
    final u = await loaded(s);
    await u.noteReads({'n1': ('ok', DateTime.utc(2026, 1, 1, 0, 0))});
    await u.noteReads({'n1': ('ok', DateTime.utc(2026, 1, 1, 0, 1))});
    expect(s.writes, 1, reason: 'same kind: no write');
    await u.background();
    expect(s.writes, 2, reason: 'newer read time: one write');
    await u.background();
    expect(s.writes, 2, reason: 'nothing newer');
    await u.noteReads({'n1': ('bad', DateTime.utc(2026, 1, 1, 0, 2))});
    expect(s.writes, 3);
  });

  test('a node without a record is dropped on load; forget removes it and writes', () async {
    final s = MemStore()..ids = ['n1', 'n2'];
    final u = await loaded(s);
    await u.noteReads({'n1': ('ok', DateTime.utc(2026)), 'n2': ('warn', DateTime.utc(2026))});
    s.ids = ['n2'];
    final v = await loaded(s);
    expect(v.nodes.keys, ['n2']);
    await v.forget('n2');
    expect((await loaded(s)).nodes, isEmpty);
  });

  test('header bad (F39): absent; the next write removes the file first', () async {
    final s = MemStore()..header = true;
    final u = await loaded(s);
    expect(u.welcomed, isFalse);
    await u.setWelcomed();
    expect((s.removes, s.gen, (await loaded(s)).welcomed), (1, 1, true));
  });

  for (final (what, body) in [
    ('does not open', null),
    ('not CBOR', Uint8List.fromList([0xff])),
    ('version 2', cborEncode(<Object, Object>{1: 2, 2: true})),
    ('a field outside the list', cborEncode(<Object, Object>{1: 1, 2: true, 5: 'x'})),
    ('a node field outside the list', cborEncode(<Object, Object>{1: 1, 4: <Object, Object>{'n1': <Object, Object>{3: 'sentence'}}})),
    ('a nickname over 24', cborEncode(<Object, Object>{1: 1, 4: <Object, Object>{'n1': <Object, Object>{1: 'x' * 25}}})),
    ('an unknown kind', cborEncode(<Object, Object>{1: 1, 4: <Object, Object>{'n1': <Object, Object>{2: 'red'}}})),
  ]) {
    test('body $what: absent; the next write overwrites it by CAS at the read generation', () async {
      final s = MemStore()
        ..gen = 7
        ..plain = body
        ..ids = ['n1'];
      final u = await loaded(s);
      expect(u.welcomed, isFalse);
      expect(u.nodes, isEmpty);
      await u.setHomeTip();
      expect(s.gen, 8);
      expect((await loaded(s)).homeTip, isTrue);
    });
  }

  test('a write that fails: not shown, the generation is read again before the next write', () async {
    final s = MemStore();
    final u = await loaded(s);
    s.failWrite = true;
    await u.setWelcomed();
    expect(s.writes, 0);
    s
      ..failWrite = false
      ..gen = 3; // something else moved it meanwhile
    await u.setHomeTip();
    expect((s.gen, (await loaded(s)).welcomed), (4, true));
  });

  test('T-U6: only the listed fields are written; no sentence, address or secret', () async {
    final s = MemStore()..ids = ['n1'];
    final u = await loaded(s);
    await u.setWelcomed();
    await u.noteReads({'n1': ('warn', DateTime.utc(2026))});
    final m = cborDecode(s.plain!) as Map<Object, Object>;
    expect(m.keys.toSet(), {1, 2, 4});
    final n = (m[4]! as Map<Object, Object>)['n1']! as Map<Object, Object>;
    expect(n.keys.toSet(), {2, 4});
    await u.noteReads({'n1': ('not-a-kind', DateTime.utc(2027))});
    expect(u.nodes['n1']!.look, 'warn', reason: 'only the four kinds are kept');
  });

  // ---- PR 2 review B-m1 / B-m9 ----------------------------------------------------------------------------------

  for (final (what, body) in [
    ('a read time beyond 2100', cborEncode(<Object, Object>{1: 1, 4: <Object, Object>{'n1': <Object, Object>{4: 9000000000000}}})),
    ('a nickname with a direction mark', cborEncode(<Object, Object>{1: 1, 4: <Object, Object>{'n1': <Object, Object>{1: 'a${String.fromCharCode(0x202e)}b'}}})),
    ('a nickname with a control character', cborEncode(<Object, Object>{1: 1, 4: <Object, Object>{'n1': <Object, Object>{1: 'a${String.fromCharCode(7)}b'}}})),
  ]) {
    test('B-m1: $what is not taken (absent)', () async {
      final s = MemStore()
        ..gen = 1
        ..plain = body
        ..ids = ['n1'];
      expect((await loaded(s)).nodes, isEmpty);
    });
  }

  test('B-m9: writes asked together run one after the other and the record ends with all of them', () async {
    final s = MemStore()..ids = ['n1'];
    final u = await loaded(s);
    await Future.wait([u.setWelcomed(), u.setHomeTip(), u.noteReads({'n1': ('ok', DateTime.utc(2026))})]);
    final v = await loaded(s);
    expect((v.welcomed, v.homeTip, v.nodes['n1']?.look), (true, true, 'ok'));
    expect(s.writes, 3, reason: 'no write lost to a CAS clash');
  });

  test('cbor: nesting deeper than 4 is refused', () {
    Object deep = 1;
    for (var i = 0; i < 6; i++) {
      deep = <Object, Object>{1: deep};
    }
    expect(() => cborDecode(cborEncode(deep)), throwsFormatException);
  });
}
