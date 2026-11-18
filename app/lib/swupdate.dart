// #254 app S5 — software update (docs/design/254-app-update.md v0.4 FROZEN §3, §11). The flow is Rust's
// (batman_proto::swupd behind the opaque SwUpdate); this page only moves things: BLE requests through the node page's
// owner session ([ask]), waits, the PUT through Kotlin (channel dev.batman/swupdate, §11.1), the operator's presses.
// D8: nothing here is ever logged (no debugPrint, no print: T4 checks it); the AP passphrase passes once from Rust to
// Kotlin `joinAp` and only when the Specifier is needed; the bearer only to Kotlin `upload`.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'src/rust/api/swupdate.dart';
import 'ui/theme.dart';
import 'ui/widgets.dart';

const swChannel = MethodChannel('dev.batman/swupdate');

/// What the page needs of the Rust flow (the app passes [RustSwFlow]; tests a scripted one).
abstract class SwFlow {
  SwAction start();
  SwAction picked(List<SwFile> files);
  SwAction press(SwButton b, BigInt nowMs);
  SwAction resume();
  SwAction keepalive();
  SwAction uploaded(SwPut r);
  List<String> apCredentials();
}

class RustSwFlow implements SwFlow {
  RustSwFlow(this.sw);
  final SwUpdate sw;
  @override
  SwAction start() => sw.start();
  @override
  SwAction picked(List<SwFile> files) => sw.picked(files: files);
  @override
  SwAction press(SwButton b, BigInt nowMs) => sw.press(button: b, nowMs: nowMs);
  @override
  SwAction resume() => sw.resume();
  @override
  SwAction keepalive() => sw.keepalive();
  @override
  SwAction uploaded(SwPut r) => sw.uploaded(result: r);
  @override
  List<String> apCredentials() => sw.apCredentials();
}

/// One update kept by the node page while the page is closed (§3.5: to the Wi-Fi row and back): the flow, its last
/// action, the picked files' URIs (memory only, D7) and whether the Specifier network is held.
class SwHold {
  SwHold(this.flow);
  final SwFlow flow;
  SwAction? last;
  List<String> uris = [];
  bool netHeld = false;

  /// D5 (code review r1 A-M2 / B-M1): this upload stage joined the node AP with the Specifier — the next PUT of the
  /// stage goes out on that network again: no second notice, no second request (each would cut TAK twice)
  bool joined = false;

  /// v0.4.2: the last PUT's non-secret code from Kotlin (refused / unreached / watchdog / ...), for 技術資訊
  String putCode = '';
  final clock = Stopwatch()..start();
  BigInt now() => BigInt.from(clock.elapsedMilliseconds);
}

/// #329 PR 6 §3 row swupdate (plan §11 MINOR): the status area at the top of the page — prepared = ok, writing / any
/// step in progress = busy, finished = ok, failed (reverted) = bad, ended otherwise (later, cancelled) = unk. Null = no
/// status area (a screen that asks for a file or a setting).
(Look, String)? swHero(SwAction? a, {required bool running}) {
  if (a == null) return null;
  if (running || a.kind == SwKind.send || a.kind == SwKind.wait || a.kind == SwKind.upload) {
    return (Look.busy, a.text.isNotEmpty ? a.text : (a.note.isNotEmpty ? a.note : '進行中'));
  }
  if (a.kind == SwKind.show_ && a.buttons.contains(SwButton.applyAnyway)) return (Look.ok, swPrepared);
  if (a.kind == SwKind.show_ && a.buttons.contains(SwButton.apply)) {
    // the written screen (swupd.rs written_screen: no code), else the apply was refused: that screen keeps 套用 to retry
    // and carries the node's codes in its technical line (swupd.rs fn tech: 「代碼 N…」)
    return a.tech.contains('代碼') ? (Look.bad, '還沒套用：節點沒有接受') : (Look.ok, swPrepared);
  }
  if (a.kind == SwKind.done) {
    if (a.text.startsWith('更新完成')) return (Look.ok, a.text);
    if (a.text.contains('退回') || a.text.contains('回到原本的版本')) return (Look.bad, '更新沒有成功，已回到原本的版本');
    return (Look.unk, '更新已結束');
  }
  return null;
}

