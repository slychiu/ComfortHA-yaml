#!/bin/bash
#25/5/26
exec > /config/deployment_debug.log 2>&1

# Source device-specific secrets before set -x to keep credentials out of debug log
{ set +x; } 2>/dev/null
if [ -f /config/.cytech_secrets ]; then
  source /config/.cytech_secrets
else
  echo "ERROR: /config/.cytech_secrets not found. Cannot provision."
  exit 1
fi

set -x
echo "Starting Zero-Touch Deployment..."

apply_discard_fix() {
  printf 'ACTION=="add", KERNEL=="mmcblk0", SUBSYSTEM=="block", ATTR{queue/discard_max_bytes}="0"\n' \
    > /config/.discard_rule.tmp
  ssh -i /config/.ssh/id_rsa -o StrictHostKeyChecking=no -o ConnectTimeout=10 root@a0d7b954-ssh \
    "docker run --rm \
      -v /mnt/overlay:/host_overlay \
      -v /mnt/data/supervisor/homeassistant:/ha_config:ro \
      busybox sh -c 'mkdir -p /host_overlay/etc/udev/rules.d && cp /ha_config/.discard_rule.tmp /host_overlay/etc/udev/rules.d/99-mmc-nodiscard.rules'" 2>/dev/null
  rm -f /config/.discard_rule.tmp
  echo "DISCARD fix written to host overlay (active on next reboot)."
}

# Generates a fresh non-ephemeral reusable auth key via OAuth.
# Suppresses credentials from deployment_debug.log.
get_auth_key() {
  local TOKEN AUTH_KEY
  TOKEN=$(curl -s -X POST https://api.tailscale.com/api/v2/oauth/token \
    -d "client_id=${TAILSCALE_CLIENT_ID}" \
    -d "client_secret=${TAILSCALE_CLIENT_SECRET}" \
    | jq -r '.access_token')
  AUTH_KEY=$(curl -s -X POST "https://api.tailscale.com/api/v2/tailnet/-/keys" \
    -H "Authorization: Bearer $TOKEN" \
    -H "Content-Type: application/json" \
    -d '{"capabilities":{"devices":{"create":{"reusable":true,"ephemeral":false,"preauthorized":true,"tags":["tag:customer"]}}},"expirySeconds":3600}' \
    | jq -r '.key')
  echo "$AUTH_KEY"
}

# Writes and launches maintenance_repair.sh in the SSH addon.
# $1 = full Tailscale DNSName (e.g. office.tailad4a00.ts.net or office.tail123456.ts.net)
# Extracts hostname from it for device_id.txt and mDNS; uses full domain for external_url.
launch_maintenance_repair() {
  local NEW_FULL_DNS="$1"
  local NEW_ID
  NEW_ID=$(echo "$NEW_FULL_DNS" | cut -d. -f1)
  echo -n "$NEW_ID" > /config/device_id.txt
  # Regenerate QR using full Funnel URL
  mkdir -p /config/www
  curl -s "https://api.qrserver.com/v1/create-qr-code/?size=250x250&data=https://${NEW_FULL_DNS}&margin=10" \
       -o /config/www/remote_access_qr.png
  cat > /config/maintenance_repair.sh << 'REPAIR_EOF'
#!/bin/bash
exec >> /config/maintenance_repair.log 2>&1
echo "=== maintenance_repair $(date) ==="
set -x
DEVICE_ID=$(cat /config/device_id.txt)
# Read full Tailscale DNSName live — works regardless of which tailnet is in use
FULL_DNS=$(docker exec addon_a0d7b954_tailscale /opt/tailscale status --json 2>/dev/null \
  | jq -r '.Self.DNSName // empty' | sed 's/\.$//')
[ -z "$FULL_DNS" ] && FULL_DNS="${DEVICE_ID}.tailad4a00.ts.net"
ha core stop
sleep 20
jq --arg ext "https://${FULL_DNS}" \
   --arg int "http://${DEVICE_ID}.local:8123" \
   '.data.external_url = $ext | .data.internal_url = $int' \
    /config/.storage/core.config > /config/.storage/core.config.tmp \
    && mv /config/.storage/core.config.tmp /config/.storage/core.config \
    && echo "URLs updated: ext=https://${FULL_DNS} int=http://${DEVICE_ID}.local:8123"
ha core start
sleep 30
curl -s -X POST -H "Authorization: Bearer $SUPERVISOR_TOKEN" \
    http://supervisor/addons/a0d7b954_ssh/stop
echo "=== maintenance_repair done $(date) ==="
REPAIR_EOF
  chmod +x /config/maintenance_repair.sh
  ssh -i /config/.ssh/id_rsa -o StrictHostKeyChecking=no root@a0d7b954-ssh \
    "nohup bash /config/maintenance_repair.sh </dev/null &"
  echo "Repair script launched in SSH addon."
}

