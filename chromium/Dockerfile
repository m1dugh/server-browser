# Chromium running headful against an X11 display, with the Chrome
# DevTools Protocol (remote debugging) enabled. No bundled VNC/display
# server here on purpose -- either this container starts its own Xvfb
# (default, headless/CDP-only use), or (when EXTERNAL_DISPLAY=1) a
# kasmvnc sidecar owns the display instead and this container connects
# to it as a plain X11 client, sharing the X11 socket under
# /tmp/.X11-unix via a volume.
#
# KasmVNC's Xvnc enforces X11 authentication (unlike the auth-less Xvfb
# started in the default case). Since every container in a pod shares
# the same network namespace/hostname, pointing XAUTHORITY at kasmvnc's
# own Xauthority file (shared via a second volume) is enough to
# authenticate -- but that file is always written 0600 owned by
# kasmvnc's own uid, unreadable by this image's own chromium user. The
# entrypoint copies it (as root, via su-exec below) before dropping to
# the chromium user, rather than requiring the two containers to somehow
# share a uid.
#
# No USER directive here -- unlike the headless/Xvfb-only case (where
# chromium always ran as the unprivileged chromium user from the start,
# baked into the image), the EXTERNAL_DISPLAY=1 case needs to start as
# root for that copy step. The actual runtime user is controlled by the
# chart's pod/container securityContext instead; the entrypoint itself
# drops to the chromium user via su-exec before exec'ing chromium in
# both cases.
FROM alpine:3.24

# Version is sourced from version.txt in this directory (single source
# of truth, shared with the CI pipeline that builds this image) and
# passed in as a build-arg -- no default here on purpose.
ARG CHROMIUM_VERSION

RUN apk add --no-cache \
      xvfb \
      dbus \
      su-exec \
      ttf-freefont \
      chromium=${CHROMIUM_VERSION}

RUN addgroup -S chromium && adduser -S chromium -G chromium \
    && mkdir -p /data /run/server-browser \
    && chown -R chromium:chromium /data /run/server-browser

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

ENV DEBUGGING_PORT=9222 \
    DISPLAY_WIDTH=1920 \
    DISPLAY_HEIGHT=1080 \
    DISPLAY_DEPTH=24 \
    DISPLAY=:1

VOLUME ["/data"]

ENTRYPOINT ["/entrypoint.sh"]
