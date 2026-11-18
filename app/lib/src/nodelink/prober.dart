// #329 §4.3.3-3/-4: one attempt's login + status read with the Rust OwnerSession, mapped to the core's outcome.
// The record is opened (Keystore) for this attempt only; the Rust session is disposed when the attempt ends (review
// pr1 B-m2). The plain bytes from the platform channel cannot be zeroed from Dart (a read-only buffer, seen on the
// S20); they go with the GC like every other opened record in the app. Nothing here writes a record (an automatic read only reads, §4.3.3-9). Platform
// calls are injected so tests can fake them.
import 'dart:async';
import 'dart:typed_data';

import '../rust/api/claim.dart' show frameLimit;
import '../rust/api/owner.dart';
import '../rust/api/rekey.dart' show UpdateHint;
import '../rust/api/team_flag.dart' as team_flag;
import 'ble_gate.dart';
import 'core.dart';
import 'handoff.dart';
import 'node_link.dart';

const eForbidden = 3; // batman-proto flow.rs E_FORBIDDEN: the node does not accept this owner key

/// #329 PR 3 §2.2: the core outcome of an `ended` step (a login end and its code), shared by the read and the hand-off
/// probers. 5 (Broken in the login) and anything before a login are noResponse — never plant a 「是 Y」 (driver
/// contract, core.dart Res).
Outcome loginOutcome(int loginEnd, int code, {required bool loggedIn}) => switch (loginEnd) {
      2 => const Outcome(Res.undecryptable),
      3 => const Outcome(Res.certRejected),
      4 => code == eForbidden ? const Outcome(Res.refusedForbidden) : const Outcome(Res.refusedOther),
      _ => loggedIn ? const Outcome(Res.broken) : const Outcome(Res.noResponse),
    };

/// #329 PR 5 plan v16 §2.4 (R6–R8): what the read needs to work out the remove-member §3.5 line 「這台還在舊密碼」 on the
/// session that just read the status page. All read-only; injected so tests can fake them.
class HintSource {
  const HintSource(
      {required this.wanted, required this.netKnown, required this.openNet, required this.onHint, this.netReady = _yes});

  static bool _yes() => true;

  /// R6: a dev build and this node's page is open
  final bool Function(String id) wanted;

  /// R6: the phone has a net or mnet record of this network (NetIndex, read-only)
  final bool Function(String netId) netKnown;

  /// #329 PR 6 §14: NetIndex has finished its first computation (before that [netKnown] says no for every network,
  /// and a team section made from that would wrongly say 「沒有名單」).
  final bool Function() netReady;

  /// `net/<id>` or `mnet/<id>` opened (store + Keystore), null when there is none or it does not open
  final Future<Uint8List?> Function(String rel) openNet;

  /// R8: the new hint of [id] (an empty line = none)
  final void Function(String id, UpdateHint hint) onHint;
}

/// R7: the hint never holds a read longer than this. #329 PR 6 D5(b): one budget for the hint and the team section.
const hintMax = Duration(seconds: 2);

class SessionProber implements Prober {
  SessionProber({
    required this.openRecord,
    required this.ownerPub,
    required this.signOwner,
    this.keyError,
    this.log,
    this.answerMax = const Duration(seconds: 20),
    this.hint,
    this.teamEnabled = team_flag.teamEnabled,
  }) : _handoff = false;

  /// #329 PR 5 R6–R8: null = no hint and no team section (a flow's login, tests of reads).
  final HintSource? hint;

  /// #329 PR 6 D5(a): Rust's `team_enabled()` (teamview::WRITE_MESH_ADDR); false (version N) -> no record is opened
  /// for the team view and `teamView` is never called. Injected for tests.
  final bool Function() teamEnabled;

  SessionProber._handoff({
    required this.openRecord,
    required this.ownerPub,
    required this.signOwner,
    this.keyError,
    this.log,
    this.answerMax = const Duration(seconds: 20),
  })  : _handoff = true,
        teamEnabled = _no,
        hint = null; // a flow's login stops at loggedIn: no status page, no hint

  static bool _no() => false;

  /// #329 PR 3 §2.2: a login for a flow (HandoffProber) stops at `loggedIn` and hands the session over instead of
  /// reading the status page.
  final bool _handoff;

  /// The plain node record of [id] (store + Keystore), or null when it is gone.
  final Future<Uint8List?> Function(String id) openRecord;
  final Future<Uint8List> Function() ownerPub;
  final Future<Uint8List> Function(Uint8List input) signOwner;

  /// X26: a key use failed (the error of openRecord / signOwner). The app checks whether the phone's key gate refused
  /// it and then tells NodeLink (2.4, not 「連不到」; review pr1 B-M5). The attempt itself ends as no answer.
  final void Function(Object error)? keyError;
  final void Function(String line)? log;

  /// After msg2: the existing 20 s (F3).
  final Duration answerMax;

