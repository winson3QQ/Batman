// #329 UX plan v5.1 (docs/design/329-ux-speed-plan.md) §6: T1–T17, T19, T20 (T18 does not exist; T21 is in
// test/ui/more_pages_test.dart). The combined rig: one NodeLink, one gate, one lease registry, one radio, the real
// SessionProber / HandoffProber over a fake Rust session, OwnerConsole + OpSession.
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:batman_app/src/flows/op_session.dart';
import 'package:batman_app/src/flows/owner_console.dart';
import 'package:batman_app/src/nodelink/ble_gate.dart';
import 'package:batman_app/src/nodelink/core.dart';
import 'package:batman_app/src/nodelink/handoff.dart';
import 'package:batman_app/src/nodelink/lease.dart';
import 'package:batman_app/src/nodelink/node_link.dart';
import 'package:batman_app/src/nodelink/prober.dart';
import 'package:batman_app/src/nodelink/record_writer.dart';
import 'package:batman_app/src/rust/api/owner.dart';
import 'package:batman_app/src/rust/frb_generated.dart';
import 'package:flutter_test/flutter_test.dart';

import '../flows/owner_console_test.dart' show Session;
import '../support/fake_node.dart' show FakeRust, step, fLogin, fInfo, fStatus, netId;
import 'node_link_test.dart' show Clock;

const fGet = 60, fSetAp = 62;

/// The fake Rust session. A status read is two requests (status, then info), as Rust's is. Every call made after
/// dispose() is recorded in [KRust.late] (the tearDown of every test expects none).
class KS extends Session {
  KS(this.k) : super(k);
  final KRust k;
  int statusReqs = 0, views = 0;
  bool fresh = true;
  String row = 'r';
  final asked = <String>[];

  void _use(String what) {
    if (disposed) k.late.add(what);
  }

  @override
  OwnerStep requestStatusPage() {
    _use('requestStatusPage');
    statusReqs++;
    asked.add('status');
    return step(OwnerKind.write, frame: fStatus);
  }

  @override
  OwnerStep requestInfo() {
    _use('requestInfo');
    asked.add('info');
    return super.requestInfo();
  }

  @override
  OwnerStep requestSettings() {
    _use('requestSettings');
    asked.add('settings');
    return step(OwnerKind.write, frame: fGet);
  }

  @override
  OwnerStep requestSetAp({required String ssid, required String passphrase}) {
    _use('requestSetAp');
    asked.add('setAp');
    return step(OwnerKind.write, frame: fSetAp, sent: true);
  }

  @override
  OwnerStep? onFrame({required List<int> frame}) {
    _use('onFrame ${frame[0]}');
    if (frame[0] == fStatus + 1) return step(OwnerKind.write, frame: fInfo);
    if (frame[0] == fGet + 1) return step(OwnerKind.answer, detail: 'settings');
    if (frame[0] == fSetAp + 1) return step(OwnerKind.answer, detail: '[AP_OK]');
    return super.onFrame(frame: frame);
  }

  @override
  StatusView statusView({required bool hasNet, required bool hasMnet}) {
    _use('statusView');
    views++;
    return StatusView(
        color: 'green',
        row: row,
        sentence: 's',
        lagNote: '',
        warning: '',
        nodeState: 2,
        netId: netId,
        version: '',
        tech: const [],
        fresh: fresh,
        rateNote: '',
        unfinished: '',
        unfinishedUnderVerdict: false,
        canLeave: false);
  }

  @override
  TeamView teamView({Uint8List? recordPlain, required bool member}) {
    _use('teamView');
    return TeamView(visible: true, title: 'team $views', only: '', cards: const [], note: '', tech: const []);
  }
}

class KRust extends FakeRust {
  final sessions = <KS>[];
  final late = <String>[]; // calls into a disposed session
  @override
  (OwnerSession, OwnerStep) crateApiOwnerOwnerSessionStart(
      {required List<int> recordPlain, required List<int> ownerPub, required int frameLimit}) {
    final s = KS(this);
    sessions.add(s);
    return (s, step(OwnerKind.write, frame: fLogin));
  }
}

/// Every address is a node that answers frame n with n + 1; [hold] delays (ms on the fake clock) or silences (-1) the
/// answer to a frame code, once per entry.
class KRadio implements BleBackend {
  KRadio(this.clock);
  final Clock clock;
  final scanCtl = StreamController<String>.broadcast();
  final tx = StreamController<List<int>>.broadcast(sync: true);
  final _st = StreamController<(String, bool, int?)>.broadcast(sync: true);
  int scans = 0, connects = 0, open = 0, maxOpen = 0;
  final written = <int>[];
  final hold = <int, List<int>>{};
  StreamController<bool>? conn;
  String addr = '';
  int goneMs = 0; // the stack reports a closed link gone this long (fake clock) after the disconnect

  @override
  Stream<String> scan() {
    scans++;
    return scanCtl.stream;
  }

  @override
  Stream<bool> connect(String address, Duration timeout) {
    connects++;
    addr = address;
    late StreamController<bool> c;
    c = conn = StreamController<bool>(onCancel: () {
      if (open > 0) open--;
      if (goneMs > 0) {
        clock.after(Duration(milliseconds: goneMs), () => _st.add((address, false, null)));
      } else {
        _st.add((address, false, null));
      }
    });
    scheduleMicrotask(() {
      open++;
      if (open > maxOpen) maxOpen = open;
      c.add(true);
    });
    return c.stream;
  }

  /// The link's state stream says false / ends.
  void drop() => conn?.add(false);
  void end() => conn?.close();

  /// The stack's own disconnect line only (`linkStates`): the gate marks the link down at once, and no state event
  /// reaches a listener of the link.
  void linkDown() => _st.add((addr, false, null));

  @override
  Stream<(String, bool, int?)> get linkStates => _st.stream;
  @override
  Future<int> requestMtu(String address, int mtu) async => 247;
  @override
  Future<List<int>> read(String address, Char c) async => [0];
  @override
  Stream<List<int>> subscribe(String address, Char c) => tx.stream;
  @override
  Future<void> write(String address, Char c, List<int> value) async {
    final f = value[0];
    written.add(f);
    final h = hold[f];
    final d = (h == null || h.isEmpty) ? 0 : h.removeAt(0);
    if (d < 0) return;
    if (d == 0) {
      scheduleMicrotask(() => tx.add([f + 1]));
    } else {
      clock.after(Duration(milliseconds: d), () => tx.add([f + 1]));
    }
  }
}

