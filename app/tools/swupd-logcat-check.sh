#!/bin/bash
# 254-app-update v0.4 §8 T8 / §7 (D8): the logcat check, on the phone. Run it around one software update on the bench
# (T11 normal path, or T9 (b) with the Specifier):
#   app/tools/swupd-logcat-check.sh start                 # clears the phone log
#   ... do the update in the app ...
#   SWUPD_PASS='<the AP passphrase set with 設定 Wi-Fi>' app/tools/swupd-logcat-check.sh check [applicationId]
# FAIL when the whole log (every tag, every process) holds the passphrase (as is, or its hex), or any 32-hex-digit token
# in the app process lines (the upload bearer is 16 bytes = 32 hex; the app never logs one), or when the log holds no
# line of the app at all (nothing checked is not a pass). The passphrase is read from the environment, never an argument
# (it would land in the shell history and ps).
set -u
ADB=${ADB:-adb}
case "${1:-}" in
start)
	"$ADB" logcat -c && echo "logcat cleared: run the update now, then: $0 check" ;;
check)
	app=${2:-dev.batman.app.dev}
	[ -n "${SWUPD_PASS:-}" ] || { echo "FAIL: set SWUPD_PASS (the AP passphrase) in the environment"; exit 2; }
	log=$(mktemp); trap 'rm -f "$log"' EXIT
	"$ADB" logcat -d -v threadtime > "$log" || { echo "FAIL: adb logcat"; exit 2; }
	pid=$("$ADB" shell pidof "$app" | tr -d '\r')
	lines=$(grep -c "BMAPP" "$log")
	fail=0
	if [ "${lines:-0}" -eq 0 ]; then echo "FAIL: no BMAPP line in the log (the app did not run, or the log was lost)"; fail=1; fi
	if grep -qF -- "$SWUPD_PASS" "$log"; then echo "FAIL: the passphrase is in the log"; fail=1; fi
	hexpass=$(printf '%s' "$SWUPD_PASS" | od -An -tx1 | tr -d ' \n')
	if grep -qiF -- "$hexpass" "$log"; then echo "FAIL: the passphrase (hex) is in the log"; fail=1; fi
	if [ -n "$pid" ]; then
		n=$(awk -v p="$pid" '$3 == p' "$log" | grep -cE '(^|[^0-9a-fA-F])[0-9a-fA-F]{32}([^0-9a-fA-F]|$)')
		if [ "$n" -gt 0 ]; then echo "FAIL: $n app line(s) hold a 32-hex token (a bearer?)"; awk -v p="$pid" '$3 == p' "$log" | grep -nE '[0-9a-fA-F]{32}' | cut -c1-60; fail=1; fi
	else
		echo "FAIL: $app is not running: its lines cannot be told apart (keep it open)"; fail=1
	fi
	[ "$fail" = 0 ] && echo "PASS: $lines BMAPP lines, no passphrase, no bearer-shaped token in the app's lines"
	exit "$fail" ;;
*)
	echo "usage: $0 start | check [applicationId]"; exit 2 ;;
esac
