#!/bin/bash
# scripts/dv/prov-gatt-254.sh — #254 H3 tier-B unit prov-gatt-254 (docs/design/254-h23-harness.md §6.3; the
# prov-gatt-254 harness design v3.1): BLE GATT regression of 04's RELEASE batman-provd, with the Windows host as the
# central (tests/tools/peer/peer.py gatt + blebridge.py) and 02 as the unpaired second central (prov-p2-central-254.sh).
# Every case is ONE connection, ONE btmon capture on 04 (decoded there as uid 65534) and ONE verdict by
# tests/tools/peer/gattjudge.py (this script prints it): the capture is bound to the central's own address and to the
# connection handle, absence verdicts need the capture to cover the link (New Index ... Disconnect Complete).
#   M1     MTU: every non-final outbound frame = min(244, MTU at subscription - 3) (not discriminating at 244 — the low
#          branch is TestFrameLimitFollowsAcquireNotifyMTU)
#   S1a    msg1 and a request in 1-byte-data frames;  S3B a 3 B (header-only) end frame;  S512 512 / 513 B frames
#          (only when the central's write size reaches 513, else NA);  S8192 8192 / 8193 B messages
#   Q1-Q6  one framing rule broken per case on a REAL `info` ciphertext (a lax provd would answer -> FAIL), Q7 1 B / 2 B
#          frames; twins T1 / T2 / T4 = the same bytes with the headers right (must be answered)
#   B1     100 pipelined requests in order; B1x 1000 (RX queue / bluetoothd write blocking), bluetoothd liveness
#   E1     no SMP / LTK request / Encryption Change on any Windows case's link;  E2 02 (not paired) subscribes TX,
#          writes msg1 to RX and gets msg2; its read-only link carries no subscription (control)
#   W1     NOT run here: cited from prov-provd-wbox-254 (design §5.5)
# 04 is made legacy inside the snapshot (pr_begin) and restored to its base state at the end and on EVERY abnormal stop.
# Needs: the WSL peer venv (PEER_PY), the host python (PY_HOST), the harness btmon (DV_BT_TOOLS) and dbus-send
# (DV_DBUS_TOOLS). The central's LE address: GATT_CENTRAL (from probe U7), else learnt from M1's capture (one
# connection only) and required equal in every later case. 02's address: GATT_02_ADDR, else E2's read capture.
# GATT_CASES="<case> ..." runs only those (m1 is added first when missing). Evidence per case (peer lines, verdict lines,
# the capture excerpt of that case's link) goes to $DV_DIR/prov-gatt-254-<run>/ (else the host temp dir).
# Runs from Git Bash on the Windows host. Prints "UNIT prov-gatt-254 PASS|FAIL|INVALID".
set -u
PR_UNIT=prov-gatt-254
# shellcheck source=scripts/dv/prov-254.sh
. "$(dirname "$0")/prov-254.sh"
PJ="$REPO/tests/tools/peer/gattjudge.py"
PEERW="$REPO_WSL/tests/tools/peer/peer.py"
PEER_PY=${PEER_PY:-'$HOME/.batman-dv/peer-venv/bin/python'}   # expanded in WSL
HPY=${PY_HOST:-python}
P2C="$REPO/scripts/node/prov-p2-central-254.sh"
BTT=${DV_BT_TOOLS:-$HOME/batman-dv-tools/bluez-5.72}; DBT=${DV_DBUS_TOOLS:-$HOME/batman-dv-tools/dbus}
CENTRAL=${GATT_CENTRAL:--}; C02=${GATT_02_ADDR:--}
GL="${TEMP:?}/batman-dv-winble.lock"
GW=$(mktemp -d)
ADDR=-; DEVID=""; MSG2LEN=0; REAL_PID=""; PIDPREV=""; GL_HELD=0
CASES_A="m1 s1a s3b q7a q7b s512a s512b s8192 s8193 t1 t2 t4 q1 q2 q3 q4 q5 q6"
ALLCASES="$CASES_A b1 b1x e2"
# GATT_CASES=<list>: only these (any of $ALLCASES). m1 always runs first when anything else is asked for: it pins the
# node's address, learns the central's and measures msg2's length (E2 compares with it)
SEL=" ${GATT_CASES:-$ALLCASES} "
for c in $SEL; do case " $ALLCASES " in *" $c "*) ;; *) echo "FAIL prov-gatt-254: unknown case [$c] in GATT_CASES (known: $ALLCASES)"; echo "UNIT $PR_UNIT INVALID"; exit 2 ;; esac; done
case "$SEL" in *" m1 "*) ;; *) SEL=" m1$SEL" ;; esac
sel(){ case "$SEL" in *" $1 "*) return 0 ;; esac; return 1; }
# evidence kept per case (review of run 1: the captures went with $PCD): peer.py's lines, the judge's lines and the
# capture excerpt of the case's own link (connection, ATT opcodes with lengths and handles, disconnect + reason, SMP /
# encryption — no ATT data bytes, no keys), in DV_DIR (the suite's run dir), else the host's temp dir
EVD="${DV_DIR:-${TEMP:?}}/prov-gatt-254-$RUN"
keep(){	# <label> <btmon file> [central]: the excerpt + whatever $GW/<label>.* exists
	local f
	mkdir -p "$EVD" || return 0
	[ -s "$2" ] && "$HPY" "$PJ" excerpt --central "${3:--}" --btmon "$2" > "$EVD/$1.btmon.txt" 2>&1
	for f in "$GW/$1".gatt "$GW/$1".v "$GW/$1".live "$GW/$1".rw "$GW/$1".read; do [ -f "$f" ] && cp "$f" "$EVD/"; done
	return 0
}
c02(){ timeout 300 ssh $SSHO root@$PEER sh -s -- "$@" < "$P2C" 2>&1 | tr -d '\r'; }
provd_pid_q(){ qr 'for x in $(pidof batman-provd); do [ "$(readlink /proc/$x/exe)" = /usr/bin/batman-provd ] && echo $x; done'; }
judge_lines(){	# judge output -> ok / no / inv / say; sets JV to the verdict
	local l; JV=INVALID
	while IFS= read -r l; do case "$l" in
		"PASS "*) ok "${l#PASS }" ;; "FAIL "*) no "${l#FAIL }" ;; "INVALID "*) inv "${l#INVALID }" ;;
		"NA "*|"RETRY "*|"INFO "*) say "${l#* }" ;; "VERDICT "*) JV=${l##* } ;; *) say "judge: $l" ;; esac
	done
}

