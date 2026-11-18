// (review pr6 A-9) "nodes.dart" / "nodes.dart:<line>" below = the old console, deleted by #329 PR 6: see
// `git show c4905ed:app/lib/nodes.dart` (main before PR 6).
// #329 PR 5 plan v16 §2.6: what the team pages keep in memory (design §4.1 邀請 controller / 移除 controller).
// Nothing here is written to a record or to UiState, and nothing here decides anything (T15, T-R1): an app that is
// killed starts with both empty, which is the design's accepted behaviour.
import 'package:flutter/foundation.dart';

import '../rust/api/member.dart' show InviteView;

/// The invite a member took (7.8; the old console's _inviteHex / _invite, nodes.dart:116-117). At most one. Taking
/// an invite writes no record (F51), so it needs no lease.
class InviteHolds extends ChangeNotifier {
  (String hex, InviteView view)? _held;
  (String hex, InviteView view)? get held => _held;

  /// 7.8: the parsed invite is kept (a newer one replaces it)
  void take(String hex, InviteView view) {
    _held = (hex, view);
    notifyListeners();
  }

  /// the join request was made, or 「不用這份邀請」
  void drop() {
    if (_held == null) return;
    _held = null;
    notifyListeners();
  }
}

/// 8.4's 「已交出」 marks, one set per network, keyed by the whole owner key (never the 8-character fingerprint, which
/// a member can grind: review A-m5 / B-m4). [removedThisRun]: a removal succeeded for that network since the app
/// started (8.1's 「還有 N 位隊員沒交更新包」 shows only then, F-m8). Only these methods change it (I-m9).
class RemoveTicks extends ChangeNotifier {
  final Map<String, ({bool removedThisRun, Set<String> handed})> _of = {};

  bool removedThisRun(String netId) => _of[netId]?.removedThisRun ?? false;
  bool handed(String netId, String owner) => _of[netId]?.handed.contains(owner) ?? false;
  int handedCount(String netId) => _of[netId]?.handed.length ?? 0;

  /// 8.3: a removal on [netId] succeeded -> the marks start empty, the 8.1 line may show
  void removed(String netId) {
    _of[netId] = (removedThisRun: true, handed: <String>{});
    notifyListeners();
  }

  /// 8.4: the leader ticks (or unticks) that [owner]'s bundle was handed over
  void tick(String netId, String owner, bool on) {
    final e = _of[netId] ?? (removedThisRun: false, handed: <String>{});
    final s = {...e.handed};
    if (on ? !s.add(owner) : !s.remove(owner)) return;
    _of[netId] = (removedThisRun: e.removedThisRun, handed: s);
    notifyListeners();
  }
}
