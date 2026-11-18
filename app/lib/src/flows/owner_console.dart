// #329 PR 3 §2.3: the owner requests of the new pages (make / join / confirm a network, send the new secrets, the link
// check after a join), copied from the old console (nodes.dart `_tryLogin`'s step loop, `_ask`, `_makeNetwork`,
// `_joinNetwork`, `_confirmNetwork`, `_sendUpdateFor`, `_watchLink`) with the same behaviour and the same lines.
// The old console stays as it is (PR 6 deletes it, and this copy with it is the only one left).
//
// What differs is only the wiring (plan §2.3):
// - the session comes logged in from NodeLink.loginFor (a LoginHandoff); `ask` never logs in itself, and the old
//   「a write failed -> log in again and send once more」 branch is not copied (none of these five requests reaches it:
//   make-network has an unclear line, the others are retry: false — nodes.dart:486-489, :647, :1244, :1581, :703);
// - every record write goes through RecordWriter under the page's lease;
// - each request returns a ConsoleReply to the page (never a line on a screen of its own); nothing of an answer is
//   logged.
import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/services.dart' show PlatformException;

import '../../key_abilities.dart' show KeyAbilities;
import '../../say.dart' show tech;
import '../../member_ui.dart' show SendTrack, askNoLink, endedLine, joinWait, joinreqLostLine, notSentLine, stepFrames;
import '../nodelink/ble_gate.dart' show Char;
import '../nodelink/handoff.dart';
import '../nodelink/lease.dart';
import '../nodelink/record_writer.dart';
import '../rust/api/owner.dart';
import '../rust/api/swupdate.dart' show SwAction, SwUpdate;

/// The software update's side of a request (Rust's `SwUpdate`; a fake in tests): what to send and what an answer, a
/// lost request or no link makes of it. Every call gets the update's own clock.
abstract class SwLink {
  OwnerStep request(OwnerSession s);
  SwAction answered(OwnerSession s, BigInt now);
  SwAction lost(BigInt now);
  SwAction noLink(BigInt now);
}

class RustSwLink implements SwLink {
  RustSwLink(this.sw);
  final SwUpdate sw;
  @override
  OwnerStep request(OwnerSession s) => s.requestSw(sw: sw);
  @override
  SwAction answered(OwnerSession s, BigInt now) => s.swAnswer(sw: sw, nowMs: now);
  @override
  SwAction lost(BigInt now) => sw.lost(nowMs: now);
  @override
  SwAction noLink(BigInt now) => sw.noLink(nowMs: now);
}

/// The old console's lines, unchanged (nodes.dart:47-55).
const joinUnclearLine = '[JOIN_STATE] 結果不明，稍後在這台按「加入網路」';
const makeUnclearLine = '[NET_STATE] 結果不明，稍後在這台按「檢查網路」';
const linkUnknownLine = '[JOINED] 已套用，連線狀態未知';
const sendUnclearLine = '[REQ_FAIL] 結果不明 — 請重新連線後看狀態頁';
const joinCancelledLine = '[JOIN_STATE] 已取消：沒有寫入、沒有送出';
const recordUnopenedLine = '[REQ_FAIL] 手機裡的網路紀錄打不開';

/// #329 PR 4 §2.2: a settings/set whose outcome is unknown (it went out); the page offers 「重新讀取」.
const settingsUnclearLine = '[REQ_FAIL] 結果不明 — 請重新讀取設定';

/// The update request's unclear mark (nodes.dart:1598 `_swUnanswered`): a lost link ends it at once; never shown.
const swUnansweredMark = '[SW_LOST]';

/// join2 §3.3-7 (nodes.dart:41-42).
const linkWindow = Duration(seconds: 120);
const linkEvery = Duration(seconds: 10);

/// How a request ended (plan §2.3 table).
enum ReplyKind {
  /// The node's answer through Rust (`OwnerKind.answer`): [ConsoleReply.text] is Rust's detail as is.
  answer,

