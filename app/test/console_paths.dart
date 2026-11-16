// #329 PR 3 §2.3 (防漂移): the console paths pinned in step 1, as one table. The old console (nodes_update_send_test,
// a page test) and OwnerConsole (flows/owner_console_test) both run every row and must send the same requests in the
// same order and end with the same line; a copy that drifts from the old console fails here.

class ConsolePath {
  const ConsolePath(this.name, {required this.action, this.joinMode = 'plain', this.poll = false, this.answer, required this.sends, required this.ends});
  final String name;

  /// 'join' (加入網路) or 'confirm' (檢查網路).
  final String action;

  /// The fake Rust session's join: plain / country / removed.
  final String joinMode;

  /// The join's answer asks for the link check.
  final bool poll;

  /// The button pressed in the question the node asks (改 / 不要 / 確定，加回); null = no question.
  final String? answer;

  /// FakeRust.sends after the path.
  final List<String> sends;

  /// Text of the line the path ends with (without its log marker).
  final String ends;
}

const consolePaths = [
  ConsolePath('join, no question', action: 'join', sends: ['join removed=false'], ends: 'sent'),
  ConsolePath('ConfirmCountry: 改 -> countryConfirmed(true), the join goes on',
      action: 'join', joinMode: 'country', answer: '改', sends: ['join removed=false', 'country true'], ends: 'sent'),
  ConsolePath('ConfirmCountry: 不要 -> countryConfirmed(false), nothing sent',
      action: 'join', joinMode: 'country', answer: '不要', sends: ['join removed=false', 'country false'], ends: '已取消'),
  ConsolePath('ConfirmRemoved: 確定，加回 -> the join starts again with removedConfirmed',
      action: 'join', joinMode: 'removed', answer: '確定，加回', sends: ['join removed=false', 'join removed=true'], ends: 'sent'),
  ConsolePath('a join that asks for it is followed by the link check until [CONNECTED]',
      action: 'join', poll: true, sends: ['join removed=false', 'link'], ends: '節點已連上隊伍網路'),
  ConsolePath('檢查網路 sends a confirm request for the network', action: 'confirm', sends: ['confirm'], ends: '網路已套用'),
];
