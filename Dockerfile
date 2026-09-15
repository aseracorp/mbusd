FROM alpine:latest AS build
RUN apk add --no-cache alpine-sdk cmake linux-headers avahi-dev
COPY . /mbusd
WORKDIR /mbusd/build
RUN cmake -DCMAKE_INSTALL_PREFIX=/usr .. && make && make install

FROM alpine:latest AS scratch
ENV QEMU_EXECVE=1
RUN apk add --no-cache libc6-compat avahi-client avahi-daemon dbus
COPY --from=build /usr/bin/mbusd /usr/bin/mbusd
# Start the Avahi mDNS responder for the mDNS/DNS-SD announcement, then run
# the gateway (defaults: foreground, log to stdout, /dev/ttyS0 @ 9600 8N1)
CMD ["sh", "-c", "avahi-daemon --daemonize --no-chroot; exec /usr/bin/mbusd -d -L - -p /dev/ttyS0 -s 9600 -m 8N1"]
