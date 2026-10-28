#!/bin/sh
# scripts/node/prov-lease-254.sh — #254 prov lease + deadman on the node (docs/design/254-h23-harness.md §3, §4.3).
# The BLE lease machinery of ble-lib-254.sh on its own lease file, $BT/lease-prov "<run> <boot> <expiry uptime>": a BLE
# run and a prov run exclude each other (each acquire FAILs while the other's lease is live) and share the one deadman
# record ($ST/dm). Staged by scripts/dv/prov-254.sh with ble-lib-254.sh and prov-wbox-254.sh in
# /tmp/run/batman-dv/bt/<run>/ (root 0700) after every boot; run as  RUN_ID=<run> sh <that dir>/prov-lease-254.sh <cmd>
#   stage-check             the staged files are root regular files with one link; prints their sha256
#   acquire <secs>          lease + deadman (<secs> + 5)
#   renew <secs>            extend the lease and re-arm the deadman, under the same lock
#   release                 cancel the deadman, drop the lease and this run's dir
#   restoring set|clear     tmpfs marker $BT/restoring.<run>: the deadman stops after its cleanup (pr_restore owns the
#                           services and the reboot)
#   normalising set|clear   p6 marker dv-prov-normalising "<run> <boot>" (pr_normalise; preflight P9 FAILs on it)
#   state                   lease, deadman, markers
# The deadman (dm-fire, after <secs> + 5 without a renew): prov-wbox unbind-all (umount every harness bind, restart an
# armed helper, rm -rf the killpoint dir), drop a harness helper copy from the upper (sha != /rom), then — unless
# restoring — start joinwatch / openmanetd / tailscaled again. It never touches a slot or p5; the dirty flag stays (the
# next preflight prints the restore command).
SELF=$(readlink -f "$0"); DIR=$(dirname "$SELF")
# shellcheck source=scripts/node/ble-lib-254.sh
. "$DIR/ble-lib-254.sh"
LEASE=$BT/lease-prov
RUN_ID=${RUN_ID:-}
NORM=/opt/batdata/state/dv-prov-normalising
UPH=/overlay/upper/usr/bin/batman-provhelper   # read only (cmp); never written or removed here

cmd_stage_check() {
	for t in "$DIR/ble-lib-254.sh" "$DIR/prov-wbox-254.sh" "$SELF"; do file_ok "$t" || die "$t is not a root regular file with one link"; done
	dir_ok "$DIR" drwx------ || die "$DIR is not a root 0700 directory"
	sha256sum "$DIR/ble-lib-254.sh" "$DIR/prov-wbox-254.sh" "$SELF" | sed "s#$DIR/##"
}
role_fire_restore() {	# $1 run (or "recover")
	dm_log "$1" "prov deadman: unbind-all, killpoint dir, harness helper copy in the upper"
	[ -f "$DIR/prov-wbox-254.sh" ] && RUN_ID=$1 lim 120 sh "$DIR/prov-wbox-254.sh" unbind-all >/dev/null 2>&1
	rm -rf /tmp/run/batman-prov-test
	# a harness helper copy in the upper: the release helper is written back THROUGH the overlay (never an rm under the
	# mounted upper — undefined in overlayfs, 2026-10-28 04 needed a reboot after one), then what runs is verified
	if [ -f "$UPH" ] && ! cmp -s "$UPH" /rom/usr/bin/batman-provhelper; then
		dm_log "$1" "prov deadman: the upper carries a harness helper — writing the release helper back"
		cp /rom/usr/bin/batman-provhelper /usr/bin/batman-provhelper.dvrel && mv /usr/bin/batman-provhelper.dvrel /usr/bin/batman-provhelper && sync
		lim 60 /etc/init.d/batman-provhelper restart >/dev/null 2>&1; sleep 3
		p=$(pidof batman-provhelper | awk '{print $1}')
		[ -n "$p" ] && cmp -s "/proc/$p/exe" /rom/usr/bin/batman-provhelper \
			|| dm_log "$1" "prov deadman: NEEDS-PERSON — the running helper (pid ${p:-none}) is not the release helper; dirty flag kept"
	fi
	[ -e "$BT/restoring.$1" ] && { dm_log "$1" "prov deadman: restoring in progress — services left to pr_restore"; return 0; }
	for s in joinwatch openmanetd tailscaled; do [ -x "/etc/init.d/$s" ] && lim 60 "/etc/init.d/$s" start >/dev/null 2>&1; done
	return 0
}
cmd_state() {
	echo "STATE lease-prov=[$(cat "$LEASE" 2>/dev/null)] lease=[$(cat "$BT/lease" 2>/dev/null)] boot=$(bootid) up=$(up_s)"
	for rec in "$ST/dm" "$ST/dm.new"; do [ -f "$rec" ] && echo "STATE ${rec##*/}=[$(cat "$rec")] alive=$(dm_rec_alive "$rec" && echo 1 || echo 0)"; done
	ls "$BT"/restoring.* 2>/dev/null | sed 's/^/STATE restoring /'
	[ -f "$NORM" ] && echo "STATE normalising=[$(cat "$NORM")]"
	return 0
}

c=${1:-}; [ $# -gt 0 ] && shift
case "$c" in
	dm-fire) cmd_dm_fire "$@" ;;
	state) cmd_state; exit 0 ;;
	*) [ -n "$RUN_ID" ] || die "RUN_ID unset"; case "$RUN_ID" in *[!A-Za-z0-9_-]*) die "bad RUN_ID" ;; esac ;;
esac
case "$c" in
	stage-check) cmd_stage_check ;;
	acquire) cmd_acquire "$@" ;;
	renew) cmd_arm "$@" ;;
	release) cmd_release ;;
	restoring)
		case "${1:-}" in set) held; echo "$RUN_ID $(bootid)" > "$BT/restoring.$RUN_ID"; unlock; echo "RESTORING set" ;;
			clear) rm -f "$BT/restoring.$RUN_ID"; echo "RESTORING clear" ;; *) die "usage: restoring set|clear" ;; esac ;;
	normalising)
		case "${1:-}" in set) held; echo "$RUN_ID $(bootid)" > "$NORM.tmp" && mv "$NORM.tmp" "$NORM" && sync; unlock; echo "NORMALISING set" ;;
			clear) [ ! -f "$NORM" ] || [ "$(cut -d' ' -f1 "$NORM")" = "$RUN_ID" ] || die "normalising marker is another run's: $(cat "$NORM")"
				rm -f "$NORM"; sync; echo "NORMALISING clear" ;;
			*) die "usage: normalising set|clear" ;; esac ;;
	*) echo "usage: RUN_ID=<run> prov-lease-254.sh stage-check|acquire <s>|renew <s>|release|restoring set|clear|normalising set|clear|state"; exit 2 ;;
esac
