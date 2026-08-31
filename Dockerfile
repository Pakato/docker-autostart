FROM alpine:3.20

# Populated by the build workflow (docker/metadata-action) so the published
# image carries provenance you can read back with `docker inspect`.
ARG VERSION=dev
ARG REVISION=unknown
ARG CREATED=unknown

LABEL org.opencontainers.image.title="docker-autostart" \
      org.opencontainers.image.description="Watchdog that brings back Docker containers stuck in created / exited / restarting." \
      org.opencontainers.image.source="https://github.com/Pakato/docker-autostart" \
      org.opencontainers.image.url="https://github.com/Pakato/docker-autostart" \
      org.opencontainers.image.licenses="MIT" \
      org.opencontainers.image.version="${VERSION}" \
      org.opencontainers.image.revision="${REVISION}" \
      org.opencontainers.image.created="${CREATED}"

ENV AUTOSTART_VERSION="${VERSION}"

RUN apk add --no-cache docker-cli curl tzdata

COPY autostart.sh /usr/local/bin/autostart
RUN chmod +x /usr/local/bin/autostart

VOLUME /var/lib/autostart

# Exposes its own health so autoheal can look after the watchdog.
HEALTHCHECK --interval=60s --timeout=5s --start-period=20s --retries=3 \
    CMD sh -c '[ $(( $(date +%s) - $(stat -c %Y /tmp/autostart.alive) )) -lt 180 ]'

ENTRYPOINT ["/usr/local/bin/autostart"]