# Checks for available updates and notifies HA — does NOT auto-apply.
# User must press "Update Now" or "Skip" on the dashboard.
# Silently skips if offline or CYTECH_MANIFEST_URL is unset.
check_and_apply_updates() {
  [ -z "${CYTECH_MANIFEST_URL}" ] && return 0

  local LOCAL_VER MANIFEST REMOTE_VER CHANGELOG
  LOCAL_VER=$(cat /config/.cytech_version 2>/dev/null || echo 0)

  MANIFEST=$(curl -sf --max-time 10 "${CYTECH_MANIFEST_URL}" 2>/dev/null)
  if [ -z "$MANIFEST" ]; then
    echo "Update check: manifest unreachable (offline?). Skipping."
    return 0
  fi

  REMOTE_VER=$(echo "$MANIFEST" | jq -r '.version // 0')
  echo "Update check: local=v${LOCAL_VER} remote=v${REMOTE_VER}"

  if [ "$REMOTE_VER" -le "$LOCAL_VER" ] 2>/dev/null; then
    echo "Up to date (v${LOCAL_VER})."
    return 0
  fi

  CHANGELOG=$(echo "$MANIFEST" | jq -r '.changelog // "No details available"')
  echo -n "$REMOTE_VER" > /config/.cytech_update_pending
  echo "Update v${REMOTE_VER} pending user action."

  # Write notification content to file — automation in packages/cytech.yaml picks it up.
  # Timestamp prefix ensures sensor state changes every write even if message is identical.
  printf '%s\t**v%s available:** %s\n\nOpen the **System** dashboard to update or skip.' \
    "$(date +%s)" "$REMOTE_VER" "$CHANGELOG" > /config/.cytech_notify_pending

  ensure_packages_configured
}

# Idempotently adds homeassistant packages include to configuration.yaml.
# Restarts HA if the line was just added so the new config is loaded.
ensure_packages_configured() {
  mkdir -p /config/packages
  if ! grep -q "^homeassistant:" /config/configuration.yaml 2>/dev/null; then
    printf '\nhomeassistant:\n  packages: !include_dir_named packages\n' >> /config/configuration.yaml
    echo "Packages line added to configuration.yaml — restarting HA to load."
    ha core restart || true
  fi
}

