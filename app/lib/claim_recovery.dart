// #254 app — claim recovery (design 254-app-replay v5): after 「認領」 found the node claimed (T2) or the claim's own
// finish may have committed (T1), recover the node with psk_replay. Rust runs the protocol (ReplaySession, sans-IO,
// §4's table in `next`); this file owns the candidates, rounds, pacing, time limits and cancellation (§3, §6) and moves
// the frames. Kotlin does the ECDH once before any connection and the owner signature. The only records it writes are
// those of a recovery, through ClaimRecords.claimed (copy aside -> node record -> remove the pending); every other end
// leaves the pending as it is. Nothing secret (K, z, records, passwords) is logged or shown.
import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_reactive_ble/flutter_reactive_ble.dart';

import 'claim_records.dart';
import 'key_abilities.dart';
import 'scan.dart' show provdService;
import 'src/rust/api/claim.dart';
import 'src/rust/api/claim.dart' as claim_api show frameLimit;
import 'src/rust/api/replay.dart';

// feed/batman-prov/src/cmd/batman-provd/bluez.go:31-34
final provdRx = Uuid.parse('540aa38c-0086-4d59-a9c0-c7c9d1e1bd42');
final provdTx = Uuid.parse('540aa38c-0086-4d5a-a9c0-c7c9d1e1bd42');
final provdCtrl = Uuid.parse('540aa38c-0086-4d5b-a9c0-c7c9d1e1bd42');

/// §3-1: the field build has no `ecdh`
const recoverNotYet = '這個版本的 app 還不能恢復中斷的認領（紀錄先保留）';

/// §2 T3, word for word
const t3Text = '沒找到未認領的這台。手機裡有它一次沒完成的認領，可以試著恢復：恢復會更換這台節點的 root 密碼，並中斷它目前所有的連線'
    '（包含隊友手機的）。如果它在「我的節點」還能用，不需要恢復。要恢復嗎？';

/// One BLE connection as the recovery uses it.
abstract class RecoveryLink {
  /// MTU, then CTRL -> the frame limit (before the TX notifications, design s1 §2)
  Future<int> frameLimit();

  /// TX notifications
  Stream<List<int>> get rx;
  Future<void> write(List<int> frame);
  Future<void> close();
}

/// BLE as the recovery uses it (the claim page: [ReactiveRecoveryBle]; tests: a fake).
abstract class RecoveryBle {
  /// false = the adapter is not ready (Bluetooth off, §3-7)
  Stream<bool> get ready;

  /// provd advertisers seen within [d]: id -> the strongest RSSI (nothing is connected or read)
  Future<Map<String, int>> scan(Duration d);

  /// null = no connection within [timeout]
  Future<RecoveryLink?> connect(String id, Duration timeout);
}

class ReactiveRecoveryBle implements RecoveryBle {
  ReactiveRecoveryBle(this.ble);
  final FlutterReactiveBle ble;

  @override
  Stream<bool> get ready => ble.statusStream.map((s) => s == BleStatus.ready);

  @override
  Future<Map<String, int>> scan(Duration d) async {
    final seen = <String, int>{};
    final sub = ble.scanForDevices(withServices: [provdService], scanMode: ScanMode.lowLatency).listen((x) {
      final o = seen[x.id];
      if (o == null || x.rssi > o) seen[x.id] = x.rssi;
    }, onError: (Object _) {});
    await Future<void>.delayed(d);
    await sub.cancel();
    return seen;
  }

  @override
  Future<RecoveryLink?> connect(String id, Duration timeout) async {
    final up = Completer<bool>();
    final conn = ble.connectToDevice(id: id, connectionTimeout: timeout).listen((u) {
      if (up.isCompleted) return;
      if (u.connectionState == DeviceConnectionState.connected) up.complete(true);
      if (u.connectionState == DeviceConnectionState.disconnected) up.complete(false);
    }, onError: (Object _) {
      if (!up.isCompleted) up.complete(false);
    });
    if (!await up.future.timeout(timeout, onTimeout: () => false)) {
      await conn.cancel();
      return null;
    }
    return _ReactiveLink(ble, id, conn);
  }
}

class _ReactiveLink implements RecoveryLink {
  _ReactiveLink(this.ble, this.id, this.conn);
  final FlutterReactiveBle ble;
  final String id;
  final StreamSubscription<ConnectionStateUpdate> conn;

