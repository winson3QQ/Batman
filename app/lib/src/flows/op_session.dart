// #329 PR 4 §2.0: the new settings / leave / update pages' way to a node — take the session lease, log in under it
// (NodeLink.loginFor), run the owner requests on an OwnerConsole, give everything back. Only PR 3's parts, PR 3's
// rules: nothing is re-sent; a page that is gone starts nothing; the console is closed before the lease goes (§4.4).
//
// - [OpSession.once]: one operation (5.6 / 5.8 read or send, 離開網路). The lease is held only while it runs, so a page
//   left open does not stop the reads (review A m8 / B m4, D6). Logs in once; requests after the first one (the
//   status read after a leave) are on the same console, which keeps Rust's after_left (§2.0, review C m4).
// - [OpenSession]: the software-update page, which holds the lease while it is open (design §4.8). Before each
//   request it logs in again when the console is gone (the node closes an idle login after 300 s: N2 / T-X17,
//   review A M2 / B M2).
// - The screen is kept on only by `once` (review C M1: Kotlin's flag has no count; the update page keeps its own).
// - No record is written here.
import 'dart:async';

import 'package:flutter/foundation.dart' show debugPrint;

import '../nodelink/handoff.dart' show LoginHandoff;
import '../nodelink/lease.dart';
import '../nodelink/node_link.dart' show LoginForEnd, LoginForResult;
import '../rust/api/owner.dart' show SettingsView;
import 'owner_console.dart';

/// How an operation ended before or instead of its requests.
enum OpEnd {
  /// The requests ran: [OpReply.reply] is the last one's.
  done,

  /// Another operation holds the lease ([OpReply.busyName]); nothing was started.
  busy,

  /// The login did not end with a session ([OpReply.login]); nothing was sent.
  login,

  /// The page went away before a request was written; nothing was sent.
  gone,

  /// The lease went away (taken back, or not valid any more).
  leaseLost,

  /// Something else went wrong (a bug, an error nobody expected): the outcome is unknown. Never up to the page as an
  /// exception (code review A m11 / B m10: a page would stay 「正在送出…」 with its back button blocked).
  failed,
}

class OpReply {
  const OpReply(this.end, {this.reply, this.login, this.found = false, this.busyName = ''});
  final OpEnd end;
  final ConsoleReply? reply;
  final LoginForEnd? login;

  /// With [login] `notFound`: LoginForResult.found.
  final bool found;
  final String busyName;

  @override
  String toString() => 'OpReply(${end.name}, ${reply?.kind.name}, ${login?.name})';
}

/// What the sessions need of the app (AppLink in the app, fakes in tests).
class OpDeps {
  OpDeps({
    required this.acquire,
    required this.busyName,
    required this.login,
    required this.console,
    required this.keepScreen,
    SettingsMemo? memo,
  }) : memo = memo ?? SettingsMemo();

  /// NodeLink.acquire(name, session): null = another operation holds the lease. 329-takeover.md §1.1 (b): with
  /// [forNode], NodeLink may first wait for the attempt in flight to that node; [gone] = the caller's page is closed.
  final Future<Lease?> Function(String name, {String? forNode, bool Function()? gone}) acquire;

  /// The name of the operation holding the lease ('' = none).
  final String Function() busyName;

  /// NodeLink.loginFor under [lease].
  final Future<LoginForResult> Function(Lease lease, String id) login;

  /// An OwnerConsole on a handed-over session, bound to [lease].
  final OwnerConsole Function(Lease lease, LoginHandoff h) console;

  /// keepScreenOn (a convenience: the flow does not depend on it).
  final Future<void> Function(bool on) keepScreen;

  /// 329-takeover.md §1.2: the settings pages' last values read (the app's one object; a test passes its own).
  final SettingsMemo memo;
}

/// 329-takeover.md §1.2: node id -> the last [SettingsView] a settings page read in this app run. Memory only; used
/// for nothing but the two settings pages' labels (「確認中…」 / 「上次讀到」), never to fill a field or enable a send.
class SettingsMemo {
  final _m = <String, SettingsView>{};

  SettingsView? operator [](String id) => _m[id];

  /// After a read, or a set whose answer was read back (only a view that was read).
  void put(String id, SettingsView v) {
    if (v.read) _m[id] = v;
  }

  /// Right before a set request is sent: a set whose answer is lost leaves no entry.
  void drop(String id) => _m.remove(id);
}

/// The requests of one operation: [c] is logged in; check [gone] before each further request.
typedef OpRequests = Future<ConsoleReply> Function(OwnerConsole c, bool Function() gone);

class OpSession {
  OpSession._();