/// The real SessionProber, so that a test can act between its return and `_run`'s next step (T19, T20): [onReturn]
/// runs once, synchronously, when a probe returns an outcome with a `keep`.
class Wrap implements Prober, KeptReader {
  Wrap(this.inner);
  final SessionProber inner;
  void Function(Outcome o)? onReturn;
  bool failRead = false; // the next read on a kept link completes with an error (once)

  @override
  bool Function(String id)? get keepFor => inner.keepFor;
  @override
  set keepFor(bool Function(String id)? f) => inner.keepFor = f;

  @override
  Future<Outcome> read(LoginHandoff h, {required Future<void> cancelled}) {
    if (failRead) {
      failRead = false;
      return Future.error(StateError('a reader that fails'));
    }
    return inner.read(h, cancelled: cancelled);
  }

  @override
  Future<Outcome> probe(GateLink link, String id, {required Future<void> due, required Future<void> cancelled}) async {
    final o = await inner.probe(link, id, due: due, cancelled: cancelled);
    final f = onReturn;
    if (f != null && o.keep != null) {
      onReturn = null;
      f(o);
    }
    return o;
  }
}

class KRig {
  KRig(this.rust, {this.readFinds = true, List<Rec>? recs, bool wrap = false})
      : recs = recs ?? [const Rec('Y1', 1), const Rec('Y2', 1)],
        base = rust.sessions.length {
    reg = LeaseRegistry(after: clock.after);
    gate = BleGate(radio, reg, now: () => clock.t, after: clock.after, trace: trace.add);
    Future<Uint8List?> open(String id) async => Uint8List(4);
    Future<Uint8List> pub() async => Uint8List(65);
    Future<Uint8List> sign(Uint8List i) async => Uint8List(70);
    reads = SessionProber(
      openRecord: open,
      ownerPub: pub,
      signOwner: sign,
      teamEnabled: () => true,
      hint: HintSource(
          wanted: (_) => false,
          netKnown: (_) => netKnown,
          openNet: (_) {
            final h = openHold; // held once: the hint / team step of one read waits here
            openHold = null;
            return h?.future ?? Future.value(null);
          },
          onHint: (a, b) {}),
    );
    if (wrap) wrapped = Wrap(reads);
    nl = NodeLink(
      core: NodeLinkCore(this.recs),
      gate: gate,
      reg: reg,
      prober: wrapped ?? reads,
      loginProber: HandoffProber(openRecord: open, ownerPub: pub, signOwner: sign),
      keysOk: () async {
        final f = duringKeys;
        if (f != null) await f();
        return keys;
      },
      readRecords: () async => [...this.recs],
      now: () {
        if (boomNow) {
          boomNow = false;
          throw StateError('now() throws');
        }
        return clock.t;
      },
      after: clock.after,
      wall: () {
        if (boomWall) {
          boomWall = false;
          throw StateError('wall() throws');
        }
        return DateTime.fromMillisecondsSinceEpoch(1000000 + clock.t);
      },
      trace: trace.add,
    );
    writer = RecordWriter(
        reg,
        RecordStore(
          writeCas: (rel, g, s) async => g + BigInt.one,
          writeSealed: (rel, g, s) async {},
          remove: (rel) async {},
          keepCopy: (rel) async => true,
        ));
  }
  final KRust rust;
  final bool readFinds;
  final int base; // this rig's first session in [rust.sessions]
  final clock = Clock();
  late final radio = KRadio(clock);
  final trace = <String>[];
  bool keys = true;
  Future<void> Function()? duringKeys; // runs inside keysOk(), before its answer
  bool netKnown = false;
  bool boomNow = false, boomWall = false; // NodeLink's next now() / wall() throws (once)
  Completer<Uint8List?>? openHold;
  String advAddr = 'a1';
  bool quiet = false; // the node does not advertise
  List<Rec> recs;
  late final LeaseRegistry reg;
  late final BleGate gate;
  late final SessionProber reads;
  Wrap? wrapped;
  late final NodeLink nl;
  late final RecordWriter writer;
  final handoffs = <LoginHandoff>[];
  final acqMs = <int>[]; // the real time each `acquire` of an operation took
  Lease? given; // handed out once by the next operation instead of a new lease
  void Function()? onConsoleLost; // the console's `onLost`: called at the top of its `_close`

  OwnerConsole console(Lease lease, LoginHandoff h) {
    handoffs.add(h);
    return OwnerConsole(
      h,
      lease,
      writer,
      ConsolePlatform(
        seal: (p, a) async => Uint8List(3),
        signOwner: (i) async => Uint8List(70),
        signAdmin: (i) async => Uint8List(70),
        publicKeys: () async => {'owner': Uint8List(65), 'ownerEnc': Uint8List(65), 'admin': Uint8List(65)},
        readRecord: (rel) async => (BigInt.one, Uint8List(4)),
        makeNetworkRefusal: () async => null,
      ),
      after: clock.after,
      nowMs: () => clock.t,
      askCountry: (q) async => false,
      askRemoved: (q) async => false,
      onLost: () => onConsoleLost?.call(),
    );
  }

  late final OpDeps d = OpDeps(
    acquire: (name) async {
      final g = given;
      if (g != null) {
        given = null;
        return g;
      }
      final sw = Stopwatch()..start();
      final l = await nl.acquire(name, LeaseKind.session);
      acqMs.add(sw.elapsedMilliseconds);
      return l;
    },
    busyName: () => reg.current?.name ?? '',
    login: (lease, id) => nl.loginFor(lease, id),
    console: console,
    keepScreen: (on) async {},
  );

  /// Runs the fake clock; the node advertises whenever the phone has no link to it.
  Future<void> run(int ms, {bool adv = true}) async {
    for (var t = 0; t < ms; t += 100) {
      if (adv && !quiet && radio.open == 0 && (clock.t ~/ 100) % 5 == 0) radio.scanCtl.add(advAddr);
      await clock.run(100);
    }
  }

  Future<void> until(int t, {bool adv = true}) => run(t - clock.t, adv: adv);

  /// Runs the clock until [cond] holds.
  Future<void> wait(bool Function() cond, {int max = 70000, bool adv = true, String what = ''}) async {
    for (var t = 0; t < max && !cond(); t += 100) {
      await run(100, adv: adv);
    }
    expect(cond(), isTrue, reason: 'never happened: $what\n$tr');
  }

  /// The node's page is opened and (when [readFinds]) its first read answers.
  Future<void> openPage() async {
    await nl.start(Page.node, node: 'Y1');
    await run(2500, adv: readFinds);
  }

  /// An operation started and left running; its reply lands in the returned list.
  List<OpReply> fly(OpRequests requests, {String id = 'Y1'}) {
    final r = <OpReply>[];
    unawaited(OpSession.once(d, id, '操作', requests, gone: () => false).then(r.add));
    return r;
  }

