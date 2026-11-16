// #329 PR 4 §2.2: OwnerConsole's settings / leave / status page / software-update requests. Each reply rule: the
// settings only from Rust, the leave's `left`, a lost link after a `sent` write = 「結果不明」 (and before it = not sent),
// Rust's end after a sent write = 「結果不明」, the status view made on the answering session, a late answer changing
// nothing, the update's own clock, and the passphrase never leaving the request. Fake Rust session and link
// (owner_console_test's Rig).
import'dart:typed_data';

import 'package:batman_app/member_ui.dart' show joinWait, leaveUnclear, notSentLine;
import 'package:batman_app/src/flows/owner_console.dart';
import 'package:batman_app/src/rust/api/owner.dart';
import 'package:batman_app/src/rust/api/swupdate.dart';
import 'package:batman_app/src/rust/frb_generated.dart';
import 'package:flutter_test/flutter_test.dart';

import '../nodes_update_send_test.dart' show FakeRust;
import 'owner_console_test.dart' show Rig, Session;

// frames: the request's write is n, the node's answer n + 1 (EchoRadio)
const fGet = 70, fSet = 72, fSetNonce = 74, fLeave = 76, fPage = 78, fSw = 80;

const view = SettingsView(read: true, name: 'BCM2711-6c89', country: 'US', channel: 42, bwMhz: 2, apSsid: 'node-ap');

OwnerStep st(OwnerKind kind,
        {int? frame, String detail = '', bool sent = false, bool left = false, bool sw = false, SettingsView? settings}) =>
    OwnerStep(
        kind: kind,
        frames: [if (frame != null) Uint8List.fromList([frame])],
        signInput: Uint8List(1),
        detail: detail,
        record: Uint8List(2),
        rel: '',
        generation: BigInt.two,
        aad: Uint8List(1),
        expectedGen: BigInt.one,
        pollLink: false,
        hex: '',
        sas: '',
        renewed: false,
        sent: sent,
        left: left,
        waitMs: BigInt.zero,
        sendUpdate: false,
        info: Uint8List(0),
        sw: sw,
        note: '',
        loginEnd: 0,
        loginCode: BigInt.zero,
        settings: settings);

StatusView page(String sentence) => StatusView(
    color: 'yellow',
    row: 'r',
    sentence: sentence,
    lagNote: '',
    warning: '',
    nodeState: 1,
    netId: '',
    version: '',
    tech: const [],
    fresh: true,
    rateNote: '',
    unfinished: '',
    unfinishedUnderVerdict: false,
    canLeave: false);

class P4Session extends Session {
  P4Session(super.rust);
  final asked = <String>[];
  String setAnswer = 'ok'; // ok / error / ended
  bool setNonceOnly = false; // the set writes only an op/nonce (not sent) and goes silent
  int pageReads = 0;
  bool cutNext = false; // Rust's after_left: the next status view is cut once

  @override
  OwnerStep requestSettings() {
    asked.add('settings/get');
    return st(OwnerKind.write, frame: fGet);
  }

  @override
  OwnerStep requestSetAp({required String ssid, required String passphrase}) {
    asked.add('settings/set ap $ssid'); // the passphrase is never recorded here either
    return setNonceOnly ? st(OwnerKind.write, frame: fSetNonce) : st(OwnerKind.write, frame: fSet, sent: true);
  }

  @override
  OwnerStep requestSetCountry({required String country}) {
    asked.add('settings/set country $country');
    return st(OwnerKind.write, frame: fSet, sent: true);
  }

  @override
  OwnerStep requestLeaveNetwork() {
    asked.add('network/leave');
    return st(OwnerKind.write, frame: fLeave, sent: true);
  }

  @override
  OwnerStep requestStatusPage() {
    asked.add('status page');
    return st(OwnerKind.write, frame: fPage);
  }

  @override
  StatusView statusView({required bool hasNet, required bool hasMnet}) {
    pageReads++;
    final cut = cutNext;
    cutNext = false;
    return page(cut ? '這台還沒加入隊伍網路' : '這台還沒加入隊伍網路 — 請按「加入網路」 net=$hasNet mnet=$hasMnet');
  }

