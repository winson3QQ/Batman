// A discrete-event BLE world for the NodeLink scheduler (#329 design §4.3, §9.1 「假藍牙」). Virtual time in ms.
// Nodes behave as measured (§1.3 M-1 / §1.2 N1–N9): one connection at a time, no advertising while connected and for
// ~5 s after (N8), a wrong record ends in 「解不開」 after ~5 s (M-1 W), a login + status read takes A1.
import 'package:batman_app/src/nodelink/core.dart';

enum Mode { own, foreignUndecryptable, foreignSilent }

class Dev {
  Dev(this.addr, {this.id, this.mode = Mode.own});
  String addr;
  final String? id; // the record that opens it (own nodes)
  final Mode mode;
  bool on = true; // powered and healthy (advertises when not connected)
  int busyUntil = 0; // connected until
  int quietUntil = 0; // re-advertises after (N8)
  int? claimedAt; // N9: undecryptable for its own record until claimedAt + 4 s
  String view = 'green';
  List<Res> statusScript = []; // per login: body or errorCode, consumed in order; empty = body
  Res? force; // every attempt ends like this (certRejected, refusedForbidden, ...)
  int logins = 0;
  int handshakes = 0;
  final List<int> handshakeTimes = [];
  final Map<String, int> byPhone = {};
  int readvertise = 5000; // N8: ~5 s after a disconnect (M-1 R)

  /// #329 rotating identifier: the node the phones named in [hintTo] (null = every phone) resolve this device's
  /// adverts to. Null = no hint (a node without the field, or no record of it on the phone).
  String? hint;
  Set<String>? hintTo;
  String? hintFor(String phone) => hintTo == null || hintTo!.contains(phone) ? hint : null;

  bool advertising(int now) => on && now >= busyUntil && now >= quietUntil;
}

class Phone {
  Phone(this.name, this.core);
  final String name;
  final NodeLinkCore core;
  Attempt? running;
  int? endsAt;
  Outcome? outcome;
  Dev? dev;
  final Map<String, int> seenAt = {}; // addr -> time it became visible to this round
  int? scanRound;
  final Map<String, List<int>> reads = {}; // id -> read times
  final List<int> roundStarts = [];
  LoginFor? login; // a flow's login under its lease (§4.3.9)
  final Map<String, int> loginSeen = {};
}

class World {
  World({this.a1 = 11000, this.wrong = 5000, this.silent = 8000, this.see = 3000});
  final int a1, wrong, silent, see;
  final List<Dev> devs = [];
  final List<Phone> phones = [];
  final List<(int, void Function())> _events = [];
  int now = 0;

  Dev dev(String addr, {String? id, Mode mode = Mode.own}) {
    final d = Dev(addr, id: id, mode: mode);
    devs.add(d);
    return d;
  }

  Phone phone(String name, List<Rec> recs, {Params p = const Params()}) {
    final ph = Phone(name, NodeLinkCore(recs, p: p));
    phones.add(ph);
    return ph;
  }

  void at(int t, void Function() f) => _events.add((t, f));

  Dev? _byAddr(String a) {
    for (final d in devs) {
      if (d.addr == a) return d;
    }
    return null;
  }

  /// One attempt: (outcome, duration, did it connect). A central can only connect to an advertising node, so a node
  /// that is connected elsewhere or re-advertising is waited for inside the 8 s msg2 budget (code-1 B, SIM_REAL).
  (Outcome, int, bool) _attempt(Dev? d, String id, String who) {
    if (d == null || !d.on) return (const Outcome(Res.noResponse), silent, false);
    final avail = d.busyUntil > d.quietUntil ? d.busyUntil : d.quietUntil;
    var wait = 0;
    if (avail > now) {
      if (avail - now + 1000 > silent) return (const Outcome(Res.noResponse), silent, false);
      wait = avail - now;
    }
    final (o, dur) = _connected(d, id, who, now + wait);
    return (o, dur + wait, true);
  }

  (Outcome, int) _connected(Dev d, String id, String who, int now) {
    d.handshakes++;
    d.byPhone[who] = (d.byPhone[who] ?? 0) + 1;
    d.handshakeTimes.add(now);
    if (d.mode == Mode.foreignSilent) return (const Outcome(Res.noResponse), silent);
    if (d.mode == Mode.foreignUndecryptable || d.id != id) return (const Outcome(Res.undecryptable), wrong);
    if (d.claimedAt != null && now < d.claimedAt! + 4000) return (const Outcome(Res.undecryptable), wrong);
    if (d.force != null) return (Outcome(d.force!), wrong);
    d.logins++;
    final r = d.statusScript.isEmpty ? Res.body : d.statusScript.removeAt(0);
    return (r == Res.body ? Outcome(Res.body, d.view) : Outcome(r), a1);
  }

