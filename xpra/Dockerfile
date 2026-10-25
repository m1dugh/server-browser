# xpra shadowing an existing X11 display (created by the chromium
# container, shared via /tmp/.X11-unix) and serving it over its HTML5
# client. Does not start/own any application itself.
#
# Unlike upstream's packaging, Alpine splits the HTML5 client out into
# its own xpra-webclient package (versioned independently of xpra
# itself -- e.g. 17.1-r0 against xpra 6.4.3-r0), so it's pulled in
# unpinned here rather than tied to XPRA_VERSION.
FROM alpine:3.24

# Version is sourced from version.txt in this directory (single source
# of truth, shared with the CI pipeline that builds this image) and
# passed in as a build-arg -- no default here on purpose.
ARG XPRA_VERSION

RUN apk add --no-cache \
      xpra=${XPRA_VERSION} \
      xpra-webclient

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

ENV XPRA_PORT=10000 \
    DISPLAY=:1

ENTRYPOINT ["/entrypoint.sh"]
