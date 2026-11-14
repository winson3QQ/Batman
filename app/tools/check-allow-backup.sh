#!/bin/bash
# app/tools/check-allow-backup.sh — T31 (docs/design/254-app-remove-member.md §6): no variant of the app allows backup
# of its data (a restored older network record could sign a version number again). Asserts on the MERGED manifest of
# every variant (what process<Variant>MainManifest writes and the APK packages), not on the source file: a library
# manifest or a build-type overlay can change the attribute at merge.
# Per variant: exactly one merged manifest, exactly one <application>, android:allowBackup the literal "false"
# (absent = Android's default true; a resource reference is not accepted).
#   GRADLE / VARIANTS as in kotlin-unit-tests.sh
#   --judge <AndroidManifest.xml> <name>   judge one file only
#   --selftest                             the judge on made-up manifests (false / absent / true / @bool / none / two)
# Not covered here: the binary manifest inside a built APK (aapt2 dump xmltree, as the design's T31 was run by hand):
# CI does not build an APK (NDK + Rust cross build).
set -u
SELF=$(cd "$(dirname "$0")" && pwd)/$(basename "$0")
cd "$(dirname "$0")/../android" || exit 2
ALL="devDebug devProfile devRelease dev2Debug dev2Profile dev2Release fieldDebug fieldProfile fieldRelease"
fail=0

judge(){ # <file> <name>
	local out
	out=$(python3 - "$1" <<'PY'
import sys
import xml.etree.ElementTree as ET
A = "{http://schemas.android.com/apk/res/android}allowBackup"
try:
    apps = ET.parse(sys.argv[1]).getroot().findall("application")
except (OSError, ET.ParseError) as e:
    print("unreadable: %s" % e); sys.exit(0)
if len(apps) != 1:
    print("%d <application> elements" % len(apps))
elif apps[0].get(A) is None:
    print("android:allowBackup is absent (default true)")
elif apps[0].get(A) != "false":
    print('android:allowBackup="%s"' % apps[0].get(A))
else:
    print("ok")
PY
	) || out="the judge itself failed"
	if [ "$out" = ok ]; then echo "PASS allowBackup $2: android:allowBackup=\"false\" in the merged manifest"
	else echo "FAIL allowBackup $2: $out"; fail=1; fi
}

case ${1:-} in
--judge)
	[ $# = 3 ] || { echo "usage: $0 --judge <AndroidManifest.xml> <name>"; exit 2; }
	judge "$2" "$3"; exit "$fail" ;;
--selftest)
	d=$(mktemp -d); trap 'rm -rf "$d"' EXIT
	mk(){ printf '<manifest xmlns:android="http://schemas.android.com/apk/res/android">%s</manifest>\n' "$2" > "$d/$1.xml"; }
	mk good '<application android:allowBackup="false"/>'
	mk absent '<application android:label="x"/>'
	mk true '<application android:allowBackup="true"/>'
	mk ref '<application android:allowBackup="@bool/no"/>'
	mk none ''
	mk two '<application android:allowBackup="false"/><application android:allowBackup="false"/>'
	mk other-ns '<application allowBackup="false"/>'
	st=0
	for c in good:0 absent:1 true:1 ref:1 none:1 two:1 other-ns:1 missing-file:1; do
		got=0; r=$("$SELF" --judge "$d/${c%%:*}.xml" "${c%%:*}") || got=1
		if [ "$got" = "${c##*:}" ]; then echo "ok   selftest ${c%%:*}: $r"; else echo "FAIL selftest ${c%%:*}: want rc ${c##*:}, got $got: $r"; st=1; fi
	done
	exit "$st" ;;
esac

GRADLE=${GRADLE:-$([ -x ./gradlew ] && echo ./gradlew || command -v gradle)}
[ -n "$GRADLE" ] || { echo "FAIL allowBackup: no gradle (GRADLE, ./gradlew or PATH)"; echo "SUITE FAIL"; exit 1; }
INT=../build/app/intermediates
tasks=""
for v in ${VARIANTS:-$ALL}; do
	cap="$(tr '[:lower:]' '[:upper:]' <<< "${v:0:1}")${v:1}"
	tasks="$tasks process${cap}MainManifest"
	rm -rf "$INT"/merged_manifest/"$v" "$INT"/merged_manifests/"$v"   # only what this run writes is judged
done
log=$(mktemp)
# shellcheck disable=SC2086  # task list
"$GRADLE" --console=plain $tasks > "$log" 2>&1; rc=$?
[ "$rc" = 0 ] || { echo "FAIL allowBackup: gradle rc=$rc"; grep -E 'FAILED|What went wrong|^> |rror:' "$log" | head -20; fail=1; }
rm -f "$log"
for v in ${VARIANTS:-$ALL}; do
	mapfile -t f < <(find "$INT"/merged_manifest/"$v" "$INT"/merged_manifests/"$v" -name AndroidManifest.xml 2>/dev/null)
	if [ "${#f[@]}" != 1 ]; then echo "FAIL allowBackup $v: ${#f[@]} merged manifests found under $INT/merged_manifest*/$v"; fail=1
	else judge "${f[0]}" "$v"; fi
done
[ "$fail" = 0 ] && echo "ALL PASS" || echo "SUITE FAIL"
exit "$fail"
