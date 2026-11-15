// #329 design §4.3 (329-app-uiux.md v12.1): the automatic-read scheduler of NodeLink, as pure Dart.
// No BLE and no timers: time comes in as `now` (ms, monotonic clock) and the driver (NodeLink, or the test simulator)
// reports what it sees. The driver asks `next(now)` for the one attempt to start, reports its outcome with `result`,
// and calls `tick(now)` at `wakeAt(now)` or after any event. Nothing here writes a record; the memos are memory only.

/// The constants of §4.3 (ms).
class Params {
  const Params({
    this.window = 30000,
    this.cap = 90000,
    this.gap = 6000,
    this.perAddr = 2,
    this.early = 10000,
    this.interval = 60000,
    this.fresh = 300000,
    this.unseen = 1200000,
    this.n9 = 30000,
    this.earlyMax = 3,
    this.afterLease = 6000,
  });
  final int window, cap, gap, perAddr, early, interval, fresh, unseen, n9, earlyMax, afterLease;
}

/// One record of this phone: a node it owns. `mtime` = the record file's last write (§4.3.3-6, A23).
class Rec {
  const Rec(this.id, this.mtime);
  final String id;
  final int mtime;
}

/// The end of one attempt (§4.3.3-4). `body` carries the status view (Rust's row; E_UNSUPPORTED is a body, row 1).
enum Res { body, errorCode, undecryptable, certRejected, refusedForbidden, refusedOther, noResponse, broken }

class Outcome {
  const Outcome(this.res, [this.view = '']);
  final Res res;
  final String view;
}

class Attempt {
  const Attempt(this.addr, this.id);
  final String addr, id;
  @override
  String toString() => '$addr×$id';
}

enum Kind { unread, read, unreachable }

enum Why { notFound, identity, refused, bluetoothOff, noPermission, keys }

/// A round's conclusion for one target (§4.3.4).
enum Concl { read, unchanged, reason, notFound, notYet, queued }

enum Page { home, node, other }

class NodeState {
  Kind kind = Kind.unread;
  Why? why;
  String view = '';
  int? readAt; // monotonic
  int? lastRead; // monotonic, for the order; null = not read in this run
  bool stale = false; // set on entering the background (§4.3.1 「新鮮」 (2))
  bool responded = false; // logged in this run but only error codes so far
  int miss = 0; // consecutive 沒找到
  int same = 0; // consecutive 不變 (full rounds only)
  int notYetRun = 0; // consecutive 還沒輪到 (§4.3.5 「連續兩輪以上」)
  Concl? last;
}

class _T {
  int n = 0; // attempts started this round
  bool body = false, err = false;
  Why? why;
}

class _Round {
  _Round(this.id, this.targets, this.early, this.start, this.noRespLast);
  final int id;
  final Set<String> targets;
  final bool early;
  final int start;
  final Set<String> noRespLast;
  final List<String> seen = [];
  final Map<String, int> count = {}, freeAt = {};
  final Set<String> exhausted = {}, noResp = {}, tried = {}, retry = {};
  final Map<String, _T> t = {};
  Attempt? running;
  bool lastWasKnown = false;
}

class NodeLinkCore {
  NodeLinkCore(List<Rec> recs, {this.p = const Params()}) {
    for (final r in recs) {
      _recs[r.id] = r;
      states[r.id] = NodeState();
    }
  }
  final Params p;
  final Map<String, Rec> _recs = {};
  final Map<String, NodeState> states = {};

  // memos (§4.3.3-5)
  final Map<String, String> isY = {};
  final Map<String, Set<String>> notY = {};
  final Map<String, int> lastSeen = {};
  final Map<String, int> writtenAt = {};

  // scheduling (§4.3.2)
  Page page = Page.other;
  String? pageNode;
  bool fg = true, lease = false, bt = true, perm = true, keys = true, started = false;
  final List<(int, Set<String>)> _fullEnds = [];
  int? fullDue, earlyDue, leaseDue;
  Set<String> _earlyTargets = {};
  int earlyCount = 0;
  int roundsRun = 0;
  int scanStarts = 0;
  int _nextId = 0;
  _Round? _round;
  bool get roundActive => _round != null;
  Set<String> _noRespLast = {};
  final List<String> log = [];

  // ---- queries -------------------------------------------------------------------------------------------------

  /// 「不是 Y」 for this address (callers have already skipped addresses with any 「是」 memo, §4.3.3-5).
  bool isNot(String a, String id) => notY[a]?.contains(id) ?? false;

