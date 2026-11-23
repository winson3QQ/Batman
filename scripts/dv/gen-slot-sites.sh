#!/bin/bash
# scripts/dv/gen-slot-sites.sh --draft [ROOT] — the draft of scripts/dv/data/slot-sites.tsv, the inventory of
# test-slot-guard-254.sh lint (3) (#254 v1.6 group 4 §4.3, §13.8, §15): every line in scope that reboots (`reboot` as a
# word, or `sysrq-trigger`), minus comment lines, one row per distinct line text per file:
#   <file> TAB <exact hit count> TAB <group> TAB <trimmed line text, tabs written as \t>
# Scope: scripts/dv, scripts/node, scripts/{fault-injection,ab-selftest,negctl-old-slot-254,daily-validation}.sh;
# *.sh only; not test-*.sh, slot-guard-254.sh or this file.
# The group is only a guess: `prechecked` for reboot_and_wait (daily-validation.sh), `text` for a line whose first word
# prints (echo / say / no / …), `REVIEW` otherwise. The lint FAILs on REVIEW: every non-text row is set by hand to
# allowlisted:<reason> or prechecked, and every text row is checked by hand, before the file is committed.
set -u
export LC_ALL=C   # bytes as they are (a UTF-8 em dash must not be re-encoded by the locale)
[ "${1:-}" = --draft ] || { echo "usage: $0 --draft [ROOT] > slot-sites.tsv.draft"; exit 2; }
ROOT=${2:-$(cd "$(dirname "$0")/../.." && pwd)}
cd "$ROOT" || exit 2
SCOPE=(scripts/dv scripts/node scripts/fault-injection.sh scripts/ab-selftest.sh scripts/negctl-old-slot-254.sh scripts/daily-validation.sh)
for p in "${SCOPE[@]}"; do [ -e "$p" ] || { echo "gen-slot-sites: scope $p missing" >&2; exit 1; }; done
echo "# scripts/dv/data/slot-sites.tsv — lint (3) of scripts/dv/test-slot-guard-254.sh (#254 v1.6 group 4 §4.3, §15)."
echo "# file<TAB>count<TAB>group<TAB>line text (trimmed, tabs as \\t). group: allowlisted:<reason> | prechecked | text"
echo "# Drafted by scripts/dv/gen-slot-sites.sh --draft; every non-text row set and every text row checked by hand."
find "${SCOPE[@]}" -name '*.sh' ! -name 'test-*.sh' ! -name slot-guard-254.sh ! -name gen-slot-sites.sh -type f | LC_ALL=C sort \
	| while IFS= read -r f; do
		grep -E '\breboot\b|sysrq-trigger' "$f" | grep -vE '^[[:space:]]*#' | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//; s/\t/\\t/g' \
			| LC_ALL=C sort | uniq -c | sed -E 's/^ *([0-9]+) /\1\t/' | while IFS=$'\t' read -r c t; do
				g=REVIEW
				case "$f" in scripts/daily-validation.sh) case "$t" in *'reboot_and_wait '*|*'cmd=${2:-reboot}'*) g=prechecked ;; esac ;; esac
				[ "$g" = REVIEW ] && case "${t%% *}" in echo|say|no|ok|fail|die|tbad|tok|r|inv|warn|bad|note|printf|logger|log|pass) g=text ;; esac
				printf '%s\t%s\t%s\t%s\n' "$f" "$c" "$g" "$t"
			done
	done