  QualifiedCharacteristic _c(Uuid u) => QualifiedCharacteristic(characteristicId: u, serviceId: provdService, deviceId: id);

  @override
  Future<int> frameLimit() async {
    final mtu = await ble.requestMtu(deviceId: id, mtu: 517);
    return claim_api.frameLimit(ctrl: await ble.readCharacteristic(_c(provdCtrl)), mtu: mtu);
  }

  @override
  Stream<List<int>> get rx => ble.subscribeToCharacteristic(_c(provdTx));

  @override
  Future<void> write(List<int> frame) => ble.writeCharacteristicWithoutResponse(_c(provdRx), value: frame);

  @override
  Future<void> close() => conn.cancel();
}

enum RecoveryOutcome {
  /// nothing was connected: no pending of this QR (another K, unreadable), keys, the field build, T3 declined
  notStarted,
  recovered,
  stopped,
  exhausted,
  cancelled,
}

/// One connection's end
class _Try {
  _Try(this.step, {this.wrote = false, this.unanswered = false, this.decrypted = false});
  final ReplayStep step;
  final bool wrote, unanswered, decrypted;
}

ReplayStep _stopStep(String detail) => ReplayStep(
    kind: ReplayKind.ended,
    frames: const [],
    signInput: Uint8List(0),
    next: ReplayNext.stop,
    detail: detail,
    path: '',
    record: Uint8List(0),
    pendingPath: '');

/// One recovery = one 「認領」 (§3: at most one per press). [say] gets the lines (log markers first).
class ClaimRecovery {
  ClaimRecovery({
    required this.ble,
    required this.platform,
    required this.store,
    required this.records,
    required this.qr,
    required this.say,
  });

  final RecoveryBle ble;
  final MethodChannel platform;
  final ClaimStore store;
  final ClaimRecords records;
  final ClaimQr qr;
  final void Function(String) say;

  // §3-2 / §3-3 / §3-4 / §3-5 / §4
  static const t1Wait = Duration(seconds: 15);
  static const roundGap = Duration(seconds: 15);
  static const lockWait = Duration(seconds: 15);
  static const connectFor = Duration(seconds: 15);
  static const msg2For = Duration(seconds: 12);
  static const answerFor = Duration(seconds: 12);
  static const signFor = Duration(seconds: 10);
  static const beforeWriteFor = Duration(seconds: 45);
  static const afterWriteFor = Duration(seconds: 90);
  static const total = Duration(seconds: 300);
  static const scanFor = Duration(seconds: 6);
  static const pace = Duration(seconds: 10);
  static const rounds = 3;
  static const perRound = 6;
  static const lockMax = 5;

  bool _cancel = false; // stop asked (button, page left, Bluetooth off)
  bool _btOff = false;
  bool _writtenNow = false; // claim/replay written on the connection now open
  bool _expired = false;
  bool _unanswered = false; // a claim/replay went out and no answer came
  bool _t3 = false;
  final _abort = Completer<void>(); // fires when the connection now open must go at once
  Timer? _paceTimer;
  Completer<void>? _paced;

  /// 「停止恢復」 / the page left (§3-7): before claim/replay is written -> disconnect now; after -> wait for this
  /// node's answer (≤ 90 s) and still write the record it brings.
  void cancel() {
    if (_cancel) return;
    _cancel = true;
    if (!_writtenNow) _fire();
  }

  void _fire() {
    if (!_abort.isCompleted) _abort.complete();
  }

  bool get _stopped => _cancel || _expired;

  /// A wait that ends early when the recovery must stop at once.
  Future<void> _sleep(Duration d) {
    final c = Completer<void>();
    final t = Timer(d, () {
      if (!c.isCompleted) c.complete();
    });
    _abort.future.then((_) {
      t.cancel();
      if (!c.isCompleted) c.complete();
    });
    return c.future;
  }

  /// [future]'s value, or null when the recovery must stop at once, after [d], or when [or] fires
  Future<T?> _race<T>(Future<T> future, Duration d, {Future<void>? or}) {
    final c = Completer<T?>();
    final t = Timer(d, () {
      if (!c.isCompleted) c.complete(null);
    });
    void none(_) {
      t.cancel();
      if (!c.isCompleted) c.complete(null);
    }

    future.then((v) {
      t.cancel();
      if (!c.isCompleted) c.complete(v);
    }, onError: (Object e) {
      t.cancel();
      if (!c.isCompleted) c.completeError(e);
    });
    _abort.future.then(none);
    or?.then(none);
    return c.future;
  }

