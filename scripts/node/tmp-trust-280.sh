#!/bin/sh
# scripts/node/tmp-trust-280.sh — runtime check that a NON-ROOT process cannot steer the node through /tmp (#280).
# Run on a node as root: ssh root@node 'sh -s' < scripts/node/tmp-trust-280.sh. docs/design/280-tmp-trust.md D6, §9, §10.
# Safe by construction (§9 N2): the planted battery reading lives at most (CONFIRM-1)*INTERVAL-5 s and a detached
# root guard removes it AND reverts the staged batpower config at its deadline, so even a fully regressed batpower
# can never see CONFIRM readings in a row (no halt), and an ssh drop cannot leave the bench config behind.
# Every plant is checked for its EFFECT (review 2 #5). A name that already exists (an operator's real hold, say)
# is never planted over and never removed (review 3 #4). The tenant is never started by this test (review 3 #5).
# Exit: 0 pass, 1 FAIL, 3 + SKIP-REASON when it does not apply.
[ -r /usr/lib/batman/rundir.sh ] || { echo "SKIP-REASON: pre-#280 image (no /usr/lib/batman/rundir.sh) — nothing planted"; exit 3; }
# shellcheck source=/dev/null
. /usr/lib/batman/rundir.sh
# never during an A/B trial: the dry-run autocommit below must not race a real one for its watchdog claim
batman-slot is-trial >/dev/null 2>&1 && { echo "SKIP-REASON: this boot is an uncommitted A/B trial — not planting next to a live autocommit"; exit 3; }
rc=0
bad(){ echo "FAIL $*"; rc=1; }
ok(){ echo "ok   $*"; }
info(){ echo "info $*"; }
NB(){ start-stop-daemon -S -c nobody -n tmptrust280 -a /bin/sh -- -c "$1"; }   # busybox has no su
lsm(){ ls -ld "$1" 2>/dev/null | awk '{print $1, $3}'; }
T=$(for d in /opt/batdata/apps/*/; do [ -d "$d" ] && ls "$d"*.manifest >/dev/null 2>&1 && { d=${d%/}; echo "${d##*/}"; break; }; done)
CAND="/tmp/batman-autocommit.hold /tmp/batman-fw-override /tmp/autocommit.committed /tmp/batman-reboot.want /tmp/batman-slot.busy /tmp/autocommit.decided /tmp/autocommit.wd /tmp/sysupgrade.tt280"
[ -n "$T" ] && CAND="$CAND /tmp/batman-payload-$T.stopping /tmp/batman-payload-$T.stop0"
# plant only names that do not exist yet; remove only what we planted
PLANTED=""; KEPT=""
for p in $CAND /tmp/batpower.mock; do if [ -e "$p" ] || [ -L "$p" ]; then KEPT="$KEPT $p"; else PLANTED="$PLANTED $p"; fi; done
mine(){ case " $PLANTED " in *" $1 "*) return 0;; esac; return 1; }
cleanup(){ for p in $PLANTED; do rm -rf "$p"; done; uci -q revert batpower; }
# a previous run killed before its trap must not leave a staged bench config behind
uci -q revert batpower
trap cleanup EXIT
trap 'cleanup; exit 1' HUP INT TERM
trap '' PIPE   # a dropped ssh must not kill us before the clean-up (writes just fail)
[ -n "$KEPT" ] && info "already present, not planted and not touched:$KEPT"

