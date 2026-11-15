// #329 §4.3.3-3/-4: one attempt's login + status read with the Rust OwnerSession, mapped to the core's outcome.
// The record is opened (Keystore) for this attempt only; the session is disposed and the plain bytes zeroed when the
// attempt ends (review pr1 B-m2). Nothing here writes a record (an automatic read only reads, §4.3.3-9). Platform
// calls are injected so tests can fake them.
import 'dart:async';
import 'dart:typed_data';

import '../rust/api/claim.dart' show frameLimit;
import '../rust/api/owner.dart';
import 'ble_gate.dart';
import 'core.dart';
import 'node_link.dart';

const eForbidden = 3; // batman-proto flow.rs E_FORBIDDEN: the node does not accept this owner key

class SessionProber implements Prober {
  SessionProber({
    required this.openRecord,
    required this.ownerPub,
    required this.signOwner,
    this.keyError,
    this.log,
    this.answerMax = const Duration(seconds: 20),
  });

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
    var gotFrame = false;
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
      if (!gotFrame) done(const Outcome(Res.noResponse));
    }));
    unawaited(cancelled.then((_) => done(const Outcome(Res.noResponse))));

    OwnerSession? s;
    Uint8List? record;
    StreamSubscription<List<int>>? sub;
    Timer? answer;

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
            st = session.requestStatusPage();
          case OwnerKind.answer:
            final v = session.statusView(hasNet: false, hasMnet: false);
            // a status answer that is an error code (Rust row 2') is 不變, not a read (§4.3.3-4, round-5 B-M1);
            // E_UNSUPPORTED is row 1, a definite answer
            done(v.row == "2'" ? const Outcome(Res.errorCode) : Outcome(Res.body, v.color));
            st = null;
          case OwnerKind.ended:
            done(switch (st.loginEnd) {
              2 => const Outcome(Res.undecryptable),
              3 => const Outcome(Res.certRejected),
              4 => st.loginCode.toInt() == eForbidden ? const Outcome(Res.refusedForbidden) : const Outcome(Res.refusedOther),
              // 5 (Broken in the login) and anything before a login: noResponse — never plant a 「是 Y」 (driver
              // contract, core.dart Res)
              _ => loggedIn ? const Outcome(Res.broken) : const Outcome(Res.noResponse),
            });
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
      record = r;
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
      sub = link.subscribe(Char.tx).listen((f) {
        if (!gotFrame) {
          gotFrame = true;
          answer = Timer(answerMax, () => done(failed())); // after msg2: the existing 20 s (F3)
        }
        if (result.isCompleted) return;
        run(session.onFrame(frame: f)).catchError((Object _) => done(failed()));
      }, onError: (Object _) => done(failed()));
      await run(first);
    }

    // the steps before msg2 race the deadline: a step that never returns cannot hold the attempt (review pr1 A-M4)
    unawaited(work().catchError((Object _) => done(failed())));
    try {
      return await result.future;
    } finally {
      answer?.cancel();
      await sub?.cancel();
      s?.dispose();
      final r = record;
      if (r != null) r.fillRange(0, r.length, 0);
    }
  }
}
