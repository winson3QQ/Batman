# shellcheck shell=bash
# scripts/dv/known-failures.sh — sourced by scripts/daily-validation.sh (and tests/known-failures.sh): the NEW vs KNOWN
# split of failed suites (#268 C1) against scripts/validation-known-failures.txt, with an expiry per entry
# (docs/design/254-h23-harness.md §4 "known-failures": 4th column expires=YYYY-MM-DD).
#   kf_check <file>          every entry has 4 TAB columns: suite, ERE, issue number, expires=YYYY-MM-DD (a real date);
#                            prints one "FAIL known-failures: …" line per bad entry; rc 1 when any (the run FAILs)
#   kf_classify <suite> <log> <file> [today]  -> "known <#issues>" or "new <why>"
# A suite is KNOWN only if EVERY "FAIL …" line of its log matches one of its unexpired entries. These are never known,
# whatever the list says (NEVER_KNOWN): a node left degraded, a failed restore / cleanup, a dropped connection, a
# reboot that did not happen, anything unreadable, a node handed to a person. An expired entry matches nothing (NEW,
# "expired"). With gh, an entry whose issue is CLOSED is NEW. The run's exit status is never changed by this.
NEVER_KNOWN='restore|cleanup|CONNECTION-LOST|CONNLOST|reboot did not happen|unreadable|not verified|rc=3 without|NEEDS-PERSON|blocked: DNODE'
kf_check() {
	local f=$1 ln=0 bad=0 line ks pat iss ex rest d
	[ -f "$f" ] || { echo "FAIL known-failures: no $f"; return 1; }
	while IFS= read -r line; do
		ln=$((ln + 1))
		case "$line" in ''|'#'*) continue ;; esac
		IFS=$'\t' read -r ks pat iss ex rest <<< "$line"
		if [ -z "$ks" ] || [ -z "$pat" ] || [ -z "$iss" ] || [ -z "$ex" ] || [ -n "$rest" ]; then
			echo "FAIL known-failures: line $ln has not exactly 4 TAB columns (suite, ERE, issue, expires=YYYY-MM-DD)"; bad=1; continue
		fi
		case "$iss" in *[!0-9]*) echo "FAIL known-failures: line $ln issue [$iss] is not a number"; bad=1; continue ;; esac
		d=${ex#expires=}
		if [ "$d" = "$ex" ] || ! [[ "$d" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || ! date -d "$d" +%F >/dev/null 2>&1 || [ "$(date -d "$d" +%F)" != "$d" ]; then
			echo "FAIL known-failures: line $ln 4th column [$ex] is not expires=YYYY-MM-DD"; bad=1; continue
		fi
	done < "$f"
	[ $bad = 0 ]
}
kf_classify() {
	local s=$1 log=$2 file=$3 today=${4:-$(date +%F)} line pat iss ex hit issues="" st ks lines expired=""
	lines=$(grep -E '^[[:space:]]*FAIL ' "$log" 2>/dev/null | sed 's/^[[:space:]]*//')
	[ -n "$lines" ] || { echo "new (no FAIL lines to match)"; return; }
	while IFS= read -r line; do
		echo "$line" | grep -qE "$NEVER_KNOWN" && { echo "new (never-known failure: $line)"; return; }
		hit=""
		while IFS=$'\t' read -r ks pat iss ex; do
			case "$ks" in ''|'#'*) continue ;; esac
			[ "$ks" = "$s" ] && [ -n "$iss" ] && echo "$line" | grep -qE -- "$pat" || continue
			if [[ "${ex#expires=}" < "$today" ]]; then expired="#$iss ${ex#expires=}"; continue; fi
			hit=$iss; break
		done < "$file"
		[ -n "$hit" ] || { if [ -n "$expired" ]; then echo "new (the entry for $expired has expired: $line)"; else echo "new (unmatched: $line)"; fi; return; }
		case " $issues " in *" #$hit "*) ;; *) issues="$issues #$hit" ;; esac
	done <<< "$lines"
	if [ "${KF_NO_GH:-0}" != 1 ] && command -v gh >/dev/null 2>&1; then
		for iss in $issues; do st=$(gh issue view "${iss#\#}" -R winson3QQ/Batman --json state --jq .state 2>/dev/null)
			[ "$st" = CLOSED ] && { echo "new (matches $iss, but $iss is CLOSED)"; return; }
			[ -z "$st" ] && issues="$issues(state?)"; done
	else issues="$issues (issue state not checked: no gh)"; fi
	echo "known$issues"
}
