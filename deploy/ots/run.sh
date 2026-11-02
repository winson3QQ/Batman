#!/bin/sh
# run.sh — thin shim (#167 Increment 3). OTS now deploys via the GENERIC payload manager: the full
# 6-container spec (images, per-container env/entrypoint/ip/hostname, volume chowns, the
# rabbitmq-extra.conf mount, lifecycle order + health) lives declaratively in
# deploy/ots/profile.yaml's operational siblings, rendered to deploy/ots/ots.manifest by
# scripts/profile-to-manifest.py and executed by /usr/bin/payload-run. The bespoke run.sh this
# replaced (behaviourally equivalent — validated on manet01, verify-profile-ots OK + CoT round-trip)
# is in git history. See docs/design/167-payload-manager.md §14.
#
# Bench use: APPS_DIR=<dir-containing-opentakserver/> run.sh   (default APPS_DIR=/opt/batdata/apps)
exec payload-run opentakserver
