// #329 design §4.6 `ui/state-v1`: what the screens remember between runs — the welcome / home-tip flags and, per node,
// a nickname and the last status kind with its read time. Display only: nothing decides anything from it, so every
// read problem is "absent" (fail-open) and every write problem is logged and retried at the next write. UiState is the
// only writer of `ui/state-v1` and writes nothing else; it needs no lease (it is not a key record).
import 'package:flutter/services.dart';

import '../src/rust/api/claim.dart' show storeRemove, storeSealParams;
import '../src/rust/api/owner.dart' show listNodes, storeReadSealed, storeWriteCas;
import 'cbor_mini.dart';

const uiRel = 'ui/state-v1';
const nickMax = 24;
const lookKinds = {'ok', 'warn', 'bad', 'unk'};
final _unsafe = RegExp('[${_c(0)}-${_c(0x1f)}${_c(0x7f)}-${_c(0x9f)}${_c(0xad)}${_c(0x61c)}${_c(0x180e)}${_c(0x200b)}-${_c(0x200f)}${_c(0x2028)}-${_c(0x202e)}${_c(0x2060)}-${_c(0x206f)}${_c(0xfeff)}${_c(0xfff9)}-${_c(0xfffb)}]'); // Cc, Cf, Zl, Zp (review r2 D-m1)
String _c(int code) => String.fromCharCode(code); // control and text-direction characters, by code point

/// One node's display memory.
class UiNode {
  const UiNode({this.nick, this.look, this.readAt});
  final String? nick; // ≤ 24 characters
  final String? look; // ok / warn / bad / unk
  final int? readAt; // UTC seconds

  UiNode copy({String? nick, String? look, int? readAt, bool clearNick = false}) =>
      UiNode(nick: clearNick ? null : (nick ?? this.nick), look: look ?? this.look, readAt: readAt ?? this.readAt);
}

/// The record header could not be read (NotARecord / UnknownVersion): a write must remove the file first (F39).
class UiHeaderBad implements Exception {}

/// The record file. The app's is [RecordUiStore]; tests use a map.
abstract class UiStore {
  /// null = no record; (generation, null) = a record that does not open; throws [UiHeaderBad].
  Future<(int, Uint8List?)?> read();

  /// Replace the record when it is at [expectedGen] (0 = none); returns the new generation.
  Future<int> write(int expectedGen, Uint8List plain);
  Future<void> remove();
  Future<List<String>> nodeIds();
}

class UiState {
  UiState(this.store, {this.log});
  final UiStore store;
  final void Function(String line)? log;

  bool welcomed = false;
  bool homeTip = false;
  final Map<String, UiNode> nodes = {};

  int _gen = 0;
  bool _headerBad = false;
  bool _reread = false;
  final Map<String, int> _savedReadAt = {};

  /// Defaults on any problem; nodes without a record are dropped.
  Future<void> load() async {
    try {
      final r = await store.read();
      if (r != null) {
        _gen = r.$1;
        final plain = r.$2;
        if (plain != null) _parse(plain);
      }
    } on UiHeaderBad {
      _headerBad = true;
      log?.call('ui/state-v1: not a record or unknown version, taken as absent');
    } catch (e) {
      log?.call('ui/state-v1: unreadable ($e), taken as absent');
      _reread = true;
    }
    try {
      final ids = (await store.nodeIds()).toSet();
      nodes.removeWhere((id, _) => !ids.contains(id));
    } catch (_) {}
    for (final e in nodes.entries) {
      final t = e.value.readAt;
      if (t != null) _savedReadAt[e.key] = t;
    }
  }

  void _parse(Uint8List plain) {
    final Object v;
    try {
      v = cborDecode(plain);
      if (v is! Map<Object, Object> || v.keys.any((k) => k is! int || k < 1 || k > 4) || v[1] != 1) {
        throw const FormatException('not version 1 or a field outside the list');
      }
      final w = v[2] ?? false, h = v[3] ?? false, t = v[4] ?? const <Object, Object>{};
      if (w is! bool || h is! bool || t is! Map<Object, Object>) throw const FormatException('field type');
      final parsed = <String, UiNode>{};
      t.forEach((id, n) {
        if (id is! String || n is! Map<Object, Object>) throw const FormatException('node table');
        if (n.keys.any((k) => k != 1 && k != 2 && k != 4)) throw const FormatException('node field outside the list');
        final nick = n[1], look = n[2], at = n[4];
        if (nick != null && (nick is! String || nick.runes.length > nickMax || _unsafe.hasMatch(nick))) {
          throw const FormatException('nickname'); // control or direction characters never reach the screen (B-m1)
        }
        if (look != null && (look is! String || !lookKinds.contains(look))) throw const FormatException('kind');
        // a time the screen can show (1970 .. 2100) — a value out of range would throw where it is drawn (review B-m1)
        if (at != null && (at is! int || at < 0 || at > 4102444800)) throw const FormatException('time');
        parsed[id] = UiNode(nick: nick as String?, look: look as String?, readAt: at as int?);
      });
      welcomed = w;
      homeTip = h;
      nodes
        ..clear()
        ..addAll(parsed);
    } on FormatException catch (e) {
      log?.call('ui/state-v1: body not usable ($e), taken as absent; the next write overwrites it');
    }
  }

