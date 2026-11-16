// #329 PR 3 §2.6 (design §4.3.8): NetIndex — the phone's network records for the screens. Fake source (folders,
// Keystore open, Rust summary) except the listKind test, which uses a real temporary folder.
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:batman_app/src/flows/net_index.dart';
import 'package:batman_app/src/nodelink/lease.dart';
import 'package:batman_app/src/rust/api/owner.dart';
import 'package:batman_app/ui/home_logic.dart' show NetRecords;
import 'package:flutter_test/flutter_test.dart';

MemberView member(String name, {String deviceId = '', bool joining = false, bool creator = false, bool approved = false}) =>
    MemberView(
        name: name,
        last4: deviceId.length > 4 ? deviceId.substring(deviceId.length - 4) : '',
        deviceId: deviceId,
        joining: joining,
        prevCountry: '',
        dacHash: '',
        creator: creator,
        approved: approved);

NetView net(String id, {bool applied = true, List<MemberView> members = const []}) =>
    NetView(netId: id, meshId: 'bm-$id', netName: 'Team $id', applied: applied, country: 'US', members: members);

class Src {
  final Map<String, List<String>> dirs = {'net': [], 'mnet': [], 'mpend': []};
  final Map<String, NetView> views = {}; // net id -> its summary; missing = does not open
  final Set<String> listFails = {};
  List<String> nodes = [];
  final files = <String>[]; // every record touched for writing (none, ever)
  Completer<void>? slow;

  NetSource get source => NetSource(
        list: (k) async {
          final v = List.of(dirs[k]!); // what the folder holds when it is listed
          final w = slow;
          if (k == 'net') slow = null; // one slow computation only
          if (w != null) await w.future;
          if (listFails.contains(k)) throw const FileSystemException('denied');
          return v;
        },
        open: (rel) async {
          final id = rel.substring(4);
          if (!views.containsKey(id)) throw Exception('keystore');
          return Uint8List.fromList(id.codeUnits);
        },
        summary: (p) => views[String.fromCharCodes(p)]!,
        nodeIds: () async => nodes,
      );
}

