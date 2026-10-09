#!/bin/sh
# scripts/node/tmp-trust-280.sh — runtime check that a NON-ROOT process cannot steer the node through /tmp (#280).
# Run on a node as root: ssh root@node 'sh -s' < scripts/node/tmp-trust-280.sh. docs/design/280-tmp-trust.md D6 + §9.
# Safe by construction (§9 N2): the planted battery reading lives at most (CONFIRM-1)*INTERVAL-5 s and a root guard
# removes it unconditionally at that deadline, so even a fully regressed batpower can never see CONFIRM readings
# in a row — it cannot reach CRIT, so it cannot halt the node. Version-gated: never plants on a pre-#280 image.
# Every plant is checked for its EFFECT, not only for "not honoured" (review 2 #5): a check that a pre-#280 build
# would also pass proves nothing.
# Exit: 0 pass, 1 FAIL, 3 + SKIP-REASON when it does not apply.
[ -r /usr/lib/batman/rundir.sh ] || { echo "SKIP-REASON: pre-#280 image (no /usr/lib/batman/rundir.sh) — nothing planted"; exit 3; }
# shellcheck source=/dev/null
. /usr/lib/batman/rundir.sh
rc=0
bad(){ echo "FAIL $*"; rc=1; }
ok(){ echo "ok   $*"; }
info(){ echo "info $*"; }
NB(){ start-stop-daemon -S -c nobody -n tmptrust280 -a /bin/sh -- -c "$1"; }   # busybox has no su
lsm(){ ls -ld "$1" 2>/dev/null | awk '{print $1, $3}'; }
T=$(for d in /opt/batdata/apps/*/; do [ -d "$d" ] && ls "$d"*.manifest >/dev/null 2>&1 && { d=${d%/}; echo "${d##*/}"; break; }; done)
PLANTS="/tmp/batpower.mock /tmp/batman-autocommit.hold /tmp/batman-fw-override /tmp/autocommit.committed /tmp/batman-reboot.want /tmp/autocommit.decided /tmp/batman-slot.busy /tmp/autocommit.wd /tmp/root"
[ -n "$T" ] && PLANTS="$PLANTS /tmp/batman-payload-$T.stopping /tmp/batman-payload-$T.stop0"
cleanup(){ for p in $PLANTS; do rm -rf "$p"; done; uci -q revert batpower; }
# a previous run killed before its trap must not leave a staged bench config behind (review 2 #5)
uci -q revert batpower
trap cleanup EXIT

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

