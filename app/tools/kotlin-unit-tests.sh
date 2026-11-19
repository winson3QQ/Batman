#!/bin/bash
# app/tools/kotlin-unit-tests.sh — the app's Kotlin JVM unit tests (app/android/app/src/test), every variant's
# test<Variant>UnitTest, judged from the JUnit XML Gradle writes (never from Gradle's exit status alone: a variant
# whose test task found no test is "NO-SOURCE" and exits 0).
# Per variant: Gradle rc 0, > 0 tests, 0 failures / errors / skipped, and every must-run class present with > 0 tests.
# Must-run = the names below plus every *Test.kt under src/test today (a new test class is required from its first
# run; a deleted file still fails by its name here until this list is edited on purpose).
#   GRADLE     the Gradle to run (default: app/android/gradlew if present, else gradle on PATH) — the version in
#              app/android/gradle/wrapper/gradle-wrapper.properties
#   VARIANTS   space-separated variants (default: devDebug dev2Debug fieldDebug — the only test<Variant>UnitTest
#              tasks this build has: AGP creates unit-test tasks for the test build type (debug) only, so
#              test<Flavor>{Profile,Release}UnitTest do not exist ("Task ... not found", CI run 43549272945).
#              With the default list the script also FAILS if Gradle's own list of test*UnitTest tasks differs
#              from it, so a variant that gains a unit-test task cannot go untested unnoticed.
#   --judge <results dir> <variant>   judge an existing build/app/test-results tree only (negative controls)
# Vendored BLE plugin (#329): when app/pubspec.yaml has a dependency_overrides entry for reactive_ble_mobile with a
# path:, the plugin's :reactive_ble_mobile:testDebugUnitTest also runs and is judged from its JUnit XML the same way,
# keyed on testcase classname (its suites are named by @DisplayName): Gradle rc 0, > 0 tests, 0 failures / errors /
# skipped, and every class in PLUGIN_MUST present with > 0 tests. No such override = one "not applicable" line and
# nothing run; an unreadable pubspec, or an override path that is not a directory, FAILS.
#   --judge-plugin <results dir>      judge an existing build/reactive_ble_mobile/test-results tree only
# Needs: the Android SDK (ANDROID_HOME or android/local.properties sdk.dir), flutter.sdk in android/local.properties
# and `flutter pub get` done (the Flutter Gradle plugin loader reads .flutter-plugins-dependencies), python3.
set -u
cd "$(dirname "$0")/../android" || exit 2
MUST="SwPutTest SwPickTest SwOwnedTest BleRxTest SignAllowListTest EcdhPeerTest KeyPolicyTest QrDecodeTest QrScanTest CameraErrorsTest ViewfinderFitTest"
ALL="devDebug dev2Debug fieldDebug"
PLUGIN_MUST='DeviceConnectorTest$QueueCleanupTest OrphanConnectorTest'
fail=0

judge(){ # <results dir> <variant> [gradle rc]
	local dir=$1 v=$2 rc=${3:-0} cap out present n classes why
	cap="$(tr '[:lower:]' '[:upper:]' <<< "${v:0:1}")${v:1}"
	present=$(find app/src/test -name '*Test.kt' -exec basename {} .kt \; 2>/dev/null | tr '\n' ' ')
	# shellcheck disable=SC2086  # word lists
	out=$(python3 - "$dir/test${cap}UnitTest" $MUST $present <<'PY'
import glob, os, sys
import xml.etree.ElementTree as ET
d, must = sys.argv[1], sorted(set(sys.argv[2:]))
per, tot, bad = {}, 0, []
for f in sorted(glob.glob(os.path.join(d, "TEST-*.xml"))):
    try:
        r = ET.parse(f).getroot()
    except ET.ParseError as e:
        bad.append("unreadable %s (%s)" % (os.path.basename(f), e)); continue
    for s in ([r] if r.tag == "testsuite" else r.iter("testsuite")):
        cls = s.get("name", "").rsplit(".", 1)[-1]
        n = len(s.findall("testcase"))
        if str(n) != s.get("tests"):
            bad.append("%s: %s testcase elements, tests=%s" % (cls, n, s.get("tests")))
        per[cls] = per.get(cls, 0) + n
        tot += n
        for k in ("failures", "errors", "skipped"):
            if s.get(k, "?") != "0":
                bad.append("%s: %s=%s" % (cls, k, s.get(k, "missing")))
for m in must:
    if per.get(m, 0) <= 0:
        bad.append("did not run: " + m)
if tot <= 0:
    bad.insert(0, "no test ran (no JUnit XML with a testcase in %s)" % d)
print("%d %d %s" % (tot, len(per), "; ".join(bad)))
PY
	) || out="0 0 the judge itself failed"
	read -r n classes why <<< "$out"
	if [ "$rc" != 0 ]; then echo "FAIL kotlin $v: gradle rc=$rc${why:+; $why}"; fail=1
	elif [ -n "$why" ] || [ "${n:-0}" -le 0 ]; then echo "FAIL kotlin $v: ${why:-no result}"; fail=1
	else echo "PASS kotlin $v: $n tests in $classes classes"; fi
}

