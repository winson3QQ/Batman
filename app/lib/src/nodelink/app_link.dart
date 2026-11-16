// #329 §4.1 / §4.2: the app's one radio, lease registry, BleGate and NodeLink, built once after the startup check.
// Monotonic time (a Stopwatch) for the core; dart:async Timers for the waits.
import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart' show debugPrint, visibleForTesting;
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart' show WidgetsBinding, WidgetsBindingObserver, AppLifecycleState;
import 'package:flutter_reactive_ble/flutter_reactive_ble.dart';

import '../../key_abilities.dart' show KeyAbilities;
import '../rust/api/claim.dart' show storeKeepCopy, storeRemove, storeWriteSealed;
import '../rust/api/owner.dart' show listNodes, storeReadSealed, storeWriteCas;
import 'ble_backend.dart';
import 'ble_gate.dart';
import 'core.dart';
import 'lease.dart';
import 'node_link.dart';
import 'prober.dart';
import 'record_writer.dart';

class AppLink {
  AppLink._(this.ble, this.reg, this.gate, this.link, this.prober, this.writer, this.records);

  /// The only FlutterReactiveBle of the app (§4.2): the older pages get this one too.
  final FlutterReactiveBle ble;
  final LeaseRegistry reg;
  final BleGate gate;
  final NodeLink link;
  final SessionProber prober;

  /// §4.4: the only way to write or delete a key record (new screens).
  final RecordWriter writer;

  /// The record store directory.
  final String records;

  static AppLink? _one;
  static AppLink? get instance => _one;

  /// Tests only: the next [create] builds a new one.
  @visibleForTesting
  static void forgetForTest() => _one = null;

  static final _clock = Stopwatch()..start();
  static int _now() => _clock.elapsedMilliseconds;
  static Cancel _after(Duration d, void Function() f) {
    final t = Timer(d, f);
    return t.cancel;
  }

  /// [ble]: tests pass a fake; the app uses the platform's.
  static AppLink create({required MethodChannel platform, required String filesDir, FlutterReactiveBle? ble}) {
    final existing = _one;
    if (existing != null) return existing;
    final radio = ble ?? FlutterReactiveBle();
    final reg = LeaseRegistry(after: _after);
    final gate = BleGate(ReactiveBackend(radio), reg, now: _now, after: _after);
    final records = '$filesDir/records';
    Future<Uint8List?> openRecord(String id) async {
      final sealed = await storeReadSealed(dir: records, rel: 'node/$id');
      if (sealed == null) return null;
      return platform.invokeMethod<Uint8List>('open', {'sealed': sealed.sealed, 'aad': sealed.aad});
    }

    Future<Uint8List> ownerPub() async =>
        ((await platform.invokeMapMethod<String, dynamic>('publicKeys'))!['owner']) as Uint8List;
    Future<Uint8List> signOwner(Uint8List input) async =>
        (await platform.invokeMethod<Uint8List>('signOwner', {'input': input}))!;
    void log(String l) => debugPrint('BMAPP nl ${NodeLink.mask(l)}');
    // X26: the key gate refused a key use -> 2.4 until the app is opened again (review pr1 B-M5)
    void keyError(Object e) => keyErrorToRadio(e, _one?.link);
    final prober =
        SessionProber(openRecord: openRecord, ownerPub: ownerPub, signOwner: signOwner, log: log, keyError: keyError);
    // #329 PR 3 §2.1: a flow's login under its lease, same keys and rules, handing the session over
    final handoff =
        HandoffProber(openRecord: openRecord, ownerPub: ownerPub, signOwner: signOwner, log: log, keyError: keyError);
    Future<List<Rec>> readRecords() async {
      final ids = await listNodes(dir: records);
      // A23: the record file's last write orders the records (newest first); unreadable time = oldest
      return [
        for (final id in ids)
          Rec(id, () {
            try {
              return File('$records/node/$id').lastModifiedSync().millisecondsSinceEpoch;
            } catch (_) {
              return 0;
            }
          }())
      ];
    }

    final link = NodeLink(
      core: NodeLinkCore(const []),
      gate: gate,
      reg: reg,
      prober: prober,
      readRecords: readRecords,
      now: _now,
      after: _after,
      trace: (l) => debugPrint('BMAPP nl $l'),
      loginProber: handoff,
      // design §4.1: the keys are read live before each login
      keysOk: () async => (await KeyAbilities.read(platform)).login,
    );
    final writer = RecordWriter(
      reg,
      RecordStore(
        writeCas: (rel, g, s) => storeWriteCas(dir: records, rel: rel, expectedGen: g, sealed: s),
        writeSealed: (rel, g, s) => storeWriteSealed(dir: records, rel: rel, generation: g, sealed: s),
        remove: (rel) => storeRemove(dir: records, rel: rel),
        keepCopy: (rel) => storeKeepCopy(dir: records, rel: rel),
      ),
    );
    // §4.3.2 (T20): the app lifecycle, app-wide (it outlives any page)
    WidgetsBinding.instance.addObserver(_Life(link));
    // §4.3.3-1: Bluetooth off / no permission are the overlay 2.3 / 2.2, at once (review pr1 A-M3 / B-M5)
    wireRadio(radio.statusStream, link);
    return _one = AppLink._(radio, reg, gate, link, prober, writer, records);
  }
}

/// flutter_reactive_ble's status -> (Bluetooth on, permission granted); null = no change. unknown (the first event)
/// and locationServicesDisabled / unsupported change nothing: a scan that fails then ends by itself and is retried.
(bool?, bool?) bleStatusToRadio(BleStatus s) => switch (s) {
      BleStatus.ready => (true, true),
      BleStatus.poweredOff => (false, null),
      BleStatus.unauthorized => (null, false),
      _ => (null, null),
    };

class _Life with WidgetsBindingObserver {
  _Life(this.link);
  final NodeLink link;

  @override
  void didChangeAppLifecycleState(AppLifecycleState s) {
    debugPrint('BMAPP nodelink lifecycle ${s.name}');
    link.lifecycle(s);
  }
}

/// §4.3.3-1: the BLE status stream drives NodeLink's Bluetooth / permission preconditions (2.3 / 2.2 at once).
StreamSubscription<BleStatus> wireRadio(Stream<BleStatus> status, NodeLink link) => status.listen((s) {
      final (bt, perm) = bleStatusToRadio(s);
      if (bt != null || perm != null) link.radio(bluetooth: bt, permission: perm);
    }, onError: (Object _) {});

/// X26: a key use the phone's key gate refused -> NodeLink's key precondition (2.4 until the app is opened again).
/// Any other error is the attempt's own (no answer).
void keyErrorToRadio(Object e, NodeLink? link) {
  if (KeyAbilities.refusedBy(e) != null) link?.radio(keyOk: false);
}
