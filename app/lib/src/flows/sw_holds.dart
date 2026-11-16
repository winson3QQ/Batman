// #329 PR 4 §2.8: the software updates left half-way, one per node, in memory (as the old console's `_swHold` field,
// nodes.dart:1630-1640): the update page puts one here and takes it back; 「從這支手機移除這台節點」 drops it. The home
// page's todo 「軟體更新還沒做完」 reads it (design §4.8: prepared, not applied). Gone when the app ends (as today).
import 'package:flutter/foundation.dart';

import '../../swupdate.dart' show SwHold;
import '../rust/api/swupdate.dart' show SwButton, SwKind;
import 'owner_console.dart' show SwLink;

class SwHolds extends ChangeNotifier {
  final _m = <String, (SwLink, SwHold)>{};

  /// The update of [id] left half-way, else a new one from [make] (a done one is not taken up again).
  (SwLink, SwHold) take(String id, (SwLink, SwHold) Function() make) {
    final h = _m[id];
    if (h != null && h.$2.last?.kind != SwKind.done) return h;
    final n = _m[id] = make();
    notifyListeners();
    return n;
  }

  (SwLink, SwHold)? of(String id) => _m[id];

  void drop(String id) {
    if (_m.remove(id) != null) notifyListeners();
  }

  /// The page changed an update's last action (SwHold.last is the page's field: it does not notify by itself).
  void touched() => notifyListeners();

  /// design §4.8 「已準備、還沒套用」: the last action offers 套用 (Rust's state, not the picked files: review A m7).
  bool unfinished(String id) {
    final b = _m[id]?.$2.last?.buttons ?? const <SwButton>[];
    return b.contains(SwButton.apply) || b.contains(SwButton.applyAnyway);
  }

  List<String> get unfinishedIds => [for (final id in _m.keys) if (unfinished(id)) id];

  /// The ones still on this phone (code review A m9 / B m9: the old console's removal does not drop a hold; the home
  /// page's count and its banners use the same list).
  List<String> unfinishedOf(bool Function(String id) known) => [for (final id in unfinishedIds) if (known(id)) id];
}
