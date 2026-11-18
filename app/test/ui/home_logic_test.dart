// #329 design §5.1 T-H1: the home status area is the first row of the table that holds, top to bottom. Every row is
// reached, and when two rows hold the upper one wins.
import 'package:batman_app/src/nodelink/core.dart';
import 'package:batman_app/src/rust/api/owner.dart' show StatusView;
import 'package:batman_app/ui/home_logic.dart';
import 'package:batman_app/ui/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

StatusView sv({String color = 'green', int nodeState = 2, String warning = '', String sentence = '可以使用'}) => StatusView(
    color: color,
    row: '3',
    sentence: sentence,
    lagNote: '',
    warning: warning,
    nodeState: nodeState,
    netId: '',
    version: '',
    tech: const [],
    fresh: true,
    rateNote: '',
    unfinished: '',
    unfinishedUnderVerdict: false,
    canLeave: false);

/// A node: read and fresh with [v], or unreachable for [why], or not read yet.
NodeInfo node(String id, {StatusView? v, Why? why, bool fresh = true, Concl? last}) {
  final s = NodeState()
    ..kind = v != null ? Kind.read : (why != null ? Kind.unreachable : Kind.unread)
    ..why = why
    ..view = v?.color ?? ''
    ..last = last ?? (v != null ? Concl.read : null);
  return NodeInfo(
      id: id,
      name: '節點 ${last4(id)}',
      state: s,
      fresh: v != null && fresh,
      shownWhy: why,
      view: v,
      readWall: v != null ? DateTime(2026, 11, 15, 22, 48) : null);
}

HomeHero home(List<NodeInfo> ns, {Why? blocked, bool first = false, Set<String>? firstIds, int todos = 0}) => decideHome(
    HomeInputs(nodes: ns, blocked: blocked, firstRoundIds: firstIds ?? (first ? {for (final n in ns) n.id} : {}), todos: todos));

