#!/bin/bash
# tests/prov-p3/setkey-settings.sh <halow-setkey> <rundir.sh> [wireless-settle.sh] — #254 P3 settings (254-p3-impl §3.3):
# halow-setkey --country / --ap - --ap-ssid --ap-section, always --rollback. Runs the product under busybox ash against
# tests/prov-p1/lib-wireless-stubs.sh plus this file's AP model. The AP model follows 04 (wsl.22, 2026-11-09): an AP on
# the air = radio0 lists the section with its ifname + ssid, `iw dev` shows the ssid, `ubus list` has hostapd.<ifname>;
# blocked = no ssid, no hostapd.<ifname>, while a DOWN type-AP netdev may linger (brcmfmac keeps it).
# Exit codes checked: 0 / 2 / 3 / 4 / 5 / 6. Zero cases run = FAIL.
# Hooks (files in $ST): p5-stale (batman-config-save --check says stale until a --save), ap-fails (empty: no AP comes up; with an ssid: only that one), batch-fails (uci batch applies nothing), r1-pending (netifd never settles radio1), stuck-on (the
# AP stays on the air whatever is written), iw-ssid (iw shows this ssid instead of the committed one).
set -u
SK=$(readlink -f "${1:?usage: $0 <halow-setkey> <rundir.sh>}"); RD=$(readlink -f "${2:?}")
WS=$(readlink -f "${3:-$(dirname "$RD")/wireless-settle.sh}")
command -v busybox >/dev/null || { echo "FAIL busybox missing"; echo "SETKEY-SETTINGS cases=0 fails=1"; exit 1; }
HERE=$(cd "$(dirname "$0")/../prov-p1" && pwd)
# shellcheck source=tests/prov-p1/lib-wireless-stubs.sh
. "$HERE/lib-wireless-stubs.sh"
T=$(mktemp -d); trap 'jobs -p | xargs -r kill 2>/dev/null; rm -rf "$T"' EXIT
stubs_init "$T/st"
stub_rundir "$RD" "$ST/rundir.sh"
printf 'US,1,1,2,42,0,0,923.0\nUS,1,1,4,40,0,0,922.0\nJP,1,1,1,9,0,0,916.5\n' > "$ST/channels.csv"
mkdir -p "$ST/uci-tmp"
# ---- this file's stubs: uci batch, the AP model in ubus / iw, ubus list, jsonfilter filters
mv "$ST/bin/uci" "$ST/bin/uci.base"
cat > "$ST/bin/uci" <<'EOF'
#!/bin/bash
S=${STUB_ST:?}
a=("$@"); while [ "${a[0]:-}" = -q ]; do a=("${a[@]:1}"); done
if [ "${a[0]:-}" = batch ]; then
	echo "batch argv: ${a[*]}" >> "$S/argv.log"
	[ -f "$S/batch-fails" ] && { cat > /dev/null; exit 1; }
	while IFS= read -r l; do
		case "$l" in
			set\ *) kv=${l#set }; k=${kv%%=*}; v=${kv#*=}; v=${v#\'}; v=${v%\'}; "$S/bin/uci.base" set "$k=$v" ;;
			delete\ *) "$S/bin/uci.base" delete "${l#delete }" ;;
		esac
	done
	exit 0
