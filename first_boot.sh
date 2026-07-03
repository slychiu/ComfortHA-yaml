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
   '.data.external_url = $ext | .data.internal_url = "http://cytech.local:8123"' \
    /config/.storage/core.config > /config/.storage/core.config.tmp \
    && mv /config/.storage/core.config.tmp /config/.storage/core.config \
    && echo "URLs updated: ext=https://${FULL_DNS} int=http://cytech.local:8123"
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

  local LOCAL_VER MANIFEST REMOTE_VER CHANGELOG WARNINGS MSG
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

  # Every update overwrites packages/cytech.yaml unconditionally (no merge,
  # no backup) so that warning always applies. Beyond that, a manifest can
  # list release-specific risks (e.g. "resets the Comfort Entities dashboard
  # to its default layout") via an optional "warnings" array -- surfaced here
  # so the user sees them before pressing Update Now, not after.
  WARNINGS=$(echo "$MANIFEST" | jq -r '
    ["Any custom edits to packages/cytech.yaml will be overwritten."]
    + (.warnings // [])
    | map("- " + .) | join("\n")
  ')

  echo -n "$REMOTE_VER" > /config/.cytech_update_pending
  echo "Update v${REMOTE_VER} pending user action."

  # .cytech_notify_pending drives the one-time popup (an automation in
  # packages/cytech.yaml clears it right after showing that). Also write the
  # same content to .cytech_pending_message, which is NOT auto-cleared, so
  # the Config Files dashboard has something stable to render next to the
  # Update Now button for as long as the update is actually pending.
  #
  # Written as {"ts": ..., "message": ...} JSON, not raw text: sensor STATE
  # values are capped at 255 characters in HA and silently become "unknown"
  # past that, but the "message" attribute (read via json_attributes) has no
  # such limit. jq builds it so the message text -- which can contain quotes,
  # newlines, whatever a manifest author writes -- gets escaped correctly.
  MSG=$(printf '**v%s available:** %s\n\n**Before you update:**\n%s' "$REMOTE_VER" "$CHANGELOG" "$WARNINGS")
  jq -n --arg ts "$(date +%s)" --arg msg "$MSG" '{ts: $ts, message: $msg}' > /config/.cytech_notify_pending
  jq -n --arg ts "$(date +%s)" --arg msg "$MSG" '{ts: $ts, message: $msg}' > /config/.cytech_pending_message

  ensure_packages_configured
}

# Idempotently adds homeassistant packages include to configuration.yaml.
# Restarts HA if the line was just added so the new config is loaded.
# Uses the raw Supervisor API rather than the `ha` CLI: this function runs via
# shell_command, i.e. inside Core's own container, which doesn't have `ha`
# installed -- only curl and $SUPERVISOR_TOKEN, same as everywhere else here.
ensure_packages_configured() {
  mkdir -p /config/packages
  if ! grep -q "^homeassistant:" /config/configuration.yaml 2>/dev/null; then
    printf '\nhomeassistant:\n  packages: !include_dir_named packages\n' >> /config/configuration.yaml
    echo "Packages line added to configuration.yaml — restarting HA to load."
    curl -s -X POST -H "Authorization: Bearer $SUPERVISOR_TOKEN" http://supervisor/core/restart || true
  fi
}

# Idempotently ensures the SSH addon's watcher loop is present. This is what
# makes the Reset to Default button work: shell_command.dev_reset just drops
# a trigger file (safe to run from Core's own container), and this loop --
# running inside the SSH addon's own container, which survives Core stopping
# and has the `ha` CLI -- picks it up and actually runs dev_reset.sh.
#
# It's addon config, not a tracked file, so it can't ship via manifest.json's
# files[] list, and it deliberately does NOT live in cytech_update.sh either:
# a device that jumps straight from, say, v3 to v5 applies that jump using
# its OLD, already-installed cytech_update.sh, which wouldn't have this step
# yet -- the new code would just sit unused on disk until some later update.
# Living here instead means it runs using whatever first_boot.sh was just
# freshly downloaded, on the very next boot after any update touches it
# (every update does), regardless of how many versions were skipped.
ensure_reset_watcher() {
  local WATCHER_CMD SSH_INFO ALREADY_CURRENT
  # The watcher only runs while the SSH addon container is up (it's launched
  # via that addon's init_commands). If a Reset to Default click queues
  # .reset_requested right as the addon is stopping (e.g. finish_firstboot.sh's
  # own lockdown step at the end of a cycle), that trigger sits unconsumed
  # until the addon is next started -- at which point a naive watcher fires
  # it immediately, even though it no longer represents a fresh click. Caught
  # live 2026-07-03: restarting the SSH addon after an unrelated completed
  # cycle re-triggered an entire new reset. Fixed by only acting on the
  # trigger if it's under a minute old (well above the 5s poll interval for
  # a genuine live click, well below how long a stale one can realistically
  # sit); anything older gets silently discarded instead of fired.
  WATCHER_CMD="nohup sh -c 'while true; do if [ -n \"\$(find /config/.reset_requested -mmin -1 2>/dev/null)\" ]; then rm -f /config/.reset_requested; bash /config/dev_reset.sh >> /config/dev_reset_watcher.log 2>&1; elif [ -f /config/.reset_requested ]; then rm -f /config/.reset_requested; fi; sleep 5; done' >/config/dev_reset_watcher_boot.log 2>&1 &"
  SSH_INFO=$(curl -s -H "Authorization: Bearer $SUPERVISOR_TOKEN" http://supervisor/addons/a0d7b954_ssh/info)
  ALREADY_CURRENT=$(echo "$SSH_INFO" | jq --arg cmd "$WATCHER_CMD" '.data.options.init_commands // [] | index($cmd) != null')
  if [ "$ALREADY_CURRENT" != "true" ]; then
    # Strip out any prior version of the watcher (matched by the stable
    # substring "reset_requested", present in every version) before adding
    # the current one -- a plain add-if-missing check would never replace
    # an outdated watcher already baked into an existing device's SSH addon
    # config, so a fix here would only ever reach brand-new devices.
    echo "$SSH_INFO" | jq --arg cmd "$WATCHER_CMD" \
      '.data.options | .init_commands = ((.init_commands // []) | map(select(contains("reset_requested") | not)) + [$cmd]) | {options: .}' \
      > /tmp/ssh_watcher_opts.json
    curl -s -X POST -H "Authorization: Bearer $SUPERVISOR_TOKEN" -H "Content-Type: application/json" \
         -d @/tmp/ssh_watcher_opts.json http://supervisor/addons/a0d7b954_ssh/options
    echo "SSH addon watcher init_command added/updated (takes effect next addon start)."
  else
    echo "SSH addon watcher init_command already up to date."
  fi
}

# Idempotently ensures the Reset to Default dashboard is registered, and
# refreshes the Config Files dashboard's markdown card if it's running an
# older template. Devices create their System dashboard once during initial
# provisioning and never touch it again (create-if-missing, not
# create-or-update), so already-deployed devices would otherwise never pick
# up template improvements like the pre-update warning list. The refresh
# path backs up the previous config first, same reasoning as apply_dashboard
# in cytech_update.sh: it's a wholesale overwrite, and anything an installer
# added on top of the managed cards would otherwise just be gone.
ensure_reset_dashboard() {
  local RESULT
  RESULT=$(python3 - << 'PYEOF'
import json, os

# 1. Register the Reset to Default dashboard if missing.
lf = '/config/.storage/lovelace_dashboards'
if os.path.exists(lf):
    ld = json.load(open(lf))
    items = ld['data']['items']
    if not any(i['id'] == 'reset_default' for i in items):
        items.append({
            "id": "reset_default", "show_in_sidebar": True,
            "icon": "mdi:restore-alert", "title": "Reset to Default",
            "require_admin": True, "mode": "storage", "url_path": "reset-default"
        })
        json.dump(ld, open(lf, 'w'))
        print("Reset to Default dashboard registered")

rf = '/config/.storage/lovelace.reset_default'
if not os.path.exists(rf):
    warning_md = (
        "# Reset to Default\n\n"
        "This resets **all users, passwords, and paired phones** (mobile app "
        "links) and restarts onboarding -- exactly like a factory-fresh setup.\n\n"
        "Your Comfort alarm configuration, automations, and remote access link "
        "are **not** affected.\n\n"
        "**This cannot be undone.** Use this to hand the system to a new user, "
        "or if account access is lost."
    )
    reset_dash = {
        "version": 1, "minor_version": 1, "key": "lovelace.reset_default",
        "data": {"config": {"views": [{"type": "sections", "sections": [{
            "type": "grid",
            "cards": [
                {"type": "markdown", "content": warning_md},
                {"type": "button", "name": "Reset to Default", "icon": "mdi:restore-alert",
                 "show_name": True, "show_icon": True,
                 "tap_action": {"action": "call-service", "service": "shell_command.dev_reset",
                                "confirmation": {"text": "This will erase all users, passwords, and paired phones, then restart onboarding. This cannot be undone. Continue?"}}}
            ]
        }]}]}}
    }
    json.dump(reset_dash, open(rf, 'w'))
    print("Reset to Default dashboard created")

# 2. Refresh the Config Files dashboard's markdown card if it's stale --
#    detect via an explicit version marker embedded as a Jinja comment
#    (invisible when rendered), not by guessing from which sensor names
#    happen to appear in the content. A previous version of this check
#    looked for the string "cytech_pending_message", but that sensor's
#    *name* appeared in both the old (broken, states()) and new (fixed,
#    state_attr()) template text, so it never actually detected staleness.
#    Bump CYTECH_DASHBOARD_TEMPLATE_VERSION whenever this template changes.
CYTECH_DASHBOARD_TEMPLATE_VERSION = "cytech_dashboard_v2"
sf = '/config/.storage/lovelace.system'
if os.path.exists(sf):
    raw = open(sf).read()
    if CYTECH_DASHBOARD_TEMPLATE_VERSION not in raw:
        backup = sf + '.pre_v5_backup'
        open(backup, 'w').write(raw)
        sd = json.loads(raw)
        try:
            cards = sd['data']['config']['views'][0]['sections'][0]['cards']
            for i, c in enumerate(cards):
                if c.get('type') == 'markdown' and ('cytech_last_result' in c.get('content', '') or 'cytech_notify_pending' in c.get('content', '') or 'cytech_pending_message' in c.get('content', '')):
                    cards[i]['content'] = (
                        "{# " + CYTECH_DASHBOARD_TEMPLATE_VERSION + " #}"
                        "{% set pending = states('sensor.cytech_update_pending') %}"
                        "{% if pending not in ['', 'unknown', 'unavailable'] %}"
                        "{{ state_attr('sensor.cytech_pending_message', 'message') | default('') }}"
                        "{% else %}"
                        "{{ state_attr('sensor.cytech_last_result', 'message') | default('') }}"
                        "{% endif %}"
                    )
                    break
            json.dump(sd, open(sf, 'w'))
            print("Config Files dashboard template refreshed (backup: " + backup + ")")
        except (KeyError, IndexError):
            print("Config Files dashboard structure unrecognized -- skipping refresh")
PYEOF
)
  echo "$RESULT"
  if echo "$RESULT" | grep -qE "registered|created|refreshed"; then
    echo "Dashboard changes applied — restarting HA to load them."
    curl -s -X POST -H "Authorization: Bearer $SUPERVISOR_TOKEN" http://supervisor/core/restart || true
  fi
}

# Idempotently ensures the remote-access QR code exists. The one-shot curl
# to api.qrserver.com during initial provisioning (step 9 below) has no
# retry -- if it fails (network hiccup, DNS not ready yet, etc.) the QR
# stays missing forever with nothing to notice or regenerate it. Observed
# this happen twice in one day (2026-07-03) for two different underlying
# causes. Self-heals here instead, same pattern as ensure_reset_watcher/
# ensure_reset_dashboard. Uses -s (exists AND non-empty) rather than -f,
# since a failed curl can leave behind a 0-byte file that -f would treat
# as "already there."
ensure_remote_qr() {
  if [ ! -s /config/www/remote_access_qr.png ]; then
    local DEV_ID
    DEV_ID=$(cat /config/device_id.txt 2>/dev/null)
    if [ -n "$DEV_ID" ] && [ "$DEV_ID" != "Initializing Secure Link..." ]; then
      mkdir -p /config/www
      curl -s "https://api.qrserver.com/v1/create-qr-code/?size=250x250&data=https://${DEV_ID}.tailad4a00.ts.net&margin=10" \
        -o /config/www/remote_access_qr.png
      echo "Remote access QR code was missing -- regenerated for ${DEV_ID}."
    fi
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
    ensure_reset_watcher
    ensure_reset_dashboard
    ensure_remote_qr

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
    "docker run --rm -v /mnt/data/supervisor/apps/data/a0d7b954_tailscale:/tsdata busybox sh -c 'rm -f /tsdata/tailscaled.state && rm -rf /tsdata/state && echo cleared'"
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
    '.data.external_url = $ext | .data.internal_url = "http://cytech.local:8123"' \
    /config/.storage/core.config > /config/.storage/core.config.tmp \
    && mv /config/.storage/core.config.tmp /config/.storage/core.config \
    && echo "URLs written OK: ext=https://${FULL_DNS} int=http://cytech.local:8123"
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
                {"type": "markdown", "content": "{# cytech_dashboard_v2 #}{% set pending = states('sensor.cytech_update_pending') %}{% if pending not in ['', 'unknown', 'unavailable'] %}{{ state_attr('sensor.cytech_pending_message', 'message') | default('') }}{% else %}{{ state_attr('sensor.cytech_last_result', 'message') | default('') }}{% endif %}"},
                {"type": "grid", "columns": 3, "square": False, "cards": [
                    {"type": "button", "name": "Check for Update", "icon": "mdi:cloud-search",
                     "tap_action": {"action": "call-service", "service": "shell_command.cytech_check_only"}},
                    {"type": "conditional",
                     "conditions": [{"condition": "state", "entity": "sensor.cytech_update_pending", "state_not": ""}],
                     "card": {"type": "button", "name": "Update Now", "icon": "mdi:update",
                              "tap_action": {"action": "call-service", "service": "shell_command.cytech_check_update"}}},
                    {"type": "conditional",
                     "conditions": [{"condition": "state", "entity": "sensor.cytech_update_pending", "state_not": ""}],
                     "card": {"type": "button", "name": "Skip this version", "icon": "mdi:update-lock",
                              "tap_action": {"action": "call-service", "service": "shell_command.cytech_reject_update"}}},
                ]},
            ]
        }]}]}}
    }
    json.dump(system_dash, open(sf, 'w'))
    print("System dashboard created")
