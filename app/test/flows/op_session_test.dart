// #329 PR 4 §2.0: OpSession.once and OpenSession — lease, login, requests, the console closed before the lease goes;
// busy / login / gone / lease ends send nothing; nothing is re-sent; the update page logs in again when its console is
// gone (N2 / T-X17); a page that goes during a request does not cut it; only `once` keeps the screen on.
// The console and link are owner_console_test's Rig (one Rig per login).
import 'dart:async';

import 'package:batman_app/src/flows/op_session.dart';
import 'package:batman_app/src/flows/owner_console.dart';
import 'package:batman_app/src/nodelink/lease.dart';
import 'package:batman_app/src/nodelink/node_link.dart' show LoginForEnd, LoginForResult;
import 'package:batman_app/src/rust/frb_generated.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fake_node.dart' show FakeRust;
import 'owner_console_pr4_test.dart' show P4Session;
import 'owner_console_test.dart' show Rig, Session;

/// The lease's end, seen with whether the console was still alive then.
class Order implements LeaseListener {
  Order(this.alive);
  final bool Function() alive;
  final seen = <String>[];
  @override
  void revoked(Token t) => seen.add('revoked');
  @override
  void released(Lease l, {required bool revoked}) => seen.add('released alive=${alive()}');
}

class Fx {
  Fx(this.rust, {int logins = 2, Session Function(FakeRust) make = P4Session.new}) {
    rigs = [for (var i = 0; i < logins; i++) Rig(rust, make: make)];
    // one registry for the operation's own lease (each Rig's lease only carries its link)
    reg = rigs.first.reg;
  }
  final FakeRust rust;
  late final List<Rig> rigs;
  late final LeaseRegistry reg;
  final screen = <bool>[];
  int logins = 0, consoles = 0;
  LoginForEnd loginEnd = LoginForEnd.ok;
  bool loginFound = false; // #329 honest-errors C2
  bool busy = false;
  Completer<void>? slowLogin;

  late final OpDeps d = OpDeps(
    acquire: (name) async {
      if (busy) return null;
      // the first Rig's lease is the operation's (Rig acquired it): hand it out once, then fresh ones
      final l = _first;
      if (l != null) {
        _first = null;
        return l;
      }
      return reg.acquire(name, LeaseKind.session);
    },
    busyName: () => '建立網路',
    login: (lease, id) async {
      final w = slowLogin;
      if (w != null) await w.future;
      if (loginEnd != LoginForEnd.ok) return LoginForResult(loginEnd, null, loginFound);
      return LoginForResult(LoginForEnd.ok, rigs[logins++].h);
    },
    console: (lease, h) => rigs[consoles++].c,
    keepScreen: (on) async => screen.add(on),
  );
  late Lease? _first = rigs.first.lease;

  /// Runs [f] while every Rig's clock goes on.
  Future<T> run<T>(Future<T> Function() f) async {
    T? r;
    var done = false;
    unawaited(f().then((x) {
      r = x;
      done = true;
    }));
    for (var t = 0; t < 30000 && !done; t += 500) {
      for (final g in rigs) {
        await g.clock.run(500);
      }
    }
    expect(done, isTrue, reason: 'did not end');
    return r as T;
  }
}

