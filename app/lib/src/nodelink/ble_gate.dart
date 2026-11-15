// #329 design §4.2 BleGate: the app's only Bluetooth entry. One scan and one link at most, each only for the
// registry's current token; a revoked token's scan and link are closed here (not by their holder); at most 4 scan
// starts in any 30 s (A10: the 6th within ~15 s is refused by Android, M-1 E); "disconnected" = the connection state
// stream says so, or 5 s. The radio sits behind BleBackend so the gate is testable without a phone.
import 'dart:async';

import 'lease.dart';

/// What the gate needs from the BLE library (the app wires FlutterReactiveBle to it).
abstract class BleBackend {
  /// Scan for the provd service; every advertisement as (address).
  Stream<String> scan();

  /// Connect; emits true when connected, false when disconnected (then completes or errors). Cancelling the
  /// subscription disconnects; after that this stream says nothing more.
  Stream<bool> connect(String address, Duration timeout);

  /// Every link's state, whoever opened it: (address, connected). flutter_reactive_ble: connectedDeviceStream. This
  /// is where "disconnected" after a cancel is seen (§4.2).
  Stream<(String, bool)> get linkStates;
}

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
  StreamSubscription<String>? _sub;
  bool _open = true;
  bool get open => _open;

  Future<void> stop() async {
    if (!_open) return;
    _open = false;
    await _sub?.cancel();
    gate._scans.remove(this);
  }
}

class GateLink {
  GateLink._(this.gate, this.token, this.address);
  final BleGate gate;
  final Token token;
  final String address;
  StreamSubscription<bool>? _sub;
  final _state = StreamController<bool>.broadcast();
  bool _open = true;
  bool _down = false;
  Completer<void>? _gone;
  bool get open => _open;

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

  /// Drop the link and wait until the stack reports it gone, or 5 s (§4.2).
  Future<void> close() async {
    if (!_open) return;
    _open = false;
    if (!_down) _gone = Completer<void>();
    await _sub?.cancel(); // cancelling the connect subscription disconnects (flutter_reactive_ble)
    final g = _gone;
    if (g != null) {
      // ignore: unawaited_futures
      gate._timer(BleGate.closeMax, () {
        if (!g.isCompleted) g.complete();
      });
      await g.future;
    }
    gate._links.remove(this);
    await _state.close();
  }
}

class BleGate implements LeaseListener {
  BleGate(this.backend, this.reg, {required this.now, required this.after}) {
    reg.listeners.add(this);
    _states = backend.linkStates.listen((e) {
      if (e.$2) return;
      for (final l in [..._links.where((l) => l.address == e.$1)]) {
        l._downNow();
      }
    });
  }
  late final StreamSubscription<(String, bool)> _states;

  Future<void> dispose() => _states.cancel();
  final BleBackend backend;
  final LeaseRegistry reg;
  final int Function() now;
  final After after;

  static const closeMax = Duration(seconds: 5);
  static const scanWindow = Duration(seconds: 30);
  static const scanMax = 4;

  final List<GateScan> _scans = [];
  final List<GateLink> _links = [];
  final List<int> _scanStarts = [];
  final List<String> refused = []; // a log line per refusal (T-G1)

  int get scans => _scans.length;
  int get links => _links.length;

  void _timer(Duration d, void Function() f) => after(d, f);

  void _gate(Token t, String what) {
    if (!reg.valid(t)) {
      refused.add('$what: $t is not the current token');
      throw Refused('not the current token');
    }
  }

  /// Start the one scan. A start beyond 4 in 30 s waits inside the gate until it is allowed (§4.2).
  Future<GateScan> scan(Token t, void Function(String address) seen) async {
    _gate(t, 'scan');
    if (_scans.isNotEmpty) {
      refused.add('scan: a scan is already running');
      throw Refused('a scan is already running');
    }
    final s = GateScan._(this, t);
    _scans.add(s);
    final w = _waitForScanSlot();
    if (w > 0) {
      final c = Completer<void>();
      _timer(Duration(milliseconds: w), c.complete);
      await c.future;
      if (!s.open || !reg.valid(t)) {
        _scans.remove(s);
        throw Refused('revoked while waiting for a scan slot');
      }
    }
    _scanStarts.add(now());
    s._sub = backend.scan().listen(seen);
    return s;
  }

  int _waitForScanSlot() {
    final t = now();
    _scanStarts.removeWhere((x) => t - x >= scanWindow.inMilliseconds);
    if (_scanStarts.length < scanMax) return 0;
    return _scanStarts.first + scanWindow.inMilliseconds - t;
  }

  /// Open the one link.
  GateLink connect(Token t, String address, {Duration timeout = const Duration(seconds: 15)}) {
    _gate(t, 'connect');
    if (_links.isNotEmpty) {
      refused.add('connect: a link is already open');
      throw Refused('a link is already open');
    }
    final l = GateLink._(this, t, address);
    _links.add(l);
    l._sub = backend.connect(address, timeout).listen(l._on, onError: (_) => l._on(false), onDone: () => l._on(false));
    return l;
  }

  /// The registry took a token back: close what it opened (§4.2, §4.4 420 s).
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
