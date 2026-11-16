// #329 PR 3 §2.5 / §2.8 (design §5.4): the flows behind the new network pages, without widgets so every rule is
// tested directly. The page owns the lease calls (acquire / hold / pageGone), keepScreenOn and the dialogs; these
// classes own the order of the requests and what each reply means (only by ConsoleReply, plan §2.3).
//
// NetRun — 「建立 / 加入網路」 for one or more nodes, one after the other (§2.5): the first ticked node makes the
// network (make mode) and the others join the record it wrote, or every node joins the picked record (join mode).
// CheckRun — 「檢查網路」 (§2.8): one login to the node that made the pending records, a confirm for each of them.
import 'dart:async';

import 'package:flutter/foundation.dart' show ChangeNotifier;
import 'package:flutter/services.dart' show PlatformException;

import '../../ui/home_logic.dart' show whyNext;
import '../nodelink/core.dart' show Why;
import '../nodelink/handoff.dart';
import '../nodelink/node_link.dart' show LoginForEnd, LoginForResult;
import 'net_index.dart';
import 'owner_console.dart';

/// What the flows need from the app (the page binds them to its lease).
class FlowDeps {
  const FlowDeps({
    required this.login,
    required this.console,
    required this.applied,
    required this.blocked,
    required this.leaseValid,
  });

  /// NodeLink.loginFor under the page's lease.
  final Future<LoginForResult> Function(String id, {bool clearNotY}) login;

  /// An OwnerConsole on a handed-over session (the page passes its dialogs and the lease).
  final OwnerConsole Function(LoginHandoff h) console;

  /// The record at rel read again under the lease (§2.6): applied? A record that does not read or open is false
  /// (fail-closed: 「檢查網路」, §2.9).
  final Future<bool> Function(String rel) applied;

  /// NodeLink's precondition (Bluetooth, permission, keys), null when none.
  final Why? Function() blocked;
  final bool Function() leaseValid;
}

/// The line for a login that found no session (§2.9: the reason's own words).
String loginLine(LoginForEnd e) => switch (e) {
      LoginForEnd.notFound => '60 秒內沒有找到這台節點。請確認節點開著、靠近手機，再試一次。',
      LoginForEnd.identity => whyNext(Why.identity),
      LoginForEnd.refused => whyNext(Why.refused),
      LoginForEnd.precondition => '藍牙、權限或手機金鑰現在不能用。',
      LoginForEnd.noLease || LoginForEnd.ok => '這個操作已經停止。',
    };

enum RowState { waiting, running, ok, failed, notDone }

/// One node of a NetRun: what the result page shows and offers.
class RunRow {
  RunRow(this.id, {required this.makes});
  final String id;

  /// This node makes the network (the first in make mode).
  final bool makes;
  RowState state = RowState.waiting;

  /// What it is doing now, or how it ended (the reply's own line).
  String line = '';

  /// A note under the line (「連線狀態未知」, 「新密碼沒有換成」).
  String note = '';

  /// make rows: the record this node's make-network wrote (ConsoleReply.persistedRel).
  String? persistedRel;

  /// Joined (the join's own answer was [JOINED]).
  bool joined = false;

  /// §2.5 result page (design :750): a make row with a written record offers only 「檢查網路」; without one, 「再試這一台」
  /// (make again); a join row 「再試這一台」 (the whole join rule again).
  bool get canRetry => state == RowState.failed && (!makes || persistedRel == null);
  bool get canCheck => state == RowState.failed && makes && persistedRel != null;
}

/// Why a whole run stopped early.
enum StopWhy { none, user, blocked, keys, leaseLost, makeFailed, pageGone }

class NetRun extends ChangeNotifier {
  NetRun(
    this.deps, {
    required List<String> ids,
    required this.makes,
    this.joinRel,
    this.name = 'Batman',
    this.channel = 40,
    required this.askGoOn,
  }) : rows = [for (var i = 0; i < ids.length; i++) RunRow(ids[i], makes: makes && i == 0)] {
    if (!makes && joinRel == null) throw ArgumentError('join mode needs the network record');
  }