# ---- host side: the Windows BLE adapter lock, orphans, PnP (design §3, §7) --------------------------------------------
host_boot(){ echo $(( $(date +%s) - $(cut -d. -f1 /proc/uptime) )); }
# The orphan patterns are bracketed: run 1 (2026-11-26) counted "peer.py 1" with no peer running — the old
# `bash -c "pgrep -f 'peer.py gatt' | …"` matched its own shell's forked pipeline children, whose command line holds the
# pattern until they exec. '[p]eer\.py gatt' matches "peer.py gatt" but not its own text.
ORPH_RE='[p]eer\.py gatt'
orph_wsl_pids(){ wsl_ pgrep -af "$ORPH_RE" 2>/dev/null | tr -d '\r'; }
orph_win_pids(){ powershell.exe -NoProfile -Command "Get-CimInstance Win32_Process -Filter \"Name='python.exe'\" | Where-Object { \$_.CommandLine -match '[b]lebridge\.py' } | ForEach-Object { '{0} {1}' -f \$_.ProcessId, \$_.CommandLine }" 2>/dev/null | tr -d '\r'; }
orph_wsl(){ orph_wsl_pids | grep -c .; }
orph_win(){ orph_win_pids | grep -c .; }
# orph_wait [s]: a peer that is still ending (its bridge's CLOSE, the WSL interop exit) is not an orphan yet: poll up to
# <s> (20) seconds; rc 1 = still there after that, with the processes it saw logged
orph_wait(){
	local t0 w x; t0=$(mono)
	while :; do
		w=$(orph_wsl_pids); x=$(orph_win_pids)
		[ -z "$w" ] && [ -z "$x" ] && return 0
		[ $(( $(mono) - t0 )) -ge "${1:-20}" ] && break
		sleep 2
	done
	say "after ${1:-20} s still running — WSL: [$(tr '\n' '|' <<< "$w")] Windows: [$(tr '\n' '|' <<< "$x" | cut -c1-200)]"
	return 1
}
pnp_list(){ powershell.exe -NoProfile -Command "(Get-PnpDevice -Class Bluetooth -ErrorAction SilentlyContinue | Where-Object { \$_.InstanceId -like 'BTHLE*' } | ForEach-Object { \$_.InstanceId }) -join ','" 2>/dev/null | tr -d '\r'; }
# gl_take: one bridge per host. A lock whose owner is gone (pid dead, or another host boot) and with no bridge running is
# printed and taken over; otherwise refused (review A2-m7 / B2-m6)
gl_take(){
	local o pid boot
	if mkdir "$GL" 2>/dev/null; then :
	else
		o=$(cat "$GL/owner" 2>/dev/null); pid=$(sed -n 's/.*pid=\([0-9]*\).*/\1/p' <<< "$o"); boot=$(sed -n 's/.*boot=\([0-9]*\).*/\1/p' <<< "$o")
		if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null && [ -n "$boot" ] && [ $(( $(host_boot) - boot )) -lt 60 ] && [ $(( boot - $(host_boot) )) -lt 60 ]; then
			no "Windows BLE lock $GL is held by a live run [$o]"; return 1; fi
		[ "$(orph_win)" = 0 ] || { no "Windows BLE lock $GL is stale [$o] but a blebridge.py still runs — not taking it over"; return 1; }
		say "taking over a stale Windows BLE lock: [$o]"; rm -f "$GL/owner"
	fi
	echo "pid=$$ boot=$(host_boot) start=$(date +%s) run=$RUN" > "$GL/owner"; GL_HELD=1
}
gl_release(){	# only after the orphan check passed (review A3-m6)
	[ "$GL_HELD" = 1 ] || return 0
	if orph_wait 20; then rm -f "$GL/owner"; rmdir "$GL" 2>/dev/null; GL_HELD=0
	else no "orphan peer / bridge still running: the Windows BLE lock $GL is KEPT"; fi
}
# orph_clean: INT, then TERM, then the bridge's own watchdog (it cuts the link and exits once HBs stop): 15 s
orph_clean(){
	orph_wait 20 && return 0
	wsl_ pkill -INT -f "$ORPH_RE" >/dev/null 2>&1; sleep 3
	wsl_ pkill -TERM -f "$ORPH_RE" >/dev/null 2>&1
	orph_wait 16 && return 0
	# no pr_needs_person here: that would skip 04's restore (pr_on_exit), and 04 must not stay legacy (review A2-M3).
	# The host side waits for a person through the KEPT lock (gl_release refuses while an orphan runs).
	no "orphan after INT / TERM / the bridge watchdog: peer.py $(orph_wsl), blebridge.py $(orph_win) — stop it on the Windows host by hand; 04 is restored regardless"
	return 1
}

