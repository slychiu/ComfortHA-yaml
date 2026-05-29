#!/bin/bash
# "Skip this version" — dismisses pending update without applying it
exec >> /config/cytech_update.log 2>&1
echo "=== cytech_reject_update.sh $(date) ==="
source /config/.cytech_secrets

PENDING_VER=$(cat /config/.cytech_update_pending 2>/dev/null)
if [ -z "$PENDING_VER" ]; then
  echo "No pending update to skip."
  exit 0
fi

# Advance local version to match remote so this version is not offered again
echo -n "$PENDING_VER" > /config/.cytech_version
rm -f /config/.cytech_update_pending
echo "Skipped update to v${PENDING_VER}."

curl -s -X POST \
  -H "Authorization: Bearer $SUPERVISOR_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"notification_id":"cytech_config_update"}' \
  http://supervisor/core/api/services/persistent_notification/dismiss 2>/dev/null || true
