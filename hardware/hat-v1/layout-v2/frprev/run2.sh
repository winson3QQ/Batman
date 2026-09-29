#!/bin/sh
# two Freerouting runs on frprev.dsn (headless; env settings, see closeout/run.sh), then import + DRC each
cd "$(dirname "$0")"
JAR=${FREEROUTING_JAR:-$HOME/tools/freerouting-2.1.0.jar}
for tag in r1 r2; do
  rm -f frprev-$tag.ses
  FREEROUTING__USAGE_AND_DIAGNOSTIC_DATA__DISABLE_ANALYTICS=true FREEROUTING__PROFILE__ALLOW_TELEMETRY=false \
  FREEROUTING__GUI__ENABLED=false FREEROUTING__ROUTER__MAX_PASSES=20 FREEROUTING__ROUTER__JOB_TIMEOUT=00:10:00 \
    timeout 900 java -jar "$JAR" -de frprev.dsn -do frprev-$tag.ses -mp 20 -mt 1 -da --gui.enabled=false > freerouting-$tag.log 2>&1
  echo "[$tag] java exit $?"
  grep -o "Auto-routing was completed.*" freerouting-$tag.log || tail -3 freerouting-$tag.log
  [ -s frprev-$tag.ses ] && python3 ../frpreview.py import $tag frprev-$tag.ses || echo "[$tag] no .ses"
done