# ---- 04 side: btmon per case (decoded as nobody), connected count, liveness ------------------------------------------
DS="$PCD/dbus-send --system --print-reply --reply-timeout=5000"
connected04(){	# a number, or "unk" when the bus call failed (the post-check reads that as INVALID, never as 0)
	local o; o=$(qr "o=\$($DS --dest=org.bluez / org.freedesktop.DBus.ObjectManager.GetManagedObjects 2>/dev/null) || { echo unk; exit 0; }; printf '%s\n' \"\$o\" | grep -A1 '\"Connected\"' | grep -c 'boolean true'; true")
	case "$o" in ''|*[!0-9]*) echo unk ;; *) echo "$o" ;; esac
}
wait_idle(){	# <s>: 04 has no connected device (a held link of the previous case would bleed into the next capture)
	local t0; t0=$(mono)
	while [ $(( $(mono) - t0 )) -lt "$1" ]; do [ "$(connected04)" = 0 ] && return 0; sleep 2; done
	return 1
}
bt_start(){	# <label>: btmon -w on 04; ready once the decoded snoop shows the index records (review A3-m4)
	local i
	q "umask 077; rm -f $PCD/g-$1.snoop; setsid $PCD/btmon -w $PCD/g-$1.snoop </dev/null >/dev/null 2>&1 & echo \$! > $PCD/g-$1.pid"
	for i in 1 2 3 4 5 6 7 8 9 10; do
		qr "$PCD/btmon -r $PCD/g-$1.snoop 2>/dev/null | grep -qE '^= (New Index|Index Info)' && echo y" | grep -qx y && return 0; sleep 1
	done
	inv "btmon on 04 not ready for $1 (no index records in 10 s)"; return 1
}
bt_stop(){	# <label> <out file>: SIGINT, then decode as uid 65534 from a nobody-owned 0700 copy (design §4.3, U13b)
	q "kill -INT \$(cat $PCD/g-$1.pid 2>/dev/null) 2>/dev/null; sleep 1; rm -f $PCD/g-$1.pid
		d=$PCD/dec.$1; rm -rf \$d; mkdir -m 0700 \$d && cp $PCD/g-$1.snoop \$d/s && chown -R 65534:65534 \$d && chmod 0400 \$d/s
		start-stop-daemon -S -c nobody -x $PCD/btmon -- -r \$d/s 2>&1; rm -rf \$d $PCD/g-$1.snoop" > "$2"
}
live_start(){	# <seconds>: bluetoothd answers Properties.Get within 2 s, once a second, bounded by its own deadline
	q "cat > $PCD/live.sh" < <(cat "$REPO/scripts/node/ble-lib-254.sh"; cat <<EOF
end=\$(( \$(cut -d. -f1 /proc/uptime) + $1 ))
while [ \$(cut -d. -f1 /proc/uptime) -lt \$end ]; do
	ms=\$(awk '{ printf "%d", \$1 * 1000 }' /proc/uptime)
	if lim 2 $DS --dest=org.bluez /org/bluez/hci0 org.freedesktop.DBus.Properties.Get string:org.bluez.Adapter1 string:Powered >/dev/null 2>&1; then s=ok; else s=timeout; fi
	p=\$(pidof bluetoothd | awk '{print \$1}'); r=\$(awk '/^VmRSS/ {print \$2}' /proc/\$p/status 2>/dev/null)
	echo "\$ms \$s \${p:-none} \${r:-0}" >> $PCD/live.log
	sleep 1
done
EOF
)
	q "rm -f $PCD/live.log; setsid sh $PCD/live.sh </dev/null >/dev/null 2>&1 & echo \$! > $PCD/live.pid"
}
live_stop(){ q "kill \$(cat $PCD/live.pid 2>/dev/null) 2>/dev/null; rm -f $PCD/live.pid"; qr "cat $PCD/live.log 2>/dev/null" > "$1"; }