  /// 「新鮮」 (§4.3.1): the only predicate that may give a colour.
  bool fresh(String id, int now) {
    final s = states[id]!;
    return s.kind == Kind.read && !s.stale && s.readAt != null && now - s.readAt! < p.fresh;
  }

  bool get roundIsEarly => _round?.early ?? false;
  Attempt? get running => _round?.running;

  Set<String> get _pageTargets => switch (page) {
        Page.home => _recs.keys.toSet(),
        Page.node => _recs.containsKey(pageNode) ? {pageNode!} : <String>{},
        Page.other => <String>{},
      };

  bool get _eligible => started && fg && !lease && page != Page.other;

  int? _lastFullEnd(Set<String> targets) {
    for (final e in _fullEnds.reversed) {
      if (e.$2.containsAll(targets)) return e.$1;
    }
    return null;
  }

  // ---- events --------------------------------------------------------------------------------------------------

  void startup(int now, Page pg, {String? node}) {
    started = true;
    page = pg;
    pageNode = node;
    _begin(now, early: false);
  }

  void setPage(int now, Page pg, {String? node}) {
    if (pg == page && node == pageNode) return;
    _cancel(now);
    page = pg;
    pageNode = node;
    earlyDue = null;
    fullDue = null;
    if (!_eligible) return;
    if (pg == Page.node) return _begin(now, early: false); // X33: entering a node page reads it
    final last = _lastFullEnd(_pageTargets);
    if (last == null || now - last >= p.interval) {
      _begin(now, early: false);
    } else {
      fullDue = last + p.interval;
    }
  }

  void background(int now) {
    _cancel(now);
    fg = false;
    for (final s in states.values) {
      if (s.kind == Kind.read) s.stale = true;
    }
    _fullEnds.clear();
    earlyCount = 0;
    earlyDue = null;
    fullDue = null;
  }

  void foreground(int now) {
    if (fg) return; // already in the foreground: not a return from the background (code-1 B-m3)
    fg = true;
    if (_eligible) _begin(now, early: false);
  }

  void acquireLease(int now) {
    _cancel(now);
    lease = true;
    earlyDue = null;
    fullDue = null;
  }

  /// The phone's node records changed (a claim added one, a removal deleted one): called with the new list and file
  /// times after every lease release (§4.3.3-6). Memos and states of the records that stay are kept (T19).
  void setRecords(List<Rec> recs) {
    final ids = {for (final r in recs) r.id};
    for (final id in _recs.keys.toList()) {
      if (ids.contains(id)) continue;
      _recs.remove(id);
      states.remove(id);
      isY.removeWhere((_, v) => v == id);
      for (final s in notY.values) {
        s.remove(id);
      }
      _earlyTargets.remove(id);
    }
    for (final r in recs) {
      _recs[r.id] = r;
      states.putIfAbsent(r.id, NodeState.new);
    }
  }

  /// Release; `written` = node records written or deleted under it (§4.4 RecordWriter); `recs` = the record list
  /// read again after it.
  void releaseLease(int now, {Set<String> written = const {}, List<Rec>? recs}) {
    lease = false;
    if (recs != null) setRecords(recs);
    for (final id in written) {
      writtenAt[id] = now;
      isY.removeWhere((_, v) => v == id);
      for (final s in notY.values) {
        s.remove(id);
      }
      final st = states[id];
      if (st != null && st.why == Why.identity) {
        st.kind = Kind.unread;
        st.why = null;
      }
    }
    if (fg) leaseDue = now + p.afterLease;
  }

  void refresh(int now) {
    notY.clear(); // identity is not ended here: the retry this allows ends it by a read, or sets it again
    final r = _round;
    if (r != null) {
      if (!r.early) return; // X2: no second round
      _cancel(now);
    }
    if (_eligible) _begin(now, early: false);
  }

  void setRadio(int now, {bool? bluetooth, bool? permission, bool? keyOk}) {
    final was = bt && perm && keys;
    bt = bluetooth ?? bt;
    perm = permission ?? perm;
    keys = keyOk ?? keys;
    final ok = bt && perm && keys;
    if (!ok) {
      _cancel(now);
    } else if (!was && _eligible) {
      _begin(now, early: false);
    }
  }

  /// One BLE address seen by this round's scan (the driver reports each visible address; repeats are fine).
  void onScan(int now, String a) {
    lastSeen[a] = now;
    final r = _round;
    if (r == null || r.seen.contains(a)) return;
    r.seen.add(a);
  }