# 1 permissions + sysctls
[ "$(lsm /tmp/run)" = "drwxr-xr-x root" ] && ok "/tmp/run root 0755" || bad "/tmp/run is [$(lsm /tmp/run)]"
batman_rundir 2>/dev/null && [ "$(lsm "$RUNDIR")" = "drwx------ root" ] && ok "$RUNDIR root 0700" || bad "run dir is [$(lsm "$RUNDIR")]"
for k in fs.protected_symlinks fs.protected_hardlinks; do [ "$(sysctl -n $k 2>/dev/null)" = 1 ] && ok "$k=1" || bad "$k=$(sysctl -n $k 2>/dev/null)"; done
# D5: whatever 90-batman.conf sets must be live (a shipped-but-not-applied sysctl protects nothing)
if [ -f /etc/sysctl.d/90-batman.conf ]; then
	for kv in $(grep -E '^fs\.[a-z_.]+=[0-9]+$' /etc/sysctl.d/90-batman.conf); do
		k=${kv%%=*}; v=${kv#*=}
		[ "$(sysctl -n "$k" 2>/dev/null)" = "$v" ] && ok "$k=$v (90-batman.conf)" || bad "$k=$(sysctl -n "$k" 2>/dev/null), 90-batman.conf wants $v"
	done
else bad "/etc/sysctl.d/90-batman.conf missing on a #280 image"; fi

# 2 the boot-time markers are really produced (review 2 BLOCKER 1)
[ -f "$RUNDIR/batdata-mount.booted" ] && ok "batdata-mount once-per-boot marker present" || bad "$RUNDIR/batdata-mount.booted missing — batdata-mount boot() wrote no marker"
if grep -q " /opt/batdata " /proc/mounts; then
	d=$(cat "$RUNDIR/batdata.dev" 2>/dev/null)
	[ -b "$d" ] && ok "batdata.dev = $d" || bad "$RUNDIR/batdata.dev is [$d], not a block device (stage-2 p6 trace would be off)"
fi

# 3 a non-root process cannot create anything in /tmp/run or the run dir
NB "id -u" | grep -qx 65534 || bad "start-stop-daemon did not run as nobody — the non-root steps verified nothing"
NB "mkdir /tmp/run/tt280 2>/dev/null && echo MADE" | grep -q MADE && { bad "nobody created /tmp/run/tt280"; rmdir /tmp/run/tt280; } || ok "nobody cannot create in /tmp/run"
NB ": > $RUNDIR/tt280 2>/dev/null && echo MADE" | grep -q MADE && bad "nobody wrote into $RUNDIR" || ok "nobody cannot write into the run dir"

# 4 old /tmp markers planted by nobody have NO effect; an operator flag planted by nobody is TAMPER
for p in /tmp/batman-autocommit.hold /tmp/batman-fw-override /tmp/autocommit.committed /tmp/batman-reboot.want /tmp/batman-slot.busy; do
	mine "$p" && NB "echo 2 > $p"; done
for p in /tmp/autocommit.decided /tmp/autocommit.wd; do mine "$p" && NB "mkdir $p"; done
if mine /tmp/batman-autocommit.hold; then
	halow-status 2>/dev/null | grep -q 'TAMPER: /tmp/batman-autocommit.hold' && ok "planted hold shown as TAMPER" || bad "planted hold not flagged by halow-status"
else info "an operator hold exists — TAMPER display not tested this run"; fi
if mine /tmp/batman-fw-override; then
	halow-status json 2>/dev/null | grep -q '"fw_override":""' && ok "planted /tmp/batman-fw-override ignored" || bad "fw_override not empty with only a planted /tmp file"
fi
u=$(cut -d. -f1 /proc/uptime)
o=$(AUTOCOMMIT_DRYRUN=1 AUTOCOMMIT_FORCE_TRIAL=1 AUTOCOMMIT_TIMEOUT=$((u + 20)) batman-autocommit run 2>&1)
if mine /tmp/batman-autocommit.hold; then
	echo "$o" | grep -q 'TAMPER: /tmp/batman-autocommit.hold' && ok "autocommit reports the planted hold as TAMPER" || bad "autocommit did not report the planted hold"
fi
# effect: with planted committed/decided/wd/busy a pre-#280 autocommit stops before deciding; ours decides
echo "$o" | grep -q 'DRYRUN decision:' && ok "autocommit still reached a decision with /tmp plants present" \
	|| bad "autocommit reached no decision with /tmp plants present: $(echo "$o" | tail -2 | tr '\n' ' ')"
# effect on the payload tenant (review 3 #5: this test must never be a second owner of tenant start): only when
# the whole stack is ALREADY running and the guardian is not stopping it, `--start-only` is a pure no-op that
# still goes through the stopping-flag decision — rc 0 exactly. A pre-#280 payload-run would return 4 (the
# /tmp plant read as "being stopped"); rc 3 = config changed (reported, not judged); anything else is a FAIL.
up=1; if [ -n "$T" ]; then for c in $(awk '/^CONTAINER /{print $2}' /opt/batdata/apps/"$T"/*.manifest 2>/dev/null); do
	[ "$(docker inspect -f '{{.State.Running}}' "$c" 2>/dev/null)" = true ] || up=0; done; fi
if [ -n "$T" ] && [ "$up" = 1 ] && [ ! -e "$RUNDIR/batman-payload-$T.stopping" ] && mine "/tmp/batman-payload-$T.stopping"; then
	NB "echo 2 > /tmp/batman-payload-$T.stopping; echo '0 0 nodocker' > /tmp/batman-payload-$T.stop0"
	PAYLOAD_LOCK_WAIT=5 payload-run --start-only "$T" >/dev/null 2>&1; prc=$?   # never outlive the harness timeout
	case "$prc" in 0) ok "payload-run --start-only $T (stack already up) ignores a /tmp stopping flag planted by nobody";;
		3) info "payload-run --start-only $T: config changed (rc 3) — stopping-flag effect not judged this run";;
		4) bad "payload-run said 'being stopped' (rc 4) because of a /tmp flag planted by nobody";;
		*) bad "payload-run --start-only $T rc=$prc on an already-running stack";; esac
else info "payload plant skipped (no tenant, stack not fully up, or a real stop in progress)"; fi

# 5 sysupgrade RAM_ROOT (review 3 #1-#3): every `include /lib/upgrade` must resolve RAM_ROOT into the run dir —
#   the same sourcing sysupgrade, validate_firmware_image and stage 2 do — and validation must refuse an input
#   another user owns. A /tmp/root planted by nobody is then simply never used.
rr=$(sh -c '. /lib/functions.sh; include /lib/upgrade; echo "$RAM_ROOT"' 2>/dev/null)
[ "$rr" = "$RUNDIR/ramroot" ] && ok "include /lib/upgrade -> RAM_ROOT=$rr (root-only)" || bad "RAM_ROOT after include /lib/upgrade is [$rr], not $RUNDIR/ramroot"
if mine /tmp/sysupgrade.tt280; then
	# a plant that blocks every OTA must not outlive this test, whatever kills it (review 4 #6): detached remover
	setsid sh -c "trap '' HUP PIPE; sleep 60; rm -f /tmp/sysupgrade.tt280" </dev/null >/dev/null 2>&1 &
	NB "echo x > /tmp/sysupgrade.tt280"
	img=$(mktemp)
	# OTATRACE_FILE: these test validations must not land in the node's persistent OTA forensics (review 4 #11)
	v=$(OTATRACE_FILE=/nonexistent/tt280 /usr/libexec/validate_firmware_image "$img" 2>&1)
	echo "$v" | grep -q 'REFUSING: /tmp/sysupgrade.tt280 is not root' && ok "validate_firmware_image refuses a /tmp/sysupgrade* owned by nobody (guard wired in)" \
		|| bad "validate_firmware_image did not refuse the planted /tmp/sysupgrade.tt280: $(echo "$v" | grep -i -m1 refus)"
	rm -f /tmp/sysupgrade.tt280
	v=$(OTATRACE_FILE=/nonexistent/tt280 /usr/libexec/validate_firmware_image "$img" 2>&1)
	echo "$v" | grep -q 'REFUSING: /tmp/sysupgrade' && bad "guard still refuses after the plant was removed" || ok "guard passes once the plant is gone (control)"
	rm -f "$img"
fi

# 6 N8 sweep: no root-owned file under a directory someone else owns; no batman decision name left at /tmp's top
sw=$(find /tmp -xdev -mindepth 1 -maxdepth 3 -user root 2>/dev/null | while read -r f; do
	p=${f%/*}; [ "$(ls -ld "$p" | awk '{print $3}')" = root ] || echo "$f (parent $p owned by $(ls -ld "$p" | awk '{print $3}'))"; done)
[ -z "$sw" ] && ok "N8: no root-owned entry under a non-root directory in /tmp" || bad "N8: root-owned entries under non-root dirs: $(echo "$sw" | head -3 | tr '\n' ';')"
left=""
for f in /tmp/autocommit* /tmp/batman-fw-override* /tmp/batman-slot.* /tmp/batpower.* /tmp/batdata* /tmp/batman-payload-* /tmp/batman-firstload-*; do
	{ [ -e "$f" ] || [ -L "$f" ]; } || continue
	case "$f" in /tmp/batman-slot.allow-*) continue;; esac       # opf-checked operator flag, stays in /tmp
	case " $CAND /tmp/batpower.mock " in *" $f "*) continue;; esac   # this test's own plant names
	left="$left $f"
done
[ -z "$left" ] && ok "N8: no batman decision state at the top of /tmp" || bad "N8: batman state still in /tmp:$left"

# 7 batpower: never a reading from a world-writable file (N1 oracle on both configs, N2 bounded plant)
CONF=$(uci -q get batpower.main.confirm || echo 3); IVL=$(uci -q get batpower.main.interval || echo 10)
if [ "$CONF" -lt 3 ] || [ "$IVL" -lt 10 ]; then echo "SKIP-REASON: batpower confirm=$CONF interval=$IVL — the bounded plant needs confirm>=3, interval>=10"; exit 3; fi
mine /tmp/batpower.mock || { echo "SKIP-REASON: /tmp/batpower.mock already exists (not ours) — not planting over it"; exit 3; }
LIFE=$(( (CONF - 1) * IVL - 5 ))
NB "echo 1000 > /tmp/batpower.mock"
reading(){ batpower once 2>/dev/null | awk '{print $2}'; }   # "STATE V I T" -> V
[ "$(reading)" = - ] && ok "default config: planted mock not read (UNKNOWN)" || bad "default config read a value: $(batpower once)"
# the detached guard owns the end of the bench window: removes the plant, reverts the staged config, restarts
# batpower — whatever happens to this shell or its ssh (review 3 #6)
GD=$(mktemp -d); G=$GD/hit; setsid sh -c "trap '' HUP PIPE; end=\$(( \$(cut -d. -f1 /proc/uptime) + $LIFE )); while [ \$(cut -d. -f1 /proc/uptime) -lt \$end ]; do
	for s in /tmp/batpower.state $RUNDIR/batpower.state; do [ \"\$(cut -d' ' -f2 \$s 2>/dev/null)\" = 1000 ] && { rm -f /tmp/batpower.mock; echo HIT > $G; }; done
	dmesg | tail -20 | grep -q 'LOW BATTERY' && { rm -f /tmp/batpower.mock; echo LOW >> $G; }
	sleep 1; done; rm -f /tmp/batpower.mock; uci -q revert batpower; /etc/init.d/batpower restart; echo DONE >> $GD/done" </dev/null >/dev/null 2>&1 &
uci -q set batpower.main.source=mock; uci -q set batpower.main.mock_ok=1   # staged only; the guard reverts it
v=$(reading); [ "$v" = 1000 ] && bad "mock config READ the planted /tmp value (old code path)" || ok "mock config: /tmp plant not read (reads the run dir: $v)"
# negative control: point the once-only seam at the planted file — the oracle must see it
[ "$(BATPOWER_MOCK_PATH=/tmp/batpower.mock batpower once 2>/dev/null | awk '{print $2}')" = 1000 ] \
	&& ok "negative control: the seam reads the plant (the oracle can tell)" || bad "negative control did not read the plant — oracle unproven"
t0=$(date +%s)
/etc/init.d/batpower restart >/dev/null 2>&1
sleep $((LIFE + 3))
i=0; while [ ! -s "$GD/done" ] && [ $i -lt 10 ]; do sleep 1; i=$((i+1)); done
[ -s "$GD/done" ] && ok "the detached guard ended the bench window (plant removed, config reverted, batpower restarted)" || bad "the detached guard did not finish"
[ -e /tmp/batpower.mock ] && { rm -f /tmp/batpower.mock; bad "guard did not remove the plant"; }
# the daemon must really have ticked in the window — "never read the plant" means nothing from a dead daemon
st=$(cat "$RUNDIR/batpower.state" 2>/dev/null); sts=${st##* }
case "$sts" in ''|*[!0-9]*) bad "batpower published no state ([$st]) — the daemon check proves nothing";;
	*) [ "$sts" -ge "$t0" ] && ok "batpower daemon ticked in the window (state: $st)" || bad "batpower state not refreshed in the window ([$st])";; esac
[ -s "$G" ] && bad "batpower daemon read the planted value ($(tr '\n' ' ' < "$G"))" || ok "batpower daemon never read the planted value over ${LIFE}s"
rm -rf "$GD"
[ -z "$(uci -q changes batpower)" ] && ok "no staged batpower config left behind" || bad "staged batpower config left: $(uci -q changes batpower | tr '\n' ' ')"
echo "== tmp-trust-280: $([ $rc = 0 ] && echo PASS || echo FAIL)"
exit $rc