  /// §2 / §3-1: the pending of this QR (re-read, the same K), the live key levels, the strict decode, T3, the ECDH —
  /// all before any connection. Null = no recovery (said why, when there is something to say; the pending untouched).
  Future<ReplaySession?> _prepare(Future<bool> Function() askT3) async {
    final Uint8List plain;
    try {
      final s = await store.readSealed('claim-pending/${qr.deviceId}');
      if (s == null) return null;
      plain = await store.open(s);
    } catch (e) {
      say('[CLAIM_FAIL] 讀不到手機裡這台節點的認領紀錄，這次不恢復：$e');
      return null;
    }
    try {
      if (!await store.matches(plain, qr)) return null; // another K (noover R4): never replayed with this QR
      final able = await KeyAbilities.read(platform); // s1 §4.1: live, before every recovery
      final no = able.refusal(KeyUse.recover);
      if (no != null) {
        say('[CLAIM_FAIL] [KEY_LEVEL] $no。手機裡的紀錄沒有改動。');
        return null;
      }
      final ReplaySession session;
      final Uint8List peer;
      try {
        (session, peer) = ReplaySession.prepare(pendingPlain: plain, deviceId: qr.deviceId, devSoftEnc: able.softOwnerEnc);
      } catch (e) {
        say('[CLAIM_FAIL] $e');
        return null;
      }
      if (_t3 && !await askT3()) {
        session.dispose();
        return null;
      }
      Uint8List? z;
      try {
        z = await platform.invokeMethod<Uint8List>('ecdh', {'peer': peer});
        if (z == null) throw recoverNotYet;
        session.setZ(z: z);
      } catch (e) {
        session.dispose();
        final k = KeyAbilities.refusedBy(e);
        say(k != null ? '[CLAIM_FAIL] [KEY_LEVEL] $k' : '[CLAIM_FAIL] $recoverNotYet');
        return null;
      } finally {
        z?.fillRange(0, z.length, 0); // §3-1: Dart's copy of z goes at once
      }
      return session;
    } catch (e) {
      say('[CLAIM_FAIL] 讀不到手機裡這台節點的認領紀錄，這次不恢復：$e');
      return null;
    } finally {
      plain.fillRange(0, plain.length, 0);
    }
  }

  /// Runs the recovery. [t1Id]: T1 — only this device (the claim's), after 15 s; null = T2 (scan). [after9]: the
  /// claim's finish answered 9. [t3]: this phone has a node record of it -> [askT3] first (T2 only). [intro]: said
  /// once the recovery is about to connect.
  Future<RecoveryOutcome> run(
      {String? t1Id, bool after9 = false, bool t3 = false, Future<bool> Function()? askT3, required String intro}) async {
    _t3 = t3 && t1Id == null;
    final session = await _prepare(askT3 ?? () async => false);
    if (session == null) return RecoveryOutcome.notStarted;
    final deadline = Timer(total, () => _expired = true);
    final bt = ble.ready.listen((r) {
      if (!r) {
        _btOff = true;
        _cancel = true;
        _fire();
      }
    });
    try {
      say(intro);
      if (t1Id != null) {
        await _sleep(t1Wait); // §2 T1: provd's cached state (N3)
        var connected = false;
        for (var r = 1; r <= rounds && !_stopped; r++) {
          if (r > 1) await _sleep(roundGap);
          if (_stopped) break;
          say('恢復中：第 $r/$rounds 輪，第 1/1 台');
          final t = await _device(session, t1Id);
          final end = await _final(t);
          if (end != null) return end;
          if (t.step.next != ReplayNext.noConnection) connected = true;
        }
        if (_cancel) return _cancelled();
        // §2: every T1 round "no connection" (not "undecryptable") -> T2 in the same press, without T3
        if (connected || _expired) return _exhausted(after9: after9);
        say('連不上剛才的節點，改為掃描附近的節點再試');
      }
      final end = await _t2(session);
      if (end != null) return end;
      if (_cancel) return _cancelled();
      return _exhausted(after9: false);
    } finally {
      deadline.cancel();
      _paceTimer?.cancel();
      _fire(); // releases any wait still registered
      unawaited(bt.cancel());
      session.dispose();
    }
  }

