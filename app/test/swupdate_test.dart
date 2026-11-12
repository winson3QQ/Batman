// 254-app-update v0.4 §8 T4 (the Dart side) / D5 / D8 / U6: the update page logs nothing, hands the AP passphrase
// only to Kotlin joinAp (and only when the current Wi-Fi does not reach the node), the bearer only to Kotlin upload;
// one upload stage joins the node AP once (code review r1 A-M2 / B-M1); keepalives go out every 10 s and the PUT
// result waits for the one in flight (r1 A-M3 D2 / D8); a cancel stops every next step (r1 A-m5 / B-m3); a declined
// D5 notice is "denied" (r1 D7). The Rust flow is scripted here (SwFlow); its own tests are batman-proto
// tests/swupd.rs and the bridge sw_tests.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:batman_app/src/rust/api/swupdate.dart';
import 'package:batman_app/swupdate.dart';

const pass = 'ap-pass-1-secret';
const bearer = 'de63f334ff58f414a57dacbfec4b9eee';
const keepaliveMs = 15001; // the scripted keepalive's wait: how [Rig.ask] tells it apart

SwAction act(SwKind k, {String text = '', List<SwButton> buttons = const [], int waitMs = 0, bool uploading = false}) => SwAction(
    kind: k,
    waitMs: BigInt.from(waitMs),
    note: '',
    text: text,
    tech: '',
    percent: -1,
    buttons: buttons,
    ip: k == SwKind.upload ? '10.41.80.13' : '',
    port: k == SwKind.upload ? 8095 : 0,
    bearerHex: k == SwKind.upload ? bearer : '',
    size: BigInt.from(k == SwKind.upload ? 1000 : 0),
    payload: k == SwKind.upload ? 1 : 0,
    uploading: uploading);

/// a scripted flow: start -> idle; pick -> U3; start -> the Upload; a PUT that is not 200 -> another Upload of the same
/// stage; 200 -> done
class Script implements SwFlow {
  final calls = <String>[];
  List<SwFile>? files;
  @override
  SwAction start() {
    calls.add('start');
    return act(SwKind.send, waitMs: 15000);
  }

  @override
  SwAction picked(List<SwFile> f) {
    calls.add('picked');
    files = f;
    return act(SwKind.send, waitMs: 340000);
  }

  @override
  SwAction press(SwButton b, BigInt nowMs) {
    calls.add('press ${b.name}');
    return act(SwKind.send, waitMs: 15000);
  }

  @override
  SwAction resume() => act(SwKind.nothing);
  @override
  SwAction keepalive() {
    calls.add('keepalive');
    return act(SwKind.send, waitMs: keepaliveMs, uploading: true);
  }

  @override
  SwAction uploaded(SwPut r) {
    calls.add('uploaded ${r.name}');
    // not 200: §3.4 (status read, bulk/open) -> the next Upload of the same stage
    return act(SwKind.send, waitMs: 15000, uploading: r == SwPut.other);
  }

  @override
  List<String> apCredentials() {
    calls.add('apCredentials');
    return ['batman-ap', pass];
  }
}

class Rig {
  Rig({required this.direct, this.puts = const ['ok200'], this.putTakes = Duration.zero, this.findTakes = Duration.zero, this.answers});
  final bool direct;
  final List<String> puts;
  final Duration putTakes, findTakes;
  final List<SwAction>? answers;
  final calls = <MethodCall>[];
  final logs = <String>[];
  final events = <String>[];
  late final List<SwAction> queue = answers ??
      [
        act(SwKind.show_, text: 'idle', buttons: [SwButton.pick]),
        act(SwKind.show_, text: 'u3', buttons: [SwButton.start, SwButton.cancel]),
        act(SwKind.upload, uploading: true),
        for (var i = 1; i < puts.length; i++) act(SwKind.upload, uploading: true),
        act(SwKind.done, text: '更新完成:1.5.14-wsl.30'),
      ];
  final flow = Script();
  late final hold = SwHold(flow);
  var _put = 0;
  bool _cancelled = false;

  Future<SwAction> ask(int ms) async {
    if (ms == keepaliveMs) {
      events.add('keepalive-sent');
      await Future<void>.delayed(const Duration(seconds: 4));
      events.add('keepalive-answered');
      return act(SwKind.nothing, uploading: true);
    }
    return queue.removeAt(0);
  }

