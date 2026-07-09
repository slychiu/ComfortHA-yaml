#!/bin/bash
#25/5/26 v3
trap '' HUP  # survive SSH disconnect
exec > >(tee /config/reset.log) 2>&1

echo "Stopping Home Assistant to prevent memory overwrites..."
ha core stop

echo "Performing factory reset � erasing users, auth, mobile devices..."
cd /config

# 0. Bake the DISCARD-disable udev rule into the host overlay BEFORE this
# card gets imaged as the golden clone source. first_boot.sh's own
# apply_discard_fix() only takes effect starting the card's SECOND boot
# (udev rules load at boot time, so writing the rule mid-boot can't protect
# that same boot) -- but first_boot.sh does its heaviest writing (config,
# storage, addon stores) during exactly that unprotected first boot. Root
# cause of the 2026-07-06 corruption incident: a freshly cloned card got
# corrupted during that first-boot window despite the fix being "deployed".
# Writing the rule here, before capture, means every unit cloned from this
# image has it active from its literal first boot -- no gap. This runs
# directly (no nested ssh hop) because reset.sh already executes inside the
# SSH addon container, which has the docker socket needed to reach the host
# overlay (see project_sdcard_fix memory).
echo "Baking DISCARD-disable udev rule into host overlay for golden image..."
printf 'ACTION=="add", KERNEL=="mmcblk0", SUBSYSTEM=="block", ATTR{queue/discard_max_bytes}="0"\n' \
  > /tmp/99-mmc-nodiscard.rules
docker run --rm -v /mnt/overlay:/host_overlay -v /tmp:/staging busybox \
  sh -c 'mkdir -p /host_overlay/etc/udev/rules.d && cp /staging/99-mmc-nodiscard.rules /host_overlay/etc/udev/rules.d/99-mmc-nodiscard.rules'
rm -f /tmp/99-mmc-nodiscard.rules
if docker run --rm -v /mnt/overlay:/host_overlay busybox test -f /host_overlay/etc/udev/rules.d/99-mmc-nodiscard.rules; then
  echo "DISCARD rule confirmed present in host overlay -- safe to capture this image."
else
  echo "ERROR: DISCARD rule NOT found in host overlay after write -- DO NOT capture this image until this is fixed."
fi

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

# Clear SSH addon password/keys AND the persistent per-device admin password
# file (see ensure_ssh_admin_access in first_boot.sh) -- this is golden-image
# prep for cloning, not the customer-facing Reset to Default button, so the
# master image should ship fully blank. Each unit cloned from it mints its
# own fresh persistent password on its own first real boot; without removing
# this file too, every clone would otherwise inherit the master's password.
rm -f /config/.ssh_admin_password
# Also clear any live Remote Support Access window (see enable_remote_support.sh)
# -- a golden-image master with an active/stale window would otherwise hand
# every clone a pre-authorized operator key until whatever expiry timestamp
# happened to be on the master at capture time.
rm -f /config/.remote_support_expires_at
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
docker run --rm -v /mnt/data/supervisor/apps/data/a0d7b954_tailscale:/tsdata \
  busybox sh -c "rm -f /tsdata/tailscaled.state && rm -rf /tsdata/state && echo 'Tailscale state cleared'"

echo "Reset complete. HA is stopped � safe to power off and clone SD card."
echo "On next boot, first_boot.sh will run automatically."
date > /config/reset_complete.txt