// #329 design §4.3: NodeLink drives the scheduler core (core.dart) with the real radio. It owns the timer, the one
// scan of a round, the one link of an attempt and the links it keeps open to its own nodes (329-link-per-node.md;
// all through BleGate with the registry's NodeLink token, which exists only while no lease is held); the login + status read of an attempt is a Prober (the OwnerSession one is
// prober.dart; tests use fakes). Pages and the app lifecycle tell it what is on screen; the lease registry tells it
// when an operation holds Bluetooth.
import 'dart:async';
import 'dart:typed_data';

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

/// #329 UX plan §4.4: a prober that can read the status page again on a session NodeLink keeps open (the app's
/// SessionProber; the test doubles of [Prober] are not one).
abstract class KeptReader {
  /// §4.1: set once by NodeLink: true = a read of [id] that ends with a body returns its open session in
  /// [Outcome.keep] instead of cleaning up.
  bool Function(String id)? keepFor;

  /// One status read on [h]'s session. Never completes with an error; closes and disposes nothing. It must stop
  /// when [cancelled] completes (it may still return the page it had read).
  Future<Outcome> read(LoginHandoff h, {required Future<void> cancelled});
}

/// The states of a kept link (#329 UX plan §4): parked = token null, NodeLink listens; reading = NodeLink's token,
/// one status read; lent = a lease's token, from `loginFor` returning it until its holder closes it.
enum KeptState { parked, reading, lent }

/// The phone's node records and their file times (A23), read after start-up and after every lease release.
typedef ReadRecords = Future<List<Rec>> Function();

/// #329 rotating identifier (329-rotating-id-plan.md §3.3): the Manufacturer Data of one scan result -> the node of
/// this phone it belongs to, or null. A hint for the order of attempts only.
typedef AdvResolve = String? Function(Uint8List mfr);

/// An [AdvResolve] and what wipes the keys it holds ([close]; the app: Rust's AdvResolver). NodeLink closes a resolver
/// when a newer one replaces it, when its build ended too late, and when it is disposed (code review A M-2 / B m-1).
class Resolver {
  const Resolver(this.resolve, [this.close, this.opened]);
  final AdvResolve resolve;
  final void Function()? close;

  /// How many of the records asked for opened (code review B MINOR-2: the trace says why a node gets no hint);
  /// null when the builder does not say.
  final int? opened;
}

/// Builds a [Resolver] from the records of the nodes [ids] (the app: `buildResolver` in app_link.dart).
typedef ResolverBuilder = Future<Resolver> Function(List<String> ids);

/// #329 PR 3 §2.1: how a flow's login under its lease ended. `noLease`: the lease given is not the registry's current
/// session lease (or was taken back meanwhile), or another login is running.
enum LoginForEnd { ok, identity, refused, notFound, precondition, noLease }

class LoginForResult {
  const LoginForResult(this.end, [this.handoff, this.found = false]);
  final LoginForEnd end;

