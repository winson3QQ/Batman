#!/usr/bin/env python3
"""#329 fast retry, device acceptance (docs/design/329-fast-retry.md §7).

Reads app logcat files (the BMAPP lines) and judges the retries of NodeLink attempts and flow logins:

  python3 fast-retry-stats.py app1.logcat [app2.logcat ...]

Per retry it prints: the first failure's gate code, `second connect +N`, the code-less downs (`downs=`), the result,
the second link's connect time and the time from the first failure to the attempt's end. Exit 0 = PASS, 1 = FAIL.

FAIL when:
  - no retry line at all (a run that checked nothing never passes);
  - a fast failure (connected=-1, < 1500 ms) of an attempt that was not retried;
  - a retry whose `second connect +N` is outside 400..600 ms, or missing;
  - the stale-event signature: a code-less down later than the second connect with no `fail=` gate line for the
    address within +-1 s of it (fail=? counts as a code), whatever the retry's result;
  - fewer than 10 retries (not enough to judge: run more and pass every log), or fewer than 8 of the first 10 read a
    body (baseline: 15/16 next attempts read, 8 s later).
"""
import re
import sys
from datetime import datetime

TS = re.compile(r'^(\d\d-\d\d \d\d:\d\d:\d\d\.\d{3})')
ATT = re.compile(r'BMAPP nl (attempt|loginFor) (…\w+×\S+) (?:connected=(-?\d+)ms )?result=(\w+) after (\d+)ms(.*)$')
FAILED = re.compile(r'BMAPP nl (attempt|loginFor) (…\w+×\S+) link failed after (\d+)ms, connecting once more')
SECOND = re.compile(r'BMAPP nl (attempt|loginFor) (…\w+×\S+) second connect \+(\d+)ms')
GATE = re.compile(r'BMAPP gate link (…\w+) down fail=(\S+)')
ROUND_END = re.compile(r'BMAPP nl [\d.]+ round \d+ end \{(.*)\}')


def ts(line, year=2026):
    m = TS.match(line)
    return datetime.strptime(f'{year}-{m.group(1)}', '%Y-%m-%d %H:%M:%S.%f').timestamp() * 1000 if m else None


def main(paths):
    lines = []
    for p in paths:
        with open(p, encoding='utf-8', errors='replace') as f:
            lines += [(ts(l), l.rstrip('\n')) for l in f if 'BMAPP' in l]
    lines = [x for x in lines if x[0] is not None]
    gate = [(t, m.group(1), m.group(2)) for t, l in lines if (m := GATE.search(l))]
    pending = {}  # key -> dict of the retry in progress
    retries, bad, not_found = [], [], 0
    for t, l in lines:
        if (m := ROUND_END.search(l)):
            not_found += m.group(1).count('notFound')
        if (m := FAILED.search(l)):
            pending[(m.group(1), m.group(2))] = {'t': t, 'fail_ms': int(m.group(3)), 'second': None}
            continue
        if (m := SECOND.search(l)):
            r = pending.get((m.group(1), m.group(2)))
            if r is not None:
                r['second'] = int(m.group(3))
            continue
        m = ATT.search(l)
        if not m:
            continue
        kind, key, conn, res, after, rest = m.groups()
        conn = int(conn) if conn is not None else None
        r = pending.pop((kind, key), None)
        if ' retried' not in rest:
            if r is None and conn == -1 and int(after) < 1500:
                bad.append(f'{l}\n    a fast failure without a retry')
            continue
        if r is None:
            bad.append(f'{l}\n    retried, but no "link failed" line before it')
            continue
        addr = key.split('×')[0]
        code = next((c for g, a, c in gate if a == addr and abs(g - r['t']) <= 1000), '-')
        downs = [int(x) for x in re.findall(r'\+(\d+)', rest.split('downs=')[1])] if 'downs=' in rest else []
        row = {'when': l[:18], 'key': key, 'kind': kind, 'code': code, 'second': r['second'], 'downs': downs,
               'res': res, 'conn': conn, 'to_end': t - r['t']}
        retries.append(row)
        if r['second'] is None or not 400 <= r['second'] <= 600:
            bad.append(f'{l}\n    second connect +{r["second"]} not in 400..600')
        for d in downs:
            if r['second'] is not None and d > r['second']:
                at = r['t'] + d
                if not any(a == addr and abs(g - at) <= 1000 for g, a, _ in gate):
                    bad.append(f'{l}\n    stale-event signature: code-less down at +{d} ms after the second connect '
                               f'(+{r["second"]}) with no fail= line within 1 s')
    print(f'{"when":18} {"kind":8} {"attempt":14} {"code":5} {"2nd+":>5} {"downs":14} {"result":12} {"conn":>5} '
          f'{"fail->end":>9}')
    for r in retries:
        print(f'{r["when"]:18} {r["kind"]:8} {r["key"]:14} {r["code"]:5} {str(r["second"]):>5} '
              f'{",".join(map(str, r["downs"])):14} {r["res"]:12} {str(r["conn"]):>5} {r["to_end"]:>9.0f}')
    first10 = retries[:10]
    ok10 = sum(1 for r in first10 if r['res'] == 'body')
    reads = [r['to_end'] for r in retries if r['res'] == 'body']
    print(f'\nretries: {len(retries)}; read a body: {sum(1 for r in retries if r["res"] == "body")}; '
          f'first 10: {ok10}/{len(first10)}; round ends with notFound: {not_found}')
    if reads:
        reads.sort()
        print(f'first failure -> end of a retry that read: median {reads[len(reads) // 2]:.0f} ms, '
              f'worst {reads[-1]:.0f} ms (baseline: next attempt 6.4-9.8 s later)')
    if not retries:
        bad.append('no retry line at all: nothing was checked')
    elif len(retries) < 10:
        bad.append(f'only {len(retries)} retries: fewer than 10, run more')
    elif ok10 < 8:
        bad.append(f'only {ok10} of the first 10 retries read a body (< 8)')
    for b in bad:
        print('FAIL:', b)
    print('PASS' if not bad else f'FAIL ({len(bad)})')
    return 0 if not bad else 1


if __name__ == '__main__':
    if len(sys.argv) < 2:
        print(__doc__)
        sys.exit(2)
    sys.exit(main(sys.argv[1:]))
