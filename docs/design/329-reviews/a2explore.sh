#!/bin/bash
# A2: page positions and screencap sizes on the pages the device checks use (no 手機 Wi-Fi tap, no node change).
# Taps: the 04 card, 「更多」, 「國家」, Back. Dumps only pages that are not secure (a2lib-v2.sh).
. "$(dirname "$0")/a2lib-v2.sh"
front || { log "STOP: the app is not in front"; exit 1; }
home || { log "STOP: not home"; exit 1; }
log "home size=$(capsize || echo unknown) 02 y=$(desc_y 880C) 04 y=$(desc_y 7D2C)"
tap_desc 7D2C || exit 1; sleep 12
log "node page size=$(capsize || echo unknown): $(descs)"
log "wifi y=$(desc_y '手機 Wi-Fi') more y=$(desc_y '更多')"
tap_desc '更多' || { back; exit 1; }; sleep 3
log "more size=$(capsize || echo unknown): $(descs)"
log "country y=$(desc_y '國家')"
tap_desc '國家' || { back; back; exit 1; }; sleep 6
log "country size=$(capsize || echo unknown): $(descs)"
dump | tr '>' '\n' | grep -ao 'content-desc="[^"]\+"' | head -30
back; back; back
home && log "end: home" || log "end: not home"
