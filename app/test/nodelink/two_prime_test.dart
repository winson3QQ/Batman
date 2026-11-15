// #329 PR 2 review A-M2: a node that answers two full rounds with only an error code turns 2' with the error answer's
// own screen data (Rust's gray 「狀態未知」), never the last body's. Negative control: 2' without s.extra = errExtra
// -> the old body stays -> FAIL.
import 'package:batman_app/src/nodelink/ble_gate.dart';
import 'package:batman_app/src/nodelink/core.dart';
import 'package:batman_app/src/nodelink/node_link.dart';
import 'package:flutter_test/flutter_test.dart';

import 'node_link_test.dart' show Radio;
import 'review_pr1_test.dart' show make;

class Script implements Prober {
  final List<Outcome> outs;
  Script(this.outs);
  @override
  Future<Outcome> probe(GateLink link, String id, {required Future<void> due, required Future<void> cancelled}) async =>
      outs.length > 1 ? outs.removeAt(0) : outs.first;
}

void main() {
  test('2\': the error answer\'s screen data replaces the last body\'s', () async {
    final radio = Radio();
    final p = Script([const Outcome(Res.body, 'green', 'BODY'), const Outcome(Res.errorCode, '', 'ERRVIEW')]);
    final (nl, clock, _, _) = make(radio, p, () async => const [Rec('Y1', 1)]);
    await nl.start(Page.home);
    for (var i = 0; i < 70; i++) {
      radio.scanCtl.add('a1'); // a node advertises all the time
      await clock.run(5000);
    }
    final s = nl.core.states['Y1']!;
    expect(s.view, "2'", reason: nl.core.log.join('\n'));
    expect(s.extra, 'ERRVIEW');
  });
}
