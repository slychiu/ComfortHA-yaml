#!/bin/bash
# SD-card health check (v35). Greps the HOST kernel journal via the SSH
# addon's container (which sees the host journal -- Core's own container
# cannot get kernel messages for the host) for card/I-O failure signatures,
# and counts host boot sessions started today to spot restart loops. Writes
# /config/.cytech_sdcard_result as {"ts","status","message"} which
# sensor.cytech_sdcard_result reads. Runs on every HA start via the
# cytech_start_health_checks automation.
#
# If the ssh client or the SSH addon is unavailable the check degrades to
# SKIP -- detection must never break the start automation.
OUT=/config/.cytech_sdcard_result
LOG=/config/cytech_sd.log
SSH_KEY=/config/.ssh/id_rsa
SSH_HOST=a0d7b954-ssh

status=OK
message="no SD/IO errors found in host kernel log"

ssh_run() {
  ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no -o ConnectTimeout=10 \
    -o BatchMode=yes root@"$SSH_HOST" "$1" 2>/dev/null
}

write_result() {
  local s="$1" m="$2"
  python3 - "$OUT" "$s" "$m" << 'PYEOF'
import json, sys, time
with open(sys.argv[1], "w") as f:
    json.dump({"ts": int(time.time()), "status": sys.argv[2], "message": sys.argv[3]}, f)
PYEOF
  echo "sdcard: $status ($message)" >> "$LOG"
}

if ! command -v ssh >/dev/null 2>&1; then
  status=SKIP
  message="ssh client missing in Core container -- check skipped"
  write_result "$status" "$message"
  exit 0
fi

if [ ! -f "$SSH_KEY" ]; then
  status=SKIP
  message="SSH addon key /config/.ssh/id_rsa missing -- check skipped"
  write_result "$status" "$message"
  exit 0
fi

# The SSH addon may still be starting up on HA start; retry before giving up.
for i in 1 2 3; do
  if ssh_run true >/dev/null 2>&1; then
    break
  fi
  if [ "$i" = 3 ]; then
    status=SKIP
    message="SSH addon unavailable -- check skipped (will retry next start)"
    write_result "$status" "$message"
    exit 0
  fi
  sleep 15
done

# Kernel error lines mentioning the card/block layer, across all retained
# boots (a boot loop leaves these; reads do not wear the card).
HITS=$(ssh_run 'journalctl -k -p err --no-pager 2>/dev/null | grep -iE "mmc|I/O error|blk_update|crc error|Buffer I/O|ext4.*(error|corrupt)|f2fs.*(error|corrupt)" | tail -5')

# Number of boot sessions that started today (journal keeps past boots).
TODAY_BOOTS=$(ssh_run "journalctl --list-boots --no-pager 2>/dev/null | grep -c '$(date +%F)'" | tr -d ' ')

if [ -n "$HITS" ]; then
  status=FAIL
  message="SD/IO errors in kernel log: $(echo "$HITS" | tr '\n' '|' | head -c 380)"
elif [ -n "${TODAY_BOOTS:-0}" ] && [ "${TODAY_BOOTS:-0}" -ge 4 ]; then
  status=FAIL
  message="Host booted ${TODAY_BOOTS:-0} times today -- restart loop suspected"
fi

json=$(python3 - "$OUT" "$status" "$message" "${TODAY_BOOTS:-0}" << 'PYEOF'
import json, sys, time
with open(sys.argv[1], "w") as f:
    json.dump({"ts": int(time.time()), "status": sys.argv[2],
               "message": sys.argv[3], "boots_today": sys.argv[4]}, f)
PYEOF
)
echo "$json" > /dev/null
echo "sdcard: $status ($message)" >> "$LOG"
