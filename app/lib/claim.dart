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
import 'claim_recovery.dart';
import 'key_abilities.dart';
import 'say.dart';
import 'scan.dart' show provdService, provdStatus;
import 'src/nodelink/raw_use.dart';
import 'src/rust/api/claim.dart';
import 'src/rust/api/owner.dart' show listNodes, listPending;
import 'src/rust/api/simple.dart';
import 'ui/theme.dart';
import 'ui/widgets.dart';

const _platform = MethodChannel('dev.batman/platform');

/// The card of the lines the page has said (tests: 「no line said」 = no card).
const claimLinesKey = Key('claim-lines');

/// The folded 「開發用」 inputs (dev builds only; tests open it).
const claimDevFoldKey = Key('claim-dev-fold');

/// #329 PR 3 §2.7: what ClaimPage pops when a node was added (claimed, recovered, or claimed over): its device id.
class ClaimDone {
  const ClaimDone(this.id);
  final String id;
}

void _log(String s) => debugPrint('BMAPP claim ${logText(s)}'); // #329 PR 6 D7: the technical marks as 〔 〕

/// 254-app-replay v6.1 §19.2-7: how the T4 list and confirmation name each pending — the last 6 characters of the
/// device id, or the whole id where two ids share them.
Map<String, String> pendingLabels(List<String> ids) {
  String tail(String s) => s.length > 6 ? s.substring(s.length - 6) : s;
  final count = <String, int>{};
  for (final id in ids) {
    count[tail(id)] = (count[tail(id)] ?? 0) + 1;
  }
  return {for (final id in ids) id: count[tail(id)]! > 1 ? id : '…${tail(id)}'};
}

/// R4 / R7 (254-app-claim-noover v2.1)
const otherQrText = '手機裡有這台節點一次沒完成的認領，用的是另一張 QR 碼。只有在你確定這張 QR 碼才是對的（例如之前貼錯）時才改用它：'
    '舊的認領紀錄會留在手機上，但 App 之後不會再用它。要改用這張 QR 碼嗎？';
String reclaimText({required bool pending}) => '這台節點已在你的清單裡。${pending ? '手機裡也有這台一次沒完成的認領。' : ''}'
    '只有在你剛把這台節點重置回未認領時才重新認領：舊紀錄會留在手機上，但 App 之後不會再用它、也不會顯示在清單裡。要重新認領嗎？';

/// Design §4.1: shown before a claim on a dev build whose owner_enc key is SOFTWARE; the claim goes on only when confirmed.
const devSoftEncTitle = '這支手機只能用於開發';
const devSoftEncText = '這支手機的復原／隊員金鑰是軟體保護，只能用於開發，不可用於實際部署。\n\n'
    '之後換手機、或改用 field 版／硬體 owner_enc，這支手機認領的每個節點都要重燒卡回收。';

class ClaimPage extends StatefulWidget {
  const ClaimPage({super.key, this.ble, this.findFor = const Duration(seconds: 60), this.recoveryBle, this.use, this.goneNote});

  /// #329 PR 3 §2.7 (F41): a line said after the page was closed (a claim keeps running after 返回); the home page
  /// shows the last one once.
  final void Function(String line)? goneNote;

  /// #329 §4.4: the raw lease this page runs under (null in tests of the page alone)
  final RawUse? use;

  /// tests: a fake BLE (null = the platform's)
  final FlutterReactiveBle? ble;
  /// how long a claim looks for the unclaimed node (tests shorten it)
  final Duration findFor;
  /// tests: the recovery's BLE (null = [ble] through ReactiveRecoveryBle)
  final RecoveryBle? recoveryBle;

  @override
  State<ClaimPage> createState() => _ClaimPageState();
}

class _ClaimPageState extends State<ClaimPage> with RawBusy<ClaimPage> {
  @override
  RawUse? get rawUse => widget.use;
  late final _ble = widget.ble ?? FlutterReactiveBle(); // late: first used by a claim (the D1 test builds the page without BLE)
  final _lines = <String>[];
  ClaimQr? _qr;
  bool get _busy => rawBusy; // #329 §4.4: busy = the raw lease is held (it outlives a pop until the work ends)
  set _busy(bool v) => rawBusy = v;
  int _claimedNear = 0; // claimed / member nodes seen by the last search (their id tail is not public)
  bool _heldNode = false; // this phone holds a node record for the QR's device id (R7), set by _held
  bool _heldPending = false; // ... and a pending (254-app-replay T2), set by _held
  bool _scanning = false; // a QrScanActivity is open
  final _typed = TextEditingController(); // dev: the QR hex typed in (e.g. over adb), cleared once read
  ClaimRecovery? _recovery; // 254-app-replay: the recovery of this press, while it runs
  List<String> _pending = const []; // 254-app-replay T4: claim-pending/ file names (dev builds only)
  bool _dev = false; // a dev build (devTrust): the typed / pasted QR