  final FlowDeps deps;
  final List<RunRow> rows;
  final bool makes;
  final String name;
  final int channel;

  /// join mode: the picked record; make mode: set from the first node's persistedRel.
  String? joinRel;

  /// 「繼續下一台 / 先停在這裡」 after a failed node (true = go on). The page closes the dialog as 「停」 when the radio
  /// gets blocked or the lease goes while it is open (§2.9).
  final Future<bool> Function(RunRow failed) askGoOn;

  StopWhy stopped = StopWhy.none;
  bool _gone = false;
  bool running = false;
  int get index => rows.indexWhere((r) => r.state == RowState.running);

  /// The page is gone (§2.5): the request in progress ends, nothing after it starts; a link check in progress stops
  /// (its console is closed, v18 AF m9).
  void pageGone() {
    _gone = true;
    if (_inLinkCheck) unawaited(_current?.close());
  }

  OwnerConsole? _current; // the node in progress (closed before 繼續 / 停 is asked)
  bool _inLinkCheck = false;

  bool get _stopNow => _gone || !deps.leaseValid();

  void _set(RunRow r, RowState s, [String? line]) {
    r.state = s;
    if (line != null) r.line = line;
    notifyListeners();
  }

  /// Runs every waiting node in order. Completes when the run is over (the result page).
  Future<void> run() async {
    running = true;
    notifyListeners();
    try {
      for (final r in rows) {
        if (r.state != RowState.waiting) continue;
        if (stopped != StopWhy.none || _stopNow) break;
        final goOn = await _one(r, clearNotY: false);
        if (!goOn) break;
      }
    } finally {
      for (final r in rows) {
        if (r.state == RowState.waiting) r.state = RowState.notDone;
      }
      if (stopped == StopWhy.none && _gone) stopped = StopWhy.pageGone;
      running = false;
      notifyListeners();
    }
  }

  /// 「再試這一台」 on the result page (§2.5): the node's own rule again, clearing its 「不是 Y」 memo.
  Future<void> retry(RunRow r) async {
    if (!r.canRetry || running) return;
    running = true;
    stopped = StopWhy.none;
    r.note = '';
    notifyListeners();
    try {
      await _one(r, clearNotY: true, retrying: true);
    } finally {
      running = false;
      notifyListeners();
    }
  }

  /// Before asking 「繼續 / 停」: a blocked radio, the keys or the lease stop the whole run without a question (§2.5).
  bool _blockedStop({bool key = false}) {
    if (!deps.leaseValid()) {
      stopped = StopWhy.leaseLost;
    } else if (key || deps.blocked() == Why.keys) {
      stopped = StopWhy.keys;
    } else if (deps.blocked() != null) {
      stopped = StopWhy.blocked;
    } else if (_gone) {
      stopped = StopWhy.pageGone;
    } else {
      return false;
    }
    return true;
  }

  /// One node; false = the run stops here.
  Future<bool> _one(RunRow r, {required bool clearNotY, bool retrying = false}) async {
    _set(r, RowState.running, '正在連到節點…');
    try {
      final c = await _login(r, clearNotY);
      if (c == null) return await _failed(r, retrying);
      _current = c;
      try {
        return r.makes ? await _make(r, c, retrying) : await _join(r, c, retrying);
      } finally {
        _current = null;
        await c.close();
      }
    } catch (e) {
      // code review A m-1 / B m2: a request that threw before it went out (a record that does not read, the phone's
      // keys): the row fails with its reason, never stays 「進行中」
      r.line = '[REQ_FAIL] 操作沒有成功：${e is PlatformException ? e.code : e.runtimeType}';
      // code review C N-4: joined, and the new secrets' request threw before it went out (§2.9)
      if (r.joined && r.note.isEmpty) r.note = '已加入，新密碼沒有送出';
      return _failed(r, retrying, key: e is PlatformException);
    }
  }

