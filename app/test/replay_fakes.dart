// 254-app-replay §10: the fakes the recovery tests share (not a test file itself).
//
// The node model is the one of §0 at the level the app sees it over BLE — each behaviour names its N-fact; the bytes
// themselves are tokens (the real protocol, crypto and §4's mapping are tested in Rust: batman-proto
// tests/replayflow.rs n1..n16 on the same N-facts, bridge api::replay r2 / r4 / d3 / d15 / s3):
//   N1  a node that is not ours (another node, unclaimed, another owner) answers msg1 with a msg2 that does not decrypt
//   N3  provd's cache window: our node also answers with a fake msg2 for a while (`fakeFor`)
//   N9  every success rotates the password (also when the answer never reaches the phone); 13 may leave it unchanged
//   N10 a node with a connection, or with a replay still in its helper, does not advertise (no scan result, no connect)
//   N12 the handshake budget is used up: no msg2 at all (`msg2Silent`)
//   N13 the ops channel busy: claim/begin answers 7 at once (`beginCodes`)
// Frames: msg1 [1]; msg2 ours [2], fake [3], ours but another DAC [4]; claim/begin [0x10] -> [0x11, code];
// op/nonce [0x20] -> [0x21, code]; claim/replay [0x30] -> [0x31, code, password generation], or [0x3f] (mangled).
import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:batman_app/claim_records.dart';
import 'package:batman_app/claim_recovery.dart';
import 'package:batman_app/src/rust/api/claim.dart';
import 'package:batman_app/src/rust/api/owner.dart' show SealedRecord;
import 'package:batman_app/src/rust/api/replay.dart';

const deviceId = '0000000000000c4f2a';
const pendPath = 'claim-pending/$deviceId';
const nodeRecPath = 'node/$deviceId';

/// the pending's bytes: K is 0x4b × 32 inside (S3 looks for it)
final pendingBytes = Uint8List.fromList([0xa7, ...List.filled(32, 0x4b), 0x01]);

/// what Kotlin's ECDH answers (S3 looks for it)
final zBytes = Uint8List.fromList(List.filled(32, 0x5a));

/// the fake clock: how long the test has run (fake async)
late Duration Function() now;

String hex(List<int> b) => b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();

class Reply {
  const Reply(this.code, {this.after = const Duration(milliseconds: 100), this.mangled = false, this.never = false, this.rotates});
  final int code;
  final Duration after;

  /// the answer is broken on the way (D15)
  final bool mangled;

  /// the helper works on it but the answer never comes (the phone waits ≤ 90 s)
  final bool never;

  /// does the password change (default: on success only; a 13 may or may not, N9)
  final bool? rotates;
}

class Dev {
  Dev(this.id, this.rssi, {this.ours = false});
  final String id;
  int rssi;
  final bool ours;

  bool reachable = true;
  Duration connectTime = const Duration(milliseconds: 200);
  Duration msg2Delay = const Duration(milliseconds: 100);
  bool msg2Silent = false;
  bool otherDac = false;

  /// N3: the first [fakeFor] handshakes of our node get a fake msg2
  int fakeFor = 0;
  Duration answerDelay = const Duration(milliseconds: 100);
  final beginCodes = <int>[];
  final nonceCodes = <int>[];
  final replies = <Reply>[];

  // transport failures (review A-M1 / B-M1)
  int ctrlFails = 0; // the next N MTU / CTRL reads fail
  int ctrlTooSmall = 0; // the next N CTRL key 3 < 20
  final writeFailsOn = <int>[]; // the next write of a frame starting with each byte fails (GATT 133)
  bool writeFailReaches = false; // ... after the node got it
  Duration writeDelay = Duration.zero; // the claim/replay frame takes this long to write
  bool writeHangs = false; // the claim/replay frame's write never returns (review r2 A-3)
  final replayWriteAt = <Duration>[];

