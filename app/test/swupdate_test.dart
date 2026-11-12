// 254-app-update v0.4 §8 T4 (the Dart side) / D8: the update page logs nothing, hands the AP passphrase only to
// Kotlin joinAp (and only when the current Wi-Fi does not reach the node), the bearer only to Kotlin upload; the
// Specifier network is released once when the upload stage ends; a cancel during the upload aborts the socket first.
// The Rust flow is scripted here (SwFlow); its own tests are batman-proto tests/swupd.rs and the bridge sw_tests.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:batman_app/src/rust/api/swupdate.dart';
import 'package:batman_app/swupdate.dart';

const pass = 'ap-pass-1-secret';
const bearer = 'de63f334ff58f414a57dacbfec4b9eee';

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

/// a scripted flow: start -> idle; pick -> U3; start -> the Upload; uploaded -> done
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
    return b == SwButton.cancel ? act(SwKind.send, waitMs: 15000) : act(SwKind.send, waitMs: 15000);
  }

  @override
  SwAction resume() => act(SwKind.nothing);
  @override
  SwAction keepalive() {
    calls.add('keepalive');
    return act(SwKind.nothing, uploading: true);
  }

  @override
  SwAction uploaded(SwPut r) {
    calls.add('uploaded ${r.name}');
    return act(SwKind.send, waitMs: 15000);
  }

  @override
  List<String> apCredentials() {
    calls.add('apCredentials');
    return ['batman-ap', pass];
  }
}

/// what each BLE request answers, in order (the flow's next action)
List<SwAction> answers() => [
      act(SwKind.show_, text: 'idle', buttons: [SwButton.pick]),
      act(SwKind.show_, text: 'u3', buttons: [SwButton.start, SwButton.cancel]),
      act(SwKind.upload, uploading: true),
      act(SwKind.done, text: '更新完成:1.5.14-wsl.30'),
    ];

class Rig {
  Rig({required this.direct, this.holdUpload = false});
  final bool direct;
  final bool holdUpload;
  final calls = <MethodCall>[];
  final logs = <String>[];
  final queue = answers();
  final flow = Script();
  late final hold = SwHold(flow);
  Future<void>? uploadDone;
  final _cancelled = <void Function()>[];

  Future<Object?> channel(MethodCall c) async {
    calls.add(c);
    switch (c.method) {
      case 'pickUpdateFiles':
        return [
          {'uri': 'content://m', 'size': 300, 'head': Uint8List.fromList([0xa5, 1]), 'data': Uint8List(300)},
          {'uri': 'content://p', 'size': 1000, 'head': Uint8List.fromList([0x1f, 0x8b]), 'data': Uint8List(0)},
        ];
      case 'findNodeNetwork':
        return direct;
      case 'joinAp':
        return 'ok';
      case 'upload':
        if (!holdUpload) return 'ok200';
        var done = false;
        _cancelled.add(() => done = true);
        while (!done) {
          await Future<void>.delayed(const Duration(milliseconds: 100));
        }
        return 'other';
      case 'cancelUpload':
        for (final f in _cancelled) {
          f();
        }
        return null;
      case 'uploadProgress':
        return 500;
      default:
        return null;
    }
  }
}

Future<Rig> run(WidgetTester t, Rig r, {bool tapDialog = true, bool cancelInUpload = false}) async {
  t.binding.defaultBinaryMessenger.setMockMethodCallHandler(swChannel, r.channel);
  final old = debugPrint;
  debugPrint = (String? m, {int? wrapWidth}) => r.logs.add(m ?? '');
  try {
    await runZonedPrints(r, () async {
      await t.pumpWidget(MaterialApp(
          home: SwUpdatePage(
              hold: r.hold,
              ask: (ms) async => r.queue.removeAt(0),
              onSetAp: () {},
              specifierText: 'leave the Wi-Fi')));
      Future<void> pumps([int n = 20]) async {
        for (var i = 0; i < n; i++) {
          await t.pump(const Duration(milliseconds: 200));
        }
      }

      await pumps(3);
      await t.tap(find.text('選擇更新檔'));
      await pumps(3);
      await t.tap(find.text('開始傳送'));
      await pumps(3);
      if (!r.direct && tapDialog) {
        await t.tap(find.text('繼續'));
        await pumps(3);
      }
      if (cancelInUpload) {
        await t.tap(find.text('取消'));
      }
      await pumps(80);
    });
  } finally {
    debugPrint = old;
    t.binding.defaultBinaryMessenger.setMockMethodCallHandler(swChannel, null);
  }
  return r;
}

Future<void> runZonedPrints(Rig r, Future<void> Function() body) =>
    runZoned(body, zoneSpecification: ZoneSpecification(print: (self, parent, zone, line) => r.logs.add(line)));

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
    expect(names.where((n) => n == 'cancelUpload').length, 1, reason: 'the Specifier network is released once, at the end of the upload stage');
    expect(names.indexOf('cancelUpload') > names.indexOf('upload'), isTrue);
  });

  testWidgets('D5: the current Wi-Fi reaches the node — no Specifier, the passphrase never leaves Rust', (t) async {
    final r = await run(t, Rig(direct: true));
    expect(r.flow.calls, isNot(contains('apCredentials')));
    expect(r.calls.map((c) => c.method), isNot(contains('joinAp')));
    expect(r.calls.map((c) => c.method), contains('upload'));
    expect(r.logs, isEmpty);
  });

  testWidgets('U6: cancel during the upload aborts the socket first, then the flow closes the window', (t) async {
    final r = await run(t, Rig(direct: true, holdUpload: true), cancelInUpload: true);
    final names = r.calls.map((c) => c.method).toList();
    expect(names.indexOf('cancelUpload') > names.indexOf('upload'), isTrue);
    expect(r.flow.calls, contains('press cancel'));
    expect(r.flow.calls.where((c) => c.startsWith('uploaded')), isEmpty, reason: 'a cancelled PUT result is not reported as a result');
    expect(r.logs, isEmpty);
  });
}
