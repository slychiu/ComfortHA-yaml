#!/bin/bash
# Ethernet port link + internet reachability check (v50a). READ-ONLY on the
# network stack: reads /sys/class/net/* only, plus outbound TCP connect probes
# addressed by IP (no DNS) -- never `ip link set`, ethtool, or anything that
# changes interface state. The fleet has a history of scripts fighting
# NetworkManager over interface ownership (bounce_nic.py is precedent and is
# deliberately NOT used here). Writes /config/.cytech_eth_result as
# {"ts","status","message","net","net_via","net_message"}, read by
# sensor.cytech_ethernet_result.
#
# Two independent facts, one owner-facing line each on the System Health screen:
#
#   status / message -- the PORT's link (end0, else eth0; the same fallback
#     first_boot.sh uses):
#       OK        carrier=1 -- the message carries the negotiated link speed
#       NO_LINK   the interface exists but reports no carrier (no cable, a dead
#                 port, or a dead far end)
#       NO_IFACE  neither end0 nor eth0 is present
#
#   net / net_message -- whether this system can actually reach the internet,
#     and through what:
#       port   reachable through THIS ETHERNET PORT -- the probe is source-bound
#              to the port's own address, so a success means this port's address
#              carried the traffic
#       other  the system is online, but through another connection (Wi-Fi, a
#              USB network adapter, ...); net_via names the interface the
#              successful connection actually left from
#       none   nothing on the internet could be reached from any connection
#
# Why the second line exists (v50a): the v48b row could report the port only, so
# a unit whose cable is unplugged -- or whose port is dead, the customer case
# behind v48b -- showed a warning and nothing else, with no way for the owner to
# see that the system itself was still online. Just as important the other way
# round: a lit port with no internet is not the port's fault, and the two lines
# now say so separately.
#
# Probes: TCP connect() to well-known public anycast endpoints. Addressed by IP
# only, so a DNS failure can never read as "no internet"; a completed connect
# means packets got there and back. First target that answers wins.
#
# Env overrides are for OFFLINE TESTING ONLY (the cytech_alert_mail.py
# convention); on-device they are unset. All are strictly read-only:
#   CY_ETH_DEV=usb0        check a specific interface (a name with no sysfs
#                          entry -> NO_IFACE)
#   CY_ETH_CARRIER=0       force the carrier value READ (never written), e.g. to
#                          exercise NO_LINK without unplugging the cable
#   CY_ETH_IP=none         force the port's address READ: "none" pretends this
#                          interface has no IPv4 address, another value is used
#                          as the address to bind the port probe to
#   CY_NET_TARGETS="host:port ..."  replace the probe target list, e.g.
#                          192.0.2.1:9 (TEST-NET-1, guaranteed unroutable) to
#                          exercise "none" without touching the real network
exec >> /config/cytech_update.log 2>&1
echo "=== cytech_check_eth.sh $(date) ==="

OUT=/config/.cytech_eth_result
# Public anycast endpoints, IP only (see the header). First answer wins.
NET_TARGETS="${CY_NET_TARGETS:-1.1.1.1:443 8.8.8.8:53 9.9.9.9:443 223.5.5.5:443}"
NET_TIMEOUT=3   # seconds per target, per probe pass

if [ -n "${CY_ETH_DEV:-}" ]; then
  DEV="$CY_ETH_DEV"
elif [ -d /sys/class/net/end0 ]; then
  DEV=end0
elif [ -d /sys/class/net/eth0 ]; then
  DEV=eth0
else
  DEV=""
fi

STATUS=NO_IFACE
SPEED_TXT=""
if [ -n "$DEV" ] && [ -d "/sys/class/net/$DEV" ]; then
  CARRIER=$(cat "/sys/class/net/$DEV/carrier" 2>/dev/null || echo 0)
  [ -n "${CY_ETH_CARRIER:-}" ] && CARRIER="$CY_ETH_CARRIER"
  if [ "$CARRIER" = "1" ]; then
    STATUS=OK
    SPEED=$(cat "/sys/class/net/$DEV/speed" 2>/dev/null || echo "")
    case "$SPEED" in
      ''|*[!0-9]*) SPEED_TXT=" link up." ;;
      *)           SPEED_TXT=" link up at $SPEED Mb/s." ;;
    esac
  else
    STATUS=NO_LINK
  fi
