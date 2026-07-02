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

echo -n "$PENDING_VER" > /config/.cytech_version
rm -f /config/.cytech_update_pending
rm -f /config/.cytech_notify_pending
rm -f /config/.cytech_pending_message
echo "Skipped update to v${PENDING_VER}."
