# xpra shadowing an existing X11 display (created by the chromium
# container, shared via /tmp/.X11-unix) and serving it over its built-in
# HTML5 client. Does not start/own any application itself.
#
# The HTML5 client has been a hard dependency of the main xpra package
# since v5.1.5, so no separate xpra-html5/xpra-webclient package is
# needed.
FROM alpine:3.24

# Version is sourced from version.txt in this directory (single source
# of truth, shared with the CI pipeline that builds this image) and
# passed in as a build-arg -- no default here on purpose.
ARG XPRA_VERSION

RUN apk add --no-cache \
      xpra=${XPRA_VERSION}

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

ENV XPRA_PORT=10000 \
    DISPLAY=:1

ENTRYPOINT ["/entrypoint.sh"]