judge_plugin(){ # <results dir> [gradle rc]
	local dir=$1 rc=${2:-0} out n classes why
	# shellcheck disable=SC2086  # word list
	out=$(python3 - "$dir/testDebugUnitTest" $PLUGIN_MUST <<'PY'
import glob, os, sys
import xml.etree.ElementTree as ET
d, must = sys.argv[1], sorted(set(sys.argv[2:]))
per, tot, bad = {}, 0, []
for f in sorted(glob.glob(os.path.join(d, "TEST-*.xml"))):
    try:
        r = ET.parse(f).getroot()
    except ET.ParseError as e:
        bad.append("unreadable %s (%s)" % (os.path.basename(f), e)); continue
    for s in ([r] if r.tag == "testsuite" else r.iter("testsuite")):
        cases = s.findall("testcase")
        if str(len(cases)) != s.get("tests"):
            bad.append("%s: %s testcase elements, tests=%s" % (s.get("name", "?"), len(cases), s.get("tests")))
        for c in cases:
            cls = c.get("classname", "").rsplit(".", 1)[-1]
            per[cls] = per.get(cls, 0) + 1
        tot += len(cases)
        for k in ("failures", "errors", "skipped"):
            if s.get(k, "?") != "0":
                bad.append("%s: %s=%s" % (os.path.basename(f)[5:-4].rsplit(".", 1)[-1], k, s.get(k, "missing")))
for m in must:
    if per.get(m, 0) <= 0:
        bad.append("did not run: " + m)
if tot <= 0:
    bad.insert(0, "no test ran (no JUnit XML with a testcase in %s)" % d)
print("%d %d %s" % (tot, len(per), "; ".join(bad)))
PY
	) || out="0 0 the judge itself failed"
	read -r n classes why <<< "$out"
	if [ "$rc" != 0 ]; then echo "FAIL plugin reactive_ble_mobile: gradle rc=$rc${why:+; $why}"; fail=1
	elif [ -n "$why" ] || [ "${n:-0}" -le 0 ]; then echo "FAIL plugin reactive_ble_mobile: ${why:-no result}"; fail=1
	else echo "PASS plugin reactive_ble_mobile: $n tests in $classes classes (must-run: $PLUGIN_MUST)"; fi
}

plugin_override(){ # prints the path: of a reactive_ble_mobile dependency_override in ../pubspec.yaml, or nothing; rc 2 = unreadable
	python3 - ../pubspec.yaml <<'PY'
import re, sys
try:
    lines = open(sys.argv[1], encoding="utf-8").read().splitlines()
except (OSError, UnicodeDecodeError) as e:
    print("cannot read %s: %s" % (sys.argv[1], e)); sys.exit(2)
def strip(l):  # drop a comment (no '#' inside pubspec values here) and trailing space
    return re.sub(r"(^|\s)#.*$", "", l).rstrip()
blk, ent, ind, cind = False, False, None, None
for l in map(strip, lines):
    if not l.strip():
        continue
    lead = len(l) - len(l.lstrip(" "))
    if lead == 0:
        blk, ent = l.startswith("dependency_overrides:"), False; continue
    if not blk:
        continue
    if ind is None:
        ind = lead
    if lead == ind:
        m = re.match(r"\s*['\"]?reactive_ble_mobile['\"]?\s*:\s*(.*)$", l)
        ent, cind = bool(m), None
        if m and m.group(1):  # flow form: reactive_ble_mobile: {path: x}
            p = re.search(r"\bpath\s*:\s*['\"]?([^,'\"}]+)", m.group(1))
            if p:
                print(p.group(1).strip()); sys.exit(0)
        continue
    if ent and cind is None:
        cind = lead  # the entry's own keys; a path: nested deeper (git: path:) is not a path override
    if ent and lead == cind:
        p = re.match(r"\s*path\s*:\s*['\"]?([^'\"]+?)['\"]?\s*$", l)
        if p:
            print(p.group(1)); sys.exit(0)
PY
}

