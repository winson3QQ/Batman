# shellcheck shell=bash
# scripts/lib/wbox-derive.sh — derive_misc: a misc-* autocommit mutant (#254 -wbox, dry-run bind only) made on the host
# from V's own batman-autocommit + the repo patch tests/wbox/<name>.patch (docs/design/254-v16-group4.md §2, §13.4,
# §15). Sourced by scripts/dv-prov-tools.sh and tests/wbox/test-derive-misc.sh; runs in Git Bash and in Linux / WSL.
#
#   derive_misc <V-autocommit> <patch> <outdir>
#     -> <outdir>/batman-autocommit, <outdir>/SHA256SUMS (exactly one line "<sha>  batman-autocommit", checked by
#        prov-misc-254.sh `sha256sum -c`), <outdir>/PROVENANCE (base sha, patch path, patch blob id); rc 0.
#     Any failure: a "derive_misc: FAIL ..." line, rc 1, and none of the three files left in <outdir> (a stale mutant
#     of an earlier run must not survive a failed derive: prov-misc then reports INVALID up front).
#
# How (fail-closed at every step):
#   - a fresh 0700 `mktemp -d`; refused when git sees a work tree there (inside one, `git apply` skips the patch with
#     rc 0 — review v3 A M1 / B m7);
#   - hermetic git: no system / global config or attributes, HOME = the work dir, XDG_CONFIG_HOME / GIT_DIR /
#     GIT_WORK_TREE / GIT_CONFIG_PARAMETERS / GIT_CONFIG_COUNT / GIT_CEILING_DIRECTORIES unset, core.autocrlf=false,
#     core.eol=lf, core.attributesFile=/dev/null (so no attributes file can turn the output into CRLF);
#   - the base is copied to the repo path the patch names (feed/batman-provision/files/usr/bin/batman-autocommit) and
#     `git apply -v --check`, then `git apply -v`, run with the default -p1; rc != 0 or a "Skipped patch" line = FAIL;
#   - the output differs from the base, has no CR byte, passes `sh -n`, and `git apply -R --check` of the same patch
#     succeeds on it (so exactly that patch was applied).
WBOX_DERIVE_PATH=feed/batman-provision/files/usr/bin/batman-autocommit
derive_misc(){
	local base=${1:-} patch=${2:-} out=${3:-} w rc
	[ -n "$base" ] && [ -n "$patch" ] && [ -n "$out" ] || { echo "derive_misc: FAIL usage: derive_misc <V-autocommit> <patch> <outdir>"; return 1; }
	mkdir -p "$out" && rm -f "$out/batman-autocommit" "$out/SHA256SUMS" "$out/PROVENANCE" || { echo "derive_misc: FAIL cannot prepare $out"; return 1; }
	[ -f "$base" ] && [ -s "$base" ] || { echo "derive_misc: FAIL no base file $base"; return 1; }
	[ -f "$patch" ] && [ -s "$patch" ] || { echo "derive_misc: FAIL no patch $patch"; return 1; }
	case "$base" in /*) ;; *) base=$PWD/$base ;; esac
	case "$patch" in /*) ;; *) patch=$PWD/$patch ;; esac
	w=$(mktemp -d) || { echo "derive_misc: FAIL mktemp -d"; return 1; }
	chmod 700 "$w"
	(
		unset XDG_CONFIG_HOME GIT_DIR GIT_WORK_TREE GIT_CONFIG_PARAMETERS GIT_CONFIG_COUNT GIT_CEILING_DIRECTORIES \
			GIT_INDEX_FILE GIT_OBJECT_DIRECTORY GIT_COMMON_DIR GIT_NAMESPACE GIT_PREFIX
		export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null GIT_ATTR_NOSYSTEM=1 HOME=$w
		g(){ git -c core.autocrlf=false -c core.eol=lf -c core.attributesFile=/dev/null "$@"; }
		cd "$w" || { echo "derive_misc: FAIL cd $w"; exit 1; }
		if g rev-parse --is-inside-work-tree >/dev/null 2>&1; then
			echo "derive_misc: FAIL refused: the work dir $w is inside a git work tree (git apply would skip the patch with rc 0)"; exit 1
		fi
		f=$WBOX_DERIVE_PATH
		mkdir -p "${f%/*}" && cp "$base" "$f" || { echo "derive_misc: FAIL copy of the base"; exit 1; }
		o=$(g apply -v --check "$patch" 2>&1); rc=$?
		[ "$rc" = 0 ] || { echo "derive_misc: FAIL apply --check rc $rc: $(echo "$o" | tail -3 | tr '\n' '|')"; exit 1; }
		grep -q 'Skipped patch' <<< "$o" && { echo "derive_misc: FAIL apply --check skipped the patch: $(echo "$o" | tr '\n' '|')"; exit 1; }
		o=$(g apply -v "$patch" 2>&1); rc=$?
		[ "$rc" = 0 ] || { echo "derive_misc: FAIL apply rc $rc: $(echo "$o" | tail -3 | tr '\n' '|')"; exit 1; }
		grep -q 'Skipped patch' <<< "$o" && { echo "derive_misc: FAIL apply skipped the patch: $(echo "$o" | tr '\n' '|')"; exit 1; }
		cmp -s "$base" "$f" && { echo "derive_misc: FAIL the output equals the base (the patch changed nothing)"; exit 1; }
		n=$(tr -dc '\r' < "$f" | wc -c | tr -d ' ')
		[ "$n" = 0 ] || { echo "derive_misc: FAIL the output has $n CR byte(s)"; exit 1; }
		o=$(sh -n "$f" 2>&1) || { echo "derive_misc: FAIL sh -n: $(echo "$o" | head -2 | tr '\n' '|')"; exit 1; }
		o=$(g apply -R --check "$patch" 2>&1) || { echo "derive_misc: FAIL reverse check: the output is not base + exactly this patch: $(echo "$o" | tail -2 | tr '\n' '|')"; exit 1; }
		blob=$(g hash-object --no-filters "$patch") && [ -n "$blob" ] || { echo "derive_misc: FAIL git hash-object of the patch"; exit 1; }
		sb=$(sha256sum < "$base" | cut -c1-64); so=$(sha256sum < "$f" | cut -c1-64)
		cp "$f" "$out/batman-autocommit.new" && mv -f "$out/batman-autocommit.new" "$out/batman-autocommit" \
			&& (cd "$out" && sha256sum batman-autocommit > SHA256SUMS && sha256sum -c --quiet SHA256SUMS) >/dev/null 2>&1 \
			&& printf 'base_sha256=%s\npatch=%s\npatch_blob=%s\noutput_sha256=%s\n' "$sb" "$2" "$blob" "$so" > "$out/PROVENANCE" \
			|| { echo "derive_misc: FAIL write to $out"; exit 1; }
		echo "derive_misc: ok ${so:0:16} (base ${sb:0:16}, patch $(basename "$2") blob ${blob:0:12})"
	); rc=$?
	rm -rf "$w"
	[ "$rc" = 0 ] || rm -f "$out/batman-autocommit" "$out/batman-autocommit.new" "$out/SHA256SUMS" "$out/PROVENANCE"
	return "$rc"
}