  // ---- rounds --------------------------------------------------------------------------------------------------

  /// §4.3.3-1: Bluetooth off, no permission or keys unusable make every target unreachable for that reason. It is an
  /// overlay: the node states underneath (身分不符 above all) are kept and shown again when it clears (code-1 A-M2).
  Why? get blocked => !bt ? Why.bluetoothOff : (!perm ? Why.noPermission : (!keys ? Why.keys : null));

  /// What the screen shows as the reason, if any: the overlay first, then the node's own state.
  Why? shownWhy(String id) => blocked ?? (states[id]!.kind == Kind.unreachable ? states[id]!.why : null);

  void _begin(int now, {required bool early, Set<String>? only}) {
    if (!_eligible) return;
    if (blocked != null) return;
    // memos of addresses not seen for 20 minutes go (§4.3.3-5)
    final old = lastSeen.entries.where((e) => now - e.value >= p.unseen).map((e) => e.key).toList();
    for (final a in old) {
      isY.remove(a);
      notY.remove(a);
      lastSeen.remove(a);
    }
    final targets = only ?? _pageTargets;
    final r = _Round(_nextId++, targets, early, now, _noRespLast);
    for (final id in targets) {
      r.t[id] = _T();
    }
    _round = r;
    roundsRun++;
    scanStarts++;
    if (early) {
      earlyDue = null;
    } else {
      fullDue = null;
      leaseDue = null;
      earlyDue = null;
    }
    log.add('${_s(now)} round ${r.id} ${early ? 'early' : 'full'} ${targets.toList()..sort()}');
  }

  void _cancel(int now) {
    final r = _round;
    if (r == null) return;
    log.add('${_s(now)} round ${r.id} cancelled');
    _round = null;
  }

  /// Order inside a queue: turns of two attempts (a target tries up to two addresses, then the next one has its turn,
  /// so none starves another); inside a turn, not read in this run first (newest record file first), then the longest
  /// since the last read.
  int _cmp(_Round r, String x, String y) {
    final c = (r.t[x]!.n ~/ 2).compareTo(r.t[y]!.n ~/ 2);
    if (c != 0) return c;
    final sx = states[x]!, sy = states[y]!;
    if ((sx.lastRead == null) != (sy.lastRead == null)) return sx.lastRead == null ? -1 : 1;
    if (sx.lastRead == null) {
      final m = _recs[y]!.mtime.compareTo(_recs[x]!.mtime);
      return m != 0 ? m : x.compareTo(y);
    }
    final d = sx.lastRead!.compareTo(sy.lastRead!);
    return d != 0 ? d : x.compareTo(y);
  }

  String? _knownAddr(_Round r, String id) {
    for (final a in r.seen) {
      if (isY[a] == id) return a;
    }
    return null;
  }

  bool _open(_Round r, String a, int now) => (r.count[a] ?? 0) < p.perAddr && (r.freeAt[a] ?? 0) <= now;

  bool _canTry(_Round r, String a, String id) {
    final key = '$a|$id';
    return !r.tried.contains(key) || r.retry.contains(key);
  }

  /// The addresses this target may still try this round, in order (§4.3.3-6). A target with a 「是 Y」 memo waits for
  /// that address during the first 30 s window and only then looks at unknown addresses (its address may have changed).
  List<String> _candidates(_Round r, String id, {required bool lookOk}) {
    final t = r.t[id]!;
    if (t.body || t.why != null) return const [];
    final k = _knownAddr(r, id);
    if (k != null) return _canTry(r, k, id) ? [k] : const [];
    if (!lookOk && isY.containsValue(id)) return const [];
    final order = [...r.seen.where((a) => !r.noRespLast.contains(a)), ...r.seen.where(r.noRespLast.contains)];
    return [
      for (final a in order)
        if (isY[a] == null && !isNot(a, id) && !r.exhausted.contains(a) && _canTry(r, a, id)) a
    ];
  }