  // what happened
  int connects = 0, msg1s = 0, replays = 0, password = 0;
  final msg1At = <Duration>[];
  final connectAt = <Duration>[];
  final closedAt = <Duration>[];
  final links = <FakeLink>[];
  int inHelper = 0;

  bool get advertising => links.every((l) => l.closed) && inHelper == 0; // N10

  void onWrite(List<int> f, FakeLink link) {
    switch (f[0]) {
      case 0x01:
        msg1s++;
        msg1At.add(now());
        if (msg2Silent) return; // N12
        final m2 = !ours || msg1s <= fakeFor ? 3 : (otherDac ? 4 : 2);
        Timer(msg2Delay, () => link.send([m2]));
      case 0x10:
        final c = beginCodes.isEmpty ? 0 : beginCodes.removeAt(0);
        Timer(c == 7 ? Duration.zero : answerDelay, () => link.send([0x11, c])); // N13: busy -> 7 at once
      case 0x20:
        final c = nonceCodes.isEmpty ? 0 : nonceCodes.removeAt(0);
        Timer(answerDelay, () => link.send([0x21, c]));
      case 0x30:
        replays++;
        final r = replies.isEmpty ? const Reply(0) : replies.removeAt(0);
        inHelper++;
        Timer(r.after, () {
          inHelper--;
          if (r.rotates ?? r.code == 0) password++; // N9
          if (r.never) return;
          link.send(r.mangled ? [0x3f] : [0x31, r.code, password]);
        });
    }
  }
}

class FakeLink implements RecoveryLink {
  FakeLink(this.dev);
  final Dev dev;
  final _rx = StreamController<List<int>>();
  bool closed = false;

  void send(List<int> f) {
    if (!closed) _rx.add(f);
  }

  @override
  Future<int> frameLimit() async {
    if (dev.ctrlFails > 0) {
      dev.ctrlFails--;
      throw PlatformException(code: 'ReadCharacteristicFailure', message: 'GATT 133'); // no CTRL / MTU failed
    }
    if (dev.ctrlTooSmall > 0) {
      dev.ctrlTooSmall--;
      throw '藍牙連線的封包太小，無法傳輸（12：CTRL 12，MTU 517）'; // bridge frame_limit's Err (CTRL key 3 < 20)
    }
    return 244;
  }

  @override
  Stream<List<int>> get rx => _rx.stream;
  @override
  Future<void> write(List<int> frame) async {
    if (closed) throw StateError('disconnected');
    if (frame[0] == 0x30) dev.replayWriteAt.add(now());
    if (dev.writeHangs && frame[0] == 0x30) return Completer<void>().future; // no timer: it just never returns
    if (dev.writeDelay > Duration.zero && frame[0] == 0x30) await Future<void>.delayed(dev.writeDelay);
    final i = dev.writeFailsOn.indexOf(frame[0]);
    if (i >= 0) {
      dev.writeFailsOn.removeAt(i);
      // GATT 133: the frame may or may not have reached the node (here: it did when [writeFailReaches])
      if (dev.writeFailReaches && !closed) dev.onWrite(frame, this);
      throw PlatformException(code: 'WriteCharacteristicFailure', message: 'GATT 133');
    }
    if (!closed) dev.onWrite(frame, this);
  }

  @override
  Future<void> close() async {
    if (closed) return;
    closed = true;
    dev.closedAt.add(now());
  }
}

class FakeField implements RecoveryBle {
  final devs = <String, Dev>{};
  final readyCtl = StreamController<RecoveryBleState>.broadcast();
  final scanAt = <Duration>[];
  final connectLog = <String>[];

  void add(Dev d) => devs[d.id] = d;

  @override
  Stream<RecoveryBleState> get ready => readyCtl.stream;

  @override
  Future<Map<String, int>> scan(Duration d) async {
    scanAt.add(now());
    await Future<void>.delayed(d);
    return {
      for (final v in devs.values)
        if (v.advertising && v.reachable) v.id: v.rssi // a node that is gone is not seen either
    };
  }

