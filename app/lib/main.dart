// #254 app S1 — first slice: the startup flavor cross-check (design v8.5.1 §4.1) and an on-device self-test of the Rust
// core. No BLE, no keys generated yet.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'claim.dart';
import 'key_abilities.dart';
import 'nodes.dart';
import 'scan.dart';
import 'src/nodelink/app_link.dart';
import 'src/nodelink/core.dart' as nlcore show Page;
import 'src/nodelink/lease.dart';
import 'src/nodelink/node_list.dart';
import 'src/nodelink/raw_use.dart';
import 'src/rust/api/owner.dart' show listNodes, listPending;
import 'src/rust/api/simple.dart';
import 'src/rust/frb_generated.dart';

const _platform = MethodChannel('dev.batman/platform');

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await RustLib.init();
  runApp(BatmanApp(makeLink: (dir) => AppLink.create(platform: _platform, filesDir: dir)));
}

class BatmanApp extends StatelessWidget {
  const BatmanApp({super.key, this.makeLink});

  /// #329 PR 1: the app's NodeLink (main passes it; a test of the pages alone does not)
  final AppLink Function(String filesDir)? makeLink;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Batman',
      theme: ThemeData(colorSchemeSeed: Colors.indigo, useMaterial3: true),
      home: StartupCheck(makeLink: makeLink),
    );
  }
}

class StartupCheck extends StatefulWidget {
  const StartupCheck({super.key, this.makeLink});

  /// #329 PR 1: builds the app's NodeLink once the startup check passed (null in tests of the page alone).
  final AppLink Function(String filesDir)? makeLink;

  @override
  State<StartupCheck> createState() => _StartupCheckState();
}

class _StartupCheckState extends State<StartupCheck> {
  AppLink? _app; // #329 PR 1: built once the startup check passed
  // what everyone sees (the result, warnings, first-run outcome) / the technical detail, folded away
  String? _report;
  String _tech = '';
  bool _ok = false;
  KeyAbilities _keys = KeyAbilities.none;
  bool _retry = false; // the key state could not be read / the first run did not finish: offer to try again
  List<String> _index = []; // app off: the plaintext node index (design §4), one line per node; nothing opened or deleted
  bool _firstRunFailed = false;

  @override
  void initState() {
    super.initState();
    _run();
  }