  /// The next attempt to start, or null. Two queues take turns: targets on their known address (「是 Y」 scanned)
  /// and targets still looking (unknown addresses), so neither kind can starve the other (round-12 A-M1 / B-M1).
  Attempt? next(int now) {
    final r = _round;
    if (r == null || r.running != null) return null;
    final known = <String>[], look = <String>[];
    final pick = <String, String>{};
    for (final id in r.targets) {
      final cands = _candidates(r, id, lookOk: now - r.start >= p.window).where((a) => _open(r, a, now)).toList();
      if (cands.isEmpty) continue;
      pick[id] = cands.first;
      (_knownAddr(r, id) != null ? known : look).add(id);
    }
    if (known.isEmpty && look.isEmpty) return null;
    known.sort((x, y) => _cmp(r, x, y));
    look.sort((x, y) => _cmp(r, x, y));
    final useKnown = known.isNotEmpty && (look.isEmpty || !r.lastWasKnown);
    final id = useKnown ? known.first : look.first;
    r.lastWasKnown = useKnown;
    final a = Attempt(pick[id]!, id);
    r.running = a;
    r.t[id]!.n++;
    r.count[a.addr] = (r.count[a.addr] ?? 0) + 1;
    r.retry.remove('${a.addr}|$id');
    r.tried.add('${a.addr}|$id');
    return a;
  }

  void result(int now, Attempt a, Outcome o) {
    final r = _round;
    if (r == null || r.running == null || r.running!.addr != a.addr || r.running!.id != a.id) return;
    r.running = null;
    r.freeAt[a.addr] = now + p.gap;
    final t = r.t[a.id]!;
    final s = states[a.id]!;
    final key = '${a.addr}|${a.id}';
    log.add('${_s(now)}   $a -> ${o.res.name}${o.view.isEmpty ? '' : ' ${o.view}'}');
    switch (o.res) {
      case Res.body:
        isY[a.addr] = a.id;
        notY[a.addr]?.remove(a.id);
        t.body = true;
        _read(s, now, o.view);
      case Res.errorCode:
        isY[a.addr] = a.id;
        t.err = true;
        r.retry.add(key);
      case Res.undecryptable:
        final w = writtenAt[a.id];
        if (w != null && now - w < p.n9) {
          r.retry.add(key); // N9: the node may not know its new owner yet
        } else if (isY[a.addr] == a.id) {
          isY.remove(a.addr); // a first undecryptable on a 「是 Y」 address only drops it (§4.3.3-4 exception 2)
        } else {
          (notY[a.addr] ??= {}).add(a.id);
        }
      case Res.certRejected:
        (notY[a.addr] ??= {}).add(a.id);
        if (isY[a.addr] == a.id) isY.remove(a.addr);
        t.why = Why.identity;
        s.kind = Kind.unreachable;
        s.why = Why.identity;
      case Res.refusedForbidden:
        isY[a.addr] = a.id;
        t.why = Why.refused;
        if (s.why != Why.identity) {
          s.kind = Kind.unreachable;
          s.why = Why.refused;
        }
      case Res.refusedOther:
      case Res.broken:
        isY[a.addr] = a.id;
        r.retry.add(key);
      case Res.noResponse:
        if (isY[a.addr] == a.id && (r.count[a.addr] ?? 0) >= p.perAddr) {
          // its known address did not answer twice in a round: drop 「是 Y」 so the next round looks for it (a device
          // replaying an old address must not hide the node for good; code-1 B-m1)
          isY.remove(a.addr);
        } else if (isY[a.addr] == a.id) {
          r.retry.add(key);
        } else {
          r.exhausted.add(a.addr);
        }
        r.noResp.add(a.addr);
    }
  }

  void _read(NodeState s, int now, String view) {
    s.view = view;
    s.readAt = now;
    s.lastRead = now;
    s.stale = false;
    s.responded = false;
    s.miss = 0;
    s.same = 0;
    s.kind = Kind.read;
    s.why = null;
  }

  /// End the round when due, start due rounds.
  void tick(int now) {
    final r = _round;
    if (r != null) {
      if (r.early && fullDue != null && now >= fullDue!) {
        _cancel(now); // the full-round timer wins over an early re-read (§4.3.2, X28)
        _begin(now, early: false);
        return;
      }
      final allDone = r.targets.every((id) => r.t[id]!.body || r.t[id]!.why != null);
      final pending = r.targets.any((id) => _candidates(r, id, lookOk: true).any((a) => (r.count[a] ?? 0) < p.perAddr));
      final atCap = now - r.start >= p.cap;
      if (atCap || allDone || (now - r.start >= p.window && r.running == null && !pending)) {
        final cut = r.running;
        if (cut != null) {
          // the attempt cut at the cap counts as not tried (§4.3.4; code-1 A-M1)
          log.add('${_s(now)}   $cut cut at the cap');
          r.tried.remove('${cut.addr}|${cut.id}');
          r.count[cut.addr] = (r.count[cut.addr] ?? 1) - 1;
          r.t[cut.id]!.n--;
          r.running = null;
        }
        _end(now, r);
      }
      return;
    }
    if (!_eligible) return;
    if ((fullDue != null && now >= fullDue!) || (leaseDue != null && now >= leaseDue!)) {
      _begin(now, early: false);
    } else if (earlyDue != null && now >= earlyDue!) {
      _begin(now, early: true, only: _earlyTargets);
    }
  }