  @override
  Future<Outcome> probe(GateLink link, String id, {required Future<void> due, required Future<void> cancelled}) async {
    final result = Completer<Outcome>();
    var gotMsg2 = false; // a whole msg2: the session answered with a step (a fragment alone is not msg2, r2 D-2)
    var loggedIn = false;
    void done(Outcome o) {
      if (!result.isCompleted) result.complete(o);
    }

    // an exception ends this attempt only: before the login it is no answer, after it the session broke (§4.3.3-4,
    // review pr1 A-m10)
    Outcome failed() => Outcome(loggedIn ? Res.broken : Res.noResponse);
    void keyCheck(Object e) => keyError?.call(e);

    // §4.3.3-3: from the start of the connect to msg2 at most 8 s, one budget for the connect and everything before
    // msg2 (Keystore, MTU, ctrl read, first write); [due] is that deadline (review pr1 A-M4 / B-M3)
    unawaited(due.then((_) {
      if (!gotMsg2) done(const Outcome(Res.noResponse));
    }));
    // #329 PR 5 R7 (S-m5): a cancel while the hint is worked out keeps the status page already read
    Outcome? read;
    var cleaning = false;
    unawaited(cancelled.then((_) => done(read ?? const Outcome(Res.noResponse))));

    OwnerSession? s;
    StreamSubscription<List<int>>? sub;
    Timer? answer;
    final inbox = FrameInbox(); // built before the subscription (§2.2)
    LoginHandoff? handed;

    Future<void> run(OwnerStep? st) async {
      while (st != null && !result.isCompleted) {
        final session = s!;
        switch (st.kind) {
          case OwnerKind.write:
            for (final f in st.frames) {
              if (result.isCompleted) return;
              await link.write(Char.rx, f);
            }
            st = null;
          case OwnerKind.sign:
            Uint8List der;
            try {
              der = await signOwner(st.signInput);
            } catch (e) {
              keyCheck(e);
              der = Uint8List(0); // the key could not sign: the login ends
            }
            if (result.isCompleted) return;
            st = session.signed(der: der);
          case OwnerKind.loggedIn:
            loggedIn = true;
            if (_handoff) {
              // §2.2: from here the frames wait in the inbox for the flow (set synchronously, before any await)
              inbox.handle(null, null);
              handed = LoginHandoff(id: id, link: link, inbox: inbox, session: session, sub: sub, detail: st.detail);
              done(Outcome(Res.body, '', handed));
              st = null;
            } else {
              st = session.requestStatusPage();
            }
          case OwnerKind.answer:
            answer?.cancel(); // #329 PR 5 R7 (K-m2): the hint's wait cannot turn a good read into a broken one
            final v = session.statusView(hasNet: false, hasMnet: false);
            // a status answer that is an error code (Rust row 2') is 不變, not a read (§4.3.3-4, round-5 B-M1);
            // E_UNSUPPORTED is row 1, a definite answer
            var o = v.row == "2'" ? Outcome(Res.errorCode, '', v) : Outcome(Res.body, v.color, v);
            read = o;
            // #329 PR 5 R7 / PR 6 D5(b): the hint and the team section on this session, before done() (done lets the
            // cleanup dispose the session); one 2 s budget; over it or cancelled -> no team section (null)
            final hs = hint;
            if (hs != null && o.res == Res.body) {
              final team = await Future.any<TeamSeen?>([
                _afterRead(hs, session, id, v, () => cleaning || result.isCompleted)
                    .timeout(hintMax, onTimeout: () => null),
                cancelled.then((_) => null),
              ]);
              if (team != null && !result.isCompleted) o = Outcome.withTeam(o.res, o.view, o.extra, team);
            }
            done(o);
            st = null;
          case OwnerKind.ended:
            log?.call('probe $id: login ended ${st.loginEnd} code ${st.loginCode} (logged in: $loggedIn)');
            done(loginOutcome(st.loginEnd, st.loginCode.toInt(), loggedIn: loggedIn));
            st = null;
          default:
            // a read never meets a step that writes a record or asks the user (§4.3.3-9): give the node up
            log?.call('NodeLink: unexpected step ${st.kind.name} in a read');
            done(failed());
            st = null;
        }
      }
    }

    Future<void> work() async {
      final Uint8List? r;
      try {
        r = await openRecord(id);
      } catch (e) {
        keyCheck(e);
        rethrow;
      }
      if (r == null) return done(const Outcome(Res.noResponse));
      if (result.isCompleted) return;
      final mtu = await link.requestMtu(517);
      if (result.isCompleted) return;
      final ctrl = await link.read(Char.ctrl);
      if (result.isCompleted) return;
      final fl = await frameLimit(ctrl: ctrl, mtu: mtu);
      final pub = await ownerPub();
      if (result.isCompleted) return;
      final (session, first) = OwnerSession.start(recordPlain: r, ownerPub: pub, frameLimit: fl);
      s = session;
      inbox.handle((f) {
        if (result.isCompleted) return;
        final OwnerStep? st;
        try {
          st = session.onFrame(frame: f);
        } catch (e) {
          log?.call('probe $id: ${e.runtimeType} $e on a frame (logged in: $loggedIn)');
          done(failed());
          return;
        }
        if (st != null && !gotMsg2) {
          gotMsg2 = true;
          answer = Timer(answerMax, () => done(failed())); // after msg2: the existing 20 s (F3)
        }
        run(st).catchError((Object e) {
          log?.call('probe $id: ${e.runtimeType} $e after a frame (logged in: $loggedIn)');
          done(failed());
        });
      }, (Object _) => done(failed()));
      sub = link.subscribe(Char.tx).listen(inbox.add, onError: inbox.addError);
      await run(first);
    }

    // the steps before msg2 race the deadline: a step that never returns cannot hold the attempt (review pr1 A-M4)
    unawaited(work().catchError((Object e) {
      log?.call('probe $id: ${e.runtimeType} $e (logged in: $loggedIn)'); // a type and a message, never bytes
      done(failed());
    }));
    final o = await result.future; // never completes with an error
    cleaning = true; // #329 PR 5 R7: a hint still waiting on its record does not call into the session any more
    // the cleanup never changes the outcome: each step on its own, a failure only logged
    answer?.cancel();
    final h = handed;
    if (h != null && identical(o.extra, h)) return o; // §2.2: handed over — subscription, link, session are the flow's
    inbox.handle(null, null);
    try {
      await sub?.cancel();
    } catch (e) {
      log?.call('probe $id cleanup: subscription ${e.runtimeType} $e');
    }
    try {
      s?.dispose();
    } catch (e) {
      log?.call('probe $id cleanup: dispose ${e.runtimeType} $e');
    }
    return o;
  }

