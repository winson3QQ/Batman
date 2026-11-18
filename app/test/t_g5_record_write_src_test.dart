// #329 T-G5 (design §4.4, #329 PR 7 T3): the source lock on direct record writes. A key record is written or deleted
// only through RecordWriter (under a valid lease); the bridge's store-write calls — storeWrite* (storeWriteCas,
// storeWriteSealed, storeWriteMarker), storeRemove, storeKeepCopy, and the generated RustLib.instance.api.crateApi…
// functions behind them — may appear in lib/ only in the files below, each exactly the given number of times (code
// only: comments and import / export lines do not count; a tear-off counts like a call). The files and why:
//   src/nodelink/app_link.dart   4  builds RecordWriter's RecordStore (writeCas / writeSealed / remove / keepCopy)
//   src/nodelink/record_writer.dart  0  the gate itself; its store calls are injected by app_link (none direct)
//   claim_records.dart           3  the claim's writes (keepCopy, writeSealed, remove): the new credential's only copy,
//                                   written even after the raw lease was taken back (design §5.3)
//   ui/ui_state.dart             2  `ui/state-v1` (writeCas, remove): display memory, not a key record, no lease (§4.6)
//   main.dart                    1  the install marker (storeWriteMarker in _install, before any lease exists, §4.1)
//   src/rust/**                  -  the generated bridge itself (not scanned)
// A new file with such a call, or one more call in an allowed file, FAILs; so does one fewer (edit the table on purpose).
// It FAILs too when it scans nothing. Negative control: a direct storeRemove added to a new lib/ file -> FAIL.
// #329 PR 7 code review B-m2: the two public wrappers that write through those calls with any `rel` — RustClaimStore
// (claim_records.dart: sealWrite / remove / keepCopy) and RecordUiStore (ui/ui_state.dart: write / remove) — are locked
// the same way: their construction (a call, `.new` tear-off, `extends` or a typedef of the class counts) may appear in
// lib/ only in the files of [wrapperAllowed], each exactly that many times:
//   claim_records.dart  1  RustClaimStore's own constructor declaration
//   claim.dart          2  the claim (_claim) and the recovery from a claim-pending (_fromPending)
//   ui/ui_state.dart    1  RecordUiStore's own constructor declaration
//   main.dart           1  the app's one UiState (ui/state-v1, §4.6)
// (device_check/ is a separate on-device check program, not lib/.) Negative control: a new lib/ file constructing
// either wrapper -> FAIL.
// TG5_LIB=<dir> scans another lib/ tree (the dry run on main before this lock was added).
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

const allowed = {
  'src/nodelink/app_link.dart': 4,
  'src/nodelink/record_writer.dart': 0,
  'claim_records.dart': 3,
  'ui/ui_state.dart': 2,
  'main.dart': 1,
};

/// A store-write identifier: the Dart wrappers and the generated api functions, with any prefix that is not a letter
/// or digit (`_storeRemoveX`, `rust.storeRemove`, `api.crateApiClaimStoreRemove` all count).
final _write = RegExp(r'(?<![A-Za-z0-9$])(?:storeWrite\w*|storeRemove\w*|storeKeepCopy\w*|crateApi\w*Store(?:Write|Remove|KeepCopy)\w*)');

/// [src] without comments and import / export directives: what is left is code.
String codeOnly(String src) => src
    .replaceAll(RegExp(r'/\*.*?\*/', dotAll: true), '')
    .replaceAll(RegExp(r'^\s*(?:import|export)\b[^;]*;', multiLine: true), '')
    .replaceAll(RegExp(r'(^|\s)//.*$', multiLine: true), r'$1');

int writes(String src) => _write.allMatches(codeOnly(src)).length;

const wrapperAllowed = {
  'claim_records.dart': 1,
  'claim.dart': 2,
  'ui/ui_state.dart': 1,
  'main.dart': 1,
};

/// A construction of a record-writing wrapper (code review B-m2): a call (also `new` / `const`), a `.new` tear-off, a
/// subclass or a type alias of RustClaimStore / RecordUiStore.
final _wrapper = RegExp(
    r'(?<![A-Za-z0-9$_])(?:(?:RustClaimStore|RecordUiStore)\s*(?:\(|\.new\b)|(?:extends|=)\s*(?:RustClaimStore|RecordUiStore)\b)');

int wrappers(String src) => _wrapper.allMatches(codeOnly(src)).length;

void main() {
  test('the scanner counts calls, tear-offs and generated calls, not comments or imports', () {
    expect(writes("import 'a.dart' show storeRemove, storeWriteCas;\n// storeRemove(dir: d)\n/* storeKeepCopy */"), 0);
    expect(writes('f() => storeRemove(dir: d, rel: r);'), 1);
    expect(writes('final w = RecordStore(remove: storeRemove, keepCopy: rust.storeKeepCopy);'), 2);
    expect(writes('RustLib.instance.api.crateApiClaimStoreWriteSealed(dir: d); x.crateApiOwnerStoreWriteCas();'), 2);
    expect(writes('storeWriteMarker(dir: d); _storeWriteX(); storeSweep(dir: d); storeReadSealed(dir: d);'), 2);
  });

  test('B-m2: the wrapper scanner counts constructions, tear-offs, subclasses and aliases, not types or comments', () {
    expect(wrappers("import 'claim_records.dart' show RustClaimStore;\n// RustClaimStore(dir)\nfinal RustClaimStore s; RecordUiStore? u;"), 0);
    expect(wrappers('final s = RustClaimStore(dir); final u = RecordUiStore(d, p);'), 2);
    expect(wrappers('final s = new RustClaimStore (dir); const x = RecordUiStore.new;'), 2);
    expect(wrappers('class X extends RustClaimStore { X() : super(d); } typedef Y = RecordUiStore;'), 2);
    expect(wrappers('class X implements RustClaimStore {} final MyRustClaimStore z = MyRustClaimStore(d);'), 0);
  });

  test('T-G5: direct record writes only in the allowed files, exactly the allowed number of times', () {
    final root = Directory(Platform.environment['TG5_LIB'] ?? 'lib');
    expect(root.existsSync(), isTrue, reason: '${root.absolute.path} not found');
    final found = <String, int>{};
    final made = <String, int>{}; // code review B-m2: the wrappers' constructions
    var scanned = 0;
    for (final f in root.listSync(recursive: true).whereType<File>().where((f) => f.path.endsWith('.dart'))) {
      final rel = f.path.substring(root.path.length + 1).replaceAll(r'\', '/');
      if (rel.startsWith('src/rust/')) continue; // the generated bridge
      scanned++;
      final src = f.readAsStringSync();
      final n = writes(src);
      if (n > 0 || allowed.containsKey(rel)) found[rel] = n;
      final m = wrappers(src);
      if (m > 0 || wrapperAllowed.containsKey(rel)) made[rel] = m;
    }
    expect(scanned, greaterThan(40), reason: 'the scan found (almost) nothing to check');
    expect(found, allowed);
    expect(made, wrapperAllowed, reason: 'RustClaimStore / RecordUiStore constructed outside the allowed files');
    // design §4.4: UiState writes `ui/state-v1` only — each of its two write calls takes the constant uiRel
    final ui = codeOnly(File('${root.path}/ui/ui_state.dart').readAsStringSync());
    expect(RegExp(r"const uiRel = 'ui/state-v1';").hasMatch(ui), isTrue);
    expect(RegExp(r'\b(?:storeWriteCas|storeRemove)\(dir: dir, rel: uiRel[,)]').allMatches(ui).length, 2);
  });
}
