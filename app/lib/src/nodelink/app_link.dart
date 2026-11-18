// (review pr6 A-9) "nodes.dart" / "nodes.dart:<line>" below = the old console, deleted by #329 PR 6: see
// `git show c4905ed:app/lib/nodes.dart` (main before PR 6).
// #329 §4.1 / §4.2: the app's one radio, lease registry, BleGate and NodeLink, built once after the startup check.
// Monotonic time (a Stopwatch) for the core; dart:async Timers for the waits.
import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart' show debugPrint, visibleForTesting;
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart' show WidgetsBinding, WidgetsBindingObserver, AppLifecycleState;
import 'package:flutter_reactive_ble/flutter_reactive_ble.dart';

import '../../key_abilities.dart' show KeyAbilities, KeyUse;
import '../flows/owner_console.dart' show ConsolePlatform;
import '../flows/net_index.dart';
import '../rust/api/claim.dart' show storeKeepCopy, storeRemove, storeWriteSealed;
import '../rust/api/member.dart' show mnetSummary;
import '../rust/api/owner.dart' show listNodes, netSummary, storeReadSealed, storeWriteCas;
import 'ble_backend.dart';
import 'ble_gate.dart';
import 'core.dart';
import 'lease.dart';
import '../flows/sw_holds.dart';
import '../flows/team_holds.dart';
import 'node_link.dart';
import 'prober.dart';
import 'record_writer.dart';

/// #329 PR 5 R6–R8: a sealed record opened for the hint: none on disk -> null; a key error is thrown on (review A m1 /
/// R8: the hint keeps its last value), never read as 「no record」.
@visibleForTesting
Future<Uint8List?> openSealedRecord(MethodChannel platform, String records, String rel) async {
  final sealed = await storeReadSealed(dir: records, rel: rel);
  if (sealed == null) return null;
  return platform.invokeMethod<Uint8List>('open', {'sealed': sealed.sealed, 'aad': sealed.aad});
}

/// A23 (design §10, §4.3.3-6): the node records under [records] with their file's last write time, which orders them
/// (newest first). The store writes a temp file and renames it (store.rs:106-127), so each write is a new file with a
/// new time; an unreadable time counts as the oldest (0).
@visibleForTesting
List<Rec> recordsByWrite(String records, List<String> ids) => [
      for (final id in ids)
        Rec(id, () {
          try {
            return File('$records/node/$id').lastModifiedSync().millisecondsSinceEpoch;
          } catch (_) {
            return 0;
          }
        }())
    ];

class AppLink {
  AppLink._(this.ble, this.reg, this.gate, this.link, this.prober, this.writer, this.records, this.nets, this.console);

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

  /// #329 PR 4 §2.8: the software updates left half-way (memory only).
  final sw = SwHolds();

  /// #329 PR 5 §2.6: the invite a member took, and 8.4's marks (memory only).
  final invite = InviteHolds();
  final ticks = RemoveTicks();

  /// #329 PR 3 §2.6: the phone's network records, summarised for the screens (computed after the startup check and
  /// after every lease release).
  final NetIndex nets;

  /// #329 PR 3 §2.3: what OwnerConsole needs from Kotlin and the record store.
  final ConsolePlatform console;

  /// #329 PR 3 §2.7 (F41): the last line of a claim whose page was closed while it ran; the home page shows it once.
  String? lastClaimNote;

  /// #329 PR 5 §2.6: a dev / dev2 build. One writer: main sets it once, right after its startup check read the flavor
  /// and the Rust library agree (main.dart:104-107); until then false (fail-closed). Every new entry reads it here.
  bool devTrust = false;

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
    final gate = BleGate(ReactiveBackend(radio), reg, now: _now, after: _after, trace: (l) => debugPrint('BMAPP gate $l'));
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
    // #329 PR 5 R6–R8: the remove-member §3.5 hint, worked out on the read of the open node page (dev builds only)
    Future<Uint8List?> openNet(String rel) => openSealedRecord(platform, records, rel);