# ---- one case -------------------------------------------------------------------------------------------------------
# run_case <case> [retry]: one connection, one capture, one verdict (JV). A first "no msg2" is RETRY: quiet 61 s under a
# continuous btmon (the handshake quota refills, a foreign central would show), then the same case once more (§6.4)
run_case(){
	local c=$1 retry=${2:-} n=0 dl=120 lab p0 p1 g b extra="" q61=0
	case "$c" in b1) n=100; dl=300 ;; b1x) n=1000; dl=600 ;; esac
	lab=$c${retry:+-r}
	[ -n "$retry" ] && q61=61
	pr_lease_renew +$(( dl + 300 + q61 )) || return 2
	wait_idle 40 || { inv "$c: 04 still has a connected device after 40 s — not started"; JV=INVALID; return 0; }
	p0=$(provd_pid_q); [ -n "$PIDPREV" ] || PIDPREV=$p0
	bt_start "$lab" || { JV=INVALID; return 0; }
	[ -n "$retry" ] && { say "$c: quiet 61 s under btmon before the retry"; sleep 61; }
	case "$c" in b1|b1x) live_start $(( dl + 60 )) ;; esac
	g="$GW/$lab.gatt"; b="$GW/$lab.btmon"
	# the hard limit inside WSL (it ends peer.py; the bridge's watchdog then cuts the link), peer.py's own --deadline first
	wsl_ timeout $(( dl + 60 )) bash -c "$PEER_PY $PEERW gatt $c --device-id $DEVID --addr $ADDR --n $n --deadline $dl" > "$g" 2>&1
	tr -d '\r' < "$g" > "$g.t" && mv "$g.t" "$g"
	say "$c peer: $(grep -E '^(PIDS|GATTR|GATTEND)' "$g" | tr '\n' ' ' | cut -c1-400)"
	orph_clean || { JV=INVALID; return 2; }
	wait_idle 60 || say "$c: a link is still up 60 s after the case (the capture's completeness check decides)"
	sleep 2
	bt_stop "$lab" "$b"
	case "$c" in b1|b1x) live_stop "$GW/$lab.live"; judge_lines < <("$HPY" "$PJ" live --log "$GW/$lab.live") ;; esac
	p1=$(provd_pid_q)
	[ -n "$retry" ] && extra="--retry"
	[ -n "$REAL_PID" ] && [ "$REAL_PID" = "$p1" ] && extra="$extra --real-seen"
	# shellcheck disable=SC2086  # extra: zero, one or two flags
	"$HPY" "$PJ" case --case "$c" --central "$CENTRAL" --target "$ADDR" --pids "$PIDPREV,$p0,$p1" $extra --gatt "$g" --btmon "$b" > "$GW/$lab.v"
	judge_lines < "$GW/$lab.v"
	keep "$lab" "$b" "$CENTRAL"
	PIDPREV=$p1
	# learn from the first bound case: the node's address (pinned from now on), the central's address, msg2's length
	if grep -q 'hs=real' "$g" && [ "$p0" = "$p1" ]; then REAL_PID=$p1; fi
	[ "$ADDR" = - ] && ADDR=$(sed -n 's/^GATTR .* target=\([^ ]*\) .*/\1/p' "$g" | tail -1); ADDR=${ADDR:--}
	if [ "$CENTRAL" = - ]; then
		local cs; cs=$(sed -n 's/^INFO gatt [a-z0-9]*: central \(.*\)$/\1/p' "$GW/$lab.v")
		[ -n "$cs" ] && { CENTRAL=$cs; say "the Windows central's LE address, learnt from $c's capture: $CENTRAL (every later case must match)"; }
	fi
	[ "$c" = m1 ] && MSG2LEN=$(sed -n 's/^GATTR .* msg2len=\([0-9]*\).*/\1/p' "$g" | tail -1)
	return 0
}
case_once(){	# <case>: with the one RETRY of §6.4
	run_case "$1" || return $?
	if [ "$JV" = RETRY ]; then run_case "$1" retry || return $?; fi
	return 0
}

