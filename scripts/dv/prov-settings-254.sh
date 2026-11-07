#!/bin/bash
# scripts/dv/prov-settings-254.sh — #254 H4 appendix A.3, the R rows (member base state, helper level, p3-how "h"):
#   ST1  settings.get: code 0, the country / name equal uci, the AP passphrase is not in the output
#   ST15 key 2 on a member -> E_REJECTED{14} (helper 21 reason=14), uci unchanged
#   ST17 key 1 -> E_UNSUPPORTED (6, rename-pending until U5)
#   ST10 key 20 with `$` in the passphrase -> E_REJECTED{13} (21 reason=13), AP unchanged
#   ST13 another process's staged uci wireless change -> key 20 answers E_BUSY (7), status key 15 names wireless;
#        the staged change is still only staged afterwards (nobody committed it), then reverted by the unit
#   ST4(P) key 20 with fresh test credentials, drawn on the node: code 0, uci ssid == the new one, hostapd re-read,
#        the member's plink stays ESTAB across it (the S arm with the setkey-full-restart seam is in the RB unit)
# Not here: ST2 / 3 / 5 / 7 / 14 / 20 (F: a fresh card), ST6 / 8 / 9 / 12 / 16 / 19 (RB: seams), ST11 (holding
# halow-setkey's lock: with the RB unit), ST22 (a measurement). The P3 helper codes: 254-p3-impl §5.1 + provd's
# mapping (F38): E_REJECTED = 21 + reason, E_BUSY = 7, E_UNSUPPORTED = 6.
# W (pre-P3 image): settings.get is unknown (20), settings.set takes only the hostname -> every row FAILs with the
# code it got; prov-p3-verbs-254 names the image pre-P3.
# Type: R. Side effects: the AP credentials are changed to test values and put back by the restore (one reboot).
set -u
PR_UNIT=prov-settings-254
PR_BASE=member
# shellcheck source=scripts/dv/prov-254.sh
. "$(dirname "$0")/prov-254.sh"
pr_begin 1500 || { pr_result; exit 1; }
pr_keys && pr_pc_place || { pr_abort "provclient"; pr_result; exit 1; }
# the node's values the rows compare with (read-only)
CC=$(qr 'uci -q get wireless.radio1.country'); HN=$(qr 'uci -q get system.@system[0].hostname')
APIF=$(qr "ubus call network.wireless status 2>/dev/null | sed -n 's/.*\"ifname\": \"\\(phy[0-9]*-ap[0-9]*\\)\".*/\\1/p' | head -1")
KEYSHA=$(qr 'uci -q get wireless.default_radio0.key | tr -d "\n" | sha256sum | cut -c1-16')   # never the value
say "node: country=$CC hostname=$HN ap=${APIF:-?} ap_key_sha=$KEYSHA"
code(){ sed -n 's/.* code=\([0-9]*\).*/\1/p' <<< "$1" | head -1; }
reason(){ sed -n 's/.* reason=\([0-9]*\).*/\1/p' <<< "$1" | head -1; }
# ---- ST1 get
r=$(pr_pc owner.pem -- settings-get "$OWNER" | grep '^RESULT settings.get'); say "ST1: $(cut -c1-160 <<< "$r")"
if [ "$(code "$r")" = 0 ]; then
	grep -q " keys=.*\b2\b" <<< "$r" && grep -qF "$CC" <<< "$r" && ok "ST1: settings.get code 0, country $CC present" || no "ST1: settings.get answered but without the country ($CC): [$r]"
	k=$(qr 'uci -q get wireless.default_radio0.key'); [ -n "$k" ] && grep -qF -- "$k" <<< "$r" && no "ST1: the AP passphrase is in settings.get's output" || ok "ST1: the AP passphrase is not in the output"
