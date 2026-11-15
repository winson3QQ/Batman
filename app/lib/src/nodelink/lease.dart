// #329 design §4.4: one operation at a time may use Bluetooth and write key records. The registry is the single
// owner of "who may use BleGate now" (§4.1): NodeLink itself when no lease is held, the lease holder otherwise.
// Time is injected (now / after) so the 420 s / 900 s caps are testable without timers.

import 'package:flutter/foundation.dart' show visibleForTesting;

/// A credential for BleGate and RecordWriter. Only the registry's current token is valid.
class Token {
  Token._(this.id, this.owner);
  final int id;
  final String owner;
  @override
  String toString() => 'token#$id($owner)';
}

enum LeaseKind { session, raw }

typedef Cancel = void Function();
typedef After = Cancel Function(Duration d, void Function() f);

/// What the registry tells the rest of the app (BleGate closes a revoked token's links; NodeLink reads the records
/// again and starts a round 6 s later; the home page shows a todo after a revocation).
abstract class LeaseListener {
  void revoked(Token t);
  void released(Lease l, {required bool revoked});
}

class Lease {
  Lease._(this.reg, this.token, this.name, this.kind);
  final LeaseRegistry reg;
  final Token token;
  final String name;
  final LeaseKind kind;
  int _busy = 0;
  bool _gone = false;
  bool _ended = false;
  Cancel? _deadline;

  /// Node records (`node/<id>`) written or deleted under this lease (§4.3.3-5: their memos go on release).
  final Set<String> writtenNodes = {};

  bool get busy => _busy > 0;
  bool get valid => !_ended && reg.valid(token);

  /// Work that uses Bluetooth or writes records: while one runs the lease is 「進行中」 (§4.4).
  Future<T> run<T>(Future<T> Function() work) async {
    if (!valid) throw StateError('lease $name is no longer valid');
    _busy++;
    try {
      return await work();
    } finally {
      _busy--;
      if (_busy == 0 && _gone && !_ended) await release();
    }
  }

  /// An older page's work (§4.4 原始佔用的頁面, review pr1 A-M1 / B-M1): the lease is 「進行中」 from now until the returned
  /// function is called (once; later calls do nothing), so a page that is popped while its claim or login still runs
  /// keeps the lease until that work ends, at most [LeaseRegistry.rawGoneMax] (900 s) after the pop. Throws when the lease is no longer valid.
  Cancel hold() {
    if (!valid) throw StateError('lease $name is no longer valid');
    _busy++;
    var done = false;
    return () {
      if (done) return;
      done = true;
      _busy--;
      if (_busy == 0 && _gone && !_ended) release();
    };
  }

  /// The page's dispose: idle -> release at once; busy -> release when the work ends, at most 420 s from now (a raw lease: 900 s).
  void pageGone() {
    if (_ended || _gone) return;
    _gone = true;
    if (_busy == 0) {
      release();
      return;
    }
    _deadline = reg.after(kind == LeaseKind.raw ? LeaseRegistry.rawGoneMax : LeaseRegistry.goneMax, () {
      if (!_ended) reg._revoke(this);
    });
  }

  Future<void> release() async {
    if (_ended) return;
    _ended = true;
    _deadline?.call();
    reg._release(this, revoked: false);
  }
}

class LeaseRegistry {
  LeaseRegistry({required this.after});
  final After after;
  static const goneMax = Duration(seconds: 420);

  /// An older page (raw lease) does not use the gate, so taking its lease back cannot stop its work; it only lets
  /// NodeLink in while the page may still scan and connect (r4 H-M1). Its cap is longer than its longest busy work
  /// (a claim with a recovery: about 485 s by its own timeouts; 我的節點's join wait 360 s) and only guards a page
  /// whose platform call never returns.
  static const rawGoneMax = Duration(seconds: 900);

  int _ids = 0;
  late Token _current = Token._(_ids++, 'NodeLink');
  Lease? _lease;
  final List<LeaseListener> listeners = [];

  /// Todo items for the home page (§5.1): 「上一個操作可能沒有存完：<名稱>」. Memory only; the page clears them.
  final List<String> unsavedTodos = [];

  Lease? get current => _lease;
  /// Tests only: during a lease this is the holder's credential (review pr1 r5 J-m5); the app uses [nodeLinkToken] and
  /// each lease's own token.
  @visibleForTesting
  Token get token => _current;

  /// NodeLink's own credential: the current token only while no lease is held (§4.1; review pr1 A-M5 / B-M2). A
  /// lease holder's token is never handed to NodeLink, so the gate refuses NodeLink while a lease is held.
  Token? get nodeLinkToken => _lease == null ? _current : null;
  bool valid(Token t) => identical(t, _current);

  /// A second request is refused (null): the caller shows 「另一個操作還在進行：<名稱>」 with [current]'s name.
  Lease? acquire(String name, LeaseKind kind) {
    if (_lease != null) return null;
    final t = Token._(_ids++, name);
    _current = t;
    return _lease = Lease._(this, t, name, kind);
  }

  void _release(Lease l, {required bool revoked}) {
    if (!identical(_lease, l)) return;
    _lease = null;
    _current = Token._(_ids++, 'NodeLink');
    for (final x in listeners) {
      x.released(l, revoked: revoked);
    }
  }

  void _revoke(Lease l) {
    if (!identical(_lease, l)) return;
    l._ended = true;
    final t = l.token;
    unsavedTodos.add('上一個操作可能沒有存完：${l.name}');
    for (final x in listeners) {
      x.revoked(t);
    }
    _release(l, revoked: true);
  }
}
