#!/bin/bash
# scripts/dv/test-ud-recover-254.sh [BLOCK-FILE] — the offline dry run of the manual recovery block (docs/design/
# 254-v16-ud.md §7.1) that scripts/node/prov-p9-254.sh prints between UD-RECOVER-BEGIN / -END. The block is taken from
# P9's quoted here-doc (or BLOCK-FILE: the negative controls scripts/dv/data/ud-recover-v{5,6,7}.txt, the earlier
# designs' texts), its placeholders filled as P9 / the host fill them, and each step is run from the repo root against
# the REAL sourced scripts/dv/prov-254.sh, with stub ssh / scp / wsl.exe / sleep on PATH. The ssh stub answers from a
# scripted node (slot, boot, uptime, the prov lease, run dirs, the undo journal with its slot bindings, the deadman
# log) and logs every lease / replay / rollback / restore / rewrite / finish / undo call.
# Asserts (§7.1): 1 order on A; 2 B committed + a pending slot:A line -> the rollback before any replay, the replay on
# A; 3 PR_WROTE_B = 1 at pr_restore (the protB-only DIFF is accepted); 4 a failed step-1 replay still releases the
# lease; 5 two dead-run deadman lines -> no deadman FAIL; 6 a live lease of the dead run -> every step ends at its
# acquire, no restore / rollback / replay / host undo (the stub models lease_valid_for: a renew of the dead run's own
# lease succeeds); 7 P9's run-id / version validation (tests/prov-p1/p9-judge.sh's UD cases); 8 no pidof, no
# rm -rf …/bt/; 9 the watcher kill: the exact command text (kill -TERM "-$p", no "--", a group wait) and, run under
# busybox sh against real processes, KILLED for the watcher's group and NOT-THE-WATCHER for a mismatching pid.
# Prints "test-ud-recover: N passed, M failed" (failures name the assert). Zero cases = FAIL.
set -u
H=$(cd "$(dirname "$0")/../.." && pwd)
SRC=${1:-}
W=$(mktemp -d); trap 'kill $(jobs -p) 2>/dev/null; rm -rf "$W"' EXIT
P=0; F=0; ok(){ echo "ok   $*"; P=$((P + 1)); }; bad(){ echo "FAIL $*"; F=$((F + 1)); }
DEAD=pupdate2541123120000; V=1.5.14-wsl.36; NODEIP=10.9.9.9
# ---- the block
if [ -n "$SRC" ]; then grep -v '^# ud-recover-' "$SRC" > "$W/block.raw"
else sed -n "/<<'UDREC'\$/,/^UDREC\$/p" "$H/scripts/node/prov-p9-254.sh" | sed '1d;$d' > "$W/block.raw"; fi
[ -s "$W/block.raw" ] || { bad "no block (P9 here-doc / $SRC)"; echo "test-ud-recover: $P passed, $F failed"; exit 1; }
sed -e "s/@DEAD@/$DEAD/g" -e "s/@V@/$V/g" -e "s/@NODE@/$NODEIP/g" -e "s/^DEAD=<run from dv-prov-dirty>; V=<BATMAN_VERSION of S0, slot A>\$/DEAD=$DEAD; V=$V/" "$W/block.raw" > "$W/block"
# split into steps: "# --- step <id>:" (v6 on) or "# <n>." (v5); a command starts with PR_UNIT= / ssh / DEAD= and runs
# until the next comment or command
awk -v d="$W" '
	/^# --- step [0-9a-z]+:/ { s = $4; sub(":", "", s); next }
	/^# [0-9]+\. / { s = $2; sub("\\.", "", s); next }
	/^#/ { inc = 0; next }
	/^(PR_UNIT=|ssh |DEAD=)/ { if ($0 ~ /^DEAD=/) { print > (d "/pre.sh"); inc = 0; next } inc = 1; n++; f = d "/step-" s "." n ($0 ~ /^ssh / ? ".ssh" : ".sh"); print > f; next }
	inc { print > f }' "$W/block"