# ---- E2: 02 as the unpaired central --------------------------------------------------------------------------------
e2(){
	local o r a hx
	lg_mark; bt_start e2-read || return 0
	# 02's one-shot bluetoothctl calls (read's scan / info, `: | bluetoothctl info`) segfault now and then — 2 in 10 on
	# 2026-11-01, once in run 1 (2026-11-26, "Segmentation fault" ahead of the read lines); the central retries them
	# (info_of, pick's 5 scans) and only the values it reports count. Cause inside bluetoothctl not found (❓).
	o=$(c02 read "$LAST4"); r=$?; echo "$o" > "$GW/e2.read"; say "E2 02 read: $(tr '\n' ' ' <<< "$o" | cut -c1-300)"
	wait_idle 40; sleep 2; bt_stop e2-read "$GW/e2-read.btmon"; lg_guard "E2 read"
	keep e2-read "$GW/e2-read.btmon"
	a=$(sed -n 's/^ADDR //p' <<< "$o")
	[ $r = 0 ] && [ -n "$a" ] || { inv "E2: 02 could not read 04 (rc $r)"; return 0; }
	[ -n "$(sed -n 's/^CTRL //p' <<< "$o")" ] && [ -n "$(sed -n 's/^STATUS //p' <<< "$o")" ] && ok "E2: 02 read CTRL and STATUS without pairing" || no "E2: 02's unencrypted read of CTRL / STATUS failed [$(grep -E '^(CTRL|STATUS|ERRS|ERRLINES)' <<< "$o" | tr '\n' '|')]"
	grep -q '^PAIRED no' <<< "$o" && ok "E2: 02 not paired after the read" || no "E2: 02 $(grep '^PAIRED' <<< "$o")"
	hx="030000$(head -c 32 /dev/urandom | od -An -v -tx1 | tr -d ' \n')"
	local try=1
	while :; do
		lg_mark; bt_start e2-rw || return 0
		o=$(c02 rw "$a" "$hx"); echo "$o" > "$GW/e2.rw"; say "E2 02 rw (try $try): $(grep -vE '^NVAL' <<< "$o" | tr '\n' ' ' | cut -c1-300)"
		wait_idle 40; sleep 2; bt_stop e2-rw "$GW/e2-rw.btmon"; lg_guard "E2 rw"
		keep e2-rw "$GW/e2-rw.btmon"
		# 02's own confirmation of the subscription and the write; the judge's precondition is 04's capture
		grep -q '^SUB yes' <<< "$o" && grep -q '^WRITE yes' <<< "$o" && break
		[ $try -ge 2 ] && break
		say "E2: 02 did not confirm the subscription / write ($(grep -E '^(SUB|WRITE|ERRLINES)' <<< "$o" | tr '\n' ' ')) — once more"
		try=$((try + 1))
	done
	grep -q '^PAIRED no' <<< "$o" || no "E2 rw: 02 $(grep '^PAIRED' <<< "$o")"
	[ "${MSG2LEN:-0}" -gt 0 ] || { inv "E2: no msg2 length from M1 to compare"; return 0; }
	"$HPY" "$PJ" e2 --central "$C02" --msg2len "$MSG2LEN" --rw "$GW/e2.rw" --rw-btmon "$GW/e2-rw.btmon" --read-btmon "$GW/e2-read.btmon" > "$GW/e2.v"
	judge_lines < "$GW/e2.v"
	cp "$GW/e2.v" "$GW/e2.rw" "$GW/e2.read" "$EVD/" 2>/dev/null || :
}