  /// Rust refused the request itself (an `Err(String)`), before anything went out.
  refused,

  /// It went out and the outcome is unknown (a timeout, the link lost after a record write).
  unclear,

  /// Nothing was written or sent.
  notSent,

  /// Rust ended the session.
  ended,

  /// The page's lease is gone.
  leaseLost,
}

/// #329 PR 5 §2.3: what a join request's answer carries (Rust's OwnerStep hex / sas / renewed), made on the session
/// that answered.
class JoinreqOut {
  const JoinreqOut(this.hex, this.sas, this.renewed);
  final String hex, sas;
  final bool renewed;
}

class ConsoleReply {
  const ConsoleReply(this.kind, this.text,
      {this.persistedRel,
      this.sendUpdate = false,
      this.pollLink = false,
      this.sessionAlive = true,
      this.keyError = false,
      this.left = false,
      this.settings,
      this.value});
  final ReplyKind kind;

  /// #329 PR 4 §2.2: network/leave answered 0 (Rust `left`; leaveFlow reads the page once more).
  final bool left;

  /// #329 PR 4 §2.1: a settings/get or settings/set answer that succeeded (Rust gives it only then).
  final SettingsView? settings;

  /// #329 PR 4 §2.2: what the request made of its answer on the session that answered it, in the step loop (a
  /// `StatusView` for [OwnerConsole.statusPage], a `SwAction` for [OwnerConsole.askSw]); null otherwise.
  final Object? value;

  /// [ReplyKind.answer]: Rust's detail, without the old `[ANSWER] ` mark. Otherwise the line to show (the old
  /// console's, Dart or Rust).
  final String text;

  /// Set only after the first PersistNet write of this request succeeded (later failures never clear it).
  final String? persistedRel;
  final bool sendUpdate, pollLink;

  /// Whether this session may take another request (false after unclear / ended / a write error: log in again).
  final bool sessionAlive;

  /// A key use failed in this request (seal / sign / signAdmin, or the make-network key check).
  final bool keyError;

  bool starts(String mark) => kind == ReplyKind.answer && text.startsWith(mark);

  @override
  String toString() => 'ConsoleReply(${kind.name}, persisted=${persistedRel != null}, alive=$sessionAlive, key=$keyError)';
}

/// What the console needs from the platform (Kotlin keys, the record store), injected so it is testable.
class ConsolePlatform {
  const ConsolePlatform({
    required this.seal,
    required this.signOwner,
    required this.signAdmin,
    required this.publicKeys,
    required this.readRecord,
    required this.makeNetworkRefusal,
  });
  final Future<Uint8List> Function(Uint8List plain, Uint8List aad) seal;
  final Future<Uint8List> Function(Uint8List input) signOwner;
  final Future<Uint8List> Function(Uint8List input) signAdmin;

  /// owner / ownerEnc / admin.
  final Future<Map<String, Uint8List>> Function() publicKeys;

  /// A sealed record as read: (generation, plain); plain null = none, or it does not open (nodes.dart:738-746).
  final Future<(BigInt, Uint8List?)> Function(String rel) readRecord;

  /// design §4.1: the live key check before a network creation; the refusal line, or null when allowed.
  final Future<String?> Function() makeNetworkRefusal;
}

/// The questions a request may ask the user (injected dialogs). Null = the page is gone: 「不要」 / 「取消」.
typedef AskUser = Future<bool> Function(String question);

class OwnerConsole {
  OwnerConsole(
    this.h,
    this.lease,
    this.writer,
    this.platform, {
    required this.after,
    required this.nowMs,
    required this.askCountry,
    required this.askRemoved,
    this.keyError,
    this.log,
    this.onLost,
  }) : _session = h.session {
    _stateSub = h.link.state.listen((up) {
      if (!up) _lost();
    }, onError: (Object _) {});
    h.inbox.handle(_onFrame, (Object e) => log?.call('owner console: subscription ${e.runtimeType}'));
  }

