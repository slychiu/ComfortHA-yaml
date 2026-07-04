#!/bin/bash
# Dev-cycle reset � re-arms first_boot.sh WITHOUT wiping Tailscale state.
# Use this for repeated dev/test cycles instead of reset.sh.
# Preserves tailscaled.state so the cached TLS cert is reused (no Let's Encrypt rate limit hit).
trap '' HUP

# Refuse to run if a previous reset cycle is still active. Uses a dedicated
# flag rather than .zero_touch_completed -- that file gets touched by
# first_boot.sh's dev-reset-mode branch within ~15-30s of HA restarting (to
# stop first_boot.sh re-provisioning on the *next* boot), long before the
# full cycle actually finishes: finish_firstboot.sh restarts HA a *second*
# time ~3-4 min later to write the Tailscale URL and set up dashboards.
# A guard keyed on .zero_touch_completed never fires because it's already
# back before a second click even lands. This flag is set here and only
# cleared at the tail of finish_firstboot.sh (see first_boot.sh), i.e. once
# the whole two-restart cycle is genuinely done. Treated as stale after
# 10 minutes so a crashed cycle (e.g. Tailscale never reconnects) can't
# permanently brick the button.
if [ -n "$(find /config/.reset_cycle_active -mmin -10 2>/dev/null)" ]; then
  echo "Reset already in progress -- ignoring duplicate trigger."
  exit 0
fi
touch /config/.reset_cycle_active

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

# SSH addon password is NOT cleared here (as of 2026-07-04): it's a
# persistent, random, per-device password (see ensure_ssh_admin_access in
# first_boot.sh), not a rotating one-off, and stays valid across every
# Reset to Default cycle on this same physical unit -- that's the whole
# point of it. authorized_keys is also left alone -- first_boot.sh
# re-injects its own per-device key there for the DISCARD fix step
# regardless, and the addon no longer gets locked down at the end of a
# cycle (it stays running, boot: auto).

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