  void _release(Phone ph) {
    final d = ph.dev;
    if (d != null) {
      d.busyUntil = now;
      d.quietUntil = now + d.readvertise;
    }
    ph.running = null;
    ph.endsAt = null;
    ph.dev = null;
  }

  void _scans(Phone ph) {
    final c = ph.core;
    if (!c.roundActive) {
      ph.scanRound = null;
      ph.seenAt.clear();
      return;
    }
    if (ph.scanRound != c.roundsRun) {
      ph.scanRound = c.roundsRun;
      ph.seenAt.clear();
      ph.roundStarts.add(now);
    }
    for (final d in devs) {
      if (!d.advertising(now)) {
        ph.seenAt.remove(d.addr);
        continue;
      }
      final since = ph.seenAt.putIfAbsent(d.addr, () => now);
      if (now >= since + see) c.onScan(now, d.addr, hint: d.hintFor(ph.name));
    }
  }

  int? _nextScanTime(Phone ph) {
    final scanning = ph.core.roundActive || (ph.login != null && !ph.login!.done);
    if (!scanning) return null;
    final seen = ph.core.roundActive ? ph.seenAt : ph.loginSeen;
    int? best;
    for (final d in devs) {
      final cands = <int>[
        if (d.on) (d.busyUntil > d.quietUntil ? d.busyUntil : d.quietUntil),
        if (seen.containsKey(d.addr)) seen[d.addr]! + see,
      ].where((t) => t > now);
      for (final t in cands) {
        if (best == null || t < best) best = t;
      }
    }
    return best;
  }

  void _stepLogin(Phone ph, LoginFor l) {
    if (ph.running != null && ph.endsAt! <= now) {
      final a = ph.running!, o = ph.outcome!;
      _release(ph);
      l.result(now, a, o);
    }
    l.tick(now);
    if (l.done) {
      if (ph.running != null) _release(ph);
      return;
    }
    for (final d in devs) {
      if (!d.advertising(now)) {
        ph.loginSeen.remove(d.addr);
        continue;
      }
      final since = ph.loginSeen.putIfAbsent(d.addr, () => now);
      if (now >= since + see) l.onScan(now, d.addr, hint: d.hintFor(ph.name));
    }
    if (ph.running == null) {
      final a = l.next(now);
      if (a != null) _start(ph, a);
    }
  }

  void _start(Phone ph, Attempt a) {
    final d = _byAddr(a.addr);
    final (o, dur, connected) = _attempt(d, a.id, ph.name);
    ph.running = a;
    ph.outcome = o;
    ph.endsAt = now + dur;
    ph.dev = connected ? d : null;
    if (d != null && connected) {
      d.busyUntil = now + dur;
      d.quietUntil = now + dur + d.readvertise;
    }
  }

  void step(Phone ph) {
    final l = ph.login;
    if (l != null && !l.done) return _stepLogin(ph, l);
    final c = ph.core;
    // an attempt the core no longer runs (cut at the cap, cancelled): the phone drops the link now
    if (ph.running != null && c.running?.toString() != ph.running.toString()) _release(ph);
    if (ph.running != null && ph.endsAt! <= now) {
      final a = ph.running!, o = ph.outcome!;
      _release(ph);
      c.result(now, a, o);
      if (o.res == Res.body) (ph.reads[a.id] ??= []).add(now);
    }
    c.tick(now);
    if (ph.running != null && c.running?.toString() != ph.running.toString()) _release(ph);
    _scans(ph);
    if (ph.running == null && c.roundActive) {
      final a = c.next(now);
      if (a != null) _start(ph, a);
    }
  }

  void run(int until) {
    while (now <= until) {
      _events.sort((a, b) => a.$1.compareTo(b.$1));
      while (_events.isNotEmpty && _events.first.$1 <= now) {
        _events.removeAt(0).$2();
      }
      for (var i = 0; i < 4; i++) {
        for (final ph in phones) {
          step(ph);
        }
      }
      final ts = <int>[
        until + 1,
        if (_events.isNotEmpty) _events.first.$1,
        for (final ph in phones) ...[
          if (ph.endsAt != null) ph.endsAt!,
          if (ph.core.wakeAt(now) != null) ph.core.wakeAt(now)!,
          if (ph.login != null && ph.login!.wakeAt(now) != null) ph.login!.wakeAt(now)!,
          if (_nextScanTime(ph) != null) _nextScanTime(ph)!,
        ],
      ]..removeWhere((t) => t <= now);
      now = ts.reduce((a, b) => a < b ? a : b);
      if (now > until) break;
    }
  }
}

/// The largest gap between consecutive reads of one node, counting from `from` (or the first read).
int maxGap(List<int> reads, {int? from, required int until}) {
  final pts = [?from, ...reads.where((r) => from == null || r >= from), until];
  var g = 0;
  for (var i = 1; i < pts.length; i++) {
    final d = pts[i] - pts[i - 1];
    if (d > g) g = d;
  }
  return g;
}
