#!/bin/bash
# "Update Now" — applies pending Cytech configuration update
exec >> /config/cytech_update.log 2>&1
echo "=== cytech_update.sh $(date) ==="
source /config/.cytech_secrets

# Sensor STATE values are capped at 255 characters in HA and silently become
# "unknown" past that; the "message" attribute (read via json_attributes)
# has no such limit, so status text is written as JSON, not raw text.
notify() {
  local json
  json=$(jq -n --arg ts "$(date +%s)" --arg msg "$1" '{ts: $ts, message: $msg}')
  echo "$json" | tee /config/.cytech_notify_pending > /config/.cytech_last_result
}

# v55: restart Core so the just-applied files actually load. Core-context can
# 401 on some units; the SSH addon's token works there, and its own integrity
# watcher (cytech_integrity_check.py) is the third backstop. 000 counts as
# success -- core may cut the connection after starting the restart.
restart_core_verified() {
  local CODE FALLBACK
  touch /config/.cytech_planned_restart 2>/dev/null || true
  CODE=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 \
    -X POST -H "Authorization: Bearer $SUPERVISOR_TOKEN" \
    http://supervisor/core/restart 2>/dev/null)
  case "$CODE" in
    200|201|000)
      echo "HA restarting to apply dashboard/package/first_boot changes..."
      return 0
      ;;
  esac
  echo "Core-context restart returned ${CODE:-no response}; retrying through the SSH addon..."
  FALLBACK=$(ssh -i /config/.ssh/id_rsa -o StrictHostKeyChecking=no \
    -o ConnectTimeout=10 root@a0d7b954-ssh \
    'curl -s -o /dev/null -w "%{http_code}" --max-time 10 -X POST -H "Authorization: Bearer $SUPERVISOR_TOKEN" http://supervisor/core/restart' \
    2>/dev/null)
  case "$FALLBACK" in
    200|201|000)
      echo "HA restarting to apply dashboard/package/first_boot changes..."
      return 0
      ;;
  esac
  echo "Restart could not be confirmed (${FALLBACK:-no response}); the integrity watcher will restart HA within 5 minutes."
  return 1
}

# v55: true when the version file is newer than the last first_boot pass --
# i.e. an update's files are on disk but no Core start has loaded them yet.
# Used on the "already up to date" path: without this, a press after a missed
# restart (the old fire-and-forget bug) reported "already on the latest
# version" and did nothing, so the only remaining recovery was a reboot.
# The 5-minute floors keep it from racing the watcher or a boot in progress.
pending_restart() {
  local V_MTIME LAST_PASS NOW GUARD
  [ -f /config/.cytech_version ] || return 1
  V_MTIME=$(stat -c %Y /config/.cytech_version 2>/dev/null) || return 1
  if [ -f /config/.cytech_boot_result ]; then
    LAST_PASS=$(jq -r '.ts // 0' /config/.cytech_boot_result 2>/dev/null)
    case "$LAST_PASS" in ''|*[!0-9]*) return 1 ;; esac
  else
    # 2026-10-23 (real v30 image, 260801 capture): images older than v35 --
    # which is exactly the class with no integrity watcher either -- never
    # write .cytech_boot_result. Without this branch the owner's second
    # "Update Now" after a missed restart still says "already on the latest
    # version" and does nothing, so those units had no local recovery at all
    # (reproduced live: old updater landed v55 over a 403, second press did
    # nothing). With no baseline, use 0; the >=300 s write-age and guard
    # floors below still prevent racing a boot or looping, and the first
    # successful restart makes first_boot (v35+) write the real timestamp.
    LAST_PASS=0
  fi
  NOW=$(date +%s)
  [ "$V_MTIME" -gt $((LAST_PASS + 120)) ] || return 1
  [ $((NOW - V_MTIME)) -ge 300 ] || return 1
  GUARD=$(jq -r '.last // 0' /config/.cytech_restart_guard.json 2>/dev/null)
  case "$GUARD" in ''|*[!0-9]*) GUARD=0 ;; esac
  [ $((NOW - GUARD)) -ge 300 ] || return 1
  return 0
}