  Future<Object?> channel(MethodCall c) async {
    calls.add(c);
    switch (c.method) {
      case 'pickUpdateFiles':
        return [
          {'uri': 'content://m', 'size': 300, 'head': Uint8List.fromList([0xa5, 1]), 'data': Uint8List(300)},
          {'uri': 'content://p', 'size': 1000, 'head': Uint8List.fromList([0x1f, 0x8b]), 'data': Uint8List(0)},
        ];
      case 'findNodeNetwork':
        await Future<void>.delayed(findTakes);
        return direct;
      case 'joinAp':
        return 'ok';
      case 'upload':
        final end = DateTime.now();
        var waited = Duration.zero;
        while (waited < putTakes && !_cancelled) {
          await Future<void>.delayed(const Duration(milliseconds: 100));
          waited += const Duration(milliseconds: 100);
        }
        events.add('put-returned');
        final _ = end;
        return _cancelled ? 'other' : puts[_put++];
      case 'cancelUpload':
        _cancelled = true;
        return null;
      case 'uploadProgress':
        return 500;
      default:
        return null;
    }
  }

  int count(String m) => calls.where((c) => c.method == m).length;
}

Future<void> pumps(WidgetTester t, [int n = 20]) async {
  for (var i = 0; i < n; i++) {
    await t.pump(const Duration(milliseconds: 200));
  }
}

/// [atUpload]: what the operator does once the upload began (taps on the page)
Future<Rig> run(WidgetTester t, Rig r, {Future<void> Function()? atUpload, bool declineNotice = false}) async {
  t.binding.defaultBinaryMessenger.setMockMethodCallHandler(swChannel, r.channel);
  final old = debugPrint;
  debugPrint = (String? m, {int? wrapWidth}) => r.logs.add(m ?? '');
  try {
    await runZoned(() async {
      await t.pumpWidget(MaterialApp(home: SwUpdatePage(hold: r.hold, ask: r.ask, onSetAp: () {}, specifierText: 'leave the Wi-Fi')));
      await pumps(t, 3);
      await t.tap(find.text('選擇更新檔'));
      await pumps(t, 3);
      await t.tap(find.text('開始傳送'));
      await pumps(t, 2);
      if (atUpload != null) await atUpload();
      for (var i = 0; i < 400; i++) {
        await t.pump(const Duration(milliseconds: 200));
        final notice = find.text('leave the Wi-Fi');
        if (notice.evaluate().isNotEmpty) {
          r.events.add('notice');
          await t.tap(find.descendant(of: find.byType(AlertDialog), matching: find.text(declineNotice ? '取消' : '繼續')));
          await pumps(t, 5); // the dialog's exit animation: it is still found while it fades
        }
      }
    }, zoneSpecification: ZoneSpecification(print: (self, parent, zone, line) => r.logs.add(line)));
  } finally {
    debugPrint = old;
    t.binding.defaultBinaryMessenger.setMockMethodCallHandler(swChannel, null);
  }
  return r;
}

