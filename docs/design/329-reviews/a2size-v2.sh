#!/bin/bash
# A2 (r6-B m4): evidence for the secure-page check. Prints screencap SIZES only: home, 04's node page, 手機 Wi-Fi.
# No dump anywhere in this script. Taps: the 04 card, the 手機 Wi-Fi entry (calm position), Back twice.
. "$(dirname "$0")/a2lib-v2.sh"
log "home size=$(capsize || echo unknown)"
log "tap 04"; $A $D shell input tap 540 1563; sleep 20
log "node page size=$(capsize || echo unknown)"
tap_wifi 1610; sleep 6
log "wifi page size=$(capsize || echo unknown)"
back
log "after Back size=$(capsize || echo unknown) WIFI=$WIFI"
back
log "after Back 2 size=$(capsize || echo unknown)"
