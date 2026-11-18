// #329 design §5.8 / §12 PR 2: settings and about; the old claim page and the BLE test page move into 開發者選項
// (devTrust builds only), each under a raw lease. PR 6: the old console is gone; its last uses are the dev pages
// (dev_pages.dart); 診斷 (10.5) is in every build.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../claim.dart';
import '../key_abilities.dart';
import '../scan.dart';
import '../src/nodelink/app_link.dart';
import 'dev_pages.dart';
import 'diag_page.dart';
import 'home_page.dart' show openUnderLease;
import 'team_hub.dart';
import 'theme.dart';
import 'ui_state.dart';
import 'widgets.dart';

const _platform = MethodChannel('dev.batman/platform');

class SettingsPage extends StatelessWidget {
  const SettingsPage(
      {super.key, required this.app, required this.ui, required this.devTrust, this.notes = const [], this.keys});
  final AppLink app;
  final UiState ui;
  final bool devTrust;
  final List<String> notes;

  /// #329 PR 6 (F11): HomePage's startup key check; null = not known (the owner-key entries are grey then).
  final KeyAbilities? keys;

  /// Why an entry that uses the owner key cannot be used now (null = it can).
  String? get _ownerNo => keys == null ? '沒有啟動時的金鑰檢查結果' : keys!.refusal(KeyUse.login);

  @override
  Widget build(BuildContext context) {
    final t = BatTheme.of(context);
    return BatPage(title: '設定', body: [
      BatCard(children: [
        // #329 PR 4 §2.9 (design §5.8 10.1 / 10.4)
        BatRow(
          icon: Icons.help_outline,
          title: '說明',
          onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const HelpPage())),
        ),
        BatRow(
          icon: Icons.phonelink_erase,
          title: '換手機 / 手機遺失',
          onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const PhoneLostPage())),
        ),
      ]),
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
      // R15: the team rows, dev builds only (T-S5)
      if (devTrust)
        BatCard(children: [
          BatRow(
              key: const Key('settings-team'),
              icon: Icons.groups_outlined,
              title: '隊伍與邀請',
              sub: '邀請隊員、加入隊長的網路、移除隊員與換密碼',
              onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => TeamHubPage(app: app, ui: ui)))),
        ]),
      // #329 PR 6 D6 (design §5.8 10.5): every build
      BatCard(children: [
        BatRow(
            key: const Key('settings-diag'),
            icon: Icons.monitor_heart_outlined,
            title: '診斷',
            sub: 'app 版本、金鑰、每台節點的技術資訊',
            onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => DiagPage(app: app, keys: keys)))),
      ]),
      if (devTrust) ...[
        const BatLabel(Btn.devOptions),
        BatCard(children: [
          // #329 PR 6 D2 / D3 / D4a: the entries that use the owner key are grey with the keys' reason (§5.1 :703)
          for (final (k, icon, title, page) in [
            ('dev-ssh', Icons.vpn_key_outlined, 'SSH 金鑰', () => SshKeysPage(app: app, ui: ui)),
            ('dev-settings', Icons.tune, '查看節點設定', () => NodeSettingsPage(app: app, ui: ui)),
            ('dev-orphans', Icons.link_off, '忘記加入中的節點', () => OrphanJoinsPage(app: app, ui: ui)),
          ])
            BatRow(
                key: Key(k),
                icon: icon,
                title: title,
                sub: _ownerNo,
                enabled: _ownerNo == null,
                onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => page()))),
          BatRow(
              key: const Key('dev-log'),
              icon: Icons.notes,
              title: '文字紀錄',
              onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => LogPage(app: app)))),
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
      Center(child: Text('Batman', style: TextStyle(fontSize: Fs.welcome, fontWeight: FontWeight.w700, color: t.ink))),
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

/// #329 PR 4 §2.9: plain text, one paragraph each (design :374, §3.3 後四碼).
class HelpPage extends StatelessWidget {
  const HelpPage({super.key});

  @override
  Widget build(BuildContext context) => const _TextPage(title: '說明', paragraphs: [
        '首頁列出這支手機管理的節點。點一台進去，可以看它的狀態、加入網路、設定手機 Wi-Fi、軟體更新與更多。',
        '畫面上的狀態大約每分鐘更新一次，旁邊的時間是讀取的時間。節點那邊的狀態本身也會慢一點。',
        '每台節點有兩個名字：暱稱只在這支手機看得到；後四碼印在節點的 QR 上，每支手機都一樣。對別人說是哪一台時，請報後四碼。',
        '要用藍牙連到節點：請開著藍牙，並靠近節點。',
      ]);
}

/// #329 PR 4 §2.9 (design §6 情境 10, board 10.4): what this version cannot do, said plainly.
class PhoneLostPage extends StatelessWidget {
  const PhoneLostPage({super.key});

  @override
  Widget build(BuildContext context) => const _TextPage(title: '換手機 / 手機遺失', paragraphs: [
        '管理節點用的金鑰只存在這支手機裡，沒有備份，也不能搬到另一支手機。',
        '換手機：新手機不能接手這支手機的節點。舊手機還在的話，節點仍然由舊手機管理。',
        '手機遺失：請隊長把你從隊伍移除。你管理的節點要請維修人員重新燒錄，燒完是新的身分和新的 QR，之後再用新手機新增。',
        '這一版沒有「恢復出廠設定」，也沒有把節點交給另一支手機的功能。',
      ]);
}

class _TextPage extends StatelessWidget {
  const _TextPage({required this.title, required this.paragraphs});
  final String title;
  final List<String> paragraphs;

  @override
  Widget build(BuildContext context) {
    final t = BatTheme.of(context);
    return BatPage(title: title, body: [
      for (final p in paragraphs) Text(p, style: TextStyle(fontSize: Fs.body, height: 1.7, color: t.ink)),
    ]);
  }
}