# Version ordering with letter revisions: "42b" > "42a", "43" > "42z" (handled
# by the integer branch, unaffected by letters). SAME-BASE bare-vs-lettered
# ("45" vs "45a"): the bare (letterless) release is always the fleet
# PROMOTION of that base number's letters once confirmed (see
# feedback_no_letter_versions) -- so bare always outranks any of its own
# base's letters, in either comparison direction. v45 fix: the original rule
# had this backwards ("$rs"="" -> not newer unconditionally), which is why a
# device already on "45a" reported "45a is the latest version" and refused
# the real "45" fleet release -- reproduced live 2026-09-07. Non-numeric
# garbage sorts as 0. Returns 0 iff $1 > $2.
ver_newer() {
  local r l rs ls
  r=$(printf '%s' "$1" | tr -cd '0-9'); r=${r:-0}
  l=$(printf '%s' "$2" | tr -cd '0-9'); l=${l:-0}
  if [ "$r" -ne "$l" ] 2>/dev/null; then
    [ "$r" -gt "$l" ] 2>/dev/null && return 0
    return 1
  fi
  rs=$(printf '%s' "$1" | sed "s/^${r}//")
  ls=$(printf '%s' "$2" | sed "s/^${l}//")
  [ "$rs" = "$ls" ] && return 1
  [ "$rs" = "" ] && return 0
  [ "$ls" = "" ] && return 1
  [ "$rs" \> "$ls" ] && return 0
  return 1
}

LOCAL_VER=$(cat /config/.cytech_version 2>/dev/null || echo 0)
MANIFEST=$(curl -sf --max-time 10 "${CYTECH_MANIFEST_URL}" 2>/dev/null)

if [ -z "$MANIFEST" ]; then
  notify "Could not reach update server. Check your internet connection."
  exit 1
fi

REMOTE_VER=$(echo "$MANIFEST" | jq -r '.version // 0')

if ! ver_newer "$REMOTE_VER" "$LOCAL_VER"; then
  # v55: if the last update landed but never restarted, a second press is the
  # owner's only local recovery -- make it restart instead of doing nothing.
  if pending_restart; then
    notify "Finishing the last update -- HA is restarting."
    restart_core_verified
  else
    notify "Already on the latest version (v${LOCAL_VER})."
    rm -f /config/.cytech_update_pending
  fi
  exit 0
fi

CHANGELOG=$(echo "$MANIFEST" | jq -r '.changelog // "No details available"')
DETAILS=$(echo "$MANIFEST" | jq -r 'if .details then .details else "" end')
echo "Applying update v${LOCAL_VER} -> v${REMOTE_VER}: ${CHANGELOG}"
if [ -n "$DETAILS" ]; then
  echo "--- Update details (technical, for the install log only):"
  echo "$DETAILS"
fi

# v42e: raw.githubusercontent.com serves each URL from a CDN that keeps it
# cached for max-age=300 (5 minutes), keyed by the URL itself (a query string
# does NOT create a separate entry -- verified 2026-09-04). A device that
# downloads right after a release can therefore receive the PREVIOUS
# version's file with no error, then write the new version label -- silently
# half-updated, and permanently unable to re-apply ("up to date"). That is
# exactly what v42c did on the bench unit. THE FIX: every release is also
# git-tagged with its version (the manifest's git_tag field) and files are
# downloaded from the tag URL -- a URL no device has ever fetched, so it can
# never be served from cache. The manifest itself stays on the branch URL
# (5-minute staleness there is harmless: a stale read just says "up to date"
# and the next check, one TTL later, is fresh).
TAG=$(echo "$MANIFEST" | jq -r '.git_tag // ""')
if [ -n "$TAG" ]; then
  # manifest URL is .../ComfortHA-yaml/main/manifest.json -> strip to repo root
  BASE_URL="${CYTECH_MANIFEST_URL%/main/manifest.json}/${TAG}"
else
  BASE_URL="${CYTECH_MANIFEST_URL%/manifest.json}"
fi

