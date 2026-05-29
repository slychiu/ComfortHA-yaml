#!/bin/bash
# "Update Now" — applies pending Cytech configuration update
exec >> /config/cytech_update.log 2>&1
echo "=== cytech_update.sh $(date) ==="
source /config/.cytech_secrets

notify() {
  curl -s -X POST \
    -H "Authorization: Bearer $SUPERVISOR_TOKEN" \
    -H "Content-Type: application/json" \
    -d "{\"title\":\"${1}\",\"message\":\"${2}\",\"notification_id\":\"cytech_config_update\"}" \
    http://supervisor/core/api/services/persistent_notification/create 2>/dev/null || true
}

dismiss() {
  curl -s -X POST \
    -H "Authorization: Bearer $SUPERVISOR_TOKEN" \
    -H "Content-Type: application/json" \
    -d '{"notification_id":"cytech_config_update"}' \
    http://supervisor/core/api/services/persistent_notification/dismiss 2>/dev/null || true
}

LOCAL_VER=$(cat /config/.cytech_version 2>/dev/null || echo 0)
MANIFEST=$(curl -sf --max-time 10 "${CYTECH_MANIFEST_URL}" 2>/dev/null)

if [ -z "$MANIFEST" ]; then
  notify "Cytech configuration update" "Could not reach update server. Check your internet connection."
  exit 1
fi

REMOTE_VER=$(echo "$MANIFEST" | jq -r '.version // 0')

if [ "$REMOTE_VER" -le "$LOCAL_VER" ] 2>/dev/null; then
  notify "Cytech configuration update" "Already on the latest version (v${LOCAL_VER})."
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
    notify "Cytech configuration update" "Update failed while downloading ${FILE}. Will retry on next boot."
    exit 1
  fi
done < <(echo "$MANIFEST" | jq -r '.files[]')

echo -n "$REMOTE_VER" > /config/.cytech_version
rm -f /config/.cytech_update_pending
dismiss
notify "Cytech configuration update" "Updated to v${REMOTE_VER}: ${CHANGELOG}"
