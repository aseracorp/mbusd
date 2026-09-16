#!/bin/sh
# mbusd entrypoint: start the Avahi mDNS responder (for the fork's
# mDNS/DNS-SD announcement), then run the gateway with the provided args.
#
# This preserves upstream's "override args via command" contract:
#   docker run <image> -d -L - -p /dev/ttyModbus -s 38400 -m 8N1
# becomes -> /usr/bin/mbusd -d -L - -p /dev/ttyModbus -s 38400 -m 8N1

# --- Start D-Bus (required by Avahi) ---
# dbus-daemon --system needs /run/dbus to exist before it can bind its
# socket; in a minimal image this directory is not created by a package
# post-install, so create it explicitly.
mkdir -p /run/dbus
# Only start if not already running (idempotent restarts). pgrep is not
# guaranteed to exist on Alpine, so rely on the pid file / dbus-send probe.
if [ ! -S /run/dbus/system_bus_socket ]; then
  dbus-daemon --system --fork || echo "warning: dbus-daemon failed to start; mDNS will be unavailable"
fi

# --- Start the Avahi daemon (mDNS responder) ---
# Only start if not already running (idempotent restarts).
if [ ! -S /var/run/avahi-daemon/socket ]; then
  avahi-daemon --daemonize --no-chroot || echo "warning: avahi-daemon failed to start; mDNS will be unavailable"
fi

# Forward all arguments to the gateway binary.
exec /usr/bin/mbusd "$@"