void main() {
  test('before the first computation it is computing: the neutral 加入網路 (PR 2 D-m9)', () {
    final i = NetIndex(Src().source);
    expect((i.now.computing, i.now.records), (true, NetRecords.unknown));
  });

  group('T-N2: home row 6\'s records (net > mnet > mpend > none), unchanged from PR 2', () {
    for (final (nets, mnet, mpend, want) in [
      (['a'], ['b'], ['c'], NetRecords.net),
      (<String>[], ['b'], ['c'], NetRecords.mnet),
      (<String>[], <String>[], ['c'], NetRecords.mpend),
      (<String>[], <String>[], <String>[], NetRecords.none),
    ]) {
      test('net $nets mnet $mnet mpend $mpend -> ${want.name}', () async {
        final s = Src()
          ..dirs['net'] = nets
          ..dirs['mnet'] = mnet
          ..dirs['mpend'] = mpend;
        for (final id in nets) {
          s.views[id] = net(id);
        }
        final i = NetIndex(s.source);
        await i.recompute();
        expect(i.now.records, want);
      });
    }
  });

  test('review v14 AA-m6: only a pending net -> row 6 is still 加入網路 (any net file), and no applied net', () async {
    final s = Src()..dirs['net'] = ['p'];
    s.views['p'] = net('p', applied: false);
    final i = NetIndex(s.source);
    await i.recompute();
    expect((i.now.records, i.now.anyApplied), (NetRecords.net, false));
  });

  test('a folder that cannot be listed -> listFailed (讀不到), never 「沒有」', () async {
    final s = Src()..listFails.add('mnet');
    final i = NetIndex(s.source);
    await i.recompute();
    expect((i.now.listFailed, i.now.records), (true, NetRecords.unknown));
  });

  test('T-L19: a record that does not open is left out, the others stay; one log line with 8 characters of its id; nothing written',
      () async {
    const bad = 'cafebabe0123456789abcdef0123456789abcdef0123456789abcdef01234567';
    final s = Src()..dirs['net'] = ['a1', bad, 'c3'];
    s.views['a1'] = net('a1');
    s.views['c3'] = net('c3');
    final lines = <String>[];
    final i = NetIndex(s.source, log: lines.add);
    await i.recompute();
    expect(i.now.nets.map((n) => n.id), ['a1', 'c3']);
    expect(i.now.netFiles, 3, reason: 'row 6 still counts it');
    expect(lines, hasLength(1));
    expect(lines.single, contains('cafebabe'));
    expect(lines.single, isNot(contains(bad)), reason: 'never the whole id');
    expect(s.files, isEmpty);
  });

  test('net files but none opens -> noneOpens (join2 T8)', () async {
    final s = Src()..dirs['net'] = ['x', 'y'];
    final i = NetIndex(s.source);
    await i.recompute();
    expect((i.now.noneOpens, i.now.records), (true, NetRecords.net));
  });

  test('「節點加入網路沒有做完」: a joining member that is this phone\'s node; never the pending creator, never another\'s node',
      () async {
    final s = Src()
      ..dirs['net'] = ['p', 'q']
      ..nodes = ['dev04', 'dev02'];
    s.views['p'] = net('p', applied: false, members: [
      member('node-0004', joining: true, creator: true), // the pending creator: Joining too (netrec.rs:395), no device id
    ]);
    s.views['q'] = net('q', members: [
      member('node-0002', deviceId: 'dev02', joining: true),
      member('node-9999', deviceId: 'dev99', joining: true), // not this phone's
      member('node-0004', deviceId: 'dev04'), // applied
    ]);
    final i = NetIndex(s.source);
    await i.recompute();
    expect(i.now.todos.map((t) => (t.net.id, t.deviceId)), [('q', 'dev02')]);
  });

  test('review v15 AD-M1: the creator is excluded even when its entry carries a device id', () async {
    final s = Src()
      ..dirs['net'] = ['p']
      ..nodes = ['dev04'];
    s.views['p'] = net('p', applied: false, members: [member('node-0004', deviceId: 'dev04', joining: true, creator: true)]);
    final i = NetIndex(s.source);
    await i.recompute();
    expect(i.now.todos, isEmpty);
  });

  test('only the newest computation is kept; listeners hear the start and the end', () async {
    final s = Src()..dirs['net'] = ['a'];
    s.views['a'] = net('a');
    final i = NetIndex(s.source);
    var heard = 0;
    i.addListener(() => heard++);
    await i.recompute();
    expect((i.now.computing, heard), (false, 1), reason: 'already computing at the start: only the end');
    final gate = s.slow = Completer<void>();
    final first = i.recompute(); // lists [a], then waits
    expect(i.now.computing, isTrue);
    s.dirs['net'] = ['a', 'b'];
    s.views['b'] = net('b');
    await i.recompute(); // lists [a, b] and ends first
    expect(i.now.nets.map((n) => n.id), ['a', 'b']);
    gate.complete(); // the older one ends last: it must not win
    await first;
    expect(i.now.nets.map((n) => n.id), ['a', 'b']);
    expect(i.now.computing, isFalse);
  });

  test('a lease release computes again', () async {
    final s = Src();
    final i = NetIndex(s.source);
    await i.recompute();
    s.dirs['net'] = ['a'];
    s.views['a'] = net('a');
    final reg = LeaseRegistry(after: (d, f) => () {});
    reg.listeners.add(i);
    await reg.acquire('建立網路', LeaseKind.session)!.release();
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);
    expect(i.now.records, NetRecords.net);
  });

  test('listKind: list_kind\'s rules — dot names skipped, a missing folder is empty, sorted', () async {
    final d = Directory.systemTemp.createTempSync('bm-lk');
    expect(await listKind(d.path, 'net'), isEmpty, reason: 'no folder = empty');
    for (final n in ['b2', 'a1', '.tmp-a1']) {
      File('${d.path}/net/$n').createSync(recursive: true);
    }
    expect(await listKind(d.path, 'net'), ['a1', 'b2']);
    d.deleteSync(recursive: true);
  });
}