  /// §3-4 T2: each round a 6 s scan, then ≤ 6 devices — those not tried yet first (by RSSI), then the tried ones (by
  /// RSSI) — until one's msg2 decrypts with the pinned DAC: from then on only that one.
  Future<RecoveryOutcome?> _t2(ReplaySession session) async {
    String? target;
    final tried = <String>{};
    final seenAll = <String>{};
    for (var r = 1; r <= rounds && !_stopped; r++) {
      if (r > 1) await _sleep(roundGap);
      if (_stopped) break;
      final seen = await _race(ble.scan(scanFor), scanFor + const Duration(seconds: 5)) ?? const <String, int>{};
      if (_stopped) break;
      seenAll.addAll(seen.keys);
      final List<String> list;
      if (target != null) {
        list = [target];
      } else {
        final byRssi = seen.keys.toList()..sort((a, b) => seen[b]!.compareTo(seen[a]!));
        list = [...byRssi.where((id) => !tried.contains(id)), ...byRssi.where(tried.contains)].take(perRound).toList();
      }
      for (var i = 0; i < list.length && !_stopped; i++) {
        say('恢復中：第 $r/$rounds 輪，第 ${i + 1}/${list.length} 台');
        final t = await _device(session, list[i]);
        final end = await _final(t);
        if (end != null) return end;
        if (t.decrypted) {
          target = list[i];
          break;
        }
        tried.add(list[i]);
      }
    }
    if (target == null && seenAll.difference(tried).isNotEmpty) say('附近還有沒試過的節點：請把手機貼近要恢復的節點再試');
    return null;
  }

  /// One device: an attempt, and §4's 13 — disconnect, 15 s, a new connection, again (not a round; ≤ 5 in a row,
  /// and never after the total time is up).
  Future<_Try> _device(ReplaySession session, String id) async {
    var locks = 0;
    var unanswered = false;
    var decrypted = false;
    while (true) {
      final t = await _attempt(session, id);
      unanswered |= t.unanswered;
      decrypted |= t.decrypted;
      if (t.step.next != ReplayNext.reconnect) return _Try(t.step, unanswered: unanswered, decrypted: decrypted);
      locks++;
      if (locks >= lockMax || _expired) {
        return _Try(_stopStep(recoveryEndText(end: RecoveryEnd.lockIncomplete, after9: false, unanswered: false, oldRecord: _t3)),
            decrypted: decrypted);
      }
      if (_cancel) return _Try(t.step, unanswered: unanswered, decrypted: decrypted);
      await _sleep(lockWait);
      if (_cancel) return _Try(t.step, unanswered: unanswered, decrypted: decrypted);
    }
  }

  /// The end of the whole recovery, or null = go on.
  Future<RecoveryOutcome?> _final(_Try t) async {
    _unanswered |= t.unanswered;
    switch (t.step.next) {
      case ReplayNext.recovered:
        try {
          await records.claimed(t.step.path, t.step.record, t.step.pendingPath); // copy aside -> node record -> pending
        } catch (e) {
          say('[CLAIM_FAIL] 節點已恢復，但手機的紀錄沒有寫成功（$e）；認領紀錄仍保留，請再按一次「認領」');
          return RecoveryOutcome.stopped;
        }
        say('[CLAIMED] [RECOVERED] ${t.step.detail}');
        return RecoveryOutcome.recovered;
      case ReplayNext.stop:
        say('[CLAIM_FAIL] [NOT_RECOVERED] ${t.step.detail}');
        return RecoveryOutcome.stopped;
      default:
        if (_cancel) return _cancelled();
        return null;
    }
  }

  RecoveryOutcome _cancelled() {
    say(_btOff ? '[CLAIM_FAIL] 藍牙已關閉，恢復已停止（紀錄先保留）' : '[CLAIM_FAIL] 已停止恢復（紀錄先保留）');
    return RecoveryOutcome.cancelled;
  }

  RecoveryOutcome _exhausted({required bool after9}) {
    say('[CLAIM_FAIL] [NOT_RECOVERED] '
        '${recoveryEndText(end: RecoveryEnd.exhausted, after9: after9, unanswered: _unanswered, oldRecord: _t3)}');
    return RecoveryOutcome.exhausted;
  }

  /// §3-3: two handshakes start ≥ 10 s apart
  Future<void> _waitPace() async {
    final p = _paced;
    if (p != null && !p.isCompleted) await _race(p.future, pace + const Duration(seconds: 1));
  }

