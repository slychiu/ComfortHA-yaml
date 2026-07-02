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

# Ensure the SSH addon's watcher loop is present. This is what makes the
# Reset to Default button work: shell_command.dev_reset just drops a trigger
# file (safe to run from Core's own container), and this loop -- running
# inside the SSH addon's own container, which survives Core stopping and has
# the `ha` CLI -- picks it up and actually runs dev_reset.sh. It's addon
# config, not a tracked file, so it can't ship via the files[] list above and
# has to be pushed here idempotently on every update instead.
WATCHER_CMD="nohup sh -c 'while true; do if [ -f /config/.reset_requested ]; then rm -f /config/.reset_requested; bash /config/dev_reset.sh >> /config/dev_reset_watcher.log 2>&1; fi; sleep 5; done' >/config/dev_reset_watcher_boot.log 2>&1 &"
SSH_INFO=$(curl -s -H "Authorization: Bearer $SUPERVISOR_TOKEN" http://supervisor/addons/a0d7b954_ssh/info)
HAS_WATCHER=$(echo "$SSH_INFO" | jq --arg cmd "$WATCHER_CMD" '.data.options.init_commands // [] | index($cmd) != null')
if [ "$HAS_WATCHER" != "true" ]; then
  echo "$SSH_INFO" | jq --arg cmd "$WATCHER_CMD" \
    '.data.options | .init_commands = ((.init_commands // []) + [$cmd]) | {options: .}' \
    > /tmp/ssh_watcher_opts.json
  curl -s -X POST -H "Authorization: Bearer $SUPERVISOR_TOKEN" -H "Content-Type: application/json" \
       -d @/tmp/ssh_watcher_opts.json http://supervisor/addons/a0d7b954_ssh/options
  echo "SSH addon watcher init_command added (takes effect next addon start)."
else
  echo "SSH addon watcher init_command already present."
fi

# Apply lovelace dashboard configs if included in this update.
# Files are deleted after applying so future updates don't re-apply stale configs.
# HA restart is required for lovelace storage changes to take effect.
LOVELACE_CHANGED=0
apply_dashboard() {
  local SRC="$1" DEST="$2"
  [ -f "/config/${SRC}" ] || return
  python3 -c "
import json, sys
with open('/config/${SRC}') as f:
    config = json.load(f)
with open('/config/.storage/${DEST}') as f:
    storage = json.load(f)
storage['data']['config'] = config
with open('/config/.storage/${DEST}', 'w') as f:
    json.dump(storage, f)
print('${DEST} updated')
" && rm -f "/config/${SRC}" && LOVELACE_CHANGED=1
}

apply_dashboard zones_dashboard.json lovelace.dashboard_zones
apply_dashboard alarm_dashboard.json lovelace.comfort_alarm
apply_dashboard system_dashboard.json lovelace.system

if [ "$LOVELACE_CHANGED" = "1" ]; then
  curl -s -X POST -H "Authorization: Bearer $SUPERVISOR_TOKEN" \
    http://supervisor/core/restart
  echo "HA restarting to apply dashboard changes..."
fi