  @override
  Future<RecoveryLink?> connect(String id, Duration timeout) async {
    connectLog.add(id);
    final d = devs[id];
    if (d == null || !d.reachable || !d.advertising) {
      await Future<void>.delayed(timeout);
      return null;
    }
    d.connects++;
    d.connectAt.add(now());
    await Future<void>.delayed(d.connectTime);
    final l = FakeLink(d);
    d.links.add(l);
    return l;
  }

  int get connects => connectLog.length;
}

ReplayStep rstep(ReplayKind kind,
        {List<List<int>> frames = const [], ReplayNext next = ReplayNext.stop, String detail = '', List<int> record = const []}) =>
    ReplayStep(
        kind: kind,
        frames: [for (final f in frames) Uint8List.fromList(f)],
        signInput: Uint8List.fromList([9]),
        next: next,
        detail: detail,
        path: kind == ReplayKind.recovered ? nodeRecPath : '',
        record: Uint8List.fromList(record),
        pendingPath: kind == ReplayKind.recovered ? pendPath : '');

/// §4's table over the token frames, the way the Rust ReplaySession maps them (its mapping: bridge r2)
class FakeReplay implements ReplaySession {
  String stage = 'idle';
  bool dec = false;
  Uint8List? z;
  bool disposed = false;

  ReplayStep _ended(ReplayNext n, [String d = '']) {
    stage = 'over';
    return rstep(ReplayKind.ended, next: n, detail: d);
  }

  @override
  ReplayStep begin({required int frameLimit}) {
    stage = 'hello';
    dec = false;
    return rstep(ReplayKind.write, frames: [
      [1]
    ]);
  }

  @override
  ReplayStep? onFrame({required List<int> frame}) {
    final c = frame.length > 1 ? frame[1] : 0;
    switch (frame[0]) {
      case 2:
        stage = 'req';
        dec = true;
        return rstep(ReplayKind.write, frames: [
          [0x10]
        ]);
      case 3:
        return _ended(ReplayNext.undecryptable);
      case 4:
        return _ended(ReplayNext.stop, 'CERT');
      case 0x11:
        if (c == 0) {
          return rstep(ReplayKind.write, frames: [
            [0x20]
          ]);
        }
        return _ended(c == 7 || c == 10 ? ReplayNext.again : ReplayNext.stop, 'BEGIN $c');
      case 0x21:
        if (c == 0) {
          stage = 'sign';
          return rstep(ReplayKind.sign);
        }
        return _ended(c == 3 || c == 7 || c == 10 ? ReplayNext.again : ReplayNext.stop, 'NONCE $c');
      case 0x31:
        stage = 'over';
        return switch (c) {
          0 => rstep(ReplayKind.recovered, next: ReplayNext.recovered, detail: 'RECOVERED', record: rec(frame[2])),
          13 => _ended(ReplayNext.reconnect),
          12 => _ended(ReplayNext.stop, 'RATE'),
          7 || 10 => _ended(ReplayNext.again),
          _ => _ended(ReplayNext.stop, 'REFUSED $c'),
        };
      case 0x3f:
        return _ended(ReplayNext.stop, 'BAD_REPLY');
    }
    return null;
  }

  @override
  ReplayStep? signed({required List<int> der}) {
    stage = 'written';
    return rstep(ReplayKind.write, frames: [
      [0x30]
    ]);
  }

  @override
  ReplayStep lost() {
    final n = switch (stage) {
      'idle' || 'hello' || 'over' => ReplayNext.noConnection,
      _ => ReplayNext.again,
    };
    stage = 'over';
    return rstep(ReplayKind.ended, next: n);
  }

  @override
  bool written() => stage == 'written';
  @override
  bool decrypted() => dec;
  @override
  void setZ({required List<int> z}) {
    this.z = Uint8List.fromList(z);
    zRef = z; // the very list Dart handed over (Dart must zero it afterwards, §3-1)
  }

  List<int>? zRef;
  @override
  void dispose() => disposed = true;
  @override
  bool get isDisposed => disposed;
}