# ---- post-check (every exit path; design §7) -------------------------------------------------------------------------
post_obs(){	# observations -> the judge's key=value form; pcd is checked after the release separately
	echo "pnp_before=$PNP0"; echo "pnp_after=$(pnp_list)"
	echo "bond04=$(qr 'for d in /var/lib/bluetooth/*/; do ls "$d"; done 2>/dev/null' | tr '\n' ' ')"
	echo "paired02=$(timeout 30 ssh $SSHO root@$PEER ': | bluetoothctl devices Paired 2>/dev/null' | tr -d '\r' | sed 's/\x1b\[[0-9;]*m//g' | grep -c '^Device ')"
	echo "btmon04=$(qr 'for x in $(pidof btmon); do case "$(readlink /proc/$x/exe)" in /tmp/run/batman-dvpc.*) echo $x ;; esac; done' | tr '\n' ' ' | sed 's/ *$//; s/^$/-/')"
	orph_wait 20 >&2 || :          # a peer still ending is not an orphan yet (run 1: "peer.py 1", gone a minute later)
	echo "pcd=0"; echo "orphan_wsl=$(orph_wsl)"; echo "orphan_win=$(orph_win)"; echo "connected04=$(connected04)"
}
post_check(){ post_obs > "$GW/post.obs"; judge_lines < <("$HPY" "$PJ" post --obs "$GW/post.obs"); }
gt_exit(){
	local rc=$?
	[ "${GT_DONE:-0}" = 1 ] || { orph_clean >/dev/null 2>&1 || :; [ "$PR_BEGUN" = 1 ] && [ -n "${PNP0+x}" ] && post_check; }
	(exit $rc); pr_on_exit
	gl_release; rm -rf "$GW"
}

