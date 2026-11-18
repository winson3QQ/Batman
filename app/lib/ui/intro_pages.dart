// #329 design §5.2 (boards 1.2-1.4, 2.2) and §5.1 board 1.7: first use. The three intro pages show only when the
// welcome was not seen and the phone has no node record (an upgrading user never sees them); 「開始」 and 「跳過說明」
// both count as seen. The Bluetooth permission is asked only when the user presses a button (F28).
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'theme.dart';
import 'widgets.dart';

class IntroPages extends StatefulWidget {
  const IntroPages({super.key, required this.onDone});

  /// 「開始」 or 「跳過說明」: the flag is written and the home page opens.
  final VoidCallback onDone;

  @override
  State<IntroPages> createState() => _IntroPagesState();
}

class _IntroPagesState extends State<IntroPages> {
  int _page = 0;

  Widget _top(String title, [String? sub]) {
    final t = BatTheme.of(context);
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      if (_page == 0)
        Center(
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: Semantics(
                label: '台灣曙豐防災自訓團臂章', child: Image.asset('assets/brand/badge.webp', width: 140, fit: BoxFit.contain)),
          ),
        ),
      Text(title, style: TextStyle(fontSize: Fs.hero, fontWeight: FontWeight.w700, height: 1.3, color: t.ink)),
      if (sub != null) ...[
        const SizedBox(height: 8),
        Text(sub, style: TextStyle(fontSize: Fs.body, height: 1.6, color: t.ink)),
      ],
    ]);
  }

  Widget _dots() {
    final t = BatTheme.of(context);
    return Semantics(
      label: '第 ${_page + 1} 頁，共 3 頁',
      child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
        for (var i = 0; i < 3; i++)
          Container(
            margin: const EdgeInsets.symmetric(horizontal: 4),
            width: i == _page ? 22 : 8,
            height: 8,
            decoration: BoxDecoration(color: i == _page ? t.ink : t.line, borderRadius: BorderRadius.circular(4)),
          ),
      ]),
    );
  }

  @override
  Widget build(BuildContext context) {
    final body = switch (_page) {
      0 => [
          _top('歡迎', '這個 app 用來設定和查看你的無線電節點。'),
          const BatCard(children: [
            BatRow(icon: Icons.hub_outlined, title: '節點會自己連成一個網路', sub: '沒有手機訊號的地方，隊伍也能互相通訊。'),
            BatRow(icon: Icons.smartphone, title: '手機是遙控器', sub: '用藍牙設定節點、看它有沒有連上隊伍。'),
          ]),
        ],
      1 => [
          _top('開始之前，請準備三樣東西'),
          const BatCard(children: [
            BatRow(icon: Icons.router_outlined, title: '你的節點', sub: '接上電源、開機，放在手機旁邊。'),
            BatRow(icon: Icons.qr_code_2, title: '節點機身上的 QR code 貼紙', sub: '它等於這台節點的鑰匙，不要拍照傳給別人。'),
            BatRow(icon: Icons.bluetooth, title: '打開手機的藍牙', sub: 'app 只會連你加入過的節點。'),
          ]),
        ],
      _ => [
          _top('三個步驟就能使用', '大約 10 分鐘。'),
          const BatCard(children: [
            BatRow(icon: Icons.looks_one_outlined, title: '把節點加入這支手機', sub: '掃 QR code'),
            BatRow(icon: Icons.looks_two_outlined, title: '建立網路，或加入隊長的網路', sub: '節點之間互相連上'),
            BatRow(icon: Icons.looks_3_outlined, title: '設定手機 Wi-Fi', sub: '手機上的其他 app 就能透過節點通訊'),
          ]),
          const BatBanner(look: Look.unk, title: '不知道要做什麼時，看首頁最上面', text: '那裡永遠寫著現在的狀況和下一步。'),
        ],
    };
    return PopScope(
      canPop: _page == 0,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) setState(() => _page--);
      },
      child: BatPage(
        title: '',
        body: body,
        foot: [
          _dots(),
          if (_page < 2) BatButton(Btn.next, onPressed: () => setState(() => _page++)),
          if (_page < 2) BatButton(Btn.skipIntro, kind: BtnKind.text, onPressed: widget.onDone),
          if (_page == 2) BatButton(Btn.start, onPressed: widget.onDone),
        ],
      ),
    );
  }
}

