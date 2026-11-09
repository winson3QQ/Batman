// #254 app S1 — first slice: the startup flavor cross-check (design v8.5.1 §4.1) and an on-device self-test of the Rust
// core. No BLE, no keys generated yet.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'claim.dart';
import 'nodes.dart';
import 'scan.dart';
import 'src/rust/api/simple.dart';
import 'src/rust/frb_generated.dart';

const _platform = MethodChannel('dev.batman/platform');

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await RustLib.init();
  runApp(const BatmanApp());
}

class BatmanApp extends StatelessWidget {
  const BatmanApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Batman',
      theme: ThemeData(colorSchemeSeed: Colors.indigo, useMaterial3: true),
      home: const StartupCheck(),
    );
  }
}

class StartupCheck extends StatefulWidget {
  const StartupCheck({super.key});

  @override
  State<StartupCheck> createState() => _StartupCheckState();
}

class _StartupCheckState extends State<StartupCheck> {
  // what everyone sees (the result, warnings, first-run outcome) / the technical detail, folded away
  String? _report;
  String _tech = '';
  bool _ok = false;

  @override
  void initState() {
    super.initState();
    _run();
  }

  Future<void> _run() async {
    final info = buildInfo();
    final flavorDevTrust = await _platform.invokeMethod<bool>('devTrust');
    // design v8.5.1 §4.1: the Rust library and the flavor must agree, else the app is disabled
    final agree = flavorDevTrust == info.devTrust;
    final lines = <String>[agree ? '啟動檢查：正常' : '啟動檢查：App 內部版本不一致，已停用（請重新安裝 App）'];
    final tech = <String>['核心 dev_trust=${info.devTrust}（batman_bridge ${info.crateVersion}），安裝版 DEV_TRUST=$flavorDevTrust'];
    if (agree) {
      tech.add('自我測試：${selftest()}');
      final inst = await _install();
      for (final l in inst) {
        (l.startsWith('安裝紀錄：') ? tech : lines).add(l); // the marker itself is technical; what happened is not
      }
      try {
        final levels = await _platform.invokeMapMethod<String, dynamic>('keyLevels');
        tech.add('金鑰保護等級：$levels');
        if (levels?['softOwnerEnc'] == true) {
          lines.add('注意：這支手機的復原／成員金鑰只有軟體保護，只適合開發使用');
        }
      } on PlatformException catch (e) {
        lines.add('讀取金鑰失敗（${e.code}）：${e.message}');
      }
    }
    debugPrint('BMAPP ${[...lines, ...tech].join(' | ')}');
    setState(() {
      _ok = agree;
      _report = lines.join('\n');
      _tech = tech.join('\n');
    });
  }

  /// Design v8.5.1 §4.1: the install marker; the four keys are generated only when there is no marker AND no record.
  Future<List<String>> _install() async {
    final out = <String>[];
    final dir = (await _platform.invokeMethod<String>('filesDir'))!;
    final swept = await storeSweep(dir: '$dir/records');
    if (swept > 0) out.add('已清除 $swept 個中途中斷的存檔');
    final marker = await storeReadMarker(dir: '$dir/records');
    if (marker != null) {
      out.add('安裝紀錄：$marker');
      return out;
    }
    if (await storeHasRecords(dir: '$dir/records')) {
      // marker lost but records exist: never delete or regenerate keys
      out.add('找不到安裝紀錄，但手機裡還有節點資料：金鑰保持原樣，不會重建');
      return out;
    }
    try {
      final levels = await _platform.invokeMapMethod<String, dynamic>('firstRun');
      final content = levels!.entries.map((e) => '${e.key}=${e.value}').join(' ');
      await storeWriteMarker(dir: '$dir/records', content: content);
      out.add('第一次啟動：已建立並測試四把金鑰，安裝紀錄：$content');
    } on PlatformException catch (e) {
      out.add('第一次啟動失敗（金鑰已全部刪除，下次開 App 會重試）：${e.message}');
    }
    return out;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Batman 節點管理')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: _report == null
            ? const Center(child: CircularProgressIndicator())
            : ListView(children: [
                Text(_report!, style: TextStyle(fontSize: 16, color: _ok ? null : Colors.red)),
                const SizedBox(height: 16),
                // only an app that passed the startup check talks to nodes; the everyday actions first
                if (_ok)
                  FilledButton(
                      onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const NodesPage())),
                      child: const Text('我的節點')),
                if (_ok)
                  OutlinedButton(
                      onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const ClaimPage())),
                      child: const Text('認領節點')),
                if (_ok)
                  TextButton(
                      onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const ScanPage())),
                      child: const Text('附近的節點（開發用：藍牙測試）')),
                const SizedBox(height: 8),
                ExpansionTile(
                    title: const Text('技術資訊（給維修人員看）'),
                    tilePadding: EdgeInsets.zero,
                    children: [SelectableText(_tech, style: const TextStyle(fontFamily: 'monospace', fontSize: 12))]),
              ]),
      ),
    );
  }
}