  /// Only with `notFound` (#329 honest-errors C2): a device that looked like this node was there, but no session
  /// came of it (LoginFor.found). Not authenticated in every case (a 「像 Y」 hint): for the wording only.
  final bool found;

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
    this.buildResolver,
  }) : wall = wall ?? DateTime.now {
    reg.listeners.add(this);
    final Object p = prober;
    // 329-link-per-node.md §3.2: a read keeps its link when this node has none, its record is here, nothing blocks
    // the radio, the app is in the foreground and there is room
    if (p is KeptReader) {
      p.keepFor = (id) =>
          !_kept.containsKey(id) &&
          core.states.containsKey(id) &&
          core.blocked == null &&
          core.fg &&
          _kept.length < keptMax;
    }
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

  /// #329 rotating identifier §3.3: builds the resolver of the scan results' identifiers; started (never awaited)
  /// each time the record list was read. Null = no hints (every node is found the old way).
  final ResolverBuilder? buildResolver;
  Resolver? _resolve; // null until the first build finished: every hint is null
  int _builds = 0, _built = 0; // the last build started / the newest one installed

  void _rebuildResolver() {
    final b = buildResolver;
    if (b == null) return;
    final n = ++_builds;
    final ids = [for (final r in _recs) r.id];
    final t0 = now();
    () async {
      try {
        final r = await b(ids);
        // two builds may overlap: the one of the newer record list stays
        if (_disposed || n < _built) {
          _close(r);
          return;
        }
        _built = n;
        final old = _resolve;
        _resolve = r;
        _close(old);
        trace?.call('adv resolver $n: ${r.opened ?? '?'} of ${ids.length} record(s) opened, ${now() - t0} ms');
      } catch (e) {
        trace?.call('adv resolver $n failed (${e.runtimeType}): the last one stays'); // never the error's text
      }
    }();
  }

  static void _close(Resolver? r) {
    try {
      r?.close?.call();
    } catch (_) {}
  }

  /// The hint of one scan result: null without a resolver, without Manufacturer Data, or when it resolves to none.
  String? _hint(Uint8List? mfr) {
    final r = _resolve;
    if (r == null || mfr == null) return null;
    try {
      return r.resolve(mfr);
    } catch (_) {
      return null;
    }
  }

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

  /// #329 fast retry (329-fast-retry.md §2): a connect whose link fails within [fastMax] is tried once more after
  /// [settle], inside the same [msg2] budget.
  static const fastMax = Duration(milliseconds: 1500);
  static const settle = Duration(milliseconds: 400);
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

  /// D5(c): the team sections (and the read times, review pr6 A-4) of records no longer on the phone go with them.
  void _dropGoneTeams() {
    teams.removeWhere((id, _) => !core.states.containsKey(id));
    readWall.removeWhere((id, _) => !core.states.containsKey(id));
  }

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
  // 329-takeover.md §1.1: the attempt its node's page took over from the cancelled round (only ever compared with
  // [_attempt]); the running attempt's own end; the one acquire call waiting for that end
  Attempt? _det;
  Completer<void>? _ended;
  _Waiter? _waiter;

  /// §1.1 (b): the longest an acquire waits for the attempt in flight (the attempt's own connect-to-msg2 budget).
  static const takeoverWait = Duration(seconds: 8);

  /// The name of the operation waiting for the attempt in flight (the busy line of a call refused meanwhile).
  String? get waitingName => _waiter?.name;

  /// §1.1: the page of [a]'s node is open in the foreground, the radio is usable and the record is there.
  bool _wanted(Attempt a) => _onPage(a.id) && core.blocked == null && core.states.containsKey(a.id);
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
    _rebuildResolver();
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
    final a = _attempt;
    core.setPage(now(), page, node: node);
    // 329-takeover.md §1.1 (a): the attempt in flight to the node whose page opens is taken over, not cancelled: the
    // core no longer runs it, its connect has started, and this page wants it
    if (a != null && identical(_attempt, a) && !identical(core.running, a) && _link != null && _wanted(a)) _det = a;
    _pump(); // 329-link-per-node.md §3.2: a page change closes no kept link
  }

  void background() {
    core.background(now());
    _closeIdle(); // §4.5: kept only in the foreground
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
    if (core.blocked != null) _closeIdle(); // §4.5
    _lfCut(); // a login under a lease ends as precondition at once (core.setRadio), its attempt with it
    _lfPoke();
    _pump();
  }

  /// §4.4 拿到之前: cancel the round, wait until its link is gone (at most 5 s), then the lease. Null = another
  /// operation holds it (the caller shows 「另一個操作還在進行：<名稱>」 with [LeaseRegistry.current]).
  ///
  /// 329-takeover.md §1.1 (b): with [forNode] the node whose page is open and an attempt to it past the start of
  /// its connect, the call first waits for that attempt's end (at most [takeoverWait]), so its session is parked
  /// and the caller's login is given the kept link. One call waits at a time; [gone] = the caller's page is closed
  /// (it then gets null and takes nothing). Without [forNode]: no wait, as before.
  Future<Lease?> acquire(String name, LeaseKind kind, {String? forNode, bool Function()? gone}) async {
    // #329 PR 3 §2.1 (P7): the last release's record read ends first (at most 5 s), so the N9 window of a record
    // written under it is set before the next lease
    final r = _releasing;
    if (r != null) {
      await r.timeout(const Duration(seconds: 5), onTimeout: () {});
    }
    if (reg.current != null) return null;
    final a = _attempt;
    final ended = _ended;
    if (forNode != null && a != null && ended != null && a.id == forNode && _link != null && _wanted(a)) {
      final w = _waiter;
      if (w != null && !w.gone()) return null; // the caller prints busy with [waitingName]
      final me = _waiter = _Waiter(name, gone ?? () => false); // a gone waiter is replaced: it returns null on wake
      final late = Completer<void>();
      final stop = after(takeoverWait, () => late.isCompleted ? null : late.complete());
      await Future.any<void>([ended.future, late.future]);
      stop();
      if (!identical(_waiter, me)) return null; // replaced, or disposed
      _waiter = null;
      // a closed page's call does not cancel the round or take a lease
      if (_disposed || me.gone()) return null;
      if (reg.current != null) return null;
    }
    core.acquireLease(now());
    // #329 UX plan §4.2: a kept link that is reading goes (the flow logs in from the start); a parked one stays for
    // a session lease's loginFor and goes for a raw lease (an older page uses the radio itself)
    final closes = <Future<void>>[];
    for (final e in _kept.entries.toList()) {
      final st = e.value.st;
      if (st == KeptState.reading || (st == KeptState.parked && kind == LeaseKind.raw)) closes.add(_closeKept(e.key));
    }
    // the round's attempt ends before the wait: it would connect again once these links are gone (review 272e0e2 C-1)
    _abort();
    // the lease is given with these links gone and their sessions disposed (bounded as the wait in _dropAll)
    await Future.wait(closes).timeout(const Duration(seconds: 5), onTimeout: () => const []);
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
    if (!mine()) {
      _closeKept(id);
      return const LoginForResult(LoginForEnd.noLease);
    }
    if (core.blocked != null) {
      _closeIdle(); // #329 UX plan §4.2: a check failed
      return const LoginForResult(LoginForEnd.precondition);
    }
    // #329 UX plan §4.2: after the checks every login runs, the kept link of this node is lent when its page is
    // open; from any other page it is closed and the login takes the existing path. The links kept to other nodes
    // stay (329-link-per-node.md §3.2)
    final kept = _kept[id];
    if (kept != null && kept.st == KeptState.parked) {
      if (_onPage(id)) {
        try {
          gate.pass(kept.h.link, lease.token);
          trace?.call(mask('loginFor $id -> ok (kept link)'));
          return LoginForResult(LoginForEnd.ok, _lend(kept.h, lease));
        } on Refused {
          await _closeKept(id); // not up: the existing path
        }
      } else {
        await _closeKept(id);
      }
    }
    final early = <String, String?>{}; // address -> its last hint, in the order first seen
    final gen = _lfGen;
    void seen(String a, Uint8List? mfr) {
      if (gen != _lfGen) return;
      final l = _lf;
      final h = _hint(mfr);
      if (l == null) {
        early[a] = h; // seen before the login's clock started
      } else if (l.onScan(now(), a, hint: h)) {
        _lfPoke();
      }
    }

    // the 60 s start when the scan really starts: a wait for a scan slot (4 in 30 s) is not counted
    await _lfStartScan(lease, seen);
    if (!mine()) return const LoginForResult(LoginForEnd.noLease);
    final l = _lf = core.loginFor(now(), id, clearNotY: clearNotY);
    for (final e in early.entries) {
      l.onScan(now(), e.key, hint: e.value);
    }
    while (true) {
      if (_disposed || !mine()) return const LoginForResult(LoginForEnd.noLease);
      l.tick(now());
      if (l.done) break;
      if (_lfScan == null && !_lfScanStarting && _lfScanWait == null) unawaited(_lfStartScan(lease, seen));
      final a = gate.active == 0 ? l.next(now()) : null;
      if (a != null) {
        final o = await _lfAttempt(p, lease, l, a);
        l.result(now(), a, o);
        final h = o.extra;
        if (h is LoginHandoff) {
          if (l.end == LoginEnd.ok && mine() && !_disposed) return LoginForResult(LoginForEnd.ok, _lend(h, lease));
          await h.close(); // logged in, but the login was over meanwhile (60 s, a precondition, the lease)
        }
        continue;
      }
      final w = l.wakeAt(now());
      // a link still closing is waited for in short steps; otherwise the next deadline or an event (an address, the
      // radio, the lease)
      final ms = gate.active > 0 ? 100 : (w == null ? null : w - now());
      await _lfSleep(ms);
    }
    trace?.call(mask('loginFor $id -> ${l.end!.name}'));
    return LoginForResult(
        switch (l.end!) {
          LoginEnd.ok => LoginForEnd.notFound, // an ok without a hand-off cannot happen: never claim a login
          LoginEnd.identity => LoginForEnd.identity,
          LoginEnd.refused => LoginForEnd.refused,
          LoginEnd.notFound => LoginForEnd.notFound,
          LoginEnd.precondition => LoginForEnd.precondition,
        },
        null,
        l.end == LoginEnd.notFound && l.found);
  }

  Future<void> _lfSleep(int? ms) async {
    final w = _lfWake = Completer<void>();
    _lfTimer?.call();
    _lfTimer = ms == null ? null : after(Duration(milliseconds: ms < 0 ? 0 : ms), _lfPoke);
    await w.future;
  }

  Future<void> _lfStartScan(Lease lease, void Function(String, Uint8List?) seen) async {
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
    // the 60 s cut the running attempt too (code-1 A-m6)
    final left = l.start + LoginFor.budget - now();
    final stopBudget = after(Duration(milliseconds: left < 0 ? 0 : left), () {
      if (!cancel.isCompleted) cancel.complete();
    });
    // 329-link-per-node.md §3.3: room for this link first; the login may be over after that wait
    await _makeRoom(cancel.future);
    if (cancel.isCompleted || !identical(reg.current, lease) || !lease.valid || _disposed) {
      stopBudget();
      if (identical(_lfCancel, cancel)) _lfCancel = null;
      return const Outcome(Res.noResponse);
    }
    final due = Completer<void>();
    final stopDue = after(msg2, () => due.isCompleted ? null : due.complete());
    final t0 = now();
    GateLink? link;
    Outcome o;
    var retried = false;
    try {
      final c = await _connect(lease.token, a, due.future, cancel.future, 'loginFor',
          still: () => identical(reg.current, lease) && lease.valid && !_disposed, onLink: (l) => link = l);
      retried = c.retried;
      o = (!c.up || cancel.isCompleted)
          ? const Outcome(Res.noResponse)
          : await p.probe(c.link, a.id, due: due.future, cancelled: cancel.future);
    } on Refused {
      o = const Outcome(Res.noResponse);
    } catch (e) {
      o = const Outcome(Res.noResponse); // one attempt's exception ends that attempt only
      trace?.call(mask('loginFor $a: ${e.runtimeType} $e'));
    }
    stopDue();
    stopBudget();
    if (identical(_lfCancel, cancel)) _lfCancel = null;
    trace?.call(mask('loginFor $a result=${o.res.name} after ${now() - t0}ms${retried ? ' retried' : ''}'));
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

  // ---- the kept links (#329 UX plan §4; one per node: 329-link-per-node.md §3) -----------------------------------

  /// §4.4: one status read on a kept link (its two requests and the hint / team step) has this long.
  static const keptReadMax = Duration(seconds: 5);

  /// 329-link-per-node.md §3.3: NodeLink's own links (parked, reading, lent, connecting, closing) are never more.
  static const keptMax = 2;

  /// §3.2-4: a kept link is read again no sooner than this after its last read ended or it was parked.
  static const readGap = 1100;

  /// Node id -> its kept link. One writer: NodeLink ([_park], [_lend], [_forget]); the core gets the ids after every
  /// change ([_syncKept]).
  final Map<String, _Kept> _kept = {};
  Cancel? _readWake; // the timer of the next kept read's [readGap]

  @visibleForTesting
  LoginHandoff? kept(String id) => _kept[id]?.h;
  @visibleForTesting
  KeptState? keptState(String id) => _kept[id]?.st;
  @visibleForTesting
  int get keptCount => _kept.length;

  void _syncKept() => core.setKept(_kept.keys.toSet());

  /// A flow's login is given the kept link of [id] only when that node's page is open in the foreground.
  bool _onPage(String id) => core.fg && core.page == Page.node && core.pageNode == id;

  /// §4.1 Park, one synchronous step: [h] becomes its node's kept link, parked (null). Not null = not parked and
  /// NodeLink holds no reference (a frame the inbox was holding closed it, or the gate refused a link that is not
  /// up): the future of that close, which ends when the link is gone (§4.3: what the holder's `close()` waits for).
  Future<void>? _park(LoginHandoff h) {
    final id = h.id;
    final e = _kept[id] ??= _Kept(h);
    e.h = h;
    e.st = KeptState.parked;
    e.lease = null;
    e.readEnd = now();
    _syncKept();
    Future<void>? closing;
    void gone() {
      if (identical(_kept[id], e) && identical(e.h.link, h.link) && e.st != KeptState.lent) closing = _closeKept(id);
    }

    e.sub ??= h.link.state.listen((up) {
      if (!up) gone();
    }, onError: (Object _) => gone(), onDone: gone);
    // nothing is expected on a parked link: a frame or a subscription error closes it (never parsed)
    h.inbox.handle((_) => gone(), (_) => gone());
    if (!identical(_kept[id], e) || !identical(e.h, h)) return closing ?? h.destroy().then(_pumpAfterClose);
    try {
      gate.pass(h.link, null);
    } on Refused {
      _forget(id);
      return h.destroy().then(_pumpAfterClose);
    }
    return null;
  }

  /// A kept link is gone: plan again. A holder's `close()` waits for these futures (§4.3) and they mean "the link
  /// is gone" only: what [_pump] throws is not their result; it goes to the zone, as it does from a timer.
  void _pumpAfterClose(void _) {
    try {
      _pump();
    } catch (e, st) {
      Zone.current.handleUncaughtError(e, st);
    }
  }

  /// Drop the reference: [id]'s kept link is nobody's here from now on. A read on it is cancelled.
  void _forget(String id) {
    final e = _kept.remove(id);
    if (e == null) return;
    e.sub?.cancel();
    e.sub = null;
    final c = e.cancel;
    e.cancel = null;
    if (c != null && !c.isCompleted) c.complete();
    _syncKept();
  }

  /// §4.5 close: a parked or reading kept link is forgotten at once and destroyed (read cancelled, session disposed,
  /// link closed); then plan again. A lent link is its holder's: nothing.
  Future<void> _closeKept(String id) {
    final e = _kept[id];
    if (e == null || e.st == KeptState.lent) return Future.value();
    _forget(id);
    // the gate counts the link as closing from here on: destroy() unsubscribes first, and until that returned the
    // link would still be open and parked, which nothing waits for (review 009d592 A-1 / B-1)
    unawaited(e.h.link.close().catchError((Object _) {}));
    return e.h.destroy().then(_pumpAfterClose);
  }

  /// §4.5: every kept link that is not lent is closed (the background, a blocked radio).
  void _closeIdle() {
    for (final id in _kept.keys.toList()) {
      _closeKept(id);
    }
  }

  /// 329-link-per-node.md §3.3, where NodeLink is about to connect: with [keptMax] links kept the first parked one
  /// is closed; then wait until no link is in use or closing (the gate counts a closing link for at most 5 s).
  /// Ends early when [cancelled] completes; the caller checks its attempt again after this.
  Future<void> _makeRoom(Future<void> cancelled) async {
    var cut = false;
    unawaited(cancelled.then((_) => cut = true));
    if (_kept.length >= keptMax) {
      for (final e in _kept.entries.toList()) {
        if (e.value.st == KeptState.parked) {
          _closeKept(e.key); // its link counts as closing from here on: the wait below sees it
          break;
        }
      }
    }
    for (var i = 0; i < 60 && gate.active > 0 && !cut && !_disposed; i++) {
      final c = Completer<void>();
      void done([void _]) => c.isCompleted ? null : c.complete();
      final stop = after(const Duration(milliseconds: 100), done);
      unawaited(cancelled.then(done));
      await c.future;
      stop();
    }
  }

  /// §4.2: the handoff a flow gets: a new object over [h]'s link and session with NodeLink's hook; state lent.
  /// NodeLink listens to nothing while it is lent.
  LoginHandoff _lend(LoginHandoff h, Lease lease) {
    final e = _kept[h.id] ??= _Kept(h);
    e.sub?.cancel();
    e.sub = null;
    h.inbox.handle(null, null);
    final n = h.again(hook: _giveBack);
    e.h = n;
    e.st = KeptState.lent;
    e.lease = lease;
    _syncKept();
    return n;
  }

  /// §4.3 the hook: the holder closed [h]. Parked again only when the session only read, [h] is still the link lent
  /// here, nothing blocks the radio and the app is in the foreground; anything else destroys it.
  Future<void> _giveBack(LoginHandoff h, {required bool reusable}) {
    final e = _kept[h.id];
    if (e != null && identical(e.h, h) && e.st == KeptState.lent) {
      if (reusable && core.blocked == null && core.fg) {
        return _park(h.again()) ?? Future.value();
      }
      _forget(h.id);
    }
    return h.again().destroy().then(_pumpAfterClose);
  }

  /// §4.4: one status read on the parked link [e], for the active round.
  void _keptRead(_Kept e) {
    final k = e.h;
    final id = k.id;
    final Object p = prober;
    final t = reg.nodeLinkToken;
    if (p is! KeptReader || t == null) {
      _closeKept(id);
      return;
    }
    try {
      gate.pass(k.link, t);
    } on Refused {
      _closeKept(id); // not up
      return;
    }
    e.st = KeptState.reading;
    final cancel = e.cancel = Completer<void>();
    var late = false;
    final stop = after(keptReadMax, () {
      late = true;
      if (!cancel.isCompleted) cancel.complete();
    });
    bool mine() => identical(_kept[id], e) && identical(e.h, k) && e.st == KeptState.reading;
    p.read(k, cancelled: cancel.future).then((o) {
      stop();
      // closed meanwhile (the background, link down, a lease): the outcome is dropped, even a body
      if (!mine()) return;
      e.cancel = null;
      if (late || (o.res != Res.body && o.res != Res.errorCode)) {
        _closeKept(id); // the round goes on by a new connect
        _pump();
        return;
      }
      try {
        final t = now();
        if (core.keptRead(t, id, k.link.address, o)) _noteRead(id, o, t);
        _park(k);
        _pump();
      } catch (_) {
        // as a reader that fails: the link is not left in state reading (the error itself goes on to the zone)
        if (identical(_kept[id], e)) _closeKept(id);
        rethrow;
      }
    }, onError: (Object _) {
      // a reader that fails (KeptReader.read never should): the link is not left in state reading
      stop();
      if (!mine()) return;
      _closeKept(id);
      _pump();
    });
  }

  /// The wall time and the team section of a read the core took (a body only; #329 PR 6 D5(c)).
  void _noteRead(String id, Outcome o, int t) {
    if (o.res != Res.body) return;
    final w = readWall[id] = wall();
    final team = o.team;
    if (team is TeamSeen) teams[id] = TeamRead(team.netId, team.view, t, w);
  }

  /// §4.5: a kept link's record is gone (checked after each new record list).
  void _keptRecordCheck() {
    for (final id in _kept.keys.toList()) {
      if (!core.states.containsKey(id)) _closeKept(id);
    }
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
    // #329 UX plan §4.5: the lease a link was lent under is gone (the gate has closed that link: it listens first)
    for (final e in _kept.entries.toList()) {
      if (e.value.st == KeptState.lent && identical(e.value.lease, l)) _forget(e.key);
    }
    final before = _recs;
    _releasing = readRecords().then<List<Rec>?>((r) => r, onError: (Object _) => null).then((recs) {
      if (_disposed) return;
      final written = {..._writtenWaiting, ...l.writtenNodes};
      if (recs != null) {
        if (l.kind == LeaseKind.raw) written.addAll(_changedIds(before, recs));
        _recs = recs;
        _rebuildResolver(); // a claim under the lease added a record, a removal took one away
      }
      if (reg.current != null) {
        // another lease was taken while the records were read: the core stays leased (review pr1 A-M5 / B-M2);
        // the written records wait for that lease's release
        if (recs != null) core.setRecords(recs);
        _keptRecordCheck();
        _dropGoneTeams(); // #329 PR 6 D5(c): node/<id> removed -> its team section goes
        _writtenWaiting.addAll(written);
        return;
      }
      _writtenWaiting.clear();
      core.releaseLease(now(), written: written, recs: recs); // records unreadable: the old list (A-m6)
      _keptRecordCheck();
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
    // 329-takeover.md §1.1 (a): except the attempt its node's page took over, while that page still wants it
    if (a != null && !identical(core.running, a) && !(identical(_det, a) && _wanted(a))) _abort();
    _readWake?.call();
    _readWake = null;
    if (core.roundActive) {
      // #329 UX plan §4.4 / 329-link-per-node.md §3.2-4: the round's read of a node with a kept link is one status
      // read on that link: one at a time, while no link is in use, [readGap] after its last one
      var needs = false; // a parked link the round still has to read: no attempt before it
      int? due;
      for (final e in _kept.values.toList()) {
        if (e.st != KeptState.parked || !core.keptNeeds(e.h.id)) continue;
        needs = true;
        if (_attempt != null || gate.active > 0) continue;
        final at = e.readEnd + readGap;
        if (at <= t) {
          _keptRead(e);
        } else if (due == null || at < due) {
          due = at;
        }
      }
      if (due != null && _attempt == null && gate.active == 0) {
        _readWake = after(Duration(milliseconds: due - t), _pump);
      }
      // §3.4: a scan only when a target of the round has no kept link; it then runs until the round ends
      if (_scan == null && !_scanStarting && _scanWait == null && core.roundTargets.any((id) => !_kept.containsKey(id))) {
        _startScan();
      }
      // the next attempt starts only once no link is in use or closing (review pr1 B-m1) and every parked link of
      // the round was read
      if (_attempt == null && _scan != null && gate.active == 0 && !needs) {
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
      s = await gate.scan(reg.nodeLinkToken, (address, mfr) {
        if (_disposed) return;
        if (core.onScan(now(), address, hint: _hint(mfr)) && _attempt == null) _pump();
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
    // 329-takeover.md §1.1: this attempt's own end, for an acquire that waits for it; completed once, here or by
    // [_abort]; a late end of an aborted attempt never touches the next one's
    final ended = _ended = Completer<void>();
    void end() {
      if (!ended.isCompleted) ended.complete();
      if (identical(_ended, ended)) _ended = null;
    }

    try {
      // 329-link-per-node.md §3.3: room for this link first; the round may have dropped the attempt in that wait
      await _makeRoom(cancel.future);
      if (!identical(_attempt, a) || cancel.isCompleted || _disposed) return;
      // §4.3.3-3: one 8 s budget from the start of the connect to msg2, on the injected clock
      final due = Completer<void>();
      final stopDue = after(msg2, () => due.isCompleted ? null : due.complete());
      final t0 = now();
      var tUp = -1;
      GateLink? mine;
      Outcome o;
      _Connected? c;
      try {
        // §2: `mine` / `_link` always point at the attempt's current link (the second one after a retry), so the end
        // below and [_abort] close it; never null in the retry window (329-fast-retry.md §4)
        final k = c = await _connect(reg.nodeLinkToken, a, due.future, cancel.future, 'attempt',
            still: () => identical(_attempt, a) && !_disposed, onLink: (l) => mine = _link = l);
        tUp = k.up ? now() - k.t : -1;
        if (!k.up || cancel.isCompleted) {
          o = const Outcome(Res.noResponse);
        } else {
          o = await prober.probe(k.link, a.id, due: due.future, cancelled: cancel.future);
        }
      } on Refused {
        o = const Outcome(Res.noResponse);
      } catch (e) {
        o = const Outcome(Res.noResponse); // one attempt's exception ends that attempt only (§4.3.3-4, F50)
        trace?.call(mask('attempt $a: ${e.runtimeType} $e'));
      }
      stopDue();
      final r = c;
      final downs = r != null && r.retried
          ? ' retried downs=${[for (final d in gate.codelessDowns(a.addr)) if (d >= r.failedAt) '+${d - r.failedAt}'].join(',')}'
          : '';
      trace?.call(mask('attempt $a connected=${tUp}ms result=${o.res.name} after ${now() - t0}ms$downs'));
      // #329 UX plan §4.1: a read that returns its open session ([Outcome.keep]) keeps its link too: from here it is
      // parked or destroyed, never left
      final kp = o.keep;
      final keep = kp is LoginHandoff ? kp : null;
      // close this attempt's own link only: a late end never closes the next attempt's (review pr1 A-m1 / B-m1)
      if (keep == null) await mine?.close();
      if (identical(_link, mine)) _link = null;
      if (!identical(_attempt, a)) {
        await keep?.destroy();
        return; // aborted: the core no longer waits for it
      }
      _attempt = null;
      _cancel = null;
      final det = identical(_det, a);
      if (det) _det = null;
      // one clock value for the core's readAt and the team section's (#329 PR 6 §14: a second now() would differ)
      final t = now();
      // 329-takeover.md §1.1 (a): the core does not know a detached attempt; its answer enters the round that is
      // active now as a read without an attempt (a body or an error code; anything else is not recorded)
      final accepted = det
          ? (o.res == Res.body || o.res == Res.errorCode) && core.keptRead(t, a.id, a.addr, o)
          : core.result(t, a, o);
      // the wall time of a read; a 2' is a read too (its own time, not the last body's: PR 2 review r2 D-m6)
      // (review pr6 A-4: only a read the core took; a dropped one leaves no time behind, e.g. for a record gone)
      // #329 PR 6 D5(c): the team section of this read, only when the core took the read (not a cancelled round, not
      // a record gone, not an error-code answer), with the very readAt / readWall just written for it
      if (accepted) _noteRead(a.id, o, t);
      if (keep != null) {
        if (!accepted ||
            (det && !_wanted(a)) ||
            core.blocked != null ||
            !core.fg ||
            _kept.containsKey(keep.id) ||
            _kept.length >= keptMax) {
          keep.destroy().then((_) => _pump()); // a late result, the record went; or no place for it any more
        } else {
          unawaited(_park(keep)); // not parked (the link is not up): destroyed there
        }
      }
      end(); // a waiting acquire resumes after this synchronous tail (a completer's listeners are microtasks)
      _pump();
    } finally {
      end(); // the early returns and an exception
    }
  }

  /// #329 fast retry (329-fast-retry.md §2): connect to [a]'s address and wait for the link's first event; a link that
  /// fails (not [due], not [cancel]) within [fastMax] is closed, and after [settle] — when [still] holds and neither
  /// [due] nor [cancel] came — connected once more, inside the same budget. Never a third connect. [onLink] gets every
  /// link the moment it is made (the caller closes the last one). A [Refused] from the gate goes to the caller.
  Future<_Connected> _connect(Token? token, Attempt a, Future<void> due, Future<void> cancel, String what,
      {required bool Function() still, required void Function(GateLink) onLink}) async {
    var done = false; // due or cancel came
    unawaited(due.then((_) => done = true));
    unawaited(cancel.then((_) => done = true));
    Future<int> first(GateLink l) => Future.any<int>([
          // design 329-ble-settle.md §2.1: the first link event, not the first `true`: a failure ends the attempt now
          l.state.first.then((s) => s ? 1 : 0, onError: (Object _) => 0),
          due.then((_) => -1),
          cancel.then((_) => -1),
        ]);
    final t0 = now();
    var link = gate.connect(token, a.addr, timeout: msg2);
    onLink(link);
    var e = await first(link);
    if (e != 0 || done || now() - t0 >= fastMax.inMilliseconds) {
      return _Connected(link, e == 1 && !done, t0, false, 0);
    }
    final failedAt = now();
    trace?.call(mask('$what $a link failed after ${failedAt - t0}ms, connecting once more'));
    await link.close(); // down already: no wait (ble_gate.dart _close)
    final waited = Completer<void>();
    final stop = after(settle, () => waited.isCompleted ? null : waited.complete());
    await Future.any<void>([waited.future, due, cancel]);
    stop();
    // §2 step 3 -> 4: the checks and the connect in one synchronous step
    if (done || !still()) return _Connected(link, false, t0, false, failedAt);
    link = gate.connect(token, a.addr, timeout: msg2);
    onLink(link);
    final t1 = now();
    trace?.call(mask('$what $a second connect +${t1 - failedAt}ms'));
    e = await first(link);
    return _Connected(link, e == 1 && !done, t1, true, failedAt);
  }

  void _abort() {
    _attempt = null;
    _det = null;
    final c = _cancel;
    _cancel = null;
    if (c != null && !c.isCompleted) c.complete();
    final e = _ended;
    _ended = null;
    if (e != null && !e.isCompleted) e.complete();
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
    // (#329 UX plan §4.6: the parked kept links stay and are not waited for)
    for (var i = 0; i < 50 && gate.active > 0; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
  }

  Future<void> dispose() async {
    _disposed = true;
    _waiter = null; // a waiting acquire wakes (the abort below) and returns null
    _close(_resolve);
    _resolve = null;
    _lfPoke();
    final c = _lfCancel;
    if (c != null && !c.isCompleted) c.complete();
    reg.listeners.remove(this);
    _timer?.call();
    _readWake?.call();
    // #329 UX plan §4.5: a lent link is its holder's (forgotten: never parked on return); any other is closed
    for (final e in _kept.entries.toList()) {
      e.value.st == KeptState.lent ? _forget(e.key) : _closeKept(e.key);
    }
    await _dropAll();
    await _changed.close();
  }
}

/// One kept link (329-link-per-node.md §3.2): the handoff, its state, the lease it is lent under, NodeLink's
/// subscription to the link's state (from the first park until it is lent or closed), what cancels a read in
/// progress, and when it was last parked.
class _Kept {
  _Kept(this.h);
  LoginHandoff h;
  KeptState st = KeptState.parked;
  Lease? lease;
  StreamSubscription<bool>? sub;
  Completer<void>? cancel;
  int readEnd = 0;
}

/// 329-takeover.md §1.1 (b): the acquire call that waits for the attempt in flight.
class _Waiter {
  _Waiter(this.name, this.gone);
  final String name;
  final bool Function() gone;
}

/// #329 fast retry: what [NodeLink._connect] ended with. [t] = the start of the connect that gave [up] (the second one
/// after a retry); [failedAt] = the first link's failure, 0 when there was none.
class _Connected {
  _Connected(this.link, this.up, this.t, this.retried, this.failedAt);
  final GateLink link;
  final bool up, retried;
  final int t, failedAt;
}