  final LoginHandoff h;
  final Lease lease;
  final RecordWriter writer;
  final ConsolePlatform platform;
  final After after;
  final int Function() nowMs;
  final AskUser askCountry, askRemoved;

  /// X26: a key use failed (the app turns a key-gate refusal into 2.4, keyErrorToRadio).
  final void Function(Object error)? keyError;

  /// Lines without an answer's content (rel cut to 8 characters, no record bytes).
  final void Function(String line)? log;

  /// The link went away or the console was closed: a question it asked (country, removed before) is closed by the
  /// page as 「不要」 before anything else is asked (plan §2.9, code review B M4).
  final void Function()? onLost;
  StreamSubscription<bool>? _stateSub;

  OwnerSession? _session;
  bool _closed = false;
  bool _busy = false;
  Future<void> _chain = Future.value(); // the frames, one after the other (nodes.dart:347 asyncMap)

  // the outstanding request (nodes.dart `_ask`'s fields)
  Completer<ConsoleReply>? _answer;
  Cancel? _wait;
  Duration _waitFor = const Duration(seconds: 15);
  String _waitLine = '';
  String? _unclear;
  var _track = SendTrack();
  String? _persistedRel;
  bool _pendSaved = false; // #329 PR 5 §2.3: the join request's record landed in this request
  bool _keyError = false;
  String? _removedQ;
  int? _linkFrom; // set when a join was applied: the link checks count from here
  Object? Function(OwnerSession s, OwnerStep st)? _derive; // the outstanding request's use of its answer

  bool get alive => _session != null && !_closed;

  /// Which own node this session is (the verified DAC's SHA-256, lowercase hex).
  String nodeDacHash() => _session?.nodeDacHash() ?? '';

  // ---- the step loop (nodes.dart:205-342) ----------------------------------------------------------------------------

  void _onFrame(List<int> f) {
    final s = _session;
    if (s == null || _closed) return;
    _chain = _chain.then((_) => _run(s.onFrame(frame: f))).catchError((Object e) {
      log?.call('owner console: a step did not finish (${e.runtimeType})');
      _endUnclear();
    });
  }

  ConsoleReply _reply(ReplyKind k, String text,
          {bool? alive, bool sendUpdate = false, bool pollLink = false, bool left = false, SettingsView? settings, Object? value}) =>
      ConsoleReply(k, text,
          persistedRel: _persistedRel,
          sendUpdate: sendUpdate,
          pollLink: pollLink,
          sessionAlive: alive ?? (_session != null && !_closed),
          keyError: _keyError,
          left: left,
          settings: settings,
          value: value);

  void _complete(ConsoleReply r) {
    final a = _answer;
    if (a != null && !a.isCompleted) a.complete(r);
  }

  Uint8List _keyFail(Object e) {
    _keyError = true;
    keyError?.call(e);
    return Uint8List(0); // an empty signature ends whatever asked
  }