/// The prepared state's sentence (plan §11 MINOR).
const swPrepared = '已準備好，還沒套用';

String buttonLabel(SwButton b) => switch (b) {
      SwButton.pick => '選擇更新檔',
      SwButton.start => '開始傳送',
      SwButton.cancel => '取消',
      SwButton.apply => '套用並重開',
      SwButton.applyAnyway => '確定，套用並重開',
      SwButton.abandon => '放棄這個上傳',
      SwButton.setAp => '去設定手機 Wi-Fi',
      SwButton.apDone => '設好了，繼續',
      SwButton.retry => '再試一次',
      SwButton.wifiPanel => '開啟 Wi-Fi 設定',
      SwButton.refresh => '重新整理',
    };

/// Kotlin `upload` / `joinAp` result -> the flow
SwPut putOf(String? r) => switch (r) {
      'ok200' => SwPut.ok200,
      'no_network' => SwPut.noNetwork,
      'denied' => SwPut.denied,
      _ => SwPut.other,
    };

class SwUpdatePage extends StatefulWidget {
  const SwUpdatePage(
      {super.key, required this.hold, required this.ask, required this.onSetAp, this.channel = swChannel, this.specifierText, this.onShown});

  /// #329 PR 4 §2.8: the page showed a new action (AppLink.sw notifies the home page)
  final VoidCallback? onShown;

  final SwHold hold;

  /// one BLE request of the flow on the node page's owner session (re-login included) -> the flow's next action
  final Future<SwAction> Function(int waitMs) ask;

  /// §3.5: back to the node page's 「設定 Wi-Fi」 row (the update waits in [hold])
  final VoidCallback onSetAp;
  final MethodChannel channel;

  /// D5: the line before the phone leaves its Wi-Fi (Rust T_SPECIFIER)
  final String? specifierText;

  @override
  State<SwUpdatePage> createState() => _SwUpdatePageState();
}

class _SwUpdatePageState extends State<SwUpdatePage> {
  SwAction? _a;
  bool _running = false;
  bool _cancel = false;
  int _sent = 0;
  Timer? _progress;

  SwHold get _h => widget.hold;
  SwFlow get _f => widget.hold.flow;
  MethodChannel get _ch => widget.channel;

  @override
  void initState() {
    super.initState();
    _keepScreen(true);
    final last = _h.last;
    if (last == null || last.kind == SwKind.done) {
      _go(_f.start());
    } else {
      _a = last;
    }
  }

  @override
  void dispose() {
    _progress?.cancel();
    _keepScreen(false);
    super.dispose();
  }

  Future<void> _keepScreen(bool on) async {
    try {
      await _ch.invokeMethod<void>('keepScreenOn', {'on': on});
    } on PlatformException {
      // D9 is a convenience: the flow does not depend on it
    } on MissingPluginException {
      // (tests without the channel)
    }
  }

  void _show(SwAction a) {
    _h.last = a;
    // #329 PR 4 §2.8: the home page's todo follows (review C m8); after this frame — the first action is shown from
    // initState, while the route is being built (code review A m1 / B m1)
    final n = widget.onShown;
    if (n != null) scheduleMicrotask(n);
    if (mounted) setState(() => _a = a);
  }

  /// D5: the upload stage is over -> the Specifier network goes (once)
  Future<void> _release(SwAction a) async {
    if (_h.netHeld && !a.uploading) {
      _h.netHeld = false;
      _h.joined = false;
      await _ch.invokeMethod<void>('cancelUpload');
    }
  }

  /// Runs the flow until it needs the operator (Show / Done).
  Future<void> _go(SwAction a) async {
    if (_running) return;
    _running = true;
    try {
      while (true) {
        if (a.kind != SwKind.nothing) _show(a);
        await _release(a);
        switch (a.kind) {
          case SwKind.send:
            a = await widget.ask(a.waitMs.toInt());
          case SwKind.wait:
            await Future<void>.delayed(Duration(milliseconds: a.waitMs.toInt()));
            a = _f.resume();
          case SwKind.upload:
            a = await _upload(a);
          case SwKind.show_ || SwKind.done || SwKind.nothing:
            return;
        }
      }
    } finally {
      _running = false;
      if (mounted) setState(() {});
    }
  }

