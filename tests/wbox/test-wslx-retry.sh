#!/bin/bash
# tests/wbox/test-wslx-retry.sh [<dv-prov-tools.sh>] — #254 L132 (docs/design/254-v16-group4.md §16): wslx of
# scripts/dv-prov-tools.sh retries ONLY a WSL launcher failure (rc 127 AND "Wsl/" in its stdout), at most 3 tries,
# each retry logged; anything else is returned at once. The function is taken from the script (its text, not a copy)
# and run against a stub wsl.exe first on PATH; `sleep` is stubbed (it records the 5 s, it does not wait).
#   1 one launcher failure, then the output   -> rc 0, the output, exactly one retry logged, 2 calls
#   2 the launcher failure every time         -> rc 127, 3 calls, 2 retries + "giving up"
#   3 rc 1 with a Wsl/ message                -> rc 1, 1 call, no retry
#   4 rc 127 without "Wsl/" (a missing command in WSL) -> rc 127, 1 call, no retry
#   5 a UTF-16 launcher message (NUL bytes between the letters) -> retried like case 1
# Negative control: main's one-line wslx FAILs case 1 (and 5).   -> "TEST-WSLX: N passed, M failed", rc 1 on any FAIL
set -u
S=${1:-$(cd "$(dirname "$0")/../.." && pwd)/scripts/dv-prov-tools.sh}
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
P=0; F=0
# the wslx definition: a one-liner ends on its own line, a block at the first line that is "}"
awk '/^wslx\(\)/ && !on { on = 1; print; if (/; }$/) exit; next } on { print } on && /^}/ { exit }' "$S" > "$T/wslx.sh"
grep -q '^wslx()' "$T/wslx.sh" || { echo "FAIL no wslx() in $S"; echo "TEST-WSLX: 0 passed, 1 failed"; exit 1; }
mkdir -p "$T/bin"
cat > "$T/bin/wsl.exe" <<'EOF'
#!/bin/bash
# stub: STUB_MODE once|always|rc1|plain127|utf16; calls counted in $STUB_DIR/calls
n=$(( $(cat "$STUB_DIR/calls" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$STUB_DIR/calls"
msg='Wsl/Service/0x8007274c'
case "$STUB_MODE" in
	once) [ "$n" = 1 ] && { echo "$msg"; exit 127; }; echo PAYLOAD-OK; exit 0 ;;
	utf16) [ "$n" = 1 ] && { printf 'W\0s\0l\0/\0S\0e\0r\0v\0i\0c\0e\0\n\0'; exit 127; }; echo PAYLOAD-OK; exit 0 ;;
	always) echo "$msg"; exit 127 ;;
	rc1) echo "$msg"; exit 1 ;;
	plain127) echo "bash: no-such-cmd: command not found"; exit 127 ;;
esac
EOF
chmod +x "$T/bin/wsl.exe"
# run <mode>: OUT RC ERR CALLS SLEEPS
run(){ rm -f "$T/calls" "$T/sleeps"
	OUT=$(PATH="$T/bin:$PATH" STUB_MODE=$1 STUB_DIR=$T bash -c '. "$1"; sleep(){ echo "$1" >> "$STUB_DIR/sleeps"; }; wslx cat /x' _ "$T/wslx.sh" 2>"$T/err" </dev/null); RC=$?
	ERR=$(cat "$T/err"); CALLS=$(cat "$T/calls" 2>/dev/null || echo 0); SLEEPS=$([ -f "$T/sleeps" ] && tr '\n' ' ' < "$T/sleeps")
	RETRIES=$(grep -c 'retry' <<< "$ERR"); }
chk(){ local l=$1; shift; if "$@"; then echo "ok   $l (rc $RC, calls $CALLS, retries logged $RETRIES, sleeps [$SLEEPS])"; P=$((P + 1)); else echo "FAIL $l (rc $RC, calls $CALLS, retries logged $RETRIES, sleeps [$SLEEPS], out [$(tr -d '\000' <<< "$OUT" | tr '\n' '|')], err [$(tr '\n' '|' <<< "$ERR")])"; F=$((F + 1)); fi; }
c1(){ [ "$RC" = 0 ] && [ "$OUT" = PAYLOAD-OK ] && [ "$CALLS" = 2 ] && [ "$RETRIES" = 1 ] && [ "$SLEEPS" = "5 " ]; }
c2(){ [ "$RC" = 127 ] && [ "$CALLS" = 3 ] && [ "$RETRIES" = 2 ] && grep -q 'giving up' <<< "$ERR"; }
c3(){ [ "$RC" = 1 ] && [ "$CALLS" = 1 ] && [ "$RETRIES" = 0 ] && [ -z "$SLEEPS" ]; }
c4(){ [ "$RC" = 127 ] && [ "$CALLS" = 1 ] && [ "$RETRIES" = 0 ] && [ -z "$SLEEPS" ]; }
run once;     chk "1 one launcher failure (rc 127 + Wsl/) -> retried once, the output comes through" c1
run always;   chk "2 launcher failure every time -> rc 127 after 3 tries" c2
run rc1;      chk "3 rc 1 with a Wsl/ message -> no retry" c3
run plain127; chk "4 rc 127 without Wsl/ -> no retry" c4
run utf16;    chk "5 a UTF-16 launcher message -> retried once" c1
echo "TEST-WSLX: $P passed, $F failed"; [ "$F" = 0 ] && [ "$P" -gt 0 ]
