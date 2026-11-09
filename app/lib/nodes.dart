// #254 app S1 — this phone's nodes (design v8.5.1 §5.3 login, §5.5 status; 254-p3-impl §3.3 settings/get).
// The node record is opened by Kotlin (Keystore record key, AAD from Rust) and handed to Rust, which keeps its secrets;
// a claimed node's advertising carries no id (RPA, UUID list only), so each nearby provd is tried in turn: msg2 that
// does not decrypt = not this node (design §5.0), try the next. Nothing secret is logged.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_reactive_ble/flutter_reactive_ble.dart';

import 'scan.dart' show provdService;
import 'src/rust/api/claim.dart' show frameLimit;
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
  QualifiedCharacteristic? _rxc;
  StreamSubscription<ConnectionStateUpdate>? _conn;
  StreamSubscription<List<int>>? _notify;
  Completer<String>? _answer;

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

  void _say(String s) {
    _log(s);
    if (mounted) setState(() => _lines.add(s));
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
      if (connected.isCompleted) return;
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
          case OwnerKind.loggedIn:
            _say(st.detail);
            if (!done.isCompleted) done.complete(true);
            st = null;
          case OwnerKind.answer:
            _answer?.complete(st.detail);
            st = null;
          case OwnerKind.ended:
            _log('device $id: ${st.detail}');
            if (!done.isCompleted) done.complete(false);
            _answer?.complete('ended: ${st.detail}');
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
        _say('Bluetooth permissions refused');
        return;
      }
      final dir = await _dir();
      final sealed = await storeReadSealed(dir: dir, rel: 'node/$deviceId');
      if (sealed == null) {
        _say('no node record for …${deviceId.substring(deviceId.length - 4)}');
        return;
      }
      final record = (await _platform.invokeMethod<Uint8List>('open', {'sealed': sealed.sealed, 'aad': sealed.aad}))!;
      final ownerPub = ((await _platform.invokeMapMethod<String, dynamic>('publicKeys'))!['owner']) as Uint8List;
      _say('looking for …${deviceId.substring(deviceId.length - 4)}');
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
            setState(() {});
            return;
          }
          scan.resume();
        }
        _say('not found in 60 s (a msg2 that does not decrypt right after a claim: wait a few s and try again)');
      } finally {
        await scan.cancel();
      }
    } catch (e) {
      _say('login stopped: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _ask(OwnerStep Function(OwnerSession) req) async {
    final s = _session;
    if (s == null || _busy) return;
    setState(() => _busy = true);
    try {
      _answer = Completer<String>();
      await _write(req(s).frames);
      _say(await _answer!.future.timeout(const Duration(seconds: 15), onTimeout: () => 'no answer in 15 s'));
    } catch (e) {
      _say('request failed: $e');
    } finally {
      _answer = null;
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final logged = _session != null;
    return Scaffold(
      appBar: AppBar(title: const Text('My nodes')),
      body: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          if (_nodes.isEmpty) const Text('No node claimed on this phone yet.'),
          for (final n in _nodes)
            ListTile(
              title: Text('node …${n.substring(n.length - 4)}'),
              subtitle: Text(_deviceId == n ? 'owner session open' : 'tap to log in'),
              onTap: _busy ? null : () => _login(n),
            ),
          if (logged)
            Row(children: [
              FilledButton(onPressed: _busy ? null : () => _ask((s) => s.requestStatus()), child: const Text('Status')),
              const SizedBox(width: 8),
              OutlinedButton(onPressed: _busy ? null : () => _ask((s) => s.requestSettings()), child: const Text('Settings')),
            ]),
          const Divider(),
          Expanded(child: ListView(children: [for (final l in _lines) Text(l, style: const TextStyle(fontFamily: 'monospace'))])),
        ]),
      ),
    );
  }
}
