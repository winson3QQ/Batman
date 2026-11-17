// #329 PR 5 plan v16 §2.2: showing a code (CodeView: QR + 複製文字 + 清除剪貼簿) and taking one in (CodeInput: 掃描 QR
// + 貼上文字). R1 when a QR is drawn, R2 how (whole device pixels), R3 FLAG_SECURE, R4 the clipboard, R5 the input.
// A code is not a secret, but an approval carries the team's names: its QR is not shown where screenshots cannot be
// stopped. No code text is ever logged here.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../secure_screen.dart';
import 'theme.dart';
import 'widgets.dart';

const _platform = MethodChannel('dev.batman/platform');

/// R1: the largest QR version R-8 measured as scannable on the S20 (approval code, v27).
const kQrMaxVersion = 27;

/// R5: a paste longer than this is not an app code (a 128 KiB update bundle is 262 144 hex characters).
const kPasteMax = 300000;

/// The QR modules from Kotlin (QrMatrix): [size]² modules, rows padded to whole bytes, MSB first.
class QrBits {
  const QrBits(this.size, this.version, this.bits);
  final int size, version;
  final Uint8List bits;

  bool on(int x, int y) => (bits[y * ((size + 7) ~/ 8) + x ~/ 8] & (0x80 >> (x % 8))) != 0;
}

/// R1: draw only a well-formed QR of version ≤ [kQrMaxVersion].
bool qrDrawable(QrBits? q) =>
    q != null &&
    q.version >= 1 &&
    q.version <= kQrMaxVersion &&
    q.size == 17 + 4 * q.version &&
    q.bits.length == q.size * ((q.size + 7) ~/ 8);

/// R2: the module width in device pixels (a whole number) for [size] modules plus a 4-module quiet zone on each side
/// in [logicalWidth]; 0 = it does not fit (R1 then shows no QR).
int qrModulePx(double logicalWidth, double dpr, int size) => (logicalWidth * dpr).floor() ~/ (size + 8);

/// The platform calls CodeView / CodeInput use; tests pass fakes.
class CodePlatform {
  const CodePlatform({required this.qrMatrix, required this.copy, required this.clear, required this.read, required this.scan});

  /// upper-case hex → modules, null when Kotlin refused it
  final Future<QrBits?> Function(String upperHex) qrMatrix;

  /// null = done, else a fixed error code (`clipTooLarge` / `clip`)
  final Future<String?> Function(String text) copy;
  final Future<String?> Function() clear;
  final Future<String?> Function() read;

  /// the camera: the text, null when left without one; throws PlatformException(`camera` / `busy`)
  final Future<String?> Function() scan;

  static final real = CodePlatform(
    qrMatrix: (hex) async {
      try {
        final m = await _platform.invokeMapMethod<String, dynamic>('qrMatrix', {'text': hex});
        if (m == null) return null;
        return QrBits(m['size'] as int, m['version'] as int, m['bits'] as Uint8List);
      } on PlatformException {
        return null;
      }
    },
    copy: (text) => _clip('copyCode', {'text': text}),
    clear: () => _clip('clearClip', null),
    read: () async => (await Clipboard.getData(Clipboard.kTextPlain))?.text,
    scan: () => _platform.invokeMethod<String>('scanQr'),
  );

  static Future<String?> _clip(String method, Object? args) async {
    try {
      await _platform.invokeMethod<void>(method, args);
      return null;
    } on PlatformException catch (e) {
      return e.code;
    }
  }
}

/// R2: the QR in whole device pixels, white ground, black modules, 4 modules of quiet zone.
class QrPainter extends CustomPainter {
  QrPainter(this.q, this.modulePx, this.dpr);
  final QrBits q;
  final int modulePx;
  final double dpr;

