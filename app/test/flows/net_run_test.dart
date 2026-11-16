// #329 PR 3 §2.5 / §2.8 / §2.9: NetRun (建立 / 加入網路, one node after the other) and CheckRun (檢查網路) on fake logins
// and a fake console scripted by reply. Every rule is asserted by what the flows send and how the rows end.

import 'dart:async';

import 'package:batman_app/src/flows/net_index.dart';
import 'package:batman_app/src/flows/net_run.dart';
import 'package:batman_app/src/flows/owner_console.dart';
import 'package:batman_app/src/nodelink/core.dart' show Why;
import 'package:batman_app/src/nodelink/handoff.dart';
import 'package:batman_app/src/nodelink/node_link.dart';
import 'package:batman_app/src/rust/api/owner.dart';
import 'package:flutter/services.dart' show PlatformException;
import 'package:flutter_test/flutter_test.dart';

ConsoleReply ans(String text, {String? rel, bool send = false, bool poll = false, bool alive = true, bool key = false}) =>
    ConsoleReply(ReplyKind.answer, text, persistedRel: rel, sendUpdate: send, pollLink: poll, sessionAlive: alive, keyError: key);

class FakeConsole implements OwnerConsole {
  FakeConsole(this.w, this.id);
  final World w;
  final String id;
  bool closed = false;
  @override
  bool get alive => !closed && w.aliveAfter;
  @override
  String nodeDacHash() => w.dac[id] ?? '';
  ConsoleReply _next(String what) {
    w.calls.add('$what $id');
    final q = w.replies[what];
    if (q == null || q.isEmpty) throw StateError('no reply scripted for $what');
    return q.removeAt(0);
  }

  @override
  Future<ConsoleReply> makeNetwork({required String name, required int channel}) async {
    final h = w.holdMake;
    if (h != null) await h.future; // the request in progress
    final r = _next('make');
    final rel = r.persistedRel;
    if (rel != null) w.records[rel] = w.appliedAfterMake;
    return r;
  }

  @override
  Future<ConsoleReply> joinNetwork(String rel) async {
    final t = w.joinThrows;
    if (t != null) throw t; // before anything went out (a record that does not read, the keys)
    final r = _next('join');
    w.onJoin?.call();
    return r;
  }
  @override
  Future<ConsoleReply> confirmNetwork(String rel) async {
    final r = _next('confirm');
    if (w.confirmApplies.contains(rel)) w.records[rel] = true;
    w.confirmed.add(rel);
    return r;
  }

  @override
  Future<ConsoleReply> sendUpdateFor(String rel, {bool member = false}) async => _next('send');
  @override
  Future<ConsoleReply> linkCheck() async {
    if (w.hangLink) {
      w.calls.add('link $id');
      await _closedC.future; // a link check that runs until the console is closed
      return const ConsoleReply(ReplyKind.unclear, linkUnknownLine);
    }
    return _next('link');
  }

  final _closedC = Completer<void>();
  @override
  Future<void> close() async {
    if (!closed) w.calls.add('close $id');
    closed = true;
    if (!_closedC.isCompleted) _closedC.complete();
  }

  @override
  dynamic noSuchMethod(Invocation i) => throw UnimplementedError('${i.memberName}');
}

class World {
  final calls = <String>[];
  final Map<String, List<ConsoleReply>> replies = {};
  final Map<String, bool> records = {}; // rel -> applied (missing = does not read: false)
  final Set<String> confirmApplies = {};
  final confirmed = <String>[];
  final Map<String, LoginForEnd> loginEnds = {}; // id -> how its login ends (default ok)
  final Map<String, String> dac = {};
  final logins = <String>[];
  bool appliedAfterMake = true;
  Completer<void>? holdMake;
  bool hangLink = false;
  Object? joinThrows;
  bool aliveAfter = true;
  Why? blocked;
  bool leaseValid = true;
  void Function()? onLogin, onJoin;
  final asks = <String>[];
  bool goOn = true;
  final reads = <String>[];

  void script(String what, List<ConsoleReply> rs) => (replies[what] ??= []).addAll(rs);

