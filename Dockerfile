FROM alpine:latest AS build
RUN apk add --no-cache alpine-sdk cmake linux-headers
# mDNS/DNS-SD announcement support (fork feature)
RUN apk add --no-cache avahi-dev
COPY . /mbusd
WORKDIR /mbusd/build
RUN cmake -DCMAKE_INSTALL_PREFIX=/usr .. && make && make install

FROM alpine:latest AS scratch
ENV QEMU_EXECVE=1
RUN apk add --no-cache libc6-compat avahi
COPY --from=build /usr/bin/mbusd /usr/bin/mbusd
# Entrypoint starts dbus + avahi-daemon (for the mDNS announcement), then
# execs the gateway. Preserves upstream's "override args via command" contract.
COPY docker-entrypoint.sh /usr/bin/docker-entrypoint.sh
RUN chmod +x /usr/bin/docker-entrypoint.sh
ENTRYPOINT ["/usr/bin/docker-entrypoint.sh"]
# Default args (override via `command` / docker run args):
#   -d foreground | -L - log to stdout | -p serial port | -s baud | -m parity
CMD ["-d", "-L", "-", "-p", "/dev/ttyS0", "-s", "9600", "-m", "8N1"]
