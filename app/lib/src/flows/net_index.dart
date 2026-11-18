// #329 PR 3 §2.6 (design §4.3.8): the phone's network records, summarised once per change for the screens — which
// kinds the phone holds (home row 6 and 3.5 / 3.6), the openable net records with their name, applied flag and members
// (4.1's forms, the pending screens), and the 「節點加入網路沒有做完」 todos. Held by AppLink, computed after the
// startup check and after every lease release (never inside an acquire's wait), never while a lease is held by a
// screen that needs one record: that screen reads its record itself (§2.6). NodeLink never touches it (D4).
//
// Listing follows Rust's list_kind (owner.rs:41-47): names starting with '.' are skipped; a missing folder is empty;
// any other listing error is 「列不出來」 (listFailed), never 「沒有」. A record that does not open is skipped with one
// log line naming only the first 8 characters of its id (the old console skips it too, nodes.dart:600-605).
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show ChangeNotifier, visibleForTesting;

import '../../member_ui.dart' show forgettable;
import '../../ui/home_logic.dart' show NetRecords;
import '../nodelink/lease.dart';
import '../rust/api/member.dart' show MnetView;
import '../rust/api/owner.dart' show NetView, MemberView;

/// One openable net record.
class NetEntry {
  const NetEntry(this.id, this.view);
  final String id;
  final NetView view;
  String get rel => 'net/$id';
  bool get applied => view.applied;
}

/// #329 PR 5 §2.11: a member's team network as listed: its name and its entry node's last four (no version: R19
/// reads the record itself). [opens] false: the record did not open (Y-m4); the name and last four are then empty.
class MnetEntry {
  const MnetEntry(this.id, {this.name = '', this.entryLast4 = '', this.opens = true});
  final String id, name;

  /// '' = no own-node entry left (a new invite is needed, V-m5)
  final String entryLast4;
  final bool opens;
  String get rel => 'mnet/$id';
}

/// 「節點加入網路沒有做完」: a joining member (not the pending creator) that is one of this phone's nodes.
class JoinTodo {
  const JoinTodo(this.net, this.member);
  final NetEntry net;
  final MemberView member;
  String get deviceId => member.deviceId;
}

class NetSnapshot {
  const NetSnapshot({
    this.computing = false,
    this.listFailed = false,
    this.netFiles = 0,
    this.nets = const [],
    this.anyMnet = false,
    this.anyMpend = false,
    this.todos = const [],
    this.mnetIds = const [],
    this.mpendIds = const [],
    this.mnets = const [],
  });

  /// Nothing computed yet, or a newer computation running: the screens use the neutral 「加入網路」 (PR 2 D-m9).
  final bool computing;

  /// A folder could not be listed: 「讀不到手機裡的網路紀錄」, never 「沒有」.
  final bool listFailed;

  /// net/ files listed (pending ones and ones that do not open included): home row 6's 「有 net」.
  final int netFiles;

  /// The net records that opened.
  final List<NetEntry> nets;
  final bool anyMnet, anyMpend;
  final List<JoinTodo> todos;

  /// #329 PR 5 §2.11: the mnet / mpend files listed (ids only; nothing opened for these). anyMnet / anyMpend stay as
  /// they were (home row 6 reads them).
  final List<String> mnetIds, mpendIds;

  /// #329 PR 5 §2.11: every mnet listed, opened or not.
  final List<MnetEntry> mnets;

  /// Home row 6 / 3.5 / 3.6 (PR 2 joinChoice, unchanged): any net file wins over mnet over mpend.
  NetRecords get records => computing || listFailed
      ? NetRecords.unknown
      : netFiles > 0
          ? NetRecords.net
          : anyMnet
              ? NetRecords.mnet
              : anyMpend
                  ? NetRecords.mpend
                  : NetRecords.none;

  /// 「已建立的 net」 (plan §2.4 用詞): an applied net record that opens.
  bool get anyApplied => nets.any((n) => n.applied);

  /// net files exist but none opens (join2 T8: the record key may be lost).
  bool get noneOpens => netFiles > 0 && nets.isEmpty;
}

/// What NetIndex reads (injected so it is testable without the bridge or Kotlin).
class NetSource {
  const NetSource({required this.list, required this.open, required this.summary, required this.nodeIds, this.mnetSummary});

  /// The names in a records folder ('net', 'mnet', 'mpend'), list_kind's rules (see [listKind]).
  final Future<List<String>> Function(String kind) list;

  /// A net record's plain bytes (store + Keystore); throws or null when it does not open.
  final Future<Uint8List?> Function(String rel) open;
  final NetView Function(Uint8List plain) summary;

  /// This phone's node ids (node/ records).
  final Future<List<String>> Function() nodeIds;

