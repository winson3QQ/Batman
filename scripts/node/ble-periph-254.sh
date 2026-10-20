#!/bin/sh
# scripts/node/ble-periph-254.sh — the BLE device under test (BLE_PERIPH = 04) for the #254 tier-B suites
# (PR-H1, docs/design/254-h1-harness.md §4.7). Staged with ble-lib-254.sh, btmgmt and btmon in
# /tmp/run/batman-dv/bt/<run_id>/ (root 0700) and run as:  RUN_ID=<id> sh <that dir>/ble-periph-254.sh <cmd> ...
# Every state change happens under the lease of RUN_ID, after the harness re-armed the deadman (`arm`).
# `irk` is the only command that prints the IRK (to stdout, for ble-ah.py's stdin); nothing else ever does.
set -u
SELF=$(readlink -f "$0"); DIR=$(dirname "$SELF")
. "$DIR/ble-lib-254.sh"
BTMGMT=$DIR/btmgmt; BTMON=$DIR/btmon
RUN_ID=${RUN_ID:-}

tool_ok() { file_ok "$1" && [ "$(ls -ln "$1" | awk '{print $1}')" = "-rwx------" ]; }
mg() { "$BTMGMT" "$@" 2>&1 | clean; }
identity() { ls /var/lib/bluetooth/*/identity 2>/dev/null | head -1; }

ad_name() {	# AD structure "Complete Local Name" as hex: len, 0x09, bytes
	n=$1; [ ${#n} -le 26 ] || die "name too long"
	printf '%02x09' $(( ${#n} + 1 )); printf '%s' "$n" | hexdump -v -e '/1 "%02x"'		# no od on the node
}

cmd_stage_check() {
	dir_ok "$DIR" drwx------ || die "$DIR is not a root 0700 directory"
	for t in "$BTMGMT" "$BTMON" "$DIR/ble-lib-254.sh" "$SELF"; do file_ok "$t" || die "$t is not a root regular file with one link"; done
	tool_ok "$BTMGMT" && tool_ok "$BTMON" || die "btmgmt / btmon are not root 0700"
	v1=$("$BTMGMT" --version 2>&1 | tail -1 | sed "s/^btmgmt: //"); v2=$("$BTMON" --version 2>&1 | tail -1)
	[ "$v1" = 5.72 ] && [ "$v2" = 5.72 ] || die "tool versions btmgmt=[$v1] btmon=[$v2], want 5.72 (missing library?)"
	sha256sum "$BTMGMT" "$BTMON" "$DIR/ble-lib-254.sh" "$SELF" | sed "s#$DIR/##"
	echo "STAGE ok"
}

cmd_info() {
	echo "SETTINGS $(settings)"
	echo "PID $(pidof bluetoothd)"
	a=$(mg advinfo | sed -n 's/^Instances list with \([0-9]*\) item.*/\1/p'); echo "ADV ${a:-?}"
	sc_check >/dev/null 2>&1 && echo "SC ok" || echo "SC bad"
}

cmd_adv_on() {	# <name> [connectable]
	held; [ -n "${1:-}" ] || die "usage: adv-on <name> [connectable]"
	c=""; [ "${2:-}" = connectable ] && c="-c"
	mg rm-adv 1 >/dev/null
	o=$(mg add-adv $c -g -u 181c -d "$(ad_name "$1")" 1)
	case "$o" in *"nstance added"*|*"Instance: 1"*) ;; *) unlock; die "add-adv failed: $o";; esac
	a=$(mg advinfo | sed -n 's/^Instances list with \([0-9]*\) item.*/\1/p')
	unlock; [ "$a" = 1 ] || die "after add-adv the controller lists [$a] instances"
	echo "ADV on name=$1 ${c:+connectable}"
}
cmd_adv_off() { held; mg rm-adv 1 >/dev/null; a=$(mg advinfo | sed -n 's/^Instances list with \([0-9]*\) item.*/\1/p'); unlock; [ "$a" = 0 ] || die "adv instances left: [$a]"; echo "ADV off"; }