  @override
  OwnerStep? onFrame({required List<int> frame}) => switch (frame[0]) {
        const (fGet + 1) => st(OwnerKind.answer, detail: '目前設定：名稱 BCM2711-6c89', settings: view),
        const (fSet + 1) => switch (setAnswer) {
            'ok' => st(OwnerKind.answer, detail: '設定已更新：名稱 BCM2711-6c89', settings: view),
            'ended' => st(OwnerKind.ended, detail: '連線出錯（x）'),
            _ => st(OwnerKind.answer, detail: '[REQ_FAIL] 設定沒有成功：節點不接受這個值（代碼 2，原因 13）'),
          },
        const (fLeave + 1) => () {
            cutNext = true;
            return st(OwnerKind.answer, detail: '[LEFT] 已離開隊伍網路', left: true);
          }(),
        const (fPage + 1) => st(OwnerKind.answer, detail: '[STATUS] 狀態已更新'),
        const (fSw + 1) => st(OwnerKind.answer, sw: true),
        _ => super.onFrame(frame: frame),
      };
}

/// A software update's side, recording the clock each call got.
class FakeSwLink implements SwLink {
  final nows = <BigInt>[];
  int answers = 0;
  SwAction act(String text) => SwAction(
      kind: SwKind.show_,
      waitMs: BigInt.zero,
      note: '',
      text: text,
      tech: '',
      percent: -1,
      buttons: const [],
      ip: '',
      port: 0,
      bearerHex: '',
      size: BigInt.zero,
      payload: 0,
      uploading: false);

  @override
  OwnerStep request(OwnerSession s) => st(OwnerKind.write, frame: fSw);
  @override
  SwAction answered(OwnerSession s, BigInt now) {
    nows.add(now);
    answers++;
    return act('answered');
  }

  @override
  SwAction lost(BigInt now) {
    nows.add(now);
    return act('lost');
  }

  @override
  SwAction noLink(BigInt now) {
    nows.add(now);
    return act('noLink');
  }
}

