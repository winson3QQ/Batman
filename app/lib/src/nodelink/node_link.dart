// #329 design §4.3: NodeLink drives the scheduler core (core.dart) with the real radio. It owns the timer, the one
// scan of a round and the one link of an attempt (both through BleGate with the registry's NodeLink token); the
// login + status read of an attempt is a Prober (the OwnerSession one is prober.dart; tests use fakes). Pages and
// the app lifecycle tell it what is on screen; the lease registry tells it when an operation holds Bluetooth.
import 'dart:async';

import 'ble_gate.dart';
import 'core.dart';
import 'lease.dart';

/// One attempt's login + status read on an open link, for record [id]. Returns the core's outcome; `noResponse`
/// when msg2 did not come within [msg2] (§4.3.3-3). It must stop when [cancelled] completes.
abstract class Prober {
  Future<Outcome> probe(GateLink link, String id, {required Duration msg2, required Future<void> cancelled});
}

/// The phone's node records and their file times (A23), read after start-up and after every lease release.
typedef ReadRecords = Future<List<Rec>> Function();

class NodeLink implements LeaseListener {
  NodeLink({
    required this.core,
    required this.gate,
    required this.reg,
    required this.prober,
    required this.readRecords,
    required this.now,
    required this.after,
  }) {
    reg.listeners.add(this);
  }

  final NodeLinkCore core;
  final BleGate gate;
  final LeaseRegistry reg;
  final Prober prober;
  final ReadRecords readRecords;
  final int Function() now;
  final After after;

  static const msg2 = Duration(seconds: 8);
  static const connectMax = Duration(seconds: 8); // inside the 8 s to msg2

  final _changed = StreamController<void>.broadcast();

  /// Fires after every change a screen may show (a read, a conclusion, a precondition).
  Stream<void> get changed => _changed.stream;

  GateScan? _scan;
  bool _scanStarting = false;
  Attempt? _attempt;
  GateLink? _link;
  Completer<void>? _cancel;
  Cancel? _timer;
  bool _disposed = false;

  // ---- events from the app ----------------------------------------------------------------------------------

  Future<void> start(Page page, {String? node}) async {
    core.setRecords(await readRecords());
    core.startup(now(), page, node: node);
    _pump();
  }

  void setPage(Page page, {String? node}) {
    core.setPage(now(), page, node: node);
    _pump();
  }

  void background() {
    core.background(now());
    _pump();
  }

  void foreground() {
    core.foreground(now());
    _pump();
  }

  void refresh() {
    core.refresh(now());
    _pump();
  }

  void radio({bool? bluetooth, bool? permission, bool? keyOk}) {
    core.setRadio(now(), bluetooth: bluetooth, permission: permission, keyOk: keyOk);
    _pump();
  }

  /// §4.4 拿到之前: cancel the round, wait until its link is gone (at most 5 s), then the lease. Null = another
  /// operation holds it (the caller shows 「另一個操作還在進行：<名稱>」 with [LeaseRegistry.current]).
  Future<Lease?> acquire(String name, LeaseKind kind) async {
    if (reg.current != null) return null;
    core.acquireLease(now());
    await _dropAll();
    final l = reg.acquire(name, kind);
    _pump();
    return l;
  }

  // ---- lease registry --------------------------------------------------------------------------------------------

  @override
  void revoked(Token t) {}

  @override
  void released(Lease l, {required bool revoked}) {
    // §4.4 釋放之後: read the records again (a claim added one, a removal deleted one), drop the memos of the
    // records written under it, a round 6 s later
    readRecords().then((recs) {
      if (_disposed) return;
      core.releaseLease(now(), written: l.writtenNodes, recs: recs);
      _pump();
    });
  }

  // ---- the loop ------------------------------------------------------------------------------------------------

  void _pump() {
    if (_disposed) return;
    final t = now();
    core.tick(t);
    // the core cancelled or cut the attempt in progress: drop its link now (a round only reads, §4.3.3-8)
    final a = _attempt;
    if (a != null && !identical(core.running, a)) _abort();
    if (core.roundActive) {
      if (_scan == null && !_scanStarting) _startScan();
      if (_attempt == null && _scan != null) {
        final next = core.next(t);
        if (next != null) _run(next);
      }
    } else if (_scan != null) {
      final s = _scan!;
      _scan = null;
      s.stop();
    }
    _changed.add(null);
    _timer?.call();
    final w = core.wakeAt(t);
    if (w != null) _timer = after(Duration(milliseconds: w - t), _pump);
  }

  Future<void> _startScan() async {
    _scanStarting = true;
    try {
      _scan = await gate.scan(reg.token, (address) {
        core.onScan(now(), address);
        if (_attempt == null) _pump();
      });
    } on Refused {
      // a lease took the radio meanwhile: nothing to do, the round is cancelled by it
    } finally {
      _scanStarting = false;
    }
    _pump();
  }

  Future<void> _run(Attempt a) async {
    _attempt = a;
    final cancel = _cancel = Completer<void>();
    Outcome o;
    try {
      final link = _link = gate.connect(reg.token, a.addr, timeout: connectMax);
      // the 8 s budget is timed with the injected clock (the same clock as the core), not a Dart timeout
      final timedOut = Completer<bool>();
      final stop = after(connectMax, () => timedOut.isCompleted ? null : timedOut.complete(false));
      final up = await Future.any<bool>([
        link.state.firstWhere((s) => s, orElse: () => false),
        timedOut.future,
        cancel.future.then((_) => false),
      ]);
      stop();
      if (!up || cancel.isCompleted) {
        o = const Outcome(Res.noResponse);
      } else {
        o = await prober.probe(link, a.id, msg2: msg2, cancelled: cancel.future);
      }
    } on Refused {
      o = const Outcome(Res.noResponse);
    } catch (_) {
      o = const Outcome(Res.noResponse); // one attempt's exception ends that attempt only (§4.3.3-4, F50)
    }
    await _link?.close();
    _link = null;
    if (!identical(_attempt, a)) return; // aborted: the core no longer waits for it
    _attempt = null;
    _cancel = null;
    core.result(now(), a, o);
    _pump();
  }

  void _abort() {
    _attempt = null;
    final c = _cancel;
    _cancel = null;
    if (c != null && !c.isCompleted) c.complete();
    final l = _link;
    _link = null;
    l?.close();
  }

  Future<void> _dropAll() async {
    _abort();
    final s = _scan;
    _scan = null;
    await s?.stop();
    // §4.2 斷線完成: the gate counts a link until the stack says it is gone, or 5 s
    for (var i = 0; i < 50 && gate.links > 0; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
  }

  Future<void> dispose() async {
    _disposed = true;
    _timer?.call();
    await _dropAll();
    await _changed.close();
  }
}
