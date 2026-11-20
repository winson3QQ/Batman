// #329 design §4.2 BleGate: the app's only Bluetooth entry. One scan at most, and one link in use at most (links
// NodeLink keeps parked may stay open beside it: 329-link-per-node.md §3.1), each only for the
// registry's current token; a revoked token's scan and link are closed here (not by their holder); at most 4 scan
// starts in any 30 s (A10: the 6th within ~15 s is refused by Android, M-1 E); "disconnected" = the connection state
// stream says so, or 5 s. The radio sits behind BleBackend so the gate is testable without a phone.
import 'dart:async';
import 'dart:typed_data';

import 'lease.dart';

/// What the gate needs from the BLE library (the app wires FlutterReactiveBle to it).
abstract class BleBackend {
  /// Scan for the provd service; every advertisement as (address, its Manufacturer Data as the plugin gives it:
  /// company id little-endian, then the data; null when it has none). #329 rotating identifier §3.3.
  Stream<(String, Uint8List?)> scan();

  /// Connect; emits true when connected, false when disconnected (then completes or errors). Cancelling the
  /// subscription disconnects; after that this stream says nothing more.
  Stream<bool> connect(String address, Duration timeout);

  /// GATT on an open link (the provd service's three characteristics).
  Future<int> requestMtu(String address, int mtu);
  Future<List<int>> read(String address, Char c);
  Stream<List<int>> subscribe(String address, Char c);
  Future<void> write(String address, Char c, List<int> value);

  /// Every link's state, whoever opened it: (address, connected). flutter_reactive_ble: connectedDeviceStream. This
  /// is where "disconnected" after a cancel is seen (§4.2).
  /// The third field: the failure status number when the link went down with a failure (failureCode; -1 = a failure
  /// without a number), else null. Only the gate reads it, only for the trace (design 329-ble-settle.md §3).
  Stream<(String, bool, int?)> get linkStates;
}

/// The provd service's characteristics (the node's BLE contract; ids in ble_backend.dart).
enum Char { rx, tx, ctrl }

class Refused implements Exception {
  Refused(this.why);
  final String why;
  @override
  String toString() => 'BleGate refused: $why';
}

class GateScan {
  GateScan._(this.gate, this.token);
  final BleGate gate;
  final Token token;
  StreamSubscription<(String, Uint8List?)>? _sub;
  bool _open = true;
  bool get open => _open;

  Future<void> stop() async {
    if (!_open) return;
    _open = false;
    gate._scans.remove(this); // gone from the gate at once: the next scan is not refused meanwhile (r5 J-m1)
    try {
      await _sub?.cancel();
    } catch (_) {} // a cancel that throws never leaves the gate thinking a scan runs (r5 J-m2)
  }
}

class GateLink {
  GateLink._(this.gate, this._token, this.address);
  final BleGate gate;

  /// #329 UX plan §4.7: null while NodeLink keeps the link parked (every GATT call is refused); written only by
  /// [BleGate.pass].
  Token? _token;
  Token? get token => _token;
  Cancel? _parked; // the gate's 120 s timer of a parked link
  final String address;
  StreamSubscription<bool>? _sub;
  final _state = StreamController<bool>.broadcast();
  bool _open = true;
  bool _down = false;
  Completer<void>? _gone;
  bool get open => _open;

  /// Open, and no down seen from either source (the connect stream, the backend's linkStates).
  bool get up => _open && !_down;

  /// true = connected, false = disconnected.
  Stream<bool> get state => _state.stream;

  void _on(bool up) {
    if (!up) _downNow();
    if (!_state.isClosed) _state.add(up);
  }

  void _downNow() {
    _down = true;
    final g = _gone;
    _gone = null;
    if (g != null && !g.isCompleted) g.complete();
  }

  void _usable(String what) {
    final t = _token;
    if (!_open || _down || t == null || !gate.reg.valid(t)) throw Refused('$what on a closed link or a revoked token');
  }

