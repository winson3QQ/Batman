// #329 PR 5 plan v16 R14 (§2.9): how a send of the new secrets reads on screen. Every result of sendNewKey and of
// NetRun's send after a join is shown only through this widget: Rust's own sentence, a neutral look unless it is one
// of the two success sentences, and the fixed rule text of the leader or the member.
import 'package:flutter/material.dart';

import '../say.dart' show screenText;
import '../src/flows/rekey_send.dart';
import 'theme.dart';
import 'widgets.dart';

/// R14: the leader's rule (8.4, 更多, the hint card).
const kRekeyDoneRule = '每台都要看到「已是新密碼」或「已換成新密碼」才算換好。沒看到的，再按一次「送出」確認。看到「正在套用」或'
    '「還有沒完成的變更」時，等幾分鐘再按；超過 10 分鐘仍如此，重新開機一次。沒看到這兩句、或讀不到的節點，被移除的人仍可能連得上。';

/// R14: the member's rule. A member's phone cannot know whether its bundle is the newest (T-M1): no tick, ever.
const kMemberRekeyRule = '這只代表節點換成了這支手機有的版本。請把上面的版本號唸給隊長聽，和他手機上的「目前是第 N 版」比對；'
    '不一樣的話，請他重新產生你的更新包。';

/// R14 + the member's two checks (Z-M1): the version line is always there; the 「換好了」 line only on current.
class RekeyResult extends StatelessWidget {
  const RekeyResult({super.key, required this.end, required this.line, required this.member, this.version});
  final RekeyEnd end;
  final String line;
  final bool member;

  /// the member's mnet version (R19), null = not read
  final int? version;

  @override
  Widget build(BuildContext context) {
    final t = BatTheme.of(context);
    final note = TextStyle(fontSize: Fs.note, height: 1.55, color: t.sub);
    final ok = end == RekeyEnd.current;
    final tick = ok && !member; // T-M1: never on the member side
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        if (tick) Icon(Icons.check_circle_outline, key: const Key('rekey-tick'), color: Look.ok.ink(t)),
        if (tick) const SizedBox(width: 8),
        Expanded(child: Text(screenText(line), key: const Key('rekey-line'), style: TextStyle(fontSize: Fs.body, height: 1.6, color: t.ink))),
      ]),
      if (end == RekeyEnd.applying) Text('狀態頁就是那台的節點頁', style: note),
      if (member) ...[
        Text(version == null ? '這支手機的版本讀不到' : '這支手機是第 $version 版', key: const Key('rekey-version'), style: note),
        Text(ok ? '這台節點已換成這支手機的版本' : '這台還沒換好，先不要跟隊長說換好了', key: const Key('rekey-node'), style: note),
        Text(kMemberRekeyRule, style: note),
      ] else
        Text(kRekeyDoneRule, style: note),
    ]);
  }
}
