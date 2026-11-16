// #329 design §5.8 / §12 PR 2: settings and about; the older console, the old claim page and the BLE test page
// move into 開發者選項 (devTrust builds only), each under a raw lease.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../claim.dart';
import '../nodes.dart';
import '../scan.dart';
import '../src/nodelink/app_link.dart';
import 'home_page.dart' show openUnderLease;
import 'theme.dart';
import 'widgets.dart';

const _platform = MethodChannel('dev.batman/platform');

class SettingsPage extends StatelessWidget {
  const SettingsPage({super.key, required this.app, required this.devTrust, this.notes = const []});
  final AppLink app;
  final bool devTrust;
  final List<String> notes;

  @override
  Widget build(BuildContext context) {
    final t = BatTheme.of(context);
    return BatPage(title: '設定', body: [
      BatCard(children: [
        BatRow(
          icon: Icons.info_outline,
          title: Btn.about,
          onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const AboutPage())),
        ),
      ]),
      if (notes.isNotEmpty) ...[
        const BatLabel('啟動時的提醒'),
        BatCard(children: [for (final n in notes) BatRow(icon: Icons.warning_amber_outlined, title: n)]),
      ],
      if (devTrust) ...[
        const BatLabel(Btn.devOptions),
        BatCard(children: [
          BatRow(
              icon: Icons.terminal,
              title: '舊版控制台',
              sub: '建網、加入、邀請、更新等（新畫面完成前）',
              onTap: () => openUnderLease(context, app, '舊版控制台', (u) => NodesPage(ble: app.ble, use: u))),
          BatRow(
              icon: Icons.qr_code,
              title: '新增節點（舊版頁面）',
              onTap: () => openUnderLease(context, app, '新增節點', (u) => ClaimPage(ble: app.ble, use: u))),
          BatRow(
              icon: Icons.bluetooth_searching,
              title: '附近的節點（藍牙測試）',
              onTap: () => openUnderLease(context, app, '附近的節點', (u) => ScanPage(ble: app.ble, use: u))),
        ]),
        Text('開發者選項只在開發版出現。', style: TextStyle(fontSize: Fs.meta, color: t.sub)),
      ],
    ]);
  }
}

class AboutPage extends StatefulWidget {
  const AboutPage({super.key});

  @override
  State<AboutPage> createState() => _AboutPageState();
}

class _AboutPageState extends State<AboutPage> {
  String _version = '';

  @override
  void initState() {
    super.initState();
    _platform.invokeMethod<String>('appVersion').then((v) {
      if (mounted) setState(() => _version = v ?? '');
    }).catchError((Object _) {});
  }

  @override
  Widget build(BuildContext context) {
    final t = BatTheme.of(context);
    return BatPage(title: Btn.about, body: [
      Center(
        child: Semantics(
            label: '台灣曙豐防災自訓團臂章', child: Image.asset('assets/brand/badge.webp', width: 132, fit: BoxFit.contain)),
      ),
      Center(child: Text('Batman', style: TextStyle(fontSize: Fs.hero + 2, fontWeight: FontWeight.w700, color: t.ink))),
      Center(child: Text('無線電節點設定與狀態', style: TextStyle(fontSize: Fs.note, color: t.sub))),
      BatCard(children: [
        BatRow(icon: Icons.info_outline, title: 'app 版本', right: _version),
        const BatRow(icon: Icons.android, title: '需要 Android 12 以上'),
      ]),
      BatCard(children: [
        BatRow(
          icon: Icons.description_outlined,
          title: '開放原始碼授權',
          sub: 'app 用到的第三方軟體',
          onTap: () => showLicensePage(context: context, applicationName: 'Batman', applicationVersion: _version),
        ),
      ]),
      Text('Rust 元件與節點軟體的授權見原始碼庫。', style: TextStyle(fontSize: Fs.meta, height: 1.6, color: t.sub)),
      Text('對別人說是哪一台節點時，請報後四碼。', style: TextStyle(fontSize: Fs.note, height: 1.55, color: t.sub)),
      Text('© 2026 台灣曙豐防災自訓團　保留所有權利\n臂章與名稱為台灣曙豐防災自訓團所有，未經同意不得使用。',
          textAlign: TextAlign.center, style: TextStyle(fontSize: Fs.meta, height: 1.7, color: t.sub)),
    ]);
  }
}