  Future<void> _run(OwnerStep? st) async {
    final s = _session;
    while (st != null && s != null) {
      if (_closed || !identical(_session, s)) return;
      switch (st.kind) {
        case OwnerKind.write:
          for (final f in stepFrames(_track, st).frames) {
            await h.link.write(Char.rx, f);
          }
          if (_closed) return;
          _kick();
          st = null;
        case OwnerKind.sign:
          Uint8List der;
          try {
            der = await platform.signOwner(st.signInput);
          } on PlatformException catch (e) {
            der = _keyFail(e);
          }
          st = s.signed(der: der);
        case OwnerKind.signAdmin:
          Uint8List der;
          try {
            der = await platform.signAdmin(st.signInput);
          } on PlatformException catch (e) {
            der = _keyFail(e);
          }
          st = s.signed(der: der);
        case OwnerKind.persistNet || OwnerKind.persistPend || OwnerKind.persistMnet:
          // the record lands (sealed, by compare-and-swap) before anything goes out (join2 §3.1), under the lease
          final OwnerStep p = st;
          _track.persisted();
          try {
            await lease.run(() async {
              final sealed = await platform.seal(p.record, p.aad);
              await writer.writeCas(lease, p.rel, p.expectedGen, sealed);
            });
            if (p.kind == OwnerKind.persistNet) _persistedRel ??= p.rel;
            if (p.kind == OwnerKind.persistPend) _pendSaved = true; // #329 PR 5 §2.3: joinreqLostLine(saved:)
            log?.call('owner console: record saved (${p.rel.length > 12 ? p.rel.substring(0, 12) : p.rel}…)');
            st = s.netPersisted();
          } catch (e) {
            final String why;
            if (e is String) {
              why = e; // store_write_cas's own reason (the "changed elsewhere" line for a generation mismatch)
            } else if (e is PlatformException) {
              _keyFail(e);
              why = KeyAbilities.refusedBy(e) ?? 'seal ${e.code}';
            } else if (e is NoLease || e is StateError) {
              why = 'no lease';
            } else {
              why = '${e.runtimeType}';
            }
            log?.call('owner console: record not saved: $why');
            st = s.persistFailed(error: why);
          }
        case OwnerKind.confirmCountry:
          _wait?.call(); // the user's time does not count against the node's answer
          final yes = _closed ? false : await askCountry(st.detail);
          if (_closed || !identical(_session, s)) return;
          _kick();
          st = s.countryConfirmed(yes: yes);
        case OwnerKind.wait:
          _wait?.call();
          final w = Completer<void>();
          after(Duration(milliseconds: st.waitMs.toInt()), w.complete);
          await w.future;
          if (_closed) return;
          _kick();
          st = s.resumeUpdate();
        case OwnerKind.confirmRemoved:
          // §2.0 rule 2: nothing was written or signed; joinNetwork asks and starts the join again
          _removedQ = st.detail;
          _complete(_reply(ReplyKind.answer, st.detail));
          st = null;
        case OwnerKind.loggedIn:
          st = null; // a login is NodeLink's (never here after the hand-off)
        case OwnerKind.answer:
          if (st.pollLink) _linkFrom = nowMs();
          // #329 PR 4 §2.2: made here, on the session that answered, and only for the request still waiting (a late
          // answer changes nothing: review D m8); a software-update answer is never logged (update D8)
          final d = _derive, w = _answer;
          final v = d != null && w != null && !w.isCompleted ? d(s, st) : null;
          _complete(_reply(ReplyKind.answer, st.detail,
              sendUpdate: st.sendUpdate, pollLink: st.pollLink, left: st.left, settings: st.settings, value: v));
          st = null;
        case OwnerKind.ended:
          log?.call('owner console: session ended');
          _session = null; // Rust ended this session: the page logs in again
          _complete(_reply(ReplyKind.ended, endedLine(st.detail), alive: false));
          st = null;
      }
    }
  }

  /// Restart the outstanding request's wait (each write to the node).
  void _kick() {
    _wait?.call();
    final line = _waitLine;
    _wait = after(_waitFor, () {
      final u = _unclear;
      _session = null; // the request is still outstanding in that session (nodes.dart:567-568)
      _complete(u != null ? _unclearReply(u) : _reply(ReplyKind.unclear, line, alive: false));
    });
  }

  ConsoleReply _unclearReply(String unclear) {
    final line = _track.unclearNow(unclear);
    return _reply(line == notSentLine ? ReplyKind.notSent : ReplyKind.unclear, line, alive: false);
  }

  void _endUnclear() {
    final u = _unclear;
    if (u == null) return;
    _session = null;
    _complete(_unclearReply(u));
  }

