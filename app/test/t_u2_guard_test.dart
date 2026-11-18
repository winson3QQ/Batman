// #329 PR 6 (review pr6-delta-C / D M-1): the T-U2 device check's guard. Its firstRun regenerates all four keys, so it
// may run only under a temporary flavor with no key and no record. The keyLevels answer shape is KeyHandlers.kt
// keyLevels: the four roles (null = no key) plus six ability booleans that are never null.
import 'package:flutter_test/flutter_test.dart';

import '../device_check/t_u2_guard.dart';

Map<String, dynamic> levels({int? record, int? owner, int? admin, int? enc}) => {
      'RECORD_AES': record, 'OWNER_SIGN': owner, 'ADMIN_SIGN': admin, 'OWNER_ENC': enc,
      // the abilities: never null (false with no key)
      'appUsable': false, 'claim': false, 'login': false, 'recover': false, 'makeNetwork': false, 'softOwnerEnc': false,
    };

void main() {
  test('a fresh temporary flavor (no key, no record) may run — the ability booleans do not count as keys', () {
    expect(tu2Refusal(flavor: 'tu2', levels: levels(), hasRecords: false), isNull);
  });

  test('any one of the four keys present -> refused, naming it', () {
    expect(tu2Refusal(flavor: 'tu2', levels: levels(owner: 2), hasRecords: false), contains('OWNER_SIGN'));
    expect(tu2Refusal(flavor: 'tu2', levels: levels(record: 2, enc: 1), hasRecords: false), contains('RECORD_AES'));
  });

  test('records present -> refused', () {
    expect(tu2Refusal(flavor: 'tu2', levels: levels(), hasRecords: true), contains('records'));
  });

  test("one of the app's own flavors (dev, dev2, field) or no flavor -> refused, even when empty", () {
    for (final f in ['dev', 'dev2', 'field', null]) {
      expect(tu2Refusal(flavor: f, levels: levels(), hasRecords: false), isNotNull, reason: '$f');
    }
  });

  test('no levels, or a role missing from the answer -> refused (fail-closed)', () {
    expect(tu2Refusal(flavor: 'tu2', levels: null, hasRecords: false), isNotNull);
    expect(tu2Refusal(flavor: 'tu2', levels: levels()..remove('OWNER_ENC'), hasRecords: false), contains('OWNER_ENC'));
  });
}
