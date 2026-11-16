// #329 §3.4 S3 / T-N2 (PR 2 review B-M1 / B-M2 / A-M4): the one 「加入網路」 button's choice — the old two buttons'
// paths, none of them lost. Negative controls: any case mapped to another -> FAIL.
import 'package:batman_app/nodes.dart' show JoinChoice, joinChoice;
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('only a network this phone made -> join it; only an imported team network -> the member\'s join', () {
    expect(joinChoice(hasNet: true, hasMnet: false), JoinChoice.own);
    expect(joinChoice(hasNet: false, hasMnet: true), JoinChoice.member);
  });
  test('both -> the user picks (neither path vanishes); neither -> nothing to join', () {
    expect(joinChoice(hasNet: true, hasMnet: true), JoinChoice.ask);
    expect(joinChoice(hasNet: false, hasMnet: false), JoinChoice.none);
  });
}
