// #329 design §5.8 / §12 PR 2: settings and about; the older console, the old claim page and the BLE test page
// move into 開發者選項 (devTrust builds only), each under a raw lease.
import 'package:flutter/material.dart';

import '../claim.dart';
import '../nodes.dart';
import '../scan.dart';
import '../src/nodelink/app_link.dart';
import 'home_page.dart' show openUnderLease;
import 'theme.dart';
import 'widgets.dart';

class SettingsPage extends StatelessWidget {
  const SettingsPage({super.key, required this.app, required this.devTrust});
  final AppLink app;
  final bool devTrust;

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

class AboutPage extends StatelessWidget {
  const AboutPage({super.key});

  @override
  Widget build(BuildContext context) {
    final t = BatTheme.of(context);
    return BatPage(title: Btn.about, body: [
      Center(
        child: Semantics(
            label: '台灣曙豐防災自訓團臂章', child: Image.asset('assets/brand/badge.webp', width: 120, fit: BoxFit.contain)),
      ),
      Center(
          child: Text('Batman 節點管理',
              style: TextStyle(fontSize: Fs.hero, fontWeight: FontWeight.w700, color: t.ink))),
      Text('這個 app 管理你的 Batman 節點：新增節點、建立或加入隊伍網路、設定手機 Wi-Fi，並隨時看節點的狀態。',
          style: TextStyle(fontSize: Fs.body, height: 1.65, color: t.ink)),
      Text('對別人說是哪一台節點時，請報後四碼。', style: TextStyle(fontSize: Fs.note, height: 1.55, color: t.sub)),
    ]);
  }
}