void main() {
  testWidgets('D8: the Specifier path — nothing logged, the passphrase only to joinAp, the bearer only to upload', (t) async {
    final r = await run(t, Rig(direct: false));
    expect(r.flow.calls, containsAllInOrder(['start', 'picked', 'press start', 'apCredentials', 'uploaded ok200']));
    expect(r.flow.files!.map((f) => f.size), [300, 1000]);
    expect(find.text('更新完成:1.5.14-wsl.30'), findsOneWidget);
    expect(r.logs, isEmpty, reason: 'the update flow logs nothing (D8): ${r.logs}');
    final names = r.calls.map((c) => c.method).toList();
    expect(names, containsAllInOrder(['pickUpdateFiles', 'findNodeNetwork', 'joinAp', 'upload', 'cancelUpload']));
    final join = r.calls.firstWhere((c) => c.method == 'joinAp');
    expect(join.arguments, {'ssid': 'batman-ap', 'pass': pass});
    final up = r.calls.firstWhere((c) => c.method == 'upload');
    expect(up.arguments, {'uri': 'content://p', 'size': 1000, 'ip': '10.41.80.13', 'port': 8095, 'bearer': bearer});
    for (final c in r.calls) {
      final s = '${c.arguments}';
      if (c.method != 'joinAp') expect(s.contains(pass), isFalse, reason: '${c.method} got the passphrase');
      if (c.method != 'upload') expect(s.contains(bearer), isFalse, reason: '${c.method} got the bearer');
    }
    expect(r.count('cancelUpload'), 1, reason: 'the Specifier network is released once, at the end of the upload stage');
    expect(names.indexOf('cancelUpload') > names.indexOf('upload'), isTrue);
  });

  testWidgets('D5: the current Wi-Fi reaches the node — no Specifier, the passphrase never leaves Rust', (t) async {
    final r = await run(t, Rig(direct: true));
    expect(r.flow.calls, isNot(contains('apCredentials')));
    expect(r.count('joinAp'), 0);
    expect(r.count('upload'), 1);
    expect(r.logs, isEmpty);
  });

  testWidgets('r1 A-M2 / B-M1: one upload stage joins the node AP once — the retry goes out on the same network', (t) async {
    final r = await run(t, Rig(direct: false, puts: ['other', 'other', 'ok200']));
    expect(r.count('upload'), 3);
    expect(r.count('joinAp'), 1, reason: 'D5: no new Specifier request between tries (TAK would drop twice each time)');
    expect(r.events.where((e) => e == 'notice').length, 1, reason: 'one D5 notice per stage');
    expect(r.flow.calls.where((c) => c == 'apCredentials').length, 1, reason: 'the passphrase passes Dart once');
    expect(r.flow.calls, containsAllInOrder(['uploaded other', 'uploaded other', 'uploaded ok200']));
    expect(r.count('cancelUpload'), 1, reason: 'released once, at the end of the stage');
    expect(r.logs, isEmpty);
  });

  testWidgets('r1 A-M3 (U6): keepalives every 10 s during the PUT; its result waits for the keepalive in flight', (t) async {
    final r = await run(t, Rig(direct: true, putTakes: const Duration(seconds: 25)));
    expect(r.events.where((e) => e == 'keepalive-sent').length, greaterThanOrEqualTo(2), reason: '${r.events}');
    final put = r.events.indexOf('put-returned');
    final lastSent = r.events.lastIndexOf('keepalive-sent');
    expect(put > lastSent, isTrue, reason: 'the PUT ended while a keepalive was in flight: ${r.events}');
    final i = r.flow.calls.indexOf('uploaded ok200');
    expect(i, greaterThan(0));
    // the PUT result went to the flow only after that keepalive answer (else prepare finds the session busy)
    expect(r.events.last, 'keepalive-answered');
    expect(r.flow.calls.where((c) => c == 'keepalive').length, r.events.where((e) => e == 'keepalive-sent').length);
  });

  testWidgets('U6: cancel during the upload aborts the socket first, then the flow closes the window', (t) async {
    final r = await run(t, Rig(direct: true, putTakes: const Duration(seconds: 60)), atUpload: () async {
      await pumps(t, 5);
      await t.tap(find.text('取消'));
    });
    final names = r.calls.map((c) => c.method).toList();
    expect(names.indexOf('cancelUpload') > names.indexOf('upload'), isTrue);
    expect(r.flow.calls, contains('press cancel'));
    expect(r.flow.calls.where((c) => c.startsWith('uploaded')), isEmpty, reason: 'a cancelled PUT result is not reported as a result');
    expect(r.logs, isEmpty);
  });

  testWidgets('r1 A-m5 / B-m3: a cancel while the network is looked up — no PUT, no join', (t) async {
    final r = await run(t, Rig(direct: true, findTakes: const Duration(seconds: 2)), atUpload: () async {
      await t.tap(find.text('取消'));
    });
    expect(r.count('findNodeNetwork'), 1);
    expect(r.count('upload'), 0, reason: 'the 126 MB PUT must not start after a cancel');
    expect(r.count('joinAp'), 0);
    expect(r.flow.calls, contains('press cancel'));
  });

  testWidgets('r1 D7: a declined D5 notice is denied — no joinAp, no PUT', (t) async {
    final r = await run(t, Rig(direct: false), declineNotice: true);
    expect(r.count('joinAp'), 0);
    expect(r.count('upload'), 0);
    expect(r.flow.calls, contains('uploaded denied'));
    expect(r.flow.calls, isNot(contains('apCredentials')));
  });
}