# 1. Maintenance mode — already provisioned, just run health checks
if [ -f /config/.zero_touch_completed ]; then
  echo "Already initialized. Running maintenance checks..."
  if [ -f /config/.ssh/id_rsa ]; then
    curl -s -X POST -H "Authorization: Bearer $SUPERVISOR_TOKEN" http://supervisor/addons/a0d7b954_ssh/start 2>/dev/null
    sleep 20
    apply_discard_fix
    check_and_apply_updates

    TS_STATE=$(ssh -i /config/.ssh/id_rsa -o StrictHostKeyChecking=no -o ConnectTimeout=10 root@a0d7b954-ssh \
      "docker exec addon_a0d7b954_tailscale /opt/tailscale status --json 2>/dev/null" \
      2>/dev/null | jq -r '.BackendState // empty' 2>/dev/null)

    if [ "$TS_STATE" = "NeedsLogin" ]; then
      echo "Tailscale NeedsLogin — state was wiped (SD card issue?). Re-authenticating..."
      { set +x; } 2>/dev/null
      AUTH_KEY=$(get_auth_key)
      ssh -i /config/.ssh/id_rsa -o StrictHostKeyChecking=no -o ConnectTimeout=10 root@a0d7b954-ssh \
        "docker exec addon_a0d7b954_tailscale /opt/tailscale up \
          --authkey='${AUTH_KEY}' \
          --accept-routes=true --hostname=cytech" 2>/dev/null
      set -x
      echo "Tailscale re-auth sent. Waiting 90s for Funnel and hostname to stabilise..."
      sleep 90
      NEW_FULL_DNS=$(ssh -i /config/.ssh/id_rsa -o StrictHostKeyChecking=no -o ConnectTimeout=10 root@a0d7b954-ssh \
        "docker exec addon_a0d7b954_tailscale /opt/tailscale status --json 2>/dev/null" \
        2>/dev/null | jq -r '.Self.DNSName // empty' | sed 's/\.$//')
      NEW_HOSTNAME=$(echo "$NEW_FULL_DNS" | cut -d. -f1)
      echo "Tailscale assigned: ${NEW_FULL_DNS}"
      STORED_ID=$(cat /config/device_id.txt 2>/dev/null)
      if [ -n "$NEW_HOSTNAME" ] && [ "$NEW_HOSTNAME" != "$STORED_ID" ]; then
        echo "Hostname mismatch after re-auth: stored=${STORED_ID} actual=${NEW_HOSTNAME}. Repairing..."
        launch_maintenance_repair "$NEW_FULL_DNS"
        exit 0
      else
        echo "Hostname OK: ${NEW_HOSTNAME}"
      fi

    elif [ "$TS_STATE" = "Running" ]; then
      STORED_ID=$(cat /config/device_id.txt 2>/dev/null)

      # Compare full Tailscale DNSName against stored external_url.
      # Catches hostname changes AND tailnet domain changes (e.g. user switches to personal Tailscale).
      CURRENT_FULL_DNS=$(ssh -i /config/.ssh/id_rsa -o StrictHostKeyChecking=no -o ConnectTimeout=10 root@a0d7b954-ssh \
        "docker exec addon_a0d7b954_tailscale /opt/tailscale status --json 2>/dev/null" \
        2>/dev/null | jq -r '.Self.DNSName // empty' | sed 's/\.$//')
      STORED_EXTERNAL=$(python3 -c \
        "import json; d=json.load(open('/config/.storage/core.config')); \
         print(d['data'].get('external_url','').replace('https://',''))" 2>/dev/null)
      echo "Tailscale DNSName: ${CURRENT_FULL_DNS}, stored external_url: ${STORED_EXTERNAL}"

      if [ -n "$CURRENT_FULL_DNS" ] && [ "$CURRENT_FULL_DNS" != "$STORED_EXTERNAL" ]; then
        echo "URL mismatch: stored=${STORED_EXTERNAL} actual=${CURRENT_FULL_DNS}. Accepting and repairing..."
        launch_maintenance_repair "$CURRENT_FULL_DNS"
        exit 0
      else
        echo "URL OK: ${CURRENT_FULL_DNS}"
      fi

    else
      echo "Tailscale state: ${TS_STATE} (no action needed)"
    fi

    curl -s -X POST -H "Authorization: Bearer $SUPERVISOR_TOKEN" http://supervisor/addons/a0d7b954_ssh/stop 2>/dev/null
  fi
  exit 0
fi

# 2. Smartly grab the MAC address from the physical port
if [ -f /sys/class/net/end0/address ]; then
  MAC_RAW=$(cat /sys/class/net/end0/address)
elif [ -f /sys/class/net/eth0/address ]; then
  MAC_RAW=$(cat /sys/class/net/eth0/address)
else
  MAC_RAW=$(ip link show | grep ether | awk '{print $2}' | head -n 1)
fi

# 6. Generate a brand new, unique SSH key
mkdir -p /config/.ssh
ssh-keygen -t rsa -b 4096 -f /config/.ssh/id_rsa -N "" -q
chmod 600 /config/.ssh/id_rsa

# 7. Inject the RAW public key directly into the Add-on's YAML config via API
PUB_KEY=$(cat /config/.ssh/id_rsa.pub)
curl -s -H "Authorization: Bearer $SUPERVISOR_TOKEN" http://supervisor/addons/a0d7b954_ssh/info \
  | jq --arg key "$PUB_KEY" '.data.options | .ssh.authorized_keys = [$key] | {options: .}' > /tmp/ssh_options.json

curl -s -X POST -H "Authorization: Bearer $SUPERVISOR_TOKEN" -H "Content-Type: application/json" -d @/tmp/ssh_options.json http://supervisor/addons/a0d7b954_ssh/options

# Force the SSH add-on to restart to read the injected key
curl -s -X POST -H "Authorization: Bearer $SUPERVISOR_TOKEN" http://supervisor/addons/a0d7b954_ssh/restart

