#!/bin/sh
# mbusd entrypoint: start D-Bus + the Avahi mDNS responder (for the fork's
# mDNS/DNS-SD announcement), then run the gateway with the provided args.
#
# mDNS is announced on EVERY connected network interface. Interfaces can be
# attached/detached without a container restart (e.g. `docker network
# connect`), so this entrypoint keeps a background watcher that:
#   - recomputes the interface set from /proc/net/route
#   - on ANY change, rewrites /etc/avahi/avahi-daemon.conf (deduped, sorted)
#     and signals the running avahi-daemon (SIGHUP) to reload it.

set -u

AVAHI_PID_FILE=/run/avahi-daemon/pid
CFG=/etc/avahi/avahi-daemon.conf
CFG_TEMPLATE=/etc/mbusd-avahi.conf
WATCH_INTERVAL=2          # seconds between interface polls
AVAHI_SIGNAL_RETRIES=30   # wait up to ~30s for avahi to be up before warning

# ---------------------------------------------------------------------------
# Interface detection + config generation (deduped, sorted, comma-separated)
# ---------------------------------------------------------------------------
detect_interfaces() {
  # /proc/net/route lists active route interfaces (one line per route).
  # Take only the interface column, skip loopback, dedupe, sort.
  tail -n +2 /proc/net/route 2>/dev/null \
    | awk '{print $1}' \
    | grep -v '^lo$' \
    | grep -v '^$' \
    | sort -u
}

write_config() {
  NEW_IFACES="$1"
  if [ -n "$NEW_IFACES" ]; then
    IFACE_LIST=$(echo "$NEW_IFACES" | tr '\n' ',' | sed 's/,$//')
    sed "s/%INTERFACES%/$IFACE_LIST/" "$CFG_TEMPLATE" > "$CFG"
  else
    # No interfaces detected - drop the allow-interfaces line entirely so
    # Avahi uses its default (announce on all interfaces).
    sed "/%INTERFACES%/d" "$CFG_TEMPLATE" > "$CFG"
  fi
}

refresh_avahi() {
  NEW_IFACES=$(detect_interfaces)
  CURRENT_IFACES="$1"

  # No change -> nothing to do.
  if [ "$CURRENT_IFACES" = "$NEW_IFACES" ]; then
    return 1
  fi

  write_config "$NEW_IFACES"

  # Find the running avahi-daemon (from its pid file) and ask it to reload
  # its config so the new interface list takes effect without a restart.
  if [ -f "$AVAHI_PID_FILE" ]; then
    AVPID=$(cat "$AVAHI_PID_FILE" 2>/dev/null)
    if [ -n "$AVPID" ] && kill -0 "$AVPID" 2>/dev/null; then
      kill -HUP "$AVPID" 2>/dev/null
      echo "mdns: interface change detected -> reloaded avahi (now: ${NEW_IFACES:-all})"
    else
      echo "mdns: avahi pid file stale ($AVPID); restarting daemon"
      rm -f "$AVAHI_PID_FILE"
      avahi-daemon --daemonize --no-chroot --file="$CFG" \
        || echo "warning: avahi-daemon failed to restart; mDNS will be unavailable"
    fi
  else
    rm -f "$AVAHI_PID_FILE"
    avahi-daemon --daemonize --no-chroot --file="$CFG" \
      || echo "warning: avahi-daemon failed to start; mDNS will be unavailable"
  fi

  echo "$NEW_IFACES"
}

# ---------------------------------------------------------------------------
# Start D-Bus (required by Avahi)
# ---------------------------------------------------------------------------
mkdir -p /run/dbus
# Remove stale pid from a previous unclean shutdown - dbus refuses to start
# if /run/dbus/dbus.pid exists while the bus is not running.
if [ ! -S /run/dbus/system_bus_socket ]; then
  rm -f /run/dbus/dbus.pid /run/dbus/pid
  dbus-daemon --system --fork || echo "warning: dbus-daemon failed to start; mDNS will be unavailable"
fi

# ---------------------------------------------------------------------------
# Initial Avahi start
# ---------------------------------------------------------------------------
mkdir -p /run/avahi-daemon
INITIAL_IFACES=$(detect_interfaces)
write_config "$INITIAL_IFACES"
echo "mdns: initial interfaces: ${INITIAL_IFACES:-all}"

# Wait a moment for the dbus socket to be up (avahi connects to the bus).
i=0
while [ ! -S /run/dbus/system_bus_socket ] && [ "$i" -lt "$AVAHI_SIGNAL_RETRIES" ]; do
  sleep 1; i=$((i + 1))
done

if [ ! -S /run/avahi-daemon/socket ]; then
  rm -f /run/avahi-daemon/pid
  avahi-daemon --daemonize --no-chroot --file="$CFG" \
    || echo "warning: avahi-daemon failed to start; mDNS will be unavailable"
fi

# Avahi binds its socket a moment after forking; wait for it so mbusd's
# Avahi client (which connects on the D-Bus) never sees a dead/not-yet-up
# responder. Give up quietly after ~10s (mDNS is best-effort).
i=0
while [ ! -S /run/avahi-daemon/socket ] && [ "$i" -lt 10 ]; do
  sleep 1; i=$((i + 1))
done

# ---------------------------------------------------------------------------
# Background watcher: reload avahi on any NIC attach/detach.
# Runs alongside the gateway (which is exec'd below); it exits when the
# container stops (PID 1 signal propagation kills all processes).
# ---------------------------------------------------------------------------
(
  CUR="$INITIAL_IFACES"
  while :; do
    sleep "$WATCH_INTERVAL"
    RES=$(refresh_avahi "$CUR")
    if [ -n "$RES" ]; then
      CUR="$RES"
    fi
  done
) &

# Forward all arguments to the gateway binary.
exec /usr/bin/mbusd "$@"
