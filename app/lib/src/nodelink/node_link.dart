// #329 design §4.3: NodeLink drives the scheduler core (core.dart) with the real radio. It owns the timer, the one
// scan of a round and the one link of an attempt (both through BleGate with the registry's NodeLink token, which
// exists only while no lease is held); the login + status read of an attempt is a Prober (the OwnerSession one is
// prober.dart; tests use fakes). Pages and the app lifecycle tell it what is on screen; the lease registry tells it
// when an operation holds Bluetooth.
import 'dart:async';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter/widgets.dart' show AppLifecycleState;

import 'ble_gate.dart';
import 'core.dart';
import 'handoff.dart';
import 'lease.dart';
import '../rust/api/owner.dart' show TeamView;
import '../rust/api/rekey.dart' show UpdateHint;

/// #329 PR 6 D5(b): the team section worked out on a read's own session ([Outcome.team]): the network the node said
/// it is in, and Rust's view.
class TeamSeen {
  const TeamSeen(this.netId, this.view);
  final String netId;
  final TeamView view;
}

/// #329 PR 6 D5(c): a node's team section as kept by NodeLink: the [TeamSeen] of an accepted read, with that read's
/// monotonic time (= the state's `readAt` it was written with) and wall time. Memory only; never logged (T-A9).
class TeamRead {
  const TeamRead(this.netId, this.view, this.readAt, this.readWall);
  final String netId;
  final TeamView view;
  final int readAt;
  final DateTime readWall;
}

/// One attempt's login + status read on an open link, for record [id]. [due] completes when the attempt's 8 s from
/// the start of the connect to msg2 are over (§4.3.3-3): without msg2 by then it is `noResponse`. It must stop when
/// [cancelled] completes.
abstract class Prober {
  Future<Outcome> probe(GateLink link, String id, {required Future<void> due, required Future<void> cancelled});
}

/// The phone's node records and their file times (A23), read after start-up and after every lease release.
typedef ReadRecords = Future<List<Rec>> Function();

/// #329 PR 3 §2.1: how a flow's login under its lease ended. `noLease`: the lease given is not the registry's current
/// session lease (or was taken back meanwhile), or another login is running.
enum LoginForEnd { ok, identity, refused, notFound, precondition, noLease }

class LoginForResult {
  const LoginForResult(this.end, [this.handoff]);
  final LoginForEnd end;