/// Board 2.2: why the app asks, before Android asks. 「繼續」 asks for the Bluetooth permission; the camera is asked
/// at the first QR scan (as today). Refused -> this page stays and says where to turn it on.
class PermissionsPage extends StatefulWidget {
  const PermissionsPage({super.key, required this.ask});

  /// Asks Android; true = granted.
  final Future<bool> Function() ask;

  @override
  State<PermissionsPage> createState() => _PermissionsPageState();
}

class _PermissionsPageState extends State<PermissionsPage> {
  bool _refused = false;
  bool _asking = false;

  Future<void> _go() async {
    setState(() => _asking = true);
    // a platform error is a refusal, never a button that stays grey (review r3 E-m6)
    var ok = false;
    try {
      ok = await widget.ask();
    } catch (_) {}
    if (!mounted) return;
    if (ok) {
      Navigator.of(context).pop(true);
      return;
    }
    setState(() {
      _asking = false;
      _refused = true;
    });
  }

  /// The app's own settings page; when the phone has none, says so (review r3 E-m6, as the home page's Bluetooth one).
  Future<void> _appSettings() async {
    var ok = false;
    try {
      ok = await const MethodChannel('dev.batman/platform').invokeMethod<bool>('appSettings') == true;
    } catch (_) {}
    if (!ok && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('打不開設定頁：請自己到手機的「設定 → 應用程式 → Batman」')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = BatTheme.of(context);
    return BatPage(
      title: '開始之前',
      body: [
        Text('app 需要兩個權限', style: TextStyle(fontSize: Fs.hero, fontWeight: FontWeight.w700, color: t.ink)),
        const BatCard(children: [
          BatRow(icon: Icons.bluetooth, title: '藍牙（附近的裝置）', sub: '用來連到你的節點。app 只會連你加入過的節點。'),
          BatRow(icon: Icons.photo_camera_outlined, title: '相機', sub: '只用來掃 QR code，不會拍照或錄影。'),
        ]),
        if (_refused)
          const BatBanner(
              look: Look.warn,
              title: '藍牙權限沒有開',
              text: '請到手機的「設定 → 應用程式 → Batman → 權限」，把「附近的裝置」設為允許，再回來按「繼續」。')
        else
          Text('接下來手機會跳出詢問，請選「允許」。', style: TextStyle(fontSize: Fs.note, height: 1.55, color: t.sub)),
      ],
      foot: [
        BatButton(Btn.goOn, onPressed: _asking ? null : _go),
        if (_refused)
          BatButton(Btn.openAppSettings,
              kind: BtnKind.text, onPressed: _appSettings),
      ],
    );
  }
}

/// Board 1.7: shown once, the first time the home page says everything is fine.
class HomeTipCard extends StatelessWidget {
  const HomeTipCard({super.key, required this.onDone});
  final VoidCallback onDone;

  @override
  Widget build(BuildContext context) {
    final t = BatTheme.of(context);
    Widget line(IconData i, String b, String s) => Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Icon(i, size: 22, color: t.ink),
          const SizedBox(width: 10),
          Expanded(
            child: Text.rich(TextSpan(children: [
              TextSpan(text: b, style: const TextStyle(fontWeight: FontWeight.w700)),
              TextSpan(text: '：$s'),
            ]), style: TextStyle(fontSize: Fs.note, height: 1.55, color: t.ink)),
          ),
        ]);
    return Container(
      decoration: BoxDecoration(color: t.surf, border: Border.all(color: t.ink, width: 2), borderRadius: BorderRadius.circular(14)),
      padding: const EdgeInsets.all(14),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text('第一次使用的提示', style: TextStyle(fontSize: Fs.body, fontWeight: FontWeight.w700, color: t.ink)),
        const SizedBox(height: 10),
        line(Icons.check_circle_outline, '最上面的色塊', '現在的狀況，以及需要你做的下一步。狀態大約每分鐘更新一次。'),
        const SizedBox(height: 8),
        line(Icons.router_outlined, '點一台節點', '看它的詳細狀態。'),
        const SizedBox(height: 8),
        line(Icons.list, '往下滑「可以做的事」', '新增節點等。'),
        const SizedBox(height: 8),
        line(Icons.settings_outlined, '右上角齒輪', '設定、關於。'),
        const SizedBox(height: 10),
        BatButton(Btn.gotIt, kind: BtnKind.text, onPressed: onDone), // #329 PR 6: 「知道了」 is a text button everywhere
      ]),
    );
  }
}