  Future<OpReply> op(OpRequests requests, {String id = 'Y1', int max = 70000}) async {
    final r = fly(requests, id: id);
    await wait(() => r.isNotEmpty, max: max, what: 'the operation ended');
    return r.single;
  }

  /// A session lease and a login under it, with no console: the link is lent.
  Future<(Lease, LoginHandoff)> lend() async {
    final l = (await nl.acquire('操作', LeaseKind.session))!;
    late LoginForResult r;
    var done = false;
    unawaited(nl.loginFor(l, 'Y1').then((x) {
      r = x;
      done = true;
    }));
    await wait(() => done, what: 'loginFor ended');
    expect(r.end, LoginForEnd.ok, reason: tr);
    return (l, r.handoff!);
  }

  KS get s0 => rust.sessions[base];
  KS sess(int i) => rust.sessions[base + i];
  int get nSessions => rust.sessions.length - base;
  String get tr => trace.join('\n');
  int get readAt => nl.core.states['Y1']!.readAt ?? -1;

  /// (links in the gate, NodeLink's kept state, the first session disposed)
  (int, KeptState?, bool) get st => (gate.links, nl.keptState, s0.disposed);
}

const gone = (0, null, true);
const parked = (1, KeptState.parked, false);

/// Runs [f] in its own error zone and returns the errors nobody handled there (what NodeLink lets go to the zone).
/// [f] must not throw (no expect inside): an error of its own future would not cross the zone and the await hangs.
Future<List<Object>> guarded(Future<void> Function() f) async {
  final errs = <Object>[];
  await runZonedGuarded(f, (e, s) => errs.add(e));
  return errs;
}

