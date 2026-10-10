# payload-lib.sh — checks shared by payload-run and the payload guardian (#274 D7-6, docs/design/274-payload-converge.md §12).
#
# One allowlist for what a container may have, applied to what payload-run would create (preflight) and to
# what exists (the guardian's tick, foreign containers included). Anything not on the list is "dangerous".
# Sourced (busybox ash); every function prints one problem per line and returns 0 — the caller decides.
#
# shellcheck shell=sh

# capabilities a tenant may ADD (on top of --cap-drop=ALL). Empty today: no shipped tenant needs one.
PL_CAPS_ALLOWED=""

# a manifest value that is joined to the tenant dir: a plain basename, nothing else (#274 B-N4)
pl_isbase(){
	case "$1" in ''|.|..|*/*|*[!A-Za-z0-9._-]*) return 1 ;; esac
	return 0
}

pl_cap_ok(){
	c=$(echo "$1" | tr 'a-z' 'A-Z'); c=${c#CAP_}
	for a in $PL_CAPS_ALLOWED; do [ "$a" = "$c" ] && return 0; done
	return 1
}

# $1 = a HARDEN_FLAGS string. Prints a problem per flag that is not on the allowlist, and one if
# no-new-privileges is missing. --restart is never allowed here (payload-run renders `--restart no` itself).
pl_harden_problems(){
	nnp=0; want=""
	# shellcheck disable=SC2086  # the flag string is word-split on purpose (no spaces inside values)
	set -- $1
	for t in "$@"; do
		if [ -n "$want" ]; then
			case "$want" in
				security-opt) case "$t" in no-new-privileges|no-new-privileges:true|no-new-privileges=true) nnp=1 ;;
				                  *) echo "flag --security-opt $t is not allowed" ;; esac ;;
				cap-add) pl_cap_ok "$t" || echo "flag --cap-add $t is not allowed" ;;
			esac
			want=""; continue
		fi
		case "$t" in
			--read-only|--init) ;;
			--user|--tmpfs|--cpus|--pids-limit|--memory|--memory-swap|--memory-reservation|--cap-drop|--stop-timeout|--stop-signal|--ulimit|--shm-size)
				want=value ;;
			--user=*|--tmpfs=*|--cpus=*|--pids-limit=*|--memory=*|--memory-swap=*|--memory-reservation=*|--cap-drop=*|--stop-timeout=*|--stop-signal=*|--ulimit=*|--shm-size=*) ;;
			--security-opt) want="security-opt" ;;
			--security-opt=*) v=${t#--security-opt=}
				case "$v" in no-new-privileges|no-new-privileges:true|no-new-privileges=true) nnp=1 ;;
				             *) echo "flag --security-opt $v is not allowed" ;; esac ;;
			--cap-add) want="cap-add" ;;
			--cap-add=*) pl_cap_ok "${t#--cap-add=}" || echo "flag $t is not allowed" ;;
			*) echo "flag $t is not allowed" ;;
		esac
	done
	[ "$want" = value ] && want=""
	[ -n "$want" ] && echo "flag --$want has no value"
	[ "$nnp" = 1 ] || echo "no-new-privileges is not set"
	return 0
}

# $1 = container name or ID; $2 = the tenant dir its RO binds may come from ("" = a foreign container: no bind
# at all is acceptable); $3 = the one user-defined network it may use ("" = any user-defined network or none).
# Prints one problem per violation; prints "gone" if the container does not exist.
pl_container_problems(){
	_c=$1; _dir=$2; _net=$3
	_h=$(docker inspect -f '{{.HostConfig.Privileged}}|{{.HostConfig.NetworkMode}}|{{.HostConfig.PidMode}}|{{.HostConfig.IpcMode}}|{{.HostConfig.UTSMode}}|{{.HostConfig.UsernsMode}}|{{.HostConfig.CgroupnsMode}}|{{len .HostConfig.Devices}}|{{len .HostConfig.DeviceCgroupRules}}|{{range .HostConfig.CapAdd}}{{.}} {{end}}|{{range .HostConfig.SecurityOpt}}{{.}} {{end}}|{{len .HostConfig.VolumesFrom}}' "$_c" 2>/dev/null) \
		|| { echo gone; return 0; }
	_oifs=$IFS; IFS='|'
	# shellcheck disable=SC2086
	set -- $_h
	IFS=$_oifs
	[ "$1" = false ] || echo "privileged"
	case "$2" in
		none) ;;
		host|bridge|default|container:*) echo "network $2" ;;
		*) [ -z "$_net" ] || [ "$2" = "$_net" ] || echo "network $2 (expected $_net)" ;;
	esac
	[ "$3" = host ] && echo "pid=host"
	[ "$4" = host ] && echo "ipc=host"
	[ "$5" = host ] && echo "uts=host"
	[ "$6" = host ] && echo "userns=host"
	[ "$7" = host ] && echo "cgroupns=host"
	[ "$8" = 0 ] || echo "devices: $8"
	[ "$9" = 0 ] || echo "device cgroup rules: $9"
	shift 9
	for cap in $1; do pl_cap_ok "$cap" || echo "cap-add $cap"; done
	_nnp=0
	for so in $2; do
		case "$so" in
			no-new-privileges|no-new-privileges:true|no-new-privileges=true) _nnp=1 ;;
			*) echo "security-opt $so" ;;
		esac
	done
	[ "$_nnp" = 1 ] || echo "no-new-privileges not set"
	[ "$3" = 0 ] || echo "volumes-from"
	# mounts: local named volumes without driver options; RO binds of a regular file in the tenant's own dir
	docker inspect -f '{{range .Mounts}}{{.Type}}|{{.Name}}|{{.Source}}|{{.RW}}|{{.Driver}}
{{end}}' "$_c" 2>/dev/null | while IFS='|' read -r mt mn ms mrw md; do
		[ -n "$mt" ] || continue
		case "$mt" in
			volume)
				[ "$md" = local ] || { echo "volume $mn driver $md"; continue; }
				o=$(docker volume inspect -f '{{len .Options}}' "$mn" 2>/dev/null)
				[ "$o" = 0 ] || echo "volume $mn has driver options (a disguised bind)" ;;
			bind)
				if [ -z "$_dir" ]; then echo "bind $ms ($([ "$mrw" = true ] && echo rw || echo ro))"
				elif [ "$mrw" = true ]; then echo "bind $ms rw"
				else case "$ms" in "$_dir"/*) case "${ms#"$_dir"/}" in secrets/*/*) echo "bind $ms outside the tenant dir" ;;
				                                                       secrets/*) ;; */*) echo "bind $ms outside the tenant dir" ;; esac ;;
				                    *) echo "bind $ms outside the tenant dir" ;; esac
				fi ;;
			tmpfs) ;;
			*) echo "mount type $mt" ;;
		esac
	done
	return 0
}