cmd_flip() {	# white-box: SC-only off (secure-conn stays on); IRK may leak from here on
	held; mark_set flipped "$RUN_ID"; mark_set irk-exposed "$RUN_ID"
	o=$(mg sc on); s=$(settings); unlock
	has_tok "$s" secure-conn || die "flip: secure-conn gone after 'sc on' ($o)"
	echo "FLIPPED (SC-only cleared; flipped + irk-exposed marked)"
}
cmd_privacy_off() {	# white-box N1: powered => kernel rejects privacy (E7) -> power off / privacy off / power on
	held; mark_set flipped "$RUN_ID"
	mg power off >/dev/null; o=$(mg privacy off); mg power on >/dev/null; s=$(settings); unlock
	has_tok "$s" privacy && die "privacy still on after the off sequence ($o)"
	echo "PRIVACY off (flipped marked; restore = bluetoothd restart)"
}
cmd_restore() {	# power off first (E27), restart bluetoothd, wait for a new pid + batman-sc; clears `flipped`
	held; old=$(pidof bluetoothd)
	mg power off >/dev/null; /etc/init.d/bluetoothd restart >/dev/null 2>&1
	new=$(wait_bluetoothd "$old") || { unlock; die "bluetoothd did not come back with a valid batman-sc within 20 s"; }
	mark_clear flipped; unlock
	echo "RESTORED pid $old -> $new settings: $(settings)"
}
irk_hash() { f=$(identity); [ -f "$f" ] && sed -n 's/^IdentityResolvingKey=//p' "$f" | tr 'A-F' 'a-f' | sha256sum | cut -c1-8; }
cmd_irk_hash() { h=$(irk_hash); [ -n "$h" ] || die "no IRK"; echo "IRKHASH $h"; }
cmd_irk() { held; f=$(identity); unlock; [ -f "$f" ] || die "no identity"; sed -n 's/^IdentityResolvingKey=//p' "$f"; }
rm_ids() {	# delete the adapter identity + peer dirs (name = a MAC) in the root-only store; prints paths only
	dir_ok /tmp/lib/bluetooth drwx------ || { echo "FAIL /tmp/lib/bluetooth is not root 0700 — not deleting"; return 1; }
	for a in /tmp/lib/bluetooth/*/; do
		b=$(basename "$a"); echo "$b" | grep -qE '^([0-9A-F]{2}:){5}[0-9A-F]{2}$' || continue
		[ -L "${a%/}" ] && continue
		echo "REKEY rm $b/identity"; rm -f "$a/identity"
		for d in "$a"*/; do
			p=$(basename "$d"); echo "$p" | grep -qE '^([0-9A-F]{2}:){5}[0-9A-F]{2}$' || continue
			[ -L "${d%/}" ] && continue; echo "REKEY rm $b/$p/"; rm -rf "${a:?}$p"
		done
	done
}
cmd_rekey() {	# void the IRK without a reboot: power off, stop, delete identity + peer dirs, start (E8, E27)
	held; old=$(irk_hash); [ -n "$old" ] || { unlock; die "no IRK before rekey"; }
	if [ "${1:-}" = nopoweroff ]; then
		# white-box N11 (E31): delete while running, then SIGKILL -> procd respawns bluetoothd with the adapter
		# still powered -> the new IRK reaches the file but not the kernel. The kernel check must catch it.
		rm_ids || { unlock; exit 1; }
		kill -9 "$(pidof bluetoothd)"
	else
		mg power off >/dev/null
		/etc/init.d/bluetoothd stop >/dev/null 2>&1
		n=0; while pidof bluetoothd >/dev/null && [ $n -lt 10 ]; do sleep 1; n=$((n + 1)); done
		pidof bluetoothd >/dev/null && { unlock; die "bluetoothd did not stop"; }
		rm_ids || { unlock; exit 1; }
		/etc/init.d/bluetoothd start >/dev/null 2>&1
	fi
	new=$(wait_bluetoothd "") || { unlock; die "bluetoothd did not come back after rekey"; }
	nh=$(irk_hash); unlock
	[ -n "$nh" ] && [ "$nh" != "$old" ] || die "IRK file unchanged after rekey ($old -> $nh)"
	echo "REKEYED file $old -> $nh pid $new (irk-exposed kept until the kernel is verified via an RPA)"
}
cmd_rekey_verified() { held; mark_clear irk-exposed; unlock; echo "IRK-EXPOSED cleared"; }

