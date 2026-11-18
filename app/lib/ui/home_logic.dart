// #329 design §5.1: what the home page's status area says (first row of the table that holds, top to bottom) and
// what each node row says. Pure: inputs in, words out, so the table order is tested directly (T-H1).
import '../src/nodelink/core.dart';
import '../src/rust/api/owner.dart' show StatusView;
import 'ui_state.dart' show UiNode;
import 'widgets.dart';

String last4(String id) => (id.length > 4 ? id.substring(id.length - 4) : id).toUpperCase();

/// What a screen knows about one node right now.
class NodeInfo {
  const NodeInfo({
    required this.id,
    required this.name,
    required this.state,
    required this.fresh,
    required this.shownWhy,
    this.view,
    this.readWall,
    this.prev,
  });
  final String id;
  final String name; // the nickname (UiState) or 「節點 XXXX」
  final NodeState state;
  final bool fresh; // §4.3.1 「新鮮」
  final Why? shownWhy; // overlay first (Bluetooth / permission / keys), then the node's own reason
  final StatusView? view; // the last read's status page
  final DateTime? readWall; // the last read, wall clock
  final UiNode? prev; // UiState: the kind and time of a read from an earlier run (§4.6), display only

  bool get notInNetwork => view != null && view!.nodeState.toInt() == 1; // §5.1 row 6 (F46)
}

/// Which network records this phone holds (file names only; §4.3.8): net wins over mnet over mpend.
enum NetRecords { net, mnet, mpend, none, unknown }

class HomeInputs {
  const HomeInputs({
    required this.nodes,
    required this.blocked,
    required this.firstRounds,
    required this.todos,
    this.records = NetRecords.none,
  });
  final List<NodeInfo> nodes;
  final Why? blocked; // Bluetooth off / no permission / keys
  final bool firstRounds; // some node's first two rounds of this run are not over (#329 PR 7 T8)
  final int todos;
  final NetRecords records; // row 6's button
}

enum HomeAction { none, openBluetooth, allowBluetooth, addNode, seeNode, joinNetwork, makeNetwork, seeRequest, joinTeam, refresh, showList }

class HomeHero {
  const HomeHero(this.row, this.look, this.text,
      {this.next, this.action = HomeAction.none, this.second = HomeAction.none, this.node});
  final int row; // the §5.1 table row that decided it
  final Look look;
  final String text;
  final String? next;
  final HomeAction action;
  final HomeAction second; // a secondary (text) button, row 6 only
  final String? node; // the node the action is about
}

String _many(List<NodeInfo> ns, String one, String many) => ns.length == 1 ? one.replaceAll('X', ns.first.name) : many.replaceAll('N', '${ns.length}');

