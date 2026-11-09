// #254 app S1 — this phone's nodes (design v8.5.1 §5.3 login, §5.5 status; 254-p3-impl §3.3 settings/get).
// The node record is opened by Kotlin (Keystore record key, AAD from Rust) and handed to Rust, which keeps its secrets;
// a claimed node's advertising carries no id (RPA, UUID list only), so each nearby provd is tried in turn: msg2 that
// does not decrypt = not this node (design §5.0), try the next. Nothing secret is logged.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_reactive_ble/flutter_reactive_ble.dart';

import 'say.dart';
import 'scan.dart' show provdService;
import 'src/rust/api/claim.dart' show frameLimit, storeRemove, storeWriteSealed;
import 'src/rust/api/owner.dart';

const _platform = MethodChannel('dev.batman/platform');
final _rx = Uuid.parse('540aa38c-0086-4d59-a9c0-c7c9d1e1bd42');
final _tx = Uuid.parse('540aa38c-0086-4d5a-a9c0-c7c9d1e1bd42');
final _ctrl = Uuid.parse('540aa38c-0086-4d5b-a9c0-c7c9d1e1bd42');

void _log(String s) => debugPrint('BMAPP owner $s');

class NodesPage extends StatefulWidget {
  const NodesPage({super.key});

  @override
  State<NodesPage> createState() => _NodesPageState();
}

