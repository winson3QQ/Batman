// #254 app S1 — claim one node over BLE (design v8.5.1 §5.1). Rust runs the protocol (ClaimSession, sans-IO); this
// file moves frames, asks Kotlin for the owner keys / sig_enc / record sealing, and writes records through the Rust
// store. The QR comes from the camera (every flavor, 254-app-qr) or is pasted as hex (dev flavor only, design §1: today
// the QR is `batman-provhelper qr`'s stdout); the clipboard is cleared after the paste. Nothing secret (K, records,
// credentials) is logged or shown. Before anything is sent or written, the record store is asked what this phone already
// holds for the QR's device id (§5.1: never claimed over without asking; records: claim_records.dart, design
// 254-app-claim-noover v2.1).
import 'dart:async';
import 'dart:collection';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_reactive_ble/flutter_reactive_ble.dart';

import 'claim_records.dart';
import 'say.dart';
import 'scan.dart' show provdService, provdStatus;
import 'src/rust/api/claim.dart';
import 'src/rust/api/simple.dart';

const _platform = MethodChannel('dev.batman/platform');
// feed/batman-prov/src/cmd/batman-provd/bluez.go:31-34
final _rx = Uuid.parse('540aa38c-0086-4d59-a9c0-c7c9d1e1bd42');
final _tx = Uuid.parse('540aa38c-0086-4d5a-a9c0-c7c9d1e1bd42');
final _ctrl = Uuid.parse('540aa38c-0086-4d5b-a9c0-c7c9d1e1bd42');

void _log(String s) => debugPrint('BMAPP claim $s');

/// R4 / R7 (254-app-claim-noover v2.1)
const otherQrText = '手機裡有這台節點一次沒完成的認領，用的是另一張 QR 碼。只有在你確定這張 QR 碼才是對的（例如之前貼錯）時才改用它：'
    '舊的認領紀錄會留在手機上，但 App 之後不會再用它。要改用這張 QR 碼嗎？';
String reclaimText({required bool pending}) => '這台節點已在你的清單裡。${pending ? '手機裡也有這台一次沒完成的認領。' : ''}'
    '只有在你剛把這台節點重置回未認領時才重新認領：舊紀錄會留在手機上，但 App 之後不會再用它、也不會顯示在清單裡。要重新認領嗎？';

class ClaimPage extends StatefulWidget {
  const ClaimPage({super.key, this.ble});

  /// tests: a fake BLE (null = the platform's)
  final FlutterReactiveBle? ble;

  @override
  State<ClaimPage> createState() => _ClaimPageState();
}

class _ClaimPageState extends State<ClaimPage> {
  late final _ble = widget.ble ?? FlutterReactiveBle(); // late: first used by a claim (the D1 test builds the page without BLE)
  final _lines = <String>[];
  ClaimQr? _qr;
  bool _busy = false;
  bool _scanning = false; // a QrScanActivity is open
  final _typed = TextEditingController(); // dev: the QR hex typed in (e.g. over adb), cleared once read

  /// [s] may start with log markers ("[CLAIMED] ", ...): logcat keeps them, the screen does not.
  void _say(String s) {
    _log(s);
    if (mounted) setState(() => _lines.add(screenText(s)));
  }

  Future<void> _paste() async {
    final dev = await _platform.invokeMethod<bool>('devTrust') ?? false;
    if (!dev) {
      _say('只有開發版可以貼上 QR 碼');
      return;
    }
    String text = _typed.text;
    _typed.clear(); // the claim secret does not stay in the field
    if (text.trim().isEmpty) {
      final d = await Clipboard.getData(Clipboard.kTextPlain);
      await Clipboard.setData(const ClipboardData(text: '')); // nor on the clipboard
      text = d?.text ?? '';
    }
    await _read(text);
  }

  /// 254-app-qr §2: the camera (every flavor). Null = left without a code: nothing changes.
  /// The button is off while a scan is open (code review r1 A-m4), so `busy` does not reach the user.
  Future<void> _scan() async {
    setState(() => _scanning = true);
    final String? text;
    try {
      text = await _platform.invokeMethod<String>('scanQr');
    } on PlatformException catch (e) {
      _say(e.code == 'camera' ? '無法使用相機：請確認已允許相機權限，且沒有其他 app 正在使用相機' : '現在無法掃描，請再試一次');
      return;
    } finally {
      if (mounted) setState(() => _scanning = false);
    }
    if (text != null && mounted) await _read(text);
  }