  /// U5 / U6 (§11.1 order): the current Wi-Fi first, else the Specifier after the D5 notice; keepalive every 10 s
  Future<SwAction> _upload(SwAction a) async {
    // v0.4.2 (04 + S20): a VPN covering this app takes the PUT into its tunnel, even on the node AP's network — stop
    // before the AP lookup and before a Specifier join (no TAK cut for nothing); nothing is held yet
    if (await _ch.invokeMethod<bool>('vpnActive') ?? false) {
      _h.putCode = 'vpn';
      return _f.uploaded(SwPut.vpn);
    }
    _h.netHeld = true;
    _cancel = false;
    _sent = 0;
    var stop = false;
    Future<void> keep() async {
      while (!stop) {
        for (var i = 0; i < 10 && !stop; i++) {
          await Future<void>.delayed(const Duration(seconds: 1));
        }
        if (stop) return;
        final k = _f.keepalive();
        if (k.kind == SwKind.send) await widget.ask(k.waitMs.toInt());
      }
    }

    _progress = Timer.periodic(const Duration(seconds: 1), (_) async {
      try {
        final n = await _ch.invokeMethod<int>('uploadProgress');
        if (mounted && n != null) setState(() => _sent = n);
      } on PlatformException {
        // the bar is a convenience
      }
    });
    final keeping = keep();
    String? r;
    try {
      r = await _reach(a);
    } on PlatformException {
      r = 'other';
    } finally {
      stop = true;
      _progress?.cancel();
      await keeping; // the keepalive's answer is in before the PUT result goes to the flow
    }
    if (_cancel) return _f.press(SwButton.cancel, _h.now());
    return _f.uploaded(putOf(r));
  }

  /// D5: the network the PUT goes out on, then the PUT. Every step checks a cancel first (r1 A-m5 / B-m3).
  Future<String?> _reach(SwAction a) async {
    if (_h.joined) {
      // the Specifier network of this stage is still held: the PUT again on it (no notice, no new request)
      final r = await _put(a);
      if (r != 'no_network') return r;
      _h.joined = false; // it went away: join again (the notice was given in this stage)
      return _join(a, notice: false);
    }
    if (_cancel) return 'other';
    final direct = await _ch.invokeMethod<bool>('findNodeNetwork', {'ip': a.ip}) ?? false;
    if (direct) {
      final r = await _put(a);
      if (r != 'no_network') return r;
    }
    return _join(a, notice: true);
  }

  Future<String?> _join(SwAction a, {required bool notice}) async {
    if (_cancel) return 'other';
    if (notice && !await _specifierOk()) return 'denied';
    if (_cancel) return 'other';
    final c = _f.apCredentials();
    final j = c.length == 2 ? await _ch.invokeMethod<String>('joinAp', {'ssid': c[0], 'pass': c[1]}) : 'no_network';
    if (j != 'ok') return j;
    _h.joined = true;
    return _put(a);
  }

  Future<String?> _put(SwAction a) async {
    if (_cancel) return 'other';
    final r = await _ch.invokeMethod<String>('upload', {
        'uri': _h.uris[a.payload],
        'size': a.size.toInt(),
        'ip': a.ip,
        'port': a.port,
        'bearer': a.bearerHex,
      });
    // v0.4.2: how a PUT that was not 200 ended (a fixed word, never the bearer), shown under 技術資訊
    _h.putCode = r == 'ok200' ? '' : (await _ch.invokeMethod<String>('lastUploadCode') ?? '');
    return r;
  }

