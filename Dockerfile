FROM alpine:latest AS build
RUN apk add --no-cache alpine-sdk cmake linux-headers
# mDNS/DNS-SD announcement support (fork feature)
RUN apk add --no-cache avahi-dev
COPY . /mbusd
WORKDIR /mbusd/build
RUN cmake -DCMAKE_INSTALL_PREFIX=/usr .. && make && make install

FROM alpine:latest AS scratch
ENV QEMU_EXECVE=1
# dbus: system D-Bus daemon (required by Avahi; provides dbus-daemon)
# avahi: the mDNS responder daemon (avahi-daemon)
# libc6-compat/gcompat: glibc shims for mbusd's binary
RUN apk add --no-cache libc6-compat gcompat dbus avahi
COPY --from=build /usr/bin/mbusd /usr/bin/mbusd
# Entrypoint starts dbus + avahi-daemon (for the mDNS announcement), then
# execs the gateway. Preserves upstream's "override args via command" contract.
COPY docker-entrypoint.sh /usr/bin/docker-entrypoint.sh
# Avahi daemon config template - announces _modbus-tcp._tcp on ALL connected
# interfaces (entrypoint fills in %INTERFACES% from the container's NICs).
COPY docker/avahi-daemon.conf.template /etc/mbusd-avahi.conf
RUN chmod +x /usr/bin/docker-entrypoint.sh
ENTRYPOINT ["/usr/bin/docker-entrypoint.sh"]
# Default args (override via `command` / docker run args):
#   -d foreground | -L - log to stdout | -p serial port | -s baud | -m parity
CMD ["-d", "-L", "-", "-p", "/dev/ttyS0", "-s", "9600", "-m", "8N1"]