  /// The QR text (scanned or pasted) through the one Rust parser; shows the node number's last 4. A text that is not a
  /// claim QR also forgets the one read before (A-m5: no claim of the previous node after a wrong scan).
  Future<void> _read(String text) async {
    try {
      final q = await parseClaimQr(text: text);
      if (!mounted) return;
      setState(() {
        _qr = q;
        _lines
          ..clear()
          ..add('已讀取節點（編號末四碼 …${q.deviceId.substring(14)}）的 QR 碼，可以按「認領」');
      });
      _log('已讀取節點 …${q.deviceId.substring(14)} 的 QR 碼');
    } catch (e) {
      if (mounted) setState(() => _qr = null);
      _say('這不是認領用的 QR 碼：$e');
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
          _log('讀不到 $id 的狀態：$e');
        }
        _say('找到節點（$id）：${stateText(state)}，編號末四碼 …${last4 ?? '----'}');
        if (state == 'unclaimed' && last4 == want) return (id, conn);
        await conn.cancel(); // not ours: its advertising comes back
      }
      return null;
    } finally {
      await scan.cancel();
    }
  }

  /// 254-app-claim-noover (v2.1): what this phone already holds for the QR's device id, before anything is sent or
  /// written. False = no claim. Nothing held, or an unfinished claim of the same QR (the recovery's first step, §5.2-1,
  /// reusing K) -> go on; an unfinished claim of another QR, or a node record -> ask (R4 / R7); unreadable -> no (R5).
  /// Nothing on disk changes here: the records are decided again at PersistPending / CLAIMED (ClaimRecords).
  Future<bool> _held(ClaimQr q, ClaimStore store, String dir) async {
    const unreadable = '[CLAIM_FAIL] 讀不到手機裡這台節點的紀錄，這次不認領';
    final ClaimTarget t;
    try {
      t = await claimTarget(dir: dir, deviceId: q.deviceId);
    } catch (e) {
      _say('$unreadable：$e');
      return false;
    }
    switch (t) {
      case ClaimTarget.nothing:
        return true;
      case ClaimTarget.pending:
        final bool same;
        try {
          final s = await store.readSealed('claim-pending/${q.deviceId}');
          if (s == null) throw '認領紀錄不見了';
          same = await store.matches(await store.open(s), q);
        } catch (e) {
          _say('$unreadable：$e');
          return false;
        }
        if (same) {
          _say('手機裡有這台節點一次沒完成的認領，這次接著再試（沿用那次的認領紀錄）');
          return true;
        }
        return _ask('要改用這張 QR 碼嗎？', otherQrText, '改用這張 QR 碼', '沒有改用這張 QR 碼，手機裡的紀錄沒有改動');
      case ClaimTarget.node:
      case ClaimTarget.nodeAndPending:
        return _ask('節點 …${q.deviceId.substring(14)} 已經認領過', reclaimText(pending: t == ClaimTarget.nodeAndPending), '重新認領',
            '沒有重新認領，手機裡的紀錄沒有改動');
    }
  }

  Future<bool> _ask(String title, String text, String yes, String no) async {
    if (!mounted) return false;
    final ok = await showDialog<bool>(
        context: context,
        builder: (c) => AlertDialog(title: Text(title), content: Text(text), actions: [
              TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('取消')),
              TextButton(onPressed: () => Navigator.pop(c, true), child: Text(yes)),
            ]));
    if (ok != true) _say(no);
    return ok == true;
  }

  Future<void> _claim() async {
    final q = _qr;
    if (q == null || _busy) return;
    setState(() => _busy = true);
    StreamSubscription<ConnectionStateUpdate>? conn;
    StreamSubscription<List<int>>? notify;
    try {
      final dir = '${(await _platform.invokeMethod<String>('filesDir'))!}/records';
      final store = RustClaimStore(dir);
      if (!await _held(q, store, dir)) return;
      final records = ClaimRecords(store, q, _say);
      if (!(await _platform.invokeMethod<bool>('blePermissions') ?? false)) {
        _say('[CLAIM_FAIL] 沒有藍牙權限（請在手機設定裡允許）');
        return;
      }
      _say('正在找節點 …${q.deviceId.substring(14)}…');
      final found = await _find(q);
      if (found == null) {
        _say('[CLAIM_FAIL] [NOT_FOUND] 60 秒內找不到編號末四碼 …${q.deviceId.substring(14)} 的未認領節點（請確認節點已開機、就在旁邊）');
        return;
      }
      final id = found.$1;
      conn = found.$2;
      final mtu = await _ble.requestMtu(deviceId: id, mtu: 517); // before the TX notifications (design §2)
      final ctrl = await _ble.readCharacteristic(
          QualifiedCharacteristic(characteristicId: _ctrl, serviceId: provdService, deviceId: id));
      final fl = await frameLimit(ctrl: ctrl, mtu: mtu);
      _say('已連上節點（技術資訊：MTU $mtu，每段 $fl 位元組）');

      final keys = (await _platform.invokeMapMethod<String, dynamic>('publicKeys'))!;
      final owner = keys['owner'] as Uint8List, ownerEnc = keys['ownerEnc'] as Uint8List;
      final der = (await _platform.invokeMethod<Uint8List>('signOwner', {'input': await ownerEncSignInput(ownerEncPub: ownerEnc)}))!;
      final sigEnc = await derToRaw(der: der);

      final (session, first) = ClaimSession.start(qr: q, ownerPub: owner, ownerEncPub: ownerEnc, sigEnc: sigEnc, frameLimit: fl);
      final rx = QualifiedCharacteristic(characteristicId: _rx, serviceId: provdService, deviceId: id);
      final done = Completer<String>();
      var claimed = false; // set when the node record is written (StepKind.claimed)
      final inbox = StreamController<List<int>>();
      notify = _ble
          .subscribeToCharacteristic(QualifiedCharacteristic(characteristicId: _tx, serviceId: provdService, deviceId: id))
          .listen(inbox.add, onError: (Object e) => done.isCompleted ? null : done.complete('接收資料出錯：$e'));

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
              await records.persistPending(st.path, st.record); // R4: another K's pending is copied aside first
              _say('已先在手機記下這次認領（還沒完成）');
              st = session.pendingPersisted();
            case StepKind.claimed:
              await records.claimed(st.path, st.record, st.pendingPath); // R1: copy aside, node record, then the pending
              claimed = true;
              done.complete(st.detail);
              st = null;
            case StepKind.ended:
              done.complete(st.detail);
              st = null;
          }
        }
      }

      await run(first);
      _say('已送出認領要求，等待節點回應…');
      final pump = inbox.stream.asyncMap((f) => run(session.onFrame(frame: f))).listen((_) {},
          onError: (Object e) => done.isCompleted ? null : done.complete('處理出錯：$e'));
      final r = await done.future.timeout(const Duration(seconds: 90), onTimeout: () => '90 秒內節點沒有回應（這次的紀錄先保留，可以稍後再試）');
      await pump.cancel();
      await inbox.close();
      _say(claimed ? '[CLAIMED] $r' : '[CLAIM_FAIL] 認領沒有完成：$r');
      if (claimed && mounted) setState(() => _qr = null); // R6: claiming again needs a new scan
    } catch (e) {
      _say('[CLAIM_FAIL] 認領中斷：$e');
    } finally {
      await notify?.cancel();
      await conn?.cancel();
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('認領節點')),
      body: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          TextField(
              controller: _typed,
              obscureText: true,
              autocorrect: false,
              enableSuggestions: false,
              decoration: const InputDecoration(labelText: '開發用：QR 碼內容（16 進位）；留空就從剪貼簿讀取')),
          Wrap(spacing: 8, children: [ // three buttons do not fit one row on a narrow phone
            FilledButton.tonal(onPressed: (_busy || _scanning) ? null : _scan, child: const Text('掃描 QR')),
            OutlinedButton(onPressed: _busy ? null : _paste, child: const Text('貼上 QR 碼（開發用）')),
            FilledButton(onPressed: (_qr == null || _busy) ? null : _claim, child: const Text('認領')),
          ]),
          const SizedBox(height: 12),
          Expanded(child: ListView(children: [for (final l in _lines) Text(l, style: const TextStyle(fontFamily: 'monospace'))])),
        ]),
      ),
    );
  }
}
