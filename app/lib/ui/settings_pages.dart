// #329 PR 4 §2.4 / §2.5 (design §5.5, boards 5.6 / 5.8): the phone Wi-Fi of a node and its HaLow country. Each read
// and each send is one OpSession.once (the lease only while it runs). Success only when Rust gives the settings
// (§2.1); anything else is the node's reason, 「結果不明」 or 「沒有送出」 as the reply says. The passphrase is taken
// out of its field only after the login, right before the request, and never logged (§5).
import 'dart:async';

import 'package:flutter/material.dart';

import '../say.dart' show screenText;
import '../secure_screen.dart';
import '../src/flows/net_run.dart' show loginLine;
import '../src/flows/op_session.dart';
import '../src/flows/owner_console.dart';
import '../src/nodelink/app_link.dart';
import '../src/nodelink/lease.dart';
import '../src/rust/api/owner.dart' show SettingsView;
import 'home_logic.dart' show last4;
import 'home_page.dart' show nodeInfo;
import 'net_pages.dart' show keepScreen;
import 'theme.dart';
import 'ui_state.dart';
import 'widgets.dart';

/// The app's OpSession parts (§2.0).
OpDeps opDeps(AppLink a) => OpDeps(
      acquire: (name) => a.link.acquire(name, LeaseKind.session),
      busyName: () => a.reg.current?.name ?? '',
      login: (lease, id) => a.link.loginFor(lease, id),
      console: (lease, h) => OwnerConsole(h, lease, a.writer, a.console,
          after: a.link.after,
          nowMs: a.link.now,
          askCountry: (_) async => false, // no settings request asks (a join's question)
          askRemoved: (_) async => false,
          keyError: (e) => keyErrorToRadio(e, a.link),
          log: (l) => debugPrint('BMAPP $l')),
      keepScreen: keepScreen,
    );

/// The line for an operation that did not end with the node's answer, or the answer's own words (no marks).
String opLine(OpReply r) => switch (r.end) {
      OpEnd.busy => '另一個操作還在進行：${r.busyName}',
      OpEnd.login => '${loginLine(r.login!)}沒有送出任何東西。',
      OpEnd.gone => '',
      OpEnd.leaseLost => r.reply == null ? '這個操作被中斷了，沒有送出。請再試一次。' : screenText(r.reply!.text),
      OpEnd.done => screenText(r.reply!.text),
      OpEnd.failed => '操作出錯，結果不明。請重新讀取後再決定要不要再做一次。',
    };

/// The settings when the operation succeeded (Rust gave them), else null.
SettingsView? okSettings(OpReply r) => r.end == OpEnd.done && r.reply!.kind == ReplyKind.answer ? r.reply!.settings : null;

// ---- the node's rules for the phone AP (plan P7 / D1: settingsset.go:60-78, 254-p3-impl §3.3) ----------------------

const _apChars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._~+=,:@%^*-';
const apPlaceholder = 'CHANGE-ME-NOW';

bool _apCharsOnly(String s, {required bool blank}) => s.runes.every((c) => (blank && c == 0x20) || _apChars.contains(String.fromCharCode(c)));

/// Why the name is not accepted by the node, or null.
String? apSsidProblem(String s) {
  if (s.isEmpty || s.length > 32) return '名稱要 1–32 個字元';
  if (!_apCharsOnly(s, blank: true)) return '名稱只能用英文字母、數字、空白與 . _ ~ + = , : @ % ^ * -';
  if (s.startsWith(' ') || s.endsWith(' ')) return '名稱的開頭和結尾不能是空白';
  return null;
}

/// Why the passphrase is not accepted by the node, or null (never the passphrase itself).
String? apPassProblem(String s) {
  if (s.length < 12 || s.length > 63) return '密碼要 12–63 個字元';
  if (!_apCharsOnly(s, blank: false)) return '密碼只能用英文字母、數字與 . _ ~ + = , : @ % ^ * -（不能有空白）';
  if (s == apPlaceholder) return '這是預設的密碼，請換一個';
  return null;
}