# ---- preconditions that need no lease, BEFORE the snapshot (review n7) ----------------------------------------------
[ -f "$BTT/btmon" ] && (cd "$BTT" && sha256sum -c --quiet --ignore-missing SHA256SUMS) >/dev/null 2>&1 || { inv "no verified btmon in $BTT"; pr_result; exit 1; }
[ -f "$DBT/dbus-send" ] && (cd "$DBT" && sha256sum -c --quiet SHA256SUMS) >/dev/null 2>&1 || { inv "no verified dbus-send in $DBT"; pr_result; exit 1; }
"$HPY" "$PJ" --selftest > "$GW/judge-selftest" 2>&1 || { inv "gattjudge selftest failed: $(tail -1 "$GW/judge-selftest")"; pr_result; exit 1; }
[ "$(orph_wsl)" = 0 ] && [ "$(orph_win)" = 0 ] || { inv "an orphan peer.py / blebridge.py runs on the host"; pr_result; exit 1; }
gl_take || { pr_result; exit 1; }
trap 'gl_release; rm -rf "$GW"' EXIT
PNP0=$(pnp_list); say "Windows BTHLE devices before: [${PNP0:-none}]"
ver=$(qr 'sed -n "s/^BATMAN_VERSION=//p" /etc/batman-build'); say "04 runs $ver"
[ -n "$ver" ] || { inv "04 unreachable"; pr_result; exit 1; }
o=$(qr 'echo "btctl=$(pidof bluetoothctl | wc -w) agent=$(ls /tmp/run/batman-dv/bt/*/agent.pg 2>/dev/null | wc -l) ptest=$([ -e /tmp/run/batman-provd-test ] && echo 1 || echo 0) rom=$(p=""; for x in $(pidof batman-provd); do [ "$(readlink /proc/$x/exe)" = /usr/bin/batman-provd ] && p=$x; done; cmp -s /proc/$p/exe /rom/usr/bin/batman-provd && echo 1 || echo 0) devdirs=$(for d in /var/lib/bluetooth/*/; do ls "$d"; done 2>/dev/null | grep -c ":")"')
say "04 preconditions: $o"
case "$o" in *"btctl=0 agent=0 "*) ;; *) no "precondition: a bluetoothctl / an agent runs on 04 [$o]"; pr_result; exit 1 ;; esac
case "$o" in *"rom=1 "*) ;; *) no "precondition: 04's running provd is not /rom's release binary [$o]"; pr_result; exit 1 ;; esac
case "$o" in *"devdirs=0"*) ;; *) no "precondition: 04 keeps a device directory (a bond?) [$o]"; pr_result; exit 1 ;; esac
case "$o" in *"ptest=1"*) say "INFO /tmp/run/batman-provd-test exists (left by a bound test provd of another run; harmless to a release provd)" ;; esac
o=$(timeout 30 ssh $SSHO root@$PEER ': | bluetoothctl devices Paired 2>/dev/null' | tr -d '\r' | sed 's/\x1b\[[0-9;]*m//g' | grep -c '^Device ')
[ "$o" = 0 ] || { no "precondition: 02 has $o paired device(s)"; pr_result; exit 1; }