# Wait 30 seconds for the add-on to fully reboot
sleep 30

# Apply DISCARD fix now that SSH addon is running
apply_discard_fix

# 8. Tailscale — dev mode reuses existing state; production wipes and re-registers
if [ -f /config/.dev_reset_mode ]; then
  rm -f /config/.dev_reset_mode
  echo "Dev reset mode: reusing existing Tailscale identity (TLS cert preserved)."
  # Ensure addon is running (dev_reset.sh does not stop it)
  curl -s -X POST -H "Authorization: Bearer $SUPERVISOR_TOKEN" http://supervisor/addons/a0d7b954_tailscale/start 2>/dev/null || true
  sleep 15
  ACTUAL_FULL_DNS=$(ssh -i /config/.ssh/id_rsa -o StrictHostKeyChecking=no root@a0d7b954-ssh \
    "docker exec addon_a0d7b954_tailscale /opt/tailscale status --json" \
    | jq -r '.Self.DNSName // empty' | sed 's/\.$//')
  ACTUAL_HOSTNAME=$(echo "$ACTUAL_FULL_DNS" | cut -d. -f1)
else
  # Production path: wipe state so each cloned SD card gets a unique node identity.
  echo "Clearing Tailscale state for fresh node identity..."
  curl -s -X POST -H "Authorization: Bearer $SUPERVISOR_TOKEN" http://supervisor/addons/a0d7b954_tailscale/stop
  sleep 8
  ssh -i /config/.ssh/id_rsa -o StrictHostKeyChecking=no root@a0d7b954-ssh \
    "docker run --rm -v /mnt/data/supervisor/addons/data/a0d7b954_tailscale:/tsdata busybox sh -c 'rm -f /tsdata/tailscaled.state && rm -rf /tsdata/state && echo cleared'"
  curl -s -X POST -H "Authorization: Bearer $SUPERVISOR_TOKEN" http://supervisor/addons/a0d7b954_tailscale/start
  sleep 20

  echo "Authenticating Tailscale with fresh identity..."
  { set +x; } 2>/dev/null
  AUTH_KEY=$(get_auth_key)
  ssh -i /config/.ssh/id_rsa -o StrictHostKeyChecking=no root@a0d7b954-ssh \
    "docker exec addon_a0d7b954_tailscale /opt/tailscale up --authkey='${AUTH_KEY}' --accept-routes=true --hostname=cytech"
  set -x

  # Wait for share-homeassistant s6 service to re-establish Funnel (~90s)
  sleep 90
  ACTUAL_FULL_DNS=$(ssh -i /config/.ssh/id_rsa -o StrictHostKeyChecking=no root@a0d7b954-ssh \
    "docker exec addon_a0d7b954_tailscale /opt/tailscale status --json" \
    | jq -r '.Self.DNSName // empty' | sed 's/\.$//')
  ACTUAL_HOSTNAME=$(echo "$ACTUAL_FULL_DNS" | cut -d. -f1)
fi

# 9. THE SAFETY CHECK: Did Tailscale connect and assign a hostname?
if [ -n "$ACTUAL_HOSTNAME" ]; then
    echo "SUCCESS: Tailscale connected as ${ACTUAL_FULL_DNS}."
    echo "$ACTUAL_HOSTNAME" > /config/device_id.txt
    DEVICE_ID="$ACTUAL_HOSTNAME"

    # Mark complete NOW so the homeassistant_start automation doesn't re-trigger
    # this script when HA restarts in the finish step below.
    touch /config/.zero_touch_completed

    # Generate QR code using full Funnel URL
    mkdir -p /config/www
    curl -s "https://api.qrserver.com/v1/create-qr-code/?size=250x250&data=https://${ACTUAL_FULL_DNS}&margin=10" \
         -o /config/www/remote_access_qr.png

    cat > /config/finish_firstboot.sh << 'FINISH_EOF'
#!/bin/bash
exec >> /config/finish_debug.log 2>&1
echo "=== finish_firstboot starting $(date) ==="
set -x
sleep 5
DEVICE_ID=$(cat /config/device_id.txt)
# Read full Tailscale DNSName live — correct regardless of which tailnet is in use
FULL_DNS=$(docker exec addon_a0d7b954_tailscale /opt/tailscale status --json 2>/dev/null \
  | jq -r '.Self.DNSName // empty' | sed 's/\.$//')
