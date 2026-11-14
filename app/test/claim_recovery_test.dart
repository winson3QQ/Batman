// 254-app-replay §10 D-tests and S-tests of the recovery itself (ClaimRecovery): T1 / T2 rounds, candidates, pacing,
// time limits, cancellation, §4's actions, the records, and no secret in any line. Fake BLE + fake node
// (replay_fakes.dart, the §0 N-facts the app can see) + a fake Rust session over the same §4 table; fake clock.

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:batman_app/claim_records.dart';
import 'package:batman_app/claim_recovery.dart';
import 'package:batman_app/src/rust/api/claim.dart';
import 'package:batman_app/src/rust/api/replay.dart';
import 'package:batman_app/src/rust/frb_generated.dart';

import 'replay_fakes.dart';

class FakeRust implements RustLibApi {
  FakeReplay? last;
  Object? prepareError;
  final endTexts = <String>[];
  final prepared = <String>[];

  @override
  (ReplaySession, Uint8List) crateApiReplayReplaySessionPrepare(
      {required List<int> pendingPlain, required String deviceId, required bool devSoftEnc}) {
    prepared.add(deviceId);
    if (prepareError != null) throw prepareError!;
    last = FakeReplay();
    return (last!, Uint8List.fromList([4, ...List.filled(64, 1)]));
  }

  /// the closing words are Rust's (bridge closing_words); here: which case Dart asked for
  @override
  String crateApiReplayRecoveryEndText({required RecoveryEnd end, required bool after9, required bool unanswered, required bool oldRecord}) {
    if (end == RecoveryEnd.stopped && !unanswered) return ''; // as Rust: nothing to add
    final s = 'END ${end.name} after9=$after9 unanswered=$unanswered old=$oldRecord';
    endTexts.add(s);
    return s;
  }

  @override
  dynamic noSuchMethod(Invocation i) => throw UnimplementedError('${i.memberName}');
}

final qr = ClaimQr(deviceId: deviceId, k: Uint8List.fromList(List.filled(32, 0x4b)));

class H {
  H(this.t, this.rust) {
    final t0 = t.binding.clock.now();
    now = () => t.binding.clock.now().difference(t0);
    store.files[pendPath] = Uint8List.fromList(pendingBytes);
    t.binding.defaultBinaryMessenger.setMockMethodCallHandler(const MethodChannel('dev.batman/platform'), plat.handle);
  }
  final WidgetTester t;
  final FakeRust rust;
  final field = FakeField();
  final store = FakeStore();
  final plat = FakePlatform();
  final lines = <String>[];
  ClaimRecovery? rec;
  bool t3Answer = true;
  int t3Asked = 0;

  Future<RecoveryOutcome> start({String? t1, bool after9 = false, bool t3 = false}) {
    rec = ClaimRecovery(
        ble: field,
        platform: const MethodChannel('dev.batman/platform'),
        store: store,
        records: ClaimRecords(store, qr, lines.add),
        qr: qr,
        say: lines.add);
    return rec!.run(t1Id: t1, after9: after9, t3: t3, askT3: () async {
      t3Asked++;
      return t3Answer;
    }, intro: 'INTRO');
  }

  Future<RecoveryOutcome> run({String? t1, bool after9 = false, bool t3 = false}) =>
      drive(t, start(t1: t1, after9: after9, t3: t3));

  /// the pending is exactly what it was, and nothing wrote or removed it
  void pendingUntouched() {
    expect(store.files[pendPath], pendingBytes, reason: 'the pending is the only way back to a locked node');
    expect(store.calls.where((c) => c.endsWith(pendPath)), isEmpty);
    expect(store.files.containsKey(nodeRecPath), isFalse);
  }

  Iterable<String> get progress => lines.where((l) => l.startsWith('恢復中'));
}