void main() {
  final ok = node('aaaa0001', v: sv());
  test('row 1: Bluetooth off, above everything', () {
    final h = home([node('x1', why: Why.identity)], blocked: Why.bluetoothOff, todos: 3);
    expect((h.row, h.look, h.action), (1, Look.bad, HomeAction.openBluetooth));
  });
  test('row 2: no permission / keys', () {
    expect(home([ok], blocked: Why.noPermission).row, 2);
    expect(home([ok], blocked: Why.noPermission).action, HomeAction.allowBluetooth);
    expect(home([ok], blocked: Why.keys).row, 2);
  });
  test('r2 C-m1: rows 2 / 3 — no permission and no node yet: the permission first', () {
    expect(home([], blocked: Why.noPermission).row, 2);
  });

  test('r2 C-m2: row 5 — 還沒輪到 is not a conclusion in the first rounds', () {
    expect(home([node('q1', last: Concl.notYet)], first: true).row, 5);
  });

  test('r2 C-m2: row 10 sentences per the design', () {
    expect(home([node('s1', v: sv(), fresh: false)], first: true).text, '正在找節點 S1…');
    expect(home([node('s2', last: Concl.notYet)]).text, '附近有還沒認出來的裝置，還在找節點 S2');
    expect(home([node('s3', v: sv(), fresh: false)]).text, '還沒讀到節點 S3 的狀態');
  });

  test('T8 (code review A-m1): row 10 asks the node it names whether its first rounds are over', () {
    // s1: read before, its first rounds over; n2: just claimed, in its first rounds (row 5 does not hold: s1 concluded)
    final old = node('s1', v: sv(), fresh: false), fresh = node('n2');
    final h = home([old, fresh], firstIds: {'n2'});
    expect(h.row, 10);
    expect(h.text, '還沒讀到 2 台節點的狀態', reason: 'the named node s1 is past its first rounds: not 「正在找」');
    expect(home([fresh, old], firstIds: {'n2'}).text, '正在找節點 N2…', reason: 'the named node n2 is in its first rounds');
  });

  test('row 3: no node yet -> add a node', () {
    final h = home([]);
    expect((h.row, h.action), (3, HomeAction.addNode));
  });
  test('row 4: 身分不符 wins over everything below it', () {
    final h = home([node('bbbb0002', why: Why.identity), node('cccc0003', v: sv(nodeState: 1))], todos: 2);
    expect((h.row, h.look, h.node), (4, Look.bad, 'bbbb0002'));
    expect(home([node('bbbb0002', why: Why.identity, last: Concl.reason)], first: true).row, 4,
        reason: 'an identity alarm is shown at once, also in the first rounds');
  });
  test('row 5: the first rounds, nothing concluded yet -> 正在找 (busy, no button)', () {
    final h = home([node('dddd0004')], first: true);
    expect((h.row, h.look, h.action), (5, Look.busy, HomeAction.none));
    // once a target has a conclusion the first rounds no longer hide it
    expect(home([node('dddd0004', why: Why.notFound, last: Concl.notFound)], first: true).row, 8);
  });
  test('row 6: not in a network (one and many); the button follows the phone''s network records (review B-M1)', () {
    expect(home([node('eeee0005', v: sv(nodeState: 1, color: 'red'))]).text, '節點 0005 還沒加入隊伍網路');
    final ns = [node('e1', v: sv(nodeState: 1)), node('e2', v: sv(nodeState: 1)), node('f1', v: sv(color: 'red'))];
    HomeHero h6(NetRecords r) => decideHome(HomeInputs(nodes: ns, blocked: null, todos: 0, records: r));
    expect((h6(NetRecords.net).row, h6(NetRecords.net).text), (6, '有 2 台節點還沒加入隊伍網路'));
    expect((h6(NetRecords.net).action, h6(NetRecords.mnet).action), (HomeAction.joinNetwork, HomeAction.joinNetwork));
    expect(h6(NetRecords.mpend).action, HomeAction.seeRequest);
    expect((h6(NetRecords.none).action, h6(NetRecords.none).second), (HomeAction.makeNetwork, HomeAction.joinTeam),
        reason: 'a phone without any network starts one; joining a team is the second way');
  });

  test('r2 D-m9: records that could not be read -> the neutral 加入網路, never 建立網路', () {
    final h = decideHome(HomeInputs(
        nodes: [node('u1', v: sv(nodeState: 1))], blocked: null, todos: 0, records: NetRecords.unknown));
    expect((h.action, h.second), (HomeAction.joinNetwork, HomeAction.none));
  });

  // #329 PR 6 T6-11 (P1-3): a node without a nickname is named 「節點 XXXX」 — its meta does not say the last four again;
  // with a nickname it does. Negative control: the tail always added -> FAIL
  test('P1-3: the meta repeats no last four for a node named by them', () {
    final plain = node('0000000000000c4f2a', v: sv());
    expect(nodeRowWords(plain, firstRounds: false).$3, '讀取於 22:48');
    final nick = NodeInfo(
        id: plain.id, name: '前門', state: plain.state, fresh: true, shownWhy: null, view: plain.view, readWall: plain.readWall);
    expect(nodeRowWords(nick, firstRounds: false).$3, '讀取於 22:48　後四碼 4F2A');
    expect(nodeRowWords(node('0000000000000c4f2a'), firstRounds: false).$3, '', reason: 'never read, no nickname: nothing to add');
  });

  test('r2 D-m6: an older read of a node not in a network says so, not 「有問題」', () {
    final w = nodeRowWords(node('o1', v: sv(nodeState: 1, color: 'red'), fresh: false), firstRounds: false);
    expect(w.$2, endsWith('，當時還沒加入隊伍網路'));
  });

  test('review A-M5: adjacent rows 10/11, 11/12, 12/13 — the upper one wins', () {
    final stale = node('s1', v: sv(), fresh: false);
    final yellow = node('y1', v: sv(color: 'yellow'));
    final gray = node('g1', v: sv(color: 'gray'));
    expect(home([stale], todos: 1).row, 10);
    expect(home([yellow], todos: 1).row, 11);
    expect(home([yellow, gray]).row, 12);
    expect(home([node('g2', v: sv(color: 'gray', warning: '時間不準'))]).row, 12, reason: 'a warning wins over gray');
  });

  test('review A-M5: rows 6 and 7 only from fresh reads', () {
    expect(home([node('n1', v: sv(nodeState: 1), fresh: false)]).row, 10);
    expect(home([node('r1', v: sv(color: 'red'), fresh: false)]).row, 10);
  });

  test('review A-M2: a fresh read without screen data (or a 2'') is never 一切正常', () {
    final s = NodeState()
      ..kind = Kind.read
      ..view = "2'"
      ..last = Concl.read;
    final blank = NodeInfo(id: 'b1', name: '節點 00B1', state: s, fresh: true, shownWhy: null);
    final h = home([blank]);
    expect((h.row, h.look), (13, Look.unk));
    final twoP = NodeInfo(
        id: 'b2', name: '節點 00B2', state: s, fresh: true, shownWhy: null, view: sv(color: 'gray', sentence: '狀態未知 — 請按「重新整理」；一直如此請找維修人員'));
    expect(home([twoP]).text, '節點 00B2：狀態未知 — 請按「重新整理」；一直如此請找維修人員');
  });
  test('row 7: a red node, above unreachable', () {
    final h = home([node('gggg0007', v: sv(color: 'red', sentence: '沒有連上網路')), node('h1', why: Why.notFound)]);
    expect((h.row, h.text), (7, '節點 0007：沒有連上網路'));
    expect(home([node('r1', v: sv(color: 'red')), node('r2', v: sv(color: 'red'))]).action, HomeAction.showList);
  });
  test('row 8: unreachable', () {
    final h = home([node('iiii0008', why: Why.notFound), ok]);
    expect((h.row, h.look, h.text), (8, Look.warn, '手機連不到節點 0008'));
  });
  test('row 10: stale or not read yet (after the first rounds)', () {
    final h = home([node('jjjj0010', v: sv(), fresh: false)]);
    expect((h.row, h.look, h.action), (10, Look.unk, HomeAction.refresh));
  });
  test('row 11: todos, below every node problem', () {
    expect(home([ok], todos: 2).text, '有 2 件事要你處理');
    expect(home([node('k1', why: Why.notFound)], todos: 2).row, 8);
  });
  test('row 12: a yellow node or a warning', () {
    expect(home([node('llll0012', v: sv(color: 'yellow', sentence: '訊號弱'))]).row, 12);
    expect(home([node('l2', v: sv(warning: '時間不準'))]).text, '節點 L2：時間不準');
  });
  test('row 13: gray', () {
    expect(home([node('mmmm0013', v: sv(color: 'gray'))]).row, 13);
  });
  test('row 14: all green', () {
    expect((home([ok]).row, home([ok]).look), (14, Look.ok));
    expect(home([ok, node('n2', v: sv())]).next, contains('2 台節點'));
  });

  test('node rows: the reason first, then the fresh read, then the old read, then searching', () {
    expect(nodeRowWords(node('p1', why: Why.notFound), firstRounds: false).$2, '手機連不到這台節點');
    expect(nodeRowWords(ok, firstRounds: false).$1, Look.ok);
    final old = nodeRowWords(node('p2', v: sv(color: 'red'), fresh: false), firstRounds: false);
    expect((old.$1, old.$2), (Look.unk, '上次讀取 22:48，當時有問題'));
    expect(nodeRowWords(node('p3'), firstRounds: true).$1, Look.busy);
    expect(nodeRowWords(node('p4', v: sv(nodeState: 1)), firstRounds: false).$2, '還沒加入隊伍網路');
  });

  test('r3 F-m6: the row time says 讀取於 only for a fresh read, 上次讀取 for an older one', () {
    expect(nodeRowWords(node('t1', v: sv()), firstRounds: false).$3, startsWith('讀取於 22:48'));
    // unreachable now, read earlier in this run: the reason, and the older read as 上次讀取
    final s = NodeState()
      ..kind = Kind.unreachable
      ..why = Why.notFound
      ..last = Concl.notFound;
    final gone = NodeInfo(
        id: 't2', name: '節點 T2', state: s, fresh: false, shownWhy: Why.notFound, view: sv(), readWall: DateTime(2026, 11, 15, 22, 48));
    expect(nodeRowWords(gone, firstRounds: false).$3, startsWith('上次讀取 22:48'));
  });

  // #329 PR 7 T16 (#329:222): a name in a Dart sentence — one space where an ASCII letter or digit at its edge meets a
  // CJK character; none between CJK characters or next to CJK punctuation. Negative control: a space always added ->
  // the Chinese name FAILs.
  group('T16 names in sentences', () {
    NodeInfo named(String name, {StatusView? v, Why? why}) {
      final n = node('aaaa0001', v: v, why: why);
      return NodeInfo(id: n.id, name: name, state: n.state, fresh: n.fresh, shownWhy: n.shownWhy, view: n.view, readWall: n.readWall);
    }

    test('an English name', () {
      expect(home([named('Alpha', why: Why.notFound)]).text, '手機連不到 Alpha');
      expect(home([named('Alpha', v: sv(nodeState: 1))]).text, 'Alpha 還沒加入隊伍網路');
      expect(home([named('Alpha', why: Why.identity)]).text, 'Alpha 的身分和這支手機記錄的不同');
    });
    test('a Chinese name', () {
      expect(home([named('山貓', why: Why.notFound)]).text, '手機連不到山貓');
      expect(home([named('山貓', v: sv(nodeState: 1))]).text, '山貓還沒加入隊伍網路');
      expect(home([named('山貓')]).text, '還沒讀到山貓的狀態');
    });
    test('English first, Chinese last; 「節點 XXXX」', () {
      expect(home([named('A山', why: Why.notFound)]).text, '手機連不到 A山');
      expect(home([named('A山', v: sv(nodeState: 1))]).text, 'A山還沒加入隊伍網路');
      expect(home([named('節點 7D2C')]).text, '還沒讀到節點 7D2C 的狀態');
      expect(home([named('節點 7D2C', why: Why.notFound)]).text, '手機連不到節點 7D2C');
    });
    test('nameIn: punctuation, empty sides, an empty name', () {
      expect(nameIn('移除', 'Bob', '，全隊換密碼'), '移除 Bob，全隊換密碼');
      expect(nameIn('移除', '王小明', '，全隊換密碼'), '移除王小明，全隊換密碼');
      expect(nameIn('', '04', '加入「山隊」還沒有完成。'), '04 加入「山隊」還沒有完成。');
      expect(nameIn('「', 'Bob', '」'), '「Bob」');
      expect(nameIn('正在找', 'Alpha', '…'), '正在找 Alpha…', reason: 'none before 「…」');
      expect(nameIn('移除', '', ''), '移除');
    });
  });
}