[ -z "$FULL_DNS" ] && FULL_DNS="${DEVICE_ID}.tailad4a00.ts.net"
# Stop HA so its shutdown-save can't overwrite the URL edits below
ha core stop
sleep 20
# Write external + internal URLs while HA is stopped
if [ -f /config/.storage/core.config ]; then
  jq --arg ext "https://${FULL_DNS}" \
     --arg int "http://${DEVICE_ID}.local:8123" \
    '.data.external_url = $ext | .data.internal_url = $int' \
    /config/.storage/core.config > /config/.storage/core.config.tmp \
    && mv /config/.storage/core.config.tmp /config/.storage/core.config \
    && echo "URLs written OK: ext=https://${FULL_DNS} int=http://${DEVICE_ID}.local:8123"
fi
# Add Cytech packages include to configuration.yaml (idempotent)
if ! grep -q "^homeassistant:" /config/configuration.yaml 2>/dev/null; then
  printf '\nhomeassistant:\n  packages: !include_dir_named packages\n' >> /config/configuration.yaml
  echo "Packages line added to configuration.yaml"
fi
mkdir -p /config/packages

# Create System dashboard (idempotent)
python3 - << 'PYEOF'
import json, os

# 1. Add System dashboard to the dashboards list
lf = '/config/.storage/lovelace_dashboards'
if os.path.exists(lf):
    ld = json.load(open(lf))
    items = ld['data']['items']
    if not any(i['id'] == 'system' for i in items):
        items.append({
            "id": "system", "show_in_sidebar": True,
            "icon": "mdi:cog", "title": "Config Files",
            "require_admin": False, "mode": "storage", "url_path": "system"
        })
        json.dump(ld, open(lf, 'w'))
        print("System dashboard added to sidebar")

# 2. Create the System dashboard config
sf = '/config/.storage/lovelace.system'
if not os.path.exists(sf):
    system_dash = {
        "version": 1, "minor_version": 1, "key": "lovelace.system",
        "data": {"config": {"views": [{"type": "sections", "title": "Config Files", "sections": [{
            "type": "grid",
            "cards": [
                {"type": "sensor", "entity": "sensor.cytech_version", "name": "System Version", "graph": "none"},
                {"type": "button", "name": "Check for Update", "icon": "mdi:cloud-search",
                 "tap_action": {"action": "call-service", "service": "shell_command.cytech_check_only"}},
                {"type": "conditional",
                 "conditions": [{"condition": "state", "entity": "sensor.cytech_notify_pending", "state_not": ""}],
                 "card": {"type": "button", "name": "Update Now", "icon": "mdi:update",
                          "tap_action": {"action": "call-service", "service": "shell_command.cytech_check_update"}}},
                {"type": "conditional",
                 "conditions": [{"condition": "state", "entity": "sensor.cytech_notify_pending", "state_not": ""}],
                 "card": {"type": "button", "name": "Skip this version", "icon": "mdi:update-lock",
                          "tap_action": {"action": "call-service", "service": "shell_command.cytech_reject_update"}}},
            ]
        }]}]}}
    }
    json.dump(system_dash, open(sf, 'w'))
    print("System dashboard created")
PYEOF

# Start HA — reads the updated core.config
ha core start
sleep 30
# Stop SSH addon (lockdown complete)
curl -s -X POST -H "Authorization: Bearer $SUPERVISOR_TOKEN" http://supervisor/addons/a0d7b954_ssh/stop
echo "=== finish_firstboot complete $(date) ==="
FINISH_EOF
    chmod +x /config/finish_firstboot.sh

    # Disable SSH addon auto-start before launching the finish script
    curl -s -X POST -H "Authorization: Bearer $SUPERVISOR_TOKEN" \
      -H "Content-Type: application/json" -d '{"boot": "manual"}' \
      http://supervisor/addons/a0d7b954_ssh/options

    # Launch finish script from WITHIN the SSH addon (separate container — not killed
    # when HA core stops) and return immediately.
    ssh -i /config/.ssh/id_rsa -o StrictHostKeyChecking=no root@a0d7b954-ssh \
      "nohup bash /config/finish_firstboot.sh </dev/null >> /config/finish_debug.log 2>&1 &"

    echo "Finish script launched in SSH addon. Deployment complete."
else
    echo "ERROR: Tailscale failed to connect! Leaving SSH open for debugging."
fi
