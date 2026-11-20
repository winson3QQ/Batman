# nc.py — negative controls of the rotating-identifier app PR, run in the WSL test tree (never the worktree).
# For each mutation: apply to the WSL copy, run the named tests, expect FAIL, restore.
import io, os, subprocess, sys, time
root = os.path.expanduser('~/advid-app-test/app')
os.environ['PATH'] = os.pathsep.join([os.path.expanduser('~/flutter/bin'), os.path.expanduser('~/.cargo/bin'), os.environ['PATH']])
only = sys.argv[1:]
CORE, NL, AL = 'lib/src/nodelink/core.dart', 'lib/src/nodelink/node_link.dart', 'lib/src/nodelink/app_link.dart'
KDF, OWN = 'rust/batman-proto/src/kdf.rs', 'rust/bridge/src/api/owner.rs'
T1, T2, T3 = 'test/nodelink/adv_hint_test.dart', 'test/nodelink/adv_hint_link_test.dart', 'test/nodelink/adv_resolver_build_test.dart'

def ft(f, name=None):
    return ['flutter', 'test', '--reporter', 'expanded', f] + (['--plain-name', name] if name else [])

M = [
  ('S1 round: no like step', CORE,
   "    if (r.like[a] != id || isY[a] != null || isNot(a, id)) return false;\n    final tried",
   "    if (true) return false;\n    // ignore: dead_code\n    final tried", ft(T1, 'a round S1: a')),
  ('S1L: no like step', CORE,
   "      like[a] == id && c.isY[a] == null && !c.isNot(a, id) && (likeTried.contains(a) || likeTried.length < 2);",
   "      false && like[a] == id;", ft(T1, 'LoginFor S1L: a')),
  ('S2 round: the hint sets the memo', CORE,
   "    lastSeen[a] = now;\n    final r = _round;\n    if (r == null) return false;",
   "    lastSeen[a] = now;\n    if (hint != null) isY[a] = hint;\n    final r = _round;\n    if (r == null) return false;", ft(T1, 'a round S2')),
  ('S2L: the hint sets the memo', CORE,
   "    c.lastSeen[a] = now;\n    var news = false;\n    if (!seen.contains(a)) {",
   "    c.lastSeen[a] = now;\n    if (hint != null) c.isY[a] = hint;\n    var news = false;\n    if (!seen.contains(a)) {", ft(T1, 'LoginFor S2L')),
  ('S3 round: no cap', CORE,
   "    return tried == null || tried.contains(a) || tried.length < 2;", "    return tried == null || true;", ft(T1, 'a round S3')),
  ('S3L: no cap', CORE, "(likeTried.contains(a) || likeTried.length < 2);", "(likeTried.contains(a) || true);", ft(T1, 'LoginFor S3L')),
  ('S4: a null hint counts as like of the target', CORE,
   "    if (r.like[a] != id || isY[a] != null || isNot(a, id)) return false;",
   "    if ((r.like[a] ?? id) != id || isY[a] != null || isNot(a, id)) return false;", ['flutter', 'test', 'test/nodelink', '--exclude-tags', 'none']),
  ('S5 round: exhausted at the first silence', CORE,
   "        } else if ((r.likeTried[a.id]?.contains(a.addr) ?? false) && (r.count[a.addr] ?? 0) < p.perAddr) {",
   "        } else if (false && (r.likeTried[a.id]?.contains(a.addr) ?? false) && (r.count[a.addr] ?? 0) < p.perAddr) {", ft(T1, 'a round S5')),
  ('S5L: no silence limit', CORE, "_likes(a) && (silent[a] ?? 0) < c.p.perAddr && _ok(a)", "_likes(a) && _ok(a)", ft(T1, 'LoginFor S5L')),
  ('S6 round: the hint overrides the memos', CORE,
   "    if (r.like[a] != id || isY[a] != null || isNot(a, id)) return false;", "    if (r.like[a] != id) return false;", ft(T1, 'a round S6')),
  ('S6L: the hint overrides the memos', CORE,
   "      like[a] == id && c.isY[a] == null && !c.isNot(a, id) && (likeTried", "      like[a] == id && (likeTried", ft(T1, 'LoginFor S6L')),
  ('S7: first sightings only', NL,
   "        if (core.onScan(now(), address, hint: _hint(mfr)) && _attempt == null) _pump();",
   "        if (!core.lastSeen.containsKey(address) && core.onScan(now(), address, hint: _hint(mfr)) && _attempt == null) _pump();", ft(T2, 'S7: every')),
  ('S7 loginFor: the early hints are dropped at the replay', NL,
   "      l.onScan(now(), e.key, hint: e.value);", "      l.onScan(now(), e.key);", ft(T2, 'S7: loginFor: a hint seen before')),
  ('S7 loginFor: later hints are not forwarded', NL,
   "      } else if (l.onScan(now(), a, hint: h)) {", "      } else if (l.onScan(now(), a)) {", ft(T2, 'S7: loginFor: a hint that arrives later')),
  ('S9: no rebuild at the release', NL,
   "        _rebuildResolver(); // a claim under the lease added a record, a removal took one away\n", "", ft(T2, 'S9: a record written')),
  ('S9: a failed build clears the resolver', NL,
   "        trace?.call('adv resolver $n failed (${e.runtimeType}): the last one stays'); // never the error's text",
   "        _resolve = null;\n        trace?.call('adv resolver $n failed (${e.runtimeType}): the last one stays');", ft(T2, 'S9: a build that fails')),
  ('S9: the trace carries the error text', NL,
   "        trace?.call('adv resolver $n failed (${e.runtimeType}): the last one stays'); // never the error's text",
   "        trace?.call('adv resolver $n failed (${e.runtimeType}): $e');", ft(T2, 'S9: a build that fails')),
  ('S9: an older build may replace a newer one', NL, "        if (_disposed || n < _built) {", "        if (_disposed) {", ft(T2, 'S9: two builds overlap')),
  ('S9: a build that ended too late is not closed', NL, "        if (_disposed || n < _built) {\n          _close(r);\n", "        if (_disposed || n < _built) {\n", ft(T2, 'S9: two builds overlap')),
  ('S9: a replaced resolver is not closed', NL, "        _resolve = r;\n        _close(old);\n", "        _resolve = r;\n", ft(T2, 'S9: a record written')),
  ('S9: dispose does not close the resolver', NL, "    _close(_resolve);\n    _resolve = null;\n    _lfPoke();", "    _lfPoke();", ft(T2, 'S9: a record written')),
  ('log: every change of a hint is logged', CORE, "      if (r.likeLogged.add(a)) _log(", "      _log(", ft(T1, 'a round onScan')),
  ('S9: a throwing resolver is not caught', NL,
   "    try {\n      return r.resolve(mfr);\n    } catch (_) {\n      return null;\n    }", "    return r.resolve(mfr);", ft(T2, 'S9: a resolver that throws')),
  ('S9: one record that does not open fails the build', AL,
   "        if (p != null) plains.add(p);\n      } catch (_) {}", "        if (p != null) plains.add(p);\n      } catch (_) {\n        rethrow;\n      }", ft(T3, 'buildResolver: records')),
  ('S9: the opened bytes are not zeroed', AL, "      p.fillRange(0, p.length, 0);", "      p.length;", ft(T3, 'buildResolver')),
  ('S9: the build reports key errors (as the prober does)', AL,
   "(ids) => buildResolver(ids, (id) => openSealedRecord(platform, records, 'node/$id'), (plains) {",
   "(ids) => buildResolver(ids, (id) => openSealedRecord(platform, records, 'node/$id').catchError((Object e) {\n        keyError(e);\n        throw e;\n      }), (plains) {", ft(T3, 'AppLink')),
  ('V1: another label', KDF, 'b"batman-adv-id-v1"', 'b"batman-adv-id-v2"', ['cargo', 'test', '-q', '--test', 'vectors', 'adv_id'], 'rust/batman-proto'),
  ('V1: another company id', KDF, "pub const ADV_CID: u16 = 0xFFFF;", "pub const ADV_CID: u16 = 0xFFFE;", ['cargo', 'test', '-q', '--test', 'vectors', 'adv_id'], 'rust/batman-proto'),
  ('R1: a 2-byte tag compare', OWN, "(want[0] ^ t[0]) | (want[1] ^ t[1]) | (want[2] ^ t[2]) == 0", "(want[0] ^ t[0]) | (want[1] ^ t[1]) == 0", ['cargo', 'test', '-q', 'adv_tests'], 'rust/bridge'),
  ('R1: the company id is not checked', OWN,
   "        if u16::from_le_bytes([m[0], m[1]]) != batman_proto::kdf::ADV_CID {\n            return None;\n        }\n", "", ['cargo', 'test', '-q', 'adv_tests'], 'rust/bridge'),
  ('R1: the first match is returned', OWN,
   "                if hit.is_some() {\n                    return None;\n                }\n                hit = Some(id);",
   "                if hit.is_none() {\n                    hit = Some(id);\n                }", ['cargo', 'test', '-q', 'adv_tests'], 'rust/bridge'),
  # code review B MINOR-4: this mutant shows R1 only; R2's claim stands on the first, negative assertion of
  # r2_after_a_reclaim_the_old_record_does_not_resolve (None before any positive line)
  ('R1: keyed by the device id only', OWN, "batman_proto::kdf::adv_owner(key, id)));", "batman_proto::kdf::adv_owner(&[0u8; 32], id)));", ['cargo', 'test', '-q', 'adv_tests'], 'rust/bridge'),
  ('R1: a record with a short key 6 is taken', OWN, "            if key.len() == 32 {", "            if !key.is_empty() {", ['cargo', 'test', '-q', 'adv_tests'], 'rust/bridge'),
]

