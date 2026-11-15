// #329 §4.3.3-3/-4: one attempt's login + status read with the Rust OwnerSession, mapped to the core's outcome.
// The record is opened (Keystore) for this attempt only and the plain bytes are dropped with the session; nothing
// here writes a record (an automatic read only reads, §4.3.3-9). Platform calls are injected so tests can fake them.
import 'dart:async';
import 'dart:typed_data';

import '../rust/api/claim.dart' show frameLimit;
import '../rust/api/owner.dart';
import 'ble_gate.dart';
import 'core.dart';
import 'node_link.dart';

const eForbidden = 3; // batman-proto flow.rs E_FORBIDDEN: the node does not accept this owner key

class SessionProber implements Prober {
  SessionProber({required this.openRecord, required this.ownerPub, required this.signOwner, this.log});

  /// The plain node record of [id] (store + Keystore), or null when it is gone.
  final Future<Uint8List?> Function(String id) openRecord;
  final Future<Uint8List> Function() ownerPub;
  final Future<Uint8List> Function(Uint8List input) signOwner;
  final void Function(String line)? log;

  static const answerMax = Duration(seconds: 20); // after msg2: the existing 20 s (F3)

  @override
  Future<Outcome> probe(GateLink link, String id, {required Duration msg2, required Future<void> cancelled}) async {
    final record = await openRecord(id);
    if (record == null) return const Outcome(Res.noResponse);
    final mtu = await link.requestMtu(517);
    final fl = await frameLimit(ctrl: await link.read(Char.ctrl), mtu: mtu);
    final (s, first) = OwnerSession.start(recordPlain: record, ownerPub: await ownerPub(), frameLimit: fl);
    final result = Completer<Outcome>();
    var gotFrame = false;
    var loggedIn = false;
    void done(Outcome o) {
      if (!result.isCompleted) result.complete(o);
    }

    Future<void> run(OwnerStep? st) async {
      while (st != null && !result.isCompleted) {
        switch (st.kind) {
          case OwnerKind.write:
            for (final f in st.frames) {
              await link.write(Char.rx, f);
            }
            st = null;
          case OwnerKind.sign:
            Uint8List der;
            try {
              der = await signOwner(st.signInput);
            } catch (_) {
              der = Uint8List(0); // the key could not sign: the login ends (X26: KeyGate checks again)
            }
            st = s.signed(der: der);
          case OwnerKind.loggedIn:
            loggedIn = true;
            st = s.requestStatusPage();
          case OwnerKind.answer:
            final v = s.statusView(hasNet: false, hasMnet: false);
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
            done(loggedIn ? const Outcome(Res.broken) : const Outcome(Res.noResponse));
            st = null;
        }
      }
    }

    final sub = link.subscribe(Char.tx).listen((f) {
      gotFrame = true;
      run(s.onFrame(frame: f)).catchError((Object _) => done(Outcome(loggedIn ? Res.broken : Res.noResponse)));
    }, onError: (Object _) => done(Outcome(loggedIn ? Res.broken : Res.noResponse)));
    final t1 = Timer(msg2, () {
      if (!gotFrame) done(const Outcome(Res.noResponse)); // §4.3.3-3: 8 s to msg2
    });
    final t2 = Timer(msg2 + answerMax, () => done(Outcome(loggedIn ? Res.broken : Res.noResponse)));
    unawaited(cancelled.then((_) => done(const Outcome(Res.noResponse))));
    try {
      await run(first);
      return await result.future;
    } finally {
      t1.cancel();
      t2.cancel();
      await sub.cancel();
    }
  }
}
