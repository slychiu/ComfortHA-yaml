#!/bin/bash
# HDMI monitor-detected-at-boot check. Live-tested 2026-07-22 on cytech.local:
# with no monitor attached, the vc4 KMS driver never creates the connector
# node at all (dmesg: "[drm] No displays found") -- with one attached at
# boot, /sys/class/drm/card1-HDMI-A-1/status reads "connected". This board's
# driver does NOT do live runtime hotplug polling after boot (confirmed:
# unplugging mid-session left status unchanged), so this is only meaningful
# read once, right after a fresh power-on -- exactly how the pre-ship test
# uses it. Never a hard failure: a real pre-ship run needs a human to have
# plugged a monitor in per the setup instructions, and this just reports
# whether that happened rather than gating the rest of the test on it.
exec >> /config/cytech_update.log 2>&1
echo "=== cytech_check_hdmi.sh $(date) ==="

STATUS_FILE=$(ls /sys/class/drm/card*-HDMI-*/status 2>/dev/null | head -1)

if [ -n "$STATUS_FILE" ] && [ "$(cat "$STATUS_FILE")" = "connected" ]; then
  MSG="HDMI OK: monitor detected at boot ($(basename "$(dirname "$STATUS_FILE")"))"
else
  MSG="Monitor not connected"
fi

jq -n --arg ts "$(date +%s)" --arg msg "$MSG" '{ts: $ts, message: $msg}' > /config/.cytech_hdmi_result