  FlowDeps get deps => FlowDeps(
        login: (id, {bool clearNotY = false}) async {
          logins.add('$id${clearNotY ? ' clear' : ''}');
          onLogin?.call();
          final e = loginEnds[id] ?? LoginForEnd.ok;
          if (e != LoginForEnd.ok) return LoginForResult(e);
          return LoginForResult(LoginForEnd.ok, _FakeHandoff(id));
        },
        console: (h) => FakeConsole(this, (h as _FakeHandoff).fid),
        applied: (rel) async {
          reads.add(rel);
          return records[rel] ?? false;
        },
        blocked: () => blocked,
        leaseValid: () => leaseValid,
      );

  NetRun run(List<String> ids, {bool makes = true, String? joinRel}) => NetRun(deps, ids: ids, makes: makes, joinRel: joinRel, askGoOn: (r) async {
        asks.add(r.id);
        return goOn;
      });
}

class _FakeHandoff implements LoginHandoff {
  _FakeHandoff(this.fid);
  final String fid;
  static final closedIds = <String>[];
  @override
  Future<void> close() async => closedIds.add(fid);
  @override
  dynamic noSuchMethod(Invocation i) => throw UnimplementedError('${i.memberName}');
}

MemberView creator(String dac) =>
    MemberView(name: 'node-x', last4: '', deviceId: '', joining: true, prevCountry: '', dacHash: dac, creator: true, approved: false);
NetEntry pend(String id, String dac) =>
    NetEntry(id, NetView(netId: id, meshId: 'bm', netName: 'n', applied: false, country: 'US', members: [creator(dac)]));
NetEntry applied(String id) => NetEntry(id, const NetView(netId: 'a', meshId: 'bm', netName: 'n', applied: true, country: 'US', members: []));

