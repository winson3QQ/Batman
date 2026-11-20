// #329 honest-errors C2: LoginFor.found — with notFound, was a device that looked like this node there? Drives
// core.LoginFor directly: one result per attempt, chosen by address.
import 'package:batman_app/src/flows/net_run.dart' show loginLine, loginFoundLine;
import 'package:batman_app/src/nodelink/core.dart';
import 'package:batman_app/src/nodelink/node_link.dart' show LoginForEnd;
import 'package:flutter_test/flutter_test.dart';

/// Runs one login for Y1 to its end. [scan]: address -> hint (null = none), all seen at 0.3 s. [answer] gives each
/// attempt's result (the n-th attempt on that address, from 1).
LoginFor run(NodeLinkCore c, Map<String, String?> scan, Res Function(String addr, int n) answer) {
  c.startup(0, Page.other);
  c.acquireLease(0);
  final l = c.loginFor(0, 'Y1');
  final n = <String, int>{};
  for (var t = 300; !l.done && t < 70000; t += 100) {
    if (t == 300) scan.forEach((a, h) => l.onScan(t, a, hint: h));
    l.tick(t);
    final a = l.next(t);
    if (a != null) l.result(t, a, Outcome(answer(a.addr, n[a.addr] = (n[a.addr] ?? 0) + 1)));
  }
  return l;
}

NodeLinkCore core() => NodeLinkCore([const Rec('Y1', 1)]);

void main() {
  test('(a) nothing seen -> notFound, not found', () {
    final l = run(core(), {}, (_, _) => Res.noResponse);
    expect((l.end, l.found, l.handshakes), (LoginEnd.notFound, false, 0));
  });

  // negative control: fails without `near` (found did not exist)
  test('(b) a 「像 Y」 address that stays silent -> found', () {
    final l = run(core(), {'a1': 'Y1'}, (_, _) => Res.noResponse);
    expect((l.end, l.found), (LoginEnd.notFound, true));
    expect(l.handshakes, greaterThan(0));
  });

  test('(c) the known 「是 Y」 address stays silent; its memo is dropped after two -> still found', () {
    final c = core()..isY['a1'] = 'Y1';
    final l = run(c, {'a1': null}, (_, _) => Res.noResponse);
    expect((l.end, l.found), (LoginEnd.notFound, true));
    expect(c.isY['a1'], isNull, reason: 'premise: the memo was dropped, found was noted before that');
  });

  // guard, mutation: count every noResponse
  test('(d) only an unknown silent device, no hint -> not found', () {
    final l = run(core(), {'a1': null}, (_, _) => Res.noResponse);
    expect((l.end, l.found), (LoginEnd.notFound, false));
    expect(l.handshakes, greaterThan(0), reason: 'premise: it was tried');
  });

  // the user has two nodes: an address whose hint is the OTHER node stays silent -> not this node, not found
  // mutation: `like[a.addr] == id` -> `like[a.addr] != null`
  test('(d2) a silent address that looks like another node of the user -> not found', () {
    final c = NodeLinkCore([const Rec('Y1', 1), const Rec('Y2', 1)]);
    final l = run(c, {'a1': 'Y2'}, (_, _) => Res.noResponse);
    expect((l.end, l.found), (LoginEnd.notFound, false));
    expect(l.handshakes, greaterThan(0), reason: 'premise: it was tried');
  });

  // guards, mutation: no removal on undecryptable
  test('(e) a 「像 Y」 address: silent once, then 解不開 -> not found', () {
    final l = run(core(), {'a1': 'Y1'}, (_, n) => n == 1 ? Res.noResponse : Res.undecryptable);
    expect((l.end, l.found), (LoginEnd.notFound, false));
    expect(l.handshakes, 2, reason: 'premise: both results came');
  });

  test('(g) the known address: silent once, then 解不開 -> not found', () {
    final c = core()..isY['a1'] = 'Y1';
    final l = run(c, {'a1': null}, (_, n) => n == 1 ? Res.noResponse : Res.undecryptable);
    expect((l.end, l.found), (LoginEnd.notFound, false));
    expect(l.handshakes, greaterThanOrEqualTo(2));
  });

  test('an address whose certificate is refused is not counted (the end is identity)', () {
    final l = run(core(), {'a1': 'Y1'}, (_, n) => n == 1 ? Res.noResponse : Res.certRejected);
    expect((l.end, l.found), (LoginEnd.identity, false));
  });

  // negative control; mutation: no add on refusedOther
  for (final res in [Res.refusedOther, Res.broken]) {
    test('(f) an unknown address, no hint, answering ${res.name} until 60 s -> found', () {
      final l = run(core(), {'a1': null}, (_, _) => res);
      expect((l.end, l.found), (LoginEnd.notFound, true));
    });
  }

  test('two devices: the stranger is 解不開, the node is busy -> found', () {
    final l = run(core(), {'a1': null, 'a2': null}, (a, _) => a == 'a1' ? Res.undecryptable : Res.refusedOther);
    expect((l.end, l.found), (LoginEnd.notFound, true));
    expect(l.near, {'a2'});
  });

  // mutation: loginLine reading `found` before the ending
  test('(h) the line: found is read only with notFound', () {
    expect(loginLine(LoginForEnd.notFound, found: true), loginFoundLine);
    expect(loginLine(LoginForEnd.notFound), '60 秒內沒有找到這台節點。請確認節點開著、靠近手機，再試一次。');
    expect(loginFoundLine, startsWith('附近有像是這台節點的裝置，但沒有連上，或登入沒有完成。'));
    expect(loginFoundLine, isNot(contains('重開')), reason: 'a busy node may be serving another phone');
    for (final e in LoginForEnd.values.where((e) => e != LoginForEnd.notFound)) {
      expect(loginLine(e, found: true), loginLine(e), reason: e.name);
      expect(loginLine(e, found: true), isNot(loginFoundLine), reason: e.name);
    }
  });
}