  /// The link went away after the login: the session is gone with it (nodes.dart:438-443).
  void _lost() {
    if (_closed) return;
    log?.call('owner console: link lost');
    onLost?.call();
    _endUnclear();
    _session = null;
  }

  /// plan §2.3: leaseLost only from the lease itself, whatever ended the request.
  ConsoleReply _leaseCheck(ConsoleReply r) => lease.valid
      ? r
      : ConsoleReply(ReplyKind.leaseLost, r.text,
          persistedRel: r.persistedRel,
          sessionAlive: r.sessionAlive,
          keyError: r.keyError,
          left: r.left,
          settings: r.settings,
          value: r.value); // #329 PR 4 code review B m2: what the answer already made is kept

  /// One request (nodes.dart `_ask` without its login and resend branch). [wait] runs from each write to the node.
  Future<ConsoleReply> _ask(OwnerStep Function(OwnerSession) req,
      {Duration wait = const Duration(seconds: 15),
      String? unclear,
      String? timeoutLine,
      Object? Function(OwnerSession s, OwnerStep st)? derive,
      bool endedAfterSent = false}) async {
    final s = _session;
    if (_closed || s == null) return _reply(ReplyKind.notSent, askNoLink, alive: false);
    if (!lease.valid) return _reply(ReplyKind.leaseLost, askNoLink);
    if (_busy) throw StateError('owner console: one request at a time');
    _busy = true;
    _waitFor = wait;
    _waitLine = timeoutLine ?? '[REQ_FAIL] ${wait.inSeconds} 秒內節點沒有回應（結果不明；下次操作會重新連線）';
    _unclear = unclear;
    _track = SendTrack();
    _removedQ = null;
    _derive = derive;
    final answer = _answer = Completer<ConsoleReply>();
    try {
      try {
        final first = req(s);
        final f = _chain.then((_) => _run(first));
        _chain = f.catchError((Object _) {}); // the frames after it still run
        await f;
      } catch (e) {
        if (e is String) {
          // a Rust refusal is the operation's own answer, not a link problem (nothing went out)
          return _leaseCheck(_reply(ReplyKind.refused, e));
        }
        // a write / platform failure on the link (nodes.dart:546-553); the old resend is not copied (plan §2.3)
        _session = null;
        if (unclear != null) return _leaseCheck(_unclearReply(unclear));
        return _leaseCheck(_reply(
            ReplyKind.unclear, '[REQ_FAIL] 操作沒有成功${tech(e is PlatformException ? e.code : e.runtimeType)}',
            alive: false));
      }
      if (!answer.isCompleted) _kick();
      var r = await answer.future;
      if (r.kind == ReplyKind.unclear || r.kind == ReplyKind.notSent) {
        // review v17 AH m1: a record write may be in progress when the wait ran out or the link went: the reply is
        // made after it (at most 10 s), so its line and persistedRel agree
        await _chain.timeout(const Duration(seconds: 10), onTimeout: () {});
        final u = unclear;
        if (u != null) r = _unclearReply(u);
      }
      // #329 PR 4 §2.0 (review C m3): Rust ended the session; after a write marked `sent` that is "outcome unknown"
      final uc = unclear;
      if (endedAfterSent && r.kind == ReplyKind.ended && uc != null) r = _unclearReply(uc);
      return _leaseCheck(r);
    } finally {
      _wait?.call();
      _wait = null;
      _answer = null;
      _unclear = null;
      _derive = null;
      _busy = false;
    }
  }

  // ---- the requests ---------------------------------------------------------------------------------------------------

  /// design §5.4: make a network on this (claimed, not joined) node (nodes.dart:476-490).
  Future<ConsoleReply> makeNetwork({required String name, required int channel}) async {
    _persistedRel = null;
    _keyError = false;
    final no = await platform.makeNetworkRefusal();
    if (no != null) {
      _keyError = true;
      return _reply(ReplyKind.notSent, '[REQ_FAIL] [KEY_LEVEL] $no');
    }
    final keys = await platform.publicKeys();
    final n = name.trim().isEmpty ? 'Batman' : name.trim();
    return _ask(
        (s) => s.requestMakeNetwork(netName: n, channel: channel, ownerEncPub: keys['ownerEnc']!, adminPub: keys['admin']!),
        wait: joinWait,
        unclear: makeUnclearLine);
  }

