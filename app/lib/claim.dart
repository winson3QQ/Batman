// #254 app S1 — claim one node over BLE (design v8.5.1 §5.1). Rust runs the protocol (ClaimSession, sans-IO); this
// file moves frames, asks Kotlin for the owner keys / sig_enc / record sealing, and writes records through the Rust
// store. The QR is pasted as hex (dev flavor only, design §1: today the QR is `batman-provhelper qr`'s stdout); the
// clipboard is cleared after the paste. Nothing secret (K, records, credentials) is logged or shown.
import 'dart:async';
import 'dart:collection';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_reactive_ble/flutter_reactive_ble.dart';

import 'scan.dart' show provdService, provdStatus;
import 'src/rust/api/claim.dart';
import 'src/rust/api/simple.dart';

const _platform = MethodChannel('dev.batman/platform');
// feed/batman-prov/src/cmd/batman-provd/bluez.go:31-34
final _rx = Uuid.parse('540aa38c-0086-4d59-a9c0-c7c9d1e1bd42');
final _tx = Uuid.parse('540aa38c-0086-4d5a-a9c0-c7c9d1e1bd42');
final _ctrl = Uuid.parse('540aa38c-0086-4d5b-a9c0-c7c9d1e1bd42');

void _log(String s) => debugPrint('BMAPP claim $s');

class ClaimPage extends StatefulWidget {
  const ClaimPage({super.key});

  @override
  State<ClaimPage> createState() => _ClaimPageState();
}

class _ClaimPageState extends State<ClaimPage> {
  final _ble = FlutterReactiveBle();
  final _lines = <String>[];
  ClaimQr? _qr;
  bool _busy = false;

  void _say(String s) {
    _log(s);
    if (mounted) setState(() => _lines.add(s));
  }

  Future<void> _paste() async {
    final dev = await _platform.invokeMethod<bool>('devTrust') ?? false;
    if (!dev) {
      _say('pasting a QR is only in the dev build (design §1)');
      return;
    }
    final d = await Clipboard.getData(Clipboard.kTextPlain);
    await Clipboard.setData(const ClipboardData(text: '')); // the claim secret does not stay on the clipboard
    try {
      final q = await parseClaimQr(text: d?.text ?? '');
      setState(() {
        _qr = q;
        _lines
          ..clear()
          ..add('QR for node …${q.deviceId.substring(14)}');
      });
      _log('QR parsed for …${q.deviceId.substring(14)}');
    } catch (e) {
      _say('not a claim QR: $e');
    }
  }

  /// Scan for the provd service; the node is the one whose STATUS says unclaimed with the QR's last 4 (design §5.1-1).
  /// The connection stays open for the claim.
  Future<(String, StreamSubscription<ConnectionStateUpdate>)?> _find(ClaimQr q) async {
    final want = q.deviceId.substring(14);
    final tried = <String>{};
    final queue = Queue<String>();
    final scan = _ble.scanForDevices(withServices: [provdService], scanMode: ScanMode.lowLatency).listen((d) {
      if (tried.add(d.id)) queue.add(d.id);
    });
    final end = DateTime.now().add(const Duration(seconds: 60));
    try {
      while (DateTime.now().isBefore(end)) {
        if (queue.isEmpty) {
          await Future<void>.delayed(const Duration(milliseconds: 300));
          continue;
        }
        final id = queue.removeFirst();
        final connected = Completer<bool>();
        final conn = _ble.connectToDevice(id: id, connectionTimeout: const Duration(seconds: 15)).listen((u) {
          if (connected.isCompleted) return;
          if (u.connectionState == DeviceConnectionState.connected) connected.complete(true);
          if (u.connectionState == DeviceConnectionState.disconnected) connected.complete(false);
        }, onError: (Object _) {
          if (!connected.isCompleted) connected.complete(false);
        });
        if (!await connected.future.timeout(const Duration(seconds: 20), onTimeout: () => false)) {
          await conn.cancel();
          continue;
        }
        String? last4;
        String state = '?';
        try {
          final raw = await _ble.readCharacteristic(
              QualifiedCharacteristic(characteristicId: provdStatus, serviceId: provdService, deviceId: id));
          final s = decodeStatus(bytes: raw);
          last4 = s.idLast4;
          state = s.state;
        } catch (e) {
          _log('STATUS of $id not read: $e');
        }
        _say('node $id: $state …${last4 ?? '----'}');
        if (state == 'unclaimed' && last4 == want) return (id, conn);
        await conn.cancel(); // not ours: its advertising comes back
      }
      return null;
    } finally {
      await scan.cancel();
    }
  }

