#!/bin/bash
# Per-boot write/readback canary (v35) on the data partition. Detects a
# failing write path or erroring/full filesystem BEFORE it becomes a boot
# loop. Small by design (8 MB): ~3 GB/year at one boot/day -- far below a
# good card's endurance budget while HA itself writes 100s of MB daily.
# Writes /config/.cytech_canary_result as {"ts","status","message"} which
# sensor.cytech_canary_result reads. Runs on every HA start via the
# cytech_start_health_checks automation.
OUT=/config/.cytech_canary_result
LOG=/config/cytech_sd.log
W=/config/.cytech_canary.tmp

status=OK
message="canary passed (8 MB write/readback)"

write_result() {
  python3 - "$OUT" "$1" "$2" << 'PYEOF'
import json, sys, time
with open(sys.argv[1], "w") as f:
    json.dump({"ts": int(time.time()), "status": sys.argv[2], "message": sys.argv[3]}, f)
PYEOF
  echo "canary: $status ($message)" >> "$LOG"
}

if ! command -v head >/dev/null 2>&1 || ! command -v sha256sum >/dev/null 2>&1; then
  status=SKIP
  message="head/sha256sum missing in Core container -- canary skipped"
  write_result "$status" "$message"
  exit 0
fi

rm -f "$W"
if ! head -c 8388608 /dev/urandom > "$W" 2>/dev/null; then
  status=FAIL
  message="canary: write failed (out of space or card write error?)"
else
  sync
  A=$(sha256sum "$W" | cut -d' ' -f1)
  B=$(cat "$W" | sha256sum | cut -d' ' -f1)
  if [ -n "$A" ] && [ "$A" != "$B" ]; then
    status=FAIL
    message="canary: readback hash mismatch (data corruption on write path)"
  fi
fi
rm -f "$W"
write_result "$status" "$message"
