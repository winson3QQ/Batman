#!/bin/bash
# app/rust/batman-proto/test-all.sh — the crate's regular test suite: BOTH builds (design §4.1 / §6: the trust policy is
# the Cargo feature `dev-trust`, so `cargo test` alone compiles the dev-build tests out). Each build must run and pass a
# non-zero number of tests, the dev-only and field-only trust tests must each have run, and the release feature tree
# must carry neither `dev-trust` nor `test-vectors` nor `team-write`. 254-app-team-status: a third round per crate with
# `team-write,dev-trust` (the N+1 behaviour, tests only) whose T-A8 / duplicate-address tests must each have run; the
# bridge's release feature tree and cargokit.yaml must not carry `team-write` (it is also a compile_error in a
# release build). Then the bridge's tests (../bridge) in both builds (without
# dev-trust the remote-invite entries must refuse: member-join M14), `flutter analyze lib` and `flutter test` (the app;
# FLUTTER, else flutter on PATH, else ~/flutter/bin/flutter). The Kotlin JVM tests need the Android SDK (the Windows
# build tree): not run here. Anything missing is a FAIL, never a clean result.
set -u
cd "$(dirname "$0")" || exit 2
CARGO=${CARGO:-cargo}
fail=0
run(){ # <name> <must-run tests, comma-separated> [cargo args]
	local name=$1 must=$2; shift 2
	local out passed failed
	out=$($CARGO test "$@" -- --test-threads=4 2>&1); local rc=$?
	passed=$(grep -E '^test result:' <<< "$out" | sed -E 's/.* ([0-9]+) passed; ([0-9]+) failed.*/\1/' | paste -sd+ | bc)
	failed=$(grep -E '^test result:' <<< "$out" | sed -E 's/.* ([0-9]+) passed; ([0-9]+) failed.*/\2/' | paste -sd+ | bc)
	if [ "$rc" != 0 ] || [ "${failed:-1}" != 0 ]; then echo "FAIL $name: cargo rc=$rc failed=${failed:-?}"; grep -E 'FAILED|panicked|^error' <<< "$out" | head -5; fail=1
	elif [ "${passed:-0}" -le 0 ]; then echo "FAIL $name: no test ran"; fail=1
	else
		local m missing=""
		for m in ${must//,/ }; do grep -q "^test $m \.\.\. ok$" <<< "$out" || missing="$missing $m"; done
		if [ -n "$missing" ]; then echo "FAIL $name: did not run:$missing"; fail=1
		else echo "PASS $name: $passed tests"; fi
	fi
}
SW=t4_the_whole_path_in_order_with_its_waits_and_no_secret_in_any_text,r1_a_stale_status_is_read_again_and_never_says_ssh_or_reflash
run field-build first_contact_field_build_refuses_dev_certificates,$SW
run dev-build first_contact_dev_build_accepts_dev_tofu,$SW --features dev-trust
TW=t_a8_addr_read_decision,t_a2_approve_drops_a_duplicated_address_from_both,t_a2_rekey_drops_a_duplicated_address_from_both
run team-write-build $TW --features team-write,dev-trust
# -i batman-proto: the crate's OWN enabled features too (a plain tree lists only its dependencies' features)
n=$( { $CARGO tree -e features,no-dev; $CARGO tree -e features,no-dev -i batman-proto; } 2>/dev/null | grep -cE 'dev-trust|test-vectors|team-write')
if [ "$n" = 0 ] && $CARGO tree -e features,no-dev >/dev/null 2>&1; then echo "PASS release feature tree: no dev-trust / test-vectors / team-write"
else echo "FAIL release feature tree: $n line(s) with dev-trust / test-vectors / team-write"; fail=1; fi
cd ../bridge || exit 2
SWB=api::owner::sw_tests::t4_the_path_through_the_owner_session,api::swupdate::tests::new_takes_the_build_trust_gate
run bridge-field api::member::tests::m14_every_entry_refuses_without_dev_trust,$SWB
run bridge-dev api::owner::tests::make_network_unclear_reply_confirms_with_chained_generations,$SWB --features dev-trust
T8=api::owner::team_addr_tests::t_a8_nothing_else_starts_during_the_address_read,api::owner::team_addr_tests::t_a8_fresh_read_beats_the_stale_page,api::owner::team_addr_tests::t_a8_e_rate_is_retried_a_bounded_number_of_times,api::owner::team_addr_tests::t_a8_busy_or_failure_goes_on_without_key7,api::owner::team_addr_tests::t_a8_join2_stores_the_fresh_address,api::owner::team_addr_tests::t_a8_join_request_is_built_with_the_fresh_address
run bridge-team-write api::owner::tests::make_network_unclear_reply_confirms_with_chained_generations,$T8 --features team-write,dev-trust
# the app's Rust build: neither its feature tree nor cargokit.yaml (debug / release / profile flags) may name team-write
n=$( { $CARGO tree -e features,no-dev; $CARGO tree -e features,no-dev -i batman-proto; cat cargokit.yaml; } 2>/dev/null | grep -c 'team-write')
if [ "$n" = 0 ] && $CARGO tree -e features,no-dev >/dev/null 2>&1 && [ -f cargokit.yaml ]; then echo "PASS bridge release features: no team-write"
else echo "FAIL bridge release features: $n line(s) with team-write (feature tree or cargokit.yaml)"; fail=1; fi
cd ../.. || exit 2
FLUTTER=${FLUTTER:-$(command -v flutter || echo "$HOME/flutter/bin/flutter")}
if [ ! -x "$FLUTTER" ]; then echo "FAIL flutter analyze lib: no flutter at $FLUTTER"; fail=1
else
	out=$("$FLUTTER" analyze lib 2>&1); rc=$?
	if [ "$rc" = 0 ] && grep -q "No issues found!" <<< "$out"; then echo "PASS flutter analyze lib"
	else echo "FAIL flutter analyze lib: rc=$rc"; grep -E "error|warning|info" <<< "$out" | head -5; fail=1; fi
	# flutter test's JSON events: every passed test by its full name (a progress reporter skips names of fast tests).
	# 254-app-update (r2 A-m11): the update page tests must be among them, and no test skipped.
	js=$("$FLUTTER" test -r json 2>/dev/null); rc=$?
	jf=$(mktemp); printf '%s\n' "$js" > "$jf"
	summary=$(python3 - "$jf" "M17 SAS screens" "D8: the Specifier path" "r1 A-M2 / B-M1: one upload stage joins the node AP once" <<'PY'
import json, sys
names, done = {}, []
for line in open(sys.argv[1], encoding="utf-8"):
    line = line.strip()
    if not line.startswith("{"):
        continue
    e = json.loads(line)
    if e.get("type") == "testStart":
        names[e["test"]["id"]] = e["test"]["name"]
    elif e.get("type") == "testDone" and not e.get("hidden"):
        done.append((names.get(e["testID"], ""), e.get("result"), e.get("skipped")))
passed = [n for n, r, s in done if r == "success" and not s]
miss = [m for m in sys.argv[2:] if not any(m in n for n in passed)]
skipped = [n for n, r, s in done if s]
failed = [n for n, r, s in done if r != "success"]
print(len(passed), len(failed), "|".join(miss + ["skipped: " + n for n in skipped]))
PY
)
	rm -f "$jf"
	read -r n nfail miss <<< "$summary"
	if [ "$rc" = 0 ] && [ "${n:-0}" -gt 0 ] && [ "${nfail:-1}" = 0 ] && [ -z "$miss" ]; then echo "PASS flutter test: $n tests"
	else echo "FAIL flutter test: rc=$rc passed=${n:-?} failed=${nfail:-?}${miss:+ missing: $miss}"; fail=1; fi
fi
[ "$fail" = 0 ] && echo "ALL PASS" || echo "SUITE FAIL"
exit "$fail"