/// The §5.1 table, top to bottom. Row 9 was removed in v10 (預期離線).
HomeHero decideHome(HomeInputs i) {
  final ns = i.nodes;
  if (i.blocked == Why.bluetoothOff) return const HomeHero(1, Look.bad, '藍牙沒有打開', action: HomeAction.openBluetooth);
  if (i.blocked == Why.noPermission) {
    return const HomeHero(2, Look.bad, 'app 還沒有藍牙權限', action: HomeAction.allowBluetooth);
  }
  if (i.blocked == Why.keys) return const HomeHero(2, Look.bad, '這支手機的金鑰現在不能用', next: '請重新開啟 app；一直如此請找維修人員');
  if (ns.isEmpty) {
    // §5.2 board 2.1's words
    return const HomeHero(3, Look.unk, '還沒有節點',
        next: '掃描節點機身上的 QR code，把它加入這支手機。之後就能建立網路、看連線狀態。', action: HomeAction.addNode);
  }
  final identity = ns.where((n) => n.shownWhy == Why.identity).toList();
  if (identity.isNotEmpty) {
    return HomeHero(4, Look.bad, '${identity.first.name} 的身分和這支手機記錄的不同',
        action: HomeAction.seeNode, node: identity.first.id);
  }
  final concluded = ns.any((n) => n.state.last != null && n.state.last != Concl.notYet && n.state.last != Concl.queued);
  if (i.firstRounds && !concluded) return const HomeHero(5, Look.busy, '正在找你的節點…', next: 'app 會自己找回節點，你不用按任何東西。通常幾秒鐘。');
  final fresh = ns.where((n) => n.fresh && n.view != null).toList();
  final notIn = fresh.where((n) => n.notInNetwork).toList();
  if (notIn.isNotEmpty) {
    // §5.1 row 6: the button follows the phone's network records (PR 2 review B-M1)
    final (act, second) = switch (i.records) {
      NetRecords.net || NetRecords.mnet || NetRecords.unknown => (HomeAction.joinNetwork, HomeAction.none),
      NetRecords.mpend => (HomeAction.seeRequest, HomeAction.none),
      NetRecords.none => (HomeAction.makeNetwork, HomeAction.joinTeam),
    };
    return HomeHero(6, Look.warn, _many(notIn, 'X 還沒加入隊伍網路', '有 N 台節點還沒加入隊伍網路'),
        action: act, second: second, node: notIn.first.id);
  }
  final red = fresh.where((n) => n.state.view == 'red').toList();
  if (red.isNotEmpty) {
    return HomeHero(7, Look.bad,
        red.length == 1 ? '${red.first.name}：${red.first.view!.sentence}' : '有 ${red.length} 台節點有問題',
        action: red.length == 1 ? HomeAction.seeNode : HomeAction.showList, node: red.first.id);
  }
  final unreach = ns.where((n) => n.shownWhy != null && n.shownWhy != Why.identity).toList();
  if (unreach.isNotEmpty) {
    return HomeHero(8, Look.warn, _many(unreach, '手機連不到X', '手機連不到 N 台節點'),
        next: '可能沒開機、還在開機、離太遠，或另一支手機正在連它。',
        action: unreach.length == 1 ? HomeAction.seeNode : HomeAction.showList, node: unreach.first.id);
  }
  final stale = ns.where((n) => !n.fresh).toList();
  if (stale.isNotEmpty) {
    // §5.1 row 10 (review A-m5): the first rounds -> 正在找; devices not recognised yet -> say so; else not read yet
    final unknownNear = stale.where((n) => n.state.last == Concl.notYet).toList();
    final text = i.firstRounds
        ? '正在找${stale.first.name}…'
        : unknownNear.isNotEmpty
            ? '附近有還沒認出來的裝置，還在找${unknownNear.first.name}'
            : _many(stale, '還沒讀到X 的狀態', '還沒讀到 N 台節點的狀態');
    return HomeHero(10, Look.unk, text, action: HomeAction.refresh);
  }
  if (i.todos > 0) return HomeHero(11, Look.warn, '有 ${i.todos} 件事要你處理');
  final yellow = fresh.where((n) => n.state.view == 'yellow' || (n.view?.warning.isNotEmpty ?? false)).toList();
  if (yellow.isNotEmpty) {
    final s = yellow.first.view!;
    return HomeHero(12, Look.warn, '${yellow.first.name}：${s.warning.isNotEmpty ? s.warning : s.sentence}',
        action: HomeAction.seeNode, node: yellow.first.id);
  }
  final gray = fresh.where((n) => n.state.view != 'green').toList();
  if (gray.isNotEmpty) {
    return HomeHero(13, Look.unk, '${gray.first.name}：${gray.first.view!.sentence}',
        action: HomeAction.seeNode, node: gray.first.id);
  }
  // a fresh read without screen data never reads as 「一切正常」 (PR 2 review A-M2)
  final blank = ns.where((n) => n.fresh && n.view == null).toList();
  if (blank.isNotEmpty) {
    return HomeHero(13, Look.unk, '${blank.first.name}：有回應，還沒拿到狀態', action: HomeAction.seeNode, node: blank.first.id);
  }
  return HomeHero(14, Look.ok, '一切正常，可以使用',
      next: ns.length == 1 ? '你的節點連上了隊伍網路。現在沒有需要你處理的事。' : '你的 ${ns.length} 台節點都連上了隊伍網路。現在沒有需要你處理的事。');
}

String hhmm(DateTime t) => '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
String hhmmss(DateTime t) => '${hhmm(t)}:${t.second.toString().padLeft(2, '0')}';

/// One node row: (look, sentence, meta).
(Look, String, String) nodeRowWords(NodeInfo n, {required bool firstRounds}) {
  // #329 PR 6 P1-3: a node without a nickname is already named 「節點 XXXX」: its meta does not repeat the last four
  final tail = n.name == '節點 ${last4(n.id)}' ? '' : '後四碼 ${last4(n.id)}';
  String withTail(String s) => tail.isEmpty ? s : '$s　$tail';
  final when = n.readWall;
  // §4.6: without a read in this run, an earlier run's read (UiState), unk style only; a future time is 「之前讀過」
  String? before;
  final p = n.prev;
  if (when == null && p != null && p.readAt != null) {
    final at = DateTime.fromMillisecondsSinceEpoch(p.readAt! * 1000);
    final was = switch (p.look) { 'ok' => '，當時正常', 'warn' => '，當時要注意', 'bad' => '，當時有問題', _ => '' };
    before = at.isAfter(DateTime.now()) ? '之前讀過' : '上次讀取 ${hhmm(at)}$was';
  }
  // 「讀取於」 only for a fresh read; an older one is 「上次讀取」 (review r3 F-m6)
  final meta = when != null
      ? withTail('${n.fresh ? '讀取於' : '上次讀取'} ${hhmm(when)}') : (before != null ? withTail(before) : tail);
  final why = n.shownWhy;
  if (why != null) {
    return switch (why) {
      Why.bluetoothOff => (Look.bad, '藍牙沒有打開', meta),
      Why.noPermission => (Look.bad, 'app 還沒有藍牙權限', meta),
      Why.keys => (Look.bad, '手機的金鑰現在不能用', meta),
      Why.identity => (Look.bad, '身分和這支手機記錄的不同', meta),
      Why.refused => (Look.warn, '這台節點不接受這支手機的登入', meta),
      Why.notFound => (Look.warn, '手機連不到這台節點', meta),
    };
  }
  final v = n.view;
  if (n.fresh && v != null) {
    if (n.notInNetwork) return (Look.warn, '還沒加入隊伍網路', meta);
    final look = switch (n.state.view) { 'green' => Look.ok, 'yellow' => Look.warn, 'red' => Look.bad, _ => Look.unk };
    return (look, v.sentence, meta);
  }
  if (n.state.kind == Kind.read && when != null) return (Look.unk, '上次讀取 ${hhmm(when)}${wasTail(n)}', tail);
  if (n.state.responded) return (Look.unk, '有回應，還沒拿到狀態', meta);
  if (n.state.last == Concl.notYet && !firstRounds) return (Look.unk, '附近有還沒認出來的裝置，還在找', meta);
  if (before != null && !firstRounds) return (Look.unk, before, tail);
  return (Look.busy, '正在找節點…', meta);
}