  void _end(int now, _Round r) {
    _round = null;
    _noRespLast = r.noResp;
    final trigger = <String>{};
    for (final id in r.targets) {
      final c = _conclude(r, id);
      final s = states[id]!;
      s.last = c;
      s.notYetRun = c == Concl.notYet ? s.notYetRun + 1 : (c == Concl.queued ? s.notYetRun : 0);
      switch (c) {
        case Concl.read:
          break;
        case Concl.reason:
          s.same = 0; // any conclusion but 不變 / 還沒輪到 / 排隊中 resets it (§4.3.4; code-1 A-m3)
        case Concl.unchanged:
          s.miss = 0;
          if (s.kind == Kind.unreachable && (s.why == Why.notFound || s.why == Why.refused)) {
            s.kind = Kind.unread;
            s.why = null;
          }
          if (s.kind == Kind.unread) s.responded = true;
          if (!r.early) s.same++;
          if (s.same >= 2 && s.why != Why.identity) {
            s.kind = Kind.read;
            s.view = "2'";
            s.readAt = now;
            s.stale = false;
          }
        case Concl.notFound:
          s.same = 0;
          s.miss++;
          if (s.miss >= 2 && s.why != Why.identity) {
            s.kind = Kind.unreachable;
            s.why = Why.notFound;
          } else if (s.kind != Kind.unreachable) {
            trigger.add(id);
          }
        case Concl.notYet:
          if (s.kind != Kind.unreachable) trigger.add(id);
        case Concl.queued:
          break;
      }
    }
    log.add('${_s(now)} round ${r.id} end ${{for (final id in r.targets) id: states[id]!.last!.name}}');
    if (!r.early) {
      _fullEnds.add((now, r.targets));
      if (_fullEnds.length > 8) _fullEnds.removeAt(0);
      fullDue = now + p.interval;
    } else {
      fullDue ??= (_lastFullEnd(_pageTargets) ?? now) + p.interval;
    }
    if (trigger.isNotEmpty && earlyCount < p.earlyMax) {
      earlyCount++;
      _earlyTargets = trigger;
      earlyDue = now + p.early;
    } else if (trigger.isEmpty) {
      earlyCount = 0;
    }
  }

  Concl _conclude(_Round r, String id) {
    final t = r.t[id]!;
    if (t.body) return Concl.read;
    if (t.why != null) return Concl.reason;
    if (t.err) return Concl.unchanged;
    final k = _knownAddr(r, id);
    if (k != null) {
      // its known address was scanned: two failed tries on it = 沒找到; fewer (the cap came first) = 排隊中
      final failed = (r.count[k] ?? 0) >= p.perAddr || !_canTry(r, k, id);
      return failed ? Concl.notFound : Concl.queued;
    }
    return _candidates(r, id, lookOk: true).isNotEmpty ? Concl.notYet : Concl.notFound;
  }

  /// When the driver must call tick next (null = only on events).
  int? wakeAt(int now) {
    final r = _round;
    final c = <int>[
      if (r != null) r.start + p.cap,
      if (r != null) r.start + p.window,
      if (r != null) ...r.freeAt.values,
      if (r != null && r.early && fullDue != null) fullDue!,
      if (r == null && fullDue != null) fullDue!,
      if (r == null && earlyDue != null) earlyDue!,
      if (r == null && leaseDue != null) leaseDue!,
    ]..removeWhere((v) => v <= now);
    if (c.isEmpty) return null;
    return c.reduce((a, b) => a < b ? a : b);
  }

  static String _s(int ms) => (ms / 1000).toStringAsFixed(1);

