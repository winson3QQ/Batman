#!/bin/bash
# A2 device scripts, shared part (design 329-takeover.md, device rules). Sourced, not run.
# Rules kept here:
#  - secure() answers "secure" on any error or a size that is not a number (fail-closed);
#  - a dump happens only right after secure() said "not secure", and /sdcard/ui.xml is deleted after each dump;
#  - from a 手機 Wi-Fi tap until a Back after which secure() says "not secure", no dump at all (WIFI=1).
export MSYS_NO_PATHCONV=1
A=/c/Users/yello/AppData/Local/Android/Sdk/platform-tools/adb.exe
D="-s RFCN30HMRAR"
SECURE_MAX=30000   # a screencap smaller than this is taken as the secure page
WIFI=0
pt(){ $A $D shell date +%T.%3N | tr -d '\r'; }
log(){ echo "[phone=$(pt)] $*"; }
# size of a screencap in bytes, or nothing on any error; the picture never leaves the phone and is deleted
capsize(){
	local n
	$A $D shell screencap -p /sdcard/a2chk.png >/dev/null 2>&1 || { $A $D shell rm -f /sdcard/a2chk.png >/dev/null 2>&1; return 1; }
	n=$($A $D shell stat -c %s /sdcard/a2chk.png 2>/dev/null | tr -d '\r')
	$A $D shell rm -f /sdcard/a2chk.png >/dev/null 2>&1
	case "$n" in ''|*[!0-9]*) return 1;; esac
	echo "$n"
}
# 0 = secure page (or unknown), 1 = known not secure
secure(){
	local n
	n=$(capsize) || return 0
	[ "$n" -ge "$SECURE_MAX" ] && return 1
	return 0
}
_dump(){
	$A $D shell uiautomator dump /sdcard/ui.xml >/dev/null 2>&1
	$A $D shell cat /sdcard/ui.xml 2>/dev/null | tr -d '\r'
	$A $D shell rm -f /sdcard/ui.xml >/dev/null 2>&1
}
# the whole dump (D7), only when allowed; prints nothing and returns 1 when not
dump(){
	[ "$WIFI" = 1 ] && return 1
	secure && return 1
	_dump
}
descs(){
	local x
	x=$(dump) || { echo "(no dump: secure or unknown)"; return 1; }
	echo "$x" | grep -oE 'content-desc="[^"]+"' | sed -E 's/content-desc="//; s/"$//; s/&#10;/ | /g' | head -4 | tr '\n' ';' | cut -c1-160
}
tap_wifi(){ WIFI=1; log "tap wifi"; $A $D shell input tap 540 "$1"; }
# Back; after a 手機 Wi-Fi tap the flag clears only when the page is known not secure
back(){
	$A $D shell input tap 84 163; sleep 2
	if [ "$WIFI" = 1 ]; then secure || WIFI=0; fi
}
home(){
	local i
	for i in 1 2 3 4; do
		if [ "$WIFI" = 1 ] || secure; then back; continue; fi
		descs | grep -q "設定;" && return 0
		back
	done
	return 1
}