void main() {
  final rust = FakeRust();
  setUpAll(() => RustLib.initMock(api: rust));
  setUp(() {
    rust.prepareError = null;
    rust.endTexts.clear();
    rust.prepared.clear();
  });

  // ---- T1 ----

  // D1: T1 tries only the device the claim used; a stronger claimed device nearby is never touched, nothing is
  // scanned. The node is in provd's cache window for the first handshake (N3): round 1 undecryptable, round 2 ok.
  // Negative control: T1 that scans (the T2 candidates) -> the other device is connected.
  testWidgets('D1: T1 connects only the claim\'s device id', (t) async {
    final h = H(t, rust);
    final mine = Dev('AA', -80, ours: true)..fakeFor = 1;
    h.field
      ..add(Dev('BB', -30))
      ..add(mine);
    expect(await h.run(t1: 'AA'), RecoveryOutcome.recovered);
    expect(h.field.connectLog, ['AA', 'AA']);
    expect(h.field.scanAt, isEmpty, reason: 'T1 never scans');
    expect(h.field.devs['BB']!.connects, 0);
    expect(mine.connectAt.first, greaterThanOrEqualTo(const Duration(seconds: 15)), reason: '§2 T1: 15 s first (N3)');
    expect(mine.connectAt[1] - mine.closedAt[0], greaterThanOrEqualTo(const Duration(seconds: 15)), reason: 'rounds 15 s apart');
    expect(h.store.calls, ['copy $nodeRecPath', 'write $nodeRecPath', 'remove $pendPath']);
  });

  // D8: T1's three rounds all "no connection" (the node's BLE id changed, N15 assumption broken) -> T2 in the same
  // press (no T3 question) -> recovered under the new id; one round that connects (only undecryptable) -> no T2.
  // Negative control: the T1 -> T2 hand-over removed -> ends with the neutral words, no node record.
  testWidgets('D8: T1 never connects -> T2 in the same press -> recovered', (t) async {
    final h = H(t, rust);
    h.field
      ..add(Dev('AA', -50)..reachable = false)
      ..add(Dev('AB', -60, ours: true));
    expect(await h.run(t1: 'AA', t3: true), RecoveryOutcome.recovered);
    expect(h.field.connectLog, ['AA', 'AA', 'AA', 'AB']);
    expect(h.field.scanAt, hasLength(1));
    expect(h.t3Asked, 0, reason: 'T3 is never asked after T1');
    expect(h.store.files[nodeRecPath], isNotNull);
  });

  testWidgets('D8 control: a T1 round that connects (undecryptable) -> no T2; the after-9 words', (t) async {
    final h = H(t, rust);
    h.field.add(Dev('AA', -50, ours: true)..fakeFor = 99);
    expect(await h.run(t1: 'AA', after9: true), RecoveryOutcome.exhausted);
    expect(h.field.scanAt, isEmpty);
    expect(h.field.connectLog, ['AA', 'AA', 'AA']);
    expect(rust.endTexts, ['END exhausted after9=true unanswered=false old=false']);
    h.pendingUntouched();
  });

  // ---- T2 ----

  // D2: no STATUS read (the recovery's BLE has no read but CTRL on its own link), candidates by RSSI, ≤ 6 a round, a
  // new scan each round, the tried ones after the untried; nothing decrypts -> the neutral words, pending kept.
  // Negative controls: no sort / no limit / one scan only -> FAIL.
  testWidgets('D2: T2 order by RSSI, ≤ 6 per round, a new scan each round; none decrypts -> neutral words', (t) async {
    final h = H(t, rust);
    for (final i in [5, 2, 8, 1, 7, 3, 6, 4]) { // not in RSSI order: the scan's order must not matter
      h.field.add(Dev('D$i', -10 * i));
    }
    expect(await h.run(), RecoveryOutcome.exhausted);
    expect(h.field.scanAt, hasLength(3), reason: 'a scan per round');
    expect(h.field.connectLog.sublist(0, 6), ['D1', 'D2', 'D3', 'D4', 'D5', 'D6'], reason: 'round 1: strongest 6');
    expect(h.field.connectLog.sublist(6, 12), ['D7', 'D8', 'D1', 'D2', 'D3', 'D4'], reason: 'round 2: untried first');
    expect(h.field.connectLog, hasLength(18));
    expect(rust.endTexts, ['END exhausted after9=false unanswered=false old=false']);
    expect(h.progress.first, '恢復中：第 1/3 輪，第 1/6 台');
    expect(h.progress.last, '恢復中：第 3/3 輪，第 6/6 台');
    h.pendingUntouched();
  });

  // D2: once a msg2 decrypts with the pinned DAC that device is the node: later rounds try only it (here claim/begin
  // answered 7 = ops busy, N13 -> next round)
  testWidgets('D2: after a decrypted msg2 only that device is tried', (t) async {
    final h = H(t, rust);
    final mine = Dev('M', -40, ours: true)..beginCodes.addAll([7, 7]); // busy twice: rounds 2 and 3 must try it alone
    h.field
      ..add(Dev('X', -20))
      ..add(mine)
      ..add(Dev('Y', -60));
    expect(await h.run(), RecoveryOutcome.recovered);
    expect(h.field.connectLog, ['X', 'M', 'M', 'M']);
    expect(mine.replays, 1);
  });

  // D9: 8 devices, the target's RSSI 7th -> round 2 reaches it. Fast fake msg2s; and every device near the worst case
  // (connect 15 s, then no msg2 for 12 s): round 2's first device starts at 6 + 6×27 + 15 + 6 ≈ 189 s < 300 s, and
  // after T1's three no-connection rounds (15 + 3×15 + 2×15 = 90 s) at ≈ 279 s < 300 s. A third round would not fit.
  // Negative control: without the "tried" set round 2 starts again from the strongest -> the target is never tried.
  for (final mode in ['fast', 'worst', 'after T1']) {
    testWidgets('D9: the 7th by RSSI is tried in round 2 ($mode)', (t) async {
      final h = H(t, rust);
      for (var i = 1; i <= 8; i++) {
        final d = Dev('D$i', -10 * i, ours: i == 7);
        if (mode != 'fast' && i != 7) {
          d
            ..connectTime = const Duration(milliseconds: 14900)
            ..msg2Silent = true;
        }
        h.field.add(d);
      }
      if (mode == 'after T1') h.field.add(Dev('GONE', -5)..reachable = false);
      final out = await h.run(t1: mode == 'after T1' ? 'GONE' : null);
      expect(out, RecoveryOutcome.recovered);
      final target = h.field.devs['D7']!;
      expect(target.connectAt, hasLength(1));
      final at = target.connectAt.first;
      expect(at, lessThan(ClaimRecovery.total));
      if (mode == 'worst') expect(at.inSeconds, inInclusiveRange(186, 192), reason: 'round 2 starts ≈ 189 s ($at)');
      if (mode == 'after T1') expect(at.inSeconds, inInclusiveRange(276, 282), reason: '≈ 279 s ($at)');
    });
  }

  // D9: at the worst case a third round does not fit in 300 s (written down in §3-4): with no target at all, two scans
  testWidgets('D9: worst case without the node: round 3 never starts', (t) async {
    final h = H(t, rust);
    for (var i = 1; i <= 8; i++) {
      h.field.add(Dev('D$i', -10 * i)
        ..connectTime = const Duration(milliseconds: 14900)
        ..msg2Silent = true);
    }
    expect(await h.run(), RecoveryOutcome.exhausted);
    expect(h.field.scanAt, hasLength(2));
    expect(h.progress.where((l) => l.contains('第 3/3 輪')), isEmpty);
  });

  // ---- §4 actions ----

  // D5: the first refusal stops (one counted failure per press); 12 stops with s1's words (Rust's text); 13 at most 5
  // in a row. Negative control: the stop rule -> a second replay goes out.
  testWidgets('D5: the first refusal (3) stops: one replay only', (t) async {
    final h = H(t, rust);
    h.field.add(Dev('M', -40, ours: true)..replies.addAll([const Reply(3), const Reply(0)]));
    expect(await h.run(), RecoveryOutcome.stopped);
    expect(h.field.devs['M']!.replays, 1);
    expect(h.lines.last, '[CLAIM_FAIL] [NOT_RECOVERED] REFUSED 3');
    h.pendingUntouched();
  });

  testWidgets('D5: 12 stops at once with its words', (t) async {
    final h = H(t, rust);
    h.field.add(Dev('M', -40, ours: true)..replies.add(const Reply(12)));
    expect(await h.run(), RecoveryOutcome.stopped);
    expect(h.field.devs['M']!.replays, 1);
    expect(h.lines.last, '[CLAIM_FAIL] [NOT_RECOVERED] RATE');
  });

  // D5 / D16: 13 -> disconnect, 15 s, a NEW connection, again; not a round: four 13s then OK recovers (5 connections,
  // more than 3 rounds); five 13s in a row stop with the lock words. Negative control: 13 counted as a round -> stopped
  // after the third.
  testWidgets('D16: 13 is retried on new connections and is not a round', (t) async {
    final h = H(t, rust);
    final m = Dev('M', -40, ours: true)..replies.addAll(List.filled(4, const Reply(13, rotates: false)));
    h.field.add(m);
    expect(await h.run(t1: 'M'), RecoveryOutcome.recovered);
    expect(m.replays, 5);
    expect(m.connects, 5);
    for (var i = 1; i < 5; i++) {
      expect(m.connectAt[i] - m.closedAt[i - 1], greaterThanOrEqualTo(const Duration(seconds: 15)));
    }
    expect(h.store.files[nodeRecPath], rec(1), reason: 'the password of the one success');
  });

  testWidgets('D5: five 13s in a row stop with the lock words', (t) async {
    final h = H(t, rust);
    final m = Dev('M', -40, ours: true)..replies.addAll(List.filled(9, const Reply(13, rotates: false)));
    h.field.add(m);
    expect(await h.run(t1: 'M'), RecoveryOutcome.stopped);
    expect(m.replays, 5);
    expect(rust.endTexts, ['END lockIncomplete after9=false unanswered=false old=false']);
    h.pendingUntouched();
  });

  // D10: the answer comes 60 s after claim/replay was written -> the record is written, one replay only.
  // Negative control: the after-write wait at 45 s -> no record, a second replay.
  testWidgets('D10: an answer after 60 s is waited for', (t) async {
    final h = H(t, rust);
    final m = Dev('M', -40, ours: true)..replies.add(const Reply(0, after: Duration(seconds: 60)));
    h.field.add(m);
    expect(await h.run(), RecoveryOutcome.recovered);
    expect(m.replays, 1);
    expect(h.store.files[nodeRecPath], rec(1));
  });

  // D10 / §4: written, no answer within 90 s -> next round; the node rotated meanwhile; the next success brings the
  // latest password (D3's "the last password"); unanswered words only if nothing was recovered
  testWidgets('§4: written and no answer -> next round; the record has the latest password', (t) async {
    final h = H(t, rust);
    final m = Dev('M', -40, ours: true)..replies.add(const Reply(0, after: Duration(seconds: 91), never: true));
    h.field.add(m);
    expect(await h.run(), RecoveryOutcome.recovered);
    expect(m.replays, 2);
    expect(m.password, 2);
    expect(h.store.files[nodeRecPath], rec(2), reason: 'the latest password, not the lost one');
  });

  testWidgets('§4: written and never answered -> the "請等幾分鐘" case is asked for', (t) async {
    final h = H(t, rust);
    final m = Dev('M', -40, ours: true)..replies.addAll(List.filled(3, const Reply(0, after: Duration(seconds: 200), never: true)));
    h.field.add(m);
    expect(await h.run(), RecoveryOutcome.exhausted);
    expect(rust.endTexts.single, contains('unanswered=true'));
    h.pendingUntouched();
  });

  // D15: an answer after the write that does not decode -> stop, 「節點回覆無法辨識」 (Rust's words), no second
  // replay. Negative control: that row -> a retry.
  testWidgets('D15: a mangled answer after the write stops, no second replay', (t) async {
    final h = H(t, rust);
    final m = Dev('M', -40, ours: true)..replies.addAll([const Reply(0, mangled: true), const Reply(0)]);
    h.field.add(m);
    expect(await h.run(), RecoveryOutcome.stopped);
    expect(m.replays, 1);
    expect(h.lines.last, '[CLAIM_FAIL] [NOT_RECOVERED] BAD_REPLY');
    h.pendingUntouched();
  });

  // ---- time limits, pacing ----

  // D11: msg2 not within 12 s -> disconnect, next device; handshakes start ≥ 10 s apart; claim/begin 7 at once (ops
  // busy, N13) -> next round. Negative controls: each limit / the pace removed.
  testWidgets('D11: no msg2 in 12 s -> disconnected at 12 s, next device; handshakes ≥ 10 s apart', (t) async {
    final h = H(t, rust);
    final silent = Dev('S', -20)..msg2Silent = true;
    final fakes = [for (var i = 1; i <= 4; i++) Dev('F$i', -30 - i)];
    h.field.add(silent);
    fakes.forEach(h.field.add);
    await h.run();
    final held = silent.closedAt.first - silent.msg1At.first;
    expect(held.inMilliseconds, inInclusiveRange(11900, 12600), reason: 'msg2 wait 12 s ($held)');
    final starts = [...silent.msg1At, for (final f in fakes) ...f.msg1At]..sort();
    for (var i = 1; i < starts.length; i++) {
      expect(starts[i] - starts[i - 1], greaterThanOrEqualTo(const Duration(seconds: 10)), reason: 'handshake $i');
    }
  });

  // D11: everything before claim/replay is written ≤ 45 s per device: a slow node (msg2, claim/begin, op/nonce 11 s
  // each) and a slow signature (9 s) -> the link goes at 45 s, no replay; next round
  testWidgets('D11: 45 s before the write, then the link goes, no replay', (t) async {
    final h = H(t, rust);
    h.plat.signDelay = const Duration(seconds: 9);
    final m = Dev('M', -40, ours: true)
      ..connectTime = const Duration(seconds: 5)
      ..msg2Delay = const Duration(seconds: 11)
      ..answerDelay = const Duration(seconds: 11);
    h.field.add(m);
    await h.run();
    expect(m.replays, 0);
    final held = m.closedAt.first - m.connectAt.first;
    expect(held.inMilliseconds, inInclusiveRange(44000, 45600), reason: '45 s from the connection ($held)');
  });

  testWidgets('D11: claim/begin 7 (ops busy) -> disconnected at once, next round', (t) async {
    final h = H(t, rust);
    final m = Dev('M', -40, ours: true)..beginCodes.addAll([7, 7]);
    h.field.add(m);
    expect(await h.run(t1: 'M'), RecoveryOutcome.recovered);
    expect(m.connects, 3);
    expect(m.replays, 1);
    expect((m.closedAt.first - m.msg1At.first).inMilliseconds, lessThan(1000));
  });

  // D6: the total limit — no new device after 300 s; a device started before it finishes
  testWidgets('D6: nothing new starts after 300 s', (t) async {
    final h = H(t, rust);
    for (var i = 1; i <= 8; i++) {
      h.field.add(Dev('D$i', -10 * i)
        ..connectTime = const Duration(milliseconds: 14900)
        ..msg2Silent = true);
    }
    expect(await h.run(), RecoveryOutcome.exhausted);
    final last = h.field.devs.values.expand((d) => d.connectAt).reduce((a, b) => a > b ? a : b);
    expect(last, lessThan(ClaimRecovery.total));
    h.pendingUntouched();
  });

  // ---- cancellation ----

  // D6: 「停止恢復」 before claim/replay is written -> the link goes at once, nothing else connects; pending kept.
  // Negative control: the cancel flag ignored -> the next device is connected.
  testWidgets('D6: stop before the write -> disconnected at once, no more connections', (t) async {
    final h = H(t, rust);
    final a = Dev('A', -20)..msg2Silent = true;
    h.field
      ..add(a)
      ..add(Dev('B', -30));
    final f = h.start();
    while (a.msg1s == 0) {
      await t.pump(const Duration(milliseconds: 250));
    }
    await t.pump(const Duration(seconds: 2));
    final at = now();
    h.rec!.cancel();
    expect(await drive(t, f), RecoveryOutcome.cancelled);
    expect(a.closedAt.single - at, lessThan(const Duration(milliseconds: 500)));
    expect(h.field.connectLog, ['A']);
    expect(h.lines.last, '[CLAIM_FAIL] 已停止恢復（紀錄先保留）');
    h.pendingUntouched();
  });

  // D6: stop AFTER the write -> this node's answer is waited for and its record written (the node already rotated)
  testWidgets('D6: stop after the write -> the answer is still taken and written', (t) async {
    final h = H(t, rust);
    final m = Dev('M', -40, ours: true)..replies.add(const Reply(0, after: Duration(seconds: 30)));
    h.field
      ..add(m)
      ..add(Dev('Z', -90));
    final f = h.start();
    while (m.replays == 0) {
      await t.pump(const Duration(milliseconds: 250));
    }
    h.rec!.cancel();
    expect(await drive(t, f), RecoveryOutcome.recovered);
    expect(h.store.files[nodeRecPath], rec(1));
    expect(h.store.files.containsKey(pendPath), isFalse);
  });

  // D6: Bluetooth turned off during the recovery -> stop at once (even after the write), pending kept
  testWidgets('D6: Bluetooth off -> stop at once, pending kept', (t) async {
    final h = H(t, rust);
    final m = Dev('M', -40, ours: true)..replies.add(const Reply(0, after: Duration(seconds: 30)));
    h.field.add(m);
    final f = h.start();
    while (m.replays == 0) {
      await t.pump(const Duration(milliseconds: 250));
    }
    final at = now();
    h.field.readyCtl.add(RecoveryBleState.off);
    expect(await drive(t, f), RecoveryOutcome.cancelled);
    expect(m.closedAt.single - at, lessThan(const Duration(milliseconds: 500)));
    expect(h.lines.last, '[CLAIM_FAIL] 藍牙已關閉，恢復已停止（紀錄先保留）。END stopped after9=false unanswered=true old=false',
        reason: 'stopped after the write: the added sentences (review m1)');
    h.pendingUntouched();
  });

  // ---- before any connection ----

  // D7: keyLevels recover off / unreadable, the ECDH refused (field build: no channel), the bridge refusing (field
  // build) -> zero connections, pending kept. Negative control: the check removed -> a connection.
  for (final c in ['recover false', 'keyLevels throws', 'ecdh error', 'prepare refuses']) {
    testWidgets('D7: $c -> no connection at all', (t) async {
      final h = H(t, rust);
      h.field.add(Dev('M', -40, ours: true));
      switch (c) {
        case 'recover false':
          h.plat.recover = false;
        case 'keyLevels throws':
          h.plat.keyLevelsThrow = true;
        case 'ecdh error':
          h.plat.ecdhError = PlatformException(code: 'ecdh', message: 'dev builds only');
        case 'prepare refuses':
          rust.prepareError = '這個版本的 app 還不能恢復中斷的認領（紀錄先保留）';
      }
      expect(await h.run(), RecoveryOutcome.notStarted);
      expect(h.field.connects, 0);
      expect(h.field.scanAt, isEmpty);
      if (c == 'ecdh error') expect(h.lines.last, '[CLAIM_FAIL] $recoverNotYet');
      if (c.startsWith('recover') || c.startsWith('keyLevels')) expect(h.plat.ecdhCalls, 0, reason: 'keys first');
      h.pendingUntouched();
    });
  }

  // D12: the pending's K is not this QR's (T1 and T2) -> zero connections, pending kept. Negative: no K check.
  for (final t1 in [true, false]) {
    testWidgets('D12: another K (${t1 ? 'T1' : 'T2'}) -> no connection', (t) async {
      final h = H(t, rust);
      h.store.kMatches = false;
      h.field.add(Dev('M', -40, ours: true));
      expect(await h.run(t1: t1 ? 'M' : null), RecoveryOutcome.notStarted);
      expect(h.field.connects, 0);
      expect(rust.prepared, isEmpty);
      h.pendingUntouched();
    });
  }

  // §3-1: one ECDH (peer = the pending's ecdh_pub, from prepare), its z handed to Rust, the session dropped at the end.
  // Dart's own z (the list handed to setZ) is all zero afterwards.
  testWidgets('§3-1: one ECDH before any connection, z reaches Rust, the session is dropped at the end', (t) async {
    final h = H(t, rust);
    h.field.add(Dev('M', -40, ours: true));
    await h.run();
    expect(h.plat.ecdhCalls, 1);
    expect(rust.last!.z, zBytes, reason: 'Rust got z');
    expect(rust.last!.zRef, everyElement(0), reason: 'review B-m3: Dart zeroed the very list it handed over');
    expect(rust.last!.disposed, isTrue, reason: 'the session (z, K) is dropped at the end');
  });

  // D14: the old node record cannot be copied aside -> the new one is still written, the pending removed
  testWidgets('D14: copy aside fails -> the node record is written anyway, pending removed', (t) async {
    final h = H(t, rust);
    h.store
      ..files[nodeRecPath] = Uint8List.fromList([0x6f])
      ..copyFails = true;
    h.field.add(Dev('M', -40, ours: true));
    expect(await h.run(), RecoveryOutcome.recovered);
    expect(h.store.calls, ['copy $nodeRecPath', 'write $nodeRecPath', 'remove $pendPath']);
    expect(h.store.files[nodeRecPath], rec(1));
    expect(h.lines.any((l) => l.startsWith('[OLD_NOT_KEPT]')), isTrue);
  });

  // The pending survives every way a recovery can end without credentials (and a failed node-record write).
  // Negative control: a "clean up the pending" on stop -> FAIL.
  testWidgets('the pending survives every non-success end', (t) async {
    final cases = <String, void Function(H)>{
      'all undecryptable': (h) => h.field.add(Dev('X', -40)),
      'nothing nearby': (h) {},
      'cert other DAC': (h) => h.field.add(Dev('M', -40, ours: true)..otherDac = true),
      'refused 3': (h) => h.field.add(Dev('M', -40, ours: true)..replies.add(const Reply(3))),
      'rate 12': (h) => h.field.add(Dev('M', -40, ours: true)..replies.add(const Reply(12))),
      'six': (h) => h.field.add(Dev('M', -40, ours: true)..replies.add(const Reply(6))),
      'lock 13 x5': (h) => h.field.add(Dev('M', -40, ours: true)..replies.addAll(List.filled(5, const Reply(13, rotates: false)))),
      'mangled': (h) => h.field.add(Dev('M', -40, ours: true)..replies.add(const Reply(0, mangled: true))),
      'never answered': (h) => h.field.add(Dev('M', -40, ours: true)..replies.addAll(List.filled(3, const Reply(0, never: true, after: Duration(seconds: 100))))),
      'busy 7': (h) => h.field.add(Dev('M', -40, ours: true)..beginCodes.addAll([7, 7, 7])),
      'nonce 4': (h) => h.field.add(Dev('M', -40, ours: true)..nonceCodes.add(4)),
      'record write fails': (h) {
        h.field.add(Dev('M', -40, ours: true));
        h.store.writeFails = true;
      },
    };
    for (final e in cases.entries) {
      final h = H(t, rust);
      e.value(h);
      final out = await h.run();
      expect(out, isNot(RecoveryOutcome.recovered), reason: e.key);
      expect(h.store.files[pendPath], pendingBytes, reason: '${e.key}: pending kept');
      expect(h.store.calls.where((c) => c.endsWith(pendPath)), isEmpty, reason: '${e.key}: pending never touched');
    }
  });

  // ---- S ----

  // S1: ten devices answering with random msg2s: each is disconnected right after its fake msg2, at most 6
  // handshakes a round. Negative control: the disconnect removed -> links stay open.
  testWidgets('S1: ten fake msg2s: each disconnected at once, ≤ 6 handshakes per round', (t) async {
    final h = H(t, rust);
    final ds = [for (var i = 0; i < 10; i++) Dev('R$i', -20 - i)];
    ds.forEach(h.field.add);
    expect(await h.run(), RecoveryOutcome.exhausted);
    for (final d in ds) {
      for (var i = 0; i < d.msg1At.length; i++) {
        expect(d.closedAt[i] - d.msg1At[i], lessThan(const Duration(milliseconds: 600)), reason: '${d.id} closed at once');
      }
      expect(d.links.every((l) => l.closed), isTrue);
    }
    final rounds = h.field.scanAt;
    for (var r = 0; r < rounds.length; r++) {
      final end = r + 1 < rounds.length ? rounds[r + 1] : const Duration(days: 1);
      final n = ds.expand((d) => d.msg1At).where((x) => x >= rounds[r] && x < end).length;
      expect(n, lessThanOrEqualTo(6), reason: 'round ${r + 1}');
    }
  });

  // S3 (Dart): no line said by a recovery carries K, z, the pending or a record, in hex or raw. Negative control: z put
  // into a line -> FAIL.
  testWidgets('S3: no secret in any line', (t) async {
    final all = <String>[];
    for (final setup in <void Function(H)>[
      (h) => h.field.add(Dev('M', -40, ours: true)),
      (h) => h.field.add(Dev('M', -40, ours: true)..replies.add(const Reply(3))),
      (h) => h.plat.ecdhError = PlatformException(code: 'ecdh', message: 'x'),
      (h) => h.field.add(Dev('X', -40)),
    ]) {
      final h = H(t, rust);
      setup(h);
      await h.run();
      all.addAll(h.lines);
    }
    expect(all.any((l) => l.contains('RECOVERED')), isTrue);
    final secrets = [hex(zBytes), hex(pendingBytes), hex(List.filled(32, 0x4b)), String.fromCharCodes(zBytes), String.fromCharCodes(List.filled(32, 0x4b)), '$zBytes',
      pwOf(1), hex(rec(1)), '${rec(1)}', '${Uint8List.fromList(rec(1))}', '${rec(1).sublist(2)}']; // review B-m3: the record and its password too
    for (final l in all) {
      for (final s in secrets) {
        expect(l.contains(s), isFalse, reason: 'a secret in "$l"');
      }
    }
  });

  // T3 is asked only in T2 with a node record; declined -> nothing connects
  testWidgets('T3: declined -> no connection, nothing written', (t) async {
    final h = H(t, rust);
    h.t3Answer = false;
    h.field.add(Dev('M', -40, ours: true));
    expect(await h.run(t3: true), RecoveryOutcome.notStarted);
    expect(h.t3Asked, 1);
    expect(h.field.connects, 0);
    h.pendingUntouched();
  });

  // ---- code review r1 ----

  // A-M1 / B-M1: transport failures end one connection, never the recovery (§4: before the write -> next device /
  // next round; after it -> no answer -> next round). Negative control: the old `catch -> stop` -> each FAILs.
  testWidgets('review M1: a strong device whose CTRL cannot be read does not stop T2', (t) async {
    final h = H(t, rust);
    h.field
      ..add(Dev('X', -20)..ctrlFails = 99)
      ..add(Dev('M', -40, ours: true));
    expect(await h.run(), RecoveryOutcome.recovered);
    expect(h.field.connectLog, ['X', 'M']);
    expect(h.lines.where((l) => l.contains('GATT')), isEmpty, reason: 'the transport error text is not shown');
  });

  for (final c in ['CTRL read fails', 'CTRL key 3 < 20', 'msg1 write fails', 'begin write fails']) {
    testWidgets('review M1 (T1): $c once -> next round recovers', (t) async {
      final h = H(t, rust);
      final m = Dev('M', -40, ours: true);
      switch (c) {
        case 'CTRL read fails':
          m.ctrlFails = 1;
        case 'CTRL key 3 < 20':
          m.ctrlTooSmall = 1;
        case 'msg1 write fails':
          m.writeFailsOn.add(0x01);
        case 'begin write fails':
          m.writeFailsOn.add(0x10);
      }
      h.field.add(m);
      expect(await h.run(t1: 'M'), RecoveryOutcome.recovered);
      expect(m.connects, 2);
      expect(m.replays, 1);
      expect(h.store.files[nodeRecPath], rec(1));
    });
  }

  // A-M1: the claim/replay frame's write fails after the node got it -> unanswered -> next round -> the record holds
  // the LATEST password (the node rotated twice); and when it did not reach the node -> the first password
  for (final reaches in [true, false]) {
    testWidgets('review M1: the claim/replay write fails (reached the node: $reaches) -> next round recovers', (t) async {
      final h = H(t, rust);
      final m = Dev('M', -40, ours: true)
        ..writeFailsOn.add(0x30)
        ..writeFailReaches = reaches;
      h.field.add(m);
      expect(await h.run(t1: 'M'), RecoveryOutcome.recovered);
      expect(m.replays, reaches ? 2 : 1);
      expect(h.store.files[nodeRecPath], rec(reaches ? 2 : 1));
    });
  }

  // A-m1: a stop while the claim/replay frame is being written -> the answer is still waited for and written.
  // Negative control: the written mark set after the write loop -> disconnected, no record (the node rotated anyway).
  testWidgets('review m1: stop during the claim/replay write -> the answer is still taken', (t) async {
    final h = H(t, rust);
    final m = Dev('M', -40, ours: true)..writeDelay = const Duration(seconds: 5);
    h.field.add(m);
    final f = h.start();
    while (h.plat.signCalls == 0) {
      await t.pump(const Duration(milliseconds: 250));
    }
    await t.pump(const Duration(seconds: 1)); // inside the 5 s write
    expect(m.replays, 0, reason: 'still writing');
    h.rec!.cancel();
    expect(await drive(t, f), RecoveryOutcome.recovered);
    expect(m.replays, 1);
    expect(h.store.files[nodeRecPath], rec(1));
  });

  // A-m1: a stop after an unanswered replay says the same added sentences (Rust's Stopped words). Negative control:
  // the added sentences dropped -> FAIL.
  testWidgets('review m1: stopped after an unanswered replay -> 「請等幾分鐘」 added', (t) async {
    final h = H(t, rust);
    final m = Dev('M', -40, ours: true)..replies.add(const Reply(0, never: true, after: Duration(seconds: 200)));
    h.field.add(m);
    final f = h.start();
    while (m.replays == 0) {
      await t.pump(const Duration(milliseconds: 250));
    }
    h.rec!.cancel();
    expect(await drive(t, f), RecoveryOutcome.cancelled);
    expect(h.lines.last, '[CLAIM_FAIL] 已停止恢復（紀錄先保留）。END stopped after9=false unanswered=true old=false');
    h.pendingUntouched();
  });

  // A-m2: the node record is written but the pending cannot be removed -> recovered (the node record counts), the
  // leftover said; never 「紀錄沒有寫成功」. Negative control: no PendingNotRemoved case -> stopped.
  testWidgets('review m2: pending not removed after the node record -> still recovered', (t) async {
    final h = H(t, rust);
    h.store.removeFails = true;
    h.field.add(Dev('M', -40, ours: true));
    expect(await h.run(), RecoveryOutcome.recovered);
    expect(h.store.files[nodeRecPath], rec(1));
    expect(h.lines.any((l) => l.startsWith('[PENDING_KEPT]')), isTrue);
    expect(h.lines.any((l) => l.contains('沒有寫成功')), isFalse);
  });

  // A-m4: every adapter state but ready stops at once, each with its own neutral words; an error of the status stream
  // = unavailable. Negative controls: no onError -> FAIL; every state said as 「藍牙已關閉」 -> FAIL.
  for (final c in ['off', 'unavailable', 'stream error']) {
    testWidgets('review m4: adapter $c -> stopped at once with its words', (t) async {
      final h = H(t, rust);
      final m = Dev('M', -40, ours: true)..msg2Silent = true;
      h.field.add(m);
      final f = h.start();
      while (m.msg1s == 0) {
        await t.pump(const Duration(milliseconds: 250));
      }
      switch (c) {
        case 'off':
          h.field.readyCtl.add(RecoveryBleState.off);
        case 'unavailable':
          h.field.readyCtl.add(RecoveryBleState.unavailable);
        case 'stream error':
          h.field.readyCtl.addError(Exception('ObserveBleStatusFailure'));
      }
      expect(await drive(t, f), RecoveryOutcome.cancelled);
      expect(h.lines.last,
          c == 'off' ? '[CLAIM_FAIL] 藍牙已關閉，恢復已停止（紀錄先保留）' : '[CLAIM_FAIL] 藍牙目前無法使用（權限、定位服務或藍牙狀態讀不到），恢復已停止（紀錄先保留）');
      expect(m.connects, 1);
      h.pendingUntouched();
    });
  }

  // A-m4: an error in the checks before any connection is not called "cannot read the pending"
  testWidgets('review m4: a failing check before any connection has its own words', (t) async {
    final h = H(t, rust);
    h.store.matchesThrows = true;
    h.field.add(Dev('M', -40, ours: true));
    expect(await h.run(), RecoveryOutcome.notStarted);
    expect(h.lines.single, startsWith('[CLAIM_FAIL] 恢復前的檢查出錯，這次不恢復（手機裡的紀錄沒有改動）'));
    expect(h.field.connects, 0);
  });

  // ---- code review r2 ----

  // A-A: the claim/replay frame's write fails (transport exception) in every round -> no answer ever came -> the
  // closing words carry the unanswered sentences. Negative control: the catch not marking unanswered -> FAIL.
  testWidgets('review r2: the claim/replay write fails in all rounds -> the unanswered words', (t) async {
    final h = H(t, rust);
    final m = Dev('M', -40, ours: true)..writeFailsOn.addAll([0x30, 0x30, 0x30]);
    h.field.add(m);
    expect(await h.run(t1: 'M'), RecoveryOutcome.exhausted);
    expect(m.replayWriteAt, hasLength(3));
    expect(rust.endTexts, ['END exhausted after9=false unanswered=true old=false']);
    h.pendingUntouched();
  });

  // A-3: a claim/replay write that never returns is bounded by the 90 s after-write limit -> ends as "no answer"
  // (unanswered), next round. Negative control: the write not raced against the 90 s -> the recovery never ends.
  testWidgets('review r2: a hung claim/replay write ends after 90 s as unanswered', (t) async {
    final h = H(t, rust);
    final m = Dev('M', -40, ours: true)..writeHangs = true;
    h.field.add(m);
    expect(await drive(t, h.start(t1: 'M'), max: const Duration(minutes: 8)), RecoveryOutcome.exhausted);
    expect(m.replayWriteAt, hasLength(3), reason: 'three rounds still fit in 300 s');
    for (var i = 0; i < 3; i++) {
      final held = m.closedAt[i] - m.replayWriteAt[i];
      expect(held.inMilliseconds, inInclusiveRange(89500, 91000), reason: 'round ${i + 1}: 90 s ($held)');
    }
    expect(rust.endTexts, ['END exhausted after9=false unanswered=true old=false']);
    h.pendingUntouched();
  });
}
