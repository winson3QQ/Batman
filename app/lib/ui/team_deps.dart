// #329 PR 5 plan v16: the app's parts for the team pages — OfflineOp (R10), its platform, sendNewKey (R17), and the
// small readers every team page uses. Tests build their own fakes of the same shapes.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../src/flows/offline_op.dart';
import '../src/flows/rekey_send.dart';
import '../src/nodelink/app_link.dart';
import '../src/nodelink/lease.dart';
import 'net_pages.dart' show askYesNo;
import '../src/flows/op_session.dart' show OpDeps;
import 'settings_pages.dart' show opDeps;

const _platform = MethodChannel('dev.batman/platform');

/// R10: OfflineOp's app parts.
OfflineDeps offlineDeps(AppLink a) => OfflineDeps(
  acquire: (name) => a.link.acquire(name, LeaseKind.session),
  busyName: () => a.reg.current?.name,
  writer: a.writer,
  after: a.link.after,
  log: (l) => debugPrint('BMAPP $l'),
);

/// R10: the keys and the record store for offline work (the same calls ConsolePlatform makes, plus ecdh).
OfflinePlatform offlinePlatform(AppLink a) => OfflinePlatform(
  seal: a.console.seal,
  signAdmin: a.console.signAdmin,
  ecdh: (peer) async => (await _platform.invokeMethod<Uint8List>('ecdh', {'peer': peer}))!,
  readRecord: a.console.readRecord,
  keyError: (e) => keyErrorToRadio(e, a.link),
);

/// R17: sendNewKey's app parts; the leader's confirmation is the old one (nodes.dart:1568-1572).
SendDeps sendDeps(BuildContext context, AppLink a) => SendDeps(
  op: opDeps(a),
  readRecord: (rel) async {
    final (g, p) = await a.console.readRecord(rel);
    return (g, p as Object?);
  },
  confirm: () async {
    if (!context.mounted) return null;
    return askYesNo(context, '把新密碼送給這台節點？', '包都交給隊員了嗎？你的節點一換，就和還沒換的人斷線，之後很難再把包傳出去。', '送出', '取消');
  },
);

/// The ECDH result as the page's own copy (the platform's buffer may be read-only: the old _ownCopy, R10).
Uint8List ownCopy(Uint8List b) => Uint8List.fromList(b);

/// Zeroes [z] in place (R10: in the work's `finally`).
void zero(Uint8List? z) => z?.fillRange(0, z.length, 0);

/// Everything the team pages (team_pages / remove_pages / join_pages) read or call besides Rust's pure functions, in
/// one place so widget tests can hand the whole set over with [teamDepsOverride].
class TeamDeps {
  const TeamDeps({
    required this.offline,
    required this.platform,
    required this.op,
    required this.publicKeys,
    required this.nodeIds,
    required this.send,
  });
  final OfflineDeps offline;
  final OfflinePlatform platform;
  final OpDeps op;
  final Future<Map<String, Uint8List>> Function() publicKeys;

  /// the node records on this phone
  final Future<List<String>> Function() nodeIds;
  final SendDeps Function(BuildContext context) send;

  Future<(BigInt, Uint8List?)> readRecord(String rel) => platform.readRecord(rel);

  factory TeamDeps.real(AppLink a) => TeamDeps(
    offline: offlineDeps(a),
    platform: offlinePlatform(a),
    op: opDeps(a),
    publicKeys: a.console.publicKeys,
    nodeIds: a.nets.src.nodeIds,
    send: (c) => sendDeps(c, a),
  );
}

@visibleForTesting
TeamDeps Function(AppLink a)? teamDepsOverride;

TeamDeps teamDeps(AppLink a) => teamDepsOverride?.call(a) ?? TeamDeps.real(a);
