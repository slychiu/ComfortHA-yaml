#!/bin/bash
#25/5/26 v3
trap '' HUP  # survive SSH disconnect

echo "Stopping Home Assistant to prevent memory overwrites..."
ha core stop

echo "Performing factory reset � erasing users, auth, mobile devices..."
cd /config

# 1. Auth and user accounts
rm -f .storage/auth
rm -f .storage/auth_provider.homeassistant
rm -f .storage/onboarding
rm -f .storage/cloud
rm -f .storage/person
rm -f .storage/person.corrupt.*

# 2. Mobile app base file
rm -f .storage/mobile_app

# 3. Safely remove Mobile App devices/entities WITHOUT touching Comfort MQTT entities
CE=".storage/core.config_entries"
DR=".storage/core.device_registry"
ER=".storage/core.entity_registry"

if [ -f "$CE" ]; then
    MOBILE_IDS=$(jq -r '.data.entries[]? | select(.domain == "mobile_app") | .entry_id' "$CE")
    if [ -n "$MOBILE_IDS" ]; then
        for ID in $MOBILE_IDS; do
            if [ -f "$ER" ]; then
                jq --arg id "$ID" '.data.entities |= map(select(.config_entry_id != $id))' "$ER" > "${ER}.tmp" && mv "${ER}.tmp" "$ER"
            fi
            if [ -f "$DR" ]; then
                jq --arg id "$ID" '.data.devices |= map(select(.config_entries | index($id) | not))' "$DR" > "${DR}.tmp" && mv "${DR}.tmp" "$DR"
            fi
        done
    fi
    jq '.data.entries |= map(select(.domain != "mobile_app" and .domain != "google_translate" and .domain != "met"))' "$CE" > "${CE}.tmp" && mv "${CE}.tmp" "$CE"
fi

# 4. Logs and old database
rm -f home-assistant.log
rm -f home-assistant_v2.db

# 5. Clear SSH terminal history
history -c
rm -f ~/.bash_history

# 6. Re-arm the Zero-Touch deployment script
echo "Resetting Zero-Touch deployment triggers..."
rm -f /config/.zero_touch_completed
rm -f /config/.cytech_version
rm -f /config/.cytech_update_pending
rm -f /config/.cytech_notify_pending
rm -f /config/.cytech_last_result
echo "Initializing Secure Link..." > /config/device_id.txt
rm -f /config/authorized_keys
rm -rf /config/.ssh
rm -f /config/www/remote_access_qr.png
rm -f /config/www/remote_access_qr_v2.png

# Clear SSH addon password and keys so addon cannot start even if manually enabled
curl -s -H "Authorization: Bearer $SUPERVISOR_TOKEN" http://supervisor/addons/a0d7b954_ssh/info \
  | jq '.data.options | .ssh.password = "" | .ssh.authorized_keys = [] | {options: .}' > /tmp/ssh_reset_opts.json
curl -s -X POST -H "Authorization: Bearer $SUPERVISOR_TOKEN" -H "Content-Type: application/json" \
     -d @/tmp/ssh_reset_opts.json http://supervisor/addons/a0d7b954_ssh/options

# Clear per-user sidebar preferences so new users inherit the default lovelace_dashboards order
rm -f /config/.storage/frontend.user_data_*

# 7. Clear Tailscale state so every cloned SD card registers as a unique device
# Must STOP the addon first � daemon writes state back to disk on graceful shutdown if running
echo "Clearing Tailscale state for fresh node identity..."
curl -s -X POST -H "Authorization: Bearer $SUPERVISOR_TOKEN" http://supervisor/addons/a0d7b954_tailscale/stop
sleep 8
docker run --rm -v /mnt/data/supervisor/addons/data/a0d7b954_tailscale:/tsdata \
  busybox sh -c "rm -f /tsdata/tailscaled.state && rm -rf /tsdata/state && echo 'Tailscale state cleared'"

echo "Reset complete. HA is stopped � safe to power off and clone SD card."
echo "On next boot, first_boot.sh will run automatically."
date > /config/reset_complete.txt