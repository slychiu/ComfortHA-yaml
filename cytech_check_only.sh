#!/bin/bash
# "Check for Update" — checks manifest and notifies; does NOT apply the update
exec >> /config/cytech_update.log 2>&1
echo "=== cytech_check_only.sh $(date) ==="
source /config/.cytech_secrets

# Writes {"ts": ..., "message": ...} JSON to one or more files. Sensor STATE
# values are capped at 255 characters in HA and silently become "unknown"
# past that; the "message" attribute (read via json_attributes) has no such
# limit, so all Cytech status text goes through here rather than raw state.
write_msg() {
  local msg="$1"
  shift
  local json
  json=$(jq -n --arg ts "$(date +%s)" --arg msg "$msg" '{ts: $ts, message: $msg}')
  for f in "$@"; do
    echo "$json" > "$f"
  done
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

# Self-heal the update source. A unit whose CYTECH_MANIFEST_URL is not the
# canonical `main` one cannot update at all: the retired `test` branch would
# leave it on its old version reporting "up to date" (truthfully, relative to
# that frozen source) forever, while any other ref -- a release tag left
# behind by a service visit, a commit SHA, no ref at all -- makes
# cytech_update.sh build a download base that 404s, so the owner sees "Update
# failed while downloading ...". Repoint it at `main` once, keeping the
# original line in a backup so nothing is lost; silent no-op otherwise.
# Fleet port of the v13 rescue repair, which reached stranded units through
# the retired `test` branch -- this makes the repair permanent on the main
# line, for any unit that was left pointed elsewhere or gets left there
# again. Deliberately never touches a local mirror or another repo.
ensure_manifest_url_current() {
  local f=/config/.cytech_secrets
  [ -f "$f" ] || return 0
  local cur ref
  cur=$(grep '^CYTECH_MANIFEST_URL=' "$f" | head -n1 | cut -d= -f2-)
  # tolerate a hand-edited CR, trailing blanks or surrounding quotes
  cur=$(printf '%s' "$cur" | tr -d '\r' | sed 's/[[:space:]]*$//; s/^"//; s/"$//')
  # this repo on its real host only -- never a local mirror, never another repo
  case "$cur" in
    https://raw.githubusercontent.com/slychiu/ComfortHA-yaml/*) ;;
    *) return 0 ;;
  esac
  ref="${cur#https://raw.githubusercontent.com/slychiu/ComfortHA-yaml/}"
  case "$ref" in
    manifest.json) ;;                            # no ref -- default branch
    */manifest.json)
      ref="${ref%/manifest.json}"
      case "$ref" in */*) return 0 ;; esac       # unexpected shape -- leave it
      if [ "$ref" = main ]; then return 0; fi ;;
    *) return 0 ;;
  esac
  [ -f "${f}.bak_pre_manifest_repair" ] || cp "$f" "${f}.bak_pre_manifest_repair"
  sed -i 's|^CYTECH_MANIFEST_URL=.*|CYTECH_MANIFEST_URL=https://raw.githubusercontent.com/slychiu/ComfortHA-yaml/main/manifest.json|' "$f"
  # The file was sourced above, before this rewrite -- refresh the variable too,
  # so the update check later in this same run already uses the new URL.
  CYTECH_MANIFEST_URL=$(grep '^CYTECH_MANIFEST_URL=' "$f" | head -n1 | cut -d= -f2-)
  echo "MANIFEST SELF-HEAL: CYTECH_MANIFEST_URL repointed to ${CYTECH_MANIFEST_URL} (backup: ${f}.bak_pre_manifest_repair)"
}

ensure_manifest_url_current

MANIFEST=$(curl -sf --max-time 10 "${CYTECH_MANIFEST_URL}" 2>/dev/null)

if [ -z "$MANIFEST" ]; then
  write_msg "Could not reach update server. Check your internet connection." /config/.cytech_notify_pending
  exit 1
fi

REMOTE_VER=$(echo "$MANIFEST" | jq -r '.version // 0')
CHANGELOG=$(echo "$MANIFEST" | jq -r '.changelog // "No details available"')

if ! ver_newer "$REMOTE_VER" "$LOCAL_VER"; then
  write_msg "System is up to date (v${LOCAL_VER})." /config/.cytech_notify_pending /config/.cytech_last_result
  rm -f /config/.cytech_pending_message
  exit 0
fi

echo -n "$REMOTE_VER" > /config/.cytech_update_pending

# Every update overwrites packages/cytech.yaml unconditionally (no merge, no
# backup) so that warning always applies. Beyond that, a manifest can list
# release-specific risks via an optional "warnings" array. Mirrors the same
# logic in first_boot.sh's check_and_apply_updates() -- this script is the
# actual "Check for Update" button path and has its own separate message
# here, not shared code, so it needs the same warnings built independently.
WARNINGS=$(echo "$MANIFEST" | jq -r '
  ["Any custom edits to packages/cytech.yaml will be overwritten."]
  + (.warnings // [])
  | map("- " + .) | join("\n")
')

MSG="**v${REMOTE_VER} available:** ${CHANGELOG}"$'\n\n**Before you update:**\n'"${WARNINGS}"$'\n\nPress **Update Now** to apply.'
# .cytech_notify_pending gets auto-cleared right after its one-time popup
# fires (see cytech_show_notification automation); .cytech_pending_message
# isn't, so the Config Files dashboard has something stable to show while
# the update is still pending. .cytech_last_result is what the dashboard
# falls back to once nothing's pending, so it's fine for it to hold this
# same text in the meantime too.
write_msg "$MSG" /config/.cytech_notify_pending /config/.cytech_pending_message /config/.cytech_last_result
