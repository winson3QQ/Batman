// #329 PR 6 D6 (design §5.8 10.5, every build): 診斷 — the app version, the flavor, the key abilities of the startup
// check (with the software-only warning, T-H4), and each node's technical list from this run's read. Read only, no
// lease. 「複製」 copies a whitelist of fields only (version, flavor, key ability names, each node's last four and its
// technical list) — never a full device id or another record's contents. No export (T11: diag/bundle is unsupported).
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../key_abilities.dart';
import '../say.dart' show logText;
import '../src/nodelink/app_link.dart';
import '../src/nodelink/node_link.dart' show NodeLink;
import '../src/rust/api/owner.dart' show StatusView;
import 'home_logic.dart' show last4;
import 'theme.dart';
import 'widgets.dart';

const _platform = MethodChannel('dev.batman/platform');

/// The startup check's software-only line (main.dart), shown again here.
const softKeyWarning = '注意：這支手機的復原／隊員金鑰只有軟體保護，只適合開發使用';
const notReadYet = '這次還沒讀到';

/// The key abilities as names (yes / no each), in a fixed order.
List<String> keyLines(KeyAbilities? k) {
  if (k == null) return const ['金鑰：沒有啟動時的檢查結果'];
  String yn(bool b) => b ? '可以' : '不可以';
  return [
    '認領節點：${yn(k.claim)}',
    '登入節點：${yn(k.login)}',
    '接續認領：${yn(k.recover)}',
    '建立網路：${yn(k.makeNetwork)}',
    if (k.softOwnerEnc) softKeyWarning,
  ];
}

/// Each node's technical list (`StatusView.tech`) of this run's read, by its full id (review pr6 A-8 / B-3: two nodes
/// may share a last four; the page and the copy show the last four only); none -> [notReadYet].
Map<String, List<String>> nodeTech(AppLink a) {
  final ids = a.link.core.states.keys.toList()..sort();
  return {
    for (final id in ids)
      id: switch (a.link.core.states[id]!.extra) {
        final StatusView v when v.tech.isNotEmpty => v.tech,
        _ => const [notReadYet],
      }
  };
}

/// The copy: whitelisted fields only, every value through [NodeLink.mask] (no long hex run, no address); a technical
/// list's markers U+001E / U+001F as 〔 〕 (plan D7: no invisible character in copied text).
String diagCopy({required String version, required String flavor, required KeyAbilities? keys, required Map<String, List<String>> tech}) => [
      'app 版本：${NodeLink.mask(version)}',
      'flavor：${NodeLink.mask(flavor)}',
      '金鑰（啟動時的檢查結果）：',
      for (final l in keyLines(keys)) '  $l',
      for (final e in tech.entries) ...[
        '節點 …${last4(e.key)}：',
        for (final l in e.value) '  ${logText(NodeLink.mask(l))}',
      ],
    ].join('\n');

class DiagPage extends StatefulWidget {
  const DiagPage({super.key, required this.app, required this.keys});
  final AppLink app;

  /// HomePage's: the startup check's answer (it is not read again here)
  final KeyAbilities? keys;

  @override
  State<DiagPage> createState() => _DiagPageState();
}

class _DiagPageState extends State<DiagPage> {
  String _version = '', _flavor = '';

  @override
  void initState() {
    super.initState();
    _platform.invokeMethod<String>('appVersion').then((v) {
      if (mounted) setState(() => _version = v ?? '');
    }).catchError((Object _) {});
    _platform.invokeMethod<String>('flavor').then((v) {
      if (mounted) setState(() => _flavor = v ?? '');
    }).catchError((Object _) {
      // an older Kotlin side without the method: the build's trust is still known
      if (mounted) setState(() => _flavor = widget.app.devTrust ? '開發版' : '正式版');
    });
  }

  @override
  Widget build(BuildContext context) {
    final t = BatTheme.of(context);
    final tech = nodeTech(widget.app);
    final mono = TextStyle(fontFamily: 'monospace', fontSize: Fs.meta, height: 1.5, color: t.ink);
    return BatPage(title: '診斷', body: [
      BatCard(children: [
        BatRow(icon: Icons.info_outline, title: 'app 版本', right: _version),
        BatRow(icon: Icons.build_outlined, title: '安裝版類型', right: _flavor), // #329 PR 7 (p1p2-check 10.5): a Chinese label; the value (dev / field) as is
      ]),
      const BatLabel('金鑰（啟動時的檢查結果）'),
      BatCard(children: [
        for (final l in keyLines(widget.keys))
          BatRow(
              key: l == softKeyWarning ? const Key('diag-soft') : null,
              icon: l == softKeyWarning ? Icons.warning_amber_outlined : Icons.key_outlined,
              title: l),
      ]),
      const BatLabel('每台節點的技術資訊（這次讀到的）'),
      if (tech.isEmpty)
        Text('這支手機還沒有節點。', style: TextStyle(fontSize: Fs.body, color: t.sub))
      else
        BatCard(children: [
          for (final n in tech.entries)
            Padding(
              padding: const EdgeInsets.all(12),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('節點 …${last4(n.key)}', style: TextStyle(fontSize: Fs.body, fontWeight: FontWeight.w600, color: t.ink)),
                for (final l in n.value) Text(logText(l), style: mono),
              ]),
            ),
        ]),
    ], foot: [
      BatButton('複製',
          key: const Key('diag-copy'),
          kind: BtnKind.secondary,
          onPressed: () => Clipboard.setData(
              ClipboardData(text: diagCopy(version: _version, flavor: _flavor, keys: widget.keys, tech: tech)))),
    ]);
  }
}