  Future<int> requestMtu(int mtu) async {
    _usable('mtu');
    return gate.backend.requestMtu(address, mtu);
  }

  Future<List<int>> read(Char c) async {
    _usable('read');
    return gate.backend.read(address, c);
  }

  Stream<List<int>> subscribe(Char c) {
    _usable('subscribe');
    return gate.backend.subscribe(address, c);
  }

  Future<void> write(Char c, List<int> value) async {
    _usable('write');
    return gate.backend.write(address, c, value);
  }

  /// Drop the link and wait until the stack reports it gone, or 5 s (§4.2).
  Future<void> close() async {
    if (!_open) return;
    _open = false;
    _parked?.call();
    _parked = null;
    if (!_down) _gone = Completer<void>();
    try {
      await _sub?.cancel(); // cancelling the connect subscription disconnects (flutter_reactive_ble)
      final g = _gone;
      if (g != null) {
        // ignore: unawaited_futures
        gate._timer(BleGate.closeMax, () {
          if (!g.isCompleted) g.complete();
        });
        await g.future;
      }
    } catch (_) {
      // a cancel that throws: the link is given up all the same (r5 J-m2)
    } finally {
      gate._links.remove(this);
      await _state.close();
    }
  }
}

class BleGate implements LeaseListener {
  BleGate(this.backend, this.reg, {required this.now, required this.after, this.trace}) {
    reg.listeners.add(this);
    _states = backend.linkStates.listen((e) {
      if (e.$2) return;
      final f = e.$3;
      if (f != null) {
        // design 329-ble-settle.md §2.2: one line per reported failure, whether or not the link is still on the table
        // (the failure may come after the connect stream already ended the attempt); last 2 of the address only
        final a = e.$1;
        trace?.call('link …${a.length > 2 ? a.substring(a.length - 2) : a} down fail=${f < 0 ? '?' : f}');
      }
      for (final l in [..._links.where((l) => l.address == e.$1)]) {
        l._downNow();
      }
    });
  }
  late final StreamSubscription<(String, bool, int?)> _states;

  Future<void> dispose() => _states.cancel();
  final BleBackend backend;
  final LeaseRegistry reg;
  /// One line per connect failure the stack reported (status number and the address's last 2 only); null = silent.
  final void Function(String)? trace;
  final int Function() now;
  final After after;

  static const closeMax = Duration(seconds: 5);
  static const scanWindow = Duration(seconds: 30);
  static const scanMax = 4;

  /// #329 UX plan §4.5: a parked link nobody passes on for this long is closed by the gate (two 60 s rounds).
  static const parkedMax = Duration(seconds: 120);

  final List<GateScan> _scans = [];
  final List<GateLink> _links = [];
  final List<int> _scanStarts = [];
  final List<String> refused = []; // a log line per refusal (T-G1); the last 200 only (review pr1 B-M4)

  int get scans => _scans.length;
  int get links => _links.length;

  /// 329-link-per-node.md §3.1: the links that are not (open and parked): one connecting, one held by a lease or by
  /// NodeLink for a read, and every link still closing. 0 = nobody uses the radio for a link.
  int get active => _links.where((l) => !(l._open && l._token == null)).length;

  /// Scan starts within the last 30 s (NodeLink's and the older pages').
  int get recentScanStarts {
    final t = now();
    return _scanStarts.where((x) => t - x < scanWindow.inMilliseconds).length;
  }

  void _timer(Duration d, void Function() f) => after(d, f);

  void _refuse(String line) {
    refused.add(line);
    if (refused.length > 200) refused.removeRange(0, refused.length - 200);
  }

  void _gate(Token? t, String what) {
    if (t == null || !reg.valid(t)) {
      _refuse('$what: $t is not the current token');
      throw Refused('not the current token');
    }
  }