  /// join2 §3.3 (nodes.dart:626-671 without the pick, the link check and the send): this node joins the network at
  /// [rel]; a node excluded before is asked about first (§2.0 rule 2).
  Future<ConsoleReply> joinNetwork(String rel) async {
    _persistedRel = null;
    _keyError = false;
    _linkFrom = null;
    var (gen, plain) = await platform.readRecord(rel);
    if (plain == null) return _reply(ReplyKind.notSent, recordUnopenedLine);
    final keys = await platform.publicKeys();
    Future<ConsoleReply> go(Uint8List p, BigInt g, bool confirmed) => _ask(
        (s) => s.requestJoinNetwork(
            recordPlain: p,
            recordGen: g,
            adminPub: keys['admin']!,
            ownerEncPub: keys['ownerEnc']!,
            removedConfirmed: confirmed),
        wait: joinWait,
        unclear: joinUnclearLine);
    final r = await go(plain, gen, false);
    final q = _removedQ;
    _removedQ = null;
    if (q == null) return r;
    if (_closed || !await askRemoved(q)) return _reply(ReplyKind.notSent, joinCancelledLine);
    (gen, plain) = await platform.readRecord(rel); // nothing was written by the first try; read it again anyway
    if (plain == null) return _reply(ReplyKind.notSent, recordUnopenedLine);
    return go(plain, gen, true);
  }

  /// join2 §3.2: read info on this node against the net record at [rel] (nodes.dart:1240-1245).
  Future<ConsoleReply> confirmNetwork(String rel) async {
    _persistedRel = null;
    _keyError = false;
    final (gen, plain) = await platform.readRecord(rel);
    if (plain == null) return _reply(ReplyKind.notSent, recordUnopenedLine);
    return _ask((s) => s.requestConfirmNetwork(recordPlain: plain, recordGen: gen));
  }

  /// remove-member §3.2 / join2 §3.5 (nodes.dart:1567-1582 with confirm: false): the new secrets from [rel].
  Future<ConsoleReply> sendUpdateFor(String rel, {bool member = false}) async {
    _keyError = false;
    final (_, plain) = await platform.readRecord(rel);
    if (plain == null) return _reply(ReplyKind.notSent, recordUnopenedLine);
    final keys = await platform.publicKeys();
    return _ask((s) => s.requestSendUpdate(recordPlain: plain, member: member, adminPub: keys['admin']!),
        wait: joinWait, unclear: sendUnclearLine);
  }

  // ---- #329 PR 5 §2.3: the member's join request, the member's join, info ---------------------------------------

  /// member-join (nodes.dart:881-895): a join request for [inviteHex] on this node. [pendRel] (`mpend/<netId>`) is
  /// read here, under the lease (R11). The answer's value is a [JoinreqOut]; a link lost on the way ends with
  /// `joinreqLostLine(saved:)`, saved = the request's record landed (the old `_joinreqInFlight`, nodes.dart:887-892).
  Future<ConsoleReply> joinreq({required String inviteHex, required String name, required String pendRel}) async {
    _keyError = false;
    _pendSaved = false;
    final (gen, plain) = await platform.readRecord(pendRel);
    final keys = await platform.publicKeys();
    final r = await _ask(
        (s) => s.requestJoinreq(inviteHex: inviteHex, name: name, pendGen: gen, pendPlain: plain, ownerEncPub: keys['ownerEnc']!),
        derive: (s, st) => st.hex.isEmpty ? null : JoinreqOut(st.hex, st.sas, st.renewed));
    if (r.kind == ReplyKind.answer || r.kind == ReplyKind.refused || r.sessionAlive) return r;
    return _reply(r.kind, joinreqLostLine(saved: _pendSaved), alive: false);
  }