touch "$W/pre.sh"
# ---- the stub node
mkdir -p "$W/bin" "$W/node/bt" "$W/tools" "$W/out/$V/ekh-bcm2711" "$W/lockdir"
head -c 64 /dev/urandom > "$W/out/$V/ekh-bcm2711/batman-$V-ekh-bcm2711-ab-payload.tar.gz"
(cd "$W/out/$V/ekh-bcm2711" && sha256sum "batman-$V-ekh-bcm2711-ab-payload.tar.gz" > SHA256SUMS)
PSHA=$(cut -c1-64 "$W/out/$V/ekh-bcm2711/SHA256SUMS")
echo x > "$W/tools/provclient-arm64"; echo y > "$W/tools/provclient-amd64"; (cd "$W/tools" && sha256sum provclient-arm64 provclient-amd64 > SHA256SUMS)
cat > "$W/bin/ssh" <<'STUB'
#!/bin/bash
# the scripted node: $N/{slot,trial,boot,up,lease,dm,dmcount,hold,protb} + $N/bt/<run>/ + $N/journal ("<run> <id> todo|done <bind> <action…>")
N=$UDR_N; c=""
while [ $# -gt 0 ]; do case "$1" in -o|-p|-i) shift 2 ;; root@*) shift; c="$*"; break ;; *) shift ;; esac; done
in=""; case "$c" in ""|"sh -s"*) in=$(cat) ;; esac
L(){ echo "$*" >> "$N/calls"; }
rd(){ cat "$N/$1" 2>/dev/null; }
up=$(( $(rd up) + 1 )); echo $up > "$N/up"
reboot_node(){ echo "$(head -c 4 /dev/urandom | od -An -tx1 | tr -d ' \n')" > "$N/boot"; rm -rf "$N/bt"; mkdir -p "$N/bt"; rm -f "$N/lease" "$N/dm"; echo 100 > "$N/up"; }
leasevalid(){ set -- "$1" $(rd lease); [ "${2:-}" = "$1" ] && [ "${3:-}" = "$(rd boot)" ] && [ "${4:-0}" -gt "$(rd up)" ]; }
case "$in" in *STAGED-DIR*)
	r=$(grep -o 'd=\$BT/[A-Za-z0-9_-]*' <<< "$in" | head -1); r=${r#d=\$BT/}
	if [ -e "$N/bt/$r" ]; then echo "FAIL /tmp/run/batman-dv/bt/$r exists"; L "STAGE-REFUSED $r"; exit 1; fi
	mkdir -p "$N/bt/$r"; echo STAGED-DIR; exit 0 ;;
esac
if [[ $c =~ ^RUN_ID=([A-Za-z0-9_-]+)\ sh\ [^\ ]*/prov-lease-254\.sh\ ([a-z-]+)(\ (.*))?$ ]]; then
	run=${BASH_REMATCH[1]}; sub=${BASH_REMATCH[2]}; arg=${BASH_REMATCH[4]}; slot=$(rd slot)
	case "$sub" in
	stage-check) for f in ble-lib-254.sh prov-wbox-254.sh prov-undo-lib-254.sh prov-ethsim-254.sh ud9-watch-254.sh prov-lease-254.sh; do echo "$(sha256sum < "$UDR_REPO/scripts/node/$f" | cut -c1-64)  $f"; done ;;
	acquire) set -- $(rd lease)
		if [ -n "${1:-}" ] && [ "$1" != "$run" ] && [ "${2:-}" = "$(rd boot)" ]; then
			if [ "${3:-0}" -gt "$(rd up)" ]; then L "ACQUIRE-REFUSED $run"; echo "FAIL another BLE test (run $1) holds the lease until uptime $3"; exit 1; fi
			[ -e "$N/dm" ] && { L "ACQUIRE-REFUSED $run"; echo "FAIL the lease of run $1 expired but its deadman is still pending"; exit 1; }
			L "ACQUIRE-REFUSED $run"; echo "FAIL run $1 did not clean up (lease expired, no deadman left): run ble-recover first"; exit 1
		fi
		for d in "$N"/bt/*/; do [ -d "$d" ] || continue; b=$(basename "$d"); [ "$b" = "$run" ] || { echo "GC run dir $b: x"; rm -rf "$d"; }; done
		echo "$run $(rd boot) $(( $(rd up) + ${arg:-60} ))" > "$N/lease"; L "ACQUIRE $run slot=$slot"; echo "LEASE $run until uptime 9999" ;;
	renew) if leasevalid "$run"; then echo "$run $(rd boot) $(( $(rd up) + ${arg:-60} ))" > "$N/lease"; echo "ARMED $arg s"; else echo "FAIL lease is not ours or expired"; exit 1; fi ;;
	release) if leasevalid "$run"; then rm -f "$N/lease"; rm -rf "$N/bt/$run"; L "RELEASE $run"; echo RELEASED; else L "RELEASE-REFUSED $run"; echo "FAIL lease is not ours or expired"; exit 1; fi ;;
	undo-pending) awk '$3=="todo" {print "UNDO-PENDING " $1 " " $2 " todo " $4 " " $5}' "$N/journal" 2>/dev/null ;;
	undo-replay) leasevalid "$run" || { echo "FAIL lease is not ours or expired"; exit 1; }
		left=0; done_=0
		while read -r jr id st b a; do
			[ "$jr" = "$run" ] || [ "$st" != todo ] && { echo "$jr $id $st $b $a"; continue; }
			case "$b" in slot:*) [ "$b" = "slot:$slot" ] || { left=$((left + 1)); echo "$jr $id $st $b $a"; continue; } ;; esac
			done_=$((done_ + 1)); echo "$jr $id done $b $a"
		done < "$N/journal" > "$N/journal.new"; mv "$N/journal.new" "$N/journal"
		L "UNDO-REPLAY by $run slot=$slot done=$done_ left=$left"; echo "REPLAY"; [ $left = 0 ] ;;
	undo) leasevalid "$run" || { echo "FAIL lease is not ours or expired"; exit 1; }; L "UNDO-HOST $run"; echo "UNDO undo_run host end rc=0" ;;
	restoring) echo "RESTORING $arg" ;;
	radio-restore) echo "RADIO clean" ;;
	provd-reset) echo "PROVD ok" ;;
	*) echo "STATE" ;;
	esac; exit 0
fi
case "$c" in
	*'prov-wbox-254.sh unbind-all'*) echo "UNBIND-ALL ok"; exit 0 ;;
	*'sh -s -- '*) set -- ${c#*sh -s -- }; L "NB $1"
		case "$1" in p5-restore) echo "P5-RESTORED $2 x" ;; overlay-restore) echo "OVERLAY-RESTORED $2" ;; manifest) echo "MANIFEST $2" ;;
			compare) printf 'DIFF identity - protB=old\nDIFF identity + protB=new\nCOMPARE %s after diffs=2\n' "$2" ;; finish) echo "FINISHED $2" ;; esac; exit 0 ;;
	*'echo "mac='*) echo "mac=$UDR_MAC slot=$(rd slot) ver=$UDR_V trial_rc=$(rd trial) dt_try=$(rd dt) hold=[$(rd hold)] held=$(rd held) badslot=[] protA=[$UDR_V] protB=[$(rd protb)] up=$(rd up) boot=$(rd boot)"; exit 0 ;;
	*'batman-slot rollback'*|*'batman-slot reboot committed'*)
		eb=$(grep -o "\[ \"\$b\" = '[0-9a-f]*' \]" <<< "$c" | grep -o "'[0-9a-f]*'" | tr -d "'"); ea=$(grep -o "\[ \"\$a\" = '[AB]' \]" <<< "$c" | grep -o "'[AB]'" | tr -d "'")
		if [ "$eb" != "$(rd boot)" ] || [ "$ea" != "$(rd slot)" ]; then echo "WRONG-STATE boot=$(rd boot) active=$(rd slot) trial=$(rd trial) extra=-"; exit 0; fi
		case "$c" in *'batman-slot rollback'*) L "ROLLBACK from $(rd slot)"; echo A > "$N/slot"; echo 1 > "$N/trial" ;;
			*) L "REBOOT"; [ "$(rd trial)" = 0 ] && { echo A > "$N/slot"; echo 1 > "$N/trial"; } ;; esac
		echo 00000000 > "$N/dt"; echo 0 > "$N/held"; reboot_node; echo SENT; exit 0 ;;
	*'sysupgrade -n'*) L "OTA"; echo B > "$N/slot"; echo 0 > "$N/trial"; echo 00000001 > "$N/dt"; echo 1 > "$N/held"; : > "$N/hold"; echo "$UDR_V" > "$N/protb"; reboot_node; exit 0 ;;
	*'> /opt/batdata/state/autocommit-hold-commit; sync'*) printf '%s' "$UDR_V" > "$N/hold"; exit 0 ;;
	*'cat /opt/batdata/state/autocommit-hold-commit'*) cat "$N/hold"; echo; exit 0 ;;
	*'df -k /opt/batdata'*) echo 999999; exit 0 ;;
	*'sha256sum < /opt/batdata/dv-prov-ota.tar.gz'*) echo "$UDR_PSHA"; exit 0 ;;
	*'disc='*) echo "disc=0 dlog=0"; exit 0 ;;
	*'echo MT='*) echo "MT=100"; exit 0 ;;
	*'date -r /boot/autoboot.txt'*) echo 100; exit 0 ;;
	*'is healthy and HELD'*) [ "$(rd trial)" = 0 ]; exit $? ;;
	*'prov.meta'*) echo member; exit 0 ;;
	*"prov deadman"*) cat "$N/dmcount" 2>/dev/null || echo 0; exit 0 ;;
	*'echo PCOK'*) echo PCOK; exit 0 ;;
	*'node update-status'*) L "STATUS"; echo "RESULT update.status code=0 phase=0 percent=0"; exit 0 ;;
	*'NO-WATCHER'*) echo NO-WATCHER; exit 0 ;;
	*UD9W*) echo "UD9W 0"; exit 0 ;;
	*'protected'*' --full-time'*) echo "-rw------- 1 0 0 30 2026-11-23 x"; exit 0 ;;
esac
exit 0
STUB
cat > "$W/bin/wsl.exe" <<'STUB'
#!/bin/bash
case "$*" in *wsl-rootfs.sh\ stamp*) echo "BATMAN_VERSION=$UDR_V" ;; *owner.pub*) printf '04%0128d\n' 0 ;; *sign*) cat >/dev/null ;; esac
exit 0
STUB
printf '#!/bin/sh\necho "SCP $*" >> "$UDR_N/scp.log"; exit 0\n' > "$W/bin/scp"
printf '#!/bin/sh\nexit 0\n' > "$W/bin/sleep"
chmod 755 "$W/bin"/*
export UDR_N=$W/node UDR_REPO=$H UDR_MAC=88:a2:9e:b5:6c:89 UDR_V=$V UDR_PSHA=$PSHA PATH="$W/bin:$PATH" TEMP=$W/lockdir NODE=$NODEIP PEER=10.9.9.8 \
	MAC=88:a2:9e:b5:6c:89 PR_OUT=$W/out PR_OUT_WSL=/x/out DV_PROV_TOOLS=$W/tools
node(){	# <slot> <trial> [live]: a fresh scripted node; the dead run's journal: p6 slot:A ssid-restore, p6 - p5-save
	rm -rf "$W/node"; mkdir -p "$W/node/bt"; cd "$W/node" || exit 1
	echo "$1" > slot; echo "$2" > trial; echo 00000000 > dt; echo 0 > held; : > hold; echo "$V" > protb; echo 2 > dmcount
	echo 1a2b3c4d > boot; echo 5000 > up; : > calls
	printf '%s\n' "$DEAD 1 todo - p5-save" "$DEAD 2 todo slot:A ssid-restore 6162" > journal
	if [ "${3:-}" = live ]; then echo "$DEAD 1a2b3c4d 99999" > lease; mkdir -p "bt/$DEAD"; : > dm; fi
	cd "$H" || exit 1; }
step(){ local f out=""; for f in "$W"/step-"$1".*.sh; do [ -f "$f" ] || continue; out="$out$(cat "$W/pre.sh" "$f" | bash 2>&1)"$'\n'; done; printf '%s' "$out"; }
has_step(){ ls "$W"/step-"$1".*.sh >/dev/null 2>&1; }
calls(){ tr '\n' '|' < "$W/node/calls"; }
# ---- 1, 3, 5: node on A, the dead run's lease gone (its deadman fired) but its run dir left
node A 1; mkdir -p "$W/node/bt/$DEAD"
o1=$(step 1); o2=$(step 2); c=$(calls)
re1="^ACQUIRE pupdate254[0-9]+ slot=A\|UNDO-REPLAY by pupdate254[0-9]+ slot=A done=2 left=0\|RELEASE pupdate254[0-9]+\|ACQUIRE $DEAD slot=A\|NB p5-restore\|.*NB overlay-restore\|.*OTA\|.*NB finish\|.*UNDO-HOST $DEAD\|RELEASE $DEAD\|"
rb1=$(grep -n '^ROLLBACK' "$W/node/calls" | head -1 | cut -d: -f1); p51=$(grep -n '^NB p5-restore' "$W/node/calls" | head -1 | cut -d: -f1)
if grep -qE "$re1" <<< "$c" && [ -n "$p51" ] && { [ -z "$rb1" ] || [ "$rb1" -gt "$p51" ]; }; then ok "assert 1: on A — replay acquire, replay, release, restore acquire, pr_restore, pr_brewrite, pr_finish_snap, pr_release"
else bad "assert 1: calls [$c] step1 [$(tail -2 <<< "$o1" | tr '\n' '|')] step2 [$(grep -E 'FAIL|NEEDS' <<< "$o2" | head -3 | tr '\n' '|')]"; fi
grep -q 'PASS prov-update-254: S0 restored' <<< "$o2" && ! grep -q 'S0 not restored' <<< "$o2" && ok "assert 3: PR_WROTE_B = 1 at pr_restore (the protB-only DIFF is accepted)" || bad "assert 3: $(grep -E 'S0 (not )?restored' <<< "$o2" | head -1)"
grep -q 'the prov deadman acted' <<< "$o2" && bad "assert 5: a deadman FAIL with 2 dead-run lines logged ($(grep 'deadman acted' <<< "$o2"))" || { grep -q 'lease released' <<< "$o2" && ok "assert 5: 2 dead-run deadman lines -> no deadman FAIL" || bad "assert 5: step 2 did not reach pr_release"; }
# ---- 2: B committed + a pending slot:A line: the rollback first, the replay only on A
node B 1
if has_step 0c; then o=$(step 0c); c=$(calls)
	fr=$(grep -n '^UNDO-REPLAY' "$W/node/calls" | head -1 | cut -d: -f1); rb=$(grep -n '^ROLLBACK from B' "$W/node/calls" | head -1 | cut -d: -f1)
	if [ -n "$rb" ] && ! grep -q 'UNDO-REPLAY .* slot=B' "$W/node/calls" && { [ -z "$fr" ] || [ "$fr" -gt "$rb" ]; } && grep -q 'UNDO-REPLAY .* slot=A done=2 left=0' "$W/node/calls"; then
		ok "assert 2: B committed — rollback first, no replay on B, the replay after the reboot on A"
	else bad "assert 2: calls [$c] out [$(grep -E 'FAIL|back_to_a' <<< "$o" | head -3 | tr '\n' '|')]"; fi
else bad "assert 2: the block has no step 0c (B committed would be replayed on B)"; fi
# ---- 4: a failed step-1 replay still releases the lease
node A 1; printf '%s\n' "$DEAD 1 todo slot:B ssid-restore 6162" > "$W/node/journal"
o=$(step 1); c=$(calls)
grep -qE 'UNDO-REPLAY by (pupdate254[0-9]+) slot=A done=0 left=1\|RELEASE pupdate254' <<< "$c" && ok "assert 4: a failed replay (a slot:B line on A) still calls pl release" || bad "assert 4: calls [$c]"
# ---- 6: the dead run's lease is live in this boot: every step ends at its acquire
node A 1 live; for s in 0c 1 2 3; do has_step $s && step $s > /dev/null; done; c=$(calls)
if ! grep -qE 'ROLLBACK|UNDO-REPLAY|NB p5-restore|UNDO-HOST|STATUS|^ACQUIRE ' "$W/node/calls"; then ok "assert 6: a live lease of $DEAD — steps 0c-3 each stop at their acquire (no rollback, replay, restore, host undo, status)"
else bad "assert 6: calls [$c]"; fi
# ---- 7: P9's run-id / version validation (the fixtures of p9-judge.sh)
o=$(bash "$H/tests/prov-p1/p9-judge.sh" "$H/scripts/node/prov-p9-254.sh" 2>&1)
n7=$(grep -cE '^ok   (dirty flag \[|dirty flag of a prov-update|  \.\.\. and the UD-RECOVER block|a slot-A version with)' <<< "$o")
[ "$n7" = 8 ] && ok "assert 7: P9 prints the block only for pupdate254 + 10 digits with a valid version (8 fixtures)" || bad "assert 7: $n7 of 8 P9 fixtures ($(grep -E '^FAIL' <<< "$o" | head -2 | tr '\n' '|'))"
# ---- 8: no pidof, no rm -rf of a run dir under bt/
grep -vE '^[[:space:]]*#' "$W/block" | grep -qE 'pidof|rm -rf [^ ]*/bt/' && bad "assert 8: the block has pidof / rm -rf …/bt/: $(grep -vE '^[[:space:]]*#' "$W/block" | grep -E 'pidof|rm -rf [^ ]*/bt/' | head -1 | cut -c1-120)" || ok "assert 8: no pidof, no rm -rf …/bt/ in the block's commands"
# ---- 9: the watcher kill (0b2): exact text, then run under busybox sh against real processes
if ls "$W"/step-0b2.*.ssh >/dev/null 2>&1; then
	cmd=$(cat "$W"/step-0b2.*.ssh)
	if grep -qF 'kill -TERM "-$p"' <<< "$cmd" && ! grep -qF -- 'kill -TERM --' <<< "$cmd" && grep -qF 'for s in /proc/[0-9]*/stat' <<< "$cmd" && grep -qF '[ $n -lt 10 ]' <<< "$cmd" \
		&& grep -qF '[ "$5" = "$p" ]' <<< "$cmd" && grep -qF 'grep -q ud9-watch-254.sh' <<< "$cmd"; then ok "assert 9a: kill -TERM \"-\$p\" (no --), a 10 s wait for every group member, pgid and cmdline checks"
	else bad "assert 9a: the 0b2 command text [$(tr '\n' ' ' <<< "$cmd" | cut -c1-200)]"; fi
	body=$(sed -e "1s/^ssh root@$NODEIP '//" -e "\$s/'\$//" <<< "$cmd" | sed "s#/tmp/run/batman-dv/#$W/rd/#g")
	BB=$(command -v busybox)
	if [ -n "$BB" ]; then
		mkdir -p "$W/rd/$DEAD" "$W/x"; printf '#!/bin/sh\n/bin/sleep 300 &\nwait\n' > "$W/x/ud9-watch-254.sh"; chmod 755 "$W/x/ud9-watch-254.sh"
		setsid /bin/sh "$W/x/ud9-watch-254.sh" </dev/null >/dev/null 2>&1 & sleep_=$!; /bin/sleep 0.5
		wp=$(pgrep -f "$W/x/ud9-watch-254.sh" | head -1); echo "$wp" > "$W/rd/$DEAD/ud9.pid"
		o=$(PATH=/usr/bin:/bin "$BB" sh -c "$body" 2>&1); left=$(ps -eo pgid= | grep -cw "$wp")
		[ "$o" = KILLED ] && [ "$left" = 0 ] && ok "assert 9b: busybox sh: the watcher's whole group killed -> KILLED" || bad "assert 9b: [$o] $left member(s) of group $wp left"
		pkill -f "$W/x/ud9-watch-254.sh" 2>/dev/null
		sleep_x=$(/bin/sh -c '/bin/sleep 300 >/dev/null 2>&1 & echo $!'); echo "$sleep_x" > "$W/rd/$DEAD/ud9.pid"
		o=$(PATH=/usr/bin:/bin "$BB" sh -c "$body" 2>&1); kill "$sleep_x" 2>/dev/null
		[ "$o" = NOT-THE-WATCHER ] && ok "assert 9c: a pid that is not the watcher's group leader -> NOT-THE-WATCHER, nothing killed" || bad "assert 9c: [$o]"
	else bad "assert 9b/9c: no busybox"; fi
else bad "assert 9: the block has no step 0b2 (the watcher kill is not a command)"; fi
echo "test-ud-recover: $P passed, $F failed"; [ $F = 0 ] && [ $P -gt 0 ]