PYEOF

# Start HA — reads the updated core.config
ha core start
sleep 30
# Clear the provisioning SSH key now that Tailscale setup and the DISCARD fix are done.
# It has no further use and is the last standing passwordless entry point into the box.
# Must happen BEFORE stopping the SSH addon below: this whole script runs
# *inside* the SSH addon's own container (see the ssh -i ... root@a0d7b954-ssh
# dispatch that launches it), so stopping that addon tears down the container
# this script is running in -- nohup only protects against a closed terminal,
# not the container itself disappearing. Anything ordered after the stop call
# was never actually guaranteed to run, and in practice often didn't: this
# used to be ordered stop-then-cleanup, which silently left old provisioning
# keys valid forever and .reset_cycle_active stuck (only ever clearing via
# its 10-minute staleness fallback, never via real completion).
curl -s -H "Authorization: Bearer $SUPERVISOR_TOKEN" http://supervisor/addons/a0d7b954_ssh/info \
  | jq '.data.options | .ssh.authorized_keys = [] | {options: .}' > /tmp/ssh_lockdown_opts.json
curl -s -X POST -H "Authorization: Bearer $SUPERVISOR_TOKEN" -H "Content-Type: application/json" \
     -d @/tmp/ssh_lockdown_opts.json http://supervisor/addons/a0d7b954_ssh/options
# The whole two-restart reset cycle is genuinely done now -- safe for
# dev_reset.sh's debounce guard to allow another run. No-op if unset
# (e.g. production reset.sh path, which never sets this flag).
rm -f /config/.reset_cycle_active
echo "=== finish_firstboot complete $(date) ==="
# Stop SSH addon (lockdown complete). Last line on purpose -- it's safe for
# this to kill the script's own container now, since everything that
# actually matters has already happened above.
curl -s -X POST -H "Authorization: Bearer $SUPERVISOR_TOKEN" http://supervisor/addons/a0d7b954_ssh/stop
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
