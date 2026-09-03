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
    "docker run --rm --entrypoint sh \
      -v /mnt/overlay:/host_overlay \
      -v /mnt/data/supervisor/homeassistant:/ha_config:ro \
      \$(docker inspect homeassistant --format '{{.Config.Image}}') \
      -c 'mkdir -p /host_overlay/etc/udev/rules.d && cp /ha_config/.discard_rule.tmp /host_overlay/etc/udev/rules.d/99-mmc-nodiscard.rules'" 2>/dev/null
  rm -f /config/.discard_rule.tmp
  echo "DISCARD fix written to host overlay (active on next reboot)."
}

# Enables USB host mode on the CM4's native USB2-OTG port. The golden image
# ships config.txt with otg_mode=1 and no dwc2 host overlay -- the port never
# powers on and no device (keyboard, UCM serial adapter, SD reader) is ever
# detected, confirmed live on two units 2026-07-09. Idempotent: skips if the
# overlay is already present.
#
# FIX 2026-07-19: originally raw-mounted /dev/mmcblk0p1 itself inside a
# privileged container on every single boot (just to run the idempotency
# check), racing the host's own already-active mount of that same device --
# root-caused via live bisection as the source of a "Can't open blockdev"
# kernel message appearing on every boot once this function shipped (v21),
# reproduced 3/3 on affected first_boot.sh versions and 0/3 without it on the
# same hardware/SD card. The host already has /dev/mmcblk0p1 mounted at
# /mnt/boot (confirmed live via /proc/mounts), so this now bind-mounts that
# existing mountpoint -- same pattern as apply_discard_fix's /mnt/overlay
# bind mount -- instead of re-mounting the raw block device. No longer needs
# --privileged or -v /dev:/dev either, since it never touches /dev directly.
# FIX 2026-08-11 (v31): runs on the Supervisor-managed core image instead of
# the alpine scratch image, so Supervisor never flags "unsupported software".
apply_usb_host_mode_fix() {
  ssh -i /config/.ssh/id_rsa -o StrictHostKeyChecking=no -o ConnectTimeout=10 root@a0d7b954-ssh \
    "docker run --rm --entrypoint sh -v /mnt/boot:/mnt/boot \
      \$(docker inspect homeassistant --format '{{.Config.Image}}') \
      -c '
      if grep -q \"^dtoverlay=dwc2,dr_mode=host\" /mnt/boot/config.txt; then
        exit 0
      fi
      cp /mnt/boot/config.txt /mnt/boot/config.txt.preusbfix.bak
      sed -i \"s/^otg_mode=1/#otg_mode=1/\" /mnt/boot/config.txt
      sed -i \"/^#otg_mode=1/a dtoverlay=dwc2,dr_mode=host\" /mnt/boot/config.txt
    '" 2>/dev/null
  echo "USB host-mode overlay ensured (active on next reboot)."
}

# v31: every host-level fix above used to run in busybox/alpine scratch images
# pulled on each boot. Home Assistant Supervisor flags any docker image outside
# the ecosystem as "Unsupported software" at every full power-on (auto-clears
# ~1h later, but the warning is visible to customers). All fixes now run on the
# Supervisor-managed core image instead; this removes the old scratch images so
# neither they nor any clone of this card can ever trigger the flag again.
remove_scratch_images() {
  ssh -i /config/.ssh/id_rsa -o StrictHostKeyChecking=no -o ConnectTimeout=10 root@a0d7b954-ssh \
    "docker image rm busybox alpine >/dev/null 2>&1 || true"
}

# Fast write/readback canary -- run ONCE, on a card's first real boot, before
# provisioning does its own heavy writing. Writes a test file to /config
# (the data partition, mmcblk0p8 -- the same partition that corrupted in both
# the Tailscale-state and 2026-07-06 configuration.yaml incidents), forcing a
# real fsync so an underlying write failure surfaces as a dd error instead of
# silently succeeding into page cache. Deliberately avoids oflag/iflag=direct:
# HA Core's container may be running busybox coreutils rather than GNU
# coreutils, and busybox dd's O_DIRECT flag support is inconsistent enough
# that relying on it risked false CANARY FAILED results on perfectly good
# cards. Net effect: this reliably catches dead/failing flash and write
# errors, but is NOT a capacity-lie detector -- a small 64MB sample can still
# land inside a counterfeit card's real (smaller) physical region even if the
# card is lying about total size. That class of defect still needs the full
# F3/h2testw pass as a separate manual pre-deployment step. Also doesn't test
# the DISCARD firmware bug itself (needs an actual discard between write and
# read, which we deliberately never issue on production units).
run_flash_canary() {
  local TESTFILE="/config/.cytech_canary_test"
  local SIZE_MB=64
  local WRITE_HASH READ_HASH

  echo "Running flash write/readback canary (${SIZE_MB}MB)..."
  if ! dd if=/dev/urandom of="$TESTFILE" bs=1M count=$SIZE_MB conv=fsync 2>/tmp/canary_write.err; then
    echo "CANARY FAILED: write itself errored -- card may be dead, full, or defective:"
    cat /tmp/canary_write.err
    rm -f "$TESTFILE" /tmp/canary_write.err
    echo "$(date): write failed" >> /config/.cytech_canary_failures
    return 1
  fi
  WRITE_HASH=$(sha256sum "$TESTFILE" | awk '{print $1}')
  sync
  READ_HASH=$(sha256sum "$TESTFILE" | awk '{print $1}')
  rm -f "$TESTFILE" /tmp/canary_write.err

  if [ -z "$WRITE_HASH" ] || [ "$WRITE_HASH" != "$READ_HASH" ]; then
    echo "CANARY FAILED: write/readback mismatch (wrote=$WRITE_HASH read=$READ_HASH). This card may be defective -- DO NOT SHIP."
    echo "$(date): hash mismatch wrote=$WRITE_HASH read=$READ_HASH" >> /config/.cytech_canary_failures
    return 1
  fi

  echo "Canary OK: ${SIZE_MB}MB write/readback verified (sha256 $WRITE_HASH)."
  return 0
}