pr_begin 3600 || { gl_release; rm -rf "$GW"; pr_result; exit 1; }
trap 'gt_exit' EXIT
pr_pc_place || { pr_abort "provclient dir"; pr_result; exit 1; }
for f in btmon:$BTT dbus-send:$DBT; do
	t=${f%%:*}; d=${f#*:}
	scp -q $SSHO "$d/$t" root@$NODE:$PCD/$t.up && q "mv $PCD/$t.up $PCD/$t && chmod 0755 $PCD/$t" || { pr_abort "$t upload"; pr_result; exit 1; }
	[ "$(qr "sha256sum < $PCD/$t | cut -c1-64")" = "$(awk -v f="$t" '{sub(/^\*/, "", $2)} $2 == f {print $1}' "$d/SHA256SUMS")" ] || { pr_abort "$t sha on 04"; pr_result; exit 1; }
done
for pr in Pairable Discoverable; do
	o=$(qr "$DS --dest=org.bluez /org/bluez/hci0 org.freedesktop.DBus.Properties.Get string:org.bluez.Adapter1 string:$pr 2>&1 | grep -o 'boolean [a-z]*'")
	[ "$o" = "boolean false" ] && ok "04 adapter $pr = false" || { no "04 adapter $pr is [$o] (provd needs it false)"; pr_abort "adapter $pr"; pr_result; exit 1; }
done
DEVID=$(qr 'tr -d "\n" < /etc/batman-prov/identity/sn')
case "$DEVID" in [0-9a-f]*) [ ${#DEVID} = 18 ] || DEVID="" ;; *) DEVID="" ;; esac
[ -n "$DEVID" ] || { inv "04's device id (identity/sn) unreadable"; pr_abort "device id"; pr_result; exit 1; }
LAST4=${DEVID: -4}
st=$(qr "sed -n 's/.*state=\([a-z]*\).*/\1/p' /etc/batman-prov/prov.meta")
[ "$st" = legacy ] || { inv "04 is [$st] after make-legacy: the anonymous handshake needs legacy"; pr_abort "not legacy"; pr_result; exit 1; }

# ---- Windows central: the cases -----------------------------------------------------------------------------------
say "cases: $SEL; evidence in $EVD"
for c in $CASES_A b1 b1x; do
	sel "$c" || continue
	case_once "$c" || { pr_abort "case $c"; pr_result; exit 1; }
	say "$c: verdict $JV"
	[ "$c" = m1 ] && [ "$ADDR" = - ] && { inv "M1 found no node to pin: the rest cannot run"; break; }
done
# ---- 02 central: E2, and the post-check's own negative control (a held link must FAIL its Connected branch)
if sel e2; then
	e2
	o=$(c02 hold "$LAST4"); a=$(sed -n 's/^HELD \([^ ]*\) connected=yes$/\1/p' <<< "$o")
	if [ -n "$a" ]; then
		post_obs > "$GW/post-neg.obs"
		"$HPY" "$PJ" post --obs "$GW/post-neg.obs" | grep -q '^FAIL gatt post: 04: [0-9]* connected' && ok "post-check negative control: a held link FAILs the Connected branch" || no "post-check negative control: a held link did not FAIL the Connected branch"
		c02 drop "$a" >/dev/null
	else inv "post-check negative control: 02 could not hold a link [$(echo $o)]"; fi
	wait_idle 40
fi
say "W1 (GATT_ENCRYPT_CTRL white box) is cited, not run: prov-provd-wbox-254, 2026-11-07, 1.5.14-wsl.22 (design §5.5)"
post_check; cp "$GW/post.obs" "$EVD/" 2>/dev/null; GT_DONE=1
pr_end
[ "$(qr "[ -e $PCD ] && echo left")" = left ] && no "this run's provclient dir $PCD is still on 04" || ok "this run's provclient dir is gone from 04"
gl_release      # before the result line, so its verdict is counted (run 1 printed the KEPT line after UNIT)
say "evidence: $EVD"
pr_result
