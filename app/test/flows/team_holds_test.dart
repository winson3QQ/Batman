// #329 PR 5 plan v16 §2.6 / §6 step 6: InviteHolds and RemoveTicks (T-R1's memory-only half; the pages test that
// no button depends on a mark).
import 'dart:io';

import 'package:batman_app/src/flows/team_holds.dart';
import 'package:batman_app/src/rust/api/member.dart' show InviteView;
import 'package:flutter_test/flutter_test.dart';

const inv = InviteView(netName: '第一小隊', netIdHex: 'aa', inviteHashHex: 'bb');

void main() {
  test('InviteHolds: one invite, a newer one replaces it, drop clears it; each change notifies', () {
    final h = InviteHolds();
    var n = 0;
    h.addListener(() => n++);
    expect(h.held, isNull);
    h.take('a201', inv);
    h.take('a202', inv);
    expect(h.held?.$1, 'a202');
    h.drop();
    expect(h.held, isNull);
    h.drop();
    expect(n, 3, reason: 'a drop of nothing does not notify');
  });

  test('RemoveTicks: a removal starts the marks empty and sets removedThisRun; ticks are per network', () {
    final t = RemoveTicks();
    expect(t.removedThisRun('n1'), isFalse);
    t.tick('n1', 'owner-a-0001', true);
    expect(t.handed('n1', 'owner-a-0001'), isTrue);
    expect(t.removedThisRun('n1'), isFalse, reason: 'from 「產生更新包」 alone: no removal this run');
    t.removed('n1');
    expect((t.removedThisRun('n1'), t.handedCount('n1')), (true, 0), reason: 'a new removal clears the marks');
    t.tick('n1', 'owner-b-0002', true);
    t.tick('n2', 'owner-b-0002', true);
    expect((t.handedCount('n1'), t.handedCount('n2')), (1, 1));
    t.tick('n1', 'owner-b-0002', false);
    expect(t.handed('n1', 'owner-b-0002'), isFalse);
  });

  test('RemoveTicks keys by the whole owner: two owners with the same fingerprint prefix stay apart', () {
    final t = RemoveTicks();
    const a = '04aabbccdd11', b = '04aabbccdd22'; // the same first 8 characters
    t.tick('n1', a, true);
    expect(t.handed('n1', b), isFalse);
  });

  test('T-R1: the controllers write nothing (no record writer, no UiState, no store call in the file)', () {
    final src = File('lib/src/flows/team_holds.dart')
        .readAsLinesSync()
        .where((l) => !l.trimLeft().startsWith('//'))
        .join('\n'); // code only: the comments say what is not done here
    for (final banned in ['RecordWriter', 'UiState', 'storeWrite', 'storeRemove', 'writeCas']) {
      expect(src.contains(banned), isFalse, reason: banned);
    }
  });
}
