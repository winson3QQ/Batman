#!/usr/bin/env python3
"""#329 fast retry, device acceptance (docs/design/329-fast-retry.md §7).

Reads app logcat files (the BMAPP lines) and judges the retries of NodeLink attempts and flow logins:

  python3 fast-retry-stats.py app1.logcat [app2.logcat ...]
  python3 fast-retry-stats.py --selftest

Per retry it prints: the first failure's gate code, `second connect +N`, the code-less downs (`downs=`), the result,
the second link's connect time and the time from the first failure to the attempt's end. Exit 0 = PASS, 1 = FAIL.

FAIL when:
  - no retry line at all (a run that checked nothing never passes);
  - a fast failure of a NodeLink attempt (connected=-1, < 1500 ms, with a `fail=` gate line of that address within
    1 s before its attempt line) that has no "link failed" line;
  - a "link failed" line whose attempt ends without ` retried`, unless "no second connect" / "second connect refused"
    says why (those are counted and listed);
  - a retry whose `second connect +N` is outside 400..600 ms, or missing;
  - the stale-event signature: a code-less down later than the second connect with no `fail=` gate line for the
    address that was logged after the second connect and within +-1 s of the down (code reviews A / B MAJOR: the
    first failure's own fail= lines must not excuse it), whatever the retry's result;
  - fewer than 10 retries (not enough to judge: run more and pass every log), or fewer than 8 of the first 10 read a
    body (baseline: 15/16 next attempts read, 8 s later).
Not judged: a fast failure of a flow login without a retry (its result line has no connected= field).
"""
import re
import sys
from datetime import datetime

TS = re.compile(r'^(\d\d-\d\d \d\d:\d\d:\d\d\.\d{3})')
ATT = re.compile(r'BMAPP nl (attempt|loginFor) (…\w+×\S+) (?:connected=(-?\d+)ms )?result=(\w+) after (\d+)ms(.*)$')
FAILED = re.compile(r'BMAPP nl (attempt|loginFor) (…\w+×\S+) link failed after (\d+)ms, connecting once more')
SECOND = re.compile(r'BMAPP nl (attempt|loginFor) (…\w+×\S+) second connect \+(\d+)ms')
SKIP = re.compile(r'BMAPP nl (attempt|loginFor) (…\w+×\S+) (no second connect: .*|second connect refused)$')
GATE = re.compile(r'BMAPP gate link (…\w+) down fail=(\S+)')
ROUND_END = re.compile(r'BMAPP nl [\d.]+ round \d+ end \{(.*)\}')


def ts(line, year=2026):
    m = TS.match(line)
    return datetime.strptime(f'{year}-{m.group(1)}', '%Y-%m-%d %H:%M:%S.%f').timestamp() * 1000 if m else None


def judge(raw_lines, out=print):
    lines = [(ts(l), l.rstrip('\n')) for l in raw_lines if 'BMAPP' in l]
    lines = [x for x in lines if x[0] is not None]
    gate = [(t, m.group(1), m.group(2)) for t, l in lines if (m := GATE.search(l))]
    pending = {}  # (kind, key) -> the retry in progress
    retries, skipped, bad, not_found = [], [], [], 0
    for t, l in lines:
        if (m := ROUND_END.search(l)):
            not_found += m.group(1).count('notFound')
        if (m := FAILED.search(l)):
            pending[(m.group(1), m.group(2))] = {'t': t, 'second': None, 'skip': None}
            continue
        if (m := SECOND.search(l)):
            r = pending.get((m.group(1), m.group(2)))
            if r is not None:
                r['second'] = int(m.group(3))
            continue
        if (m := SKIP.search(l)):
            r = pending.get((m.group(1), m.group(2)))
            if r is not None:
                r['skip'] = m.group(3)
            continue
        m = ATT.search(l)
        if not m:
            continue
        kind, key, conn, res, after, rest = m.groups()
        conn = int(conn) if conn is not None else None
        addr = key.split('×')[0]
        r = pending.pop((kind, key), None)
        if ' retried' not in rest:
            if r is not None:
                if r['skip']:
                    skipped.append(f'{l[:18]} {kind} {key}: {r["skip"]}')
                else:
                    bad.append(f'{l}\n    "link failed" but the attempt ended without a retry and without a reason')
            elif kind == 'attempt' and conn == -1 and int(after) < 1500 and \
                    any(a == addr and 0 <= t - g <= 1000 for g, a, _ in gate):
                bad.append(f'{l}\n    a fast failure (with a fail= line) without a retry')
            continue
        if r is None:
            bad.append(f'{l}\n    retried, but no "link failed" line before it')
            continue
        code = next((c for g, a, c in gate if a == addr and abs(g - r['t']) <= 1000), '-')
        downs = [int(x) for x in re.findall(r'\+(\d+)', rest.split('downs=')[1])] if 'downs=' in rest else []
        row = {'when': l[:18], 'key': key, 'kind': kind, 'code': code, 'second': r['second'], 'downs': downs,
               'res': res, 'conn': conn, 'to_end': t - r['t']}
        retries.append(row)
        if r['second'] is None or not 400 <= r['second'] <= 600:
            bad.append(f'{l}\n    second connect +{r["second"]} not in 400..600')
            continue
        t2 = r['t'] + r['second']
        for d in downs:
            if d > r['second']:
                at = r['t'] + d
                if not any(a == addr and g > t2 and abs(g - at) <= 1000 for g, a, _ in gate):
                    bad.append(f'{l}\n    stale-event signature: code-less down at +{d} ms, after the second connect '
                               f'(+{r["second"]}), with no fail= line of its own (after the second connect, within 1 s)')
    out(f'{"when":18} {"kind":8} {"attempt":14} {"code":5} {"2nd+":>5} {"downs":14} {"result":12} {"conn":>5} '
        f'{"fail->end":>9}')
    for r in retries:
        out(f'{r["when"]:18} {r["kind"]:8} {r["key"]:14} {r["code"]:5} {str(r["second"]):>5} '
            f'{",".join(map(str, r["downs"])):14} {r["res"]:12} {str(r["conn"]):>5} {r["to_end"]:>9.0f}')
    for s in skipped:
        out(f'retry not made: {s}')
    first10 = retries[:10]
    ok10 = sum(1 for r in first10 if r['res'] == 'body')
    reads = sorted(r['to_end'] for r in retries if r['res'] == 'body')
    out(f'\nretries: {len(retries)}; read a body: {sum(1 for r in retries if r["res"] == "body")}; '
        f'first 10: {ok10}/{len(first10)}; retries not made (with a reason): {len(skipped)}; '
        f'round ends with notFound: {not_found}')
    if reads:
        out(f'first failure -> end of a retry that read: median {reads[len(reads) // 2]:.0f} ms, '
            f'worst {reads[-1]:.0f} ms (baseline: next attempt 6.4-9.8 s later)')
    if not retries:
        bad.append('no retry line at all: nothing was checked')
    elif len(retries) < 10:
        bad.append(f'only {len(retries)} retries: fewer than 10, run more')
    elif ok10 < 8:
        bad.append(f'only {ok10} of the first 10 retries read a body (< 8)')
    for b in bad:
        out(f'FAIL: {b}')
    out('PASS' if not bad else f'FAIL ({len(bad)})')
    return bad


