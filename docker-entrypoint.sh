#!/bin/sh
# mbusd entrypoint: start the Avahi mDNS responder (for the fork's
# mDNS/DNS-SD announcement), then run the gateway with the provided args.
#
# This preserves upstream's "override args via command" contract:
#   docker run <image> -d -L - -p /dev/ttyModbus -s 38400 -m 8N1
# becomes -> /usr/bin/mbusd -d -L - -p /dev/ttyModbus -s 38400 -m 8N1

# Start D-Bus (needed by Avahi), then the Avahi daemon. Failures here are
# non-fatal (mDNS is an optional fork feature; the gateway must still run).
dbus-daemon --system --fork 2>/dev/null || true
avahi-daemon --daemonize --no-chroot 2>/dev/null || true

# Forward all arguments to the gateway binary.
exec /usr/bin/mbusd "$@"