  Uint8List encode() => cborEncode(<Object, Object>{
        1: 1,
        if (welcomed) 2: true,
        if (homeTip) 3: true,
        4: <Object, Object>{
          for (final e in nodes.entries)
            e.key: <Object, Object>{
              if (e.value.nick != null) 1: e.value.nick!,
              if (e.value.look != null) 2: e.value.look!,
              if (e.value.readAt != null) 4: e.value.readAt!,
            },
        },
      });

  Future<void>? _saving;

  /// One write at a time (review B-m9): a write asked while one runs waits for it, then writes the latest state.
  Future<void> _save() {
    final prev = _saving;
    final next = (prev ?? Future<void>.value()).then((_) => _saveNow());
    _saving = next;
    return next.whenComplete(() {
      if (identical(_saving, next)) _saving = null;
    });
  }

  Future<void> _saveNow() async {
    try {
      if (_headerBad) {
        await store.remove();
        _headerBad = false;
        _gen = 0;
      }
      if (_reread) {
        final r = await store.read();
        _gen = r?.$1 ?? 0;
        _reread = false;
      }
      _gen = await store.write(_gen, encode());
      _savedReadAt
        ..clear()
        ..addAll({for (final e in nodes.entries) if (e.value.readAt != null) e.key: e.value.readAt!});
    } on UiHeaderBad {
      _headerBad = true;
      log?.call('ui/state-v1: write refused (header), removed next time');
    } catch (e) {
      _reread = true; // a CAS that did not match, Keystore, the disk: not shown, tried again at the next write
      log?.call('ui/state-v1: not written ($e)');
    }
  }

  Future<void> setWelcomed() async {
    if (welcomed) return;
    welcomed = true;
    await _save();
  }

  Future<void> setHomeTip() async {
    if (homeTip) return;
    homeTip = true;
    await _save();
  }

  /// A round's reads: the time is kept in memory; the record is written only when a node's kind changed.
  Future<void> noteReads(Map<String, (String, DateTime)> reads) async {
    var changed = false;
    reads.forEach((id, r) {
      final (look, at) = r;
      if (!lookKinds.contains(look)) return;
      final old = nodes[id];
      if (old?.look != look) changed = true;
      nodes[id] = (old ?? const UiNode()).copy(look: look, readAt: at.toUtc().millisecondsSinceEpoch ~/ 1000);
    });
    if (changed) await _save();
  }

  /// Entering the background: write once when a read time is newer than the record's.
  Future<void> background() async {
    final newer = nodes.entries.any((e) => e.value.readAt != null && e.value.readAt! > (_savedReadAt[e.key] ?? -1));
    if (newer) await _save();
  }

  /// 「從這支手機移除這台節點」: its nickname and status go too.
  Future<void> forget(String id) async {
    if (nodes.remove(id) != null) await _save();
  }
}

/// The app's store: `ui/state-v1` in the record store, sealed with the record key (Keystore).
class RecordUiStore implements UiStore {
  RecordUiStore(this.dir, this.platform);
  final String dir;
  final MethodChannel platform;

  static bool _header(Object e) => '$e'.contains('NotARecord') || '$e'.contains('UnknownVersion');

  @override
  Future<(int, Uint8List?)?> read() async {
    final r = await storeReadSealed(dir: dir, rel: uiRel).catchError((Object e) => throw (_header(e) ? UiHeaderBad() : e));
    if (r == null) return null;
    Uint8List? plain;
    try {
      plain = await platform.invokeMethod<Uint8List>('open', {'sealed': r.sealed, 'aad': r.aad});
    } catch (_) {
      plain = null; // does not open (a new install's key): absent, overwritten by CAS at this generation
    }
    return (r.generation.toInt(), plain);
  }

  @override
  Future<int> write(int expectedGen, Uint8List plain) async {
    final p = await storeSealParams(dir: dir, rel: uiRel).catchError((Object e) => throw (_header(e) ? UiHeaderBad() : e));
    if (p.generation.toInt() != expectedGen + 1) throw StateError('ui/state-v1 changed on disk');
    final sealed = (await platform.invokeMethod<Uint8List>('seal', {'plain': plain, 'aad': p.aad}))!;
    return (await storeWriteCas(dir: dir, rel: uiRel, expectedGen: BigInt.from(expectedGen), sealed: sealed)).toInt();
  }

  @override
  Future<void> remove() => storeRemove(dir: dir, rel: uiRel);

  @override
  Future<List<String>> nodeIds() => listNodes(dir: dir);
}