else no "ST1: settings.get code $(code "$r") (want 0): [$r]"; fi
# ---- ST15 key 2 on a member
r=$(pr_pc owner.pem -- settings-set "$OWNER" 2 DE | grep '^RESULT settings.set'); say "ST15: $r"
[ "$(code "$r")" = 21 ] && [ "$(reason "$r")" = 14 ] && ok "ST15: key 2 on a member -> E_REJECTED{14}" || no "ST15: key 2 on a member: code $(code "$r") reason $(reason "$r") (want 21 / 14)"
c=$(qr 'uci -q get wireless.radio1.country'); [ "$c" = "$CC" ] && ok "ST15: country unchanged ($c)" || no "ST15: country changed: $CC -> $c"
# ---- ST17 key 1
r=$(pr_pc owner.pem -- settings-set "$OWNER" 1 "dv-rename-$RUN" | grep '^RESULT settings.set'); say "ST17: $r"
[ "$(code "$r")" = 6 ] && ok "ST17: key 1 -> E_UNSUPPORTED (rename-pending)" || no "ST17: key 1: code $(code "$r") (want 6)"
h=$(qr 'uci -q get system.@system[0].hostname'); [ "$h" = "$HN" ] && ok "ST17: hostname unchanged" || no "ST17: hostname changed: $HN -> $h"
# ---- ST10 `$` in the passphrase (made on the node, fd 3; never argv)
r=$(pr_pc owner.pem FD3="printf 'ssid=%s\npsk=%s\n' 'dv-$RUN' 'bad\$pass-12345678'" -- settings-set "$OWNER" 20 | grep '^RESULT settings.set'); say "ST10: $r"
[ "$(code "$r")" = 21 ] && [ "$(reason "$r")" = 13 ] && ok "ST10: a passphrase with \$ -> E_REJECTED{13}" || no "ST10: code $(code "$r") reason $(reason "$r") (want 21 / 13)"
s=$(qr 'uci -q get wireless.default_radio0.key | tr -d "\n" | sha256sum | cut -c1-16'); [ "$s" = "$KEYSHA" ] && ok "ST10: AP key unchanged" || no "ST10: AP key changed"
# ---- ST13 a staged change of someone else -> E_BUSY, status says so
q "uci set wireless.default_radio0.ssid='staged-$RUN'" >/dev/null
st=$(qr 'ls /tmp/.uci/wireless 2>/dev/null | wc -l'); [ "$st" = 1 ] && say "ST13: wireless change staged (not committed)" || no "ST13: could not stage a uci change [$st]"
r=$(pr_pc owner.pem FD3="umask 077; s=\$(head -c 12 /dev/urandom | hexdump -v -e '1/1 \"%02x\"'); printf 'ssid=%s\npsk=%s\n' 'dv-$RUN' \"\$s\"" -- settings-set "$OWNER" 20 | grep '^RESULT settings.set'); say "ST13: $r"
[ "$(code "$r")" = 7 ] && ok "ST13: key 20 with a staged wireless change -> E_BUSY" || no "ST13: code $(code "$r") (want 7 E_BUSY)"
r2=$(pr_pc owner.pem -- status-get "$OWNER" | grep '^RESULT status.get'); say "ST13: $(cut -c1-200 <<< "$r2")"
grep -q "f15=.*wireless" <<< "$r2" && ok "ST13: status key 15 names the staged package" || no "ST13: status key 15 does not name wireless: [$r2]"
x=$(qr 'echo "staged=$(ls /tmp/.uci/wireless 2>/dev/null | wc -l) ssid=$(uci -q get wireless.default_radio0.ssid)"; uci revert wireless; echo "after_revert=$(ls /tmp/.uci/wireless 2>/dev/null | wc -l)"'); say "ST13: $(echo $x)"
case "$(echo $x)" in "staged=1 ssid=staged-$RUN after_revert=0") ok "ST13: the staged change was not committed by anybody, reverted";; *) no "ST13: staging state afterwards: $(echo $x)";; esac
# ---- ST4(P) key 20 with fresh test credentials (drawn on the node): applied, plink stays
P0=$(qr 'iw dev wlh0 station dump 2>/dev/null | grep -c "plink:.*ESTAB"')
r=$(pr_pc owner.pem FD3="umask 077; s=\$(head -c 16 /dev/urandom | hexdump -v -e '1/1 \"%02x\"'); printf 'ssid=%s\npsk=%s\n' 'dv-$RUN' \"\$s\"" PROVCLIENT_TIMEOUT_S=600 -- settings-set "$OWNER" 20 | grep '^RESULT settings.set'); say "ST4(P): $r"
if [ "$(code "$r")" = 0 ]; then
	ok "ST4(P): key 20 code 0"
	x=$(qr "echo ssid=\$(uci -q get wireless.default_radio0.ssid) keysha=\$(uci -q get wireless.default_radio0.key | tr -d '\n' | sha256sum | cut -c1-16) hostapd_ssid=\$(grep -h '^ssid=' /tmp/run/hostapd-*.conf 2>/dev/null | head -1 | cut -d= -f2) plink=\$(iw dev wlh0 station dump 2>/dev/null | grep -c 'plink:.*ESTAB')")
	say "ST4(P): $(echo $x)"
	case "$(echo $x)" in "ssid=dv-$RUN keysha="*) ;; *) no "ST4(P): uci does not hold the new ssid: $(echo $x)";; esac
	case "$(echo $x)" in *"keysha=$KEYSHA "*) no "ST4(P): the AP key did not change";; *"keysha="????????????????" "*) ok "ST4(P): uci holds a new AP key";; esac
	case "$(echo $x)" in *"hostapd_ssid=dv-$RUN "*) ok "ST4(P): hostapd runs the new ssid";; *) no "ST4(P): hostapd not on the new ssid: $(echo $x)";; esac
	case "$(echo $x)" in *"plink=$P0") ok "ST4(P): plink count unchanged ($P0)";; *) no "ST4(P): plink count changed from $P0: $(echo $x)";; esac
else no "ST4(P): key 20: code $(code "$r") reason $(reason "$r") (want 0): [$r]"; fi
pr_end
pr_result