  Future<OwnerConsole?> _login(RunRow r, bool clearNotY) async {
    final res = await deps.login(r.id, clearNotY: clearNotY);
    final h = res.handoff;
    if (res.end == LoginForEnd.ok && h != null) {
      if (_stopNow) {
        await h.close(); // §2.5: a login that ends after the page is gone sends nothing (nodes.dart:405-409)
        r.line = '這個操作已經停止。';
        return null;
      }
      return deps.console(h);
    }
    if (res.end == LoginForEnd.precondition) stopped = deps.blocked() == Why.keys ? StopWhy.keys : StopWhy.blocked;
    if (res.end == LoginForEnd.noLease) stopped = StopWhy.leaseLost;
    r.line = loginLine(res.end);
    return null;
  }

  /// A failed node: the whole run stops for a blocked radio, the keys, the lease, the page, or a make (D12);
  /// otherwise the user is asked (a retry asks nothing: it is one node).
  Future<bool> _failed(RunRow r, bool retrying, {bool key = false}) async {
    _set(r, RowState.failed);
    if (stopped != StopWhy.none || _blockedStop(key: key)) return false;
    if (r.makes) {
      stopped = StopWhy.makeFailed; // D12: no network for the others to join
      return false;
    }
    if (retrying) return false;
    if (r == rows.last) return true;
    await _current?.close(); // code review B m1: the failed node's link is not held while the user decides
    final go = await askGoOn(r);
    if (!go) {
      // the dialog closed as 「停」 because the radio got blocked meanwhile: say why (§2.9)
      if (!_blockedStop()) stopped = StopWhy.user;
      return false;
    }
    return !_blockedStop();
  }

  Future<bool> _make(RunRow r, OwnerConsole c, bool retrying) async {
    _set(r, RowState.running, '正在建立網路，這一步最多 6 分鐘');
    final m = await c.makeNetwork(name: name, channel: channel);
    r.line = m.text;
    r.persistedRel = m.persistedRel;
    if (m.keyError) return _failed(r, retrying, key: true); // §2.9: no reread, no automatic check
    final rel = m.persistedRel;
    if (rel == null) return _failed(r, retrying);
    if (_stopNow) return _failed(r, retrying);
    var ok = await deps.applied(rel);
    if (!ok) {
      // design §5.4: once, automatically, 「檢查網路」 (D6)
      _set(r, RowState.running, '正在確認');
      var cc = c;
      if (!m.sessionAlive || !c.alive) {
        await c.close();
        final again = await _login(r, false);
        if (again == null) {
          r.line = '沒有連到節點，無法檢查。${r.line}';
          return _failed(r, retrying);
        }
        cc = again;
      }
      try {
        final k = await cc.confirmNetwork(rel);
        r.line = k.text;
        if (k.keyError) return await _failed(r, retrying, key: true);
        ok = await deps.applied(rel);
      } finally {
        if (!identical(cc, c)) await cc.close();
      }
    }
    if (!ok) return _failed(r, retrying);
    joinRel = rel;
    _set(r, RowState.ok);
    return true;
  }

  Future<bool> _join(RunRow r, OwnerConsole c, bool retrying) async {
    final rel = joinRel!;
    _set(r, RowState.running, '正在加入網路，這一步最多 6 分鐘');
    final j = await c.joinNetwork(rel);
    r.line = j.text;
    if (j.keyError) return _failed(r, retrying, key: true);
    if (!j.starts('[JOINED] ')) return _failed(r, retrying);
    r.joined = true;
    if (_stopNow) {
      // §2.5: the page is gone: no send, no link check
      _set(r, RowState.ok, j.text);
      return false;
    }
    if (j.sendUpdate) {
      _set(r, RowState.running, '正在把新密碼送給節點');
      final u = await c.sendUpdateFor(rel);
      if (!u.starts('[UPDATED] ')) {
        r.note = switch (u.kind) {
          ReplyKind.notSent => '已加入，新密碼沒有送出',
          ReplyKind.unclear => '已加入，新密碼結果不明',
          _ => '已加入，新密碼沒有換成',
        };
        r.line = u.text;
        return _failed(r, retrying, key: u.keyError);
      }
    } else if (j.pollLink) {
      _set(r, RowState.running, '正在確認節點連上了，最多 2 分鐘');
      _inLinkCheck = true;
      final l = await c.linkCheck().whenComplete(() => _inLinkCheck = false);
      if (!l.starts('[CONNECTED]')) r.note = '連線狀態未知';
    }
    // device session 2026-11-16: a done row shows the join's own answer, not the last 「正在…」 line
    _set(r, RowState.ok, j.text);
    return true;
  }
}

