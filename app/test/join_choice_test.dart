// #329 §3.4 S3 / T-N2: the one 「加入網路」 button's choice (the old two buttons, 「加入網路／繼續加入」 and
// 「加入隊伍網路」), in the order of the status sentence (net/ wins). Negative control: the order swapped -> FAIL.
import 'package:batman_app/nodes.dart' show JoinChoice, joinChoice;
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('a phone that made a network joins its own, also when it holds an imported team network', () {
    expect(joinChoice(hasNet: true, hasMnet: false), JoinChoice.own);
    expect(joinChoice(hasNet: true, hasMnet: true), JoinChoice.own);
  });
  test('only an imported team network -> the member\'s join; neither -> the own path (it says there is none)', () {
    expect(joinChoice(hasNet: false, hasMnet: true), JoinChoice.member);
    expect(joinChoice(hasNet: false, hasMnet: false), JoinChoice.own);
  });
}
