#!/usr/bin/env python3
# app/tools/flutter-test-summary.py <events.json> [must-pass name ...] — judges `flutter test -r json` output for
# app/rust/batman-proto/test-all.sh (a progress reporter skips the names of fast tests, so the JSON events are read).
# Line 1:  <passed> <failed> <missing>   missing = the must-pass names no passed test contains, then "skipped: <name>"
#          for each skipped test, joined by "|" (empty when none).
# Then:    one "FAILED: <name>" line per test that did not succeed (#254 L220: the names, not only a count).
# Lines that are not JSON events (pub's "Resolving dependencies..." on stdout) are ignored.
# Fixture: app/tools/testdata/flutter-test-one-failure.json (test-all.sh checks it names its one failure).
import json
import sys

names, done = {}, []
for line in open(sys.argv[1], encoding="utf-8"):
    line = line.strip()
    if not line.startswith("{"):
        continue
    e = json.loads(line)
    if e.get("type") == "testStart":
        names[e["test"]["id"]] = e["test"]["name"]
    elif e.get("type") == "testDone" and not e.get("hidden"):
        tid = e["testID"]
        done.append((names.get(tid) or "<test id %s>" % tid, e.get("result"), e.get("skipped")))
passed = [n for n, r, s in done if r == "success" and not s]
miss = [m for m in sys.argv[2:] if not any(m in n for n in passed)]
skipped = [n for n, r, s in done if s]
failed = [n for n, r, s in done if r != "success"]
print(len(passed), len(failed), "|".join(miss + ["skipped: " + n for n in skipped]))
for n in failed:
    print("FAILED: " + n.replace("\n", " "))
