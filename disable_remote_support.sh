#!/bin/bash
# Revokes the Cytech operator SSH key. Invoked either by the customer
# manually flipping the "Remote Support Access" toggle off, or by the
# 1-hour timer forcing that toggle off (packages/cytech.yaml) -- one
# authoritative disable path for both cases. Takes effect immediately,
# same pattern as enable_remote_support.sh.
exec >> /config/cytech_update.log 2>&1
echo "=== disable_remote_support.sh $(date) ==="

rm -f /config/.remote_support_expires_at

PUB_KEY=$(cat /config/.ssh/id_rsa.pub 2>/dev/null)
AUTH_KEYS_JSON=$(jq -cn --arg a "$PUB_KEY" '[$a]')

SSH_INFO=$(curl -s -H "Authorization: Bearer $SUPERVISOR_TOKEN" http://supervisor/addons/a0d7b954_ssh/info)
echo "$SSH_INFO" | jq --argjson keys "$AUTH_KEYS_JSON" \
  '.data.options | .ssh.authorized_keys = $keys | {options: .}' \
  > /tmp/remote_support_opts.json
curl -s -X POST -H "Authorization: Bearer $SUPERVISOR_TOKEN" -H "Content-Type: application/json" \
     -d @/tmp/remote_support_opts.json http://supervisor/addons/a0d7b954_ssh/options

# See enable_remote_support.sh -- the options POST alone doesn't take effect
# on an already-running addon, so directly overwrite the live file too.
ssh -i /config/.ssh/id_rsa -o StrictHostKeyChecking=no -o ConnectTimeout=10 root@a0d7b954-ssh \
  "printf '%s\n' \"$PUB_KEY\" > /etc/ssh/authorized_keys"

echo "Remote support access revoked."
