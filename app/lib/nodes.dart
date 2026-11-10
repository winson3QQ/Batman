// #254 app S1 — this phone's nodes (design v8.5.1 §5.3 login, §5.5 status; 254-p3-impl §3.3 settings/get).
// The node record is opened by Kotlin (Keystore record key, AAD from Rust) and handed to Rust, which keeps its secrets;
// a claimed node's advertising carries no id (RPA, UUID list only), so each nearby provd is tried in turn: msg2 that
// does not decrypt = not this node (design §5.0), try the next. Nothing secret is logged.
// Join a second node (254-app-join2 v7.1): a net record opened by Kotlin goes to Rust as is; every net record write
// is sealed by Kotlin and written by compare-and-swap (storeWriteCas) — the record bytes are never logged or shown.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_reactive_ble/flutter_reactive_ble.dart';

import 'member_ui.dart';
import 'say.dart';
import 'scan.dart' show provdService;
import 'src/rust/api/claim.dart' show frameLimit, storeRemove;
import 'src/rust/api/member.dart';
import 'src/rust/api/owner.dart';

const _platform = MethodChannel('dev.batman/platform');
final _rx = Uuid.parse('540aa38c-0086-4d59-a9c0-c7c9d1e1bd42');
final _tx = Uuid.parse('540aa38c-0086-4d5a-a9c0-c7c9d1e1bd42');
final _ctrl = Uuid.parse('540aa38c-0086-4d5b-a9c0-c7c9d1e1bd42');

void _log(String s) => debugPrint('BMAPP owner $s');

/// An opened net record (join2): its path, plain bytes (secrets inside: never logged), the generation it was read at
/// and what the screen may show of it.
class _Net {
  const _Net(this.rel, this.plain, this.gen, this.view);
  final String rel;
  final Uint8List plain;
  final BigInt gen;
  final NetView view;
}

/// join2 §3.3-7: "connected" is looked for during 2 x the measured join -> connected time (T5); 120 s until measured
const _linkWindow = Duration(seconds: 120);
const _linkEvery = Duration(seconds: 10);

