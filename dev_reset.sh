#!/bin/bash
# Dev-cycle reset � re-arms first_boot.sh WITHOUT wiping Tailscale state.
# Use this for repeated dev/test cycles instead of reset.sh.
# Preserves tailscaled.state so the cached TLS cert is reused (no Let's Encrypt rate limit hit).
trap '' HUP

# Refuse to run if a previous reset/provisioning cycle is still in progress.
# .zero_touch_completed only reappears once first_boot.sh finishes, and this
# script removes it at the start of every cycle below. There's no "in
# progress" indicator on the Reset to Default button and the full cycle
# takes ~3-4 minutes, so clicking it more than once is an easy mistake --
# without this guard, a second click's `ha core stop` would interrupt the
# first cycle's first_boot.sh mid-flight instead of being a harmless no-op.
if [ ! -f /config/.zero_touch_completed ]; then
  echo "Reset already in progress -- ignoring duplicate trigger."
  exit 0
fi

echo "Dev reset: stopping HA..."
ha core stop
sleep 10

cd /config

# Auth and user accounts
rm -f .storage/auth
rm -f .storage/auth_provider.homeassistant
rm -f .storage/onboarding
rm -f .storage/cloud
rm -f .storage/person
rm -f .storage/person.corrupt.*

# Mobile app base file
rm -f .storage/mobile_app

# Remove mobile app config entries / devices / entities without touching other integrations
CE=".storage/core.config_entries"
DR=".storage/core.device_registry"
ER=".storage/core.entity_registry"

if [ -f "$CE" ]; then
    MOBILE_IDS=$(jq -r '.data.entries[]? | select(.domain == "mobile_app") | .entry_id' "$CE")
    if [ -n "$MOBILE_IDS" ]; then
        for ID in $MOBILE_IDS; do
            [ -f "$ER" ] && jq --arg id "$ID" '.data.entities |= map(select(.config_entry_id != $id))' "$ER" > "${ER}.tmp" && mv "${ER}.tmp" "$ER"
            [ -f "$DR" ] && jq --arg id "$ID" '.data.devices |= map(select(.config_entries | index($id) | not))' "$DR" > "${DR}.tmp" && mv "${DR}.tmp" "$DR"
        done
    fi
    jq '.data.entries |= map(select(.domain != "mobile_app" and .domain != "google_translate" and .domain != "met"))' "$CE" > "${CE}.tmp" && mv "${CE}.tmp" "$CE"
fi

# Logs and database
rm -f home-assistant.log
rm -f home-assistant_v2.db

# Clear SSH addon password (defense-in-depth for handoff to a new user).
# authorized_keys is intentionally left alone -- first_boot.sh re-injects its
# own per-device key there for the DISCARD fix step regardless.
echo "Clearing SSH addon password..."
curl -s -H "Authorization: Bearer $SUPERVISOR_TOKEN" http://supervisor/addons/a0d7b954_ssh/info \
  | jq '.data.options | .ssh.password = "" | {options: .}' > /tmp/ssh_reset_opts.json
curl -s -X POST -H "Authorization: Bearer $SUPERVISOR_TOKEN" -H "Content-Type: application/json" \
     -d @/tmp/ssh_reset_opts.json http://supervisor/addons/a0d7b954_ssh/options

# Re-arm zero-touch provisioning
rm -f .zero_touch_completed
echo "Initializing Secure Link..." > device_id.txt
rm -f www/remote_access_qr.png
rm -f www/remote_access_qr_v2.png

# Clear per-user sidebar preferences
rm -f .storage/frontend.user_data_*

# Signal first_boot.sh to skip Tailscale state wipe � preserves node identity and TLS cert
touch /config/.dev_reset_mode

echo "Starting HA � first_boot.sh will run automatically..."
ha core start

echo ""
echo "Dev reset complete. Provisioning running in background (~3 min)."
echo "Watch progress: tail -f /config/deployment_debug.log"
