// #329 §3.4 S3: the one 「加入網路」 button's choice (the old two buttons, 「加入網路／繼續加入」 and 「加入隊伍網路」).
import 'package:batman_app/nodes.dart' show JoinChoice, joinChoice;
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('a join going on in this phone\x27s network goes on, even with an imported team network', () {
    expect(joinChoice(joiningHere: true, hasMnet: true), JoinChoice.own);
    expect(joinChoice(joiningHere: true, hasMnet: false), JoinChoice.own);
  });
  test('else an imported team network -> the member\x27s join; nothing -> pick an own network', () {
    expect(joinChoice(joiningHere: false, hasMnet: true), JoinChoice.member);
    expect(joinChoice(joiningHere: false, hasMnet: false), JoinChoice.own);
  });
}