/// The next step for each reason a node is not read (node page; PR 2 review A-M3): an identity mismatch is a
/// security warning, never "it will retry".
String whyNext(Why w) => switch (w) {
      Why.notFound => '節點可能沒開機、還在開機，或離手機太遠。app 會持續自動重試，連上後這裡會自己更新。',
      Why.identity => '這台的身分證明和手機記錄的不同：可能是被重燒過，也可能是別的裝置冒充。不要在它上面做任何設定，請找維修人員確認。',
      Why.refused => '這台節點不接受這支手機的登入（可能已被重設或交給別人）。請找維修人員。',
      // #329 PR 7 T6: the node page shows the button these two name, right below
      Why.bluetoothOff => '請按下面的「開啟藍牙設定」打開手機的藍牙。打開後 app 會自動重新讀取。',
      Why.noPermission => '請按下面的「允許藍牙權限」。',
      Why.keys => '這支手機的金鑰現在不能用。請重新開啟 app；一直如此請找維修人員。',
    };

/// What an older read of [n] said (a read of this run that is no longer fresh): one of the four tails, '' for any other.
String wasTail(NodeInfo n) {
  if (n.state.kind != Kind.read) return '';
  return n.notInNetwork
      ? '，當時還沒加入隊伍網路' // the same words as the fresh row, not 「有問題」 (review r2 D-m6)
      : switch (n.state.view) { 'green' => '，當時正常', 'yellow' => '，當時要注意', 'red' => '，當時有問題', _ => '' };
}

/// A node's last read for the status area: this run's (`readWall`, with [wasTail]) or, without one, an earlier run's
/// (UiState `prev`, with its own kind's tail; §4.6); `prev` = from an earlier run (only those can be 「之前讀過」).
(DateTime, String, bool)? _lastRead(NodeInfo n) {
  final w = n.readWall;
  if (w != null) return (w, wasTail(n), false);
  final p = n.prev;
  if (p == null || p.readAt == null) return null;
  final was = switch (p.look) { 'ok' => '，當時正常', 'warn' => '，當時要注意', 'bad' => '，當時有問題', _ => '' };
  return (DateTime.fromMillisecondsSinceEpoch(p.readAt! * 1000), was, true);
}

/// #329 PR 6 D9: the status area's time. A row about one node ([about]): fresh -> 「讀取於 HH:MM:SS」, older ->
/// 「上次讀取 HH:MM」 + what it said then (the four tails; none for an identity mismatch or a refused login: that row is
/// not about what the node said). Any other row: the newest fresh read -> 「讀取於」, none fresh -> the newest read ->
/// 「上次讀取 HH:MM」 (no tail: it is not about one node). An earlier run's time after [now] -> 「之前讀過」 (as the node
/// row, home_logic.dart nodeRowWords; plan §11: only for those). Never read -> null (nothing shown).
String? heroTime(List<NodeInfo> ns, {String? about, required DateTime now}) {
  String older((DateTime, String, bool) l, {required bool tail}) =>
      l.$3 && l.$1.isAfter(now) ? '之前讀過' : '上次讀取 ${hhmm(l.$1)}${tail ? l.$2 : ''}';
  if (about != null) {
    final n = ns.where((x) => x.id == about).firstOrNull;
    if (n == null) return null;
    final w = n.readWall;
    if (n.fresh && w != null) return '讀取於 ${hhmmss(w)}';
    final l = _lastRead(n);
    if (l == null) return null;
    return older(l, tail: n.shownWhy != Why.identity && n.shownWhy != Why.refused);
  }
  DateTime? f;
  for (final n in ns) {
    final w = n.readWall;
    if (n.fresh && w != null && (f == null || w.isAfter(f))) f = w;
  }
  if (f != null) return '讀取於 ${hhmmss(f)}';
  (DateTime, String, bool)? o;
  for (final n in ns) {
    final l = _lastRead(n);
    if (l != null && (o == null || l.$1.isAfter(o.$1))) o = l;
  }
  return o == null ? null : older(o, tail: false);
}