void main() {
  final rust = FakeRust();
  setUpAll(() => RustLib.initMock(api: rust));

  Rig rig() => Rig(rust, make: P4Session.new);
  P4Session ses(Rig r) => r.session as P4Session;

  group('settings', () {
    test('get: the current values come from Rust, the text without [ANSWER]', () async {
      final r = rig();
      final a = await r.run(r.c.settings);
      expect((a.kind, a.settings, a.text), (ReplyKind.answer, view, '目前設定：名稱 BCM2711-6c89'));
      await r.c.close();
    });

    test('set ap: an answer with settings is the success; the passphrase is in no reply and no log', () async {
      final r = rig();
      final a = await r.run(() => r.c.setAp('node-ap', 'correct-horse-1'));
      expect((a.kind, a.settings), (ReplyKind.answer, view));
      expect('$a ${a.text} ${ses(r).asked}', isNot(contains('correct-horse-1')));
      await r.c.close();
    });

    test('set: an error answer has no settings (never 「已更新」)', () async {
      final r = rig();
      ses(r).setAnswer = 'error';
      final a = await r.run(() => r.c.setCountry('TW'));
      expect((a.kind, a.settings), (ReplyKind.answer, null));
      expect(a.text, startsWith('[REQ_FAIL]'));
      await r.c.close();
    });

    test('T-W3: the link lost after the sent write -> 「結果不明 — 請重新讀取設定」, not 「沒有送出」', () async {
      final r = rig();
      r.radio.silent = true;
      final f = r.run(() => r.c.setAp('node-ap', 'correct-horse-1'));
      await r.clock.run(1000);
      r.radio.drop();
      final a = await f;
      expect((a.kind, a.text), (ReplyKind.unclear, settingsUnclearLine));
      expect(a.sessionAlive, isFalse);
      await r.c.close();
    });

    test('T-W3b: the link lost before anything sent -> 「沒有寫入或送出」', () async {
      final r = rig();
      ses(r).setNonceOnly = true;
      r.radio.silent = true;
      final f = r.run(() => r.c.setAp('node-ap', 'correct-horse-1'));
      await r.clock.run(1000);
      r.radio.drop();
      final a = await f;
      expect((a.kind, a.text), (ReplyKind.notSent, notSentLine));
      await r.c.close();
    });

    test('a set waits joinWait (360 s), not the old 15 s (D2)', () async {
      final r = rig();
      r.radio.silent = true;
      var done = false;
      final f = r.c.setCountry('TW').then((x) {
        done = true;
        return x;
      });
      await r.clock.run(300000);
      expect(done, isFalse, reason: 'the node takes up to about 230 s');
      await r.clock.run(joinWait.inMilliseconds - 300000 + 1000);
      expect(done, isTrue);
      expect((await f).text, settingsUnclearLine);
      await r.c.close();
    });

    test('review C m3: Rust ends the session after the sent write -> 「結果不明」', () async {
      final r = rig();
      ses(r).setAnswer = 'ended';
      final a = await r.run(() => r.c.setAp('node-ap', 'correct-horse-1'));
      expect((a.kind, a.text), (ReplyKind.unclear, settingsUnclearLine));
      await r.c.close();
    });
  });

  group('leave and the status page', () {
    test('leave answers left; the read after it on the same session is the cut one', () async {
      final r = rig();
      final a = await r.run(() => r.c.leave(wait: joinWait, unclear: leaveUnclear));
      expect((a.kind, a.left, a.text), (ReplyKind.answer, true, '[LEFT] 已離開隊伍網路'));
      final p = await r.run(() => r.c.statusPage(hasNet: true, hasMnet: false));
      expect((p.value as StatusView).sentence, '這台還沒加入隊伍網路');
      final again = await r.run(() => r.c.statusPage(hasNet: true, hasMnet: false));
      expect((again.value as StatusView).sentence, contains('net=true mnet=false'), reason: 'cut only once');
      await r.c.close();
    });

    test('the status view is made only for the request still waiting (a late answer: nothing)', () async {
      final r = rig();
      r.radio.silent = true;
      final a = await r.run(() => r.c.statusPage(hasNet: false, hasMnet: false));
      expect(a.kind, ReplyKind.unclear);
      // the answer arrives after the wait ran out
      r.radio.tx.add([fPage + 1]);
      await r.clock.run(500);
      expect(ses(r).pageReads, 0);
      await r.c.close();
    });
  });

  group('software update', () {
    test('an answer is the update\'s next action, on the update\'s clock', () async {
      final r = rig();
      final sw = FakeSwLink();
      r.clock.t = 5; // the app clock
      final a = await r.run(() => r.c.askSw(sw, () => BigInt.from(7777), 15000));
      expect((a.text, sw.answers), ('answered', 1));
      expect(sw.nows, [BigInt.from(7777)], reason: 'the update clock, not the app clock (review D M1)');
      expect(r.c.alive, isTrue);
      await r.c.close();
    });

    test('a lost link is `lost` at once (the unclear mark), and the session is not used again', () async {
      final r = rig();
      final sw = FakeSwLink();
      r.radio.silent = true;
      final f = r.run(() => r.c.askSw(sw, () => BigInt.from(9), 340000), ms: 5000);
      await r.clock.run(1000);
      r.radio.drop();
      final a = await f;
      expect((a.text, sw.answers), ('lost', 0));
      expect(sw.nows, [BigInt.from(9)]);
      expect(r.c.alive, isFalse);
      await r.c.close();
    });

    test('a timeout is `lost`; a late answer does not reach the update', () async {
      final r = rig();
      final sw = FakeSwLink();
      r.radio.silent = true;
      final a = await r.run(() => r.c.askSw(sw, () => BigInt.one, 15000));
      expect(a.text, 'lost');
      r.radio.tx.add([fSw + 1]);
      await r.clock.run(500);
      expect(sw.answers, 0);
      await r.c.close();
    });

    test('an answer without sw (not the update\'s) is `lost`', () async {
      final r = rig();
      final sw = _NotSw();
      final a = await r.run(() => r.c.askSw(sw, () => BigInt.one, 15000));
      expect(a.text, 'lost');
      expect(r.c.alive, isFalse);
      await r.c.close();
    });
  });
}

class _NotSw extends FakeSwLink {
  @override
  OwnerStep request(OwnerSession s) => st(OwnerKind.write, frame: fPage); // answered by a plain answer
}
