#!/bin/bash
# "Check for Update" — checks manifest and notifies; does NOT apply the update
exec >> /config/cytech_update.log 2>&1
echo "=== cytech_check_only.sh $(date) ==="
source /config/.cytech_secrets

# Writes {"ts": ..., "message": ...} JSON to one or more files. Sensor STATE
# values are capped at 255 characters in HA and silently become "unknown"
# past that; the "message" attribute (read via json_attributes) has no such
# limit, so all Cytech status text goes through here rather than raw state.
write_msg() {
  local msg="$1"
  shift
  local json
  json=$(jq -n --arg ts "$(date +%s)" --arg msg "$msg" '{ts: $ts, message: $msg}')
  for f in "$@"; do
    echo "$json" > "$f"
  done
}

LOCAL_VER=$(cat /config/.cytech_version 2>/dev/null || echo 0)
MANIFEST=$(curl -sf --max-time 10 "${CYTECH_MANIFEST_URL}" 2>/dev/null)

if [ -z "$MANIFEST" ]; then
  write_msg "Could not reach update server. Check your internet connection." /config/.cytech_notify_pending
  exit 1
fi

REMOTE_VER=$(echo "$MANIFEST" | jq -r '.version // 0')
CHANGELOG=$(echo "$MANIFEST" | jq -r '.changelog // "No details available"')

if [ "$REMOTE_VER" -le "$LOCAL_VER" ] 2>/dev/null; then
  write_msg "System is up to date (v${LOCAL_VER})." /config/.cytech_notify_pending /config/.cytech_last_result
  rm -f /config/.cytech_pending_message
  exit 0
fi

echo -n "$REMOTE_VER" > /config/.cytech_update_pending

# Every update overwrites packages/cytech.yaml unconditionally (no merge, no
# backup) so that warning always applies. Beyond that, a manifest can list
# release-specific risks via an optional "warnings" array. Mirrors the same
# logic in first_boot.sh's check_and_apply_updates() -- this script is the
# actual "Check for Update" button path and has its own separate message
# here, not shared code, so it needs the same warnings built independently.
WARNINGS=$(echo "$MANIFEST" | jq -r '
  ["Any custom edits to packages/cytech.yaml will be overwritten."]
  + (.warnings // [])
  | map("- " + .) | join("\n")
')

MSG="**v${REMOTE_VER} available:** ${CHANGELOG}"$'\n\n**Before you update:**\n'"${WARNINGS}"$'\n\nPress **Update Now** to apply.'
# .cytech_notify_pending gets auto-cleared right after its one-time popup
# fires (see cytech_show_notification automation); .cytech_pending_message
# isn't, so the Config Files dashboard has something stable to show while
# the update is still pending. .cytech_last_result is what the dashboard
# falls back to once nothing's pending, so it's fine for it to hold this
# same text in the meantime too.
write_msg "$MSG" /config/.cytech_notify_pending /config/.cytech_pending_message /config/.cytech_last_result