  /// Start the one scan. A start beyond 4 in 30 s waits inside the gate until it is allowed (§4.2). [ended] is called
  /// once if the radio ends the scan by itself (an error such as Bluetooth off or no permission, or the stream
  /// closing); the scan is closed then (review pr1 A-M3 / B-M5).
  /// [seen]: every scan result with its Manufacturer Data (null = none), passed through as the backend gives it.
  Future<GateScan> scan(Token? t, void Function(String address, Uint8List? mfr) seen,
      {void Function(Object? error)? ended}) async {
    _gate(t, 'scan');
    if (_scans.isNotEmpty) {
      _refuse('scan: a scan is already running');
      throw Refused('a scan is already running');
    }
    final s = GateScan._(this, t!); // _gate refused a null token
    _scans.add(s);
    final w = _waitForScanSlot();
    if (w > 0) {
      final c = Completer<void>();
      _timer(Duration(milliseconds: w), c.complete);
      await c.future;
      if (!s.open || !reg.valid(s.token)) {
        _scans.remove(s);
        throw Refused('revoked while waiting for a scan slot');
      }
    }
    _scanStarts.add(now());
    void end(Object? e) {
      if (!s.open) return;
      s.stop();
      ended?.call(e);
    }

    s._sub = backend.scan().listen((r) => seen(r.$1, r.$2), onError: (Object e) => end(e), onDone: () => end(null));
    return s;
  }

  /// An older page (raw lease) started a scan on the shared FlutterReactiveBle: it counts against the 4 in 30 s too
  /// (A10; review pr1 A-m7).
  void noteScanStart() => _scanStarts.add(now());

  int _waitForScanSlot() {
    final t = now();
    _scanStarts.removeWhere((x) => t - x >= scanWindow.inMilliseconds);
    if (_scanStarts.length < scanMax) return 0;
    return _scanStarts.first + scanWindow.inMilliseconds - t;
  }

  /// Open a link. Refused while another link is in use or closing ([active]) and for an address that has a link
  /// (parked ones included).
  GateLink connect(Token? t, String address, {Duration timeout = const Duration(seconds: 15)}) {
    _gate(t, 'connect');
    if (active > 0) {
      _refuse('connect: a link is already open');
      throw Refused('a link is already open');
    }
    if (_links.any((l) => l.address == address)) {
      _refuse('connect: this address has a link');
      throw Refused('this address has a link');
    }
    final l = GateLink._(this, t!, address); // _gate refused a null token
    _links.add(l);
    l._sub = backend.connect(address, timeout).listen(l._on, onError: (_) => l._on(false), onDone: () => l._on(false));
    return l;
  }

  /// #329 UX plan §4.7: give an open link to another token, or park it (null: no GATT call passes until the next
  /// pass; the gate closes it after [parkedMax]). Refused for a link that is not up and for a token that is not the
  /// current one; the caller then closes the link. Only NodeLink calls this.
  void pass(GateLink l, Token? t) {
    if (!l.up) throw Refused('pass on a link that is not up');
    if (t != null && !reg.valid(t)) {
      _refuse('pass: $t is not the current token');
      throw Refused('not the current token');
    }
    l._parked?.call();
    l._parked = null;
    l._token = t;
    if (t == null) {
      l._parked = after(parkedMax, () {
        if (l._open && l._token == null) l.close();
      });
    }
  }

  /// Close what a token opened: the registry took it back (§4.4 cap), a lease was released (its leftovers), or NodeLink
  /// is handing the radio to a new lease (its own token, r5 J-m1).
  @override
  void revoked(Token t) {
    for (final s in [..._scans.where((s) => identical(s.token, t))]) {
      s.stop();
    }
    for (final l in [..._links.where((l) => identical(l.token, t))]) {
      l.close();
    }
  }

  @override
  void released(Lease l, {required bool revoked}) {
    // a released lease's holder closes its own links before releasing (§4.4 釋放: 先等斷線完成); anything left open
    // by mistake is closed here, so the next holder never finds the gate busy
    this.revoked(l.token);
  }
}