# ---- btmon: one recording per label; judged ON the node, the snoop never leaves it (design §4.7)
cmd_btmon_start() { held; [ -n "${1:-}" ] || { unlock; die "usage: btmon-start <label>"; }; rm -f "$DIR/$1.snoop"; bg_start "btmon-$1" "$BTMON" -w "$DIR/$1.snoop" || { unlock; exit 1; }; unlock; echo "BTMON $1 started"; }
cmd_btmon_stop() {
	held; bg_stop "btmon-$1" || { unlock; die "btmon group did not exit"; }; unlock
	[ -s "$DIR/$1.snoop" ] || die "no snoop for $1"
	"$BTMON" -r "$DIR/$1.snoop" 2>/dev/null | clean | btmon_judge
}
cmd_btmon_dump_masked() {	# fixture capture (§4.7): headers, event names, Reason/Status kept; every other value masked
	[ -s "$DIR/$1.snoop" ] || die "no snoop for $1"
	"$BTMON" -r "$DIR/$1.snoop" 2>/dev/null | clean | awk '
		{ gsub(/([0-9A-Fa-f][0-9A-Fa-f]:){5}[0-9A-Fa-f][0-9A-Fa-f]/, "00:00:00:00:00:00") }
		/^[<>@=] / { sub(/ +(#[0-9]+ +)?(\[hci0\] +)?(\{0x[0-9a-f]+\} +)?(\[hci0\] +)?[0-9]+\.[0-9]+$/, ""); print; next }
		/^ +(SMP|L2CAP|LE [A-Za-z ]*Complete|ATT): / || /^ +LE [A-Za-z ]*Complete/ { print; next }
		/^ +(Reason|Status): / { print; next }
		/^ +[A-Za-z][A-Za-z ()\/-]*:/ { match($0, /^ +[A-Za-z][A-Za-z ()\/-]*:/); print substr($0, 1, RLENGTH) " <masked>"; next }
		{ match($0, /^ */); print substr($0, 1, RLENGTH) "<masked>" }'
}
cmd_snoop_clean() { held; rm -f "$DIR"/*.snoop; unlock; echo "SNOOP cleaned"; }

btmon_judge() {	# btmon -r text -> verdict lines. Sections (6-space indent) decide what a deeper line belongs to:
	# only SMP sections, LE (Enhanced) Connection Complete and Disconnect Complete are judged; ATT / L2CAP / other
	# LE subevents are not part of the verdict. UNPARSED = unknown lines INSIDE a judged section (design §4.7).
	awk '
	function flush() { if (pend != "") { print pend; pend = "" } }
	BEGIN {
		split("PairingRequest PairingResponse PairingConfirm PairingRandom PairingFailed EncryptionInformation MasterIdentification CentralIdentification IdentityInformation IdentityAddressInformation SigningInformation PairingPublicKey PairingDHKeyCheck SecurityRequest PairingKeypressNotification", w, " ")
		for (i in w) WL[w[i]] = 1
		split("IO capability|OOB data|Authentication requirement|Max encryption key size|Initiator key distribution|Responder key distribution|Confirm value|Confim value|Random value|Long term key|EDIV|Rand|Identity resolving key|Address type|Address|Signature key|X|Y|E|Notification type|Role|Peer address type|Peer address|Local resolvable private address|Peer resolvable private address|Connection interval|Connection latency|Supervision timeout|Central clock accuracy|Master clock accuracy|Handle|Status|Reason", f, "|")
		for (i in f) IGN[f[i]] = 1
		unparsed = 0
	}
	/^[<>@=] / {
		flush(); dir = (substr($0, 1, 1) == "<") ? "TX" : "RX"; blk = "other"; sec = ""
		if ($0 ~ /ACL Data/) blk = "acl"
		else if ($0 ~ /HCI Event: LE Meta Event/) blk = "lemeta"
		else if ($0 ~ /HCI Event: Disconnect Complete/) { blk = "disc"; sec = "disc" }
		next
	}
	blk == "acl" && /^      [^ ]/ {		# a section line of an ACL block
		flush()
		if ($0 ~ /^      SMP: /) {
			s = $0; sub(/^      SMP: /, "", s); sub(/ \(0x[0-9a-fA-F]+\).*$/, "", s); gsub(/[^A-Za-z]/, "", s)
			if (!(s in WL)) { unparsed++; sec = "other"; next }
			sec = "smp"; pend = "SMP " dir " " s; if (s != "PairingFailed") flush()
		} else sec = "other"
		next
	}
	blk == "lemeta" && /^      [^ ]/ { sec = ($0 ~ /^      LE (Enhanced )?Connection Complete/) ? "conn" : "other"; next }
	sec == "smp" && /^ +Reason: / && pend ~ /PairingFailed$/ { match($0, /\(0x[0-9a-fA-F]+\)/); pend = pend " reason=" substr($0, RSTART + 1, RLENGTH - 2); flush(); next }
	sec == "conn" && /^ +Status: / { match($0, /\(0x[0-9a-fA-F]+\)/); print "CONN status=" substr($0, RSTART + 1, RLENGTH - 2); next }
	sec == "disc" && /^ +Reason: / { match($0, /\(0x[0-9a-fA-F]+\)/); print "DISC reason=" substr($0, RSTART + 1, RLENGTH - 2); next }
	(sec == "smp" || sec == "conn" || sec == "disc") && /^ +/ {
		k = $0; sub(/^ +/, "", k); sub(/:.*$/, "", k)
		if (!(k in IGN)) unparsed++
		next
	}
	END { flush(); print "UNPARSED " unparsed }'
}

role_fire_restore() {	# deadman on 04: stop recorders, drop snoops + adv; leaked IRK => reboot (H-U6), else restore
	rm -f "$BT/$1"/*.snoop
	"$BTMGMT" rm-adv 1 >/dev/null 2>&1
	if mark_here irk-exposed; then
		dm_log "$1" "deadman: IRK was exposed and not verified as voided — reboot (H-U6)"
		rm -f "$BT/lease" "$ST/dm" "$ST/dm.new"
		batman-slot reboot committed ble-dm-254; exit 0
	fi
	"$BTMGMT" power off >/dev/null 2>&1; /etc/init.d/bluetoothd restart >/dev/null 2>&1
	wait_bluetoothd "" >/dev/null && mark_clear flipped
}

c=${1:-}; [ $# -gt 0 ] && shift
case "$c" in
	dm-fire) cmd_dm_fire "$@" ;;
	judge) btmon_judge; exit $? ;;		# stdin = btmon -r text (fixture tests on the host)
	*) [ -n "$RUN_ID" ] || die "RUN_ID unset" ;;
esac
case "$c" in
	stage-check) cmd_stage_check ;;
	acquire) cmd_acquire "$@" ;;
	arm) cmd_arm "$@" ;;
	release) cmd_release ;;
	state) ble_state ;;
	info) cmd_info ;;
	adv-on) cmd_adv_on "$@" ;;
	adv-off) cmd_adv_off ;;
	flip) cmd_flip ;;
	privacy-off) cmd_privacy_off ;;
	restore) cmd_restore ;;
	irk) cmd_irk ;;
	irk-hash) cmd_irk_hash ;;
	rekey) cmd_rekey "$@" ;;
	rekey-verified) cmd_rekey_verified ;;
	btmon-start) cmd_btmon_start "$@" ;;
	btmon-stop) cmd_btmon_stop "$@" ;;
	btmon-dump-masked) cmd_btmon_dump_masked "$@" ;;
	snoop-clean) cmd_snoop_clean ;;
	canary) cmd_canary ;;
	*) die "unknown command [$c]" ;;
esac