  /// Only with `ok`: the logged-in session, now the caller's.
  final LoginHandoff? handoff;
}

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
    this.loginProber,
    this.keysOk,
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

  /// #329 PR 3 §2.1: the prober of a flow's login (HandoffProber in the app). Null = no flow logins (tests of reads).
  final Prober? loginProber;

  /// The live key read before a flow's login (design §4.1: KeyAbilities before each login). Null = not checked.
  final Future<bool> Function()? keysOk;

  static String mask(String s) => s
      .replaceAllMapped(RegExp(r'[0-9a-fA-F]{8,}'), (m) => '…${m[0]!.substring(m[0]!.length - 4)}')
      .replaceAllMapped(RegExp(r'(?:[0-9A-Fa-f]{2}:){5}([0-9A-Fa-f]{2})'), (m) => '…${m[1]}');

  /// #329 PR 6 D4 (design :342): an event the text log must keep (a lease taken back, a record write refused or
  /// failed); the caller names only the kind, the operation and last fours. Also forwarded to logcat, masked.
  void note(String line) {
    core.note(now(), line);
    _forwardLog();
  }

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

  /// Fires after every change a screen may show (a read, a conclusion, a precondition). Each listener is counted
  /// ([changedListeners]); events reach it in the same turn the shared broadcast delivers them (addSync: no extra hop).
  Stream<void> get changed => Stream<void>.multi((c) {
        _changedListeners++;
        final s = _changed.stream.listen((_) => c.addSync(null), onError: c.addErrorSync, onDone: c.closeSync);
        c.onCancel = () {
          _changedListeners--;
          return s.cancel();
        };
      }, isBroadcast: true);
  int _changedListeners = 0;

  /// #329 PR 6 D10: how many subscriptions to [changed] are open. A page's own subscription is the difference while it
  /// is on screen (AppLink keeps one of its own, app_link.dart: `sw.retain`; the home page another), so the plan's
  /// `hasChangedListener` (a bool) could not tell a page's subscription apart: tests compare this count instead.
  @visibleForTesting
  int get changedListeners => _changedListeners;

  /// The wall-clock time of each node's last status read.
  final Map<String, DateTime> readWall = {};

  /// #329 PR 5 R8: the remove-member §3.5 line of the node whose page is open (memory only, never in UiState).
  final Map<String, UpdateHint> hints = {};

  /// #329 PR 6 D5(c): each own node's team section. One writer: [_run], after the core accepted that read; cleared
  /// for a record that is gone ([_dropGoneTeams]); a page change keeps it. Never logged (254 T-A9).
  final Map<String, TeamRead> teams = {};

  /// D5(c): the team sections of records no longer on the phone go with them.
  void _dropGoneTeams() => teams.removeWhere((id, _) => !core.states.containsKey(id));

  /// R8: a read's hint for [id], kept only while [id]'s page is open (a late one after leaving is dropped); an empty
  /// line removes it. Fires [changed] when it changes.
  void setHint(String id, UpdateHint h) {
    if (core.page != Page.node || core.pageNode != id) return;
    final had = hints[id];
    if (h.line.isEmpty) {
      if (hints.remove(id) != null) _changed.add(null);
      return;
    }
    if (had != null && had.line == h.line && had.button == h.button) return;
    hints[id] = h;
    _changed.add(null);
  }

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
  Future<void>? _releasing; // the record read after the last release (§2.1, P7)

  // ---- events from the app ----------------------------------------------------------------------------------

  /// [life]: the app's lifecycle state now; the user may have left during the startup check, before the app-wide
  /// observer existed (r3 E-m1): then no round starts until the app comes back.
  Future<void> start(Page page, {String? node, AppLifecycleState? life}) async {
    // applied before the records are read: a return to the foreground during the read then wins (r4 G-m1)
    if (life == AppLifecycleState.paused || life == AppLifecycleState.hidden || life == AppLifecycleState.detached) {
      core.background(now());
    }
    _recs = await readRecords();
    core.setRecords(_recs);
    _dropGoneTeams();
    core.startup(now(), page, node: node);
    _pump();
  }

  void setPage(Page page, {String? node}) {
    // R8: leaving a node page drops its hint (no stale card when it opens again, review K-m5 / L-m1)
    if (hints.isNotEmpty && (page != Page.node || node != core.pageNode)) {
      hints.clear();
      _changed.add(null);
    }
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
    _lfCut(); // a login under a lease ends as precondition at once (core.setRadio), its attempt with it
    _lfPoke();
    _pump();
  }

  /// §4.4 拿到之前: cancel the round, wait until its link is gone (at most 5 s), then the lease. Null = another
  /// operation holds it (the caller shows 「另一個操作還在進行：<名稱>」 with [LeaseRegistry.current]).
  Future<Lease?> acquire(String name, LeaseKind kind) async {
    // #329 PR 3 §2.1 (P7): the last release's record read ends first (at most 5 s), so the N9 window of a record
    // written under it is set before the next lease
    final r = _releasing;
    if (r != null) {
      await r.timeout(const Duration(seconds: 5), onTimeout: () {});
    }
    if (reg.current != null) return null;
    core.acquireLease(now());
    await _dropAll();
    final mine = reg.nodeLinkToken; // NodeLink's own token (no lease is held here), until the lease replaces it
    final l = reg.acquire(name, kind);
    // anything NodeLink's token still has in the gate goes too: a scan that was waiting for a slot would block the
    // holder's own scan for up to 30 s (review pr1 r5 J-m1)
    if (l != null && mine != null) gate.revoked(mine);
    _pump();
    return l;
  }


  // ---- a flow's login under its lease (#329 PR 3 §2.1, design §4.3.9) -------------------------------------------

  // the driver's own fields (never the round's): one login at a time
  bool _lfBusy = false;
  int _lfGen = 0; // a scan that comes back after its login ended never feeds the next one
  LoginFor? _lf;
  GateScan? _lfScan;
  bool _lfScanStarting = false;
  Cancel? _lfScanWait;
  Cancel? _lfTimer;
  Completer<void>? _lfWake;
  Completer<void>? _lfCancel;

  void _lfPoke() {
    final w = _lfWake;
    _lfWake = null;
    if (w != null && !w.isCompleted) w.complete();
  }

  /// The running attempt is cut when the login is over (60 s, a precondition) or its lease is gone.
  void _lfCut() {
    final c = _lfCancel;
    if (c != null && !c.isCompleted && (_lf?.done ?? true)) c.complete();
  }

  /// §4.3.9: log in to node [id] under the session lease [lease], up to 60 s from the moment its scan really started.
  /// [clearNotY]: 「再試這一台」 (a node just claimed may have been memoed 「不是」). On `ok` the session, its link and
  /// its frames are handed over ([LoginForResult.handoff]); every other end leaves no link open.
  Future<LoginForResult> loginFor(Lease lease, String id, {bool clearNotY = false}) async {
    final p = loginProber;
    bool mine() => identical(reg.current, lease) && lease.valid && lease.kind == LeaseKind.session;
    if (p == null || _disposed || _lfBusy || !mine()) return const LoginForResult(LoginForEnd.noLease);
    _lfBusy = true;
    _lfGen++;
    try {
      return await _loginFor(p, lease, id, clearNotY, mine);
    } finally {
      await _lfStop();
      _lfBusy = false;
    }
  }

  Future<LoginForResult> _loginFor(Prober p, Lease lease, String id, bool clearNotY, bool Function() mine) async {
    // design §4.1: the keys are read live before each login; a no is 2.4, as a key the gate refused (X26)
    final k = keysOk;
    if (k != null) {
      var ok = false;
      try {
        ok = await k();
      } catch (_) {}
      if (!ok) radio(keyOk: false);
    }
    if (!mine()) return const LoginForResult(LoginForEnd.noLease);
    if (core.blocked != null) return const LoginForResult(LoginForEnd.precondition);
    final early = <String>[];
    final gen = _lfGen;
    void seen(String a) {
      if (gen != _lfGen) return;
      final l = _lf;
      if (l == null) {
        early.add(a); // seen before the login's clock started
      } else if (!l.seen.contains(a)) {
        l.onScan(now(), a);
        _lfPoke();
      }
    }

    // the 60 s start when the scan really starts: a wait for a scan slot (4 in 30 s) is not counted
    await _lfStartScan(lease, seen);
    if (!mine()) return const LoginForResult(LoginForEnd.noLease);
    final l = _lf = core.loginFor(now(), id, clearNotY: clearNotY);
    for (final a in early) {
      l.onScan(now(), a);
    }
    while (true) {
      if (_disposed || !mine()) return const LoginForResult(LoginForEnd.noLease);
      l.tick(now());
      if (l.done) break;
      if (_lfScan == null && !_lfScanStarting && _lfScanWait == null) unawaited(_lfStartScan(lease, seen));
      final a = gate.links == 0 ? l.next(now()) : null;
      if (a != null) {
        final o = await _lfAttempt(p, lease, l, a);
        l.result(now(), a, o);
        final h = o.extra;
        if (h is LoginHandoff) {
          if (l.end == LoginEnd.ok && mine() && !_disposed) return LoginForResult(LoginForEnd.ok, h);
          await h.close(); // logged in, but the login was over meanwhile (60 s, a precondition, the lease)
        }
        continue;
      }
      final w = l.wakeAt(now());
      // a link still closing is waited for in short steps; otherwise the next deadline or an event (an address, the
      // radio, the lease)
      final ms = gate.links > 0 ? 100 : (w == null ? null : w - now());
      await _lfSleep(ms);
    }
    trace?.call(mask('loginFor $id -> ${l.end!.name}'));
    return LoginForResult(switch (l.end!) {
      LoginEnd.ok => LoginForEnd.notFound, // an ok without a hand-off cannot happen: never claim a login
      LoginEnd.identity => LoginForEnd.identity,
      LoginEnd.refused => LoginForEnd.refused,
      LoginEnd.notFound => LoginForEnd.notFound,
      LoginEnd.precondition => LoginForEnd.precondition,
    });
  }

  Future<void> _lfSleep(int? ms) async {
    final w = _lfWake = Completer<void>();
    _lfTimer?.call();
    _lfTimer = ms == null ? null : after(Duration(milliseconds: ms < 0 ? 0 : ms), _lfPoke);
    await w.future;
  }

  Future<void> _lfStartScan(Lease lease, void Function(String) seen) async {
    final gen = _lfGen;
    _lfScanStarting = true;
    late final GateScan s;
    try {
      s = await gate.scan(lease.token, seen, ended: (_) {
        // the radio ended the scan while the login goes on: a new one a little later (§2.1 重掃)
        if (identical(_lfScan, s)) _lfScan = null;
        _lfScanWait?.call();
        _lfScanWait = after(NodeLink.scanEndedRetry, () {
          _lfScanWait = null;
          _lfPoke();
        });
      });
    } on Refused {
      _lfScanWait?.call();
      _lfScanWait = after(NodeLink.scanRetry, () {
        _lfScanWait = null;
        _lfPoke();
      });
      return;
    } finally {
      _lfScanStarting = false;
    }
    if (gen != _lfGen || !_lfBusy || _disposed) {
      await s.stop(); // the login ended while the scan waited for a slot
      return;
    }
    if (s.open) _lfScan = s;
  }

  Future<Outcome> _lfAttempt(Prober p, Lease lease, LoginFor l, Attempt a) async {
    final cancel = _lfCancel = Completer<void>();
    final due = Completer<void>();
    final stopDue = after(msg2, () => due.isCompleted ? null : due.complete());
    // the 60 s cut the running attempt too (code-1 A-m6)
    final left = l.start + LoginFor.budget - now();
    final stopBudget = after(Duration(milliseconds: left < 0 ? 0 : left), () {
      if (!cancel.isCompleted) cancel.complete();
    });
    final t0 = now();
    GateLink? link;
    Outcome o;
    try {
      final k = link = gate.connect(lease.token, a.addr, timeout: msg2);
      final up = await Future.any<bool>([
        // design 329-ble-settle.md §2.1: the first link event, not the first `true`: a failure ends the attempt now
        k.state.first.then((s) => s, onError: (Object _) => false),
        due.future.then((_) => false),
        cancel.future.then((_) => false),
      ]);
      o = (!up || cancel.isCompleted)
          ? const Outcome(Res.noResponse)
          : await p.probe(k, a.id, due: due.future, cancelled: cancel.future);
    } on Refused {
      o = const Outcome(Res.noResponse);
    } catch (e) {
      o = const Outcome(Res.noResponse); // one attempt's exception ends that attempt only
      trace?.call(mask('loginFor $a: ${e.runtimeType} $e'));
    }
    stopDue();
    stopBudget();
    if (identical(_lfCancel, cancel)) _lfCancel = null;
    trace?.call(mask('loginFor $a result=${o.res.name} after ${now() - t0}ms'));
    // a failed attempt's link is gone before the next one (§2.1); a hand-off keeps its link
    if (o.extra is! LoginHandoff) await link?.close();
    return o;
  }

  Future<void> _lfStop() async {
    _lfTimer?.call();
    _lfTimer = null;
    _lfScanWait?.call();
    _lfScanWait = null;
    final c = _lfCancel;
    _lfCancel = null;
    if (c != null && !c.isCompleted) c.complete();
    _lf = null;
    _lfPoke();
    final s = _lfScan;
    _lfScan = null;
    await s?.stop();
  }
  // ---- lease registry --------------------------------------------------------------------------------------------

  @override
  void revoked(Token t) {
    // a login under the lease taken back ends now (its attempt's link is closed by the gate)
    final c = _lfCancel;
    if (c != null && !c.isCompleted) c.complete();
    _lfPoke();
  }

  @override
  void released(Lease l, {required bool revoked}) {
    // §4.4 釋放之後: read the records again (a claim added one, a removal deleted one), drop the memos of the
    // records written under it, a round 6 s later. An older page (raw lease) does not report what it wrote: the
    // records that appeared, went or changed time are taken as written by it (review pr1 A-M2).
    // a login under the released lease ends now, its attempt with it
    final c = _lfCancel;
    if (c != null && !c.isCompleted) c.complete();
    _lfPoke();
    final before = _recs;
    _releasing = readRecords().then<List<Rec>?>((r) => r, onError: (Object _) => null).then((recs) {
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
        _dropGoneTeams(); // #329 PR 6 D5(c): node/<id> removed -> its team section goes
        _writtenWaiting.addAll(written);
        return;
      }
      _writtenWaiting.clear();
      core.releaseLease(now(), written: written, recs: recs); // records unreadable: the old list (A-m6)
      _dropGoneTeams(); // #329 PR 6 D5(c): node/<id> removed -> its team section goes
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
    _noteTwoPrime();
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

  final Map<String, int?> _twoPrimeAt = {};

  /// A 2' is a read too: its wall time is the moment the core made it 2' (at a round's end, in tick), not the last
  /// body's (PR 2 review r2 D-m6, r3 E-m2).
  void _noteTwoPrime() {
    core.states.forEach((id, s) {
      if (s.view == "2'" && s.readAt != _twoPrimeAt[id]) {
        _twoPrimeAt[id] = s.readAt;
        readWall[id] = wall();
      }
    });
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
        if (_disposed) return;
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
    if (_disposed) {
      await s.stop(); // disposed while the scan waited for a slot (r2 C-m6)
      return;
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
        // design 329-ble-settle.md §2.1: the first link event, not the first `true`: a failure ends the attempt now
        link.state.first.then((s) => s, onError: (Object _) => false),
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
    } catch (e) {
      o = const Outcome(Res.noResponse); // one attempt's exception ends that attempt only (§4.3.3-4, F50)
      trace?.call(mask('attempt $a: ${e.runtimeType} $e'));
    }
    stopDue();
    trace?.call(mask('attempt $a connected=${tUp}ms result=${o.res.name} after ${now() - t0}ms'));
    // close this attempt's own link only: a late end never closes the next attempt's (review pr1 A-m1 / B-m1)
    await mine?.close();
    if (identical(_link, mine)) _link = null;
    if (!identical(_attempt, a)) return; // aborted: the core no longer waits for it
    _attempt = null;
    _cancel = null;
    // one clock value for the core's readAt and the team section's (#329 PR 6 §14: a second now() would differ)
    final t = now();
    final accepted = core.result(t, a, o);
    // the wall time of a read; a 2' is a read too (its own time, not the last body's: PR 2 review r2 D-m6)
    if (o.res == Res.body) readWall[a.id] = wall();
    // #329 PR 6 D5(c): the team section of this read, only when the core took the read (not a cancelled round, not
    // a record gone, not an error-code answer), with the very readAt / readWall just written for it
    final team = o.team;
    final w = readWall[a.id];
    if (accepted && o.res == Res.body && team is TeamSeen && w != null) {
      teams[a.id] = TeamRead(team.netId, team.view, t, w);
    }
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
    _lfPoke();
    final c = _lfCancel;
    if (c != null && !c.isCompleted) c.complete();
    reg.listeners.remove(this);
    _timer?.call();
    await _dropAll();
    await _changed.close();
  }
}