void main() {
  final rust = FakeRust();
  setUpAll(() => RustLib.initMock(api: rust));

  group('once', () {
    test('lease, login, the requests, then the console closed before the lease is released', () async {
      final f = Fx(rust, logins: 1);
      final o = Order(() => f.rigs.first.c.alive);
      f.reg.listeners.add(o);
      final r = await f.run(() => OpSession.once(f.d, 'Y1', '手機 Wi-Fi', (c, gone) => c.settings(), gone: () => false));
      expect((r.end, r.reply?.settings?.apSsid), (OpEnd.done, 'node-ap'));
      expect(o.seen, ['released alive=false'], reason: 'close() first, then release() (§4.4)');
      expect(f.reg.current, isNull);
      expect(f.screen, [true, false]);
    });

    test('T-P2: another operation holds the lease -> busy, nothing logged in', () async {
      final f = Fx(rust)..busy = true;
      final r = await f.run(() => OpSession.once(f.d, 'Y1', 'x', (c, gone) => c.settings(), gone: () => false));
      expect((r.end, r.busyName, f.logins), (OpEnd.busy, '建立網路', 0));
    });

    test('a login that finds no session -> login, nothing sent, the lease released', () async {
      final f = Fx(rust)..loginEnd = LoginForEnd.notFound;
      final r = await f.run(() => OpSession.once(f.d, 'Y1', 'x', (c, gone) => c.settings(), gone: () => false));
      expect((r.end, r.login, f.consoles), (OpEnd.login, LoginForEnd.notFound, 0));
      expect(f.reg.current, isNull);
      expect(r.found, false);
    });

    // #329 honest-errors C2. Negative control: OpSession.once dropping `found` -> FAIL.
    test('a login that ends with the node near: the reply carries found', () async {
      final f = Fx(rust)
        ..loginEnd = LoginForEnd.notFound
        ..loginFound = true;
      final r = await f.run(() => OpSession.once(f.d, 'Y1', 'x', (c, gone) => c.settings(), gone: () => false));
      expect((r.end, r.login, r.found, f.consoles), (OpEnd.login, LoginForEnd.notFound, true, 0));
    });

    test('T-P5: the page goes during the login -> nothing written, the session closed, the lease released', () async {
      final f = Fx(rust, logins: 1)..slowLogin = Completer<void>();
      var gone = false;
      final r = f.run(() => OpSession.once(f.d, 'Y1', '離開網路', (c, g) => c.leave(wait: const Duration(seconds: 360), unclear: 'u'),
          gone: () => gone));
      await f.rigs.first.clock.run(500);
      gone = true;
      f.slowLogin!.complete();
      final x = await r;
      expect(x.end, OpEnd.gone);
      expect(f.rigs.first.radio.written, isEmpty, reason: 'network/leave never went out');
      expect((f.consoles, f.reg.current), (0, null));
    });

    test('T-P3: an unclear reply is returned as it is: no second login, no resend', () async {
      final f = Fx(rust);
      f.rigs.first.radio.silent = true;
      final r = f.run(() => OpSession.once(f.d, 'Y1', 'x', (c, gone) => c.setAp('node-ap', 'correct-horse-1'), gone: () => false));
      await f.rigs.first.clock.run(1000);
      f.rigs.first.radio.drop();
      final x = await r;
      expect((x.end, x.reply?.kind, f.logins), (OpEnd.done, ReplyKind.unclear, 1));
      expect(f.rigs.first.radio.written.length, 1, reason: 'sent once');
    });

    test('code review B m5: the lease goes during the login -> leaseLost, nothing written', () async {
      final f = Fx(rust, logins: 1)..slowLogin = Completer<void>();
      final r = f.run(() => OpSession.once(f.d, 'Y1', 'x', (c, g) => c.settings(), gone: () => false));
      await f.rigs.first.clock.run(500);
      await f.rigs.first.lease.release(); // taken back while the login runs
      f.slowLogin!.complete();
      final x = await r;
      expect(x.end, OpEnd.leaseLost);
      expect((f.consoles, f.rigs.first.radio.written.length), (0, 0));
    });

    test('security review LOW-3: a StateError after a request went out -> failed (結果不明), never leaseLost (沒有送出)', () async {
      final f = Fx(rust, logins: 1);
      final r = await f.run(() => OpSession.once(f.d, 'Y1', 'x', (c, g) async {
            await c.setAp('node-ap', 'correct-horse-1');
            throw StateError('after the write');
          }, gone: () => false));
      expect(r.end, OpEnd.failed);
    });

    test('code review A m11 / B m10: any other error -> failed, never an exception to the page', () async {
      final f = Fx(rust, logins: 1);
      final r = await f.run(() => OpSession.once(f.d, 'Y1', 'x', (c, g) => throw ArgumentError('bug'), gone: () => false));
      expect(r.end, OpEnd.failed);
      expect(f.reg.current, isNull, reason: 'released all the same');
    });

    test('a lease that is no longer valid -> leaseLost, never an exception to the page', () async {
      final f = Fx(rust, logins: 1);
      final l = f.rigs.first.lease;
      await l.release(); // gone before the operation starts
      f.busy = false;
      final r = await f.run(() => OpSession.once(f.d, 'Y1', 'x', (c, gone) => c.settings(), gone: () => false));
      expect(r.end, OpEnd.leaseLost);
    });
  });

  group('OpenSession (the update page)', () {
    test('T-P4: idle, the node closed the login -> the next request logs in first', () async {
      final f = Fx(rust);
      final s = (await OpenSession.open(f.d, 'Y1', '軟體更新'))!;
      final a = await f.run(() => s.run((c) => c.settings(), failed: (_) => throw 'no'));
      expect(a.kind, ReplyKind.answer);
      // the node's idle timeout (300 s): the link drops while no request waits
      f.rigs.first.radio.drop();
      await f.rigs.first.clock.run(500);
      final b = await f.run(() => s.run((c) => c.settings(), failed: (_) => throw 'no'));
      expect((b.kind, f.logins), (ReplyKind.answer, 2));
      await s.pageGone();
    });

    test('a live console is used again (one login)', () async {
      final f = Fx(rust);
      final s = (await OpenSession.open(f.d, 'Y1', '軟體更新'))!;
      await f.run(() => s.run((c) => c.settings(), failed: (_) => throw 'no'));
      await f.run(() => s.run((c) => c.settings(), failed: (_) => throw 'no'));
      expect(f.logins, 1);
      await s.pageGone();
    });

    test('a login that finds nothing -> failed(login)', () async {
      final f = Fx(rust)..loginEnd = LoginForEnd.notFound;
      final s = (await OpenSession.open(f.d, 'Y1', '軟體更新'))!;
      final why = await f.run(() => s.run<OpReply?>((c) async => null, failed: (w) => w));
      expect((why?.end, why?.login, why?.found), (OpEnd.login, LoginForEnd.notFound, false));
      await s.pageGone();
    });

    // #329 honest-errors C2. Negative control: OpenSession.run dropping `found` -> FAIL.
    test('a login that ends with the node near -> failed(login) carries found', () async {
      final f = Fx(rust)
        ..loginEnd = LoginForEnd.notFound
        ..loginFound = true;
      final s = (await OpenSession.open(f.d, 'Y1', '軟體更新'))!;
      final why = await f.run(() => s.run<OpReply?>((c) async => null, failed: (w) => w));
      expect((why?.end, why?.login, why?.found), (OpEnd.login, LoginForEnd.notFound, true));
      await s.pageGone();
    });

    test('B m3: the page goes during a request: the request is not cut; then the console closes and the lease goes',
        () async {
      final f = Fx(rust);
      final o = Order(() => f.rigs.first.c.alive);
      f.reg.listeners.add(o);
      final s = (await OpenSession.open(f.d, 'Y1', '軟體更新'))!;
      f.rigs.first.radio.silent = true;
      final r = f.run(() => s.run((c) => c.settings(), failed: (_) => throw 'no'));
      await f.rigs.first.clock.run(500);
      await s.pageGone();
      expect(f.reg.current, isNotNull, reason: 'held while the request runs');
      expect(f.rigs.first.c.alive, isTrue, reason: 'not cut');
      f.rigs.first.radio.tx.add([71]); // the answer (fGet + 1)
      expect((await r).kind, ReplyKind.answer);
      await f.rigs.first.clock.run(500);
      expect(o.seen, ['released alive=false']);
    });

    test('code review B m5: the page goes during the login -> nothing sent, the session closed', () async {
      final f = Fx(rust)..slowLogin = Completer<void>();
      final s = (await OpenSession.open(f.d, 'Y1', '軟體更新'))!;
      final r = f.run(() => s.run<OpReply?>((c) async {
            await c.settings();
            return null;
          }, failed: (w) => w));
      await f.rigs.first.clock.run(500);
      await s.pageGone();
      f.slowLogin!.complete();
      final why = await r;
      expect((why?.end, f.consoles), (OpEnd.gone, 0));
      expect(f.rigs.first.radio.written, isEmpty);
    });

    test('after pageGone nothing starts', () async {
      final f = Fx(rust);
      final s = (await OpenSession.open(f.d, 'Y1', '軟體更新'))!;
      await s.pageGone();
      final why = await f.run(() => s.run<OpReply?>((c) async => null, failed: (w) => w));
      expect((why?.end, f.logins), (OpEnd.gone, 0));
    });

    test('C M1: the update page\'s screen flag is never touched', () async {
      final f = Fx(rust);
      final s = (await OpenSession.open(f.d, 'Y1', '軟體更新'))!;
      await f.run(() => s.run((c) => c.settings(), failed: (_) => throw 'no'));
      await s.pageGone();
      expect(f.screen, isEmpty);
    });

    test('busy at open -> null (the page does not open)', () async {
      final f = Fx(rust)..busy = true;
      expect(await OpenSession.open(f.d, 'Y1', '軟體更新'), isNull);
    });
  });
}
