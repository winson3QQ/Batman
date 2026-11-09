// #254 app S1 — BLE probe (design v8.5.1 §9 step 2): does Android list provd's advertising (UUID list only,
// non-discoverable, RPA, no name; bluez.go:226-229) with BLUETOOTH_SCAN neverForLocation, what MTU does the link get,
// and what does STATUS say. Scan + connect + one read only: no pairing (design §2), no write, no handshake.
// Every result goes to logcat as "BMAPP ble ..." so the probe can be read off the phone with adb.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_reactive_ble/flutter_reactive_ble.dart';

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
      setState(() => _note = 'Bluetooth permissions refused — nothing scanned');
      return;
    }
    await _scan?.cancel();
    setState(() {
      _found.clear();
      _note = 'scanning for the provd service…';
    });
    _scan = _ble.scanForDevices(withServices: [provdService], scanMode: ScanMode.lowLatency).listen((d) {
      if (!_found.containsKey(d.id)) _log('found id=${d.id} rssi=${d.rssi} name=[${d.name}] uuids=${d.serviceUuids}');
      setState(() => _found[d.id] = d);
    }, onError: (Object e) {
      _log('scan error $e');
      setState(() => _note = 'scan error: $e');
    });
  }

  Future<void> _stop() async {
    await _scan?.cancel();
    _scan = null;
    setState(() => _note = 'scan stopped (${_found.length} found)');
  }

  /// Connect, ask for MTU 517 (design §2), read STATUS once, disconnect. Connecting withdraws the node's
  /// advertising until the link drops (bluez.go:325,666-669).
  Future<void> _read(DiscoveredDevice d) async {
    if (_busy) return;
    await _stop();
    setState(() {
      _busy = true;
      _status[d.id] = 'connecting…';
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
            what = 'state=${s.state} trial=${s.trial} last4=${s.idLast4 ?? '-'} versions=${s.versions} transports=${s.transports}';
          } catch (e) {
            what = 'STATUS not understood: $e';
          }
          _log('read id=${d.id} mtu=$mtu status=$hex $what');
          done.complete('mtu $mtu\n$what');
        } catch (e) {
          // a stale cache on the node is an ATT error 0x0E (server.go:562-566): no value, not a guess
          _log('read id=${d.id} error $e');
          done.complete('read failed: $e');
        }
      } else if (u.connectionState == DeviceConnectionState.disconnected && !done.isCompleted) {
        done.complete('disconnected before the read (${u.failure?.message ?? 'no reason'})');
      }
    }, onError: (Object e) {
      _log('conn id=${d.id} error $e');
      if (!done.isCompleted) done.complete('connect error: $e');
    });
    final r = await done.future.timeout(const Duration(seconds: 30), onTimeout: () => 'no answer in 30 s');
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
      appBar: AppBar(title: const Text('Nodes nearby (BLE probe)')),
      body: Column(children: [
        Padding(
          padding: const EdgeInsets.all(8),
          child: Row(children: [
            FilledButton(onPressed: _busy ? null : _start, child: const Text('Scan')),
            const SizedBox(width: 8),
            OutlinedButton(onPressed: _scan == null ? null : _stop, child: const Text('Stop')),
            const SizedBox(width: 8),
            Expanded(child: Text(_note)),
          ]),
        ),
        Expanded(
          child: ListView(children: [
            for (final d in list)
              ListTile(
                title: Text('${d.id}  rssi ${d.rssi}'),
                subtitle: Text(_status[d.id] ?? 'tap to read STATUS'),
                onTap: _busy ? null : () => _read(d),
              ),
          ]),
        ),
      ]),
    );
  }
}