/// Board 5.6.
class WifiPage extends StatefulWidget {
  const WifiPage({super.key, required this.app, required this.ui, required this.id, this.deps});
  final AppLink app;
  final UiState ui;
  final String id;
  final OpDeps? deps; // tests

  @override
  State<WifiPage> createState() => _WifiPageState();
}

class _WifiPageState extends State<WifiPage> {
  late final OpDeps _d = widget.deps ?? opDeps(widget.app);
  final _ssid = TextEditingController();
  final _pass = TextEditingController();
  SettingsView? _now;
  bool _reading = false, _sending = false, _show = false;
  String _line = '';
  bool _again = false; // 「重新讀取」 is offered

  @override
  void initState() {
    super.initState();
    _ssid.addListener(_changed);
    _pass.addListener(_changed);
    _read();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _ssid.dispose();
    _pass.dispose();
    super.dispose();
  }

  Future<void> _read() async {
    setState(() {
      _reading = true;
      _line = '';
      _again = false;
    });
    final r = await OpSession.once(_d, widget.id, '手機 Wi-Fi', (c, gone) => c.settings(), gone: () => !mounted);
    if (!mounted) return;
    final v = okSettings(r);
    setState(() {
      _reading = false;
      if (v != null && v.read) {
        _now = v;
        if (_ssid.text.isEmpty) _ssid.text = v.apSsid;
      } else {
        _line = v != null ? '讀不到目前的名稱。' : '讀不到目前的名稱：${opLine(r)}';
        _again = true;
      }
    });
  }

