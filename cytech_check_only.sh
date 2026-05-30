#!/bin/bash
# "Check for Update" — checks manifest and notifies; does NOT apply the update
exec >> /config/cytech_update.log 2>&1
echo "=== cytech_check_only.sh $(date) ==="
source /config/.cytech_secrets

LOCAL_VER=$(cat /config/.cytech_version 2>/dev/null || echo 0)
MANIFEST=$(curl -sf --max-time 10 "${CYTECH_MANIFEST_URL}" 2>/dev/null)

if [ -z "$MANIFEST" ]; then
  printf '%s\tCould not reach update server. Check your internet connection.' \
    "$(date +%s)" > /config/.cytech_notify_pending
  exit 1
fi

REMOTE_VER=$(echo "$MANIFEST" | jq -r '.version // 0')
CHANGELOG=$(echo "$MANIFEST" | jq -r '.changelog // "No details available"')

if [ "$REMOTE_VER" -le "$LOCAL_VER" ] 2>/dev/null; then
  MSG="System is up to date (v${LOCAL_VER})."
  printf '%s\t%s' "$(date +%s)" "$MSG" | tee /config/.cytech_notify_pending > /config/.cytech_last_result
  exit 0
fi

echo -n "$REMOTE_VER" > /config/.cytech_update_pending
MSG="**v${REMOTE_VER} available:** ${CHANGELOG}"$'\n\nPress **Update Now** to apply.'
printf '%s\t%s' "$(date +%s)" "$MSG" | tee /config/.cytech_notify_pending > /config/.cytech_last_result