void main() {
  group('NetRun (§2.5)', () {
    test('make then two joins: one after the other, the others join the record the first one wrote', () async {
      final w = World()
        ..script('make', [ans('[NET_MADE] 網路已建立', rel: 'net/n1')])
        ..script('join', [ans('[JOINED] 已加入'), ans('[JOINED] 已加入')]);
      final run = w.run(['04', '02', '03']);
      await run.run();
      expect(run.rows.map((r) => r.state), everyElement(RowState.ok));
      expect(w.calls, ['make 04', 'close 04', 'join 02', 'close 02', 'join 03', 'close 03'],
          reason: 'each node closed before the next starts');
      expect(run.joinRel, 'net/n1');
      expect(w.confirmed, isEmpty, reason: 'applied at once: no automatic check');
    });

    test('make with no record written -> the whole run stops (D12), no automatic check, the rest not done', () async {
      final w = World()..script('make', [ans('[REQ_FAIL] 網路資料沒有存成功')]);
      final run = w.run(['04', '02']);
      await run.run();
      expect((run.rows[0].state, run.rows[1].state, run.stopped), (RowState.failed, RowState.notDone, StopWhy.makeFailed));
      expect(w.reads, isEmpty);
      expect(w.calls.where((c) => c.startsWith('confirm')), isEmpty);
      expect(w.asks, isEmpty, reason: 'D12: no question');
      expect((run.rows[0].canRetry, run.rows[0].canCheck), (true, false), reason: 'nothing written: 再試這一台');
    });

    test('make written but not applied -> one automatic check on the same session, then on', () async {
      final w = World()
        ..appliedAfterMake = false
        ..confirmApplies.add('net/n1')
        ..script('make', [ans('[NET_STATE] 還在設定中', rel: 'net/n1')])
        ..script('confirm', [ans('[NET_STATE] 網路已建立')])
        ..script('join', [ans('[JOINED] 已加入')]);
      final run = w.run(['04', '02']);
      await run.run();
      expect(run.rows.map((r) => r.state), [RowState.ok, RowState.ok]);
      expect(w.logins, ['04', '02'], reason: 'the session was alive: no second login');
      expect(w.confirmed, ['net/n1']);
    });

    test('make written, session gone -> log in again once for the automatic check', () async {
      final w = World()
        ..appliedAfterMake = false
        ..confirmApplies.add('net/n1')
        ..script('make', [ans('[NET_STATE] 結果不明', rel: 'net/n1', alive: false)])
        ..script('confirm', [ans('[NET_STATE] 網路已建立')]);
      final run = w.run(['04']);
      await run.run();
      expect(run.rows.single.state, RowState.ok);
      expect(w.logins, ['04', '04']);
    });

    test('make written, still not applied after the check -> failed with only 檢查網路, the run stops', () async {
      final w = World()
        ..appliedAfterMake = false
        ..script('make', [ans('[NET_STATE] 結果不明', rel: 'net/n1')])
        ..script('confirm', [ans('[NET_STATE] 沒有套用，可以再建立一次')]);
      final run = w.run(['04', '02']);
      await run.run();
      final r = run.rows[0];
      expect((r.state, r.canCheck, r.canRetry, run.stopped), (RowState.failed, true, false, StopWhy.makeFailed),
          reason: 'design :750: a written make row never offers 再試這一台 (a second network)');
    });

    test('a key error on make: stop, no reread, no automatic check, persistedRel kept (§2.9)', () async {
      final w = World()..script('make', [ans('[REQ_FAIL] 網路資料沒有存成功', rel: 'net/n1', key: true)]);
      final run = w.run(['04', '02']);
      await run.run();
      expect((run.stopped, run.rows[0].persistedRel), (StopWhy.keys, 'net/n1'));
      expect(w.reads, isEmpty);
      expect(w.asks, isEmpty);
    });

    test('a join that is not [JOINED]: asked 繼續 / 停; 停 -> the rest not done', () async {
      final w = World()
        ..goOn = false
        ..script('join', [ans('[COUNTRY] 已取消：這台的國家仍是 TW')]);
      final run = w.run(['02', '03'], makes: false, joinRel: 'net/a');
      await run.run();
      expect((run.rows[0].state, run.rows[1].state, run.stopped), (RowState.failed, RowState.notDone, StopWhy.user));
      expect(w.asks, ['02']);
      expect(run.rows[0].canRetry, isTrue);
    });

    test('a failed join, 繼續 -> the next node runs', () async {
      final w = World()..script('join', [const ConsoleReply(ReplyKind.ended, '[REQ_FAIL] 連線已結束', sessionAlive: false), ans('[JOINED] 已加入')]);
      final run = w.run(['02', '03'], makes: false, joinRel: 'net/a');
      await run.run();
      expect(run.rows.map((r) => r.state), [RowState.failed, RowState.ok]);
    });

    test('the last node failing asks nothing', () async {
      final w = World()..script('join', [ans('[REQ_FAIL] 節點拒絕')]);
      final run = w.run(['02'], makes: false, joinRel: 'net/a');
      await run.run();
      expect(w.asks, isEmpty);
    });

    test('joined and behind: the new secrets are sent; [REQ_FAIL] -> failed 「新密碼沒有換成」, asked', () async {
      final w = World()
        ..script('join', [ans('[JOINED] 已加入（版本落後）', send: true), ans('[JOINED] 已加入')])
        ..script('send', [ans('[REQ_FAIL] 沒有送出：落後太多版')]);
      final run = w.run(['02', '03'], makes: false, joinRel: 'net/a');
      await run.run();
      expect((run.rows[0].state, run.rows[0].note, run.rows[0].joined), (RowState.failed, '已加入，新密碼沒有換成', true));
      expect(w.asks, ['02']);
    });

    test('joined: the link check after it; unknown is still a success, with a note', () async {
      final w = World()
        ..script('join', [ans('[JOINED] 已加入', poll: true)])
        ..script('link', [const ConsoleReply(ReplyKind.unclear, linkUnknownLine)]);
      final run = w.run(['02'], makes: false, joinRel: 'net/a');
      await run.run();
      expect((run.rows[0].state, run.rows[0].note), (RowState.ok, '連線狀態未知'));
    });

    test('a login that finds nothing: the row fails with the reason and the user is asked', () async {
      final w = World()
        ..loginEnds['02'] = LoginForEnd.notFound
        ..script('join', [ans('[JOINED] 已加入')]);
      final run = w.run(['02', '03'], makes: false, joinRel: 'net/a');
      await run.run();
      expect(run.rows[0].line, contains('60 秒內沒有找到這台節點'));
      expect(run.rows[1].state, RowState.ok);
      expect(w.asks, ['02']);
    });

    test('a precondition at login (Bluetooth off): the whole run stops without a question', () async {
      final w = World()
        ..loginEnds['02'] = LoginForEnd.precondition
        ..blocked = Why.bluetoothOff;
      final run = w.run(['02', '03'], makes: false, joinRel: 'net/a');
      await run.run();
      expect((run.stopped, run.rows[1].state), (StopWhy.blocked, RowState.notDone));
      expect(w.asks, isEmpty);
    });

    test('Bluetooth goes off while the question is open: the dialog\'s 停 is the blocked stop (§2.9)', () async {
      final w = World()..script('join', [ans('[REQ_FAIL] x')]);
      final run = NetRun(w.deps, ids: ['02', '03'], makes: false, joinRel: 'net/a', askGoOn: (r) async {
        w.blocked = Why.bluetoothOff; // the page closes the dialog as 停
        return false;
      });
      await run.run();
      expect(run.stopped, StopWhy.blocked);
    });

    test('the page gone during a join: no new-secret send, no link check, nothing after it', () async {
      final w = World()..script('join', [ans('[JOINED] 已加入', send: true)]);
      late NetRun run;
      w.onJoin = () => run.pageGone(); // while the join request runs
      run = w.run(['02', '03'], makes: false, joinRel: 'net/a');
      await run.run();
      expect(w.calls, ['join 02', 'close 02'], reason: 'no send after it, no next node');
      expect((run.rows[0].state, run.rows[0].joined), (RowState.ok, true));
      expect((run.rows[1].state, run.stopped), (RowState.notDone, StopWhy.pageGone));
    });

    test('a login that ends after the page is gone: its session closed, nothing sent (nodes.dart:405-409)', () async {
      final w = World();
      late NetRun run;
      w.onLogin = () => run.pageGone();
      run = w.run(['02'], makes: false, joinRel: 'net/a');
      await run.run();
      expect(w.calls, isEmpty);
      expect(_FakeHandoff.closedIds, contains('02'));
    });

    test('the lease taken back: the run stops, nothing asked', () async {
      final w = World()..script('join', [ans('[REQ_FAIL] x')]);
      w.onLogin = () => w.leaseValid = false;
      final run = w.run(['02', '03'], makes: false, joinRel: 'net/a');
      await run.run();
      expect(run.stopped, StopWhy.leaseLost);
      expect(w.asks, isEmpty);
    });

    test('再試這一台 (join row): the whole join rule again, with clearNotY', () async {
      final w = World()
        ..goOn = false
        ..script('join', [ans('[REQ_FAIL] x'), ans('[JOINED] 已加入', send: true)])
        ..script('send', [ans('[UPDATED] 節點 …0002 已換成新密碼')]);
      final run = w.run(['02'], makes: false, joinRel: 'net/a');
      await run.run();
      await run.retry(run.rows[0]);
      expect(run.rows[0].state, RowState.ok);
      expect(w.logins, ['02', '02 clear']);
      expect(w.calls, contains('send 02'), reason: 'review v16 AF-M1: not only joinNetwork');
    });

    test('再試這一台 (join row) that joins but the send fails again: still failed', () async {
      final w = World()
        ..script('join', [ans('[REQ_FAIL] x'), ans('[JOINED] 已加入（版本落後）', send: true)])
        ..script('send', [ans('[REQ_FAIL] 沒有送出')]);
      final run = w.run(['02'], makes: false, joinRel: 'net/a');
      await run.run();
      await run.retry(run.rows[0]);
      expect((run.rows[0].state, run.rows[0].note), (RowState.failed, '已加入，新密碼沒有換成'));
    });


    test('code review B m1: the failed node is closed before 繼續 / 停 is asked', () async {
      final w = World()..script('join', [ans('[REQ_FAIL] x'), ans('[JOINED] 已加入')]);
      List<String>? atAsk;
      final run = NetRun(w.deps, ids: ['02', '03'], makes: false, joinRel: 'net/a', askGoOn: (r) async {
        atAsk = [...w.calls];
        return true;
      });
      await run.run();
      expect(atAsk, contains('close 02'));
    });

    test('code review A m-1 / B m2: a request that throws before it goes out fails its row with a reason, never 「進行中」',
        () async {
      final w = World()
        ..goOn = false
        ..joinThrows = StateError('store');
      final run = w.run(['02', '03'], makes: false, joinRel: 'net/a');
      await run.run();
      expect(run.rows[0].state, RowState.failed);
      expect(run.rows[0].line, startsWith('[REQ_FAIL] 操作沒有成功'));
      expect(run.rows[0].canRetry, isTrue);
      expect(w.asks, ['02']);
    });

    test('a key error thrown before the request (publicKeys) stops the run like any key error', () async {
      final w = World()..joinThrows = PlatformException(code: 'keystore');
      final run = w.run(['02', '03'], makes: false, joinRel: 'net/a');
      await run.run();
      expect(run.stopped, StopWhy.keys);
      expect(w.asks, isEmpty);
    });

    test('code review A m-2: the page gone during the link check stops it (its console closed)', () async {
      final w = World()
        ..hangLink = true
        ..script('join', [ans('[JOINED] 已加入', poll: true)]);
      final run = w.run(['02'], makes: false, joinRel: 'net/a');
      final done = run.run();
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(w.calls, contains('link 02'));
      run.pageGone();
      await done.timeout(const Duration(seconds: 2));
      expect(w.calls, contains('close 02'));
    });
    test('再試這一台 on a make row with a written record does nothing (only 檢查網路)', () async {
      final w = World()
        ..appliedAfterMake = false
        ..script('make', [ans('[NET_STATE] 結果不明', rel: 'net/n1')])
        ..script('confirm', [ans('[NET_STATE] 沒有套用')]);
      final run = w.run(['04']);
      await run.run();
      final n = w.calls.length;
      await run.retry(run.rows[0]);
      expect(w.calls.length, n);
    });
  });

  group('CheckRun (§2.8)', () {
    Future<NetSnapshot> snap(List<NetEntry> nets) async => NetSnapshot(netFiles: nets.length, nets: nets);

    test('two pending records, the node made the first: one login, the first upgrades, stop', () async {
      final w = World()
        ..dac['04'] = 'd4'
        ..confirmApplies.add('net/p1')
        ..script('confirm', [ans('[NET_STATE] 網路已建立')]);
      final c = CheckRun(w.deps, id: '04', snapshot: () => snap([pend('p2', 'd9'), pend('p1', 'd4')]));
      await c.run();
      expect(c.end, CheckEnd.upgraded);
      expect(w.confirmed, ['net/p1']);
      expect(w.logins, ['04']);
    });

    test('several records of this node: each confirmed in one login until one upgrades; the first given goes first', () async {
      final w = World()
        ..dac['04'] = 'd4'
        ..confirmApplies.add('net/p2')
        ..script('confirm', [ans('[NET_STATE] 沒有套用'), ans('[NET_STATE] 網路已建立')]);
      final c = CheckRun(w.deps, id: '04', first: 'net/p1', snapshot: () => snap([pend('p2', 'd4'), pend('p1', 'd4')]));
      await c.run();
      expect(c.end, CheckEnd.upgraded);
      expect(w.confirmed, ['net/p1', 'net/p2']);
      expect(w.logins, ['04']);
    });

    test('not the node that made them (nodeDacHash): nothing confirmed, no 建立網路', () async {
      final w = World()..dac['02'] = 'd2';
      final c = CheckRun(w.deps, id: '02', snapshot: () => snap([pend('p1', 'd4')]));
      await c.run();
      expect((c.end, c.offerMake), (CheckEnd.notCreator, false));
      expect(w.confirmed, isEmpty);
    });

    test('every record answered, none upgraded, no applied net -> 建立網路 offered', () async {
      final w = World()
        ..dac['04'] = 'd4'
        ..script('confirm', [ans('[NET_STATE] 沒有套用，可以再建立一次')]);
      final c = CheckRun(w.deps, id: '04', snapshot: () => snap([pend('p1', 'd4')]));
      await c.run();
      expect((c.end, c.offerMake), (CheckEnd.answered, true));
    });

    test('answered but the phone has an applied net -> no 建立網路 (design §5.3)', () async {
      final w = World()
        ..dac['04'] = 'd4'
        ..script('confirm', [ans('[NET_STATE] 沒有套用')]);
      final c = CheckRun(w.deps, id: '04', snapshot: () => snap([pend('p1', 'd4'), applied('a1')]));
      await c.run();
      expect((c.end, c.offerMake), (CheckEnd.answered, false));
    });

    test('code review B m5: a node picked by hand that is the verified creator still gets 建立網路 (nodeDacHash decides)', () async {
      final w = World()
        ..dac['04'] = 'd4'
        ..script('confirm', [ans('[NET_STATE] 沒有套用')]);
      final c = CheckRun(w.deps, id: '04', snapshot: () => snap([pend('p1', 'd4')]));
      await c.run();
      expect((c.end, c.offerMake), (CheckEnd.answered, true));
    });

    test('a reply that does not start with [NET_STATE] is no answer: stop, no 建立網路 (v11 U-m1)', () async {
      final w = World()
        ..dac['04'] = 'd4'
        ..script('confirm', [ans('[REQ_FAIL] 節點說 [NET_STATE] 沒有套用'), ans('[NET_STATE] x')]);
      final c = CheckRun(w.deps, id: '04', snapshot: () => snap([pend('p1', 'd4'), pend('p2', 'd4')]));
      await c.run();
      expect((c.end, c.offerMake, w.confirmed.length), (CheckEnd.noAnswer, false, 1));
    });

    test('the login fails -> only 再檢查一次; a second run passes clearNotY', () async {
      final w = World()..loginEnds['04'] = LoginForEnd.notFound;
      final c = CheckRun(w.deps, id: '04', snapshot: () => snap([pend('p1', 'd4')]));
      await c.run();
      expect((c.end, c.offerMake), (CheckEnd.loginFailed, false));
      await c.run(clearNotY: true);
      expect(w.logins, ['04', '04 clear']);
    });


    test('code review A m-3 / B m3: the check page gone during its login: the session closed, nothing confirmed', () async {
      final w = World()
        ..dac['04'] = 'd4'
        ..script('confirm', [ans('[NET_STATE] 網路已建立')]);
      late CheckRun c;
      w.onLogin = () => c.pageGone();
      c = CheckRun(w.deps, id: '04', snapshot: () => snap([pend('p1', 'd4')]));
      await c.run();
      expect(c.end, CheckEnd.blocked);
      expect(w.confirmed, isEmpty);
    });

    test('a check whose records throw (a record store error): ends without an answer, the reason said', () async {
      final w = World();
      final c = CheckRun(w.deps, id: '04', snapshot: () async => throw StateError('store'));
      await c.run();
      expect(c.end, CheckEnd.noAnswer);
      expect(c.lines.single, startsWith('[REQ_FAIL] 操作沒有成功'));
      expect(c.offerMake, isFalse);
    });
    test('records unreadable / none pending', () async {
      final w = World();
      final a = CheckRun(w.deps, id: '04', snapshot: () async => const NetSnapshot(listFailed: true));
      await a.run();
      final b = CheckRun(w.deps, id: '04', snapshot: () => snap([applied('a1')]));
      await b.run();
      expect((a.end, b.end), (CheckEnd.unreadable, CheckEnd.nothingToCheck));
      expect(w.logins, isEmpty);
    });
  });
}