if [ "${1:-}" = --judge ]; then
	[ $# = 3 ] || { echo "usage: $0 --judge <results dir> <variant>"; exit 2; }
	judge "$2" "$3"; exit "$fail"
fi
if [ "${1:-}" = --judge-plugin ]; then
	[ $# = 2 ] || { echo "usage: $0 --judge-plugin <results dir>"; exit 2; }
	judge_plugin "$2"; exit "$fail"
fi

GRADLE=${GRADLE:-$([ -x ./gradlew ] && echo ./gradlew || command -v gradle)}
[ -n "$GRADLE" ] || { echo "FAIL kotlin: no gradle (GRADLE, ./gradlew or PATH)"; echo "SUITE FAIL"; exit 1; }
RES=../build/app/test-results
if [ -z "${VARIANTS:-}" ]; then   # the task list Gradle offers must be exactly the default list
	want=$(for v in $ALL; do echo "test$(tr "[:lower:]" "[:upper:]" <<< "${v:0:1}")${v:1}UnitTest"; done | sort)
	have=$("$GRADLE" --console=plain :app:tasks --all 2>&1 | grep -oE "^test[A-Za-z0-9]+UnitTest" | sort -u)
	if [ "$want" = "$have" ]; then echo "PASS kotlin task list: $(echo $have)"
	else echo "FAIL kotlin task list: Gradle offers [$(echo $have)], this script runs [$(echo $want)]"; fail=1; fi
fi
for v in ${VARIANTS:-$ALL}; do
	cap="$(tr '[:lower:]' '[:upper:]' <<< "${v:0:1}")${v:1}"
	rm -rf "$RES/test${cap}UnitTest"   # only what this run writes is judged
	log=$(mktemp)
	"$GRADLE" --console=plain "test${cap}UnitTest" > "$log" 2>&1; rc=$?
	[ "$rc" = 0 ] || { grep -E 'FAILED|^e: |rror:' "$log" | head -20; sed -n '/What went wrong/,/^* Try/p' "$log" | head -20; }
	rm -f "$log"
	judge "$RES" "$v" "$rc"
done
ov=$(plugin_override); orc=$?
if [ "$orc" != 0 ]; then echo "FAIL plugin tests: app/pubspec.yaml: ${ov:-override parse failed rc=$orc}"; fail=1
elif [ -z "$ov" ]; then echo "plugin tests: reactive_ble_mobile not vendored (no path override in app/pubspec.yaml) — not applicable"
elif [ ! -d "../$ov/android" ]; then echo "FAIL plugin tests: reactive_ble_mobile overridden to path $ov, but app/$ov/android is not a directory"; fail=1
else
	echo "plugin tests: reactive_ble_mobile vendored at app/$ov (path override) — running :reactive_ble_mobile:testDebugUnitTest"
	PRES=../build/reactive_ble_mobile/test-results
	rm -rf "$PRES/testDebugUnitTest"   # only what this run writes is judged
	log=$(mktemp)
	"$GRADLE" --console=plain :reactive_ble_mobile:testDebugUnitTest > "$log" 2>&1; rc=$?
	[ "$rc" = 0 ] || { grep -E 'FAILED|^e: |rror:' "$log" | head -20; sed -n '/What went wrong/,/^* Try/p' "$log" | head -20; }
	rm -f "$log"
	judge_plugin "$PRES" "$rc"
fi
[ "$fail" = 0 ] && echo "ALL PASS" || echo "SUITE FAIL"
exit "$fail"