  /// §4.4: an older page that uses Bluetooth or writes records holds a raw lease while it is open.
  Future<void> _open(String name, Widget Function(AppLink? a, RawUse? use) page) async {
    final a = _app;
    if (a == null) {
      // no NodeLink (a test of this page alone): the page as before
      await Navigator.of(context).push(MaterialPageRoute(builder: (_) => page(null, null)));
      return;
    }
    final lease = await a.link.acquire(name, LeaseKind.raw);
    if (!mounted) {
      await lease?.release(); // review pr1 A-m4: never keep a lease no page will use
      return;
    }
    if (lease == null) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('另一個操作還在進行：${a.reg.current?.name ?? ''}')));
      return;
    }
    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => page(a, RawUse(lease, a.gate))));
    lease.pageGone();
    if (mounted) setState(() {});
  }

  Future<void> _run() async {
    var agree = false;
    final lines = <String>[];
    final tech = <String>[];
    var keys = KeyAbilities.none;
    var retry = false;
    var index = <String>[];
    _firstRunFailed = false;
    try {
      final info = buildInfo();
      final flavorDevTrust = await _platform.invokeMethod<bool>('devTrust');
      // design v8.5.1 §4.1: the Rust library and the flavor must agree, else the app is disabled
      agree = flavorDevTrust == info.devTrust;
      lines.add(agree ? '啟動檢查：正常' : '啟動檢查：App 內部版本不一致，已停用（請重新安裝 App）');
      tech.add('核心 dev_trust=${info.devTrust}（batman_bridge ${info.crateVersion}），安裝版 DEV_TRUST=$flavorDevTrust');
      if (agree) {
        tech.add('自我測試：${selftest()}');
        final inst = await _install();
        for (final l in inst) {
          (l.startsWith('安裝紀錄：') ? tech : lines).add(l); // the marker itself is technical; what happened is not
        }
        // design v8.5.1 §4.1 table: the live key levels decide what is on (record AES not hardware = the whole app off)
        keys = await KeyAbilities.read(_platform, detail: (d) => tech.add('金鑰保護等級：$d'));
        if (!keys.appUsable) {
          // three causes, three messages (design §4 / §4.1): unreadable (may be transient -> retry), lost, not hardware
          retry = keys.unread || _firstRunFailed;
          lines[0] = '啟動檢查：${_firstRunFailed && !keys.unread ? '金鑰沒有建立成功，App 暫時不能使用' : keys.offReason}';
          // design §4: the plaintext index (file names only: nothing is opened or deleted), also while the levels
          // cannot be read; an unfinished claim is listed as such. A first run happens only with no record at all.
          if (!_firstRunFailed) {
            final dir = '${(await _platform.invokeMethod<String>('filesDir'))!}/records';
            index = [
              for (final n in await listNodes(dir: dir)) '節點 $n',
              for (final n in await listPending(dir: dir)) '節點 $n（認領沒有確認）',
            ];
          }
        } else {
          // one line per reason (claim and recovery share theirs when the owner key is the cause)
          lines.addAll({for (final u in KeyUse.values) keys.refusal(u)}.whereType<String>());
          if (keys.softOwnerEnc) lines.add('注意：這支手機的復原／成員金鑰只有軟體保護，只適合開發使用');
        }
      }
    } catch (e) {
      // a step that failed (the platform, the record store's sweep / marker / listing): its reason and a retry, never
      // a spinner that does not end
      agree = false;
      keys = KeyAbilities.none;
      retry = true;
      index = [];
      lines
        ..clear()
        ..add('啟動檢查失敗：$e');
    }
    debugPrint('BMAPP ${[...lines, ...tech].join(' | ')}');
    final make = widget.makeLink;
    if (agree && keys.appUsable && _app == null && make != null) {
      // review pr1 A-m5: a NodeLink that cannot be built leaves the startup result on screen, never a spinner
      try {
        final a = make((await _platform.invokeMethod<String>('filesDir'))!);
        a.link.radio(keyOk: keys.login); // X26: the startup key check is the key precondition
        await a.link.start(nlcore.Page.home);
        _app = a;
      } catch (e) {
        lines.add('節點自動讀取沒有啟動：$e');
        debugPrint('BMAPP nodelink start failed: $e');
      }
    }
    setState(() {
      _ok = agree && keys.appUsable;
      _keys = keys;
      _retry = retry;
      _index = index;
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
      _firstRunFailed = true;
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
                // while the levels cannot be read nothing is lost yet: no re-flash advice, only what the phone holds
                if (_index.isNotEmpty)
                  Text(_retry ? '手機裡有這些節點的紀錄（沒有打開，也沒有刪除）：' : '這些節點需要重燒卡回收：',
                      style: const TextStyle(fontSize: 16)),
                for (final n in _index) SelectableText(n, style: const TextStyle(fontFamily: 'monospace')),
                if (_retry)
                  FilledButton(
                      onPressed: () {
                        setState(() => _report = null);
                        _run();
                      },
                      child: const Text('再試一次')),
                if (_ok && _app != null) NodeStatusList(link: _app!.link),
                // only an app that passed the startup check talks to nodes; the everyday actions first
                if (_ok)
                  FilledButton(
                      onPressed: () => _open('我的節點', (a, u) => NodesPage(ble: a?.ble, use: u)),
                      child: const Text('我的節點')),
                if (_ok)
                  OutlinedButton(
                      onPressed: _keys.claim // off: the reason is in the report above
                          ? () => _open('新增節點', (a, u) => ClaimPage(ble: a?.ble, use: u))
                          : null,
                      child: const Text('認領節點')),
                if (_ok)
                  TextButton(
                      onPressed: () => _open('附近的節點', (a, u) => ScanPage(ble: a?.ble, use: u)),
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