  /// member-join §4 step 8 (nodes.dart:1040-1062 without the pick, the send and the link check): this node joins the
  /// team network of [mnetRel], read here under the lease (R11). [ConsoleReply.sendUpdate] / [ConsoleReply.pollLink]
  /// say what comes next (R16).
  Future<ConsoleReply> memberJoin(String mnetRel) async {
    _persistedRel = null;
    _keyError = false;
    _linkFrom = null;
    final (gen, plain) = await platform.readRecord(mnetRel);
    if (plain == null) return _reply(ReplyKind.notSent, recordUnopenedLine);
    return _ask((s) => s.requestMemberJoin(mnetPlain: plain, mnetGen: gen), wait: joinWait, unclear: joinUnclearLine);
  }

  /// `info` (nodes.dart:1363-1372, :1546-1563): the node's info bytes as the answer's value (a Uint8List; empty = not
  /// read). 8.3 pairs them with the record's dac hash, as the old `_remove` did.
  Future<ConsoleReply> info() {
    _keyError = false;
    return _ask((s) => s.requestInfo(), derive: (s, st) => st.info.isEmpty ? null : st.info);
  }

  // ---- #329 PR 4 §2.2: settings, leave, the status page, the software update ------------------------------------

  /// `settings/get` (nodes.dart:1672): the answer's [ConsoleReply.settings] is the current values.
  Future<ConsoleReply> settings() {
    _keyError = false;
    return _ask((s) => s.requestSettings());
  }

  /// `settings/set` {2: country} (nodes.dart:1694). Waits [joinWait] (the node takes up to about 230 s: D2); a lost link
  /// after the signed write is 「結果不明」 (§2.1 (a)).
  Future<ConsoleReply> setCountry(String country) {
    _keyError = false;
    return _ask((s) => s.requestSetCountry(country: country),
        wait: joinWait, unclear: settingsUnclearLine, endedAfterSent: true);
  }

  /// `settings/set` {20: {1: ssid, 2: passphrase}} (nodes.dart:1714). The passphrase goes straight into Rust's
  /// encrypted request: it is never logged and never in a reply (owner.rs request_set_ap).
  Future<ConsoleReply> setAp(String ssid, String passphrase) {
    _keyError = false;
    return _ask((s) => s.requestSetAp(ssid: ssid, passphrase: passphrase),
        wait: joinWait, unclear: settingsUnclearLine, endedAfterSent: true);
  }

  /// 「離開網路」 (leave v4.1 §3): the call policy comes from `sendLeave` (wait, unclear); never re-sent.
  Future<ConsoleReply> leave({required Duration wait, required String unclear}) {
    _keyError = false;
    return _ask((s) => s.requestLeaveNetwork(), wait: wait, unclear: unclear);
  }

  /// The status page read (nodes.dart:1155-1160): [ConsoleReply.value] is its `StatusView`, made on the session that
  /// answered (so the read right after a leave is cut once, `after_left`).
  Future<ConsoleReply> statusPage({required bool hasNet, required bool hasMnet}) {
    _keyError = false;
    return _ask((s) => s.requestStatusPage(), derive: (s, st) => s.statusView(hasNet: hasNet, hasMnet: hasMnet));
  }

  /// One request of a software update (nodes.dart:1590-1626 `_askSw` without its login): the update's next action.
  /// [now] is the update's own clock (`SwHold.now`, the one every call of this update uses: plan §2.2, review D M1).
  /// Anything but the node's answer is `lost`, and this session is not used again (the old `_drop`).
  Future<SwAction> askSw(SwLink sw, BigInt Function() now, int waitMs) async {
    final r = await _ask(sw.request,
        wait: Duration(milliseconds: waitMs),
        unclear: swUnansweredMark,
        derive: (s, st) => st.sw ? sw.answered(s, now()) : null);
    final v = r.value;
    // the node's answer was handed to the update already (swAnswer ran): its action, whatever came after (code review
    // B m2: never `lost` on top of it)
    if (v is SwAction) return v;
    _session = null; // the request may still be outstanding in that session (nodes.dart:1621)
    return sw.lost(now());
  }

