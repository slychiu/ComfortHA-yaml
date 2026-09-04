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

# Version ordering with letter revisions: "42a" > "42", "42b" > "42a",
# "43" > "42z", but "41a" < "42" (a letter fix is not newer than the next
# full version). A letter suffix marks a FIX revision of the same release --
# the fleet policy: while a version has not yet been committed to the fleet,
# fixes keep the same number with a suffix instead of burning a new version
# per small fix. Non-numeric garbage sorts as 0. Returns 0 iff $1 > $2.
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
  [ "$rs" = "" ] && return 1
  [ "$ls" = "" ] && return 0
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
  notify "Already on the latest version (v${LOCAL_VER})."
  rm -f /config/.cytech_update_pending
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
  curl -s -X POST -H "Authorization: Bearer $SUPERVISOR_TOKEN" \
    http://supervisor/core/restart
  echo "HA restarting to apply dashboard/package/first_boot changes..."
fi
