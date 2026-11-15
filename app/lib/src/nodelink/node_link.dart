// #329 design §4.3: NodeLink drives the scheduler core (core.dart) with the real radio. It owns the timer, the one
// scan of a round and the one link of an attempt (both through BleGate with the registry's NodeLink token, which
// exists only while no lease is held); the login + status read of an attempt is a Prober (the OwnerSession one is
// prober.dart; tests use fakes). Pages and the app lifecycle tell it what is on screen; the lease registry tells it
// when an operation holds Bluetooth.
import 'dart:async';

import 'package:flutter/widgets.dart' show AppLifecycleState;

import 'ble_gate.dart';
import 'core.dart';
import 'lease.dart';

/// One attempt's login + status read on an open link, for record [id]. [due] completes when the attempt's 8 s from
/// the start of the connect to msg2 are over (§4.3.3-3): without msg2 by then it is `noResponse`. It must stop when
/// [cancelled] completes.
abstract class Prober {
  Future<Outcome> probe(GateLink link, String id, {required Future<void> due, required Future<void> cancelled});
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
    DateTime Function()? wall,
    this.trace,
  }) : wall = wall ?? DateTime.now {
    reg.listeners.add(this);
  }

  final NodeLinkCore core;
  final BleGate gate;
  final LeaseRegistry reg;
  final Prober prober;
  final ReadRecords readRecords;
  final int Function() now;
  final After after;

  /// Wall-clock time, for 「讀取於 HH:MM」 only (the core's clock is monotonic and stops in deep sleep; review pr1
  /// A-m8).
  final DateTime Function() wall;

  /// A line per attempt (timings, outcome) and the core's log lines, for logcat. Ids and addresses are cut to their
  /// last 4 characters (T-S4: no long hex run in a log).
  final void Function(String line)? trace;
  String? _traced;

  static String mask(String s) => s
      .replaceAllMapped(RegExp(r'[0-9a-fA-F]{8,}'), (m) => '…${m[0]!.substring(m[0]!.length - 4)}')
      .replaceAllMapped(RegExp(r'(?:[0-9A-Fa-f]{2}:){5}([0-9A-Fa-f]{2})'), (m) => '…${m[1]}');

  void _forwardLog() {
    final t = trace;
    if (t == null) return;
    final log = core.log;
    var i = log.length;
    while (i > 0 && !identical(log[i - 1], _traced)) {
      i--;
    }
    for (final l in log.sublist(i)) { // not found (first call, or trimmed out of the ring): all of it
      t(mask(l));
    }
    if (log.isNotEmpty) _traced = log.last;
  }

  /// §4.3.3-3: from the start of the connect to msg2, one budget.
  static const msg2 = Duration(seconds: 8);
  static const scanRetry = Duration(milliseconds: 500); // a refused scan start is tried again after this (B-M4)
  static const scanEndedRetry = Duration(seconds: 2); // the radio ended the scan by itself (A-M3)

  final _changed = StreamController<void>.broadcast();

  /// Fires after every change a screen may show (a read, a conclusion, a precondition).
  Stream<void> get changed => _changed.stream;

  /// The wall-clock time of each node's last status read.
  final Map<String, DateTime> readWall = {};

  GateScan? _scan;
  bool _scanStarting = false;
  Cancel? _scanWait;
  Attempt? _attempt;
  GateLink? _link;
  Completer<void>? _cancel;
  Cancel? _timer;
  bool _disposed = false;
  List<Rec> _recs = const [];
  final Set<String> _writtenWaiting = {}; // records written under a lease released while another one was taken

  // ---- events from the app ----------------------------------------------------------------------------------

  Future<void> start(Page page, {String? node}) async {
    _recs = await readRecords();
    core.setRecords(_recs);
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

  /// T20: paused / hidden / detached are the background; resumed is the foreground; inactive (a dialog, the
  /// notification shade) changes nothing.
  void lifecycle(AppLifecycleState s) {
    switch (s) {
      case AppLifecycleState.resumed:
        foreground();
      case AppLifecycleState.paused || AppLifecycleState.hidden || AppLifecycleState.detached:
        background();
      case AppLifecycleState.inactive:
        break;
    }
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
    // records written under it, a round 6 s later. An older page (raw lease) does not report what it wrote: the
    // records that appeared, went or changed time are taken as written by it (review pr1 A-M2).
    final before = _recs;
    readRecords().then<List<Rec>?>((r) => r, onError: (Object _) => null).then((recs) {
      if (_disposed) return;
      final written = {..._writtenWaiting, ...l.writtenNodes};
      if (recs != null) {
        if (l.kind == LeaseKind.raw) written.addAll(_changedIds(before, recs));
        _recs = recs;
      }
      if (reg.current != null) {
        // another lease was taken while the records were read: the core stays leased (review pr1 A-M5 / B-M2);
        // the written records wait for that lease's release
        if (recs != null) core.setRecords(recs);
        _writtenWaiting.addAll(written);
        return;
      }
      _writtenWaiting.clear();
      core.releaseLease(now(), written: written, recs: recs); // records unreadable: the old list (A-m6)
      _pump();
    });
  }

  static Set<String> _changedIds(List<Rec> a, List<Rec> b) {
    final was = {for (final r in a) r.id: r.mtime};
    final now = {for (final r in b) r.id: r.mtime};
    return {
      for (final id in {...was.keys, ...now.keys})
        if (was[id] != now[id]) id,
    };
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
      if (_scan == null && !_scanStarting && _scanWait == null) _startScan();
      // the next attempt starts only once the last link is gone (review pr1 B-m1)
      if (_attempt == null && _scan != null && gate.links == 0) {
        final next = core.next(t);
        if (next != null) _run(next);
      }
    } else if (_scan != null) {
      final s = _scan!;
      _scan = null;
      s.stop();
    }
    _forwardLog();
    _changed.add(null);
    _timer?.call();
    final w = core.wakeAt(t);
    if (w != null) _timer = after(Duration(milliseconds: w - t), _pump);
  }

  void _retryScan(Duration d) {
    _scanWait?.call();
    _scanWait = after(d, () {
      _scanWait = null;
      _pump();
    });
  }

  Future<void> _startScan() async {
    _scanStarting = true;
    GateScan? s;
    try {
      s = await gate.scan(reg.nodeLinkToken, (address) {
        if (core.onScan(now(), address) && _attempt == null) _pump();
      }, ended: (_) {
        // the radio ended the scan (Bluetooth off, no permission): the round goes on without one; the status
        // stream tells the core why, and a new scan is tried a little later
        if (identical(_scan, s)) _scan = null;
        _retryScan(scanEndedRetry);
      });
    } on Refused {
      // a lease took the radio, or the last scan is still stopping: never again in the same microtask (B-M4)
      _scanStarting = false;
      _retryScan(scanRetry);
      return;
    } finally {
      _scanStarting = false;
    }
    if (s.open) _scan = s;
    _pump();
  }

  Future<void> _run(Attempt a) async {
    _attempt = a;
    final cancel = _cancel = Completer<void>();
    // §4.3.3-3: one 8 s budget from the start of the connect to msg2, on the injected clock
    final due = Completer<void>();
    final stopDue = after(msg2, () => due.isCompleted ? null : due.complete());
    final t0 = now();
    var tUp = -1;
    GateLink? mine;
    Outcome o;
    try {
      final link = mine = _link = gate.connect(reg.nodeLinkToken, a.addr, timeout: msg2);
      final up = await Future.any<bool>([
        link.state.firstWhere((s) => s, orElse: () => false),
        due.future.then((_) => false),
        cancel.future.then((_) => false),
      ]);
      tUp = up ? now() - t0 : -1;
      if (!up || cancel.isCompleted) {
        o = const Outcome(Res.noResponse);
      } else {
        o = await prober.probe(link, a.id, due: due.future, cancelled: cancel.future);
      }
    } on Refused {
      o = const Outcome(Res.noResponse);
    } catch (_) {
      o = const Outcome(Res.noResponse); // one attempt's exception ends that attempt only (§4.3.3-4, F50)
    }
    stopDue();
    trace?.call(mask('attempt $a connected=${tUp}ms result=${o.res.name} after ${now() - t0}ms'));
    // close this attempt's own link only: a late end never closes the next attempt's (review pr1 A-m1 / B-m1)
    await mine?.close();
    if (identical(_link, mine)) _link = null;
    if (!identical(_attempt, a)) return; // aborted: the core no longer waits for it
    _attempt = null;
    _cancel = null;
    if (o.res == Res.body) readWall[a.id] = wall();
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
    // the next attempt waits for this link to be gone; then plan again
    l?.close().then((_) => _pump());
  }

  Future<void> _dropAll() async {
    _abort();
    _scanWait?.call();
    _scanWait = null;
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