bad = 0
for m in M:
    name, f, old, new, cmd = m[:5]
    cwd = os.path.join(root, m[5]) if len(m) > 5 else root
    if only and not any(o in name for o in only):
        continue
    p = os.path.join(root, f)
    s = io.open(p, encoding='utf-8', newline='').read()
    if s.count(old) != 1:
        print(f'## {name}: MUTATION DID NOT APPLY ({s.count(old)} matches)'); bad += 1; continue
    io.open(p, 'w', encoding='utf-8', newline='').write(s.replace(old, new))
    try:
        r = subprocess.run(cmd, cwd=cwd, capture_output=True, text=True, encoding='utf-8', errors='replace')
    finally:
        io.open(p, 'w', encoding='utf-8', newline='').write(s)
        time.sleep(1.2)
        os.utime(p)  # cargo must see the restored file as newer than the mutated build (a stale artifact failed test-all once)
    out = (r.stdout + r.stderr).splitlines()
    key = [l.strip() for l in out if ('[E]' in l or 'test result' in l or 'FAILED' in l or 'panicked' in l or 'Some tests failed' in l
                                      or 'All tests passed' in l or 'error' in l.lower() and 'Error:' in l or 'No tests' in l)][:8]
    verdict = 'FAIL (as wanted)' if r.returncode != 0 else 'PASS  <-- the test does not catch it'
    if r.returncode == 0: bad += 1
    print(f'## {name}: rc={r.returncode} {verdict}')
    for l in key: print('   ', l[-230:])
    sys.stdout.flush()
print('not discriminating / not applied:', bad)
# wsync.sh (rsync -a) sets the Windows mtimes back on the restored Rust files, so cargo would keep the artifact of the
# last mutation: build once from the restored sources now (that stale artifact failed test-all's field builds once).
if not only or any(m[1] in (KDF, OWN) for m in M if any(o in m[0] for o in only)):
    for d in ('rust/batman-proto', 'rust/bridge'):
        r = subprocess.run(['cargo', 'test', '-q', '--no-run'], cwd=os.path.join(root, d), capture_output=True, text=True)
        print(f'rebuild {d}: rc={r.returncode}')