  /// #329 PR 5 §2.11: an mnet record's summary (null: mnets are listed as ids only).
  final MnetView Function(Uint8List plain)? mnetSummary;
}

/// list_kind's rules on a real folder: '.' names skipped, a missing folder is empty, any other error thrown.
Future<List<String>> listKind(String records, String kind) async {
  try {
    final names = await Directory('$records/$kind')
        .list()
        .where((e) => e is File)
        .map((e) => e.uri.pathSegments.last)
        .where((n) => n.isNotEmpty && !n.startsWith('.'))
        .toList();
    return names..sort();
  } on PathNotFoundException {
    return const [];
  }
}

class NetIndex extends ChangeNotifier implements LeaseListener {
  NetIndex(this.src, {this.log});
  final NetSource src;
  final void Function(String line)? log;

  NetSnapshot _now = const NetSnapshot(computing: true);
  NetSnapshot get now => _now;

  /// #329 PR 6 §14: a computation has finished at least once (a later one keeps the last snapshot while it runs).
  /// Before that nothing is known about any network (cold start).
  bool get ready => _ready;
  bool _ready = false;

  @visibleForTesting
  void setForTest(NetSnapshot s) {
    _gen++;
    _now = s;
    _ready = true;
    notifyListeners();
  }
  int _gen = 0;

  /// Computes again; only the newest computation is kept. Notifies when it starts and when it ends.
  Future<void> recompute() async {
    final gen = ++_gen;
    if (!_now.computing) {
      _now = NetSnapshot(
          computing: true,
          listFailed: _now.listFailed,
          netFiles: _now.netFiles,
          nets: _now.nets,
          anyMnet: _now.anyMnet,
          anyMpend: _now.anyMpend,
          todos: _now.todos,
          mnetIds: _now.mnetIds,
          mpendIds: _now.mpendIds,
          mnets: _now.mnets);
      notifyListeners();
    }
    final s = await compute();
    if (gen != _gen) return; // a newer one runs
    _now = s;
    _ready = true;
    notifyListeners();
  }

  /// One computation, not kept (a screen holding a lease reads the records itself with it, §2.8).
  Future<NetSnapshot> compute() async {
    final List<String> netIds, mnets, mpends;
    try {
      netIds = await src.list('net');
      mnets = await src.list('mnet');
      mpends = await src.list('mpend');
    } catch (e) {
      log?.call('NetIndex: records not listed (${e.runtimeType})');
      return const NetSnapshot(listFailed: true);
    }
    final nets = <NetEntry>[];
    for (final id in netIds) {
      try {
        final p = await src.open('net/$id');
        if (p == null) throw StateError('none');
        nets.add(NetEntry(id, src.summary(p)));
      } catch (e) {
        log?.call('NetIndex: net ${id.length > 8 ? id.substring(0, 8) : id}… does not open (${e.runtimeType})');
      }
    }
    final mnetEntries = <MnetEntry>[];
    final ms = src.mnetSummary;
    if (ms != null) {
      for (final id in mnets) {
        try {
          final p = await src.open('mnet/$id');
          if (p == null) throw StateError('none');
          final v = ms(p); // the plain bytes go no further (§2.11)
          mnetEntries.add(MnetEntry(id, name: v.netName, entryLast4: v.entryState.isEmpty ? '' : v.deviceLast4));
        } catch (e) {
          mnetEntries.add(MnetEntry(id, opens: false));
          log?.call('NetIndex: mnet ${id.length > 8 ? id.substring(0, 8) : id}… does not open (${e.runtimeType})');
        }
      }
    }
    var todos = <JoinTodo>[];
    try {
      final mine = (await src.nodeIds()).toSet();
      todos = [
        for (final n in nets)
          for (final m in n.view.members)
            if (forgettable(joining: m.joining, approved: m.approved, creator: m.creator) &&
                m.deviceId.isNotEmpty &&
                mine.contains(m.deviceId))
              JoinTodo(n, m)
      ];
    } catch (e) {
      log?.call('NetIndex: node records not listed (${e.runtimeType})');
    }
    return NetSnapshot(
        netFiles: netIds.length,
        nets: nets,
        anyMnet: mnets.isNotEmpty,
        anyMpend: mpends.isNotEmpty,
        todos: todos,
        mnetIds: mnets,
        mpendIds: mpends,
        mnets: mnetEntries);
  }

  // §2.6: after every lease release (a flow may have written a record). Not in the same call: a release often comes
  // from a page's dispose, while the widget tree is locked, and a listener may set its state on the first notice.
  @override
  void released(Lease l, {required bool revoked}) => scheduleMicrotask(() => unawaited(recompute()));

  @override
  void revoked(Token t) {}
}