else
  DEV=""   # CY_ETH_DEV pointed at an interface that does not exist
fi

# The facts go in as arguments; python does the address lookup, both probes, the
# owner-facing wording and the JSON write in one pass.
python3 - "$OUT" "$STATUS" "$SPEED_TXT" "$DEV" "$NET_TARGETS" "$NET_TIMEOUT" <<'PYEOF'
import fcntl, json, os, socket, struct, sys, time


def iface_ip(name):
    """IPv4 address an interface holds, straight from the kernel (SIOCGIFADDR).
    None when it has none -- DHCP not done or failed, link without a lease."""
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        packed = struct.pack("256s", name[:15].encode())
        return socket.inet_ntoa(fcntl.ioctl(s.fileno(), 0x8915, packed)[20:24])
    except OSError:
        return None
    finally:
        s.close()


def friendly(name):
    """Owner-facing name for the connection that carried the traffic."""
    if name.startswith(("usb", "enx")):
        return "a USB network adapter"
    if name.startswith("wl"):
        return "Wi-Fi"
    return name


def reachable(bind_ip, targets, timeout):
    """Try each target in turn; returns the local source address of the first
    connection that completed, else None. With bind_ip set the socket is bound
    to that address first, so a success proves traffic could leave from it,
    i.e. through the interface that holds it."""
    for host, port in targets:
        s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        s.settimeout(timeout)
        try:
            if bind_ip:
                s.bind((bind_ip, 0))
            s.connect((host, port))
            return s.getsockname()[0]
        except OSError:
            pass
        finally:
            s.close()
    return None


def iface_owning(addr):
    """Name of the interface whose IPv4 is addr -- what the probe left from."""
    if not addr:
        return ""
    try:
        names = os.listdir("/sys/class/net")
    except OSError:
        return ""
    for name in names:
        if iface_ip(name) == addr:
            return name
    return ""


# TOP LEVEL -- everything above this line is importable for offline unit tests.
out, status, speed_txt, dev, targets, timeout = sys.argv[1:7]
timeout = float(timeout)

parsed = []
for tok in targets.split():
    if ":" not in tok:
        continue
    host, port = tok.rsplit(":", 1)
    try:
        parsed.append((host, int(port)))
    except ValueError:
        continue

ip = None
if dev:
    forced = os.environ.get("CY_ETH_IP")
    if forced == "none":
        ip = None
    elif forced:
        ip = forced
    else:
        ip = iface_ip(dev)
    if ip and ip.startswith("169.254."):   # link-local == no DHCP lease
        ip = None

net, net_via = "none", ""
if status == "OK" and ip and reachable(ip, parsed, timeout):
    net, net_via = "port", dev
else:
    src = reachable(None, parsed, timeout)
    if src:
        net, net_via = "other", iface_owning(src)

if status == "NO_IFACE":
    message = "The Ethernet port was not found on this system. Please contact support@cytech.biz."
elif status == "OK":
    message = "Ethernet OK:" + speed_txt
    if not ip:
        message += " No network address has been assigned to this system yet."
else:
    message = ("The Ethernet port has no connection. Check that the cable is fully "
               "inserted at both ends; if it still shows no connection, contact "
               "support@cytech.biz.")

if net == "port":
    net_message = "Internet connection OK: reachable through this Ethernet port."
elif net == "other":
    if net_via:
        desc = friendly(net_via)
        via = desc if desc == net_via else "%s (%s)" % (desc, net_via)
    else:
        via = "another connection"
    net_message = "Internet connection OK: this system is online through %s." % via
else:
    net_message = "No internet connection detected."
    if status == "OK" and not ip:
        net_message += " The Ethernet port has a link, but this system has no network address yet."
    elif status == "OK":
        net_message += (" The Ethernet port has a link, so the problem is further "
                        "along the network (router or internet service).")

with open(out, "w") as f:
    json.dump({"ts": int(time.time()), "status": status, "message": message,
               "net": net, "net_via": net_via, "net_message": net_message}, f)

print("eth: %s ip=%s net=%s via=%s :: %s :: %s"
      % (status, ip or "-", net, net_via or "-", message, net_message))
PYEOF