  /// join2 §3.3-7 (nodes.dart:687-716): after an applied join, the status every 10 s until connected or 120 s. Any
  /// end that is not the node's answer stops it (no login again): the result is unknown.
  Future<ConsoleReply> linkCheck() async {
    final from = _linkFrom;
    _linkFrom = null;
    if (from == null) return _reply(ReplyKind.unclear, linkUnknownLine);
    var last = _reply(ReplyKind.unclear, linkUnknownLine);
    while (!_closed && nowMs() - from < linkWindow.inMilliseconds) {
      final w = Completer<void>();
      final stop = after(linkEvery, w.complete);
      _stopWait = () {
        stop();
        if (!w.isCompleted) w.complete();
      };
      await w.future;
      _stopWait = null;
      if (_closed || _session == null) {
        last = _reply(ReplyKind.unclear, linkUnknownLine);
        break;
      }
      final secs = (nowMs() - from) ~/ 1000;
      final a = await _ask((s) => s.requestLinkCheck(secsSinceJoin: BigInt.from(secs)));
      if (a.kind != ReplyKind.answer) {
        last = _reply(ReplyKind.unclear, linkUnknownLine);
        break;
      }
      last = a;
      if (a.text.startsWith('[CONNECTED]')) break;
    }
    return last;
  }

  void Function()? _stopWait;

  /// Idempotent (plan §2.2): stop taking frames, wait for the step in progress (seal / CAS / netPersisted; at most
  /// 10 s), then the subscription, the link (until it is gone) and the session. Every caller waits for the same close
  /// (code review C N-2: a second caller does not return before the link is gone).
  Future<void> close() => _closing ??= _close();
  Future<void>? _closing;

  Future<void> _close() async {
    _closed = true;
    _stopWait?.call();
    onLost?.call();
    unawaited(_stateSub?.cancel());
    h.inbox.handle(null, null);
    final a = _answer;
    if (a != null && !a.isCompleted) {
      // the request still waiting ends now as its timeout would (nodes.dart:147-151)
      final u = _unclear;
      _session = null;
      a.complete(u != null ? _unclearReply(u) : _reply(ReplyKind.unclear, _waitLine, alive: false));
    }
    try {
      await _chain.timeout(const Duration(seconds: 10), onTimeout: () {});
    } catch (_) {}
    _session = null;
    await h.close();
  }
}

/// join2 §3.4 (nodes.dart:1250-1295 without the dialogs): forget a joining member of the net record at [rel] — this
/// phone's record only, the node is not changed. Needs no login: its own short lease, written through RecordWriter.
/// Returns Rust's line; throws the line to show on failure.
Future<String> forgetJoining(
  Lease lease,
  RecordWriter writer, {
  required String rel,
  required Uint8List plain,
  required BigInt gen,
  required String dacHash,
  required Future<Uint8List> Function(Uint8List plain, Uint8List aad) seal,
  void Function(Object error)? keyError,
}) async {
  try {
    final st = netForgetJoining(recordPlain: plain, recordGen: gen, dacHash: dacHash);
    await lease.run(() async {
      final sealed = await seal(st.record, st.aad);
      await writer.writeCas(lease, st.rel, st.expectedGen, sealed);
    });
    return st.detail;
  } catch (e) {
    if (e is PlatformException) keyError?.call(e);
    throw '[REQ_FAIL] 忘記沒有成功：${e is PlatformException ? (KeyAbilities.refusedBy(e) ?? e.code) : e}';
  }
}
