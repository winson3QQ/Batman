#!/bin/bash
# app/tools/kotlin-unit-tests.sh — the app's Kotlin JVM unit tests (app/android/app/src/test), every variant's
# test<Variant>UnitTest, judged from the JUnit XML Gradle writes (never from Gradle's exit status alone: a variant
# whose test task found no test is "NO-SOURCE" and exits 0).
# Per variant: Gradle rc 0, > 0 tests, 0 failures / errors / skipped, and every must-run class present with > 0 tests.
# Must-run = the names below plus every *Test.kt under src/test today (a new test class is required from its first
# run; a deleted file still fails by its name here until this list is edited on purpose).
#   GRADLE     the Gradle to run (default: app/android/gradlew if present, else gradle on PATH) — the version in
#              app/android/gradle/wrapper/gradle-wrapper.properties
#   VARIANTS   space-separated variants (default: all nine: dev / dev2 / field x debug / profile / release)
#   --judge <results dir> <variant>   judge an existing build/app/test-results tree only (negative controls)
# Needs: the Android SDK (ANDROID_HOME or android/local.properties sdk.dir), flutter.sdk in android/local.properties
# and `flutter pub get` done (the Flutter Gradle plugin loader reads .flutter-plugins-dependencies), python3.
set -u
cd "$(dirname "$0")/../android" || exit 2
MUST="SwPutTest SwPickTest SwOwnedTest BleRxTest SignAllowListTest EcdhPeerTest KeyPolicyTest QrDecodeTest QrScanTest CameraErrorsTest ViewfinderFitTest"
ALL="devDebug devProfile devRelease dev2Debug dev2Profile dev2Release fieldDebug fieldProfile fieldRelease"
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

if [ "${1:-}" = --judge ]; then
	[ $# = 3 ] || { echo "usage: $0 --judge <results dir> <variant>"; exit 2; }
	judge "$2" "$3"; exit "$fail"
fi

GRADLE=${GRADLE:-$([ -x ./gradlew ] && echo ./gradlew || command -v gradle)}
[ -n "$GRADLE" ] || { echo "FAIL kotlin: no gradle (GRADLE, ./gradlew or PATH)"; echo "SUITE FAIL"; exit 1; }
RES=../build/app/test-results
for v in ${VARIANTS:-$ALL}; do
	cap="$(tr '[:lower:]' '[:upper:]' <<< "${v:0:1}")${v:1}"
	rm -rf "$RES/test${cap}UnitTest"   # only what this run writes is judged
	log=$(mktemp)
	"$GRADLE" --console=plain "test${cap}UnitTest" > "$log" 2>&1; rc=$?
	[ "$rc" = 0 ] || { grep -E 'FAILED|^e: |rror:' "$log" | head -20; sed -n '/What went wrong/,/^* Try/p' "$log" | head -20; }
	rm -f "$log"
	judge "$RES" "$v" "$rc"
done
[ "$fail" = 0 ] && echo "ALL PASS" || echo "SUITE FAIL"
exit "$fail"