  /// #329 PR 3 §2.7: the node was added -> back to the caller with it (3.2 取名 next). A page that is the first route
  /// (the page alone in a test) stays and shows its lines.
  void _done(String id) {
    if (!mounted) return;
    final nav = Navigator.of(context);
    if (nav.canPop()) nav.pop(ClaimDone(id));
  }

  @override
  void initState() {
    super.initState();
    _loadPending();
  }

  /// 254-app-replay §3-7: leaving the page stops a recovery (a claim/finish in flight is not interrupted; its T1 then
  /// does not start, §2)
  @override
  void dispose() {
    _recovery?.cancel();
    super.dispose();
  }

  /// 254-app-replay v6 §19.2-1: a dev build lists claim-pending/ (file names only, nothing opened) for the T4 entry;
  /// a field build, or a list that cannot be read, has no entry.
  Future<void> _loadPending() async {
    var ids = const <String>[];
    try {
      final dev = await _platform.invokeMethod<bool>('devTrust') ?? false;
      if (mounted && dev != _dev) setState(() => _dev = dev); // design §5.3: the dev inputs only in a dev build
      if (dev) {
        ids = await listPending(dir: '${(await _platform.invokeMethod<String>('filesDir'))!}/records');
      }
    } catch (e) {
      _log('認領暫存的清單讀不到：$e');
    }
    if (mounted) setState(() => _pending = ids);
  }

  /// 254-app-replay T4 (v6 §19.2, v6.1): choose a claim-pending, confirm, recover it with its own K (no QR). Holds
  /// `_busy` for the whole run; asks for the BLE permissions before any connection.
  Future<void> _fromPending() async {
    if (_busy || _pending.isEmpty) return;
    setState(() => _busy = true);
    try {
      final labels = pendingLabels(_pending);
      final id = await showDialog<String>(
          context: context,
          builder: (c) => SimpleDialog(title: const Text('從認領暫存恢復'), children: [
                for (final p in _pending)
                  SimpleDialogOption(onPressed: () => Navigator.pop(c, p), child: Text('節點 ${labels[p]}')),
              ]));
      if (id == null || !mounted) return;
      final label = labels[id]!;
      if (!await _ask('要恢復節點 $label 嗎？', '恢復會更換這台節點的 root 密碼，並中斷它目前所有的連線（包含隊友手機的）。', '恢復',
          '沒有恢復，手機裡的紀錄沒有改動')) {
        return;
      }
      if (!(await _platform.invokeMethod<bool>('blePermissions') ?? false)) {
        _say('[CLAIM_FAIL] 沒有藍牙權限（請在手機設定裡允許）');
        return;
      }
      final dir = '${(await _platform.invokeMethod<String>('filesDir'))!}/records';
      final store = RustClaimStore(dir);
      final t3 = (await listNodes(dir: dir)).contains(id); // a node record too -> T3 asks again (§19.2-4)
      if (!mounted) {
        // T4 review A-m1: the page left during the checks above -> no recovery without its stop button; pending kept
        _log('頁面已離開：這次不恢復（認領暫存保留）');
        return;
      }
      await _recover(id, null, store, ClaimRecords(store, null, _say), t3: t3, intro: '[RECOVERING] 從認領暫存恢復節點 $label');
    } catch (e) {
      final k = _keyRefused(e);
      _say(k != null ? '[CLAIM_FAIL] $k' : '[CLAIM_FAIL] 恢復中斷：${sayErr(e)}');
    } finally {
      rawIdle();
      await _loadPending();
    }
  }