void main() {
  late KRust rust;
  setUp(() {
    rust = KRust();
    RustLib.initMock(api: rust);
  });
  tearDown(() {
    RustLib.dispose();
    expect(rust.late, isEmpty, reason: 'a call into a disposed session');
  });

  /// T1's state: the node's page is open and its first read was kept.
  Future<KRig> t1({bool readFinds = true, bool wrap = false}) async {
    final rig = KRig(rust, readFinds: readFinds, wrap: wrap);
    await rig.openPage();
    if (readFinds && !wrap) expect(rig.st, parked, reason: rig.tr);
    return rig;
  }

  test('T1: node page opened, the real SessionProber reads -> 1 link, parked, null token; a GATT call on it is refused',
      () async {
    final rig = KRig(rust);
    await rig.openPage();
    expect(rig.nl.core.states['Y1']!.kind, Kind.read, reason: rig.tr);
    expect(rig.gate.links, 1);
    expect(rig.nl.keptState, KeptState.parked);
    final k = rig.nl.kept!;
    expect(k.link.token, isNull);
    expect(() => k.link.write(Char.rx, [1]), throwsA(isA<Refused>()));
    expect(() => k.link.subscribe(Char.tx), throwsA(isA<Refused>()));
    expect(rig.s0.disposed, isFalse);
    expect(rig.radio.connects, 1);
  });

  test('T2: T1, then OpSession.once (settings) twice -> 1 connect; answered; parked again; a new handoff each lending',
      () async {
    final rig = await t1();
    final a = await rig.op((c, gone) => c.settings());
    expect(a.end, OpEnd.done, reason: '$a\n${rig.tr}');
    expect(a.reply!.text, contains('settings'));
    expect(rig.radio.connects, 1);
    expect(rig.st, parked);
    expect(rig.reg.current, isNull);
    final b = await rig.op((c, gone) => c.settings());
    expect(b.end, OpEnd.done);
    expect(b.reply!.text, contains('settings'));
    expect(rig.radio.connects, 1);
    expect(rig.handoffs.length, 2);
    expect(identical(rig.handoffs[0], rig.handoffs[1]), isFalse);
    expect(identical(rig.handoffs[0].session, rig.handoffs[1].session), isTrue);
    expect(rig.st, parked);
    expect(rig.nSessions, 1);
    // _dropAll waits in real time (Future.delayed), which the fake clock does not see: 5 s for a link nobody closes
    expect(rig.acqMs.length, 2);
    expect(rig.acqMs.every((ms) => ms < 1000), isTrue, reason: 'acquire waited for the parked link: ${rig.acqMs}');
    // a second acquire while the lease is held
    final l = (await rig.nl.acquire('甲', LeaseKind.session))!;
    expect(await rig.nl.acquire('乙', LeaseKind.session), isNull);
    expect(rig.st, parked);
    await l.release();
  });

  test('T3: on the node page with no kept link, two OpSession.once reads in a row -> 1 connect; parked after each',
      () async {
    final rig = await t1(readFinds: false);
    expect((rig.radio.connects, rig.gate.links, rig.nl.keptState), (0, 0, null));
    final a = await rig.op((c, gone) => c.settings());
    expect(a.end, OpEnd.done, reason: '$a\n${rig.tr}');
    expect(rig.st, parked);
    final b = await rig.op((c, gone) => c.info());
    expect(b.end, OpEnd.done);
    expect(b.reply!.text, contains('info'));
    expect(rig.radio.connects, 1);
    expect(rig.nSessions, 1);
    expect(rig.st, parked);
  });

  group('T4', () {
    test('(a) 60 s, then 130 s: status on the same link, no scan, no connect, fresh, readWall / team updated', () async {
      final rig = await t1();
      final scans = rig.radio.scans;
      final w0 = rig.nl.readWall['Y1'];
      final team0 = rig.nl.teams['Y1']!.view.title;
      expect(rig.s0.statusReqs, 1);
      await rig.run(61000);
      expect(rig.s0.statusReqs, 2, reason: rig.tr);
      expect((rig.radio.connects, rig.radio.scans), (1, scans));
      expect(rig.nl.core.fresh('Y1', rig.clock.t), isTrue);
      expect(rig.readAt, greaterThan(59000));
      expect(rig.nl.readWall['Y1'], isNot(w0));
      expect(rig.nl.teams['Y1']!.view.title, isNot(team0));
      expect(rig.nl.teams['Y1']!.readAt, rig.readAt);
      await rig.run(130000);
      expect(rig.s0.statusReqs, greaterThanOrEqualTo(4), reason: rig.tr);
      expect((rig.radio.connects, rig.radio.scans), (1, scans));
      expect(rig.st, parked, reason: 'still there after 190 s');
    });

    test('(b) a hung answer -> closed after 5 s and the round reads by a new connect inside its window', () async {
      final rig = await t1();
      rig.radio.hold[fStatus] = [-1];
      await rig.wait(() => rig.nl.keptState == KeptState.reading, what: 'the 60 s read');
      final t0 = rig.clock.t;
      await rig.until(t0 + 4700);
      expect(rig.nl.keptState, KeptState.reading, reason: rig.tr);
      expect(rig.s0.disposed, isFalse);
      await rig.until(t0 + 5300, adv: false);
      expect(rig.st, gone, reason: rig.tr);
      await rig.until(t0 + 25000); // the round's window is 30 s
      expect(rig.radio.connects, 2, reason: rig.tr);
      expect(rig.nSessions, 2);
      expect(rig.nl.core.fresh('Y1', rig.clock.t), isTrue);
      expect(rig.readAt, greaterThan(t0));
    });

    test('(c) fresh == false -> not a read; the link is closed and the round reads by a new connect', () async {
      final rig = await t1();
      final at = rig.readAt;
      rig.s0.fresh = false;
      await rig.wait(() => rig.s0.views == 2, adv: false, what: 'the 60 s read has its page');
      final t0 = rig.clock.t;
      await rig.run(300, adv: false);
      expect(rig.s0.statusReqs, 2, reason: rig.tr);
      expect(rig.readAt, at, reason: 'a page that is not fresh was recorded as a read');
      expect(rig.st, gone, reason: rig.tr);
      await rig.until(t0 + 25000); // the round's window is 30 s
      expect((rig.radio.connects, rig.nSessions), (2, 2), reason: rig.tr);
      expect((rig.gate.links, rig.nl.keptState), (1, KeptState.parked));
      expect(identical(rig.nl.kept!.session, rig.sess(1)), isTrue);
      expect(rig.readAt, greaterThan(t0));
    });

    test('(b2) the read has its page and is still in the hint / team step at 5 s -> closed, the late body not recorded',
        () async {
      final rig = await t1();
      final at = rig.readAt;
      rig.netKnown = true;
      rig.radio.hold[fStatus] = [3500];
      rig.openHold = Completer<Uint8List?>(); // never ends: the step's own 2 s budget is real time, not the fake clock
      await rig.wait(() => rig.nl.keptState == KeptState.reading, adv: false, what: 'the 60 s read');
      final t0 = rig.clock.t;
      await rig.until(t0 + 4700, adv: false);
      expect((rig.nl.keptState, rig.s0.views, rig.openHold), (KeptState.reading, 2, null), reason: rig.tr);
      await rig.until(t0 + 5300, adv: false);
      expect(rig.st, gone, reason: rig.tr);
      expect(rig.readAt, at, reason: 'a read that returned after its limit was recorded');
    });

    test('(b3) a reader that completes with an error -> closed; the round reads by a new connect', () async {
      final rig = await t1(wrap: true);
      expect(rig.st, parked, reason: rig.tr);
      rig.wrapped!.failRead = true;
      await rig.wait(() => !rig.wrapped!.failRead, adv: false, what: 'the 60 s read');
      final t0 = rig.clock.t;
      await rig.run(300, adv: false);
      expect(rig.st, gone, reason: rig.tr);
      await rig.until(t0 + 25000);
      expect((rig.radio.connects, rig.gate.links, rig.nl.keptState), (2, 1, KeptState.parked), reason: rig.tr);
      expect(rig.readAt, greaterThan(t0));
    });

    test('(b4) recording the read throws (review T-2) -> closed as (b3), not left reading; the next round reads',
        () async {
      final rig = await t1();
      var t0 = -1;
      rig.radio.hold[fStatus] = [500]; // the 60 s read is seen in state reading
      final errs = await guarded(() async {
        for (var i = 0; i < 700 && rig.nl.keptState != KeptState.reading; i++) {
          await rig.run(100, adv: false);
        }
        if (rig.nl.keptState != KeptState.reading) return;
        t0 = rig.clock.t;
        rig.boomWall = true; // _noteRead's wall(), in the block that takes the answer
        await rig.run(1000, adv: false);
      });
      expect(t0, greaterThan(0), reason: 'the 60 s read never started\n${rig.tr}');
      expect((rig.boomWall, errs.length, errs.every((e) => e is StateError)), (false, 1, true), reason: '$errs');
      expect(rig.st, gone, reason: rig.tr);
      // the core had taken the body before the throw: this round is over, the next one reads by a new connect
      await rig.until(t0 + 70000);
      expect((rig.radio.connects, rig.gate.links, rig.nl.keptState), (2, 1, KeptState.parked), reason: rig.tr);
      expect(rig.readAt, greaterThan(t0 + 50000));
    });

    test('(d) errorCode -> still parked, no scan and no connect; 2\' when the core makes it so', () async {
      final rig = await t1();
      final scans = rig.radio.scans;
      rig.s0.row = "2'";
      await rig.run(61000);
      expect(rig.s0.statusReqs, 2);
      expect((rig.st, rig.radio.connects, rig.radio.scans), (parked, 1, scans), reason: rig.tr);
      await rig.until(183000);
      expect((rig.st, rig.radio.connects, rig.radio.scans), (parked, 1, scans), reason: rig.tr);
      expect(rig.nl.core.states['Y1']!.view, "2'", reason: rig.tr);
    });

    test('(e) Bluetooth off then on during the read, the old body returned after the cancel -> not recorded, not parked',
        () async {
      final rig = await t1();
      final at = rig.readAt;
      rig.netKnown = true;
      final hold = rig.openHold = Completer<Uint8List?>();
      // the read has its page (statusView was called) and waits in the hint / team step
      await rig.wait(() => rig.nl.keptState == KeptState.reading && rig.s0.views == 2, adv: false, what: 'the read');
      expect(rig.openHold, isNull, reason: 'the read is not waiting in openNet');
      rig.nl.radio(bluetooth: false);
      rig.nl.radio(bluetooth: true); // a new round, and the node is its target again
      await rig.run(200, adv: false);
      expect(rig.readAt, at, reason: 'the old read was recorded in the new round');
      expect(rig.st, gone, reason: rig.tr);
      hold.complete(null);
      await rig.run(200, adv: false);
      expect(rig.readAt, at);
      expect(rig.st, gone);
    });
  });

  group('T5 parked: T1, then the page / app / record / radio goes -> 0 links, session disposed', () {
    test('setPage(home)', () async {
      final rig = await t1();
      rig.nl.setPage(Page.home);
      await rig.run(300, adv: false);
      expect(rig.st, gone);
      expect(rig.radio.maxOpen, 1);
    });
    test('setPage(other)', () async {
      final rig = await t1();
      rig.nl.setPage(Page.other);
      await rig.run(300, adv: false);
      expect(rig.st, gone);
    });
    test('setPage(node, other id)', () async {
      final rig = await t1();
      rig.nl.setPage(Page.node, node: 'Y2');
      await rig.run(300, adv: false);
      expect(rig.st, gone);
    });
    test('setPage(home) then at once setPage(node, id): the new read connects and is kept', () async {
      final rig = await t1();
      rig.nl.setPage(Page.home);
      rig.nl.setPage(Page.node, node: 'Y1');
      await rig.run(3000);
      expect(rig.s0.disposed, isTrue);
      expect((rig.radio.connects, rig.radio.maxOpen, rig.gate.links, rig.nl.keptState), (2, 1, 1, KeptState.parked),
          reason: rig.tr);
      expect(identical(rig.nl.kept!.session, rig.sess(1)), isTrue);
    });
    test('background()', () async {
      final rig = await t1();
      rig.nl.background();
      await rig.run(300, adv: false);
      expect(rig.st, gone);
    });
    test('record removed (a session lease is taken, the records change, the lease is released)', () async {
      final rig = await t1();
      final l = (await rig.nl.acquire('移除節點', LeaseKind.session))!;
      expect(rig.st, parked);
      l.writtenNodes.add('Y1');
      rig.recs.removeWhere((r) => r.id == 'Y1');
      await l.release();
      await rig.run(300, adv: false);
      expect(rig.st, gone, reason: rig.tr);
    });
    test('record removed, and another lease is held when the records come back (taken on the registry itself)',
        () async {
      final rig = await t1();
      final l = (await rig.nl.acquire('移除節點', LeaseKind.session))!;
      expect(rig.st, parked);
      rig.recs = [const Rec('Y2', 1)];
      unawaited(l.release());
      // NodeLink.acquire waits for the record read; a lease taken on the registry is how the rig gets in between
      expect(rig.reg.acquire('操作', LeaseKind.session), isNotNull);
      await rig.run(300, adv: false);
      expect(rig.st, gone, reason: rig.tr);
    });
    test('dispose()', () async {
      final rig = await t1();
      await rig.nl.dispose();
      expect(rig.st, gone);
    });
    test('radio(bluetooth: false) (the fake radio keeps the link up)', () async {
      final rig = await t1();
      rig.nl.radio(bluetooth: false);
      await rig.run(300, adv: false);
      expect(rig.st, gone);
      expect(rig.trace.where((x) => x.contains('down')), isEmpty, reason: 'the link-down listener closed it');
    });
  });

  group('T5 reading (between the status and the info request) -> 0 links, nothing recorded, nothing parked', () {
    Future<(KRig, int)> reading() async {
      final rig = await t1();
      final at = rig.readAt;
      rig.radio.hold[fInfo] = [-1];
      await rig.wait(() => rig.nl.keptState == KeptState.reading && rig.radio.written.last == fInfo,
          adv: false, what: 'the 60 s read asked for info');
      return (rig, at);
    }

    test('background()', () async {
      final (rig, at) = await reading();
      rig.nl.background();
      await rig.run(300, adv: false);
      expect(rig.st, gone, reason: rig.tr);
      expect(rig.readAt, at);
    });
    test('setPage(home)', () async {
      final (rig, at) = await reading();
      rig.nl.setPage(Page.home);
      await rig.run(300, adv: false);
      expect(rig.st, gone, reason: rig.tr);
      expect(rig.readAt, at);
    });
    test('link down', () async {
      final (rig, at) = await reading();
      rig.radio.drop();
      await rig.run(300, adv: false);
      expect(rig.st, gone, reason: rig.tr);
      expect(rig.readAt, at);
    });
  });

  group('T6: T1, link down -> 0 links; the next op succeeds by the slow path', () {
    for (final how in ['state false', 'stream done']) {
      test(how, () async {
        final rig = await t1();
        how == 'state false' ? rig.radio.drop() : rig.radio.end();
        await rig.run(300, adv: false);
        expect(rig.st, gone, reason: rig.tr);
        final a = await rig.op((c, gone) => c.settings());
        expect(a.end, OpEnd.done, reason: '$a\n${rig.tr}');
        expect(rig.radio.connects, 2);
      });
    }
  });

  group('T7: a frame nobody asked for', () {
    test('(a) while parked -> 0 links', () async {
      final rig = await t1();
      rig.radio.tx.add([99]);
      await rig.run(300, adv: false);
      expect(rig.st, gone);
    });
    test('(b) lent, right after the console cleared its handler in _close -> the held frame closes it at the park',
        () async {
      final rig = await t1();
      var sent = 0;
      // the console's onLost runs at the top of _close; a microtask from it runs at _close's first await: after the
      // handler was cleared, before the hook
      rig.onConsoleLost = () => scheduleMicrotask(() {
            sent++;
            rig.radio.tx.add([99]);
          });
      final a = await rig.op((c, gone) => c.settings());
      expect(a.end, OpEnd.done, reason: '$a\n${rig.tr}');
      expect(a.reply!.text, contains('settings'));
      expect(sent, 1);
      await rig.run(300, adv: false);
      expect(rig.st, gone, reason: rig.tr);
    });
  });

  test('T7 (c) lent, a held frame at the park, the stack reports the link gone 1 s later -> close() returns then',
      () async {
    final rig = await t1();
    final (l, h) = await rig.lend();
    rig.radio.goneMs = 1000;
    rig.radio.tx.add([99]); // nobody handles a lent link's frames here: the inbox holds it
    var closed = false;
    unawaited(h.close(reusable: true).then((_) => closed = true));
    await rig.run(500, adv: false);
    expect((closed, rig.gate.links, rig.nl.keptState), (false, 1, null), reason: rig.tr);
    await rig.run(1000, adv: false);
    expect((closed, rig.st), (true, gone), reason: rig.tr);
    await l.release();
  });

  test('T7 (d) as (c), and the planning after that close throws (review T-1) -> close() still ends without an error',
      () async {
    final rig = await t1();
    final (l, h) = await rig.lend();
    rig.radio.tx.add([99]);
    Object? end;
    final errs = await guarded(() async {
      final c = h.close(reusable: true).then<Object?>((_) => 'closed', onError: (Object e) => e);
      rig.boomNow = true; // the _pump after the link is gone
      end = await c;
    });
    expect(end, 'closed', reason: rig.tr);
    expect((rig.boomNow, errs.length, errs.every((e) => e is StateError)), (false, 1, true), reason: '$errs');
    await rig.run(300, adv: false);
    expect(rig.st, gone, reason: rig.tr);
    await l.release();
  });

  group('T8: lent, the lease goes and the holder does not close; the next round reads; then the late close', () {
    for (final how in ['taken back at 420 s', 'released']) {
      test(how, () async {
        final rig = await t1();
        final (l, h) = await rig.lend();
        expect(rig.nl.keptState, KeptState.lent);
        expect(rig.radio.connects, 1);
        if (how == 'released') {
          await l.release();
        } else {
          l.hold();
          l.pageGone();
          await rig.run(421000, adv: false);
        }
        expect(l.valid, isFalse);
        await rig.run(300, adv: false);
        expect((rig.gate.links, rig.nl.keptState), (0, null), reason: rig.tr);
        await rig.run(10000); // the round after the lease
        expect((rig.radio.connects, rig.gate.links, rig.nl.keptState), (2, 1, KeptState.parked), reason: rig.tr);
        final k = rig.nl.kept;
        expect(identical(k!.session, rig.sess(1)), isTrue);
        await h.close(reusable: true); // the old holder, late
        await rig.run(300, adv: false);
        expect((rig.gate.links, rig.nl.keptState), (1, KeptState.parked));
        expect(identical(rig.nl.kept, k), isTrue);
        expect((rig.s0.disposed, rig.sess(1).disposed), (true, false));
        expect(rig.radio.connects, 2);
      });
    }
  });

  test('T9: a console with an unclear reply closes -> 0 links', () async {
    final rig = await t1();
    rig.radio.hold[fGet] = [-1];
    final a = await rig.op((c, gone) => c.settings());
    expect(a.reply!.kind, ReplyKind.unclear, reason: '$a');
    await rig.run(300, adv: false);
    expect(rig.st, gone, reason: rig.tr);
  });

  group('T10: 0 links before the other work starts', () {
    test('raw lease acquired', () async {
      final rig = await t1();
      final l = await rig.nl.acquire('新增節點', LeaseKind.raw);
      expect(l, isNotNull);
      expect(rig.st, gone);
    });
    test('loginFor another id', () async {
      final rig = await t1();
      rig.advAddr = 'a2';
      final a = await rig.op((c, gone) => c.settings(), id: 'Y2');
      expect(a.end, OpEnd.done, reason: '$a\n${rig.tr}');
      expect(rig.s0.disposed, isTrue);
      expect((rig.radio.connects, rig.radio.maxOpen), (2, 1));
      expect(rig.gate.refused, isEmpty);
    });
  });

  test('T11: a session lease asked for while the 60 s read runs -> the read is cancelled, 0 links, the slow path',
      () async {
    final rig = await t1();
    final at = rig.readAt;
    rig.radio.hold[fInfo] = [-1];
    await rig.wait(() => rig.nl.keptState == KeptState.reading && rig.radio.written.last == fInfo,
        adv: false, what: 'the 60 s read asked for info');
    final sw = Stopwatch()..start();
    final l = await rig.nl.acquire('操作', LeaseKind.session);
    sw.stop();
    expect(l, isNotNull);
    expect(rig.st, gone, reason: rig.tr);
    expect(sw.elapsedMilliseconds, lessThan(1000), reason: 'acquire waited for a link nobody closed');
    expect(rig.readAt, at);
    rig.given = l;
    final a = await rig.op((c, gone) => c.settings());
    expect(a.end, OpEnd.done, reason: '$a\n${rig.tr}');
    expect(a.reply!.text, contains('settings'));
    expect(rig.radio.connects, 2);
    expect(rig.readAt, at, reason: 'the cancelled read was recorded');
  });

  group('T12: close(reusable: true)', () {
    bool allDisposed(KRig rig) => rust.sessions.isNotEmpty && rust.sessions.every((s) => s.disposed);

    test('(a) on the node page, nothing wrong -> parked', () async {
      final rig = await t1();
      final (l, h) = await rig.lend();
      expect(rig.nl.keptState, KeptState.lent);
      await h.close(reusable: true);
      expect(rig.st, parked);
      await l.release();
    });

    test('(b) no kept link, OpSession.once (info), background() before the login ends -> answered, 0 links', () async {
      final rig = await t1(readFinds: false);
      rig.radio.hold[fLogin] = [1000];
      final r = rig.fly((c, gone) => c.info());
      await rig.wait(() => rig.radio.written.contains(fLogin), what: 'the login was sent');
      expect(r, isEmpty);
      rig.nl.background();
      await rig.wait(() => r.isNotEmpty, what: 'the operation ended');
      expect(r.single.end, OpEnd.done, reason: '${r.single}\n${rig.tr}');
      expect(r.single.reply!.text, contains('info'));
      await rig.run(300, adv: false);
      expect((rig.gate.links, rig.nl.keptState, allDisposed(rig)), (0, null, true), reason: rig.tr);
    });

    test('(c) Page.other, OpSession.once (settings) -> answered, 0 links', () async {
      final rig = KRig(rust);
      await rig.nl.start(Page.other);
      await rig.run(2500, adv: false);
      final a = await rig.op((c, gone) => c.settings());
      expect(a.end, OpEnd.done, reason: '$a\n${rig.tr}');
      expect(a.reply!.text, contains('settings'));
      await rig.run(300, adv: false);
      expect((rig.gate.links, rig.nl.keptState, allDisposed(rig)), (0, null, true), reason: rig.tr);
    });

    test('(d) Page.home, one record, OpSession.once (info) -> answered, 0 links; the 60 s round reads by a new connect',
        () async {
      final rig = KRig(rust, recs: [const Rec('Y1', 1)]);
      await rig.nl.start(Page.home);
      await rig.run(2500);
      expect((rig.gate.links, rig.nl.keptState), (0, null), reason: 'a read on the home page is not kept');
      final a = await rig.op((c, gone) => c.info());
      expect(a.end, OpEnd.done, reason: '$a\n${rig.tr}');
      expect(a.reply!.text, contains('info'));
      await rig.run(300, adv: false);
      expect((rig.gate.links, rig.nl.keptState, allDisposed(rig)), (0, null, true), reason: rig.tr);
      final c0 = rig.radio.connects;
      await rig.run(70000);
      expect(rig.radio.connects, greaterThan(c0), reason: rig.tr);
      expect((rig.gate.links, rig.nl.keptState, allDisposed(rig)), (0, null, true), reason: rig.tr);
    });

    for (final (name, event) in <(String, void Function(KRig))>[
      ('(e) lent, then setPage(home)', (rig) => rig.nl.setPage(Page.home)),
      ('(e) lent, then setPage(node, other id)', (rig) => rig.nl.setPage(Page.node, node: 'Y2')),
      ('(e) lent, then background()', (rig) => rig.nl.background()),
      ('(f) core.blocked set while lent', (rig) => rig.nl.radio(bluetooth: false)),
    ]) {
      test('$name -> answered, 0 links', () async {
        final rig = await t1();
        rig.radio.hold[fGet] = [2000];
        final r = rig.fly((c, gone) => c.settings());
        await rig.wait(() => rig.radio.written.last == fGet, adv: false, what: 'the request is out');
        expect(rig.nl.keptState, KeptState.lent);
        event(rig);
        await rig.wait(() => r.isNotEmpty, adv: false, what: 'the operation ended');
        expect(r.single.end, OpEnd.done, reason: '${r.single}\n${rig.tr}');
        expect(r.single.reply!.text, contains('settings'), reason: '${r.single.reply!.kind}');
        await rig.run(300, adv: false);
        expect(rig.st, gone, reason: rig.tr);
        expect(rig.radio.connects, 1);
      });
    }
  });

  test('T13: source check: pass( on a BleGate is called only in node_link.dart', () {
    // `pass(` not after an identifier character: `gate.pass(`, `g.pass(` and a bare `pass(` match; `bypass(` does not
    final call = RegExp(r'(?<![A-Za-z0-9_$])pass\(');
    expect(call.hasMatch('gate.pass(l, null)'), isTrue);
    expect(call.hasMatch('  pass(l, null);'), isTrue);
    expect(call.hasMatch('bypass(x)'), isFalse);
    expect(call.hasMatch('x.compass(y)'), isFalse);
    const declaration = 'void pass(GateLink l, Token? t)';
    final hits = <String>[];
    var files = 0, declared = 0, own = 0;
    for (final f in Directory('lib').listSync(recursive: true).whereType<File>().where((f) => f.path.endsWith('.dart'))) {
      files++;
      final p = f.path.replaceAll('\\', '/');
      final lines = f.readAsLinesSync();
      for (var i = 0; i < lines.length; i++) {
        final line = lines[i];
        if (!call.hasMatch(line)) continue;
        final t = line.trimLeft();
        if (t.startsWith('//')) continue; // a comment
        if (p.endsWith('nodelink/node_link.dart')) {
          own++;
          continue;
        }
        if (p.endsWith('nodelink/ble_gate.dart') && line.contains(declaration)) {
          declared++;
          continue;
        }
        hits.add('$p:${i + 1}: ${line.trim()}');
      }
    }
    expect(files, greaterThan(20), reason: 'nothing to check: run from app/');
    expect(declared, 1, reason: 'the declaration of BleGate.pass was not found');
    expect(own, greaterThanOrEqualTo(3), reason: 'node_link.dart does not call pass(');
    expect(hits, isEmpty);
  });

  test('T14: a parked link NodeLink never closes -> after 120 s the gate closes it; the next read is kept', () async {
    final rig = await t1();
    final l = (await rig.nl.acquire('更新', LeaseKind.session))!; // held with no loginFor: no round, no read
    await rig.until(119000, adv: false);
    expect(rig.st, parked, reason: rig.tr);
    await rig.until(123500, adv: false);
    expect(rig.st, gone, reason: rig.tr);
    await l.release();
    await rig.run(10000);
    expect((rig.radio.connects, rig.gate.links, rig.nl.keptState), (2, 1, KeptState.parked), reason: rig.tr);
    expect(identical(rig.nl.kept!.session, rig.sess(1)), isTrue);
  });

  group('T15: T1, then a failed precondition, loginFor -> precondition, 0 links, no request sent', () {
    test('keysOk false', () async {
      final rig = await t1();
      rig.keys = false;
      final n = rig.radio.written.length;
      final a = await rig.op((c, gone) => c.settings());
      expect((a.end, a.login), (OpEnd.login, LoginForEnd.precondition));
      await rig.run(300, adv: false);
      expect((rig.st, rig.radio.written.length), (gone, n), reason: rig.tr);
    });
    test('the lease is released while keysOk() runs -> noLease, 0 links, no request sent', () async {
      final rig = await t1();
      final l = (await rig.nl.acquire('操作', LeaseKind.session))!;
      rig.duringKeys = () => l.release();
      final n = rig.radio.written.length;
      final r = await rig.nl.loginFor(l, 'Y1');
      expect((r.end, r.handoff), (LoginForEnd.noLease, null));
      await rig.run(300, adv: false);
      expect((rig.st, rig.radio.written.length), (gone, n), reason: rig.tr);
    });
    test('core.blocked set (on the core only: NodeLink.radio() itself closes a parked link, T5)', () async {
      final rig = await t1();
      rig.nl.core.setRadio(rig.clock.t, permission: false);
      expect(rig.st, parked);
      final n = rig.radio.written.length;
      final a = await rig.op((c, gone) => c.settings());
      expect((a.end, a.login), (OpEnd.login, LoginForEnd.precondition));
      await rig.run(300, adv: false);
      expect((rig.st, rig.radio.written.length), (gone, n), reason: rig.tr);
    });
  });

  group('T16: lent with a request out -> answered; not disposed before the holder\'s close; then 0 links', () {
    Future<(KRig, List<OpReply>)> out() async {
      final rig = await t1();
      rig.radio.hold[fGet] = [2000];
      final r = rig.fly((c, gone) => c.settings());
      await rig.wait(() => rig.radio.written.last == fGet, adv: false, what: 'the request is out');
      expect(rig.nl.keptState, KeptState.lent);
      return (rig, r);
    }

    Future<void> answered(KRig rig, List<OpReply> r) async {
      await rig.run(1000, adv: false);
      expect(rig.s0.disposed, isFalse, reason: 'disposed under the holder');
      expect(r, isEmpty);
      await rig.wait(() => r.isNotEmpty, adv: false, what: 'the operation ended');
      expect(r.single.end, OpEnd.done, reason: '${r.single}\n${rig.tr}');
      expect(r.single.reply!.text, contains('settings'), reason: '${r.single.reply!.kind} ${rig.tr}');
    }

    test('(a) background()', () async {
      final (rig, r) = await out();
      rig.nl.background();
      await answered(rig, r);
      await rig.run(300, adv: false);
      expect(rig.st, gone);
    });
    test('(b) setPage(home)', () async {
      final (rig, r) = await out();
      rig.nl.setPage(Page.home);
      await answered(rig, r);
      await rig.run(300, adv: false);
      expect(rig.st, gone);
    });
    test('(c) dispose(), not awaited before the request is answered', () async {
      final (rig, r) = await out();
      final disposed = rig.nl.dispose(); // _dropAll waits (real time) for the lent link
      await answered(rig, r);
      await disposed;
      expect(rig.st, gone);
    });
  });

  test('T17: T1, OpSession.once (setAp) -> 1 connect; after it 0 links (not reusable)', () async {
    final rig = await t1();
    final a = await rig.op((c, gone) => c.setAp('x', 'passphrase'));
    expect(a.end, OpEnd.done, reason: '$a\n${rig.tr}');
    expect(a.reply!.text, contains('[AP_OK]'));
    expect(rig.radio.connects, 1);
    await rig.run(300, adv: false);
    expect(rig.st, gone);
  });

  group('T19: the prober returned a keep, then -> 0 links, session disposed, the next round reads again', () {
    /// [event] runs between the prober's return and `_run`'s next step; [again] makes a read possible again.
    Future<void> row(void Function(KRig rig) event, FutureOr<void> Function(KRig rig) again) async {
      final rig = KRig(rust, wrap: true);
      var ran = 0;
      rig.wrapped!.onReturn = (o) {
        ran++;
        rig.quiet = true; // nothing reads again before the checks below
        event(rig);
      };
      await rig.openPage();
      expect(ran, 1, reason: 'the prober returned no keep\n${rig.tr}');
      expect(rig.radio.connects, 1);
      expect(rig.st, gone, reason: rig.tr);
      rig.quiet = false;
      await again(rig);
      await rig.run(70000);
      expect(rig.radio.connects, greaterThanOrEqualTo(2), reason: 'no read after it\n${rig.tr}');
      expect(rig.nSessions, greaterThanOrEqualTo(2));
    }

    test('(a) setPage', () => row((rig) => rig.nl.setPage(Page.home), (rig) => rig.nl.setPage(Page.node, node: 'Y1')));
    test('(b) background()', () => row((rig) => rig.nl.background(), (rig) => rig.nl.foreground()));
    test('(c) acquire', () {
      Future<Lease?>? lease;
      return row((rig) => lease = rig.nl.acquire('操作', LeaseKind.session), (rig) async => (await lease)!.release());
    });
    test('(d) radio off',
        () => row((rig) => rig.nl.radio(bluetooth: false), (rig) => rig.nl.radio(bluetooth: true)));
    test('(f) core.result returns false (the record gone from the core)', () {
      return row((rig) => rig.nl.core.setRecords([const Rec('Y2', 1)]), (rig) {
        rig.nl.core.setRecords(rig.recs);
        rig.nl.setPage(Page.node, node: 'Y1');
      });
    });
    test('(g) the link went down', () => row((rig) => rig.radio.linkDown(), (rig) {}));

    /// (e), unwrapped: the read waits in the hint / team step (openNet held); the hold ends and [n] microtask turns
    /// later [cancel] runs. Returns (links, kept state, session disposed).
    Future<(int, KeptState?, bool)> hintStep(int n, void Function(KRig rig) cancel) async {
      final rig = KRig(rust);
      rig.netKnown = true;
      final hold = rig.openHold = Completer<Uint8List?>();
      await rig.nl.start(Page.node, node: 'Y1');
      await rig.wait(() => rig.nSessions == 1 && rig.s0.views == 1, what: 'the first read has its page');
      expect(rig.openHold, isNull, reason: 'the read is not waiting in openNet');
      hold.complete(null);
      for (var i = 0; i < n; i++) {
        await null;
      }
      cancel(rig);
      await rig.run(300, adv: false);
      return rig.st;
    }

    test('(e) a cancel at every microtask turn around the end of the hint / team step: disposed, or kept', () async {
      // a session is either NodeLink's kept one or disposed: never open with nobody holding it. background() ends
      // with nothing kept at every turn; acquire() leaves a link that was already parked (a session lease).
      final seen = <String>{};
      for (var n = 0; n <= 24; n++) {
        final b = await hintStep(n, (rig) => rig.nl.background());
        expect(b, gone, reason: 'background() $n turns after the hint step ended');
        final a = await hintStep(n, (rig) => unawaited(rig.nl.acquire('操作', LeaseKind.session)));
        expect(a == gone || a == parked, isTrue, reason: 'acquire() $n turns after the hint step ended: $a');
        seen.add(a == gone ? 'gone' : 'parked');
      }
      expect(seen, {'gone', 'parked'}, reason: 'the turns did not cover both sides of the park');
    });

    test('(e) background() around the end of the hint / team step, then the foreground -> the next round reads again',
        () async {
      for (final n in [0, 24]) {
        late KRig r;
        final b = await hintStep(n, (rig) {
          r = rig;
          rig.nl.background();
        });
        expect(b, gone, reason: 'background() $n turns after the hint step ended');
        r.nl.foreground();
        await r.run(5000);
        expect(r.radio.connects, 2, reason: 'no read after the foreground ($n turns)\n${r.tr}');
      }
    });
  });

  group('T20: link down', () {
    test('(a) after the prober\'s answer and before _run parks -> 0 links; the next op by the slow path', () async {
      final rig = KRig(rust, wrap: true);
      rig.wrapped!.onReturn = (o) => rig.radio.linkDown();
      await rig.openPage();
      expect(rig.st, gone, reason: rig.tr);
      final a = await rig.op((c, gone) => c.settings());
      expect(a.end, OpEnd.done, reason: '$a\n${rig.tr}');
      expect(rig.radio.connects, 2);
    });

    test('(b) no request in flight, after _close cancelled the console\'s state subscription, before the hook',
        () async {
      final rig = await t1();
      var downs = 0;
      rig.onConsoleLost = () => scheduleMicrotask(() {
            downs++;
            rig.radio.linkDown();
          });
      final a = await rig.op((c, gone) => c.settings());
      expect(a.end, OpEnd.done, reason: '$a\n${rig.tr}');
      expect(a.reply!.text, contains('settings'));
      expect(downs, 1);
      await rig.run(300, adv: false);
      expect(rig.st, gone, reason: rig.tr);
      rig.onConsoleLost = null;
      final b = await rig.op((c, gone) => c.settings());
      expect(b.end, OpEnd.done, reason: '$b\n${rig.tr}');
      expect(rig.radio.connects, 2);
    });

    test('(c) while parked, through linkStates only -> the lending is refused, the op answered by the slow path',
        () async {
      final rig = await t1();
      rig.radio.linkDown();
      await rig.run(200, adv: false);
      expect(rig.nl.keptState, KeptState.parked, reason: 'no state event: NodeLink has not heard of it');
      expect(rig.nl.kept!.link.up, isFalse);
      final a = await rig.op((c, gone) => c.settings());
      expect(a.end, OpEnd.done, reason: '$a\n${rig.tr}');
      expect(a.reply!.text, contains('settings'));
      expect(rig.s0.disposed, isTrue);
      expect((rig.radio.connects, rig.nSessions), (2, 2));
    });
  });
}