# Ongoing integrity self-check -- runs every maintenance-pass boot. Doesn't
# care about root cause (DISCARD bug, bad NAND, power loss); it just verifies
# configuration.yaml still parses as YAML and every file HA has ever written
# under .storage/ still parses as JSON (HA always writes JSON there, whatever
# the filename). This is the same failure signature both 2026 corruption
# incidents produced -- catching it here surfaces a dying card as a
# dashboard/notification alert instead of the first sign being HA's own
# recovery mode with no usable backup.
check_config_integrity() {
  local RESULT STATUS DETAILS
  RESULT=$(python3 - << 'PYEOF'
import json, os
import yaml

problems = []

# HA's configuration.yaml legitimately uses custom tags (!include,
# !include_dir_named, !secret, etc.) that plain yaml.safe_load() doesn't
# know how to construct -- confirmed live 2026-07-07: a totally healthy
# config with `packages: !include_dir_named packages` false-positived as
# "corrupt" under the naive loader. This tolerant loader treats any `!`-tagged
# node as its underlying scalar/sequence/mapping instead of erroring, since
# this check only cares about YAML structure being well-formed (garbled
# bytes), not about actually resolving HA's include directives.
class TolerantLoader(yaml.SafeLoader):
    pass

def _construct_any_tag(loader, tag_suffix, node):
    if isinstance(node, yaml.ScalarNode):
        return loader.construct_scalar(node)
    if isinstance(node, yaml.SequenceNode):
        return loader.construct_sequence(node)
    if isinstance(node, yaml.MappingNode):
        return loader.construct_mapping(node)
    return None

TolerantLoader.add_multi_constructor('!', _construct_any_tag)

cfg = '/config/configuration.yaml'
if os.path.exists(cfg):
    try:
        with open(cfg, 'r', encoding='utf-8') as f:
            yaml.load(f, Loader=TolerantLoader)
    except Exception as e:
        problems.append(f"configuration.yaml: {type(e).__name__}: {e}")

storage_dir = '/config/.storage'
if os.path.isdir(storage_dir):
    for name in sorted(os.listdir(storage_dir)):
        # HA's own storage helper already quarantines files it finds corrupt
        # by renaming them to <name>.corrupt.<timestamp> and starting fresh --
        # confirmed live 2026-07-07: a month-old quarantined
        # http.auth.corrupt.<ts> file false-positived here as NEW corruption.
        # That's HA's self-healing already having done its job, not a live
        # problem to alert on.
        if '.corrupt.' in name:
            continue
        path = os.path.join(storage_dir, name)
        if not os.path.isfile(path):
            continue
        try:
            with open(path, 'rb') as f:
                json.load(f)
        except Exception as e:
            problems.append(f".storage/{name}: {type(e).__name__}: {e}")

if problems:
    print("CORRUPT")
    for p in problems[:10]:
        print(p)
else:
    print("OK")
PYEOF
)
  STATUS=$(echo "$RESULT" | head -1)
  if [ "$STATUS" = "CORRUPT" ]; then
    DETAILS=$(echo "$RESULT" | tail -n +2 | tr '\n' '; ')
    echo "INTEGRITY CHECK FAILED: $DETAILS"
    jq -n --arg ts "$(date +%s)" \
      --arg msg "Data integrity issue detected on this device's SD card: ${DETAILS} This may indicate SD card failure -- check the device soon." \
      '{ts: $ts, message: $msg}' > /config/.cytech_integrity_alert
  else
    echo "Integrity check OK: configuration.yaml and .storage/* all parse correctly."
    rm -f /config/.cytech_integrity_alert
  fi
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
FULL_DNS=$(docker exec app_a0d7b954_tailscale /opt/tailscale status --json 2>/dev/null \
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
# SSH addon stays up permanently (boot: auto, v16+ always-on design) --
# do NOT stop it here. A previous version of this template stopped the addon
# at the end of a repair, which killed the reset watcher and silently broke
# Reset to Default until the next reboot. Same bug class as v11/v13.
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

# Ensures the SSH addon has a persistent, per-device admin password and
# stays up (boot: auto) instead of being started/stopped around every Reset
# to Default cycle. This removes the entire *class* of bug that came from
# cycling the addon on and off: v9's QR race, v11's self-kill ordering,
# v12's stray-trigger-on-restart, v13's concurrency race with the
# maintenance branch, and v15's crash-on-blind-start were all, in one way
# or another, about the addon being off except for brief windows around a
# reset -- an addon that never turns off doesn't have those windows for a
# bug to live in.
#
# The password is random per device, generated once and stored in
# /config/.ssh_admin_password -- untouched by dev_reset.sh, so it survives
# every Reset to Default cycle on this same physical unit. NOT a fixed
# password shared across the fleet (a single leaked credential would then
# reach every device), and NOT derived from the per-device SSH key (which
# *does* get regenerated on every reset, so isn't something a person can
# reliably remember/retrieve access via). reset.sh (golden-image prep, not
# the customer-facing button) deletes this file so every unit cloned from
# a golden image mints its own fresh password on its first real boot.
ensure_ssh_admin_access() {
  local PW_FILE="/config/.ssh_admin_password"
  local PASSWORD PUB_KEY AUTH_KEYS_JSON SSH_INFO DESIRED SUPPORT_ACTIVE
  if [ ! -s "$PW_FILE" ]; then
    head -c 32 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 20 > "$PW_FILE"
    chmod 600 "$PW_FILE"
    echo "Generated persistent per-device SSH admin password."
  fi
  PASSWORD=$(cat "$PW_FILE")
  PUB_KEY=$(cat /config/.ssh/id_rsa.pub 2>/dev/null)
  # authorized_keys carries this device's own generated key (used internally
  # by first_boot.sh's nested-ssh docker/ha-cli steps) PLUS, only while a
  # customer-granted Remote Support Access window is active, a second, fixed
  # operator key (operator_pubkey.txt, shared across the whole fleet) that
  # lets the operator SSH in without needing the device's own random
  # password. /config/.remote_support_expires_at (a unix timestamp) is the
  # single source of truth for whether that window is active -- written by
  # enable_remote_support.sh, removed by disable_remote_support.sh. This
  # function runs on every HA Core start, not just full reboots, so it MUST
  # check this file rather than unconditionally granting/revoking -- otherwise
  # an unrelated Core restart mid-window would silently clobber (or resurrect)
  # the operator key regardless of the customer's toggle state.
  # Built as a JSON array via jq rather than plain --arg since
  # authorized_keys is a list, not a single value.
  SUPPORT_ACTIVE=false
  if [ -s /config/.remote_support_expires_at ] && [ "$(cat /config/.remote_support_expires_at)" -gt "$(date +%s)" ] 2>/dev/null; then
    SUPPORT_ACTIVE=true
  fi
  if [ "$SUPPORT_ACTIVE" = true ] && [ -s /config/operator_pubkey.txt ]; then
    AUTH_KEYS_JSON=$(jq -cn --arg a "$PUB_KEY" --arg b "$(cat /config/operator_pubkey.txt)" '[$a, $b]')
  else
    AUTH_KEYS_JSON=$(jq -cn --arg a "$PUB_KEY" '[$a]')
  fi
  SSH_INFO=$(curl -s -H "Authorization: Bearer $SUPERVISOR_TOKEN" http://supervisor/addons/a0d7b954_ssh/info)
  # watchdog is a TOP-LEVEL addon property, not an option -- nesting it inside
  # .data.options (a previous version of this function did) silently no-ops and
  # left watchdog:false. Send it at the top level alongside boot.
  DESIRED=$(echo "$SSH_INFO" | jq --arg pw "$PASSWORD" --argjson keys "$AUTH_KEYS_JSON" \
    '(.data.options.ssh.password == $pw) and (.data.options.ssh.authorized_keys == $keys) and (.data.watchdog == true) and (.data.boot == "auto")')
  if [ "$DESIRED" != "true" ]; then
    echo "$SSH_INFO" | jq --arg pw "$PASSWORD" --argjson keys "$AUTH_KEYS_JSON" \
      '.data.options | .ssh.password = $pw | .ssh.authorized_keys = $keys | {options: .}' \
      > /tmp/ssh_admin_opts.json
    curl -s -X POST -H "Authorization: Bearer $SUPERVISOR_TOKEN" -H "Content-Type: application/json" \
         -d @/tmp/ssh_admin_opts.json http://supervisor/addons/a0d7b954_ssh/options
    curl -s -X POST -H "Authorization: Bearer $SUPERVISOR_TOKEN" -H "Content-Type: application/json" \
         -d '{"boot": "auto", "watchdog": true}' http://supervisor/addons/a0d7b954_ssh/options
    echo "SSH addon credentials/boot config updated (persistent password, boot: auto, watchdog: on)."
  fi
  curl -s -X POST -H "Authorization: Bearer $SUPERVISOR_TOKEN" http://supervisor/addons/a0d7b954_ssh/start > /dev/null 2>&1
  # The options POST above only regenerates /etc/ssh/authorized_keys inside
  # the addon's OWN container the next time that container itself starts --
  # confirmed live that an options change does NOT propagate to an
  # already-running addon's on-disk file (no config-watcher process exists
  # in that container; it's a fixed s6 service tree). Since HA Core
  # restarting does not restart the separate SSH addon container, relying
  # only on the options POST would mean a stale Remote Support Access
  # window (operator key still authorized past its expiry) could persist
  # indefinitely on an addon that never itself restarts. So if the addon was
  # ALREADY running at entry, also directly overwrite the live file via the
  # same nested-ssh technique used elsewhere in this script -- OpenSSH
  # re-reads AuthorizedKeysFile per new connection attempt (no caching), so
  # this takes effect immediately with no restart and no disruption to any
  # already-open session. Skipped on a true cold start (addon not running
  # yet): the /start call above already makes the container's own init
  # generate this file correctly from the options just POSTed, and
  # attempting to SSH into a container that isn't up yet would just fail.
  if [ "$(echo "$SSH_INFO" | jq -r '.data.state')" = "started" ]; then
    ssh -i /config/.ssh/id_rsa -o StrictHostKeyChecking=no -o ConnectTimeout=10 root@a0d7b954-ssh \
      "echo '$AUTH_KEYS_JSON' | jq -r '.[]' > /etc/ssh/authorized_keys"
  fi
}

# Blocks until sshd inside the SSH addon actually accepts a connection, and
# force-restarts the addon if it doesn't come up on its own.
#
# Supervisor's own addon state is NOT a usable readiness signal here. reset.sh
# deliberately ships the golden image with blank ssh.password and
# ssh.authorized_keys, so on a clone's very first boot the addon can start --
# via boot:auto, long before Core and therefore this script exist to configure
# it -- against those blank credentials. Its init-ssh service refuses to come
# up ("Configuration of this app is incomplete"), exits 1, and the watchdog
# crash-loops it for ~2 minutes before giving up. Supervisor reports state
# "started" throughout that, and answers a /start with "already running!" -- a
# no-op -- so credentials POSTed by ensure_ssh_admin_access never reach any
# container and sshd stays down for the rest of the boot. The old loop here
# polled .data.state, saw "started", and broke on its first iteration; every
# nested-ssh step afterwards then failed with "Connection refused", silently,
# since none of them check exit status. That took out the entire Tailscale
# registration block, so the device never got a node identity, a QR, or remote
# access -- root-caused 2026-08-01 on a fresh SD image.
#
# Probing the real thing costs nothing on the normal path (first attempt
# succeeds) and self-heals the crash-loop case without gratuitously bouncing a
# healthy addon on every Core restart.
wait_for_ssh_addon() {
  local i=1
  while [ "$i" -le 24 ]; do
    if ssh -i /config/.ssh/id_rsa -o StrictHostKeyChecking=no -o ConnectTimeout=5 \
         -o BatchMode=yes root@a0d7b954-ssh true 2>/dev/null; then
      [ "$i" -gt 1 ] && echo "SSH addon reachable after ~$(( (i - 1) * 5 ))s."
      return 0
    fi
    # 30s in, stop waiting on a container that may be looping on stale options
    # and force Supervisor to build a new one from the options just POSTed.
    if [ "$i" -eq 6 ]; then
      echo "SSH addon still unreachable after 30s -- forcing a restart to pick up current options."
      curl -s -X POST -H "Authorization: Bearer $SUPERVISOR_TOKEN" \
           http://supervisor/addons/a0d7b954_ssh/restart > /dev/null 2>&1
    fi
    sleep 5
    i=$((i + 1))
  done
  echo "ERROR: SSH addon never became reachable -- host-level provisioning steps will fail."
  return 1
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
  # Now that the addon (see ensure_ssh_admin_access) never turns off around a
  # reset, a trigger is always picked up within one 5s poll of being
  # touched -- but the staleness guard stays as cheap insurance against any
  # other unexpected restart (host reboot, a genuine crash Supervisor's
  # watchdog restarts from).
  WATCHER_CMD="nohup sh -c 'while true; do if [ -n \"\$(find /config/.reset_requested -mmin -5 2>/dev/null)\" ]; then rm -f /config/.reset_requested; bash /config/dev_reset.sh >> /config/dev_reset_watcher.log 2>&1; elif [ -f /config/.reset_requested ]; then rm -f /config/.reset_requested; fi; sleep 5; done' >/config/dev_reset_watcher_boot.log 2>&1 &"
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
    echo "SSH addon watcher init_command added/updated."
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
  # reset_default and system (Config Files) dashboards are now YAML-mode
  # (read-only, managed as files in /config/dashboards/ + registered in
  # configuration.yaml's lovelace.dashboards dict). This function's old job
  # -- registering/creating/refreshing their STORAGE versions -- would
  # recreate them as storage dashboards on every maintenance boot and cause
  # duplicates. No-op now; the bodies below are dead but kept for reference.
  return 0
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

# v32: ships the "Register Control Example" dashboard (Comfort outputs/
# flags + counters/sensors, storage mode so users can edit it) to every
# device, healing whatever prior state exists: golden-image clones carry an
# old registry entry with no storage file, updated devices can have a
# UI-created placeholder ("sections" view with a "New section" heading,
# 585-byte file observed live on ems.local 2026-08-11) under the legacy id
# dashboard_automation, and the fixed id automation-dashboard (cytech.local)
# may still carry the old title. Replaces placeholder content (never a
# legitimately customized dashboard -- only touched when it has no
# Outputs & Flags / Counters & Sensors markers at all) and renames the
# sidebar title whichever id exists; creates the canonical automation-
# dashboard id when neither exists. Same pattern as ensure_reset_dashboard.
ensure_register_control_dashboard() {
  local RESULT
  RESULT=$(python3 - << 'PYEOF'
import json, os

LF = '/config/.storage/lovelace_dashboards'
CANONICAL = 'automation-dashboard'
LEGACY = 'dashboard_automation'
TITLE = 'Register Control Example'

VIEWS = [{
    "title": "Automation",
    "layout": {"type": "grid", "columns": 2},
    "cards": [
        {
            "type": "entities",
            "title": "Outputs & Flags",
            "show_header_toggle": False,
            "entities": [
                "switch.cytech_comfort_mqtt_output001",
                "switch.cytech_comfort_mqtt_output002",
                "switch.cytech_comfort_mqtt_output003",
                "switch.cytech_comfort_mqtt_output004",
                "switch.cytech_comfort_mqtt_output005",
                "switch.cytech_comfort_mqtt_output006",
                "switch.cytech_comfort_mqtt_output007",
                "switch.cytech_comfort_mqtt_output008",
                "switch.cytech_comfort_mqtt_flag001",
                "switch.cytech_comfort_mqtt_flag002",
                "switch.cytech_comfort_mqtt_flag003",
                "switch.cytech_comfort_mqtt_flag004",
                "switch.cytech_comfort_mqtt_flag005",
                "switch.cytech_comfort_mqtt_flag006",
                "switch.cytech_comfort_mqtt_flag007",
                "switch.cytech_comfort_mqtt_flag008"
            ]
        },
        {
            "type": "entities",
            "title": "Counters & Sensors",
            "show_header_toggle": False,
            "entities": [
                "number.cytech_comfort_mqtt_counter000",
                "number.cytech_comfort_mqtt_counter001",
                "number.cytech_comfort_mqtt_counter002",
                "number.cytech_comfort_mqtt_counter003",
                "number.cytech_comfort_mqtt_counter004",
                "number.cytech_comfort_mqtt_counter005",
                "number.cytech_comfort_mqtt_counter006",
                "number.cytech_comfort_mqtt_counter007",
                "number.cytech_comfort_mqtt_sensor000",
                "number.cytech_comfort_mqtt_sensor001",
                "number.cytech_comfort_mqtt_sensor002",
                "number.cytech_comfort_mqtt_sensor003",
                "number.cytech_comfort_mqtt_sensor004",
                "number.cytech_comfort_mqtt_sensor005",
                "number.cytech_comfort_mqtt_sensor006",
                "number.cytech_comfort_mqtt_sensor007"
            ]
        }
    ]
}]

changed = []

# 1. Registry: resolve which id is in use, rename its title, or create the
#    canonical entry when neither exists. If the registry file itself is
#    missing the device is too broken to heal from here -- HA rebuilds it.
if not os.path.exists(LF):
    print("lovelace_dashboards registry missing -- skipping")
    raise SystemExit(0)
reg = json.load(open(LF))
items = reg['data']['items']
dash_id = None
for i in items:
    if i.get('id') == CANONICAL:
        dash_id = CANONICAL
        break
    if i.get('id') == LEGACY:
        dash_id = LEGACY
if dash_id:
    for i in items:
        if i.get('id') == dash_id and i.get('title') != TITLE:
            i['title'] = TITLE
            json.dump(reg, open(LF, 'w'))
            changed.append(f"renamed {dash_id} -> {TITLE}")
            break
else:
    items.append({"id": CANONICAL, "show_in_sidebar": True,
                  "icon": "mdi:robot-industrial", "title": TITLE,
                  "require_admin": False, "mode": "storage",
                  "url_path": CANONICAL})
    dash_id = CANONICAL
    json.dump(reg, open(LF, 'w'))
    changed.append(f"registered {CANONICAL}")

# 2. Content: create the storage file when missing; replace it only when it
#    is the UI-created placeholder (no real cards at all), never a
#    customized dashboard.
sf = f'/config/.storage/lovelace.{dash_id}'
if not os.path.exists(sf):
    dash = {"version": 1, "minor_version": 1, "key": f"lovelace.{dash_id}",
            "data": {"config": {"views": VIEWS}}}
    json.dump(dash, open(sf, 'w'))
    changed.append(f"created {sf}")
else:
    raw = open(sf).read()
    if '"heading": "New section"' in raw or (
            'Outputs & Flags' not in raw and 'Counters & Sensors' not in raw):
        open(sf + '.pre_v32_backup', 'w').write(raw)
        dash = json.loads(raw)
        dash['data']['config'] = {"views": VIEWS}
        json.dump(dash, open(sf, 'w'))
        changed.append(f"replaced placeholder content of {dash_id}")

print("; ".join(changed) if changed else "Register Control dashboard already up to date")
PYEOF
)
  echo "$RESULT"
  if echo "$RESULT" | grep -qE "registered|created|replaced|renamed"; then
    echo "Register Control dashboard changes applied — restarting HA to load them."
    curl -s -X POST -H "Authorization: Bearer $SUPERVISOR_TOKEN" http://supervisor/core/restart >/dev/null || true
  fi
}

# v34: The bridge addon discovers one button.comfort_* entity per Comfort
# panel Response key. Since v33 no bundled dashboard is applied on updates
# anymore (see the v33 changelog), devices that let the addon discover the
# responses had NO user-facing way to press them until this one-time self-
# heal adds a Responses card to the Comfort Entities dashboard, using the
# native button card (no tap_action at all -- button-card v5 drops a plain
# action-level entity: on the call-service path, which is why the earlier
# custom-card variants errored out).
#
# Rules, mirroring ensure_register_control_dashboard:
#  * only ever ADD (never replace a whole card, never touch user cards);
#  * if a Responses card exists but its button include isn't the native
#    button card, convert just that include (self-heals the legacy variants);
#  * if a card exists with native buttons already, do nothing;
#  * gate on at least one button.comfort_* state existing -- on a fresh
#    install the card is added on a later boot once the addon has
#    discovered them, rather than rendering an empty card.
ensure_responses_card() {
  local RESULT
  if ! curl -sf -H "Authorization: Bearer $SUPERVISOR_TOKEN" http://supervisor/core/api/states 2>/dev/null \
      | grep -q 'button.comfort_'; then
    echo "No button.comfort_* entities yet -- Responses card deferred until the addon discovers them (runs again next boot)."
    return 0
  fi
  RESULT=$(python3 - << 'PYEOF'
import copy, json, os

sf = '/config/.storage/lovelace.dashboard_zones'
CARD = {
    "type": "custom:auto-entities",
    "card": {"type": "grid", "title": "Responses", "columns": 3, "square": False},
    "card_param": "cards",
    "sort": {"method": "name"},
    "filter": {"include": [
        {"entity_id": "button.comfort_*",
         "options": {"type": "button", "entity": "this.entity_id"}},
    ]},
}

if not os.path.exists(sf):
    print("lovelace.dashboard_zones missing -- nothing to patch")
    raise SystemExit(0)

doc = json.load(open(sf))
changed = []

def includes(c):
    return (c.get('filter', {}) or {}).get('include') or []

def is_zones(c):
    return c.get('type') == 'custom:auto-entities' and any(
        i.get('entity_id') == 'binary_sensor.comfort_*' for i in includes(c))

def is_responses(c):
    return c.get('type') == 'custom:auto-entities' and any(
        i.get('entity_id') == 'button.comfort_*' for i in includes(c))

def patch(cards):
    existing = next((c for c in cards if is_responses(c)), None)
    if existing is None:
        cards.append(copy.deepcopy(CARD))
        changed.append("appended Responses card with native buttons")
        return
    inc = includes(existing)
    if not any(i.get('entity_id') == 'button.comfort_*' for i in inc):
        inc.append(copy.deepcopy(CARD['filter']['include'][0]))
        changed.append("added button.comfort_* include to existing Responses card")
        return
    for i in inc:
        if i.get('entity_id') == 'button.comfort_*' and \
                (i.get('options') or {}).get('type') != 'button':
            i['options'] = copy.deepcopy(CARD['filter']['include'][0]['options'])
            changed.append("converted Responses button include to native button card")
            return

def walk(o):
    if isinstance(o, dict):
        cards = o.get('cards')
        if isinstance(cards, list) and any(isinstance(c, dict) and is_zones(c) for c in cards):
            patch(cards)
            return
        for v in o.values():
            walk(v)
    elif isinstance(o, list):
        for v in o:
            walk(v)

walk(doc)

if not changed:
    print("Responses card already present with native buttons -- no change")
else:
    open(sf + '.pre_v34_backup', 'w').write(open(sf).read())
    open(sf, 'w').write(json.dumps(doc))
    print("; ".join(changed) + " -- written and re-parsed OK")
PYEOF
)
  echo "$RESULT"
  if echo "$RESULT" | grep -qE "appended|added|converted"; then
    echo "Responses card changes applied — restarting HA to load them."
    curl -s -X POST -H "Authorization: Bearer $SUPERVISOR_TOKEN" http://supervisor/core/restart >/dev/null || true
  fi
}

# v34: HA's alarm panel accepts only the standard payloads
# (disarmed/armed_*/triggered) and rejects anything else as "unexpected
# payload". The addon publishes the raw panel status word
# (Idle/Trouble/Alert/Alarm) on cytech_comfort_mqtt/alarm, and its AM report
# handler publishes a literal "triggered" for zone-trouble codes that the
# panel then latches with nothing ever clearing it. This ensure adds the
# value_template to the panel's mqtt.alarm_control_panel entry so the status
# word maps onto what HA understands (Alarm -> triggered, Idle/Trouble/
# Alert -> disarmed, everything else passthrough -- so a panel that sits in
# TROUBLE no longer shows as a stuck "triggered"). This is the HA-side half
# of the contract fix; the addon-side AM change is tracked separately in
# the ucmpi4 addon. Only touches a panel entry whose state_topic is the
# comfort alarm topic -- never sensors or other mqtt entities, never
# anything else in configuration.yaml.
#
# Rules: idempotent; keeps .pre_v34_backup on first change; restarts HA if
# the file was modified (mirrors ensure_register_control_dashboard).
ensure_comfort_alarm_template() {
  local RESULT
  RESULT=$(python3 - << 'PYEOF'
import os
import shutil

# CY_CFG override is for offline testing only; on-device it always patches
# the real configuration.yaml.
CFG = os.environ.get('CY_CFG', '/config/configuration.yaml')
# These 4 lines go directly after the panel's state_topic line. The 3
# template lines are YAML-folded into one string by the '>-' scalar --
# exact copy of the block live-tested on cytech.local 2026-09-03.
INSERT = [
    '      value_template: >-',
    '        {% if value == "Alarm" %}triggered',
    '        {% elif value in ["Idle", "Trouble", "Alert"] %}disarmed',
    '        {% else %}{{ value }}{% endif %}',
]

if not os.path.exists(CFG):
    print("configuration.yaml missing -- skipping")
    raise SystemExit(0)

with open(CFG) as f:
    lines = f.read().split('\n')

# 1. Find the top-level mqtt: section, then the alarm_control_panel: list
# inside it. Only that subsection is ever touched.
try:
    mqtt_i = next(i for i, l in enumerate(lines) if l == 'mqtt:')
except StopIteration:
    print("no mqtt: section -- skipping")
    raise SystemExit(0)

panel_i = None
for i in range(mqtt_i + 1, len(lines)):
    l = lines[i]
    if l and not l.startswith(' '):
        break  # left the mqtt: section (next top-level key)
    if l.strip() == 'alarm_control_panel:':
        panel_i = i
        break

if panel_i is None:
    print("no mqtt alarm_control_panel -- skipping")
    raise SystemExit(0)

# 2. Inside the panel list, find the item owned by the comfort alarm:
# the first '- name:' whose block contains the alarm state_topic.
def item_end(j):
    i = j + 1  # skip the '- name:' line itself
    while i < len(lines) and lines[i].strip():
        if lines[i].startswith('    - '):          # next list item
            break
        if lines[i].startswith('  ') and not lines[i].startswith('    '):
            break                                  # next 2-space sub-key (sensor: etc.)
        i += 1
    return i

topic_txt = 'state_topic: "cytech_comfort_mqtt/alarm"'
item_i = None
j = panel_i + 1
while j < len(lines):
    if lines[j].startswith('    - '):
        if any(lines[k].strip() == topic_txt for k in range(j, item_end(j))):
            item_i = j
            break
        j = item_end(j)
    else:
        j += 1

if item_i is None:
    print("comfort alarm panel entry not found -- skipping")
    raise SystemExit(0)

# 3. Idempotent: already patched?
hi = item_end(item_i)
for k in range(item_i, hi):
    if lines[k].startswith('      value_template:'):
        print("already has value_template -- no change")
        raise SystemExit(0)

# 4. Insert the template right after the state_topic line.
topic_i = next(k for k in range(item_i, hi) if lines[k].strip() == topic_txt)
new = lines[:topic_i + 1] + INSERT + lines[topic_i + 1:]

# 5. Back up once, then write. Backup name follows the pattern used by the
# other ensure functions (.pre_vXX_backup) but is version-specific so an
# older update's backup is never silently overwritten.
bak = CFG + '.pre_v34_backup'
if not os.path.exists(bak):
    shutil.copy(CFG, bak)

with open(CFG, 'w') as f:
    f.write('\n'.join(new))

print("value_template added to comfort alarm panel -- updating")
PYEOF
)
  echo "$RESULT"
  if echo "$RESULT" | grep -qE "added|updated"; then
    echo "Comfort Alarm value_template applied -- restarting HA to load it."
    curl -s -X POST -H "Authorization: Bearer $SUPERVISOR_TOKEN" http://supervisor/core/restart >/dev/null || true
  fi
}

# v35: boot-loop detection. Every first_boot.sh run (i.e. every HA start)
# appends an epoch to /config/.cytech_boot_events; check_boot_storm then
# counts events in the last 24h and writes
# /config/.cytech_boot_result {"ts","status","message"} (status
# RESTART_STORM when >=5, OK otherwise) for sensor.cytech_boot_result.
record_boot_event() {
  if [ -f /config/.cytech_boot_events ]; then
    if [ "$(wc -l < /config/.cytech_boot_events)" -gt 500 ]; then
      tail -n 500 /config/.cytech_boot_events > /config/.cytech_boot_events.tmp 2>/dev/null \
        && mv /config/.cytech_boot_events.tmp /config/.cytech_boot_events
    fi
  fi
  date +%s >> /config/.cytech_boot_events 2>/dev/null || true
}

check_boot_storm() {
  local RESULT
  RESULT=$(python3 - << 'PYEOF'
import json
import os
import time

F = '/config/.cytech_boot_events'
O = '/config/.cytech_boot_result'
now = int(time.time())
events = []
if os.path.exists(F):
    with open(F) as f:
        for line in f:
            line = line.strip()
            if line.isdigit():
                events.append(int(line))
recent = [e for e in events if now - e < 86400]
status = 'OK'
message = 'no restart storm: %d HA restarts in the last 24h' % len(recent)
if len(recent) >= 5:
    status = 'RESTART_STORM'
    message = ('HA restarted %d times in the last 24h (first %s local). '
               'Likely a restart loop -- check the card and host journal.') % (
        len(recent), time.strftime('%H:%M:%S', time.localtime(min(recent))))
with open(O, 'w') as f:
    json.dump({'ts': now, 'status': status, 'message': message}, f)
print(message)
PYEOF
)
  echo "$RESULT"
}

# v36: email alert credentials. There must be NO SMTP password in the repo
# or the golden image -- the device keeps it in its existing
# /config/.cytech_secrets (KEY=VALUE lines, same file as the Tailscale
# client keys). v35 fed HA's secrets.yaml via !secret refs in
# packages/cytech.yaml -- fatal design: on a device without creds the config
# failed to parse (recovery mode), the maintenance pass that would have
# written them never ran, and the device was stuck until creds were pushed
# by hand (hit on cytechoffice-1). v36 instead GENERATES packages/
# cytech_email.yaml with the two smtp notify platforms as literal values:
# no creds -> no file -> cytech.yaml always parses. File is byte-compared so
# unchanged content does not restart HA again; file is chmod 600.
ensure_email_secrets() {
  # v37: the generator body moved out of this heredoc into the standalone
  # /config/cytech_email_gen.py -- the same file cytech_register_email.sh
  # calls, so there is exactly ONE source of truth for the generated
  # packages/cytech_email.yaml. Behavior is unchanged: prints one status
  # line; "written" or "removed" mean the generated file changed and HA
  # must restart; byte-compare means unchanged content never restarts.
  if [ ! -f /config/cytech_email_gen.py ]; then
    echo "cytech_email_gen.py missing -- email package not checked this pass"
    return 0
  fi
  local RESULT
  RESULT=$(python3 /config/cytech_email_gen.py 2>&1)
  echo "$RESULT"
  if echo "$RESULT" | grep -qE "written|removed"; then
    echo "Email package changed -- restarting HA to load it."
    curl -s -X POST -H "Authorization: Bearer $SUPERVISOR_TOKEN" http://supervisor/core/restart >/dev/null || true
  fi
}

# Home Assistant Supervisor's own DNS plugin defaults to Cloudflare over
# DNS-over-TLS (port 853) whenever no explicit "servers" are configured --
# fine on networks that allow it, but some corporate/guest/hotel-style
# networks block outbound port 853 specifically (to stop devices bypassing
# local DNS filtering). When that happens, every outbound HTTPS call from
# HA Core and its integrations fails outright -- push notifications, update
# checks, weather, HACS, analytics -- even though the network's own plain
# DNS works completely fine for every other device on it, phones included.
# Found 2026-07-04 at a customer site via repeated
# "dial tcp 1.1.1.1:853: i/o timeout" / "1.0.0.1:853" errors in the
# hassio_dns plugin's own log, right as Reset to Default separately failed
# there (see ensure_reset_watcher and the maintenance branch below).
#
# Configure explicit plain DNS (port 53, not DoT) instead: the site's own
# DHCP-provided gateway first (works virtually everywhere, including sites
# that rely on their own DNS-based filtering), then Cloudflare/Google plain
# DNS as a fallback if that's ever unreachable. The gateway address is
# rediscovered fresh every run (not hardcoded) since it differs per site;
# idempotent, only touches Supervisor's config if it's actually drifted
# from what the current network says it should be.
#
# Also disables Supervisor's own separate "fallback" option. That's a
# SECOND, independent DNS path (its own internal listener) that's
# hardcoded to Cloudflare over DoT regardless of what "servers" above is
# set to -- setting "servers" alone is not enough. Verified live
# 2026-07-04 by blocking outbound port 853 on a test device: with
# "servers" set but "fallback" still true, real hostnames resolved fine,
# but any query that came back empty/negative from the configured servers
# still silently hung for 15+ seconds on this second hardcoded path before
# failing. Disabling it entirely closed the gap -- both real and
# nonexistent hostnames then resolved in well under a second with port 853
# fully blocked.
ensure_resilient_dns() {
  local GATEWAY_DNS DESIRED CURRENT
  GATEWAY_DNS=$(curl -s -H "Authorization: Bearer $SUPERVISOR_TOKEN" http://supervisor/network/info \
    | jq -r '.data.interfaces[]? | select(.primary == true) | .ipv4.nameservers[0] // empty' 2>/dev/null)
  [ -z "$GATEWAY_DNS" ] && return 0
  DESIRED=$(jq -cn --arg gw "dns://${GATEWAY_DNS}" '[$gw, "dns://1.1.1.1", "dns://8.8.8.8"] | unique')
  CURRENT=$(curl -s -H "Authorization: Bearer $SUPERVISOR_TOKEN" http://supervisor/dns/info)
  if [ "$DESIRED" != "$(echo "$CURRENT" | jq -c '.data.servers // [] | unique')" ] \
      || [ "$(echo "$CURRENT" | jq -r '.data.fallback')" != "false" ]; then
    curl -s -X POST -H "Authorization: Bearer $SUPERVISOR_TOKEN" -H "Content-Type: application/json" \
      -d "{\"servers\": ${DESIRED}, \"fallback\": false}" http://supervisor/dns/options
    echo "DNS servers set to plain (port 53) resolution, hardcoded DoT fallback disabled: ${DESIRED}"
  fi
}

# Idempotently registers the Cytech managed dashboards as YAML-mode (read-only)
# entries in configuration.yaml's lovelace.dashboards dict, and removes their
# now-superseded storage registry entries (so a v17->v18 device doesn't end up
# with both storage and YAML versions = duplicate dashboards). Dashboard content
# files live in /config/dashboards/ (shipped via manifest files[] or baked into
# the golden image). Returns 1 if configuration.yaml changed (caller restarts
# HA to load the new block), 0 otherwise.
ensure_yaml_dashboards() {
  local CFG=/config/configuration.yaml CHANGED=0
  mkdir -p /config/dashboards
  if ! grep -q '^lovelace:' "$CFG" 2>/dev/null; then
    cat >> "$CFG" << 'YAMLEOF'

lovelace:
  # Managed dashboards in YAML mode (read-only in the UI). Landing = standard
  # HA Overview (editable storage). Edit /config/dashboards/*.yaml to change.
  dashboards:
    comfort-alarm:
      mode: yaml
      title: Comfort Alarm
      icon: mdi:alarm-panel
      show_in_sidebar: true
      require_admin: false
      filename: dashboards/alarm.yaml
    config-files:
      mode: yaml
      title: Config Files
      icon: mdi:cog
      show_in_sidebar: true
      require_admin: true
      filename: dashboards/system.yaml
    dashboard-welcome:
      mode: yaml
      title: Remote Access
      icon: mdi:home-assistant
      show_in_sidebar: true
      require_admin: false
      filename: dashboards/welcome.yaml
    reset-default:
      mode: yaml
      title: Reset to Default
      icon: mdi:restore-alert
      show_in_sidebar: true
      require_admin: true
      filename: dashboards/reset_default.yaml
    battery-levels:
      mode: yaml
      title: System Info
      icon: mdi:account-settings
      show_in_sidebar: true
      require_admin: false
      filename: dashboards/battery_levels.yaml
YAMLEOF
    CHANGED=1
    echo "YAML dashboards registered in configuration.yaml"
  fi
  # Remove storage registry entries for dashboards now managed as YAML.
  if [ -f /config/.storage/lovelace_dashboards ]; then
    python3 - <<'PYEOF'
import json
p = '/config/.storage/lovelace_dashboards'
d = json.load(open(p))
remove = {'comfort_alarm', 'system', 'reset_default', 'dashboard_welcome', 'battery_levels'}
before = len(d['data']['items'])
d['data']['items'] = [i for i in d['data']['items'] if i.get('id') not in remove]
after = len(d['data']['items'])
if after != before:
    json.dump(d, open(p, 'w'))
    print(f"lovelace_dashboards registry: {before} -> {after} (removed storage duplicates)")
PYEOF
  fi
  return $CHANGED
}

# 1. Maintenance mode — already provisioned, just run health checks
if [ -f /config/.zero_touch_completed ]; then
  # .reset_cycle_active still guards against this branch's dashboard/DNS
  # work running concurrently with an in-progress reset cycle rewriting the
  # same config files. It's no longer guarding against an addon-stop race
  # (see ensure_ssh_admin_access -- the addon doesn't stop around resets
  # anymore, so that race no longer exists), just against two passes
  # touching the same files at once. Treated as stale after 15 minutes so a
  # crashed finish_firstboot (which clears this flag on its last line) can't
  # permanently disable maintenance self-heal.
  if [ -n "$(find /config/.reset_cycle_active -mmin -15 2>/dev/null)" ]; then
    echo "Reset cycle still in progress -- skipping maintenance checks this pass."
    exit 0
  fi
  echo "Already initialized. Running maintenance checks..."
  record_boot_event
  check_boot_storm
  check_config_integrity
  ensure_resilient_dns
  ensure_yaml_dashboards
  if [ $? -eq 1 ]; then
    echo "YAML dashboard config changed — restarting HA to load it."
    curl -s -X POST -H "Authorization: Bearer $SUPERVISOR_TOKEN" http://supervisor/core/restart >/dev/null
    exit 0
  fi
  if [ -f /config/.ssh/id_rsa ]; then
    ensure_ssh_admin_access
    # Normally already up well before this point (boot: auto), so this returns
    # on its first probe -- it's only a real wait the first time
    # ensure_ssh_admin_access has to change anything (e.g. an existing device's
    # first boot after adopting this).
    wait_for_ssh_addon
    apply_discard_fix
    apply_usb_host_mode_fix
    check_and_apply_updates
    ensure_reset_watcher
    ensure_reset_dashboard
    ensure_remote_qr
    ensure_register_control_dashboard
    ensure_responses_card
    ensure_comfort_alarm_template
    ensure_email_secrets

    TS_STATE=$(ssh -i /config/.ssh/id_rsa -o StrictHostKeyChecking=no -o ConnectTimeout=10 root@a0d7b954-ssh \
      "docker exec app_a0d7b954_tailscale /opt/tailscale status --json 2>/dev/null" \
      2>/dev/null | jq -r '.BackendState // empty' 2>/dev/null)

    if [ "$TS_STATE" = "NeedsLogin" ]; then
      echo "Tailscale NeedsLogin — state was wiped (SD card issue?). Re-authenticating..."
      { set +x; } 2>/dev/null
      AUTH_KEY=$(get_auth_key)
      ssh -i /config/.ssh/id_rsa -o StrictHostKeyChecking=no -o ConnectTimeout=10 root@a0d7b954-ssh \
        "docker exec app_a0d7b954_tailscale /opt/tailscale up \
          --authkey='${AUTH_KEY}' \
          --accept-routes=true --hostname=cytech" 2>/dev/null
      set -x
      echo "Tailscale re-auth sent. Waiting 90s for Funnel and hostname to stabilise..."
      sleep 90
      NEW_FULL_DNS=$(ssh -i /config/.ssh/id_rsa -o StrictHostKeyChecking=no -o ConnectTimeout=10 root@a0d7b954-ssh \
        "docker exec app_a0d7b954_tailscale /opt/tailscale status --json 2>/dev/null" \
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
        "docker exec app_a0d7b954_tailscale /opt/tailscale status --json 2>/dev/null" \
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
  fi
  remove_scratch_images
  exit 0
fi

# Fresh device -- run the flash canary before anything else touches disk.
# A card that fails this shouldn't be provisioned or shipped at all.
if ! run_flash_canary; then
  echo "ABORTING PROVISIONING: flash canary failed. This card should not be used for a customer device."
  exit 1
fi

ensure_resilient_dns
ensure_yaml_dashboards

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

# 7. Set up the addon: persistent per-device password + this fresh key,
# boot: auto, watchdog on -- see ensure_ssh_admin_access.
ensure_ssh_admin_access

# Wait for the addon to actually be up before relying on SSH into it. Every
# host-level step below tunnels through it, so a false-positive readiness
# signal here silently no-ops the whole rest of provisioning -- Tailscale
# included. See wait_for_ssh_addon.
wait_for_ssh_addon

# Apply DISCARD fix now that SSH addon is running
apply_discard_fix
apply_usb_host_mode_fix

# 8. Tailscale — dev mode / an already-registered identity reuses state; only
# a genuinely fresh device (no existing registration) wipes and re-registers.
#
# The second condition (an existing Running identity found with no
# .dev_reset_mode flag) covers a provisioning run that gets interrupted by an
# HA Core restart AFTER Tailscale successfully registered but BEFORE
# .zero_touch_completed was written -- e.g. an "Update Now" config update
# landing mid-provisioning fires `core/restart` in cytech_update.sh, which
# kills this script and re-triggers it from scratch on the next start. Without
# this check the retried run has no memory of the identity the interrupted
# run already obtained, and blindly wipes+re-registers, burning a Tailscale
# node + Let's Encrypt cert and orphaning the QR/link already shown to the
# user. Root-caused 2026-07-16 on a unit that churned cytech-34 -> cytech-36
# this way. A genuinely fresh clone from the golden image has no Running
# Tailscale state at this point (reset.sh wipes it at capture time), so this
# doesn't affect normal first-ever-boot provisioning.
EXISTING_FULL_DNS=$(ssh -i /config/.ssh/id_rsa -o StrictHostKeyChecking=no root@a0d7b954-ssh \
  "docker exec app_a0d7b954_tailscale /opt/tailscale status --json 2>/dev/null" \
  | jq -r 'select(.BackendState=="Running") | .Self.DNSName // empty' | sed 's/\.$//')

if [ -f /config/.dev_reset_mode ] || [ -n "$EXISTING_FULL_DNS" ]; then
  if [ -f /config/.dev_reset_mode ]; then
    rm -f /config/.dev_reset_mode
    echo "Dev reset mode: reusing existing Tailscale identity (TLS cert preserved)."
  else
    echo "Found an already-registered Tailscale identity (${EXISTING_FULL_DNS}) and no dev-reset flag — reusing it instead of wiping (likely an interrupted prior provisioning run)."
  fi
  # Ensure addon is running (dev_reset.sh does not stop it; an interrupted
  # run may have left it in any state)
  curl -s -X POST -H "Authorization: Bearer $SUPERVISOR_TOKEN" http://supervisor/addons/a0d7b954_tailscale/start 2>/dev/null || true
  sleep 15
  ACTUAL_FULL_DNS=$(ssh -i /config/.ssh/id_rsa -o StrictHostKeyChecking=no root@a0d7b954-ssh \
    "docker exec app_a0d7b954_tailscale /opt/tailscale status --json" \
    | jq -r '.Self.DNSName // empty' | sed 's/\.$//')
  ACTUAL_HOSTNAME=$(echo "$ACTUAL_FULL_DNS" | cut -d. -f1)
else
  # Production path: no existing identity to reuse — wipe state so each
  # cloned SD card gets a unique node identity.
  echo "Clearing Tailscale state for fresh node identity..."
  curl -s -X POST -H "Authorization: Bearer $SUPERVISOR_TOKEN" http://supervisor/addons/a0d7b954_tailscale/stop
  sleep 8
  ssh -i /config/.ssh/id_rsa -o StrictHostKeyChecking=no root@a0d7b954-ssh \
    "docker run --rm --entrypoint sh \
      -v /mnt/data/supervisor/apps/data/a0d7b954_tailscale:/tsdata \
      \$(docker inspect homeassistant --format '{{.Config.Image}}') \
      -c 'rm -f /tsdata/tailscaled.state && rm -rf /tsdata/state && echo cleared'"
  curl -s -X POST -H "Authorization: Bearer $SUPERVISOR_TOKEN" http://supervisor/addons/a0d7b954_tailscale/start
  sleep 20

  echo "Authenticating Tailscale with fresh identity..."
  { set +x; } 2>/dev/null
  AUTH_KEY=$(get_auth_key)
  ssh -i /config/.ssh/id_rsa -o StrictHostKeyChecking=no root@a0d7b954-ssh \
    "docker exec app_a0d7b954_tailscale /opt/tailscale up --authkey='${AUTH_KEY}' --accept-routes=true --hostname=cytech"
  set -x

  # Wait for share-homeassistant s6 service to re-establish Funnel (~90s)
  sleep 90
  ACTUAL_FULL_DNS=$(ssh -i /config/.ssh/id_rsa -o StrictHostKeyChecking=no root@a0d7b954-ssh \
    "docker exec app_a0d7b954_tailscale /opt/tailscale status --json" \
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
# Clear the reset-cycle flag even if killed mid-run (addon crash, SIGTERM on
# container stop). Without this, .reset_cycle_active stays set and the
# maintenance branch defers forever, disabling self-heal. Normal completion
# also clears it at the end -- idempotent no-op here.
trap 'rm -f /config/.reset_cycle_active' EXIT
sleep 5
DEVICE_ID=$(cat /config/device_id.txt)
# Read full Tailscale DNSName live — correct regardless of which tailnet is in use
FULL_DNS=$(docker exec app_a0d7b954_tailscale /opt/tailscale status --json 2>/dev/null \
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

# Create System dashboard -- SKIPPED: system (Config Files) is now YAML-mode
# (dashboards/system.yaml + registered in configuration.yaml). The heredoc
# below is consumed by ':' so it does nothing; kept for reference.
: << 'PYEOF'
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
# The SSH addon stays up permanently now (boot: auto, see
# ensure_ssh_admin_access in first_boot.sh) -- no more clearing the
# provisioning key or stopping the addon here. The persistent per-device
# password and this same key remain valid across every future reset cycle.
# The whole two-restart reset cycle is genuinely done now -- safe for
# dev_reset.sh's debounce guard to allow another run. No-op if unset
# (e.g. production reset.sh path, which never sets this flag).
rm -f /config/.reset_cycle_active
echo "=== finish_firstboot complete $(date) ==="
FINISH_EOF
    chmod +x /config/finish_firstboot.sh

    # Launch finish script from WITHIN the SSH addon (separate container — not killed
    # when HA core stops) and return immediately.
    ssh -i /config/.ssh/id_rsa -o StrictHostKeyChecking=no root@a0d7b954-ssh \
      "nohup bash /config/finish_firstboot.sh </dev/null >> /config/finish_debug.log 2>&1 &"

    echo "Finish script launched in SSH addon. Deployment complete."
    remove_scratch_images
else
    echo "ERROR: Tailscale failed to connect! Leaving SSH open for debugging."
fi
