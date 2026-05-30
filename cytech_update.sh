#!/bin/bash
# "Update Now" — applies pending Cytech configuration update
exec >> /config/cytech_update.log 2>&1
echo "=== cytech_update.sh $(date) ==="
source /config/.cytech_secrets

notify() {
  printf '%s\t%s' "$(date +%s)" "$1" | tee /config/.cytech_notify_pending > /config/.cytech_last_result
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
notify "Updated to v${REMOTE_VER}: ${CHANGELOG}"

# Apply lovelace dashboard config if zones_dashboard.json was part of this update.
# Delete it after applying so future updates without it don't re-apply stale config.
# HA restart is required for lovelace storage changes to take effect.
if [ -f /config/zones_dashboard.json ]; then
  python3 -c "
import json
with open('/config/zones_dashboard.json') as f:
    config = json.load(f)
with open('/config/.storage/lovelace.dashboard_zones') as f:
    storage = json.load(f)
storage['data']['config'] = config
with open('/config/.storage/lovelace.dashboard_zones', 'w') as f:
    json.dump(storage, f)
print('Lovelace dashboard updated')
"
  rm -f /config/zones_dashboard.json
  curl -s -X POST -H "Authorization: Bearer $SUPERVISOR_TOKEN" \
    http://supervisor/core/restart
  echo "HA restarting to apply dashboard changes..."
fi
