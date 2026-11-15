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

  (Outcome, int) _attempt(Dev? d, String id) {
    if (d == null || !d.on || now < d.busyUntil) return (const Outcome(Res.noResponse), silent);
    d.handshakes++;
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
      d.quietUntil = now + 5000;
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
      if (now >= since + see) c.onScan(now, d.addr);
    }
  }

  int? _nextScanTime(Phone ph) {
    if (!ph.core.roundActive) return null;
    int? best;
    for (final d in devs) {
      final cands = <int>[
        if (d.on) (d.busyUntil > d.quietUntil ? d.busyUntil : d.quietUntil),
        if (ph.seenAt.containsKey(d.addr)) ph.seenAt[d.addr]! + see,
      ].where((t) => t > now);
      for (final t in cands) {
        if (best == null || t < best) best = t;
      }
    }
    return best;
  }

  void step(Phone ph) {
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
      if (a != null) {
        final d = _byAddr(a.addr);
        final (o, dur) = _attempt(d, a.id);
        ph.running = a;
        ph.outcome = o;
        ph.endsAt = now + dur;
        ph.dev = d;
        if (d != null && d.on) {
          d.busyUntil = now + dur;
          d.quietUntil = now + dur + 5000;
        }
      }
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