  void _startPace() {
    _paceTimer?.cancel();
    final c = Completer<void>();
    _paced = c;
    _paceTimer = Timer(pace, () {
      if (!c.isCompleted) c.complete();
    });
  }

  /// One connection with §3-2's limits: connect ≤ 15 s; msg2 ≤ 12 s; claim/begin and op/nonce ≤ 12 s each; the
  /// signature ≤ 10 s; everything before claim/replay is written ≤ 45 s; its answer ≤ 90 s.
  Future<_Try> _attempt(ReplaySession session, String id) async {
    await _waitPace();
    if (_cancel) return _Try(session.lost());
    final events = <Object>[]; // ReplayStep, or 'lost'
    Completer<void>? wake;
    void push(Object e) {
      events.add(e);
      final w = wake;
      wake = null;
      if (w != null && !w.isCompleted) w.complete();
    }

    var beforeWrite = true;
    final preExpired = Completer<void>(); // the 45 s before the write ran out (also ends a signature wait)
    final preWrite = Timer(beforeWriteFor, () {
      if (!beforeWrite) return;
      preExpired.complete();
      push('lost');
    });
    final connecting = ble.connect(id, connectFor);
    final link = await _race(connecting, connectFor + const Duration(seconds: 1));
    if (link == null) {
      preWrite.cancel();
      unawaited(connecting.then((l) => l?.close(), onError: (Object _) {}));
      return _Try(session.lost());
    }
    _abort.future.then((_) {
      if (!_writtenNow || _btOff) push('lost');
    });
    StreamSubscription<List<int>>? rx;
    var wrote = false;
    var decrypted = false;
    try {
      if (_abort.isCompleted) return _Try(session.lost());
      final fl = await _race(link.frameLimit(), answerFor);
      if (fl == null || events.isNotEmpty) return _Try(session.lost());
      rx = link.rx.listen((f) {
        final st = session.onFrame(frame: f);
        if (st != null) push(st);
      }, onError: (Object _) => push('lost'), onDone: () => push('lost'));
      Future<Object> next(Duration d) async {
        if (events.isEmpty) {
          final w = Completer<void>();
          wake = w;
          final t = Timer(d, () => push('lost'));
          await w.future;
          t.cancel();
        }
        return events.removeAt(0);
      }

      var st = session.begin(frameLimit: fl);
      var first = true;
      while (true) {
        switch (st.kind) {
          case ReplayKind.write:
            for (final f in st.frames) {
              await link.write(f);
            }
            if (first) _startPace(); // msg1 went out: the handshake started
            first = false;
            if (session.written()) {
              wrote = true;
              _writtenNow = true;
              beforeWrite = false;
            }
            final e = await next(_writtenNow ? afterWriteFor : (session.decrypted() ? answerFor : msg2For));
            if (e is! ReplayStep) {
              final w = session.written();
              if (w) _unanswered = true;
              return _Try(session.lost(), wrote: w, unanswered: w, decrypted: decrypted);
            }
            decrypted = session.decrypted(); // msg2 of this connection decrypted with the pinned DAC
            st = e;
          case ReplayKind.sign:
            final Uint8List? der;
            try {
              der = await _race<Uint8List?>(platform.invokeMethod<Uint8List>('signOwner', {'input': st.signInput}), signFor,
                  or: preExpired.future);
            } catch (e) {
              final k = KeyAbilities.refusedBy(e);
              final lost = session.lost(); // before claim/replay: §4 "next round"
              return _Try(k != null ? _stopStep('[KEY_LEVEL] $k') : lost, decrypted: true);
            }
            if (der == null || events.isNotEmpty) return _Try(session.lost(), decrypted: true);
            final s = session.signed(der: der);
            if (s == null) return _Try(session.lost(), decrypted: true);
            st = s;
          case ReplayKind.ended:
          case ReplayKind.recovered:
            return _Try(st, wrote: wrote, decrypted: decrypted);
        }
      }
    } catch (e) {
      return _Try(_stopStep('恢復中斷：$e'), wrote: wrote, decrypted: decrypted);
    } finally {
      preWrite.cancel();
      unawaited(rx?.cancel()); // not awaited: nothing depends on it (and a fake-async test would wait forever)
      await link.close(); // every end disconnects (§4: an undecryptable msg2 at once)
      _writtenNow = false;
    }
  }
}
