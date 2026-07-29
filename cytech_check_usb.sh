#!/bin/bash
# USB SD-card-reader-detected-at-boot check. Live-verified 2026-07-29 on
# cytech.local: `lsusb` lists only the internal DWC OTG root hub (Bus 001
# Device 001, idVendor=1d6b) when nothing is plugged into the USB port; a
# USB SD card reader with a card inserted enumerates as a usb-storage block
# device under /sys/block (sda, sdb, ...) alongside the internal mmcblk0.
# Checking for that block device catches both "nothing plugged in" and
# "port/reader/card isn't actually working" in one signal, unlike lsusb
# device-count alone which would also pass for a USB device that enumerates
# but never becomes usable storage.
#
# Unlike cytech_check_hdmi.sh, this check IS meant to fail the pre-ship
# test: a working USB port + reader is a hard setup requirement, not just
# nice-to-know -- this fleet has a history of both a firmware otg_mode bug
# (fixed v21) and per-unit dead USB ports (e.g. cytech.local's own D5
# hardware defect), so a missing USB device here is a real defect signal,
# not an optional accessory like a monitor.
exec >> /config/cytech_update.log 2>&1
echo "=== cytech_check_usb.sh $(date) ==="

USB_BLOCK=$(ls /sys/block 2>/dev/null | grep -E '^sd[a-z]' | head -1)

if [ -n "$USB_BLOCK" ]; then
  MSG="USB OK: storage device detected ($USB_BLOCK)"
else
  MSG="No USB storage device detected"
fi

jq -n --arg ts "$(date +%s)" --arg msg "$MSG" '{ts: $ts, message: $msg}' > /config/.cytech_usb_result