def _synthetic(stale_at=None, second_fails=False, n=10):
    """n retries; each: failure at T, fail=133 at T, second connect +400, read or a second 133 at +700."""
    out = []

    def L(ms, text):
        s, ms = divmod(ms, 1000)
        m, s = divmod(s, 60)
        out.append(f'11-21 10:{m:02d}:{s:02d}.{ms:03d} I/flutter (1): BMAPP {text}')

    for i in range(n):
        T = 10000 + i * 40000
        k = '…01×…7d2c'
        L(T, f'nl attempt {k} link failed after 500ms, connecting once more')
        L(T, 'gate link …01 down fail=133')
        L(T + 400, f'nl attempt {k} second connect +400ms')
        downs = '+0'
        if stale_at is not None and i == 0:
            downs += f',+{stale_at}'
        if second_fails and i == 0:
            L(T + 700, 'gate link …01 down fail=133')
            downs += ',+700'
            L(T + 701, f'nl attempt {k} connected=-1ms result=noResponse after 1201ms retried downs={downs}')
        else:
            L(T + 2400, f'nl attempt {k} connected=300ms result=body after 2900ms retried downs={downs}')
    return out


def selftest():
    quiet = lambda *_: None
    cases = [
        ('10 good retries', _synthetic(), True),
        ('a stale down at +700 next to the first failure\'s fail=133 (the reviewed blind spot)', _synthetic(700), False),
        ('a stale down at +450, right after the second connect', _synthetic(450), False),
        ('the second failure\'s own coded down at +700', _synthetic(second_fails=True), True),
        ('no retries at all', [], False),
        ('only 3 retries', _synthetic(n=3), False),
        ('a fast failure with a fail= line and no retry',
         _synthetic() + ['11-21 10:59:00.000 I/flutter (1): BMAPP gate link …02 down fail=133',
                         '11-21 10:59:00.001 I/flutter (1): BMAPP nl attempt …02×…880c connected=-1ms '
                         'result=noResponse after 500ms'], False),
        ('a "link failed" whose attempt ends unretried without a reason',
         _synthetic() + ['11-21 10:59:00.000 I/flutter (1): BMAPP nl attempt …02×…880c link failed after 500ms, '
                         'connecting once more',
                         '11-21 10:59:00.900 I/flutter (1): BMAPP nl attempt …02×…880c connected=-1ms '
                         'result=noResponse after 900ms'], False),
    ]
    ok = True
    for name, lines, want in cases:
        got = not judge(lines, out=quiet)
        print(f'{"ok  " if got == want else "BAD "} {name}: expected {"PASS" if want else "FAIL"}, '
              f'got {"PASS" if got else "FAIL"}')
        ok &= got == want
    print('selftest', 'PASS' if ok else 'FAIL')
    return 0 if ok else 1


def main(argv):
    if argv == ['--selftest']:
        return selftest()
    raw = []
    for p in argv:
        with open(p, encoding='utf-8', errors='replace') as f:
            raw += f.readlines()
    return 0 if not judge(raw) else 1


if __name__ == '__main__':
    if len(sys.argv) < 2:
        print(__doc__)
        sys.exit(2)
    sys.exit(main(sys.argv[1:]))