/// How a CheckRun ended (§2.8).
enum CheckEnd { upgraded, answered, notCreator, nothingToCheck, noAnswer, loginFailed, blocked, unreadable }

class CheckRun extends ChangeNotifier {
  CheckRun(this.deps, {required this.id, required this.snapshot, this.first});
  final FlowDeps deps;

  /// The node checked (§2.8: 「檢查的是節點 XXXX」).
  final String id;

  /// The records as listed under the lease (§2.8, not NetIndex).
  final Future<NetSnapshot> Function() snapshot;

  /// From the result page: the record just made, checked first.
  final String? first;

  CheckEnd? end;
  final List<String> lines = [];
  bool _anyApplied = false;
  bool running = false;

  /// §2.8: every record answered, none upgraded, no applied net on the phone. (A node picked by hand needs no rule
  /// of its own: only the verified creator, by nodeDacHash, is ever asked; code review B m5.)
  bool get offerMake => end == CheckEnd.answered && !_anyApplied;

  bool _gone = false;

  /// The page is gone (§3.2 T-R1(c)): no login or confirm starts after the one in progress.
  void pageGone() => _gone = true;

  Future<void> run({bool clearNotY = false}) async {
    running = true;
    end = null;
    lines.clear();
    notifyListeners();
    try {
      end = await _run(clearNotY);
    } catch (e) {
      lines.add('[REQ_FAIL] 操作沒有成功：${e is PlatformException ? e.code : e.runtimeType}');
      end = CheckEnd.noAnswer;
    } finally {
      running = false;
      notifyListeners();
    }
  }

  Future<CheckEnd> _run(bool clearNotY) async {
    final s = await snapshot();
    if (s.listFailed || s.noneOpens) return CheckEnd.unreadable;
    _anyApplied = s.anyApplied;
    final pending = s.nets.where((n) => !n.applied && n.view.members.any((m) => m.creator)).toList();
    if (pending.isEmpty) return CheckEnd.nothingToCheck;
    if (_gone) return CheckEnd.blocked;
    final res = await deps.login(id, clearNotY: clearNotY);
    final h = res.handoff;
    if (_gone) {
      await h?.close();
      return CheckEnd.blocked;
    }
    if (res.end != LoginForEnd.ok || h == null) {
      lines.add(loginLine(res.end));
      return res.end == LoginForEnd.precondition || res.end == LoginForEnd.noLease ? CheckEnd.blocked : CheckEnd.loginFailed;
    }
    final c = deps.console(h);
    try {
      final me = c.nodeDacHash();
      final mine = [
        for (final n in pending)
          if (me.isNotEmpty && n.view.members.any((m) => m.creator && m.dacHash == me)) n
      ];
      if (mine.isEmpty) return CheckEnd.notCreator;
      final f = first;
      if (f != null) mine.sort((a, b) => a.rel == f ? -1 : (b.rel == f ? 1 : 0));
      for (final n in mine) {
        if (_gone) return CheckEnd.blocked;
        final r = await c.confirmNetwork(n.rel);
        lines.add(r.text);
        notifyListeners();
        if (r.keyError || !deps.leaseValid() || deps.blocked() != null) return CheckEnd.blocked;
        if (!r.starts('[NET_STATE] ')) return CheckEnd.noAnswer; // §2.8: only the confirm's own answer counts
        if (await deps.applied(n.rel)) return CheckEnd.upgraded;
      }
      return CheckEnd.answered;
    } finally {
      await c.close();
    }
  }
}
