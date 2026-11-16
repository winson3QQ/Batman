// #329 PR 5 plan v16 §2.9: sending the new secrets to a node.
// R17 sendNewKey is the only way the new pages send them (8.4, 8.5, the node page's 更多, the hint card); NetRun's
// send after a join is the one other caller of sendUpdateFor (it already holds the session). R14 rekeyEnd sorts
// Rust's answer, so that only the two success sentences count as 「換好了」. The old console (nodes.dart) is the
// stated exception until PR 6 removes it.
import '../rust/api/rekey.dart' show infoNetId;
import 'op_session.dart';
import 'owner_console.dart';

/// R14: what an answer to sending the new secrets means.
enum RekeyEnd { current, applying, unfinished, unclear, failed }

/// The four last characters of a device id as Rust prints them in update_text (owner.rs:717: the id's own case).
/// Dart's [last4] upper-cases for display only and is never used to compare (R18).
String rustLast4(String deviceId) => deviceId.length > 4 ? deviceId.substring(deviceId.length - 4) : deviceId;

/// R18: two last-four values are the same node's whatever their case.
bool sameLast4(String a, String b) => a.toLowerCase() == b.toLowerCase();

/// R14: in this order, the first that matches; anything else is [RekeyEnd.failed] (fail-closed). The sentences are
/// pinned by the Rust test rekey_texts_are_pinned and the Dart rekey_send_test, so a change on either side fails.
RekeyEnd rekeyEnd(String line, ReplyKind kind, String deviceId) {
  if (kind == ReplyKind.unclear || line == sendUnclearLine) return RekeyEnd.unclear;
  // Rust: the id's last four, or the whole id when it is shorter (owner.rs:717)
  final m = RegExp(r'^\[UPDATED\] 節點 …(.{1,4}) (已是新密碼|已換成新密碼|正在套用新密碼，稍後再看狀態頁)$').firstMatch(line);
  if (m != null && sameLast4(m[1]!, rustLast4(deviceId))) {
    return m[2] == '正在套用新密碼，稍後再看狀態頁' ? RekeyEnd.applying : RekeyEnd.current;
  }
  if (line == unfinishedLine) return RekeyEnd.unfinished;
  return RekeyEnd.failed;
}

/// Rust's Unfinished sentence (bridge rekey.rs:445).
const unfinishedLine = '[REQ_FAIL] 沒有送出：節點還有沒完成的變更，等一下再按；超過 10 分鐘仍如此，重新開機一次';

/// R17's result: [line] is what the page shows (Rust's text, or the old console's sentence); [member] is null when it
/// never got as far as knowing the network.
class RekeySent {
  const RekeySent(this.end, this.line, {this.member, this.netId = '', this.notReached});
  final RekeyEnd end;
  final String line;
  final bool? member;
  final String netId;

  /// a session that never reached its requests (busy, login, gone, lease lost): the page shows opLine of it
  final OpReply? notReached;
}

/// The old console's sentences when there is nothing to send (nodes.dart:1551-1562).
const noNetLine = '[REQ_FAIL] 讀不到這台節點在哪個隊伍網路（不在網路裡，或稍後再試）';
const noRecordLine = '[REQ_FAIL] 這台節點所在的隊伍網路不在這支手機的紀錄裡';
const notThisNetLine = '[REQ_FAIL] 沒有送出：這台不在這個網路';
const notThisNodeLine = '[REQ_FAIL] 沒有送出：這台的身分和網路紀錄不符';
const cancelledLine = '沒有送出';

/// What sendNewKey needs besides the session: reading a record, and the leader's confirmation (outside the lease).
class SendDeps {
  const SendDeps({required this.op, required this.readRecord, required this.confirm});
  final OpDeps op;
  final Future<(BigInt, Object?)> Function(String rel) readRecord;

  /// nodes.dart:1568-1572: 「把新密碼送給這台節點？」 for the leader; null = the page is gone (= no)
  final Future<bool?> Function() confirm;
}

/// R17: the only flow that sends the new secrets from a page.
/// 1. one session: info -> its network -> which record (net = leader, mnet = member); [expectDac] / [expectNet]
///    checked; then the lease goes.
/// 2. the leader, when [confirm]: the old confirmation, outside the lease.
/// 3. a second session: info again (the same network), then sendUpdateFor.
/// 4. the answer, sorted by rekeyEnd.
Future<RekeySent> sendNewKey(SendDeps d, String deviceId,
    {bool confirm = true, String? expectDac, String? expectNet, required bool Function() gone}) async {
  const name = '把新密碼送給節點';
  String? failLine;
  String netId = '';
  String? rel;
  bool? member;

  Future<String?> check(OwnerConsole c) async {
    if (expectDac != null && c.nodeDacHash() != expectDac) return notThisNodeLine;
    final r = await c.info();
    final info = r.value;
    if (info is! List<int>) return r.text.startsWith('[REQ_FAIL]') ? r.text : noNetLine;
    final id = infoNetId(info: info);
    if (id.isEmpty) return noNetLine;
    if (expectNet != null && id != expectNet) return notThisNetLine;
    if (netId.isNotEmpty && id != netId) return notThisNetLine; // step 3: still the same network (U-m)
    netId = id;
    return null;
  }

  // step 1
  final first = await OpSession.once(d.op, deviceId, name, (c, g) async {
    failLine = await check(c);
    if (failLine == null) {
      for (final (r, m) in [('net/$netId', false), ('mnet/$netId', true)]) {
        final (_, p) = await d.readRecord(r);
        if (p != null) {
          rel = r;
          member = m;
          break;
        }
      }
      if (rel == null) failLine = noRecordLine;
    }
    return ConsoleReply(ReplyKind.answer, failLine ?? '');
  }, gone: gone);
  if (first.end != OpEnd.done) return RekeySent(RekeyEnd.failed, '', notReached: first);
  if (failLine != null) return RekeySent(RekeyEnd.failed, failLine!, member: member, netId: netId);

  // step 2: the leader is reminded of the order (hand out every bundle first, remove-member §3.1)
  if (confirm && member == false) {
    final yes = await d.confirm();
    if (yes != true) return RekeySent(RekeyEnd.failed, cancelledLine, member: member, netId: netId);
  }

  // step 3
  ConsoleReply? sent;
  final second = await OpSession.once(d.op, deviceId, name, (c, g) async {
    failLine = await check(c);
    if (failLine != null) return ConsoleReply(ReplyKind.answer, failLine!);
    return sent = await c.sendUpdateFor(rel!, member: member!);
  }, gone: gone);
  if (second.end != OpEnd.done) return RekeySent(RekeyEnd.failed, '', member: member, netId: netId, notReached: second);
  if (failLine != null) return RekeySent(RekeyEnd.failed, failLine!, member: member, netId: netId);
  final s = sent!;
  // step 4
  return RekeySent(rekeyEnd(s.text, s.kind, deviceId), s.text, member: member, netId: netId);
}