  Future<bool> _specifierOk() async {
    if (!mounted) return false;
    return await showDialog<bool>(
            context: context,
            builder: (c) => AlertDialog(
                  title: const Text('連到節點的 Wi-Fi'),
                  content: Text(widget.specifierText ?? ''),
                  actions: [
                    TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('取消')),
                    TextButton(onPressed: () => Navigator.pop(c, true), child: const Text('繼續')),
                  ],
                )) ==
        true;
  }

  Future<void> _press(SwButton b) async {
    switch (b) {
      case SwButton.pick:
        final List<Object?> got;
        try {
          got = await _ch.invokeMethod<List<Object?>>('pickUpdateFiles') ?? const [];
        } on PlatformException {
          return;
        }
        if (got.isEmpty) return;
        final maps = got.cast<Map<Object?, Object?>>();
        _h.uris = [for (final m in maps) m['uri'] as String];
        final files = [
          for (final m in maps)
            SwFile(size: m['size'] as int, head: m['head'] as Uint8List, data: m['data'] as Uint8List),
        ];
        await _go(_f.picked(files));
      case SwButton.setAp:
        widget.onSetAp();
      case SwButton.wifiPanel:
        await _ch.invokeMethod<void>('wifiPanel');
      default:
        await _go(_f.press(b, _h.now()));
    }
  }

  /// U6 cancel: abort the socket first (linger 0, Kotlin), then the flow closes the window when the PUT returns
  Future<void> _cancelUpload() async {
    _cancel = true;
    _h.joined = false;
    await _ch.invokeMethod<void>('cancelUpload');
  }

  /// #329 PR 4 §2.8: the dangerous buttons (they cut the node off for a while: the note says how long)
  BtnKind _kind(SwButton b) => switch (b) {
        // #329 PR 6 P2-5 (9.2): 「開始傳送」 starts what cannot be cancelled once writing starts (T_CONFIRM says so)
        SwButton.apply || SwButton.applyAnyway || SwButton.start => BtnKind.danger,
        SwButton.cancel || SwButton.abandon => BtnKind.text,
        _ => BtnKind.primary,
      };

  @override
  Widget build(BuildContext context) {
    final a = _a;
    final uploading = a?.kind == SwKind.upload;
    final t = BatTheme.of(context);
    final hero = swHero(a, running: _running);
    // #329 PR 4 §2.8: PR 2's page parts; what shows when, and every button, as before
    return PopScope(
      canPop: !_running,
      child: BatPage(
        title: '軟體更新',
        body: [
          if (hero case (final look, final text)) StatusHero(key: const Key('sw-hero'), look: look, text: text),
          if (a != null && a.text.isNotEmpty && hero?.$2 != a.text) // (said once: not again under the status area)
            Text(a.text, style: TextStyle(fontSize: Fs.title, fontWeight: FontWeight.w700, height: 1.4, color: t.ink)),
          if (a != null && a.note.isNotEmpty) Text(a.note, style: TextStyle(fontSize: Fs.body, height: 1.6, color: t.ink)),
          if (a != null && a.percent >= 0) LinearProgressIndicator(value: a.percent / 100),
          if (uploading && a != null) ...[
            LinearProgressIndicator(value: a.size > BigInt.zero ? _sent / a.size.toDouble() : null),
            Text('已送出 ${(_sent / 1048576).toStringAsFixed(1)} / ${(a.size.toDouble() / 1048576).toStringAsFixed(1)} MB',
                style: TextStyle(fontSize: Fs.meta, color: t.sub)),
            BatButton('取消', kind: BtnKind.secondary, onPressed: _cancel ? null : _cancelUpload),
          ],
          if (_running && !uploading) const Padding(padding: EdgeInsets.all(8), child: Center(child: CircularProgressIndicator())),
          if (a != null && (a.tech.isNotEmpty || _h.putCode.isNotEmpty))
            ExpansionTile(title: const Text('技術資訊（給維修人員看）'), children: [
              Text([if (a.tech.isNotEmpty) a.tech, if (_h.putCode.isNotEmpty) 'PUT: ${_h.putCode}'].join(';'),
                  style: TextStyle(fontFamily: 'monospace', fontSize: Fs.meta, color: t.ink)),
            ]),
        ],
        foot: [
          if (a != null && !_running) ...[
            for (final b in a.buttons) BatButton(buttonLabel(b), kind: _kind(b), onPressed: () => _press(b)),
            if (a.kind == SwKind.done) BatButton('關閉', onPressed: () => Navigator.pop(context)),
          ],
        ],
      ),
    );
  }
}
