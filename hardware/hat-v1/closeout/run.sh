#!/bin/sh
# HAT v1 routing close-out, end to end (KiCad 7.0.x pcbnew python, Java 21, Freerouting 2.1.0).
#   1. baseline board = the cloud hand-off (commit 8041361), extracted once to out/route/baseline.kicad_pcb
#   2. closeout.py  : hand edits + input-stage re-place, pours, hand lanes
#   3. export.py    : incremental Specctra DSN (existing copper kept)
#   4. Freerouting  : headless, analytics off, 12 passes and a 4 min job timeout via environment
#                     variables (it ignores -mp headless and ran forever); saves the .ses and exits.
#                     GUI mode is not used: its "User Settings" dialog blocks the save and once held
#                     a run for 1 h 45 min.
#   5. finish.py    : gen/layout.finish() -- import SES, GND pours + stitching, widen power, DRC
#   6. post.py      : solid EP vias, drop dangling leftovers (only if KiCad connectivity agrees)
#   7. bottleneck.py: narrowest track on each main current path
# Freerouting is NOT deterministic: the same input gave 0 unconnected on one run and 2 on the next.
# The committed board is a run that ended at 0; re-runs must be checked (the gate below) and
# repeated until DRC reports 0 unconnected pads.
set -e
cd "$(dirname "$0")/.."
mkdir -p out/route
[ -f out/route/baseline.kicad_pcb ] || git show 8041361:hardware/hat-v1/batman-hat.kicad_pcb > out/route/baseline.kicad_pcb
JAR=${FREEROUTING_JAR:-$HOME/tools/freerouting-2.1.0.jar}

python3 closeout/closeout.py
python3 closeout/export.py
rm -f out/route/batman-hat-inc.ses
# Headless: the command-line -mp is ignored there, but router.max_passes / job_timeout from the
# environment are honoured, and the run saves the .ses and exits on its own (no GUI, no dialogs).
(cd out/route && FREEROUTING__USAGE_AND_DIAGNOSTIC_DATA__DISABLE_ANALYTICS=true   FREEROUTING__PROFILE__ALLOW_TELEMETRY=false FREEROUTING__GUI__ENABLED=false   FREEROUTING__ROUTER__MAX_PASSES=12 FREEROUTING__ROUTER__JOB_TIMEOUT=00:04:00   timeout 600 java -jar "$JAR" -de batman-hat-inc.dsn -do batman-hat-inc.ses -mp 12 -mt 1 -da   --gui.enabled=false > freerouting.log 2>&1) || { echo "GATE: Freerouting failed / timed out"; exit 1; }
[ -s out/route/batman-hat-inc.ses ] || { echo "GATE: Freerouting wrote no .ses"; exit 1; }
grep -o "Auto-routing was completed.*" out/route/freerouting.log
python3 closeout/finish.py
python3 closeout/post.py | tee out/route/post.log
grep -q "Found 0 unconnected pads" out/route/post.log || { echo "GATE: unconnected pads left -- re-run"; exit 1; }
for p in "VBAT_RAW J1.1 Q1.1" "EF_IN Q1.5 U1.1" "EF_OUT U1.18 R9.1" "VSYS R9.2 U3.2 C6.1" \
         "5V_BUCK L1.2 Q3.1" "5V_PI Q3.5 J2.2 J2.4" "3V3_BUCK L2.2 R22.1" "3V3_MPCIE JP1.2 J3.2"; do
  python3 closeout/bottleneck.py $p
done