/// A record store in memory (path -> bytes; "sealed" = the plaintext here). Every write / remove is logged.
class FakeStore implements ClaimStore {
  final files = <String, Uint8List>{};
  final calls = <String>[];
  bool kMatches = true;
  bool copyFails = false;
  bool writeFails = false;
  bool removeFails = false;

  @override
  Future<SealedRecord?> readSealed(String rel) async {
    final f = files[rel];
    return f == null ? null : SealedRecord(generation: BigInt.one, sealed: Uint8List.fromList(f), aad: Uint8List(1));
  }

  @override
  Future<Uint8List> open(SealedRecord s) async => Uint8List.fromList(s.sealed);
  @override
  Future<bool> matches(Uint8List pendingPlain, ClaimQr qr) async {
    if (matchesThrows) throw '手機裡的認領紀錄看不懂（pending is not CBOR）';
    return kMatches;
  }

  bool matchesThrows = false;
  @override
  Future<bool> keepCopy(String rel) async {
    calls.add('copy $rel');
    if (copyFails) throw 'Io(StorageFull)';
    final f = files[rel];
    if (f == null) return false;
    files['forgotten-${rel.replaceFirst('/', '-')}'] = f;
    return true;
  }

  @override
  Future<void> sealWrite(String rel, Uint8List record) async {
    calls.add('write $rel');
    if (writeFails) throw 'Io(EIO)';
    files[rel] = Uint8List.fromList(record);
  }

  @override
  Future<void> remove(String rel) async {
    calls.add('remove $rel');
    if (removeFails) throw 'Io(EIO)';
    files.remove(rel);
  }
}

/// The platform channel as MainActivity answers it (keyLevels' full shape; ecdh; signOwner).
class FakePlatform {
  bool recover = true;
  bool keyLevelsThrow = false;
  Object? ecdhError;
  Duration signDelay = Duration.zero;
  int ecdhCalls = 0, signCalls = 0;
  Uint8List? ecdhPeer;

  Future<Object?> handle(MethodCall c) async {
    switch (c.method) {
      case 'keyLevels':
        if (keyLevelsThrow) throw PlatformException(code: 'keystore', message: 'boom');
        return {
          'RECORD_AES': 1, 'OWNER_SIGN': 1, 'ADMIN_SIGN': 1, 'OWNER_ENC': 1, 'appUsable': true, 'claim': true, 'login': true,
          'recover': recover, 'makeNetwork': true, 'softOwnerEnc': false,
        };
      case 'ecdh':
        ecdhCalls++;
        ecdhPeer = (c.arguments as Map)['peer'] as Uint8List;
        if (ecdhError != null) throw ecdhError!;
        return Uint8List.fromList(zBytes);
      case 'signOwner':
        signCalls++;
        if (signDelay > Duration.zero) await Future<void>.delayed(signDelay);
        return Uint8List(70);
    }
    return null;
  }
}

/// pump the fake clock in [step]s until [f] completes (fails after [max])
Future<T> drive<T>(WidgetTester t, Future<T> f, {Duration step = const Duration(milliseconds: 250), Duration max = const Duration(minutes: 15)}) async {
  T? r;
  Object? err;
  var done = false;
  f.then((v) {
    r = v;
    done = true;
  }, onError: (Object e) {
    err = e;
    done = true;
  });
  var spent = Duration.zero;
  while (!done && spent < max) {
    await t.pump(step);
    spent += step;
  }
  if (err != null) throw err!;
  expect(done, isTrue, reason: 'did not finish within $max');
  await t.pump(const Duration(minutes: 5)); // the fake nodes' own timers (a helper still working) run out
  return r as T;
}

/// The node record a recovery brings: a marker, the password generation, and the root password as text (S3 looks for
/// the password and for the record's bytes)
String pwOf(int gen) => 'rootpw-Zq$gen-secret';
List<int> rec(int gen) => [0x52, gen, ...pwOf(gen).codeUnits];