/// A join waits longer than provd's helper wait (HelperWait 330 s, S/provd/server.go:22) per node request; the
/// country question to the user does not count.
const _joinWait = Duration(seconds: 360);
const _joinUnclear = '[JOIN_STATE] 結果不明，稍後在這台按「繼續加入」';
const _makeUnclear = '[NET_STATE] 結果不明，稍後在這台按「確認網路」';
/// a join / make-network that lost the link before any record write: nothing was written or sent
const _notSent = '[REQ_FAIL] 連線失敗，還沒有寫入或送出，請重試';
const _linkUnknown = '[JOINED] 已套用，連線狀態未知';

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
  // the outstanding request's wait: restarted on every write to the node, stopped while the user is asked
  Timer? _wait;
  Duration _waitFor = const Duration(seconds: 15);
  String _waitLine = '';
  // a join / make-network in flight: its "outcome unknown" line (null otherwise); whether a record write happened yet
  String? _unclear;
  bool _wrote = false;
  bool _quiet = false; // the last request was a quiet one (a late answer of it is only logged)
  final _country = TextEditingController(); // settings/set key 2 (two capital letters)
  final _apSsid = TextEditingController(); // settings/set key 20
  final _apPass = TextEditingController(); // obscured; cleared once sent
  final _netName = TextEditingController(text: 'Batman'); // make-network (design §5.4)
  int _channel = 40; // US ch 40 (4 MHz, the default) or 42 (2 MHz)
  // the step loop of the open session (set at login): a request whose first step is not a write runs through it
  Future<void> Function(OwnerStep?)? _run;
  final _sshKey = TextEditingController(); // dev: an ssh-ed25519 public key line to add (ssh_keys/set, P2 owner-op)
  // remote invites (254-app-member-join; dev / dev2 only): the pasted invite (public), the node name for a request,
  // and the code / SAS of the last answer that carried one
  String? _inviteHex;
  InviteView? _invite;
  final _memberName = TextEditingController();
  String _lastHex = '', _lastSas = '';
  bool _lastRenewed = false;
  DateTime? _linkFrom; // set when a join was applied: the link checks that follow count from here

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

  /// [rxc]: the RX characteristic of the login attempt that owns the frames (never another candidate's)
  Future<void> _write(QualifiedCharacteristic rxc, List<Uint8List> frames) async {
    for (final f in frames) {
      await _ble.writeCharacteristicWithoutResponse(rxc, value: f);
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
    final rx = _rxc!; // this attempt's device: its run writes only here
    // after login, a run belongs to session s only: once the session was dropped or replaced it stops
    bool gone() => done.isCompleted && !identical(_session, s);
    Future<void> run(OwnerStep? st) async {
      while (st != null) {
        if (gone()) {
          _log('裝置 $id：連線已換掉，舊的步驟不再執行');
          return;
        }
        switch (st.kind) {
          case OwnerKind.write:
            await _write(rx, st.frames);
            if (gone()) return;
            _kick();
            st = null;
          case OwnerKind.sign:
            final der = (await _platform.invokeMethod<Uint8List>('signOwner', {'input': st.signInput}))!;
            st = s.signed(der: der);
          case OwnerKind.signAdmin:
            Uint8List der;
            try {
              der = (await _platform.invokeMethod<Uint8List>('signAdmin', {'input': st.signInput}))!;
            } on PlatformException catch (e) {
              // the admin key could not sign (lost / invalidated): an empty signature stops the flow before any
              // record write or country change (join2 §6, T8)
              _log('[REQ_FAIL] 手機的管理者金鑰無法簽章（${e.code}）');
              der = Uint8List(0);
            }
            st = s.signed(der: der);
          case OwnerKind.persistNet || OwnerKind.persistPend || OwnerKind.persistMnet:
            // the net / mpend / mnet record lands (sealed, fsynced) before anything goes out (design §3), by compare-and-swap from
            // the generation it was read at (join2 §3.1); never shown
            final OwnerStep p = st;
            _wrote = true;
            try {
              final sealed = (await _platform.invokeMethod<Uint8List>('seal', {'plain': p.record, 'aad': p.aad}))!;
              await storeWriteCas(dir: await _dir(), rel: p.rel, expectedGen: p.expectedGen, sealed: sealed);
              _log('已在手機存下網路資料（${p.rel.substring(0, 8)}…，第 ${p.generation} 版）');
              st = s.netPersisted();
            } catch (e) {
              // storeWriteCas throws its reason as a String (exactly the "changed elsewhere" line for a generation
              // mismatch); anything else (sealing, storage) is passed on as what failed
              final why = e is String ? e : (e is PlatformException ? 'seal ${e.code}' : '${e.runtimeType}');
              _log('[REQ_FAIL] 網路資料沒有存成功（${p.rel.substring(0, 8)}…）：$why');
              st = s.persistFailed(error: why);
            }
          case OwnerKind.confirmCountry:
            _log(st.detail);
            final question = screenText(st.detail);
            _wait?.cancel(); // the user's time does not count against the node's answer
            final yes = mounted
                ? await showDialog<bool>(
                    context: context,
                    builder: (c) => AlertDialog(
                          title: const Text('要改這台節點的國家嗎？'),
                          content: Text(question),
                          actions: [
                            TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('不要')),
                            TextButton(onPressed: () => Navigator.pop(c, true), child: const Text('改')),
                          ],
                        ))
                : false;
            if (gone()) return;
            _kick();
            st = s.countryConfirmed(yes: yes == true);
          case OwnerKind.loggedIn:
            _say('[LOGGED_IN] ${st.detail}');
            if (!done.isCompleted) done.complete(true);
            st = null;
          case OwnerKind.answer:
            if (st.pollLink) _linkFrom = DateTime.now();
            _lastHex = st.hex;
            _lastSas = st.sas;
            _lastRenewed = st.renewed;
            final a = _answer;
            if (a != null && !a.isCompleted) {
              a.complete('[ANSWER] ${st.detail}');
            } else if (_quiet) {
              _log('[ANSWER] ${st.detail}'); // a late link check stays quiet
            } else {
              _say('[ANSWER] ${st.detail}'); // an answer after its wait ended is still shown
            }
            st = null;
          case OwnerKind.ended:
            _log('裝置 $id：${st.detail}');
            if (!done.isCompleted) done.complete(false);
            final a = _answer;
            if (a != null && !a.isCompleted) a.complete('[REQ_FAIL] 連線已結束：${st.detail}');
            // Rust ended this session: the next action logs in again (only if it still is the current one)
            if (identical(_session, s)) _drop();
            st = null;
        }
      }
    }

    final inbox = StreamController<List<int>>();
    final notify = _ble
        .subscribeToCharacteristic(QualifiedCharacteristic(characteristicId: _tx, serviceId: provdService, deviceId: id))
        .listen(inbox.add, onError: (Object e) => done.isCompleted ? null : done.complete(false));
    inbox.stream.asyncMap((f) => run(s.onFrame(frame: f))).listen((_) {}, onError: (Object e) {
      _log('裝置 $id：步驟沒有完成（$e）');
      _endUnclear();
    });
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

  /// A join / make-network whose link went away: its pending answer becomes "outcome unknown" (or "nothing was
  /// written or sent" before any record write).
  void _endUnclear() {
    final a = _answer;
    if (a != null && !a.isCompleted && _unclear != null) a.complete(_unclearNow());
  }

  String _unclearNow() => _wrote ? _unclear! : _notSent;

  void _lost() {
    _say('[LINK_LOST] 和節點的連線斷了（下次操作時會自動重新連線）');
    _endUnclear();
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
        wait: _joinWait,
        unclear: _makeUnclear);
  }

  /// Restart the outstanding request's wait (each write to the node).
  void _kick() {
    _wait?.cancel();
    final a = _answer, line = _waitLine;
    _wait = Timer(_waitFor, () {
      if (a != null && !a.isCompleted) a.complete(_unclear != null ? _unclearNow() : line);
    });
  }

  /// One request on the owner session; the answer is shown (or with [quiet] only logged) and returned.
  /// [wait] runs from each write to the node, not from the start.
  /// [retry]: a write that fails logs in again and sends the request once more — never for a join / confirm, whose
  /// record was read before the first try (the record write would refuse a stale generation anyway).
  /// [unclear]: a join / make-network — a timeout or a lost link says this "outcome unknown" line (or, before any
  /// record write, that nothing was written or sent) and drops the session (it may be mid-flow).
  /// Any other request that times out drops the session too (its request is still outstanding there): the next
  /// action logs in again.
  /// [held]: the caller already holds _busy (the link watch after a join) and keeps it afterwards.
  Future<String?> _ask(OwnerStep Function(OwnerSession) req,
      {Duration wait = const Duration(seconds: 15),
      bool quiet = false,
      bool retry = true,
      String? unclear,
      bool held = false}) async {
    if (_busy && !held) return null;
    if (_session == null && _lastNode != null && !held) await _login(_lastNode!);
    var s = _session;
    if (s == null || (_busy && !held)) return null;
    if (mounted) setState(() => _busy = true);
    _waitFor = wait;
    _waitLine = '[REQ_FAIL] ${wait.inSeconds} 秒內節點沒有回應（結果不明；下次操作會重新連線）';
    _unclear = unclear;
    _wrote = false;
    _quiet = quiet;
    try {
      _answer = Completer<String>();
      try {
        await _run!(req(s));
      } catch (e) {
        // a Rust refusal (thrown as a String) is the operation's own answer, not a link problem
        if (e is String) rethrow;
        // a write / platform failure: flutter_reactive_ble reports GATT write errors as a plain Exception,
        // Kotlin as PlatformException
        final code = e is PlatformException ? e.code : '$e';
        if (unclear != null) {
          _say('[LINK_LOST] 連線或手機金鑰出錯（$code）');
          _say(_unclearNow());
          await _drop();
          return null;
        }
        if (!retry) rethrow;
        // nothing reached the node (the write itself failed): log in again and send it once more
        _say('[LINK_LOST] 連線或手機金鑰出錯（$code），正在重新連線…');
        await _drop();
        setState(() => _busy = false);
        await _login(_lastNode!);
        s = _session;
        if (s == null) return null;
        setState(() => _busy = true);
        _answer = Completer<String>();
        await _run!(req(s));
      }
      _kick();
      final a = await _answer!.future;
      if (unclear != null && (a == unclear || a == _notSent)) await _drop(); // the session may still be mid-flow
      if (a == _waitLine) await _drop(); // the request is still outstanding in that session
      if (quiet) {
        _log(a);
      } else {
        _say(a);
      }
      return a;
    } catch (e) {
      _say('[REQ_FAIL] 操作沒有成功：$e');
      return null;
    } finally {
      _wait?.cancel();
      _answer = null;
      _unclear = null;
      if (mounted && !held) setState(() => _busy = false);
    }
  }

  /// This phone's net records, opened (Kotlin) and summarised (Rust); one is picked (directly when there is only one).
  Future<_Net?> _pickNet(String title, {bool Function(NetView)? only, bool forJoin = false, String? none}) async {
    final dir = await _dir();
    final nets = <_Net>[];
    for (final id in await listNets(dir: dir)) {
      final rel = 'net/$id';
      try {
        final sealed = await storeReadSealed(dir: dir, rel: rel);
        if (sealed == null) continue;
        final plain = (await _platform.invokeMethod<Uint8List>('open', {'sealed': sealed.sealed, 'aad': sealed.aad}))!;
        final view = netSummary(recordPlain: plain);
        if (only == null || only(view)) nets.add(_Net(rel, plain, sealed.generation, view));
      } catch (e) {
        _say('網路紀錄 ${id.substring(0, 6)}… 打不開（手機的紀錄金鑰可能已遺失）：$e');
      }
    }
    if (nets.isEmpty) {
      // join2 §6: app reinstalled / record key lost -> no more nodes can be added from this phone
      _say(forJoin
          ? '手機裡沒有可用的網路紀錄，不能再加節點。若 App 重裝過：新建網路會讓整隊分成兩個網路，舊節點要重燒'
          : none ?? '手機裡沒有可用的網路紀錄');
      return null;
    }
    if (nets.length == 1 || !mounted) return nets.first;
    return showDialog<_Net>(
        context: context,
        builder: (c) => SimpleDialog(title: Text(title), children: [
              for (final n in nets)
                SimpleDialogOption(
                    onPressed: () => Navigator.pop(c, n),
                    child: Text('${n.view.meshId}（${n.view.applied ? '已建立' : '建立中'}，${n.view.members.length} 台）')),
            ]));
  }

  /// join2 §3.3: this logged-in node joins one of this phone's networks (also "繼續加入": the same flow again)
  Future<void> _joinNetwork() async {
    if (_busy) return;
    setState(() => _busy = true); // a second tap while the network is being picked does nothing
    final _Net? net;
    try {
      net = await _pickNet('要加入哪個網路？', forJoin: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
    if (net == null || !mounted) return;
    final n = net; // non-null from here (the request closure below cannot promote `net`)
    final keys = (await _platform.invokeMapMethod<String, dynamic>('publicKeys'))!;
    _say('正在把這台節點加入網路 ${net.view.meshId}，最多可能要等幾分鐘…');
    _linkFrom = null;
    await _ask(
        (s) => s.requestJoinNetwork(
            recordPlain: n.plain,
            recordGen: n.gen,
            adminPub: keys['admin'] as Uint8List,
            ownerEncPub: keys['ownerEnc'] as Uint8List),
        wait: _joinWait,
        retry: false,
        unclear: _joinUnclear);
    await _watchLink();
  }

  /// join2 §3.3-7: after "applied", read status every 10 s until connected or the window is over; one line shown.
  /// The whole window holds _busy (no other action or node can start in between) and reads only the session of the
  /// node that joined: once that session is gone (link lost / timeout), the result is unknown.
  Future<void> _watchLink() async {
    final from = _linkFrom;
    _linkFrom = null;
    final joined = _session;
    if (from == null || joined == null || _busy || !mounted) return;
    setState(() => _busy = true);
    var last = _linkUnknown;
    try {
      while (mounted && DateTime.now().difference(from) < _linkWindow) {
        await Future<void>.delayed(_linkEvery);
        if (!identical(_session, joined)) {
          last = _linkUnknown;
          break;
        }
        final secs = DateTime.now().difference(from).inSeconds;
        final a = await _ask((s) => s.requestLinkCheck(secsSinceJoin: BigInt.from(secs)),
            quiet: true, retry: false, held: true);
        if (a == null) {
          last = _linkUnknown; // the read failed (§3.3-7)
          break;
        }
        // anything but the node's answer (a timeout, a lost link) = unknown (§3.3-7)
        last = a.startsWith('[ANSWER] ') ? a.replaceFirst('[ANSWER] ', '') : _linkUnknown;
        if (last.startsWith('[CONNECTED]')) break;
      }
      _say(last);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  // ---- remote invites (254-app-member-join §4); every entry refuses in a field build (Rust, Kotlin and here) ----

  Future<bool> _devTrust() async => await _platform.invokeMethod<bool>('devTrust') ?? false;

  /// The clipboard's text, then the clipboard cleared (R12: as the claim QR).
  Future<String?> _takeClipboard() async {
    final d = await Clipboard.getData(Clipboard.kTextPlain);
    await Clipboard.setData(const ClipboardData(text: ''));
    return d?.text;
  }

  Widget _paste(String label, void Function(String) onText) => PasteButton(
      label: label, enabled: !_busy, devTrust: _devTrust, readClipboard: _takeClipboard, onText: onText, onRefused: (w) => _say('[REQ_FAIL] $w'));

  /// A sealed record as read: (generation, plain); plain null = none, or it does not open.
  Future<(BigInt, Uint8List?)> _readRecord(String rel) async {
    final sealed = await storeReadSealed(dir: await _dir(), rel: rel);
    if (sealed == null) return (BigInt.zero, null);
    try {
      return (sealed.generation, await _platform.invokeMethod<Uint8List>('open', {'sealed': sealed.sealed, 'aad': sealed.aad}));
    } on PlatformException {
      return (sealed.generation, null);
    }
  }

  /// Seal a record step's plain bytes and write them by CAS; the error text is store_write_cas's (or the sealing's).
  Future<String?> _writeRecord(OwnerStep p) async {
    try {
      final sealed = (await _platform.invokeMethod<Uint8List>('seal', {'plain': p.record, 'aad': p.aad}))!;
      await storeWriteCas(dir: await _dir(), rel: p.rel, expectedGen: p.expectedGen, sealed: sealed);
      return null;
    } catch (e) {
      return e is String ? e : (e is PlatformException ? 'seal ${e.code}' : '${e.runtimeType}');
    }
  }

  /// Run an admin operation (invite / approve): SignAdmin -> PersistNet -> the code, copied to the clipboard.
  Future<void> _runOp(NetOp op, OwnerStep? st) async {
    while (st != null) {
      switch (st.kind) {
        case OwnerKind.signAdmin:
          Uint8List der;
          try {
            der = (await _platform.invokeMethod<Uint8List>('signAdmin', {'input': st.signInput}))!;
          } on PlatformException catch (e) {
            _log('[REQ_FAIL] 手機的管理者金鑰無法簽章（${e.code}）');
            der = Uint8List(0);
          }
          st = op.signed(der: der);
        case OwnerKind.persistNet:
          final err = await _writeRecord(st);
          st = err == null ? op.netPersisted() : op.persistFailed(error: err);
        default:
          if (st.hex.isNotEmpty) await Clipboard.setData(ClipboardData(text: st.hex));
          _say(st.detail);
          st = null;
      }
    }
  }

  /// §4 step 1 (admin): a remote invite for one of this phone's networks.
  Future<void> _makeInvite() async {
    if (_busy) return;
    setState(() => _busy = true); // one thing at a time
    try {
      final net = await _pickNet('要邀請隊員加入哪個網路？', only: (v) => v.applied);
      if (net == null) return;
      final keys = (await _platform.invokeMapMethod<String, dynamic>('publicKeys'))!;
      final (op, st) = NetOp.makeInvite(recordPlain: net.plain, recordGen: net.gen, adminPub: keys['admin'] as Uint8List);
      await _runOp(op, st);
    } catch (e) {
      _say('[REQ_FAIL] 邀請沒有成功：$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// §4 steps 5-6 (admin): a pasted join request -> its SAS screen -> approve -> the approval code.
  Future<void> _checkRequest(String hex) async {
    final net = await _pickNet('這份申請是哪個網路的？', only: (v) => v.applied);
    if (net == null || !mounted) return;
    final JoinReqView jr;
    try {
      jr = netCheckJoinreq(recordPlain: net.plain, hex: hex);
    } catch (e) {
      _say('[REQ_FAIL] 申請不能用：$e');
      return;
    }
    final keys = (await _platform.invokeMapMethod<String, dynamic>('publicKeys'))!;
    if (!mounted) return;
    await Navigator.of(context).push(MaterialPageRoute(
        builder: (c) => SasConfirmView(
              title: '核對隊員的申請：${jr.name}（…${jr.deviceSuffix}）${jr.replacesApproved ? '，重新同意' : ''}',
              sas: jr.sas,
              confirmLabel: '確認碼相同，同意',
              onConfirm: (_) async {
                // the record is read again: approve re-runs every check on what is on disk now
                final (gen, plain) = await _readRecord(net.rel);
                if (plain == null) {
                  _say('[REQ_FAIL] 手機裡的網路資料打不開');
                } else {
                  try {
                    final (op, st) = NetOp.approve(recordPlain: plain, recordGen: gen, hex: hex, joinreqHash: jr.joinreqHash, adminPub: keys['admin'] as Uint8List);
                    await _runOp(op, st);
                  } catch (e) {
                    _say('[REQ_FAIL] 同意沒有成功：$e');
                  }
                }
                if (c.mounted) Navigator.of(c).pop();
              },
            )));
  }

  /// §4 step 2 (member): a pasted invite, checked and kept (public data).
  void _takeInvite(String hex) {
    try {
      final v = parseInvite(hex: hex);
      setState(() {
        _inviteHex = hex;
        _invite = v;
      });
      _say('[INVITE] 收到網路「${v.netName}」的邀請：登入自己的節點後按「申請加入」');
    } catch (e) {
      _say('[REQ_FAIL] 邀請不能用：$e');
    }
  }

  /// §4 step 4 (member, logged in to the own node): the join request; its code is copied, its SAS shown.
  Future<void> _requestJoin() async {
    final hex = _inviteHex, inv = _invite;
    if (hex == null || inv == null) return;
    final (gen, plain) = await _readRecord('mpend/${inv.netIdHex}');
    final keys = (await _platform.invokeMapMethod<String, dynamic>('publicKeys'))!;
    _lastHex = '';
    await _ask((s) => s.requestJoinreq(
        inviteHex: hex, name: _memberName.text.trim(), pendGen: gen, pendPlain: plain, ownerEncPub: keys['ownerEnc'] as Uint8List));
    await _showRequest();
  }

  Future<void> _showRequest() async {
    if (_lastHex.isEmpty) return;
    await Clipboard.setData(ClipboardData(text: _lastHex));
    final sas = _lastSas, renewed = _lastRenewed;
    _lastHex = '';
    if (!mounted) return;
    await showDialog<void>(
        context: context,
        builder: (c) => AlertDialog(
              title: const Text('申請已複製到剪貼簿，請傳給管理者'),
              content: SasShowView(sas: sas, notice: renewed ? '申請已換新，要重新核對 SAS' : null),
              actions: [TextButton(onPressed: () => Navigator.pop(c), child: const Text('好'))],
            ));
  }

  /// "Show the request again" (§3): from a pending request on this phone (also after a restart: mpend/ is listed).
  Future<void> _showPending() async {
    final ids = _invite != null ? [_invite!.netIdHex] : await listPends(dir: await _dir());
    if (ids.isEmpty) {
      _say('[REQ_FAIL] 這支手機沒有待處理的申請');
      return;
    }
    final id = ids.length == 1 || !mounted
        ? ids.first
        : await showDialog<String>(
            context: context,
            builder: (c) => SimpleDialog(title: const Text('哪一個網路的申請？'), children: [
                  for (final x in ids) SimpleDialogOption(onPressed: () => Navigator.pop(c, x), child: Text('網路 ${x.substring(0, 12)}…')),
                ]));
    if (id == null) return;
    final (_, plain) = await _readRecord('mpend/$id');
    if (plain == null) {
      _say('[REQ_FAIL] 這支手機沒有這個網路的申請');
      return;
    }
    try {
      final st = memberPendView(pendPlain: plain);
      _lastHex = st.hex;
      _lastSas = st.sas;
      _lastRenewed = false;
      await _showRequest();
    } catch (e) {
      _say('[REQ_FAIL] $e');
    }
  }

  /// §4 step 7 (member): a pasted approval -> 7a checks -> the SAS screen -> (pressed) Kotlin ECDH -> 7c -> mnet.
  Future<void> _takeApproval(String hex) async {
    final String id;
    try {
      id = approvalNetId(hex: hex);
    } catch (e) {
      _say('[REQ_FAIL] 同意碼不能用：$e');
      return;
    }
    final (pendGen, pend) = await _readRecord('mpend/$id');
    final (mnetGen, mnet) = await _readRecord('mnet/$id');
    final ImportPrep prep;
    try {
      prep = memberImportPrepare(hex: hex, pendGen: pendGen, pendPlain: pend, mnetPlain: mnet);
    } catch (e) {
      _say('[REQ_FAIL] 同意碼不能匯入：$e');
      return;
    }
    if (prep.state != ImportState.ready || pend == null) {
      _say(prep.detail);
      return;
    }
    if (!mounted) return;
    await Navigator.of(context).push(MaterialPageRoute(
        builder: (c) => SasConfirmView(
              title: '核對管理者的同意',
              sas: prep.sas,
              confirmLabel: '確認碼相同，匯入',
              onConfirm: (sas) async {
                await _importApproval(hex, id, prep, sas);
                if (c.mounted) Navigator.of(c).pop();
              },
            )));
  }

  Future<void> _importApproval(String hex, String id, ImportPrep prep, String confirmedSas) async {
    Uint8List? z;
    try {
      z = await _platform.invokeMethod<Uint8List>('ecdh', {'peer': prep.ephPub});
      // read again: 7c checks the same generation 7a saw
      final (pendGen, pend) = await _readRecord('mpend/$id');
      final (mnetGen, mnet) = await _readRecord('mnet/$id');
      if (z == null || pend == null) throw '找不到申請';
      final st = memberImportApproval(
          hex: hex,
          pendGen: pendGen,
          pendPlain: pend,
          expectedPendGen: prep.pendGen,
          mnetPlain: mnet,
          mnetGen: mnetGen,
          z: z,
          confirmedSas: confirmedSas);
      final err = await _writeRecord(st);
      if (err != null) {
        _say('[REQ_FAIL] 沒有匯入：$err');
        return;
      }
      // accepted fail-closed (§3): a request written meanwhile is removed too; a failed removal is harmless
      try {
        await storeRemove(dir: await _dir(), rel: 'mpend/$id');
      } catch (_) {}
      _say(st.detail);
    } on PlatformException catch (e) {
      _say('[REQ_FAIL] 沒有匯入：手機金鑰出錯（${e.code}）');
    } catch (e) {
      _say('[REQ_FAIL] 沒有匯入：$e');
    } finally {
      z?.fillRange(0, z.length, 0);
    }
  }

  /// §4 step 8 (member, logged in to the own node): join the imported network.
  Future<void> _memberJoin() async {
    if (_busy) return;
    setState(() => _busy = true); // a second tap while the network is being picked does nothing
    final (String, MnetView)? pick;
    try {
      pick = await _pickMnet();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
    if (pick == null || !mounted) return;
    final (gen, plain) = await _readRecord('mnet/${pick.$1}');
    if (plain == null) return;
    _say('正在把這台節點加入隊伍網路「${pick.$2.netName}」，最多可能要等幾分鐘…');
    _linkFrom = null;
    await _ask((s) => s.requestMemberJoin(mnetPlain: plain, mnetGen: gen), wait: _joinWait, retry: false, unclear: _joinUnclear);
    await _watchLink();
  }

  Future<(String, MnetView)?> _pickMnet() async {
    final dir = await _dir();
    final ids = listMnets(dir: dir);
    final views = <(String, MnetView)>[];
    for (final id in await ids) {
      final (_, plain) = await _readRecord('mnet/$id');
      if (plain == null) continue;
      try {
        views.add((id, mnetSummary(mnetPlain: plain)));
      } catch (_) {}
    }
    if (views.isEmpty) {
      _say('[REQ_FAIL] 手機裡沒有匯入過的隊伍網路（先貼上同意碼）');
      return null;
    }
    final pick = views.length == 1 || !mounted
        ? views.first
        : await showDialog<(String, MnetView)>(
            context: context,
            builder: (c) => SimpleDialog(title: const Text('要加入哪個隊伍網路？'), children: [
                  for (final v in views) SimpleDialogOption(onPressed: () => Navigator.pop(c, v), child: Text(v.$2.netName)),
                ]));
    return pick;
  }

  /// §8: a readable status page of the logged-in node.
  Future<void> _statusPage() async {
    final a = await _ask((s) => s.requestStatusPage(), quiet: true);
    final s = _session;
    if (a == null || s == null || !mounted) return;
    final v = s.statusView();
    final names = <String, String>{};
    final dir = await _dir();
    for (final id in await listNets(dir: dir)) {
      final (_, p) = await _readRecord('net/$id');
      if (p != null) {
        try {
          names[id] = netSummary(recordPlain: p).netName;
        } catch (_) {}
      }
    }
    for (final id in await listMnets(dir: dir)) {
      final (_, p) = await _readRecord('mnet/$id');
      if (p != null) {
        try {
          names[id] = mnetSummary(mnetPlain: p).netName;
        } catch (_) {}
      }
    }
    if (!mounted) return;
    final f = StatusFields(
        state: v.state, reason: v.reason, neighbours: v.neighbours, health: v.health, snr: v.snr, version: v.version, netId: v.netId);
    await Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => Scaffold(appBar: AppBar(title: const Text('節點狀態')), body: StatusPageView(fields: f, names: names))));
  }

  /// join2 §3.2: read info on the logged-in node against one of this phone's net records
  Future<void> _confirmNetwork() async {
    if (_busy) return;
    final net = await _pickNet('要確認哪個網路？');
    if (net == null) return;
    await _ask((s) => s.requestConfirmNetwork(recordPlain: net.plain, recordGen: net.gen), retry: false);
  }

  /// join2 §3.4: forget a joining member (this phone's record only; the node is not changed)
  Future<void> _forgetJoining() async {
    if (_busy) return;
    final net = await _pickNet('在哪個網路裡忘記？',
        only: (v) => v.members.any((m) => forgettable(joining: m.joining, approved: m.approved, creator: m.creator)),
        none: '沒有「加入中」或「已同意」的節點可以忘記');
    if (net == null || !mounted) return;
    // the node that made the network is never offered (Rust refuses it too: 建立網路的節點不能忘記)
    final joining = net.view.members.where((m) => forgettable(joining: m.joining, approved: m.approved, creator: m.creator)).toList();
    String who(MemberView m) => m.last4.isEmpty ? m.name : '${m.name}（…${m.last4}）';
    final m = joining.length == 1
        ? joining.first
        : await showDialog<MemberView>(
            context: context,
            builder: (c) => SimpleDialog(title: const Text('要忘記哪一台？'), children: [
                  for (final x in joining) SimpleDialogOption(onPressed: () => Navigator.pop(c, x), child: Text(who(x))),
                ]));
    if (m == null || !mounted) return;
    final yes = await showDialog<bool>(
        context: context,
        builder: (c) => AlertDialog(
              title: Text(m.approved ? '要從清單移除 ${who(m)} 嗎？' : '要忘記加入中的 ${who(m)} 嗎？'),
              content: Text(forgetNotice(approved: m.approved)),
              actions: [
                TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('取消')),
                TextButton(onPressed: () => Navigator.pop(c, true), child: const Text('忘記')),
              ],
            ));
    if (yes != true) return;
    try {
      final st = netForgetJoining(recordPlain: net.plain, recordGen: net.gen, dacHash: m.dacHash);
      final sealed = (await _platform.invokeMethod<Uint8List>('seal', {'plain': st.record, 'aad': st.aad}))!;
      await storeWriteCas(dir: await _dir(), rel: st.rel, expectedGen: st.expectedGen, sealed: sealed);
      _say(st.detail);
    } catch (e) {
      _say('[REQ_FAIL] 忘記沒有成功：$e');
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
            Row(children: [
              FilledButton(onPressed: _busy ? null : _joinNetwork, child: const Text('加入網路／繼續加入')),
              const SizedBox(width: 8),
              OutlinedButton(onPressed: _busy ? null : _confirmNetwork, child: const Text('確認網路')),
            ]),
          Align(
              alignment: Alignment.centerLeft,
              child: TextButton(onPressed: _busy ? null : _forgetJoining, child: const Text('忘記加入中的節點'))),
          if (logged) TextButton(onPressed: _busy ? null : _statusPage, child: const Text('狀態頁')),
          // remote invites (dev / dev2 only; the paste buttons refuse in a field build)
          const Text('遠端邀請（開發版）', style: TextStyle(fontWeight: FontWeight.bold)),
          Wrap(spacing: 8, children: [
            DevOnlyButton(label: '邀請隊員', enabled: !_busy, devTrust: _devTrust, onPressed: _makeInvite, onRefused: (w) => _say('[REQ_FAIL] $w')),
            _paste('貼上隊員的申請', (t) => _checkRequest(t)),
            _paste('貼上邀請', _takeInvite),
            _paste('貼上同意碼', (t) => _takeApproval(t)),
          ]),
          if (_invite != null) Text('邀請：網路「${_invite!.netName}」'),
          if (logged && _invite != null)
            Row(children: [
              Expanded(child: TextField(controller: _memberName, maxLength: 32, decoration: const InputDecoration(labelText: '這台節點的名稱（給管理者看）', counterText: ''))),
              OutlinedButton(onPressed: _busy ? null : _requestJoin, child: const Text('申請加入')),
            ]),
          TextButton(onPressed: _busy ? null : _showPending, child: const Text('再顯示申請')),
          if (logged) Align(alignment: Alignment.centerLeft, child: OutlinedButton(onPressed: _busy ? null : _memberJoin, child: const Text('加入隊伍網路'))),
          const Divider(),
          Expanded(child: ListView(children: [for (final l in _lines) Text(l, style: const TextStyle(fontFamily: 'monospace'))])),
        ]),
      ),
    );
  }
}