    final hint = HintSource(
      wanted: (id) {
        final a = _one;
        return a != null && a.devTrust && a.link.core.page == Page.node && a.link.core.pageNode == id;
      },
      netKnown: (netId) {
        final n = _one?.nets.now;
        return n != null && (n.nets.any((e) => e.view.netId == netId) || n.mnetIds.contains(netId));
      },
      openNet: openNet,
      onHint: (id, h) => _one?.link.setHint(id, h),
      // #329 PR 6 §14: before NetIndex's first computation no team section is made
      netReady: () => _one?.nets.ready ?? false,
    );
    final prober = SessionProber(
        openRecord: openRecord, ownerPub: ownerPub, signOwner: signOwner, log: log, keyError: keyError, hint: hint);
    // #329 PR 3 §2.1: a flow's login under its lease, same keys and rules, handing the session over
    final handoff =
        HandoffProber(openRecord: openRecord, ownerPub: ownerPub, signOwner: signOwner, log: log, keyError: keyError);
    Future<List<Rec>> readRecords() async => recordsByWrite(records, await listNodes(dir: records));

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
      log: link.note, // #329 PR 6 D4: a refused or failed write goes to the text log (design :342)
    );
    reg.log = link.note; // #329 PR 6 D4: a lease taken back (60 / 420 / 900 s) goes to the text log too
    // §4.3.2 (T20): the app lifecycle, app-wide (it outlives any page)
    WidgetsBinding.instance.addObserver(_Life(link));
    // §4.3.3-1: Bluetooth off / no permission are the overlay 2.3 / 2.2, at once (review pr1 A-M3 / B-M5)
    wireRadio(radio.statusStream, link);
    final nets = NetIndex(
      NetSource(
        list: (kind) => listKind(records, kind),
        open: (rel) async {
          final sealed = await storeReadSealed(dir: records, rel: rel);
          if (sealed == null) return null;
          return platform.invokeMethod<Uint8List>('open', {'sealed': sealed.sealed, 'aad': sealed.aad});
        },
        summary: (p) => netSummary(recordPlain: p),
        nodeIds: () => listNodes(dir: records),
        mnetSummary: (p) => mnetSummary(mnetPlain: p),
      ),
      log: (l) => debugPrint('BMAPP $l'),
    );
    reg.listeners.add(nets); // §2.6: computed again after every lease release
    final console = ConsolePlatform(
      seal: (plain, aad) async => (await platform.invokeMethod<Uint8List>('seal', {'plain': plain, 'aad': aad}))!,
      signOwner: signOwner,
      signAdmin: (input) async => (await platform.invokeMethod<Uint8List>('signAdmin', {'input': input}))!,
      publicKeys: () async => {
        for (final e in (await platform.invokeMapMethod<String, dynamic>('publicKeys'))!.entries) e.key: e.value as Uint8List
      },
      readRecord: (rel) async {
        // nodes.dart:738-746: plain null = none, or it does not open
        final sealed = await storeReadSealed(dir: records, rel: rel);
        if (sealed == null) return (BigInt.zero, null);
        try {
          return (sealed.generation, await platform.invokeMethod<Uint8List>('open', {'sealed': sealed.sealed, 'aad': sealed.aad}));
        } on PlatformException {
          return (sealed.generation, null);
        }
      },
      makeNetworkRefusal: () async => (await KeyAbilities.read(platform)).refusal(KeyUse.makeNetwork),
    );
    final a = _one = AppLink._(radio, reg, gate, link, prober, writer, records, nets, console);
    // #329 PR 4 security review LOW-1: an update of a node no longer on the phone (forgotten in the old console too)
    // goes with it, its upload bearer and AP credentials included
    link.changed.listen((_) => a.sw.retain(link.core.states.containsKey));
    return a;
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
