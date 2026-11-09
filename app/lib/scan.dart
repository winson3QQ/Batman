// #254 app S1 — BLE probe (design v8.5.1 §9 step 2): does Android list provd's advertising (UUID list only,
// non-discoverable, RPA, no name; bluez.go:226-229) with BLUETOOTH_SCAN neverForLocation, what MTU does the link get,
// and what does STATUS say. Scan + connect + one read only: no pairing (design §2), no write, no handshake.
// Every result goes to logcat as "BMAPP ble ..." so the probe can be read off the phone with adb.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_reactive_ble/flutter_reactive_ble.dart';

import 'say.dart';
import 'src/rust/api/simple.dart';

const _platform = MethodChannel('dev.batman/platform');
// feed/batman-prov/src/cmd/batman-provd/bluez.go:30-34
final provdService = Uuid.parse('540aa38c-0086-4d58-a9c0-c7c9d1e1bd42');
final provdStatus = Uuid.parse('540aa38c-0086-4d5c-a9c0-c7c9d1e1bd42');

void _log(String s) => debugPrint('BMAPP ble $s');

class ScanPage extends StatefulWidget {
  const ScanPage({super.key});

  @override
  State<ScanPage> createState() => _ScanPageState();
}

class _ScanPageState extends State<ScanPage> {
  final _ble = FlutterReactiveBle();
  final _found = <String, DiscoveredDevice>{};
  final _status = <String, String>{};
  StreamSubscription<DiscoveredDevice>? _scan;
  String _note = '';
  bool _busy = false;

  @override
  void dispose() {
    _scan?.cancel();
    super.dispose();
  }

  Future<void> _start() async {
    final ok = await _platform.invokeMethod<bool>('blePermissions') ?? false;
    _log('permissions granted=$ok');
    if (!ok) {
      setState(() => _note = '沒有藍牙權限，無法搜尋（請在手機設定裡允許）');
      return;
    }
    await _scan?.cancel();
    setState(() {
      _found.clear();
      _note = '正在搜尋附近的節點…';
    });
    _scan = _ble.scanForDevices(withServices: [provdService], scanMode: ScanMode.lowLatency).listen((d) {
      if (!_found.containsKey(d.id)) _log('found id=${d.id} rssi=${d.rssi} name=[${d.name}] uuids=${d.serviceUuids}');
      setState(() => _found[d.id] = d);
    }, onError: (Object e) {
      _log('scan error $e');
      setState(() => _note = '搜尋出錯：$e');
    });
  }

  Future<void> _stop() async {
    await _scan?.cancel();
    _scan = null;
    setState(() => _note = '已停止搜尋（找到 ${_found.length} 台）');
  }

  /// Connect, ask for MTU 517 (design §2), read STATUS once, disconnect. Connecting withdraws the node's
  /// advertising until the link drops (bluez.go:325,666-669).
  Future<void> _read(DiscoveredDevice d) async {
    if (_busy) return;
    await _stop();
    setState(() {
      _busy = true;
      _status[d.id] = '連線中…';
    });
    StreamSubscription<ConnectionStateUpdate>? conn;
    final done = Completer<String>();
    conn = _ble.connectToDevice(id: d.id, connectionTimeout: const Duration(seconds: 15)).listen((u) async {
      _log('conn id=${d.id} state=${u.connectionState} failure=${u.failure}');
      if (u.connectionState == DeviceConnectionState.connected && !done.isCompleted) {
        try {
          final mtu = await _ble.requestMtu(deviceId: d.id, mtu: 517);
          final raw = await _ble.readCharacteristic(
              QualifiedCharacteristic(characteristicId: provdStatus, serviceId: provdService, deviceId: d.id));
          final hex = raw.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
          String what;
          try {
            final s = decodeStatus(bytes: raw);
            what = '${stateText(s.state)}，試用中：${s.trial ? '是' : '否'}，編號末四碼：${s.idLast4 ?? '（不公開）'}'
                '（技術資訊：state=${s.state} versions=${s.versions} transports=${s.transports}）';
          } catch (e) {
            what = '看不懂節點的狀態資料：$e';
          }
          _log('read id=${d.id} mtu=$mtu status=$hex $what');
          done.complete('$what\n連線封包大小 MTU $mtu');
        } catch (e) {
          // a stale cache on the node is an ATT error 0x0E (server.go:562-566): no value, not a guess
          _log('read id=${d.id} error $e');
          done.complete('讀取失敗：$e');
        }
      } else if (u.connectionState == DeviceConnectionState.disconnected && !done.isCompleted) {
        done.complete('還沒讀到就斷線了（${u.failure?.message ?? '原因不明'}）');
      }
    }, onError: (Object e) {
      _log('conn id=${d.id} error $e');
      if (!done.isCompleted) done.complete('連線失敗：$e');
    });
    final r = await done.future.timeout(const Duration(seconds: 30), onTimeout: () => '30 秒內沒有回應');
    await conn.cancel(); // drops the link: the node advertises again
    _log('disconnected id=${d.id}');
    setState(() {
      _status[d.id] = r;
      _busy = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final list = _found.values.toList()..sort((a, b) => b.rssi.compareTo(a.rssi));
    return Scaffold(
      appBar: AppBar(title: const Text('附近的節點（開發用：藍牙測試）')),
      body: Column(children: [
        Padding(
          padding: const EdgeInsets.all(8),
          child: Row(children: [
            FilledButton(onPressed: _busy ? null : _start, child: const Text('搜尋')),
            const SizedBox(width: 8),
            OutlinedButton(onPressed: _scan == null ? null : _stop, child: const Text('停止')),
            const SizedBox(width: 8),
            Expanded(child: Text(_note)),
          ]),
        ),
        Expanded(
          child: ListView(children: [
            for (final d in list)
              ListTile(
                title: Text('${d.id}  訊號 ${d.rssi} dBm'),
                subtitle: Text(_status[d.id] ?? '點一下讀取狀態'),
                onTap: _busy ? null : () => _read(d),
              ),
          ]),
        ),
      ]),
    );
  }
}
