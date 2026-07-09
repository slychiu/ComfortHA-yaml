#!/bin/bash
# Grants the Cytech operator SSH key access for 1 hour. Invoked by the
# "Remote Support Access" toggle turning on (packages/cytech.yaml). Takes
# effect immediately (does not wait for a reboot/maintenance pass) by
# re-running the same authorized_keys sync ensure_ssh_admin_access() does in
# first_boot.sh -- duplicated here rather than shared, consistent with how
# this repo already duplicates that read-modify-write Supervisor API pattern
# elsewhere (ensure_reset_watcher, reset.sh).
exec >> /config/cytech_update.log 2>&1
echo "=== enable_remote_support.sh $(date) ==="

EXPIRES=$(( $(date +%s) + 3600 ))
echo "$EXPIRES" > /config/.remote_support_expires_at

PUB_KEY=$(cat /config/.ssh/id_rsa.pub 2>/dev/null)
OPERATOR_KEY=$(cat /config/operator_pubkey.txt 2>/dev/null)
if [ -z "$OPERATOR_KEY" ]; then
  echo "ERROR: /config/operator_pubkey.txt missing or empty -- cannot grant remote support access."
  exit 1
fi
AUTH_KEYS_JSON=$(jq -cn --arg a "$PUB_KEY" --arg b "$OPERATOR_KEY" '[$a, $b]')

SSH_INFO=$(curl -s -H "Authorization: Bearer $SUPERVISOR_TOKEN" http://supervisor/addons/a0d7b954_ssh/info)
echo "$SSH_INFO" | jq --argjson keys "$AUTH_KEYS_JSON" \
  '.data.options | .ssh.authorized_keys = $keys | {options: .}' \
  > /tmp/remote_support_opts.json
curl -s -X POST -H "Authorization: Bearer $SUPERVISOR_TOKEN" -H "Content-Type: application/json" \
     -d @/tmp/remote_support_opts.json http://supervisor/addons/a0d7b954_ssh/options

# The options POST above alone does NOT take effect on an already-running
# addon (confirmed live -- no config-watcher process exists in that
# container to notice the change; it only regenerates authorized_keys the
# next time the container itself restarts). Directly overwrite the live
# file instead so this takes effect within seconds, not at some future
# restart -- OpenSSH re-reads AuthorizedKeysFile per new connection, so this
# doesn't disrupt any already-open session (including this device's own
# always-on password access).
ssh -i /config/.ssh/id_rsa -o StrictHostKeyChecking=no -o ConnectTimeout=10 root@a0d7b954-ssh \
  "printf '%s\n%s\n' \"$PUB_KEY\" \"$OPERATOR_KEY\" > /etc/ssh/authorized_keys"

echo "Remote support access granted until $(date -d "@${EXPIRES}")."