  @override
  void paint(Canvas canvas, Size size) {
    final m = modulePx / dpr;
    canvas.drawRect(Offset.zero & size, Paint()..color = const Color(0xFFFFFFFF));
    final black = Paint()
      ..color = const Color(0xFF000000)
      ..isAntiAlias = false;
    for (var y = 0; y < q.size; y++) {
      for (var x = 0; x < q.size; x++) {
        if (q.on(x, y)) canvas.drawRect(Rect.fromLTWH((x + 4) * m, (y + 4) * m, m, m), black);
      }
    }
  }

  @override
  bool shouldRepaint(QrPainter old) => old.q != q || old.modulePx != modulePx || old.dpr != dpr;
}

/// R1–R4: one code to hand over. [hex] is the lower-case hex the old console copied; the QR shows it upper-cased.
class CodeView extends StatefulWidget {
  const CodeView({super.key, required this.hex, this.platform, this.qr = true, this.tooLong = '這個碼太長，無法用 QR 顯示，請用「複製文字」傳給對方'});
  final String hex;

  /// false: text only, no QR (an update bundle, UI/UX T10)
  final bool qr;
  final CodePlatform? platform;
  final String tooLong;

  @override
  State<CodeView> createState() => _CodeViewState();
}

class _CodeViewState extends State<CodeView> {
  CodePlatform get _p => widget.platform ?? CodePlatform.real;
  QrBits? _q;
  bool _asked = false, _copied = false, _cleared = false;
  String _line = '';
  ScaffoldMessengerState? _messenger;

  @override
  void initState() {
    super.initState();
    if (!widget.qr) return;
    _p.qrMatrix(widget.hex.toUpperCase()).then((q) {
      if (!mounted) return;
      setState(() {
        _q = q;
        _asked = true;
      });
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _messenger = ScaffoldMessenger.maybeOf(context);
  }

  @override
  void dispose() {
    // R4: leaving with the code still on the clipboard -> one reminder
    final m = _messenger;
    if (_copied && !_cleared && m != null) {
      // after this frame, and only if the messenger itself is still there (not while the whole tree goes away)
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (m.mounted) m.showSnackBar(const SnackBar(content: Text('剛才複製的碼還在剪貼簿')));
      });
    }
    super.dispose();
  }

  Future<void> _copy() async {
    final e = await _p.copy(widget.hex);
    if (!mounted) return;
    setState(() {
      _copied = e == null || _copied;
      _cleared = e == null ? false : _cleared;
      _line = switch (e) {
        null => '已複製',
        'clipTooLarge' => '這段太大，無法複製',
        _ => '複製失敗',
      };
    });
  }

  Future<void> _clear() async {
    final e = await _p.clear();
    if (!mounted) return;
    setState(() {
      _cleared = e == null;
      _line = e == null ? '已清除剪貼簿' : '清除失敗';
    });
  }

