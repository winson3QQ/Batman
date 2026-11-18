// #254 app S1 — first slice: the startup flavor cross-check (design v8.5.1 §4.1) and an on-device self-test of the Rust
// core. No BLE, no keys generated yet.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'claim.dart';
import 'key_abilities.dart';
import 'scan.dart';
import 'src/nodelink/app_link.dart';
import 'src/nodelink/core.dart' as nlcore show Page;
import 'src/nodelink/raw_use.dart';
import 'src/rust/api/owner.dart' show listNodes, listPending;
import 'src/rust/api/simple.dart';
import 'src/rust/frb_generated.dart';
import 'say.dart' show logText, sayErr;
import 'ui/home_logic.dart' show last4;
import 'ui/home_page.dart';
import 'ui/intro_pages.dart';
import 'ui/theme.dart';
import 'ui/widgets.dart';
import 'ui/ui_state.dart';

const _platform = MethodChannel('dev.batman/platform');

/// #329 PR 6 §3 row 2.4: the key-check page's title bar, its next step when a retry cannot help, and the line above
/// its technical information.
const startupKeysTitle = '手機金鑰';
const startupNoRetryNext = '請找維修人員，把下面的技術資訊給他看。';
const startupTechAsk = '請把技術資訊給維修人員看（可以按「複製文字」）。';
/// #329 PR 6 D1: the older start page's instruction when NodeLink did not start (no retry on the same AppLink, F15).
const restartLine = '請完全關閉 app 再開；仍然如此請找維修人員';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]); // T13: portrait only
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
      theme: batThemeData(Brightness.light),
      darkTheme: batThemeData(Brightness.dark),
      themeMode: ThemeMode.system,
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
  bool _devTrust = false;
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
    final m = ScaffoldMessenger.of(context);
    final busy = await openRawPage(Navigator.of(context), a.link, a.gate, name, (u) => page(a, u));
    if (busy != null) m.showSnackBar(SnackBar(content: Text('另一個操作還在進行：$busy')));
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
      _devTrust = flavorDevTrust == true;
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
            final nodes = await listNodes(dir: dir), pend = await listPending(dir: dir);
            index = [
              for (final n in nodes) '節點 ${last4(n)}', // #329 PR 6 P1-3: the last four (the whole id: 技術資訊)
              for (final n in pend) '節點 ${last4(n)}（認領沒有確認）',
            ];
            tech.addAll([for (final n in nodes) '節點紀錄：$n', for (final n in pend) '認領暫存：$n']);
          }
        } else {
          // one line per reason (claim and recovery share theirs when the owner key is the cause)
          lines.addAll({for (final u in KeyUse.values) keys.refusal(u)}.whereType<String>());
          if (keys.softOwnerEnc) lines.add('注意：這支手機的復原／隊員金鑰只有軟體保護，只適合開發使用');
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
        ..add('啟動檢查失敗：${sayErr(e)}');
    }
    debugPrint('BMAPP ${logText([...lines, ...tech].join(' | '))}');
    final make = widget.makeLink;
    if (agree && keys.appUsable && _app == null && make != null) {
      // review pr1 A-m5: a NodeLink that cannot be built leaves the startup result on screen, never a spinner
      try {
        final a = make((await _platform.invokeMethod<String>('filesDir'))!);
        a.devTrust = _devTrust; // #329 PR 5 §2.6: the one writer, right after the startup check agreed
        a.link.radio(keyOk: keys.login); // X26: the startup key check is the key precondition
        await a.link.start(nlcore.Page.home, life: WidgetsBinding.instance.lifecycleState);
        unawaited(a.nets.recompute()); // #329 PR 3 §2.6: once the startup check passed
        _app = a;
      } catch (e) {
        // #329 PR 6 D1: the reason on screen, the exception in the technical detail; no retry (F15: a second start
        // on the same AppLink would leave half its subscriptions behind)
        lines.add('節點自動讀取沒有啟動');
        tech.add('NodeLink start: $e');
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
    // #329 PR 2: a passed startup check goes straight to the new home page (§5.1)
    final a = _app;
    if (_ok && a != null && mounted) {
      // §4.6 / §5.2: the display memory, then the welcome pages only when never seen and the phone has no node
      final ui = UiState(RecordUiStore(a.records, _platform), log: (l) => debugPrint('BMAPP $l'));
      await ui.load();
      if (!mounted) return;
      final notes = lines.skip(1).toList(); // lines[0] is 「啟動檢查：正常」
      Widget home() => HomePage(app: a, ui: ui, devTrust: _devTrust, keys: keys, notes: notes);
      final nav = Navigator.of(context);
      if (!ui.welcomed && a.link.core.states.isEmpty) {
        nav.pushReplacement(MaterialPageRoute(
            builder: (_) => IntroPages(onDone: () {
                  ui.setWelcomed(); // a write that fails is remembered for this run only (§5.2)
                  nav.pushReplacement(MaterialPageRoute(builder: (_) => home()));
                })));
      } else {
        nav.pushReplacement(MaterialPageRoute(builder: (_) => home()));
      }
    }
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
    final t = BatTheme.of(context);
    // §5.2 board 1.1: the splash while the phone is checked, and on until the home page replaces it (the older start
    // page never flashes in between; PR 2 review A-m4)
    if (_report == null || (_ok && _app != null)) {
      return Scaffold(
        backgroundColor: t.bg,
        body: SafeArea(
          child: Column(children: [
            Expanded(
              child: Center(
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                  Semantics(
                      label: '台灣曙豐防災自訓團臂章',
                      child: Image.asset('assets/brand/badge.webp', width: 160, fit: BoxFit.contain)),
                  const SizedBox(height: 18),
                  Text('Batman', style: TextStyle(fontSize: 28, fontWeight: FontWeight.w700, color: t.ink)),
                  const SizedBox(height: 6),
                  Text('台灣曙豐防災自訓團', style: TextStyle(fontSize: Fs.note, color: t.sub)),
                ]),
              ),
            ),
            Padding(
              padding: const EdgeInsets.only(bottom: 28),
              child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: t.sub)),
                const SizedBox(width: 8),
                Text('正在檢查這支手機…', style: TextStyle(fontSize: Fs.note, color: t.sub)),
              ]),
            ),
          ]),
        ),
      );
    }
    if (!_ok) {
      // §5.2 board 2.4: the key check did not pass; the reason, what the phone holds (names only), a retry when it
      // may help, the technical detail folded away. No gate is relaxed (KeyGate is the existing check).
      final lines = _report!.split('\n');
      // #329 PR 6 §3 row 2.4: a title bar; with no retry, the next step is the repair person (and the copy below)
      final next = [...lines.skip(1), if (!_retry) startupNoRetryNext];
      return BatPage(
        title: startupKeysTitle,
        body: [
          StatusHero(look: Look.bad, text: lines.first, next: next.isEmpty ? null : next.join('\n')),
          if (_index.isNotEmpty) ...[
            BatLabel(_retry ? '手機裡有這些節點的紀錄（沒有打開，也沒有刪除）：' : '這些節點需要重燒卡回收：'),
            BatCard(children: [for (final n in _index) BatRow(icon: Icons.router_outlined, title: n)]),
          ],
          BatCard(children: [
            ExpansionTile(
                key: const Key('startup-tech'),
                title: Text('技術資訊（給維修人員看）', style: TextStyle(fontSize: Fs.body, color: t.ink)),
                children: [
                  Padding(
                    padding: const EdgeInsets.all(14),
                    child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                      Text(startupTechAsk, style: TextStyle(fontSize: Fs.note, color: t.ink)),
                      const SizedBox(height: 8),
                      SelectableText(_tech, style: TextStyle(fontFamily: 'monospace', fontSize: Fs.meta, color: t.ink)),
                      const SizedBox(height: 8),
                      BatButton(Btn.copyText,
                          kind: BtnKind.secondary,
                          onPressed: () => Clipboard.setData(ClipboardData(text: logText('$_report\n$_tech')))),
                    ]),
                  ),
                ]),
          ]),
        ],
        foot: _retry
            ? [
                BatButton(Btn.tryAgain, onPressed: () {
                  setState(() => _report = null);
                  _run();
                }),
              ]
            : null,
      );
    }
    return Scaffold(
      appBar: AppBar(title: const Text('Batman 節點管理')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: _report == null
            ? const Center(child: CircularProgressIndicator())
            : ListView(children: [
                // #329 PR 6 D1: only reached when the check passed but NodeLink did not start (the home page needs
                // it). The reason, what to do, no 「再試一次」 (F15) and no older console.
                Text(_report!, style: const TextStyle(fontSize: 16)),
                const SizedBox(height: 8),
                Text(restartLine, style: const TextStyle(fontSize: 16)),
                const SizedBox(height: 16),
                OutlinedButton(
                    onPressed: _keys.claim // off: the reason is in the report above
                        ? () => _open('新增節點', (a, u) => ClaimPage(ble: a?.ble, use: u))
                        : null,
                    child: const Text('認領節點')),
                if (_devTrust) // the BLE test page: dev builds only (D1)
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