# 2 the boot-time markers are really produced (review 2 BLOCKER 1: the generated batdata-mount init once had no
#   mark/tmpd/RUNDIR, so none of these was ever written and nothing noticed)
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
NB "for p in /tmp/batman-autocommit.hold /tmp/batman-fw-override /tmp/autocommit.committed /tmp/batman-reboot.want /tmp/batman-slot.busy; do echo 2 > \$p; done; mkdir /tmp/autocommit.decided /tmp/autocommit.wd"
s=$(halow-status 2>/dev/null)
echo "$s" | grep -q 'TAMPER: /tmp/batman-autocommit.hold' && ok "planted hold shown as TAMPER" || bad "planted hold not flagged by halow-status"
j=$(halow-status json 2>/dev/null)
echo "$j" | grep -q '"fw_override":""' && ok "planted /tmp/batman-fw-override ignored" || bad "fw_override not empty with only a planted /tmp file: $(echo "$j" | grep -o '"fw_override":"[^"]*"')"
u=$(cut -d. -f1 /proc/uptime)
o=$(AUTOCOMMIT_DRYRUN=1 AUTOCOMMIT_FORCE_TRIAL=1 AUTOCOMMIT_TIMEOUT=$((u + 20)) batman-autocommit run 2>&1)
echo "$o" | grep -q 'TAMPER: /tmp/batman-autocommit.hold' && ok "autocommit reports the planted hold as TAMPER" || bad "autocommit did not report the planted hold"
# effect: with planted committed/decided/wd/busy a pre-#280 autocommit stops before deciding; ours decides
echo "$o" | grep -q 'DRYRUN decision:' && ok "autocommit still reached a decision with committed/decided/wd/busy planted in /tmp" \
	|| bad "autocommit reached no decision with /tmp plants present: $(echo "$o" | tail -2 | tr '\n' ' ')"
echo "$o" | grep -q 'hold present' && bad "autocommit HONOURED a hold planted by nobody" || info "autocommit did not honour the planted hold (also true before #280 — not a gate)"
# effect: a planted stopping/stop0 must not stop the payload tenant from being (re)started
if [ -n "$T" ]; then
	NB "echo 2 > /tmp/batman-payload-$T.stopping; echo '0 0 nodocker' > /tmp/batman-payload-$T.stop0"
	payload-run --start-only "$T" >/dev/null 2>&1; prc=$?
	[ "$prc" != 4 ] && ok "payload-run --start-only $T ignores a /tmp stopping flag planted by nobody (rc=$prc)" \
		|| bad "payload-run refused with rc 4 (being stopped) because of a /tmp flag planted by nobody"
else info "no payload tenant on this node — payload plant skipped"; fi

# 5 sysupgrade RAM_ROOT (review 2 BLOCKER 2): a /tmp/root planted by nobody is taken back before stage 1 copies into it
rm -rf /tmp/root
NB "mkdir -p /tmp/root/sbin && echo planted > /tmp/root/sbin/upgraded"
[ -f /tmp/root/sbin/upgraded ] || bad "could not plant /tmp/root as nobody — the guard check below proves nothing"
g=$(sh -c '. /lib/functions.sh; . /lib/upgrade/common.sh; . /lib/upgrade/platform.sh; _ab_ramroot_guard' 2>&1); grc=$?
[ "$grc" = 0 ] && [ ! -e /tmp/root/sbin/upgraded ] && [ "$(lsm /tmp/root)" = "drwx------ root" ] \
	&& ok "planted /tmp/root removed and re-created root 0700 ($(echo "$g" | head -1))" \
	|| bad "RAM_ROOT guard rc=$grc, /tmp/root [$(lsm /tmp/root)], plant $( [ -e /tmp/root/sbin/upgraded ] && echo STILL THERE || echo gone)"
rm -rf /tmp/root

# 6 N8 sweep: no root-owned file under a directory someone else owns; no batman decision name left at /tmp's top
sw=$(find /tmp -xdev -mindepth 1 -maxdepth 3 -user root 2>/dev/null | while read -r f; do
	p=${f%/*}; [ "$(ls -ld "$p" | awk '{print $3}')" = root ] || echo "$f (parent $p owned by $(ls -ld "$p" | awk '{print $3}'))"; done)
[ -z "$sw" ] && ok "N8: no root-owned entry under a non-root directory in /tmp" || bad "N8: root-owned entries under non-root dirs: $(echo "$sw" | head -3 | tr '\n' ';')"
left=""
for f in /tmp/autocommit* /tmp/batman-fw-override* /tmp/batman-slot.* /tmp/batpower.* /tmp/batdata* /tmp/batman-payload-* /tmp/batman-firstload-*; do
	{ [ -e "$f" ] || [ -L "$f" ]; } || continue
	case "$f" in /tmp/batman-slot.allow-*) continue;; esac       # opf-checked operator flag, stays in /tmp
	case " $PLANTS " in *" $f "*) continue;; esac                # this test's own plants
	left="$left $f"
done
[ -z "$left" ] && ok "N8: no batman decision state at the top of /tmp" || bad "N8: batman state still in /tmp: $(echo "$left" | tr '\n' ' ')"

# 7 batpower: never a reading from a world-writable file (N1 oracle on both configs, N2 bounded plant)
CONF=$(uci -q get batpower.main.confirm || echo 3); IVL=$(uci -q get batpower.main.interval || echo 10)
if [ "$CONF" -lt 3 ] || [ "$IVL" -lt 10 ]; then echo "SKIP-REASON: batpower confirm=$CONF interval=$IVL — the bounded plant needs confirm>=3, interval>=10"; exit 3; fi
LIFE=$(( (CONF - 1) * IVL - 5 ))
NB "echo 1000 > /tmp/batpower.mock"
reading(){ batpower once 2>/dev/null | awk '{print $2}'; }   # "STATE V I T" -> V
[ "$(reading)" = - ] && ok "default config: planted mock not read (UNKNOWN)" || bad "default config read a value: $(batpower once)"
uci -q set batpower.main.source=mock; uci -q set batpower.main.mock_ok=1   # staged only, reverted on exit
v=$(reading); [ "$v" = 1000 ] && bad "mock config READ the planted /tmp value (old code path)" || ok "mock config: /tmp plant not read (reads the run dir: $v)"
# negative control: point the once-only seam at the planted file — the oracle must see it
[ "$(BATPOWER_MOCK_PATH=/tmp/batpower.mock batpower once 2>/dev/null | awk '{print $2}')" = 1000 ] \
	&& ok "negative control: the seam reads the plant (the oracle can tell)" || bad "negative control did not read the plant — oracle unproven"
# daemon under the staged mock config, plant alive at most $LIFE s (guard deletes it whatever happens)
G=$(mktemp); setsid sh -c "end=\$(( \$(cut -d. -f1 /proc/uptime) + $LIFE )); while [ \$(cut -d. -f1 /proc/uptime) -lt \$end ]; do
	for s in /tmp/batpower.state $RUNDIR/batpower.state; do [ \"\$(cut -d' ' -f2 \$s 2>/dev/null)\" = 1000 ] && { rm -f /tmp/batpower.mock; echo HIT > $G; }; done
	dmesg | tail -20 | grep -q 'LOW BATTERY' && { rm -f /tmp/batpower.mock; echo LOW >> $G; }
	sleep 1; done; rm -f /tmp/batpower.mock" </dev/null >/dev/null 2>&1 &
t0=$(date +%s)
/etc/init.d/batpower restart >/dev/null 2>&1
sleep $((LIFE + 3))
[ -e /tmp/batpower.mock ] && { rm -f /tmp/batpower.mock; bad "guard did not remove the plant"; }
# the daemon must really have ticked in the window — "never read the plant" means nothing from a dead daemon
st=$(cat "$RUNDIR/batpower.state" 2>/dev/null); sts=${st##* }
case "$sts" in ''|*[!0-9]*) bad "batpower published no state in the window ([$st]) — the daemon check proves nothing";;
	*) [ "$sts" -ge "$t0" ] && ok "batpower daemon ticked in the window (state: $st)" || bad "batpower state not refreshed in the window ([$st])";; esac
[ -s "$G" ] && bad "batpower daemon read the planted value ($(tr '\n' ' ' < "$G"))" || ok "batpower daemon never read the planted value over ${LIFE}s"
rm -f "$G"
uci -q revert batpower; /etc/init.d/batpower restart >/dev/null 2>&1
[ -z "$(uci -q changes batpower)" ] && ok "no staged batpower config left behind" || bad "staged batpower config left: $(uci -q changes batpower | tr '\n' ' ')"
echo "== tmp-trust-280: $([ $rc = 0 ] && echo PASS || echo FAIL)"
exit $rc