  @override
  Widget build(BuildContext context) {
    final t = BatTheme.of(context);
    final note = TextStyle(fontSize: Fs.note, height: 1.55, color: t.sub);
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      if (!widget.qr)
        Text('剪貼簿裡的東西，手機上別的 app 也讀得到；傳完請按「清除剪貼簿」', key: const Key('code-clipwarn'), style: note)
      else
      SecureScreen(
        fallback: Column(children: [
          Text('這支手機無法防止截圖，所以不顯示 QR', key: const Key('code-noqr'), style: TextStyle(fontSize: Fs.body, height: 1.6, color: t.ink)),
          Text('剪貼簿裡的東西，手機上別的 app 也讀得到；傳完請按「清除剪貼簿」', key: const Key('code-clipwarn'), style: note),
        ]),
        child: !_asked
            ? const SizedBox(height: 48)
            : qrDrawable(_q)
                ? LayoutBuilder(builder: (context, box) {
                    final dpr = MediaQuery.devicePixelRatioOf(context);
                    final px = qrModulePx(box.maxWidth, dpr, _q!.size);
                    if (px <= 0) return Text(widget.tooLong, key: const Key('code-toolong'), style: note);
                    final sidePx = px * (_q!.size + 8);
                    // the left edge on a whole device pixel of this box (R2)
                    final leftPx = ((box.maxWidth * dpr).floor() - sidePx) ~/ 2;
                    return Padding(
                      padding: EdgeInsets.only(left: leftPx / dpr),
                      child: Align(
                        alignment: Alignment.topLeft,
                        child: RepaintBoundary(
                          key: const Key('code-qr'),
                          child: CustomPaint(size: Size.square(sidePx / dpr), painter: QrPainter(_q!, px, dpr)),
                        ),
                      ),
                    );
                  })
                : Text(widget.tooLong, key: const Key('code-toolong'), style: note),
      ),
      const SizedBox(height: 12),
      BatButton(Btn.copyText, key: const Key('code-copy'), kind: BtnKind.secondary, onPressed: _copy),
      if (_copied) BatButton(Btn.clearClip, key: const Key('code-clear'), kind: BtnKind.text, onPressed: _clear),
      // §5 / T-m8 (review A m5): after any copy (Android 12's sensitive flag is not verified), the warning is shown
      if (_copied && widget.qr) Text('剪貼簿裡的東西，手機上別的 app 也讀得到；傳完請按「清除剪貼簿」', key: const Key('code-clipwarn-copied'), style: note),
      Text('鍵盤 app 自己的剪貼簿紀錄，這裡清不到', style: note),
      if (_line.isNotEmpty) Text(_line, key: const Key('code-line'), style: note),
    ]);
  }
}

/// R5: taking a code in. Both ways hand the raw text to [onText]; Rust parses it (from_hex takes upper case and
/// spaces). Pasting is dev-only (PasteButton's rule) and always clears the clipboard afterwards, refused or not (R4).
class CodeInput extends StatefulWidget {
  const CodeInput({super.key, required this.devTrust, required this.onText, required this.onError, this.platform, this.scan = true});
  final bool devTrust;

  /// false: paste only (8.5: an update bundle has no QR, T10)
  final bool scan;
  final void Function(String text) onText;
  final void Function(String why) onError;
  final CodePlatform? platform;

  @override
  State<CodeInput> createState() => _CodeInputState();
}

class _CodeInputState extends State<CodeInput> {
  CodePlatform get _p => widget.platform ?? CodePlatform.real;
  bool _busy = false;

  Future<void> _scan() async {
    setState(() => _busy = true);
    String? text;
    try {
      text = await _p.scan();
    } on PlatformException catch (e) {
      widget.onError(e.code == 'camera' ? '無法使用相機：請確認已允許相機權限，且沒有其他 app 正在使用相機' : '現在無法掃描，請再試一次');
      return;
    } finally {
      if (mounted) setState(() => _busy = false);
    }
    if (text != null && mounted) widget.onText(text);
  }

  Future<void> _paste() async {
    if (!widget.devTrust) {
      widget.onError('只有開發版可以貼上');
      return;
    }
    // R4 (review B m4): cleared after every paste, also when reading it threw
    String text;
    String? cleared;
    try {
      text = await _p.read() ?? '';
    } catch (_) {
      text = '';
    } finally {
      cleared = await _p.clear();
    }
    if (!mounted) return;
    if (cleared != null) widget.onError('清除剪貼簿失敗，請自己清掉');
    if (text.trim().isEmpty) return widget.onError('剪貼簿是空的');
    if (text.length > kPasteMax) return widget.onError('這段文字太長，不是 app 產生的碼');
    widget.onText(text);
  }

  @override
  Widget build(BuildContext context) => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        if (widget.scan) BatButton(Btn.scanQr, key: const Key('code-scan'), onPressed: _busy ? null : _scan),
        if (widget.scan) const SizedBox(height: 8),
        if (widget.devTrust) BatButton(Btn.pasteText, key: const Key('code-paste'), kind: BtnKind.secondary, onPressed: _busy ? null : _paste),
      ]);
}

