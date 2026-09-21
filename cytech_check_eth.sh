#!/bin/bash
# Ethernet port link check (v48b). READ-ONLY on the network stack: reads
# /sys/class/net/* only and never runs `ip link set`, ethtool or anything that
# changes interface state -- the fleet has a history of scripts fighting
# NetworkManager over interface ownership (bounce_nic.py is precedent and is
# deliberately NOT used here). Writes /config/.cytech_eth_result as
# {"ts","status","message"}, read by sensor.cytech_ethernet_result.
#
# Interface resolution matches first_boot.sh's fallback: end0, else eth0.
#   OK        carrier=1 -- message includes the negotiated link speed
#   NO_LINK   interface exists but reports no carrier -- the message names any
#             OTHER physical interface that has link ("a USB network adapter",
#             "Wi-Fi", ...) so the owner's screen explains how the unit is
#             still online
#   NO_IFACE  neither end0 nor eth0 present
#
# The customer case behind v48b: a new unit shipped with a dead onboard
# Ethernet port (no link LEDs across several proven-good switches/cables;
# NetworkManager refused activation with "device has no carrier") and the
# owner was limping along on a USB NIC, with nothing on the unit to show it.
exec >> /config/cytech_update.log 2>&1
echo "=== cytech_check_eth.sh $(date) ==="

# Env overrides are for OFFLINE TESTING ONLY (the cytech_alert_mail.py
# convention); on-device they are unset. Both are strictly read-only:
#   CY_ETH_DEV=usb0    check a specific interface (a name with no sysfs entry
#                      -> NO_IFACE)
#   CY_ETH_CARRIER=0   force the carrier value READ (never written) --
#                      exercises the NO_LINK branch without unplugging
OUT=/config/.cytech_eth_result

friendly() {   # owner-facing name for a working alternative interface
  case "$1" in
    usb*|enx*) echo "a USB network adapter" ;;
    wl*)       echo "Wi-Fi" ;;
    *)         echo "$1" ;;
  esac
}

write_result() {
  python3 - "$OUT" "$1" "$2" <<'PYEOF'
import json, sys, time
with open(sys.argv[1], "w") as f:
    json.dump({"ts": int(time.time()), "status": sys.argv[2], "message": sys.argv[3]}, f)
PYEOF
  echo "eth: $1"
}

if [ -n "${CY_ETH_DEV:-}" ]; then
  DEV="$CY_ETH_DEV"
elif [ -d /sys/class/net/end0 ]; then
  DEV=end0
elif [ -d /sys/class/net/eth0 ]; then
  DEV=eth0
else
  DEV=""
fi

if [ -z "$DEV" ] || [ ! -d "/sys/class/net/$DEV" ]; then
  write_result NO_IFACE "The Ethernet port was not found on this system. Please contact support@cytech.biz."
  exit 0
fi

CARRIER=$(cat "/sys/class/net/$DEV/carrier" 2>/dev/null || echo 0)
[ -n "${CY_ETH_CARRIER:-}" ] && CARRIER="$CY_ETH_CARRIER"

if [ "$CARRIER" = "1" ]; then
  SPEED=$(cat "/sys/class/net/$DEV/speed" 2>/dev/null || echo "")
  case "$SPEED" in
    ''|*[!0-9]*) SPEED_TXT=" link up." ;;
    *)           SPEED_TXT=" link up at $SPEED Mb/s." ;;
  esac
  write_result OK "Ethernet OK:${SPEED_TXT}"
  exit 0
fi

# No carrier -- name any OTHER physical interface that has link, so the owner's
# screen explains how the unit is still online. The device-symlink test skips
# virtual interfaces (docker0, veth*, tailscale0, hassio), whose carrier would
# otherwise produce a false "online via".
OTHER=""
for iface in /sys/class/net/*; do
  name=$(basename "$iface")
  case "$name" in lo|end0|eth0) continue ;; esac   # end0/eth0 == the same port
  [ -e "$iface/device" ] || continue
  c=$(cat "$iface/carrier" 2>/dev/null || echo 0)
  [ "$c" = "1" ] && { OTHER="$name"; break; }
done

if [ -n "$OTHER" ]; then
  DESC=$(friendly "$OTHER")
  if [ "$DESC" = "$OTHER" ]; then VIA="$OTHER"; else VIA="$DESC ($OTHER)"; fi
  write_result NO_LINK "The Ethernet port has no connection. This system is online via ${VIA}. If the port should be working, please contact support@cytech.biz."
else
  write_result NO_LINK "The Ethernet port has no connection. Check that the cable is fully inserted at both ends; if it still shows no connection, contact support@cytech.biz."
fi
