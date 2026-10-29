#!/bin/bash
# scripts/dv/prov-normalise-254.sh <V> — #254 head of the prov block (docs/design/254-h23-harness.md §4.4): 04 committed
# on A with version V (pr_normalise in scripts/dv/prov-254.sh). No snapshot: it moves 04 between slots, nothing else.
set -u
PR_UNIT=prov-normalise-254
# shellcheck source=scripts/dv/prov-254.sh
. "$(dirname "$0")/prov-254.sh"
pr_normalise "${1:?usage: prov-normalise-254.sh <V>}"
r=$?; [ "$PR_BEGUN" = 1 ] && [ "${PR_PERSON:-0}" = 0 ] && pr_release
pr_result; exit $r
