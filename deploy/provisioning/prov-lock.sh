# shellcheck shell=sh
# /usr/lib/batman/prov-lock.sh — #254 PR-P1: the provisioning-record formats and the ONE lock decision
# 96-batman-config-migrate makes at every exit (docs/design/254-stage1-impl.md §4.3; 254-p1-impl.md §4.8).
# Sourced (root) by 96-batman-config-migrate, batman-config-save, batman-prov-lock and batman-provhelper. Pure functions except prov_apply_lock.
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
# prov_lock_decision <p5_read 0|1> <meta_status word> <meta_state|-> <last_known_state|-> [any]: prints LOCK or TODAY
#   p5 readable: meta ok + state claimed/member -> LOCK; meta present but bad (or too new) -> LOCK (fail-secure,
#   it may be claimed/member); meta absent -> TODAY.
#   p5 NOT readable (bypass / no p5 / not ext4 / mount failed): p6 last_known_state claimed/member -> LOCK.
#   "any" (batman-prov-lock, #254 claim-lock fix §5.4): p5 readable AND p6 says claimed/member -> LOCK too — a ro,noload
#   read does not replay the journal, so a power cut before config-save's umount can show the pre-claim meta.
#   dev-open does not exempt a LOCK (parent §4.3).
prov_lock_decision() {
	if [ "$1" = 1 ]; then
		case "$2:$3" in ok:claimed|ok:member) echo LOCK; return ;; bad:*) echo LOCK; return ;; esac
		[ "${5:-}" = any ] && case "$4" in claimed|member) echo LOCK; return ;; esac
	else
		case "$4" in claimed|member) echo LOCK; return ;; esac
	fi
	echo TODAY
}
# prov_root_hash_ok <field>: rc 0 when musl crypt() can verify a password against <field> (claim-lock fix §5.3 v8):
#   $1$<salt 0-8>$<22>  |  $5$[rounds=N$]<salt 0-16>$<43>  |  $6$[rounds=N$]<salt 0-16>$<86>
#   N decimal 1000-9999999, no leading zero (musl rewrites anything else in its output: never matches); after it the
#   rest is salt as in musl (a salt may itself read "rounds=…");
#   salt without $ : newline; hash part in [./0-9A-Za-z]. Anything else (DES, $2…, empty, !…) -> 1.
# Used ONLY where a hash is converged to or written (S13, --hash-stdin). "Has the operator set a password" (not open)
# stays a plain `$…` check in config-save and 96.
prov_root_hash_ok() {
	_rh=$1
	case "$_rh" in *:*|*"
"*) return 1 ;; esac
	case "$_rh" in
		'$1$'*) _rh_sm=8; _rh_hl=22 ;;
		'$5$'*) _rh_sm=16; _rh_hl=43 ;;
		'$6$'*) _rh_sm=16; _rh_hl=86 ;;
		*) return 1 ;;
	esac
	_rh_t=${_rh%"${_rh#???}"}; _rh_r=${_rh#???}
	if [ "$_rh_t" != '$1$' ]; then
		case "$_rh_r" in rounds=*)
			_rh_n=${_rh_r#rounds=}; _rh_n=${_rh_n%%\$*}
			case "$_rh_n" in ''|0*|*[!0-9]*) return 1 ;; esac
			[ "${#_rh_n}" -le 7 ] && [ "$_rh_n" -ge 1000 ] || return 1
			_rh_r=${_rh_r#"rounds=$_rh_n\$"}
		;; esac
	fi
	_rh_s=${_rh_r%%\$*}; [ "$_rh_r" != "$_rh_s" ] || return 1
	[ "${#_rh_s}" -le "$_rh_sm" ] || return 1
	_rh_x=${_rh_r#"$_rh_s\$"}
	[ "${#_rh_x}" = "$_rh_hl" ] || return 1
	case "$_rh_x" in *[!./0-9A-Za-z]*) return 1 ;; esac
	return 0
}
# prov_apply_lock [--hash-stdin | --restore-stdin] [--no-reload] — THE one lock implementation (#254 claim-lock fix
# §5.3; callers: 96, batman-prov-lock, batman-provhelper). Order "lock the doors first, change the password last":
#   1 every dropbear section PasswordAuth/RootPasswordAuth=off, system ttylogin=1, uci commit
#   2 (unless --no-reload) dropbear running -> reload, then EVERY instance's command must carry -s and -g; an ubus
#     failure is a step-2 failure (fail-closed). The read-back proves procd's record; procd swaps the master async.
#   3 root's shadow field: --hash-stdin = the line read from stdin, written only if 1-2 succeeded; --restore-stdin =
#     written whatever 1-2 did (the helper's restore after a failed --save); otherwise (and when 1-2 failed) only an
#     EMPTY root field becomes "!". mktemp in /etc + sync + mv + sync. --hash-stdin: the field must pass
#     prov_root_hash_ok, else rc 3 and shadow untouched; --restore-stdin: a $… / !… field without ':' is written
#     back as is, anything else as "!" (same rule as the helper's RestoreRoot). stdin is read ONLY with a flag.
#   4 p6 lock-status (tmp + mv): LOCKED when 1-3 succeeded, else LOCK-INCOMPLETE; a write failure is only logged.
# Last stdout line: "LOCK <ok|uci|dropbear|shadow> rc=<0|1|2|3>". Test hooks (CI only, never set on a node):
# PROV_SHADOW, PROV_STATE, PROV_DROPBEAR_INIT.
prov_apply_lock() {
	_pl_in=""; _pl_nr=0
	for _pl_a in "$@"; do
		case "$_pl_a" in
			--hash-stdin) _pl_in='hash' ;; --restore-stdin) _pl_in='restore' ;; --no-reload) _pl_nr=1 ;;
			*) echo "LOCK usage rc=9"; return 9 ;;
		esac
	done
	_pl_sh=${PROV_SHADOW:-/etc/shadow}; _pl_st=${PROV_STATE:-/opt/batdata/state}
	_pl_new=""
	if [ -n "$_pl_in" ]; then
		IFS= read -r _pl_new || [ -n "$_pl_new" ] || { echo "LOCK shadow rc=3"; return 3; }
		if [ "$_pl_in" = hash ]; then
			prov_root_hash_ok "$_pl_new" || { echo "prov_apply_lock: refusing a hash musl cannot verify (prov_root_hash_ok)"; echo "LOCK shadow rc=3"; return 3; }
		else case "$_pl_new" in *:*) _pl_new='!' ;; \$*|!*) ;; *) _pl_new='!' ;; esac; fi
	fi
	_pl_rc=0; _pl_step=ok
	# 1 uci
	_pl_ok=1
	set -f   # the section names are expanded unquoted: no globbing (review A-m6)
	for _pl_s in $(uci -q show dropbear 2>/dev/null | sed -n 's/^dropbear\.\([^.=]*\)=dropbear$/\1/p'); do
		uci set "dropbear.$_pl_s.PasswordAuth=off" && uci set "dropbear.$_pl_s.RootPasswordAuth=off" || _pl_ok=0
	done
	set +f
	uci set 'system.@system[0].ttylogin=1' || _pl_ok=0
	uci commit dropbear || _pl_ok=0
	uci commit system || _pl_ok=0
	[ "$_pl_ok" = 1 ] || { _pl_rc=1; _pl_step=uci; }
	# 2 dropbear
	if [ "$_pl_rc" = 0 ] && [ "$_pl_nr" = 0 ]; then
		if ! _pl_o=$(ubus -t 5 call service list '{"name":"dropbear"}' 2>/dev/null); then
			_pl_rc=2; _pl_step=dropbear
		elif printf '%s' "$_pl_o" | grep -q '"instances"'; then
			"${PROV_DROPBEAR_INIT:-/etc/init.d/dropbear}" reload >/dev/null 2>&1
			_pl_i=0; _pl_good=0
			while [ "$_pl_i" -lt 5 ]; do
				_pl_c=$(ubus -t 5 call service list '{"name":"dropbear"}' 2>/dev/null | jsonfilter -e '@.dropbear.instances[*].command' 2>/dev/null)
				if [ -n "$_pl_c" ] && ! printf '%s\n' "$_pl_c" | grep -v '"-s"' | grep -q . && ! printf '%s\n' "$_pl_c" | grep -v '"-g"' | grep -q .; then _pl_good=1; break; fi
				_pl_i=$((_pl_i + 1)); sleep 1
			done
			[ "$_pl_good" = 1 ] || { _pl_rc=2; _pl_step=dropbear; }
		fi
	fi
	# 3 shadow
	_pl_shrc=0
	_pl_cur=$(grep '^root:' "$_pl_sh" 2>/dev/null | cut -d: -f2)
	if [ "$_pl_in" = restore ] || { [ "$_pl_in" = hash ] && [ "$_pl_rc" = 0 ]; }; then _pl_want=$_pl_new
	else case "$_pl_cur" in \$*|!*) _pl_want=$_pl_cur ;; *) _pl_want='!' ;; esac; fi
	if [ "$_pl_want" != "$_pl_cur" ]; then
		_pl_t=$(mktemp "${_pl_sh%/*}/.shadow.XXXXXX") || _pl_shrc=3
		if [ -n "${_pl_t:-}" ]; then
			if PL_W="$_pl_want" awk 'BEGIN { w = ENVIRON["PL_W"] } /^root:/ { n = split($0, f, ":"); f[2] = w; s = f[1]; for (i = 2; i <= n; i++) s = s ":" f[i]; print s; next } { print }' "$_pl_sh" > "$_pl_t" \
				&& [ -s "$_pl_t" ] && chmod 600 "$_pl_t" && sync && mv "$_pl_t" "$_pl_sh" && sync \
				&& [ "$(grep '^root:' "$_pl_sh" | cut -d: -f2)" = "$_pl_want" ]; then :
			else rm -f "$_pl_t"; _pl_shrc=3; fi
		fi
	fi
	[ "$_pl_shrc" = 3 ] && [ "$_pl_rc" = 0 ] && { _pl_rc=3; _pl_step=shadow; }
	# --restore-stdin: the caller only asks "is root's field back?" — its rc is step 3's alone (review B-m3); the doors
	# (steps 1-2) are re-tried by batman-prov-lock at the next boot and lock-status still says LOCK-INCOMPLETE
	_pl_doors=$_pl_rc
	[ "$_pl_in" = restore ] && { if [ "$_pl_shrc" = 0 ]; then _pl_rc=0; _pl_step=ok; else _pl_rc=3; _pl_step=shadow; fi; }
	# 4 lock-status
	if [ -n "${PROV_STATE:-}" ] || grep -q ' /opt/batdata ' /proc/mounts 2>/dev/null; then
		_pl_w=LOCKED; [ "$_pl_rc" = 0 ] && [ "$_pl_doors" = 0 ] || _pl_w=LOCK-INCOMPLETE
		{ mkdir -p "$_pl_st" && _pl_t=$(mktemp "$_pl_st/.lock-status.XXXXXX") && echo "$_pl_w" > "$_pl_t" && chmod 644 "$_pl_t" && mv "$_pl_t" "$_pl_st/lock-status"; } 2>/dev/null \
			|| logger -t prov-lock "lock-status not written ($_pl_w)" 2>/dev/null
	fi
	echo "LOCK $_pl_step rc=$_pl_rc"
	return "$_pl_rc"
}