# Tracked separately from LOVELACE_CHANGED below (declared later, closer to
# where it's used) because packages/cytech.yaml holds live HA config
# (shell_command/sensor/automation definitions) that -- like lovelace
# storage changes -- silently doesn't take effect until HA restarts. A
# content compare (not just "was it in the file list") avoids restarting
# on every single update when this file happens to be unchanged.
PACKAGES_CHANGED=0
# first_boot.sh changes must also trigger a restart -- otherwise the new
# first_boot.sh sits on disk unexecuted until the next manual reboot, and
# things like ensure_yaml_dashboards() wouldn't run on Update Now.
FIRSTBOOT_CHANGED=0
while IFS= read -r FILE; do
  case "$FILE" in
    .cytech_secrets|device_id.txt|.zero_touch_completed|configuration.yaml|secrets.yaml|"") continue ;;
    *..*) continue ;;
  esac
  mkdir -p "/config/$(dirname "${FILE}")"
  if curl -sf --max-time 30 "${BASE_URL}/${FILE}" -o "/config/${FILE}.tmp"; then
    case "$FILE" in *.sh) chmod +x "/config/${FILE}.tmp" ;; esac
    if [ "$FILE" = "packages/cytech.yaml" ] && ! cmp -s "/config/${FILE}" "/config/${FILE}.tmp" 2>/dev/null; then
      PACKAGES_CHANGED=1
    fi
    if [ "$FILE" = "first_boot.sh" ] && ! cmp -s "/config/${FILE}" "/config/${FILE}.tmp" 2>/dev/null; then
      FIRSTBOOT_CHANGED=1
    fi
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
rm -f /config/.cytech_pending_message
notify "Updated to v${REMOTE_VER}: ${CHANGELOG}"

# Note: the SSH addon watcher (which makes Reset to Default work) is NOT
# pushed here. It's addon config, not a tracked file, and a device that
# jumps multiple versions in one update runs this exact script to do it --
# meaning whatever's already installed, not whatever this update just wrote
# to disk. That self-referential gap is why it lives in first_boot.sh's
# maintenance-mode branch instead: it runs using the freshly-downloaded
# first_boot.sh on the next boot, regardless of which version was skipped.

# Storage-mode dashboards are no longer pushed via updates (v33): every
# update used to bundle zones_dashboard.json and rewrite the "Comfort
# Entities" dashboard wholesale, silently discarding any UI customization
# (rearranged cards, renamed zones, entities added after discovery, e.g.
# the bridge addon's Response buttons). User-edit dashboards now stay
# user-edit dashboards. YAML-mode dashboards ship as plain files via
# manifest.json. Keep this apply_dashboard() around in case a future
# release needs to push a one-off storage dashboard -- but then also
# remind the user that the next release must remove that json from
# the manifest, or it re-applies forever.
LOVELACE_CHANGED=0
apply_dashboard() {
  local SRC="$1" DEST="$2"
  [ -f "/config/${SRC}" ] || return
  # This replaces the dashboard's entire config wholesale -- any local
  # customization (rearranged cards, renamed zones, added entities) would
  # otherwise be silently lost with no way to recover it. Keep one backup of
  # whatever was there immediately before this update; not a full history,
  # but enough to undo a bad surprise without needing to reset the device.
  cp "/config/.storage/${DEST}" "/config/.storage/${DEST}.pre_update_backup" 2>/dev/null
  python3 -c "
import json, sys
with open('/config/${SRC}') as f:
    config = json.load(f)
with open('/config/.storage/${DEST}') as f:
    storage = json.load(f)
storage['data']['config'] = config
with open('/config/.storage/${DEST}', 'w') as f:
    json.dump(storage, f)
print('${DEST} updated (previous config backed up to ${DEST}.pre_update_backup)')
" && rm -f "/config/${SRC}" && LOVELACE_CHANGED=1
}

# v33: no dashboard jsons are shipped anymore -- zones_dashboard.json and
# welcome_dashboard.json were both removed from manifest.json. The old
# welcome call also was actively broken: its storage file no longer exists
# (the welcome dashboard is YAML-mode now), so every update raised a
# FileNotFoundError and left the json on disk to re-fail next time.
if [ "$LOVELACE_CHANGED" = "1" ] || [ "$PACKAGES_CHANGED" = "1" ] || [ "$FIRSTBOOT_CHANGED" = "1" ]; then
  # v45: restart_core_verified() marks this as a planned restart so
  # record_boot_event() (first_boot.sh) doesn't count it toward Repeated
  # Restarts -- an update applying is not an instability signal.
  #
  # v55: this used to be a fire-and-forget curl. On a unit whose core
  # container gets 401 from the Supervisor API, the update applied its files
  # and then silently never restarted -- and everything that only runs on a
  # Core start (the v54 provisioning repair, the boot-time ensures) never ran
  # either. The helper checks the result, retries through the SSH addon, and
  # leaves the addon's integrity watcher as the last backstop.
  restart_core_verified
fi