class _NodesPageState extends State<NodesPage> {
  final _ble = FlutterReactiveBle();
  final _lines = <String>[];
  List<String> _nodes = [];
  bool _busy = false;
  // the live owner session
  OwnerSession? _session;
  String? _deviceId;
  // the node of the last owner session: a request after the link dropped (idle BLE disconnects, GATT 133) logs in again
  String? _lastNode;
  QualifiedCharacteristic? _rxc;
  StreamSubscription<ConnectionStateUpdate>? _conn;
  StreamSubscription<List<int>>? _notify;
  Completer<String>? _answer;
  final _country = TextEditingController(); // settings/set key 2 (two capital letters)
  final _apSsid = TextEditingController(); // settings/set key 20
  final _apPass = TextEditingController(); // obscured; cleared once sent
  final _netName = TextEditingController(text: 'Batman'); // make-network (design §5.4)
  int _channel = 40; // US ch 40 (4 MHz, the default) or 42 (2 MHz)
  // the step loop of the open session (set at login): a request whose first step is not a write runs through it
  Future<void> Function(OwnerStep?)? _run;
  final _sshKey = TextEditingController(); // dev: an ssh-ed25519 public key line to add (ssh_keys/set, P2 owner-op)

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _drop();
    super.dispose();
  }

  /// [s] may start with log markers ("[LOGGED_IN] ", "[ANSWER] [NET_MADE] ", ...; owner.rs puts some on its answers):
  /// logcat keeps them, the screen does not.
  void _say(String s) {
    _log(s);
    if (mounted) setState(() => _lines.add(screenText(s)));
  }

  Future<String> _dir() async => '${(await _platform.invokeMethod<String>('filesDir'))!}/records';

  Future<void> _load() async {
    final n = await listNodes(dir: await _dir());
    setState(() => _nodes = n);
  }

  Future<void> _drop() async {
    await _notify?.cancel();
    await _conn?.cancel();
    _notify = null;
    _conn = null;
    _session = null;
    _deviceId = null;
  }

  Future<void> _write(List<Uint8List> frames) async {
    for (final f in frames) {
      await _ble.writeCharacteristicWithoutResponse(_rxc!, value: f);
    }
  }

  /// One login attempt on device [id] with the opened record; true = an owner session is up.
  Future<bool> _tryLogin(String id, Uint8List record, Uint8List ownerPub) async {
    final connected = Completer<bool>();
    final conn = _ble.connectToDevice(id: id, connectionTimeout: const Duration(seconds: 15)).listen((u) {
      if (connected.isCompleted) {
        // the link went away after the login: the session is gone with it (the next request logs in again)
        if (u.connectionState == DeviceConnectionState.disconnected && _rxc?.deviceId == id && _session != null) _lost();
        return;
      }
      if (u.connectionState == DeviceConnectionState.connected) connected.complete(true);
      if (u.connectionState == DeviceConnectionState.disconnected) connected.complete(false);
    }, onError: (Object _) => connected.isCompleted ? null : connected.complete(false));
    if (!await connected.future.timeout(const Duration(seconds: 20), onTimeout: () => false)) {
      await conn.cancel();
      return false;
    }
    final mtu = await _ble.requestMtu(deviceId: id, mtu: 517);
    final ctrl = await _ble.readCharacteristic(QualifiedCharacteristic(characteristicId: _ctrl, serviceId: provdService, deviceId: id));
    final fl = await frameLimit(ctrl: ctrl, mtu: mtu);
    _rxc = QualifiedCharacteristic(characteristicId: _rx, serviceId: provdService, deviceId: id);
    final (s, first) = OwnerSession.start(recordPlain: record, ownerPub: ownerPub, frameLimit: fl);
    final done = Completer<bool>();
    Future<void> run(OwnerStep? st) async {
      while (st != null) {
        switch (st.kind) {
          case OwnerKind.write:
            await _write(st.frames);
            st = null;
          case OwnerKind.sign:
            final der = (await _platform.invokeMethod<Uint8List>('signOwner', {'input': st.signInput}))!;
            st = s.signed(der: der);
          case OwnerKind.signAdmin:
            final der = (await _platform.invokeMethod<Uint8List>('signAdmin', {'input': st.signInput}))!;
            st = s.signed(der: der);
          case OwnerKind.persistNet:
            // the net record lands (sealed, fsynced) before network/join goes out (design §3); never shown
            final sealed = (await _platform.invokeMethod<Uint8List>('seal', {'plain': st.record, 'aad': st.aad}))!;
            await storeWriteSealed(dir: await _dir(), rel: st.rel, generation: st.generation, sealed: sealed);
            _log('已在手機存下網路資料（${st.rel.substring(0, 8)}…，第 ${st.generation} 版）');
            st = s.netPersisted();
          case OwnerKind.loggedIn:
            _say('[LOGGED_IN] ${st.detail}');
            if (!done.isCompleted) done.complete(true);
            st = null;
          case OwnerKind.answer:
            _answer?.complete('[ANSWER] ${st.detail}');
            st = null;
          case OwnerKind.ended:
            _log('裝置 $id：${st.detail}');
            if (!done.isCompleted) done.complete(false);
            _answer?.complete('[REQ_FAIL] 連線已結束：${st.detail}');
            st = null;
        }
      }
    }

    final inbox = StreamController<List<int>>();
    final notify = _ble
        .subscribeToCharacteristic(QualifiedCharacteristic(characteristicId: _tx, serviceId: provdService, deviceId: id))
        .listen(inbox.add, onError: (Object e) => done.isCompleted ? null : done.complete(false));
    inbox.stream.asyncMap((f) => run(s.onFrame(frame: f))).listen((_) {});
    await run(first);
    final ok = await done.future.timeout(const Duration(seconds: 20), onTimeout: () => false);
    if (!ok) {
      await notify.cancel();
      await conn.cancel();
      return false;
    }
    _session = s;
    _run = run;
    _conn = conn;
    _notify = notify;
    return true;
  }

  Future<void> _login(String deviceId) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await _drop();
      if (!(await _platform.invokeMethod<bool>('blePermissions') ?? false)) {
        _say('[LOGIN_FAIL] 沒有藍牙權限（請在手機設定裡允許）');
        return;
      }
      final dir = await _dir();
      final sealed = await storeReadSealed(dir: dir, rel: 'node/$deviceId');
      if (sealed == null) {
        _say('[LOGIN_FAIL] 手機裡沒有節點 …${deviceId.substring(deviceId.length - 4)} 的資料');
        return;
      }
      final record = (await _platform.invokeMethod<Uint8List>('open', {'sealed': sealed.sealed, 'aad': sealed.aad}))!;
      final ownerPub = ((await _platform.invokeMapMethod<String, dynamic>('publicKeys'))!['owner']) as Uint8List;
      _say('正在找節點 …${deviceId.substring(deviceId.length - 4)}…');
      final tried = <String>{};
      final end = DateTime.now().add(const Duration(seconds: 60));
      final found = <String>[];
      final scan = _ble.scanForDevices(withServices: [provdService], scanMode: ScanMode.lowLatency).listen((d) {
        if (tried.add(d.id)) found.add(d.id);
      });
      try {
        while (DateTime.now().isBefore(end)) {
          if (found.isEmpty) {
            await Future<void>.delayed(const Duration(milliseconds: 300));
            continue;
          }
          final id = found.removeAt(0);
          scan.pause();
          final ok = await _tryLogin(id, record, ownerPub);
          if (ok) {
            _deviceId = deviceId;
            _lastNode = deviceId;
            setState(() {});
            return;
          }
          scan.resume();
        }
        _say('[LOGIN_FAIL] [NOT_FOUND] 60 秒內找不到節點 …${deviceId.substring(deviceId.length - 4)}（剛認領完的話，等幾秒再試一次）');
      } finally {
        await scan.cancel();
      }
    } catch (e) {
      _say('[LOGIN_FAIL] 連線中斷：$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _lost() {
    _say('[LINK_LOST] 和節點的連線斷了（下次操作時會自動重新連線）');
    _drop();
    if (mounted) setState(() {});
  }

  /// dev: forget this phone's record of a node (long press). The node is not changed; without the record this phone
  /// cannot log in to it as owner any more. Not in the app design (v8.5.1) — a bench tool for records made stale by a
  /// bench restore.
  Future<void> _forget(String deviceId) async {
    final last4 = deviceId.substring(deviceId.length - 4);
    final yes = await showDialog<bool>(
        context: context,
        builder: (c) => AlertDialog(
              title: Text('開發用：要忘記節點 …$last4 嗎？'),
              content: const Text('忘記之後，這支手機就不能再以擁有者身分管理這台節點。'
                  '節點本身不會被改動。'),
              actions: [
                TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('取消')),
                TextButton(onPressed: () => Navigator.pop(c, true), child: const Text('忘記')),
              ],
            ));
    if (yes != true) return;
    if (_deviceId == deviceId || _lastNode == deviceId) {
      await _drop();
      _lastNode = null;
    }
    try {
      await storeRemove(dir: await _dir(), rel: 'node/$deviceId');
      _say('[FORGOT] 已忘記節點 …$last4');
    } catch (e) {
      _say('忘記失敗：$e');
    }
    await _load();
  }

  /// design §5.4: make a network on this (claimed, not joined) node; country US (S1), bandwidth from the channel
  Future<void> _makeNetwork() async {
    final keys = (await _platform.invokeMapMethod<String, dynamic>('publicKeys'))!;
    final name = _netName.text.trim().isEmpty ? 'Batman' : _netName.text.trim();
    _say('正在建立網路「$name」（頻道 $_channel，美國頻段），最多可能要等 3 分鐘…');
    await _ask(
        (s) => s.requestMakeNetwork(
            netName: name, channel: _channel, ownerEncPub: keys['ownerEnc'] as Uint8List, adminPub: keys['admin'] as Uint8List),
        wait: const Duration(seconds: 180));
  }

  Future<void> _ask(OwnerStep Function(OwnerSession) req, {Duration wait = const Duration(seconds: 15)}) async {
    if (_busy) return;
    if (_session == null && _lastNode != null) await _login(_lastNode!);
    var s = _session;
    if (s == null || _busy) return;
    setState(() => _busy = true);
    try {
      _answer = Completer<String>();
      try {
        await _run!(req(s));
      } on PlatformException catch (e) {
        // nothing reached the node (the write itself failed): log in again and send it once more
        _say('[LINK_LOST] 連線斷了（${e.code}），正在重新連線…');
        await _drop();
        setState(() => _busy = false);
        await _login(_lastNode!);
        s = _session;
        if (s == null) return;
        setState(() => _busy = true);
        _answer = Completer<String>();
        await _run!(req(s));
      }
      _say(await _answer!.future.timeout(wait, onTimeout: () => '[REQ_FAIL] ${wait.inSeconds} 秒內節點沒有回應'));
    } catch (e) {
      _say('[REQ_FAIL] 操作沒有成功：$e');
    } finally {
      _answer = null;
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final logged = _session != null || _lastNode != null; // after a lost link a request logs in again
    return Scaffold(
      appBar: AppBar(title: const Text('我的節點')),
      body: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          if (_nodes.isEmpty) const Text('這支手機還沒有認領任何節點。'),
          for (final n in _nodes)
            ListTile(
              title: Text('節點 …${n.substring(n.length - 4)}'),
              subtitle: Text(_deviceId == n ? '已連線（擁有者）' : '點一下連線（開發用：長按可忘記）'),
              onTap: _busy ? null : () => _login(n),
              onLongPress: _busy ? null : () => _forget(n),
            ),
          if (logged)
            Row(children: [
              FilledButton(onPressed: _busy ? null : () => _ask((s) => s.requestStatus()), child: const Text('查看狀態')),
              const SizedBox(width: 8),
              OutlinedButton(onPressed: _busy ? null : () => _ask((s) => s.requestSettings()), child: const Text('查看設定')),
            ]),
          if (logged)
            Row(children: [
              Expanded(
                  child: TextField(
                      controller: _sshKey,
                      autocorrect: false,
                      enableSuggestions: false,
                      decoration: const InputDecoration(labelText: '開發用：SSH 公鑰（ssh-ed25519 開頭的一行）'))),
              OutlinedButton(
                  onPressed: _busy ? null : () => _ask((s) => s.requestSshKeys(lines: [_sshKey.text.trim()])),
                  child: const Text('加入 SSH 金鑰（開發用）')),
            ]),
          if (logged)
            Row(children: [
              Expanded(
                  child: TextField(
                      controller: _country,
                      autocorrect: false,
                      textCapitalization: TextCapitalization.characters,
                      maxLength: 2,
                      decoration: const InputDecoration(labelText: 'HaLow 無線電的國家代碼（例如 US）', counterText: ''))),
              OutlinedButton(
                  onPressed: _busy ? null : () => _ask((s) => s.requestSetCountry(country: _country.text.trim().toUpperCase())),
                  child: const Text('設定國家')),
            ]),
          if (logged)
            Row(children: [
              Expanded(child: TextField(controller: _apSsid, autocorrect: false, decoration: const InputDecoration(labelText: '給手機連的 Wi-Fi 名稱'))),
              const SizedBox(width: 8),
              Expanded(
                  child: TextField(
                      controller: _apPass,
                      obscureText: true,
                      autocorrect: false,
                      enableSuggestions: false,
                      decoration: const InputDecoration(labelText: 'Wi-Fi 密碼'))),
              OutlinedButton(
                  onPressed: _busy
                      ? null
                      : () {
                          final ssid = _apSsid.text.trim(), pass = _apPass.text;
                          _apPass.clear();
                          _ask((s) => s.requestSetAp(ssid: ssid, passphrase: pass));
                        },
                  child: const Text('設定 Wi-Fi')),
            ]),
          if (logged)
            Row(children: [
              Expanded(child: TextField(controller: _netName, decoration: const InputDecoration(labelText: '網路名稱'))),
              const SizedBox(width: 8),
              DropdownButton<int>(
                  value: _channel,
                  items: const [
                    DropdownMenuItem(value: 40, child: Text('頻道 40（4 MHz）')),
                    DropdownMenuItem(value: 42, child: Text('頻道 42（2 MHz）')),
                  ],
                  onChanged: _busy ? null : (v) => setState(() => _channel = v ?? 40)),
              FilledButton(
                  onPressed: _busy ? null : _makeNetwork,
                  child: const Text('建立網路')),
            ]),
          if (logged)
            Align(
                alignment: Alignment.centerLeft,
                child: TextButton(onPressed: _busy ? null : () => _ask((s) => s.checkNetwork()), child: const Text('檢查網路'))),
          const Divider(),
          Expanded(child: ListView(children: [for (final l in _lines) Text(l, style: const TextStyle(fontFamily: 'monospace'))])),
        ]),
      ),
    );
  }
}