fi
echo "argv: ${a[*]}" >> "$S/argv.log"
exec "$S/bin/uci.base" "$@"
EOF
cat > "$ST/bin/wifi" <<'EOF'
#!/bin/bash
S=${STUB_ST:?}
echo "wifi $*" >> "$S/wifi.log"
[ $# = 0 ] && [ -f "$S/stuck-until-wifi" ] && rm -f "$S/stuck-on" "$S/stuck-until-wifi"   # a full reconfigure frees it
g(){ awk -v k="$1" 'index($0, k "=") == 1 { print substr($0, length(k) + 2); exit }' "$S/committed"; }
apf=n; [ -f "$S/ap-fails" ] && { [ ! -s "$S/ap-fails" ] || [ "$(cat "$S/ap-fails")" = "$(g wireless.default_radio0.ssid)" ]; } && apf=y
if [ "$(g wireless.default_radio0.disabled)" != 1 ] && [ "$(g wireless.default_radio0.key)" != CHANGE-ME-NOW ] && [ "$apf" = n ]; then
	echo up > "$S/ap"; g wireless.default_radio0.ssid > "$S/ap.ssid"
else
	[ -f "$S/ap" ] && echo linger > "$S/ap"   # brcmfmac keeps a DOWN type-AP netdev
fi
exit 0   # `wifi reload` succeeds: setkey's `|| wifi` fallback must not run a full wifi behind the test's back
EOF
cat > "$ST/bin/iw" <<'EOF'
#!/bin/bash
S=${STUB_ST:?}
st=$(cat "$S/ap" 2>/dev/null); [ -f "$S/stuck-on" ] && st=up
sid=$(cat "$S/ap.ssid" 2>/dev/null); [ -f "$S/iw-ssid" ] && sid=$(cat "$S/iw-ssid")
if [ "$*" = dev ]; then
	printf 'phy#1\n\tInterface phy1-ap0\n\t\ttype AP\n'
	[ "$st" = up ] && [ ! -f "$S/ap-noair" ] && printf '\t\tssid %s\n' "$sid"
	exit 0
fi
if [ "$1 $2 ${3:-}" = "dev phy1-ap0 info" ]; then
	printf 'Interface phy1-ap0\n\ttype AP\n'; [ "$st" = up ] && [ ! -f "$S/ap-noair" ] && printf '\tssid %s\n' "$sid"; exit 0
fi
exit 0
EOF
cat > "$ST/bin/ubus" <<'EOF'
#!/bin/bash
S=${STUB_ST:?}
st=$(cat "$S/ap" 2>/dev/null); [ -f "$S/stuck-on" ] && st=up
r1p=false; [ -f "$S/r1-pending" ] && r1p=true
if [ "$1" = list ]; then
	if [ -n "${2:-}" ]; then [ "$2" = hostapd.phy1-ap0 ] && [ "$st" = up ]; exit; fi
	echo hostapd; [ "$st" = up ] && echo hostapd.phy1-ap0; exit 0
fi
[ "$*" = "call network.wireless status" ] || exit 1
ifs=""; [ "$st" = up ] && ifs="{ \"section\": \"default_radio0\", \"ifname\": \"phy1-ap0\", \"config\": { \"mode\": \"ap\", \"ssid\": \"$(cat "$S/ap.ssid")\" } }"
printf '{ "radio0": { "up": true, "pending": false, "disabled": false, "interfaces": [ %s ] }, "radio1": { "up": false, "pending": %s, "disabled": true, "interfaces": [ ] } }\n' "$ifs" "$r1p"
EOF
cat > "$ST/bin/jsonfilter" <<'EOF'
#!/usr/bin/env python3
# OpenWrt jsonfilter subset: -e @.a.b[*].c, @.a[N], and the filter @.a[@.k='v'].b (04: rc 1 when nothing matches)
import json, re, sys
a = sys.argv[1:]
if len(a) != 2 or a[0] != "-e" or not a[1].startswith("@."):
    sys.exit(2)
toks = re.findall(r"\[@\.[^\]]*\]|\[[^\]]*\]|[^.\[\]]+", a[1][2:])
cur = [json.load(sys.stdin)]
for t in toks:
    nxt = []
    for v in cur:
        if t.startswith("[@."):
            k, val = re.match(r"\[@\.(\w+)='([^']*)'\]", t).groups()
            nxt += [e for e in (v if isinstance(v, list) else []) if isinstance(e, dict) and e.get(k) == val]
        elif t == "[*]":
            nxt += v if isinstance(v, list) else []
        elif t.startswith("["):
            i = int(t[1:-1]); nxt += [v[i]] if isinstance(v, list) and i < len(v) else []
        elif isinstance(v, dict) and t in v:
            nxt.append(v[t])
    cur = nxt
if not cur:
    sys.exit(1)
for x in cur:
    print(json.dumps(x) if isinstance(x, (bool, dict, list)) else x)
EOF
chmod +x "$ST/bin/"*
sed -e "s#/usr/lib/batman/rundir.sh#$ST/rundir.sh#g" -e "s#^MARK=/etc/halow-keyguard.blocked#MARK=$ST/mark#" \
	-e "s#^WSETTLE=/usr/lib/batman/wireless-settle.sh#WSETTLE=$WS#" -e "s#^SETTLE_WAIT=30#SETTLE_WAIT=2#" \
	-e "s#^READBACK_WAIT=60#READBACK_WAIT=3#" -e "s#^REGDB=/usr/share/morse-regdb/channels.csv#REGDB=$ST/channels.csv#" \
	-e "s#^PROVTXN=/etc/batman-prov/.txn#PROVTXN=$ST/txn#" -e "s#^LOCKWAIT=90#LOCKWAIT=2#" -e 's/$(id -u)/0/g' \
	-e "s#/tmp/.uci/wireless#$ST/uci-tmp/wireless#g" -e "s#-b /dev/mmcblk0p5#-e $ST/p5#" "$SK" > "$T/sk"
PL=CHANGE-ME-NOW
cases=0; fails=0
ok(){ cases=$((cases + 1)); echo "PASS $*"; }; no(){ cases=$((cases + 1)); fails=$((fails + 1)); echo "FAIL $*"; }
run(){ PATH="$ST/bin:$PATH" busybox sh "$T/sk" "$@"; }
get(){ awk -v k="$1" 'index($0, k "=") == 1 { print substr($0, length(k) + 2); exit }' "$ST/committed"; }
reset() {   # a fresh claimed node: AP placeholder + blocked, radio1 blocked (not in a network)
	cat > "$ST/live" <<EOF
wireless.radio0.type=mac80211
wireless.default_radio0.device=radio0
wireless.default_radio0.mode=ap
wireless.default_radio0.ssid=BCM2711-6c89
wireless.default_radio0.key=$PL
wireless.default_radio0.disabled=1
wireless.radio1.type=morse
wireless.radio1.channel=42
wireless.radio1.country=US
wireless.radio1.disabled=1
wireless.default_radio1.device=radio1
wireless.default_radio1.mode=mesh
wireless.default_radio1.key=$PL
EOF
	cp "$ST/live" "$ST/committed"; echo " radio1 default_radio0" > "$ST/mark"; rm -f "$ST/ap" "$ST/ap.ssid" "$ST/ap-fails" "$ST/ap-noair" "$ST/uci-tmp/wireless" "$ST/batch-fails" "$ST/r1-pending" "$ST/stuck-on" "$ST/iw-ssid" "$ST/txn" "$ST/stuck-until-wifi"
	: > "$ST/argv.log"; : > "$ST/cfgsave.log"; : > "$ST/p5"
	printf '#!/bin/bash\necho "$*" >> "$STUB_ST/cfgsave.log"; [ "$1" = --check ] && { [ -f "$STUB_ST/p5-stale" ] && exit 5; exit 0; }; [ -f "$STUB_ST/save-fails" ] && exit 1; rm -f "$STUB_ST/p5-stale"; echo saved\n' > "$ST/bin/batman-config-save"; chmod +x "$ST/bin/batman-config-save"; rm -f "$ST/save-fails" "$ST/p5-stale"
}
PASS1=Abcdefgh1234._~
# 1. AP pairing: key from stdin, ssid set, the AP's block released, on the air, persisted; the key never in an argv
reset
o=$(printf '%s\n' "$PASS1" | run --ap - --ap-ssid "Team 1" --ap-section default_radio0 --rollback 2>&1); rc=$?
[ "$rc" = 0 ] && ok "AP pairing rc 0 ($(echo "$o" | tail -1))" || no "AP pairing rc $rc: $o"
[ "$(get wireless.default_radio0.key)" = "$PASS1" ] && [ "$(get wireless.default_radio0.ssid)" = "Team 1" ] && [ -z "$(get wireless.default_radio0.disabled)" ] && ok "AP: key + ssid committed, disabled removed" || no "AP committed state wrong"
[ "$(cat "$ST/mark")" = " radio1" ] && ok "AP: default_radio0 left the keyguard mark, radio1 stays" || no "mark: [$(cat "$ST/mark")]"
grep -q -- "$PASS1" "$ST/argv.log" && no "the passphrase appeared in a uci argv" || ok "the passphrase never in a uci argv (batch on stdin)"
grep -qx -- "--save" "$ST/cfgsave.log" && ok "AP: persisted (--save)" || no "AP: not persisted"
# 2. refused values: nothing written, rc 2
for bad in "Team1!" " lead" "trail " "$(printf 'x%.0s' $(seq 1 33))"; do
	reset; o=$(printf '%s\n' "$PASS1" | run --ap - --ap-ssid "$bad" --ap-section default_radio0 --rollback 2>&1); rc=$?
	[ "$rc" = 2 ] && [ "$(get wireless.default_radio0.key)" = "$PL" ] && ok "ssid [${bad:0:12}…] refused rc 2, nothing written" || no "ssid [$bad]: rc $rc"
done
for bad in short1 "has'quote12345" "$PL" "abc\$defghijklm"; do
	reset; o=$(printf '%s\n' "$bad" | run --ap - --ap-ssid T --ap-section default_radio0 --rollback 2>&1); rc=$?
	[ "$rc" = 2 ] && [ "$(get wireless.default_radio0.key)" = "$PL" ] && ok "passphrase [${bad:0:5}…] refused rc 2" || no "passphrase [$bad]: rc $rc"
done
reset; o=$(printf '%s\n' "$PASS1" | run --ap - --ap-ssid T --ap-section default_radio1 --rollback 2>&1); [ $? = 2 ] && ok "another section refused" || no "section: $o"
reset; o=$(printf '%s\n' "$PASS1" | run --ap - --ap-ssid T --ap-section default_radio0 2>&1); [ $? = 2 ] && ok "--ap-ssid without --rollback refused" || no "no rollback: $o"
reset; o=$(run --country JP --rollback --mesh x 2>&1); [ $? = 2 ] && ok "a P3 value mixed with --mesh refused" || no "mixed: $o"
# 3. the AP does not come up -> rc 3, back to blocked: placeholder + disabled=1 + in the mark, off the air, not persisted
reset; : > "$ST/ap-fails"
o=$(printf '%s\n' "$PASS1" | run --ap - --ap-ssid "Team 1" --ap-section default_radio0 --rollback 2>&1); rc=$?
[ "$rc" = 3 ] && ok "AP not up -> rc 3" || no "AP not up: rc $rc ($o)"
[ "$(get wireless.default_radio0.key)" = "$PL" ] && [ "$(get wireless.default_radio0.disabled)" = 1 ] && grep -q default_radio0 "$ST/mark" && ok "back to blocked: placeholder, disabled=1, in the mark" || no "not blocked again"
grep -qx -- "--save" "$ST/cfgsave.log" && no "persisted after a failed read back" || ok "nothing persisted after the failed read back"
grep -q "back to blocked" <<< "$o" && ok "restore verified (off the air)" || no "restore message: $o"
# 3b. netifd lists the section with the ssid but nothing is on the air (iw shows no ssid) -> not "up": rc 3, re-blocked
reset; : > "$ST/ap-noair"
o=$(printf '%s\n' "$PASS1" | run --ap - --ap-ssid "Team 1" --ap-section default_radio0 --rollback 2>&1); rc=$?
[ "$rc" = 3 ] && [ "$(get wireless.default_radio0.disabled)" = 1 ] && ok "netifd's word without the ssid on the air is not 'up' -> rc 3, re-blocked" || no "no-air: rc $rc ($o)"
# 4. persist fails -> rc 4, back to blocked and persisted again
reset; : > "$ST/save-fails"
o=$(printf '%s\n' "$PASS1" | run --ap - --ap-ssid "Team 1" --ap-section default_radio0 --rollback 2>&1); rc=$?
[ "$rc" = 4 ] && [ "$(get wireless.default_radio0.key)" = "$PL" ] && [ "$(get wireless.default_radio0.disabled)" = 1 ] && ok "persist fails -> rc 4, back to blocked" || no "persist fail: rc $rc ($o)"
# 5. a paired AP (real old key) whose new values fail -> the old key and ssid back, on the air
reset; printf '%s\n' "$PASS1" | run --ap - --ap-ssid "Team 1" --ap-section default_radio0 --rollback >/dev/null 2>&1
echo "Team 2" > "$ST/ap-fails"; o=$(printf '%s\n' "Zzzzzzzzzzzz9" | run --ap - --ap-ssid "Team 2" --ap-section default_radio0 --rollback 2>&1); rc=$?
rm -f "$ST/ap-fails"
[ "$rc" = 3 ] && [ "$(get wireless.default_radio0.key)" = "$PASS1" ] && [ "$(get wireless.default_radio0.ssid)" = "Team 1" ] && ok "re-pair fails -> the previous key + ssid back" || no "re-pair restore: rc $rc key/ssid $(get wireless.default_radio0.ssid) ($o)"
# 6. country: blocked radio -> set + persisted; not in the regdb / lower case / radio enabled -> rc 2; staged -> rc 5
reset; o=$(run --country JP --rollback 2>&1); rc=$?
[ "$rc" = 0 ] && [ "$(get wireless.radio1.country)" = JP ] && grep -qx -- "--save" "$ST/cfgsave.log" && ok "country JP set + persisted" || no "country: rc $rc ($o)"
for bad in TW jp J; do reset; run --country "$bad" --rollback >/dev/null 2>&1; rc=$?
	[ "$rc" = 2 ] && [ "$(get wireless.radio1.country)" = US ] && ok "country [$bad] refused rc 2" || no "country [$bad]: rc $rc"; done
reset; sed -i '/^wireless.radio1.disabled=/d' "$ST/live"; cp "$ST/live" "$ST/committed"
run --country JP --rollback >/dev/null 2>&1; [ $? = 2 ] && [ "$(get wireless.radio1.country)" = US ] && ok "country on an enabled (joined) radio refused" || no "country on an enabled radio accepted"
reset; echo staged > "$ST/uci-tmp/wireless"; run --country JP --rollback >/dev/null 2>&1; [ $? = 5 ] && [ "$(get wireless.radio1.country)" = US ] && ok "staged wireless changes -> rc 5, nothing written" || no "staged: not rc 5"
reset; : > "$ST/save-fails"; run --country JP --rollback >/dev/null 2>&1; rc=$?
[ "$rc" = 4 ] && [ "$(get wireless.radio1.country)" = US ] && ok "country persist fails -> rc 4, US back" || no "country persist fail: rc $rc country $(get wireless.radio1.country)"
# 7. the lock busy past --lockwait -> rc 5 (P3), nothing written
reset; ( flock 8; sleep 4 ) 8>"$ST/run/batman/halow-setkey.lock" & sleep 0.3
run --country JP --rollback --lockwait 1 >/dev/null 2>&1; rc=$?; wait
[ "$rc" = 5 ] && [ "$(get wireless.radio1.country)" = US ] && ok "lock busy -> rc 5" || no "lock busy: rc $rc"
# 8. design D-5: busy states are 5, not 2 ("value refused"): an unfinished helper change (.txn), netifd never settling
reset; : > "$ST/txn"; run --country JP --rollback >/dev/null 2>&1; rc=$?
[ "$rc" = 5 ] && [ "$(get wireless.radio1.country)" = US ] && ok "D-5: .txn present -> rc 5, nothing written" || no "D-5 .txn: rc $rc"
reset; : > "$ST/r1-pending"; run --country JP --rollback >/dev/null 2>&1; rc=$?
[ "$rc" = 5 ] && [ "$(get wireless.radio1.country)" = US ] && ok "D-5: netifd not settled -> rc 5, nothing written" || no "D-5 settle: rc $rc"
# 9. design D-6: a restore that does not verify is 6 (the AP never goes off the air), after one more full `wifi`
reset; : > "$ST/ap-fails"; : > "$ST/stuck-on"
o=$(printf '%s\n' "$PASS1" | run --ap - --ap-ssid "Team 1" --ap-section default_radio0 --rollback 2>&1); rc=$?
rm -f "$ST/stuck-on"
[ "$rc" = 6 ] && grep -q "RESTORE NOT VERIFIED" <<< "$o" && ok "D-6: restore not verified (still on the air) -> rc 6" || no "D-6: rc $rc ($o)"
[ "$(grep -cx 'wifi ' "$ST/wifi.log" 2>/dev/null)" -ge 1 ] && ok "D-6: one more full wifi before rc 6" || no "D-6: no full wifi retry ($(tr '\n' ' ' < "$ST/wifi.log"))"
# 10. a previous key / ssid that uci batch cannot take back (set outside the app) -> 6, no batch with it (security m2)
reset; sed -i -e "s/^wireless.default_radio0.ssid=.*/wireless.default_radio0.ssid=Tom's AP/" -e "s/^wireless.default_radio0.key=.*/wireless.default_radio0.key=Oldkey123456789/" -e '/^wireless.default_radio0.disabled=/d' "$ST/live"; cp "$ST/live" "$ST/committed"
: > "$ST/ap-fails"; : > "$ST/argv.log"
o=$(printf '%s\n' "$PASS1" | run --ap - --ap-ssid "Team 1" --ap-section default_radio0 --rollback 2>&1); rc=$?
[ "$rc" = 2 ] && [ "$(get wireless.default_radio0.ssid)" = "Tom's AP" ] && [ "$(get wireless.default_radio0.key)" = Oldkey123456789 ] && [ -z "$(get wireless.default_radio0.disabled)" ] && ! grep -q "batch" "$ST/argv.log" && ok "unquotable previous ssid -> rc 2 before any change (nothing written)" || no "unquotable: rc $rc ssid [$(get wireless.default_radio0.ssid)] ($o)"
# the same with the AP disabled before: it stays disabled and in the mark (B r2 m1's scenario)
reset; sed -i -e "s/^wireless.default_radio0.key=.*/wireless.default_radio0.key=Old'key123456/" "$ST/live"; cp "$ST/live" "$ST/committed"; : > "$ST/ap-fails"
printf '%s\n' "$PASS1" | run --ap - --ap-ssid "Team 1" --ap-section default_radio0 --rollback >/dev/null 2>&1; rc=$?
[ "$rc" = 2 ] && [ "$(get wireless.default_radio0.disabled)" = 1 ] && grep -q default_radio0 "$ST/mark" && ok "unquotable key on a disabled AP -> rc 2, AP stays disabled + in the mark" || no "unquotable disabled: rc $rc disabled [$(get wireless.default_radio0.disabled)]"
# 11. a passphrase with a second line is refused, not cut (security m1)
reset; o=$(printf '%s\nxyz\n' "$PASS1" | run --ap - --ap-ssid T --ap-section default_radio0 --rollback 2>&1); rc=$?
[ "$rc" = 2 ] && [ "$(get wireless.default_radio0.key)" = "$PL" ] && ok "passphrase with a second line -> rc 2, nothing written" || no "two lines: rc $rc key $(get wireless.default_radio0.key | cut -c1-4)"
# 12. uci batch did not land -> rc 3 before any reload (code review m2)
reset; : > "$ST/batch-fails"; : > "$ST/wifi.log"
o=$(printf '%s\n' "$PASS1" | run --ap - --ap-ssid "Team 1" --ap-section default_radio0 --rollback 2>&1); rc=$?
rm -f "$ST/batch-fails"
[ "$rc" = 3 ] && grep -q "uci read back" <<< "$o" && ok "uci batch not landed -> rc 3 (uci read back)" || no "batch fails: rc $rc ($o)"
# 13. back to blocked with no previous ssid -> the new ssid is deleted, not kept (code review m3)
reset; sed -i '/^wireless.default_radio0.ssid=/d' "$ST/live"; cp "$ST/live" "$ST/committed"; : > "$ST/ap-fails"
printf '%s\n' "$PASS1" | run --ap - --ap-ssid "Team 1" --ap-section default_radio0 --rollback >/dev/null 2>&1; rc=$?
[ "$rc" = 3 ] && [ -z "$(get wireless.default_radio0.ssid)" ] && ok "restore with no previous ssid -> ssid deleted" || no "empty old ssid: rc $rc ssid [$(get wireless.default_radio0.ssid)]"
# 14. the ssid read back is literal: iw showing "Teaxm" is not "Tea.m" (security m3)
reset; echo Teaxm > "$ST/iw-ssid"
printf '%s\n' "$PASS1" | run --ap - --ap-ssid "Tea.m" --ap-section default_radio0 --rollback >/dev/null 2>&1; rc=$?
[ "$rc" = 3 ] && ok "ssid read back literal: Teaxm on the air is not Tea.m -> rc 3" || no "regex read back: rc $rc"
# 15. the same value again: 0, nothing written, no reload (code review m6)
reset; run --country US --rollback >/dev/null 2>&1; rc=$?
[ "$rc" = 0 ] && ! grep -qx -- --save "$ST/cfgsave.log" && ok "country equal to the current one, p5 fresh -> 0, nothing saved" || no "same country: rc $rc"
reset; printf '%s\n' "$PASS1" | run --ap - --ap-ssid "Team 1" --ap-section default_radio0 --rollback >/dev/null 2>&1; : > "$ST/wifi.log"; : > "$ST/cfgsave.log"
o=$(printf '%s\n' "$PASS1" | run --ap - --ap-ssid "Team 1" --ap-section default_radio0 --rollback 2>&1); rc=$?
[ "$rc" = 0 ] && [ ! -s "$ST/wifi.log" ] && ! grep -qx -- --save "$ST/cfgsave.log" && ok "AP equal and on the air, p5 fresh -> 0, no reload, no save" || no "same AP: rc $rc wifi [$(tr '\n' ' ' < "$ST/wifi.log")] ($o)"
# 16. A r2 MAJOR-2: the same value with p5 stale (power lost between a commit and its save) -> saved now
reset; : > "$ST/p5-stale"; run --country US --rollback >/dev/null 2>&1; rc=$?
[ "$rc" = 0 ] && grep -qx -- --save "$ST/cfgsave.log" && ok "country equal but p5 stale -> saved, 0" || no "same country p5 stale: rc $rc ($(tr '\n' ' ' < "$ST/cfgsave.log"))"
reset; : > "$ST/p5-stale"; : > "$ST/save-fails"; run --country US --rollback >/dev/null 2>&1; rc=$?
[ "$rc" = 4 ] && ok "country equal, p5 stale, save fails -> 4" || no "same country save fails: rc $rc"
reset; printf '%s\n' "$PASS1" | run --ap - --ap-ssid "Team 1" --ap-section default_radio0 --rollback >/dev/null 2>&1; : > "$ST/p5-stale"; : > "$ST/cfgsave.log"
printf '%s\n' "$PASS1" | run --ap - --ap-ssid "Team 1" --ap-section default_radio0 --rollback >/dev/null 2>&1; rc=$?
[ "$rc" = 0 ] && grep -qx -- --save "$ST/cfgsave.log" && ok "AP equal but p5 stale -> saved, 0" || no "same AP p5 stale: rc $rc"
# 17. A r2 m2: a verified restore after rc 3 with p5 stale (something saved the unverified value) -> saved
reset; : > "$ST/ap-fails"; : > "$ST/p5-stale"
printf '%s\n' "$PASS1" | run --ap - --ap-ssid "Team 1" --ap-section default_radio0 --rollback >/dev/null 2>&1; rc=$?
[ "$rc" = 3 ] && grep -qx -- --save "$ST/cfgsave.log" && ok "rc 3 restore with p5 stale -> saved after the restore" || no "rc3 p5 stale: rc $rc ($(tr '\n' ' ' < "$ST/cfgsave.log"))"
# 18. B r2 C1: a real previous key with no ssid -> restore deletes the ssid (not ''), rc 3
reset; sed -i -e '/^wireless.default_radio0.ssid=/d' -e "s/^wireless.default_radio0.key=.*/wireless.default_radio0.key=Oldkey123456789/" -e '/^wireless.default_radio0.disabled=/d' "$ST/live"; cp "$ST/live" "$ST/committed"; : > "$ST/ap-fails"
printf '%s\n' "$PASS1" | run --ap - --ap-ssid "Team 1" --ap-section default_radio0 --rollback >/dev/null 2>&1; rc=$?
[ "$rc" = 3 ] && ! grep -q "^wireless.default_radio0.ssid=" "$ST/committed" && [ "$(get wireless.default_radio0.key)" = Oldkey123456789 ] && ok "real key, no previous ssid -> ssid deleted on restore (rc $rc)" || no "no old ssid: rc $rc ssid [$(get wireless.default_radio0.ssid)]"
# 19. A r2 m4: a previously disabled AP with a real key is verified off the air: stuck on -> 6
reset; sed -i -e "s/^wireless.default_radio0.key=.*/wireless.default_radio0.key=Oldkey123456789/" "$ST/live"; cp "$ST/live" "$ST/committed"; : > "$ST/ap-fails"; : > "$ST/stuck-on"
printf '%s\n' "$PASS1" | run --ap - --ap-ssid "Team 1" --ap-section default_radio0 --rollback >/dev/null 2>&1; rc=$?; rm -f "$ST/stuck-on"
[ "$rc" = 6 ] && [ "$(get wireless.default_radio0.disabled)" = 1 ] && ok "disabled AP with a real key, still on the air after the restore -> 6" || no "disabled real key stuck: rc $rc"
# 20. B r2 A5: a CR inside the passphrase is refused (only a trailing CR is dropped)
reset; o=$(printf 'Abcdef\rgh12345\n' | run --ap - --ap-ssid T --ap-section default_radio0 --rollback 2>&1); rc=$?
[ "$rc" = 2 ] && [ "$(get wireless.default_radio0.key)" = "$PL" ] && ok "CR inside the passphrase -> 2" || no "inner CR: rc $rc"
reset; printf '%s\r\n' "$PASS1" | run --ap - --ap-ssid "Team 1" --ap-section default_radio0 --rollback >/dev/null 2>&1; rc=$?
[ "$rc" = 0 ] && [ "$(get wireless.default_radio0.key)" = "$PASS1" ] && ok "trailing CR dropped -> 0, key as sent" || no "trailing CR: rc $rc"
# 21. A r3 m3: a disabled AP with a real key whose change fails -> verified OFF and rc 3 (not assumed, not 6)
reset; sed -i -e "s/^wireless.default_radio0.key=.*/wireless.default_radio0.key=Oldkey123456789/" "$ST/live"; cp "$ST/live" "$ST/committed"; : > "$ST/ap-fails"
printf '%s\n' "$PASS1" | run --ap - --ap-ssid "Team 1" --ap-section default_radio0 --rollback >/dev/null 2>&1; rc=$?
[ "$rc" = 3 ] && [ "$(get wireless.default_radio0.disabled)" = 1 ] && [ "$(get wireless.default_radio0.key)" = Oldkey123456789 ] && ok "disabled AP + real key, change fails -> rc 3, back disabled with the old key" || no "disabled real key: rc $rc"
# 22. A r3 m4 (D-6): still on the air after the reload, off after one full `wifi` -> verified, rc 3 (not 6)
reset; : > "$ST/ap-fails"; : > "$ST/stuck-on"; : > "$ST/stuck-until-wifi"
printf '%s\n' "$PASS1" | run --ap - --ap-ssid "Team 1" --ap-section default_radio0 --rollback >/dev/null 2>&1; rc=$?; rm -f "$ST/stuck-on" "$ST/stuck-until-wifi"
[ "$rc" = 3 ] && ok "D-6: off only after the full wifi -> rc 3 (the second try is what verifies it)" || no "D-6 full wifi: rc $rc"
# 23. B r3 m1: a value flag with no value -> usage (2) at once, not an endless loop
for fl in --country --ap-ssid --ap-section --mesh-id; do
	timeout 10 env PATH="$ST/bin:$PATH" busybox sh "$T/sk" --rollback "$fl" >/dev/null 2>&1; rc=$?
	[ "$rc" = 2 ] && ok "$fl with no value -> 2" || no "$fl with no value: rc $rc (124 = loop)"
done
echo "SETKEY-SETTINGS cases=$cases fails=$fails"
[ "$cases" -gt 0 ] && [ "$fails" = 0 ]
