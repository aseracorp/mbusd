#!/bin/sh
# mbusd entrypoint: start D-Bus + the Avahi mDNS responder (for the fork's
# mDNS/DNS-SD announcement), then run the gateway with the provided args.
#
# mDNS is announced on EVERY connected network interface (not only the
# default-route one). In multi-homed Docker containers (e.g. a compose net
# plus a user-defined network shared with modbus2mqtt) this makes the
# _modbus-tcp._tcp service reachable on all of them.

# --- Start D-Bus (required by Avahi) ---
mkdir -p /run/dbus
if [ ! -S /run/dbus/system_bus_socket ]; then
  dbus-daemon --system --fork || echo "warning: dbus-daemon failed to start; mDNS will be unavailable"
fi

# --- Build an Avahi config announcing on ALL connected interfaces ---
# Read interfaces from /proc/net/route (no 'ip' dependency on Alpine).
IFS='
'
INTERFACES=""
for l in $(tail -n +2 /proc/net/route 2>/dev/null); do
  iface=$(echo "$l" | awk '{print $1}')
  # Destination 00000000 = default route => this is a real network iface
  case "$iface" in
    lo) continue ;;
  esac
  if [ -n "$iface" ]; then
    if [ -z "$INTERFACES" ]; then INTERFACES="$iface"; else INTERFACES="$INTERFACES,$iface"; fi
  fi
done
unset IFS

CFG=/etc/avahi/avahi-daemon.conf
if [ -n "$INTERFACES" ]; then
  sed "s/%INTERFACES%/$INTERFACES/" /etc/mbusd-avahi.conf > "$CFG"
  echo "mdns: announcing on interfaces: $INTERFACES"
else
  # No interfaces detected - drop the allow-interfaces line (Avahi default = all)
  sed "/%INTERFACES%/d" /etc/mbusd-avahi.conf > "$CFG"
  echo "mdns: announcing on all interfaces (none detected by name)"
fi

# --- Start the Avahi daemon ---
if [ ! -S /var/run/avahi-daemon/socket ]; then
  avahi-daemon --daemonize --no-chroot --file="$CFG" || echo "warning: avahi-daemon failed to start; mDNS will be unavailable"
fi

# Forward all arguments to the gateway binary.
exec /usr/bin/mbusd "$@"
