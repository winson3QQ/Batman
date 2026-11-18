// #329 design A23 / T-L20 (2026-11-17 audit: the test the design asked for was never written): the node records are
// ordered by their file's last write. Real files, written the way the store writes them (a temp file, then a rename:
// rust/batman-proto/src/store.rs:106-127); the core's ordering by that time is covered by the core tests.
import 'dart:io';

import 'package:batman_app/src/nodelink/app_link.dart' show recordsByWrite;
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('a23-'));
  tearDown(() => dir.deleteSync(recursive: true));

  Future<void> write(String id) async {
    final node = Directory('${dir.path}/node')..createSync(recursive: true);
    final tmp = File('${node.path}/.$id.tmp');
    await tmp.writeAsBytes([1, 2, 3], flush: true);
    await tmp.rename('${node.path}/$id');
    // a write later in time than the one before, at any file-time resolution
    await Future<void>.delayed(const Duration(milliseconds: 1100));
  }

  int timeOf(List<dynamic> recs, String id) => recs.firstWhere((r) => r.id == id).mtime as int;

  test('T-L20: the record written last is the newest; writing an older one again makes it the newest', () async {
    await write('aa01');
    await write('bb02');
    var recs = recordsByWrite(dir.path, ['aa01', 'bb02']);
    expect(timeOf(recs, 'bb02'), greaterThan(timeOf(recs, 'aa01')));
    await write('aa01'); // the store writes the whole record again
    recs = recordsByWrite(dir.path, ['aa01', 'bb02']);
    expect(timeOf(recs, 'aa01'), greaterThan(timeOf(recs, 'bb02')));
  });

  test('A23: a record whose time cannot be read counts as the oldest (0), not as an error', () async {
    await write('aa01');
    final recs = recordsByWrite(dir.path, ['aa01', 'gone']);
    expect(timeOf(recs, 'gone'), 0);
    expect(timeOf(recs, 'aa01'), greaterThan(0));
  });
}
