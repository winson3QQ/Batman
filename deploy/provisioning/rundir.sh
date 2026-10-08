# shellcheck shell=sh disable=SC3043   # busybox ash has local
# /usr/lib/batman/rundir.sh — the root-only run directory for batman decision state (#280).
#
# /tmp is world-writable (1777): any non-root process (dnsmasq, avahi, ntpd, ubus, a container that escaped
# into a non-root uid) can pre-create a name there, and since fs.protected_regular=0 root then writes INTO
# the attacker's file. Every marker that decides commit/revert/slot/reboot/halt, a health verdict, a lock,
# or what root writes to a boot sector lives here instead. docs/design/280-tmp-trust.md.
#
# Spelled /tmp/run/batman, NEVER /var/run/...: /var is a symlink to tmp in normal boots but a fresh real
# directory in the sysupgrade stage-2 ramfs, while /tmp crosses supivot (design B1). /tmp/run is created
# root 0755 by procd before any non-root process exists, so nobody else can create anything in it.
#
#   batman_rundir           ensure + verify; rc 0 ok, rc 1 unusable (the caller fails CLOSED)
#   batman_tmp [-d] [prefix] print a fresh mktemp file (or dir) <prefix>.XXXXXX inside it; rc 1 if unusable
# Test seam: BATMAN_RUNDIR (tests/ab-card-invariants.sh runs storage scripts on a build host).
RUNDIR=${BATMAN_RUNDIR:-/tmp/run/batman}

# owner-is-me, not a symlink, and mode bits per `ls -ld` (busybox has no stat)
_rd_mode(){ ls -ld "$1" 2>/dev/null | cut -c1-10; }
batman_rundir(){
	local p
	p=${RUNDIR%/*}   # no dirname: not in the sysupgrade ramfs
	# parent: ours (root in production), not a symlink, not group/other-writable
	[ -d "$p" ] && [ ! -L "$p" ] && [ -O "$p" ] || { _rd_log "parent $p not owned by us / missing"; return 1; }
	case "$(_rd_mode "$p")" in d????w????|d???????w?) _rd_log "parent $p is group/other-writable"; return 1;; esac
	mkdir -m 700 "$RUNDIR" 2>/dev/null   # EEXIST from a concurrent creator is fine: always verify below
	[ -d "$RUNDIR" ] && [ ! -L "$RUNDIR" ] && [ -O "$RUNDIR" ] && [ "$(_rd_mode "$RUNDIR")" = drwx------ ] \
		|| { _rd_log "$RUNDIR is not a private directory of ours"; return 1; }
	return 0
}
batman_tmp(){
	local d=""
	[ "${1:-}" = -d ] && { d=-d; shift; }
	batman_rundir || return 1
	# shellcheck disable=SC2086
	mktemp $d "$RUNDIR/${1:-t}.XXXXXX"
}
_rd_log(){ logger -t batman-rundir "UNUSABLE: $*" 2>/dev/null; echo "batman-rundir: UNUSABLE: $*" >&2; }