  /// [s] may start with log markers ("[CLAIMED] ", ...): logcat keeps them, the screen does not.
  void _say(String s) {
    _log(s);
    if (mounted) {
      setState(() => _lines.add(s)); // the whole line: SayLine shows its main part and its technical part
    } else {
      widget.goneNote?.call(s); // F41: the page was closed while the claim ran (J MINOR-9: the whole line, split where shown)
    }
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
          ..add('已讀取節點（編號後四碼 …${q.deviceId.substring(14)}）的 QR 碼，可以按「認領」');
      });
      _log('已讀取節點 …${q.deviceId.substring(14)} 的 QR 碼');
    } catch (e) {
      if (mounted) setState(() => _qr = null);
      _say('這不是認領用的 QR 碼：${sayErr(e)}');
    }
  }

  /// Scan for the provd service; the node is the one whose STATUS says unclaimed with the QR's last 4 (design §5.1-1).
  /// The connection stays open for the claim.
  Future<(String, StreamSubscription<ConnectionStateUpdate>)?> _find(ClaimQr q) async {
    final want = q.deviceId.substring(14);
    final tried = <String>{};
    final queue = Queue<String>();
    rawScanStarted();
    final scan = _ble.scanForDevices(withServices: [provdService], scanMode: ScanMode.lowLatency).listen((d) {
      if (tried.add(d.id)) queue.add(d.id);
    });
    _claimedNear = 0;
    final end = DateTime.now().add(widget.findFor);
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
        _log('found $id');
        // #329 design §3.4 S10 (PR 7 T10): the BLE address under the line's 技術資訊, never in its main words
        _say('找到節點，後四碼 ${(last4 ?? '----').toUpperCase()}：${stateText(state)}${tech('BLE 位址 $id')}');
        if (state == 'unclaimed' && last4 == want) return (id, conn);
        if (state == 'claimed' || state == 'member') _claimedNear++; // its id tail is not public: it may be this QR's node
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
      _heldNode = t == ClaimTarget.node || t == ClaimTarget.nodeAndPending;
      _heldPending = t == ClaimTarget.pending || t == ClaimTarget.nodeAndPending;
    } catch (e) {
      _say('$unreadable：${sayErr(e)}');
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
          _say('$unreadable：${sayErr(e)}');
          return false;
        }
        if (same) {
          _say('手機裡有這台節點一次沒完成的認領，這次接著再試（沿用那次的認領紀錄）');
          return true;
        }
        return _ask('要改用這張 QR 碼嗎？', otherQrText, '改用這張 QR 碼', '沒有改用這張 QR 碼，手機裡的紀錄沒有改動');
      case ClaimTarget.node:
      case ClaimTarget.nodeAndPending:
        return _ask('節點 …${q.deviceId.substring(14).toUpperCase()} 已經認領過', reclaimText(pending: t == ClaimTarget.nodeAndPending), '重新認領',
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

  /// Kotlin's own key gate refused (MainActivity.gate): the same [KEY_LEVEL] line as the gate above.
  String? _keyRefused(Object e) {
    final k = KeyAbilities.refusedBy(e);
    return k == null ? null : '[KEY_LEVEL] $k';
  }

  Future<void> _claim() async {
    final q = _qr;
    if (q == null || _busy) return;
    setState(() => _busy = true);
    StreamSubscription<ConnectionStateUpdate>? conn;
    StreamSubscription<List<int>>? notify;
    try {
      // design §4.1: the key levels are read live before every claim / recovery (a claim may turn out to be the
      // recovery of an unfinished one, so both must be allowed)
      final able = await KeyAbilities.read(_platform);
      final no = able.refusal(KeyUse.claim) ?? able.refusal(KeyUse.recover);
      if (no != null) {
        _say('[CLAIM_FAIL] [KEY_LEVEL] $no。手機裡的紀錄沒有改動。');
        return;
      }
      // design §4.1 (dev build + SOFTWARE owner_enc): said and confirmed before anything is read or sent
      if (able.softOwnerEnc && !await _ask(devSoftEncTitle, devSoftEncText, '我了解，繼續認領', '[CLAIM_FAIL] 沒有確認，沒有認領。手機裡的紀錄沒有改動。')) {
        return;
      }
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
      if (found == null && _heldPending && mounted) {
        // 254-app-replay §2 T2: an unfinished claim of this QR (K compared again by the recovery) and no unclaimed node
        // -> recover it; T3 (a node record too) asks first. Not started (another K, keys, field build, T3 declined)
        // -> the NOT_FOUND words below, as before.
        final out = await _recover(q.deviceId, q, store, records,
            t3: _heldNode, intro: '[RECOVERING] 沒找到未認領的這台，改試恢復先前的認領');
        if (out != RecoveryOutcome.notStarted) return;
      }
      if (found == null) {
        // design note §4-§5 (R7-2, 2026-11-13): the power / range hint always stays (a team's claimed nodes are often
        // around while the wanted one is off); a claimed node publishes no id tail, so a claimed node nearby is only a
        // possibility, never a count or a "this one" — and never a reset (there is none in this stage: a re-flash makes a
        // new identity and this QR stops working)
        final tail = q.deviceId.substring(14);
        final near = _claimedNear == 0
            ? ''
            : _heldNode
                ? '附近有已認領的節點（不公開編號），可能就是這台：如果它還在你的「我的節點」裡，不用重新認領，直接從那裡使用；重燒過卡的話，要掃它新的 QR 碼。'
                : '附近有已認領的節點（不公開編號）；已經被認領的節點不能再認領。';
        _say('[CLAIM_FAIL] [NOT_FOUND] ${(widget.findFor.inMilliseconds / 1000).ceil()} 秒內沒找到編號後四碼 …$tail 的未認領節點'
            '（請確認節點已開機、就在旁邊）。$near手機裡的紀錄沒有改動。');
        return;
      }
      final id = found.$1;
      conn = found.$2;
      final mtu = await _ble.requestMtu(deviceId: id, mtu: 517); // before the TX notifications (design §2)
      final ctrl = await _ble.readCharacteristic(
          QualifiedCharacteristic(characteristicId: provdCtrl, serviceId: provdService, deviceId: id));
      final fl = await frameLimit(ctrl: ctrl, mtu: mtu);
      _say('已連上節點${tech('MTU $mtu，每段 $fl 位元組')}');

      final keys = (await _platform.invokeMapMethod<String, dynamic>('publicKeys'))!;
      final owner = keys['owner'] as Uint8List, ownerEnc = keys['ownerEnc'] as Uint8List;
      final der = (await _platform.invokeMethod<Uint8List>('signOwner', {'input': await ownerEncSignInput(ownerEncPub: ownerEnc)}))!;
      final sigEnc = await derToRaw(der: der);

      final (session, first) = ClaimSession.start(
          qr: q, ownerPub: owner, ownerEncPub: ownerEnc, sigEnc: sigEnc, frameLimit: fl, devSoftEnc: able.softOwnerEnc);
      final rx = QualifiedCharacteristic(characteristicId: provdRx, serviceId: provdService, deviceId: id);
      final done = Completer<String>();
      var claimed = false; // set when the node record is written (StepKind.claimed)
      PendingNotRemoved? pendingKept; // ... and its pending could not be removed (harmless: the node record counts)
      final inbox = StreamController<List<int>>();
      notify = _ble
          .subscribeToCharacteristic(QualifiedCharacteristic(characteristicId: provdTx, serviceId: provdService, deviceId: id))
          .listen(inbox.add, onError: (Object e) => done.isCompleted ? null : done.complete('接收資料出錯${tech(e)}'));

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
              try {
                await records.claimed(st.path, st.record, st.pendingPath); // R1: copy aside, node record, then the pending
              } on PendingNotRemoved catch (e) {
                pendingKept = e; // 254-app-replay review r2 A-B: the node record IS written -> still CLAIMED
              }
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
          onError: (Object e) => done.isCompleted ? null : done.complete(_keyRefused(e) ?? '處理出錯${tech(e)}'));
      final r = await done.future.timeout(const Duration(seconds: 90), onTimeout: () => '90 秒內節點沒有回應（這次的紀錄先保留，可以稍後再試）');
      await pump.cancel();
      await inbox.close();
      _say(claimed
          ? '[CLAIMED] $r'
          : r.startsWith('[KEY_LEVEL] ')
              ? '[CLAIM_FAIL] $r'
              : '[CLAIM_FAIL] 認領沒有完成：$r');
      if (claimed && pendingKept != null) _say('[PENDING_KEPT] $pendingKept');
      if (claimed && mounted) setState(() => _qr = null); // R6: claiming again needs a new scan
      if (claimed) _done(q.deviceId);
      // 254-app-replay §2 T1: the finish went out and its end is unknown / 9 / 13 / OK without credentials -> replay
      // this very device. replay_due() failing = false (§7: no replay; the next 「認領」 finds it claimed -> T2).
      if (!claimed) {
        bool due, after9;
        try {
          due = session.replayDue();
          after9 = due && session.finishedWith9();
        } catch (e) {
          _log('replay_due 出錯：$e');
          due = after9 = false;
        }
        if (due) {
          await notify.cancel(); // disconnect first (§2 T1)
          await conn.cancel();
          if (!mounted) {
            // §2: the page is gone at the decision point -> no recovery now; the pending stays (next 「認領」 -> T2)
            _log('頁面已離開：這次不恢復（認領紀錄保留，下次按「認領」會接著恢復）');
            return;
          }
          await _recover(q.deviceId, q, store, records, t1Id: id, after9: after9, intro: '[RECOVERING] 改試恢復這次的認領（先等節點收尾 15 秒）');
        }
      }
    } catch (e) {
      final k = _keyRefused(e);
      _say(k != null ? '[CLAIM_FAIL] $k' : '[CLAIM_FAIL] 認領中斷：${sayErr(e)}');
    } finally {
      await notify?.cancel();
      await conn?.cancel();
      rawIdle();
      await _loadPending(); // a claim may have written or removed a pending (the T4 entry)
    }
  }

  /// 254-app-replay §3: one recovery for this press; 「認領」 becomes 「停止恢復」 while it runs. The records it writes do
  /// not need the page (§3-7).
  Future<RecoveryOutcome> _recover(String deviceId, ClaimQr? q, ClaimStore store, ClaimRecords records,
      {String? t1Id, bool after9 = false, bool t3 = false, required String intro}) async {
    final rec = ClaimRecovery(
        ble: widget.recoveryBle ?? ReactiveRecoveryBle(_ble, onScan: rawScanStarted), platform: _platform, store: store, records: records, deviceId: deviceId, qr: q, say: _say);
    if (mounted) setState(() => _recovery = rec);
    try {
      final out = await rec.run(
          t1Id: t1Id,
          after9: after9,
          t3: t3,
          // v6.1 §19.2-6: T4 (no QR) asks without "沒找到未認領的這台"
          askT3: () => _ask('要恢復這台節點嗎？', q == null ? t3Body : t3Text, '恢復', '沒有恢復，手機裡的紀錄沒有改動'),
          intro: intro);
      if (out == RecoveryOutcome.recovered && q != null && mounted) setState(() => _qr = null); // R6: a new scan for another claim
      if (out == RecoveryOutcome.recovered) _done(deviceId);
      return out;
    } finally {
      _recovery = null;
      if (mounted) setState(() {});
    }
  }

  /// #329 PR 3 §2.7 (D1): the new screens' look; the claim, its search and its recovery are unchanged.
  @override
  Widget build(BuildContext context) {
    final t = BatTheme.of(context);
    return BatPage(
      title: Btn.addNode,
      body: [
        // design §5.3 / §3.3: one explanation of 認領, one main action
        Text('掃描節點機身上的 QR code，把它加入這支手機（這一步叫「認領」）。之後這台節點只聽這支手機的設定。',
            style: TextStyle(fontSize: Fs.body, height: 1.6, color: t.ink)),
        // #329 PR 6 P2-2 / P2-3b: one primary button at a time — no code: 「掃描 QR」; a code read: 「認領」 (掃描 QR
        // secondary); a recovery running: 「停止恢復」 (primary, not danger; scanning off)
        if (_recovery != null) ...[
          BatButton(Btn.stopRecovery, onPressed: () => _recovery?.cancel()), // 254-app-replay §3-6
          const BatButton(Btn.scanQr, kind: BtnKind.secondary, onPressed: null),
        ] else if (_qr != null) ...[
          BatButton(Btn.claim, onPressed: _busy ? null : _claim),
          BatButton(Btn.scanQr, kind: BtnKind.secondary, onPressed: (_busy || _scanning) ? null : _scan),
        ] else
          BatButton(Btn.scanQr, onPressed: (_busy || _scanning) ? null : _scan),
        if (_pending.isNotEmpty) // 254-app-replay T4 (§19.2-1): dev builds with a claim-pending only
          BatButton(Btn.fromPending, kind: BtnKind.secondary, onPressed: (_busy || _scanning) ? null : _fromPending),
        if (_lines.isNotEmpty)
          BatCard(key: claimLinesKey, children: [
            for (final l in _lines)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                child: SayLine(l, style: TextStyle(fontSize: Fs.body, height: 1.5, color: t.ink)),
              ),
          ]),
        if (_dev) // design §5.3: the dev inputs only in a dev build — at the bottom, folded
          ExpansionTile(
            key: claimDevFoldKey,
            title: Text('開發用', style: TextStyle(fontSize: Fs.body, color: t.ink)),
            tilePadding: EdgeInsets.zero,
            childrenPadding: const EdgeInsets.only(bottom: 8),
            children: [
              TextField(
                  controller: _typed,
                  obscureText: true,
                  autocorrect: false,
                  enableSuggestions: false,
                  decoration: const InputDecoration(labelText: 'QR 內容（16 進位）', helperText: '留空就從剪貼簿讀取')),
              const SizedBox(height: 8),
              BatButton(Btn.pasteQr, kind: BtnKind.secondary, onPressed: _busy ? null : _paste),
            ],
          ),
      ],
    );
  }
}