  /// §4.3.9: a flow's login under its lease. Same attempt rules as a round, for one record, up to 60 s.
  LoginFor loginFor(int now, String id, {bool clearNotY = false}) {
    if (clearNotY) {
      for (final s in notY.values) {
        s.remove(id);
      }
    }
    final l = LoginFor._(this, id, now);
    if (blocked != null) l.end = LoginEnd.precondition;
    log.add('${_s(now)} loginFor $id${l.end == null ? '' : ' -> ${l.end!.name}'}');
    return l;
  }
}

enum LoginEnd { ok, identity, refused, notFound, precondition }

class LoginFor {
  LoginFor._(this.c, this.id, this.start);
  final NodeLinkCore c;
  final String id;
  final int start;
  static const budget = 60000;
  final List<String> seen = [];
  final Map<String, int> freeAt = {};
  final Set<String> tried = {}, retry = {};
  final Map<String, int> silent = {};
  Attempt? running;
  LoginEnd? end;
  int handshakes = 0;

  bool get done => end != null;

  void onScan(int now, String a) {
    c.lastSeen[a] = now;
    if (!seen.contains(a)) seen.add(a);
  }

  bool _ok(String a) => !tried.contains(a) || retry.contains(a);

  /// Its known address first; with a 「是 Y」 memo it waits for that address during the first 30 s; then unknown
  /// addresses in scan order (never one with any 「是」 memo or a 「不是 Y」 memo), addresses not tried yet before retries
  /// (so a node just claimed among many others is reached in the first minute; code-1 B-M4).
  Attempt? next(int now) {
    if (done || running != null) return null;
    String? pick;
    final known = seen.where((a) => c.isY[a] == id).toList();
    if (known.isNotEmpty) {
      if (_ok(known.first) && (freeAt[known.first] ?? 0) <= now) pick = known.first;
    } else if (!c.isY.containsValue(id) || now - start >= c.p.window) {
      final open = [
        for (final a in seen)
          if (c.isY[a] == null && !c.isNot(a, id) && _ok(a) && (freeAt[a] ?? 0) <= now) a
      ];
      pick = open.where((a) => !tried.contains(a)).firstOrNull ?? open.firstOrNull;
    }
    if (pick == null) return null;
    retry.remove(pick);
    tried.add(pick);
    handshakes++;
    return running = Attempt(pick, id);
  }

  void result(int now, Attempt a, Outcome o) {
    if (running == null || running!.addr != a.addr || !c.lease) return; // a lease taken back: drop it (code-1 A-m5)
    running = null;
    freeAt[a.addr] = now + c.p.gap;
    c.log.add('${NodeLinkCore._s(now)}   loginFor $a -> ${o.res.name}');
    final s = c.states[id] ?? NodeState(); // a record removed meanwhile: memos only
    switch (o.res) {
      case Res.body:
      case Res.errorCode:
        c.isY[a.addr] = id;
        end = LoginEnd.ok;
      case Res.undecryptable:
        final w = c.writtenAt[id];
        if (w != null && now - w < c.p.n9) {
          retry.add(a.addr);
        } else if (c.isY[a.addr] == id) {
          c.isY.remove(a.addr);
        } else {
          (c.notY[a.addr] ??= {}).add(id);
        }
      case Res.certRejected:
        (c.notY[a.addr] ??= {}).add(id);
        if (c.isY[a.addr] == id) c.isY.remove(a.addr);
        s.kind = Kind.unreachable;
        s.why = Why.identity;
        end = LoginEnd.identity;
      case Res.refusedForbidden:
        c.isY[a.addr] = id;
        if (s.why != Why.identity) {
          s.kind = Kind.unreachable;
          s.why = Why.refused;
        }
        end = LoginEnd.refused;
      case Res.refusedOther:
      case Res.broken:
        c.isY[a.addr] = id;
        retry.add(a.addr);
      case Res.noResponse:
        silent[a.addr] = (silent[a.addr] ?? 0) + 1;
        if (c.isY[a.addr] == id && silent[a.addr]! >= c.p.perAddr) {
          c.isY.remove(a.addr); // as in a round: two silences on the known address drop it, then it looks
        }
        retry.add(a.addr);
    }
  }

  void tick(int now) {
    if (!done && now - start >= budget) {
      running = null; // §4.3.9: 60 s, the running attempt is cut (code-1 A-m6)
      end = LoginEnd.notFound;
    }
  }

  int? wakeAt(int now) {
    if (done) return null;
    final c0 = <int>[start + budget, start + c.p.window, ...freeAt.values]..removeWhere((v) => v <= now);
    return c0.isEmpty ? null : c0.reduce((a, b) => a < b ? a : b);
  }
}