  Future<void> _claim() async {
    final q = _qr;
    if (q == null || _busy) return;
    setState(() => _busy = true);
    StreamSubscription<ConnectionStateUpdate>? conn;
    StreamSubscription<List<int>>? notify;
    try {
      if (!(await _platform.invokeMethod<bool>('blePermissions') ?? false)) {
        _say('Bluetooth permissions refused');
        return;
      }
      final found = await _find(q);
      if (found == null) {
        _say('no unclaimed node with …${q.deviceId.substring(14)} in 60 s');
        return;
      }
      final id = found.$1;
      conn = found.$2;
      final mtu = await _ble.requestMtu(deviceId: id, mtu: 517); // before the TX notifications (design §2)
      final ctrl = await _ble.readCharacteristic(
          QualifiedCharacteristic(characteristicId: _ctrl, serviceId: provdService, deviceId: id));
      final fl = await frameLimit(ctrl: ctrl, mtu: mtu);
      _say('link: MTU $mtu, frames $fl B');

      final keys = (await _platform.invokeMapMethod<String, dynamic>('publicKeys'))!;
      final owner = keys['owner'] as Uint8List, ownerEnc = keys['ownerEnc'] as Uint8List;
      final der = (await _platform.invokeMethod<Uint8List>('signOwner', {'input': await ownerEncSignInput(ownerEncPub: ownerEnc)}))!;
      final sigEnc = await derToRaw(der: der);
      final dir = '${(await _platform.invokeMethod<String>('filesDir'))!}/records';

      final (session, first) = ClaimSession.start(qr: q, ownerPub: owner, ownerEncPub: ownerEnc, sigEnc: sigEnc, frameLimit: fl);
      final rx = QualifiedCharacteristic(characteristicId: _rx, serviceId: provdService, deviceId: id);
      final done = Completer<String>();
      final inbox = StreamController<List<int>>();
      notify = _ble
          .subscribeToCharacteristic(QualifiedCharacteristic(characteristicId: _tx, serviceId: provdService, deviceId: id))
          .listen(inbox.add, onError: (Object e) => done.isCompleted ? null : done.complete('TX error: $e'));

      Future<void> seal(String path, Uint8List record) async {
        final p = await storeSealParams(dir: dir, rel: path);
        final sealed = (await _platform.invokeMethod<Uint8List>('seal', {'plain': record, 'aad': p.aad}))!;
        await storeWriteSealed(dir: dir, rel: path, generation: p.generation, sealed: sealed);
      }

      // one step at a time: a step's writes / record finish before the next frame is fed in
      Future<void> run(ClaimStep? st) async {
        while (st != null && !done.isCompleted) {
          switch (st.kind) {
            case StepKind.write:
              for (final f in st.frames) {
                await _ble.writeCharacteristicWithoutResponse(rx, value: f);
              }
              st = null;
            case StepKind.persistPending:
              await seal(st.path, st.record);
              _say('claim-pending written');
              st = session.pendingPersisted();
            case StepKind.claimed:
              await seal(st.path, st.record); // the node record first,
              await storeRemove(dir: dir, rel: st.pendingPath); // then the pending (design §5.1)
              done.complete(st.detail);
              st = null;
            case StepKind.ended:
              done.complete(st.detail);
              st = null;
          }
        }
      }

      await run(first);
      _say('msg1 sent');
      final pump = inbox.stream.asyncMap((f) => run(session.onFrame(frame: f))).listen((_) {},
          onError: (Object e) => done.isCompleted ? null : done.complete('error: $e'));
      final r = await done.future.timeout(const Duration(seconds: 90), onTimeout: () => 'no answer in 90 s (the pending stays: design §5.2)');
      await pump.cancel();
      await inbox.close();
      _say('result: $r');
    } catch (e) {
      _say('claim stopped: $e');
    } finally {
      await notify?.cancel();
      await conn?.cancel();
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Claim a node (dev)')),
      body: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(children: [
            OutlinedButton(onPressed: _busy ? null : _paste, child: const Text('Paste QR')),
            const SizedBox(width: 8),
            FilledButton(onPressed: (_qr == null || _busy) ? null : _claim, child: const Text('Claim')),
          ]),
          const SizedBox(height: 12),
          Expanded(child: ListView(children: [for (final l in _lines) Text(l, style: const TextStyle(fontFamily: 'monospace'))])),
        ]),
      ),
    );
  }
}