  Future<void> _send() async {
    final ssid = _ssid.text;
    setState(() {
      _sending = true;
      _line = '';
      _again = false;
    });
    final r = await OpSession.once(_d, widget.id, '手機 Wi-Fi', (c, gone) {
      // §2.4 (review D m6): out of the field only now, after the login, right before the request; checked once more
      // (code review B m7: what is sent is what was checked)
      final pass = _pass.text;
      _pass.clear();
      if (apPassProblem(pass) != null || apSsidProblem(ssid) != null) {
        return Future.value(const ConsoleReply(ReplyKind.notSent, '[REQ_FAIL] 名稱或密碼不符合節點的規定，沒有送出'));
      }
      return c.setAp(ssid, pass);
    }, gone: () => !mounted);
    if (!mounted) return;
    final v = okSettings(r);
    setState(() {
      _sending = false;
      if (v != null) {
        if (v.read) _now = v;
        _line = v.read ? '已更新。手機請用新的名稱「${v.apSsid}」和密碼連線。' : '已更新；目前的名稱要重新讀取才看得到。';
        _again = !v.read;
      } else {
        _line = opLine(r);
        _again = r.end == OpEnd.failed || (r.end == OpEnd.done && r.reply!.kind == ReplyKind.unclear);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final t = BatTheme.of(context);
    final ssidBad = apSsidProblem(_ssid.text);
    final passBad = _pass.text.isEmpty ? null : apPassProblem(_pass.text);
    final can = !_reading && !_sending && ssidBad == null && _pass.text.isNotEmpty && passBad == null;
    final cur = _now;
    return PopScope(
      canPop: !_sending,
      child: SecureScreen(
        child: BatPage(
          title: '手機 Wi-Fi',
          body: [
            BatCard(children: [
              BatRow(
                  icon: Icons.wifi,
                  title: '目前的名稱',
                  right: _reading ? '讀取中…' : (cur == null ? '讀不到' : cur.apSsid)),
            ]),
            TextField(
              key: const Key('wifi-ssid'),
              controller: _ssid,
              enabled: !_sending, // code review B m7: the values sent are the ones on screen
              autocorrect: false,
              enableSuggestions: false,
              decoration: InputDecoration(border: const OutlineInputBorder(), labelText: '名稱', errorText: ssidBad),
            ),
            TextField(
              key: const Key('wifi-pass'),
              controller: _pass,
              enabled: !_sending,
              obscureText: !_show,
              autocorrect: false,
              enableSuggestions: false,
              enableIMEPersonalizedLearning: false,
              enableInteractiveSelection: false,
              autofillHints: null, // null disables Android autofill (the default, an empty list, does not)
              keyboardType: _show ? TextInputType.visiblePassword : TextInputType.text,
              decoration: InputDecoration(
                border: const OutlineInputBorder(),
                labelText: '密碼',
                errorText: passBad,
                suffixIcon: IconButton(
                  key: const Key('wifi-show'),
                  tooltip: _show ? '隱藏密碼' : '顯示密碼',
                  icon: Icon(_show ? Icons.visibility_off : Icons.visibility),
                  onPressed: () => setState(() => _show = !_show),
                ),
              ),
            ),
            Text('改完之後，正連著這台 Wi-Fi 的手機（例如跑 TAK 的）會斷線，要用新的名稱和密碼重新連。',
                style: TextStyle(fontSize: Fs.note, height: 1.55, color: t.ink)),
            if (_line.isNotEmpty) Text(_line, key: const Key('wifi-line'), style: TextStyle(fontSize: Fs.body, height: 1.6, color: t.ink)),
          ],
          foot: [
            BatButton(_sending ? '正在送出…' : '送出', onPressed: can ? _send : null),
            if (_again) BatButton('重新讀取', kind: BtnKind.text, onPressed: _reading || _sending ? null : _read),
          ],
        ),
      ),
    );
  }
}

/// Board 5.8: the menu of design §5.5. #329 PR 6 D11: only the countries of [allowedCountries] (US: Taiwan uses that
/// band); a node set to another one shows it and can be changed to US.
final countries = {for (final c in allowedCountries) c: _countryLabels[c] ?? c};
const _countryLabels = {'US': '美國 US（台灣使用這個頻段）'};

bool _hidden(int r) =>
    r < 0x20 ||
    (r >= 0x7f && r < 0xa0) ||
    (r >= 0x200b && r <= 0x200f) ||
    (r >= 0x2028 && r <= 0x202e) ||
    (r >= 0x2060 && r <= 0x206f) ||
    r == 0xfeff;

/// #329 PR 6 D11 (plan §11 MINOR): a node's country string for the screen — control and format characters dropped,
/// at most 8 characters (a node string; the value is never sent back).
String countryShown(String cc) => String.fromCharCodes(cc.runes.where((r) => !_hidden(r)).take(8));

String _countryName(String cc) => countries[cc] ?? '${countryShown(cc)}（不在可選清單）';

class CountryPage extends StatefulWidget {
  const CountryPage({super.key, required this.app, required this.ui, required this.id, this.deps});
  final AppLink app;
  final UiState ui;
  final String id;
  final OpDeps? deps;

  @override
  State<CountryPage> createState() => _CountryPageState();
}

class _CountryPageState extends State<CountryPage> {
  late final OpDeps _d = widget.deps ?? opDeps(widget.app);
  String? _cc; // read in this page's settings read
  bool _reading = false, _sending = false, _again = false;
  String _line = '';
  StreamSubscription<void>? _sub;

  @override
  void initState() {
    super.initState();
    // code review A m2: the menu follows NodeLink's reads while the page is open (after a leave, its refresh)
    _sub = widget.app.link.changed.listen((_) => mounted ? setState(() {}) : null);
    _read();
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  Future<void> _read() async {
    setState(() {
      _reading = true;
      _line = '';
      _again = false;
    });
    final r = await OpSession.once(_d, widget.id, '國家', (c, gone) => c.settings(), gone: () => !mounted);
    if (!mounted) return;
    final v = okSettings(r);
    setState(() {
      _reading = false;
      _cc = v != null && v.read && v.country.isNotEmpty ? v.country : null;
      if (_cc == null) _line = v != null ? '讀不到目前的國家。' : '讀不到目前的國家：${opLine(r)}';
    });
  }

  /// §2.5 (review A m4 / B m7): only after this page read the settings, and only while NodeLink's fresh read says
  /// the node is not in a network; the line saying why otherwise.
  String? _blocked() {
    if (_cc == null) return '先讀到目前的國家。';
    final n = nodeInfo(widget.app, widget.id, widget.ui);
    final v = n.view;
    if (!n.fresh || v == null) return '先讓手機讀到這台的狀態（回節點頁按「重新整理」）。';
    if (v.nodeState.toInt() != 1 || v.netId.isNotEmpty) return '要先離開網路才能改國家。';
    return null;
  }

  Future<void> _pick(String cc) async {
    final from = _cc;
    if (from == null || cc == from) return;
    final t = BatTheme.of(context);
    final yes = await showDialog<bool>(
        context: context,
        builder: (c) => AlertDialog(
              backgroundColor: t.surf,
              title: Text('把這台的國家從 ${_countryName(from)} 改成 ${countries[cc]}？',
                  style: TextStyle(fontSize: Fs.title, fontWeight: FontWeight.w700, color: t.ink)),
              content: Text('之後加入網路時，國家會改成那個網路的國家。', style: TextStyle(fontSize: Fs.body, height: 1.6, color: t.ink)),
              actions: [
                Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  BatButton('改', onPressed: () => Navigator.pop(c, true)),
                  const SizedBox(height: 6),
                  BatButton(Btn.cancel, kind: BtnKind.text, onPressed: () => Navigator.pop(c, false)),
                ]),
              ],
            ));
    if (yes != true || !mounted) return;
    setState(() {
      _sending = true;
      _line = '';
    });
    final r = await OpSession.once(_d, widget.id, '國家', (c, gone) => c.setCountry(cc), gone: () => !mounted);
    if (!mounted) return;
    final v = okSettings(r);
    setState(() {
      _sending = false;
      if (v != null) {
        if (v.read && v.country.isNotEmpty) _cc = v.country;
        _line = '已更新。';
      } else {
        _line = opLine(r);
        // code review A m2 / B m8: an outcome not known (as 5.6) -> 重新讀取
        _again = r.end == OpEnd.failed || (r.end == OpEnd.done && r.reply!.kind == ReplyKind.unclear);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final t = BatTheme.of(context);
    final no = _reading || _sending ? '' : _blocked();
    final cur = _cc;
    return PopScope(
      canPop: !_sending,
      child: BatPage(title: '國家', body: [
        Text('節點的 HaLow 無線電照這個國家的規定使用頻率。台灣使用美國 US 的頻段。', style: TextStyle(fontSize: Fs.note, height: 1.55, color: t.sub)),
        BatCard(children: [
          BatRow(
              key: const Key('country-now'),
              icon: Icons.public,
              title: '目前',
              right: _reading ? '讀取中…' : (cur == null ? '讀不到' : _countryName(cur))),
        ]),
        BatCard(children: [
          for (final e in countries.entries)
            BatRow(
              key: Key('country-${e.key}'),
              icon: e.key == cur ? Icons.radio_button_checked : Icons.radio_button_unchecked,
              title: e.value,
              enabled: no == null,
              onTap: () => _pick(e.key),
            ),
        ]),
        if (no != null && no.isNotEmpty) Text(no, key: const Key('country-why'), style: TextStyle(fontSize: Fs.body, height: 1.6, color: t.sub)),
        if (_line.isNotEmpty) Text(_line, key: const Key('country-line'), style: TextStyle(fontSize: Fs.body, height: 1.6, color: t.ink)),
      ], foot: [
        if ((cur == null || _again) && !_reading) BatButton('重新讀取', kind: BtnKind.secondary, onPressed: _sending ? null : _read),
        Text('後四碼 ${last4(widget.id)}', textAlign: TextAlign.center, style: TextStyle(fontSize: Fs.meta, color: t.sub)),
      ]),
    );
  }
}