  /// One operation: lease, login, [requests], then the console closed and the lease released. [gone] = the page is no
  /// longer there (checked after the login and before the requests).
  static Future<OpReply> once(OpDeps d, String id, String name, OpRequests requests, {required bool Function() gone}) async {
    if (gone()) return const OpReply(OpEnd.gone);
    // 329-takeover.md §1.1 (b): the page's own node; a call whose page closed meanwhile takes nothing
    final lease = await d.acquire(name, forNode: id, gone: gone);
    if (lease == null) return gone() ? const OpReply(OpEnd.gone) : OpReply(OpEnd.busy, busyName: d.busyName());
    if (gone()) {
      await lease.release();
      return const OpReply(OpEnd.gone);
    }
    Cancel? hold;
    OwnerConsole? c;
    unawaited(d.keepScreen(true));
    try {
      hold = lease.hold();
    } on StateError {
      await lease.release();
      unawaited(d.keepScreen(false));
      return const OpReply(OpEnd.leaseLost); // the lease was gone before anything started
    }
    try {
      final r = await d.login(lease, id);
      final h = r.handoff;
      if (r.end != LoginForEnd.ok || h == null) {
        return r.end == LoginForEnd.noLease ? const OpReply(OpEnd.leaseLost) : OpReply(OpEnd.login, login: r.end, found: r.found);
      }
      if (gone()) {
        await h.close();
        return const OpReply(OpEnd.gone);
      }
      if (!lease.valid) {
        await h.close();
        return const OpReply(OpEnd.leaseLost);
      }
      final console = c = d.console(lease, h);
      final reply = await requests(console, gone);
      return reply.kind == ReplyKind.leaseLost ? OpReply(OpEnd.leaseLost, reply: reply) : OpReply(OpEnd.done, reply: reply);
    } catch (e) {
      // security review LOW-3: after the hold, an error (a second request at once — a page bug — or anything else)
      // may come after a write: never 「沒有送出」, the outcome is unknown
      debugPrint('BMAPP op $name failed: ${e.runtimeType}'); // the type only
      return const OpReply(OpEnd.failed);
    } finally {
      await c?.close(); // the console before the lease (§4.4, review A m11 / B m12)
      hold();
      await lease.release();
      unawaited(d.keepScreen(false));
    }
  }
}

/// The update page's session: the lease is held from [open] to [pageGone] (design §4.8).
class OpenSession {
  OpenSession._(this.d, this.lease, this.id);
  final OpDeps d;
  final Lease lease;
  final String id;

  OwnerConsole? _c;
  bool _gone = false;
  int _running = 0;

  /// The lease, or null when another operation holds it (the page then does not open: review C m10 / D m1).
  static Future<OpenSession?> open(OpDeps d, String id, String name) async {
    final l = await d.acquire(name);
    return l == null ? null : OpenSession._(d, l, id);
  }

  bool get gone => _gone;

  /// One request: logged in first when there is no live console. [failed] makes the result when no request could be
  /// sent (login, gone, lease).
  Future<T> run<T>(Future<T> Function(OwnerConsole c) request, {required T Function(OpReply why) failed}) async {
    if (_gone) return failed(const OpReply(OpEnd.gone));
    Cancel hold;
    try {
      hold = lease.hold();
    } on StateError {
      return failed(const OpReply(OpEnd.leaseLost));
    }
    _running++;
    try {
      var c = _c;
      if (c == null || !c.alive) {
        await c?.close();
        _c = null;
        final r = await d.login(lease, id);
        final h = r.handoff;
        if (r.end != LoginForEnd.ok || h == null) {
          return failed(r.end == LoginForEnd.noLease ? const OpReply(OpEnd.leaseLost) : OpReply(OpEnd.login, login: r.end, found: r.found));
        }
        if (_gone || !lease.valid) {
          await h.close();
          return failed(OpReply(_gone ? OpEnd.gone : OpEnd.leaseLost));
        }
        c = _c = d.console(lease, h);
      }
      return await request(c);
    } catch (e) {
      // security review LOW-3: after the hold any error is 「結果不明」, never 「沒有送出」
      debugPrint('BMAPP op failed: ${e.runtimeType}');
      return failed(const OpReply(OpEnd.failed));
    } finally {
      _running--;
      if (_gone && _running == 0) await _c?.close(); // before the hold goes: the lease follows it (review B m3)
      hold();
    }
  }

  /// The page's dispose: nothing new starts; a request in progress is not cut — the console closes and the lease goes
  /// when it ends (lease.pageGone keeps the lease while the hold is out).
  Future<void> pageGone() async {
    if (_gone) return;
    _gone = true;
    if (_running == 0) await _c?.close();
    lease.pageGone();
  }
}
