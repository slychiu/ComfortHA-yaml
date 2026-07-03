#!/bin/bash
# "Update Now" — applies pending Cytech configuration update
exec >> /config/cytech_update.log 2>&1
echo "=== cytech_update.sh $(date) ==="
source /config/.cytech_secrets

# Sensor STATE values are capped at 255 characters in HA and silently become
# "unknown" past that; the "message" attribute (read via json_attributes)
# has no such limit, so status text is written as JSON, not raw text.
notify() {
  local json
  json=$(jq -n --arg ts "$(date +%s)" --arg msg "$1" '{ts: $ts, message: $msg}')
  echo "$json" | tee /config/.cytech_notify_pending > /config/.cytech_last_result
}

LOCAL_VER=$(cat /config/.cytech_version 2>/dev/null || echo 0)
MANIFEST=$(curl -sf --max-time 10 "${CYTECH_MANIFEST_URL}" 2>/dev/null)

if [ -z "$MANIFEST" ]; then
  notify "Could not reach update server. Check your internet connection."
  exit 1
fi

REMOTE_VER=$(echo "$MANIFEST" | jq -r '.version // 0')

if [ "$REMOTE_VER" -le "$LOCAL_VER" ] 2>/dev/null; then
  notify "Already on the latest version (v${LOCAL_VER})."
  rm -f /config/.cytech_update_pending
  exit 0
fi

CHANGELOG=$(echo "$MANIFEST" | jq -r '.changelog // "No details available"')
echo "Applying update v${LOCAL_VER} -> v${REMOTE_VER}: ${CHANGELOG}"
BASE_URL="${CYTECH_MANIFEST_URL%/manifest.json}"

while IFS= read -r FILE; do
  case "$FILE" in
    .cytech_secrets|device_id.txt|.zero_touch_completed|configuration.yaml|secrets.yaml|"") continue ;;
    *..*) continue ;;
  esac
  mkdir -p "/config/$(dirname "${FILE}")"
  if curl -sf --max-time 30 "${BASE_URL}/${FILE}" -o "/config/${FILE}.tmp"; then
    case "$FILE" in *.sh) chmod +x "/config/${FILE}.tmp" ;; esac
    mv "/config/${FILE}.tmp" "/config/${FILE}"
    echo "$FILE updated"
  else
    rm -f "/config/${FILE}.tmp"
    notify "Update failed while downloading ${FILE}. Will retry on next boot."
    exit 1
  fi
done < <(echo "$MANIFEST" | jq -r '.files[]')

echo -n "$REMOTE_VER" > /config/.cytech_version
rm -f /config/.cytech_update_pending
rm -f /config/.cytech_pending_message
notify "Updated to v${REMOTE_VER}: ${CHANGELOG}"

# Note: the SSH addon watcher (which makes Reset to Default work) is NOT
# pushed here. It's addon config, not a tracked file, and a device that
# jumps multiple versions in one update runs this exact script to do it --
# meaning whatever's already installed, not whatever this update just wrote
# to disk. That self-referential gap is why it lives in first_boot.sh's
# maintenance-mode branch instead: it runs using the freshly-downloaded
# first_boot.sh on the next boot, regardless of which version was skipped.

# Apply lovelace dashboard configs if included in this update.
# Files are deleted after applying so future updates don't re-apply stale configs.
# HA restart is required for lovelace storage changes to take effect.
LOVELACE_CHANGED=0
apply_dashboard() {
  local SRC="$1" DEST="$2"
  [ -f "/config/${SRC}" ] || return
  # This replaces the dashboard's entire config wholesale -- any local
  # customization (rearranged cards, renamed zones, added entities) would
  # otherwise be silently lost with no way to recover it. Keep one backup of
  # whatever was there immediately before this update; not a full history,
  # but enough to undo a bad surprise without needing to reset the device.
  cp "/config/.storage/${DEST}" "/config/.storage/${DEST}.pre_update_backup" 2>/dev/null
  python3 -c "
import json, sys
with open('/config/${SRC}') as f:
    config = json.load(f)
with open('/config/.storage/${DEST}') as f:
    storage = json.load(f)
storage['data']['config'] = config
with open('/config/.storage/${DEST}', 'w') as f:
    json.dump(storage, f)
print('${DEST} updated (previous config backed up to ${DEST}.pre_update_backup)')
" && rm -f "/config/${SRC}" && LOVELACE_CHANGED=1
}

apply_dashboard zones_dashboard.json lovelace.dashboard_zones
apply_dashboard alarm_dashboard.json lovelace.comfort_alarm
apply_dashboard system_dashboard.json lovelace.system
apply_dashboard welcome_dashboard.json lovelace.dashboard_welcome

if [ "$LOVELACE_CHANGED" = "1" ]; then
  curl -s -X POST -H "Authorization: Bearer $SUPERVISOR_TOKEN" \
    http://supervisor/core/restart
  echo "HA restarting to apply dashboard changes..."
fi
