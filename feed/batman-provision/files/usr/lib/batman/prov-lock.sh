# shellcheck shell=sh
# /usr/lib/batman/prov-lock.sh — #254 PR-P1: the provisioning-record formats and the ONE lock decision
# 96-batman-config-migrate makes at every exit (docs/design/254-stage1-impl.md §4.3; 254-p1-impl.md §4.8).
# Sourced (root) by 96-batman-config-migrate and batman-config-save. Pure functions except prov_apply_lock.
# busybox ash; no bashisms.

PROV_IDFILES="node.key ecdh.key node.cert claim.secret backend sn"
PROV_MAX=65536

# prov_meta_ok <meta>: a well-formed v=1 meta line -> prints "v state gen sha", rc 0. rc 2 = v too new, 1 = bad.
# Format (parent §4.3): one line "v=1 state=<s> gen=<n> sha=<hex64>", <= 256 B, charset [a-z0-9=_ ], unknown keys ignored.
prov_meta_ok() {
	[ -f "$1" ] && [ ! -L "$1" ] || return 1
	[ "$(wc -c < "$1")" -le 256 ] || return 1
	[ "$(wc -l < "$1")" -le 1 ] || return 1
	_l=$(head -n 1 "$1")
	case "$_l" in *[!a-z0-9=_\ ]*) return 1 ;; esac
	_v=""; _s=""; _g=""; _h=""
	for _kv in $_l; do
		case "$_kv" in v=*) _v=${_kv#v=} ;; state=*) _s=${_kv#state=} ;; gen=*) _g=${_kv#gen=} ;; sha=*) _h=${_kv#sha=} ;; esac
	done
	case "$_v" in ''|*[!0-9]*) return 1 ;; esac
	[ "$_v" -gt 1 ] && return 2
	[ "$_v" = 1 ] || return 1
	case "$_s" in legacy|unclaimed|claimed|member) ;; *) return 1 ;; esac
	case "$_g" in ''|*[!0-9]*) return 1 ;; esac
	[ "${#_h}" = 64 ] || return 1
	case "$_h" in *[!0-9a-f]*) return 1 ;; esac
	echo "$_v $_s $_g $_h"
}
# prov_cbor_ok <cbor> <sha>: regular, <= 64 KiB, matching sha
prov_cbor_ok() {
	[ -f "$1" ] && [ ! -L "$1" ] || return 1
	[ "$(wc -c < "$1")" -le "$PROV_MAX" ] || return 1
	[ "$(sha256sum < "$1" | cut -c1-64)" = "$2" ]
}
# prov_ident_ok <dir>: the 7 identity files, regular, sha256 lists exactly the first 6 and they match
prov_ident_ok() {
	[ -d "$1" ] && [ ! -L "$1" ] || return 1
	for _f in $PROV_IDFILES sha256; do [ -f "$1/$_f" ] && [ ! -L "$1/$_f" ] || return 1; done
	[ "$(wc -l < "$1/sha256")" -eq 6 ] || return 1
	for _f in $PROV_IDFILES; do grep -q "^[0-9a-f]\{64\}  $_f\$" "$1/sha256" || return 1; done
	( cd "$1" && sha256sum -c sha256 >/dev/null 2>&1 )
}
# prov_meta_status <meta> <cbor>: absent | ok <state> | bad   (too-new counts as bad here: its state is unknown)
prov_meta_status() {
	[ -e "$1" ] || [ -L "$1" ] || { echo absent; return 0; }
	_m=$(prov_meta_ok "$1") || { echo bad; return 0; }
	set -- "$2" $_m
	prov_cbor_ok "$1" "$5" || { echo bad; return 0; }
	echo "ok $3"
}
# prov_last_known_state: field 3 of p6 prov-state when p6 is mounted, else "-"
prov_last_known_state() {
	grep -q ' /opt/batdata ' /proc/mounts 2>/dev/null || { echo -; return 0; }
	_k=$(awk 'NR==1 {print $3}' /opt/batdata/state/prov-state 2>/dev/null)
	case "$_k" in legacy|unclaimed|claimed|member) echo "$_k" ;; *) echo - ;; esac
}
# prov_lock_decision <p5_read 0|1> <meta_status word> <meta_state|-> <last_known_state|->: prints LOCK or TODAY
#   p5 readable: meta ok + state claimed/member -> LOCK; meta present but bad (or too new) -> LOCK (fail-secure,
#   it may be claimed/member); meta absent -> TODAY.
#   p5 NOT readable (bypass / no p5 / not ext4 / mount failed): p6 last_known_state claimed/member -> LOCK.
#   dev-open does not exempt a LOCK (parent §4.3).
prov_lock_decision() {
	if [ "$1" = 1 ]; then
		case "$2:$3" in ok:claimed|ok:member) echo LOCK; return ;; bad:*) echo LOCK; return ;; esac
	else
		case "$4" in claimed|member) echo LOCK; return ;; esac
	fi
	echo TODAY
}
# prov_apply_lock: network key-only, serial via a password, root without a hash becomes "root:!"
prov_apply_lock() {
	uci set dropbear.@dropbear[0].PasswordAuth='off'
	uci set dropbear.@dropbear[0].RootPasswordAuth='off'
	uci set system.@system[0].ttylogin='1'
	uci commit dropbear; uci commit system
	case "$(grep '^root:' /etc/shadow 2>/dev/null | cut -d: -f2)" in
		\$*|!*) : ;;
		*) awk '/^root:/ { n = split($0, f, ":"); f[2] = "!"; s = f[1]; for (i = 2; i <= n; i++) s = s ":" f[i]; print s; next } { print }' \
			/etc/shadow > /etc/shadow.prov 2>/dev/null && [ -s /etc/shadow.prov ] && grep -q '^root:!' /etc/shadow.prov \
			&& chmod 600 /etc/shadow.prov && mv /etc/shadow.prov /etc/shadow || rm -f /etc/shadow.prov ;;
	esac
	grep -q ' /opt/batdata ' /proc/mounts 2>/dev/null && { mkdir -p /opt/batdata/state; echo LOCKED > /opt/batdata/state/lock-status; }
	return 0
}