  /// #329 PR 5 R6–R8 + PR 6 D5(b): after the status page [v] was read on [session]: the hint of [id] (only when
  /// [HintSource.wanted]) and the team section (only when [teamEnabled]), from ONE opening of this network's record.
  /// Returns the team section, or null (not enabled, stopped, NetIndex not ready, a failure). Every failure is local:
  /// this read's outcome never depends on it, and the log has the type only. [stop] is true once the cleanup started
  /// or the read ended (then the session may be disposed): it is checked after every await and before every call
  /// into the session (updateHint / teamView are synchronous, so the check right before them holds).
  Future<TeamSeen?> _afterRead(HintSource hs, OwnerSession session, String id, StatusView v, bool Function() stop) async {
    try {
      final wantHint = hs.wanted(id);
      bool wantTeam;
      try {
        wantTeam = teamEnabled();
      } catch (e) {
        wantTeam = false; // fail-closed: no team section
        log?.call('probe $id team flag: ${e.runtimeType}');
      }
      if (!wantHint && !wantTeam) return null;
      // 254 v2.4 / the old console (nodes.dart:1165-1176): first the section without a record (NoNet / NoInfo), then
      // the record's names over it
      if (stop()) return null;
      var team = wantTeam ? session.teamView(recordPlain: null, member: false) : null;
      TeamSeen? seen() => team == null ? null : TeamSeen(v.netId, team);
      if (v.netId.isEmpty) {
        // the node says it is in no network: it really left -> no hint; otherwise (info not read) keep the last one
        if (wantHint && v.nodeState == 1) hs.onHint(id, const UpdateHint(line: '', button: false));
        return seen();
      }
      // §14: NetIndex not computed yet (cold start): nothing is known about this network yet -> no hint change, and
      // no team section (a 「沒有名單」 now would be wrong)
      if (!hs.netReady()) return null;
      if (!hs.netKnown(v.netId)) return seen();
      // net first, then mnet; the first record that opens is used (the old loop's break, nodes.dart:1167-1175)
      for (final (rel, member) in [('net/${v.netId}', false), ('mnet/${v.netId}', true)]) {
        final p = await hs.openNet(rel);
        if (stop()) return null;
        if (p == null) continue;
        if (wantHint) hs.onHint(id, session.updateHint(recordPlain: p, member: member));
        if (wantTeam) team = session.teamView(recordPlain: p, member: member);
        return seen();
      }
      if (wantHint) hs.onHint(id, const UpdateHint(line: '', button: false));
      return seen();
    } catch (e) {
      log?.call('probe $id after read: ${e.runtimeType}');
      return null;
    }
  }
}

/// #329 PR 3 §2.2: the login of a flow under its lease (NodeLink.loginFor). Same attempt rules and budgets as a read
/// (8 s to msg2, then 20 s); at `loggedIn` it ends as a read would (`Res.body`) with a [LoginHandoff] as the extra and
/// leaves the subscription, the link and the session open for the flow.
class HandoffProber extends SessionProber {
  HandoffProber({
    required super.openRecord,
    required super.ownerPub,
    required super.signOwner,
    super.keyError,
    super.log,
    super.answerMax,
  }) : super._handoff();
}
