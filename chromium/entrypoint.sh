#!/bin/sh
set -eu

# Block until the X server on ${DISPLAY} actually accepts a connection
# (real handshake via xdpyinfo, as the chromium user), not merely until
# its socket file exists: a stale socket left in a pod-lifetime emptyDir,
# or an X server that is still starting, makes chromium exit with
# "Missing X server or $DISPLAY". `prepare` runs before every attempt, and
# `extra_check` adds a mode-specific condition on top of the handshake.
wait_for_x() {
  waited=0
  until prepare && su-exec chromium xdpyinfo -display "${DISPLAY}" >/dev/null 2>&1 && extra_check; do
    if [ $((waited % 30)) -eq 0 ]; then
      echo "waiting for X server on ${DISPLAY} to accept connections (${waited}s)..."
    fi
    waited=$((waited + 1))
    sleep 1
  done
  echo "X server on ${DISPLAY} is up"
}

if [ "${EXTERNAL_DISPLAY:-0}" = "1" ]; then
  # A sidecar (kasmvnc) owns the X11 display -- wait for it instead of
  # starting our own Xvfb. kasmvnc is started with XAUTHORITY pointed at
  # a path on a volume shared (read-only here) with this container; since
  # all containers in a pod share the same network namespace (and so the
  # same hostname), the X11 authority entries kasmvnc wrote under its own
  # hostname resolve correctly for this container too -- no cookie
  # extraction or local xauth database needed.
  #
  # kasmvnc's Xauthority is always written 0600, owned by its own
  # (different) uid -- unreadable by the chromium user this entrypoint
  # drops to below. Copy it to a chromium-owned path while still root.
  # Done on every attempt, since kasmvnc rewrites it when it restarts.
  prepare() {
    [ -s /run/server-browser/x11-auth/Xauthority ] || return 1
    cp /run/server-browser/x11-auth/Xauthority /run/server-browser/xauthority
    chown chromium:chromium /run/server-browser/xauthority
    export XAUTHORITY=/run/server-browser/xauthority
  }

  # The X server accepts connections before kasmvnc's session has started
  # the window manager (xfwm4). A window mapped before then is never put in
  # the fullscreen state chromium asked for (--start-fullscreen), so it
  # keeps a title bar. Wait for an EWMH-compliant window manager as well.
  extra_check() {
    su-exec chromium xprop -root _NET_SUPPORTING_WM_CHECK 2>/dev/null | grep -q "window id"
  }
else
  su-exec chromium Xvfb "${DISPLAY}" -screen 0 "${DISPLAY_WIDTH}x${DISPLAY_HEIGHT}x${DISPLAY_DEPTH}" -nolisten tcp &
  XVFB_PID=$!

  trap 'kill "${XVFB_PID}" 2>/dev/null' EXIT INT TERM

  prepare() { :; }
  extra_check() { :; }
fi

wait_for_x

touch /run/server-browser/ready

# Drop to the chromium user and exec "$@" (an `env ...` argument list).
# su-exec discards every capability on the uid change, so when the container
# was granted CAP_SYS_RESOURCE (chart default) chromium could never lower its
# renderers' oom_score_adj and logged "Failed to adjust OOM score of
# renderer ... Permission denied" on every tab switch. capsh keeps exactly
# that one capability across the uid change as an ambient capability; when
# the container wasn't granted it, fall back to plain su-exec.
launch() {
  if capsh --has-p=cap_sys_resource >/dev/null 2>&1; then
    exec capsh --keep=1 --user=chromium \
      --inh=cap_sys_resource --addamb=cap_sys_resource \
      --shell=/usr/bin/env -- "$@"
  fi
  exec su-exec chromium env "$@"
}

# No D-Bus daemon runs in this container, so every bus lookup logs a
# connection error. The session bus address is pointed at `disabled:` (the
# project's chosen setting, passed through `env` so it survives the
# privilege drop). Verified against chromium 155: libdbus does not know
# that transport, so the errors are still logged -- this only makes the
# failure deterministic (empty address -> unknown address type either way);
# silencing them takes a real bus or a lower --log-level.
# GCM: chromium keeps retrying a registration that Google answers with
# DEPRECATED_ENDPOINT (the legacy endpoint is retired), logging an error
# every few minutes. --disable-features=GCM does not stop it. The three
# --gcm-* switches send the registration, check-in and MCS endpoints to
# 127.0.0.1:9 (always refused), so chromium can never check in and the
# error is no longer logged. Side effects: web push subscription,
# chrome.gcm and sync invalidations cannot work -- unused here.
launch DBUS_SESSION_BUS_ADDRESS=disabled: ${XAUTHORITY:+XAUTHORITY="${XAUTHORITY}"} chromium-browser \
  --no-sandbox \
  --disable-gpu \
  --disable-dev-shm-usage \
  --user-data-dir=/data \
  --remote-debugging-port="${DEBUGGING_PORT}" \
  --remote-debugging-address=0.0.0.0 \
  --no-first-run \
  --disable-background-networking \
  --disable-sync \
  --disable-features=GCM \
  --gcm-registration-url=http://127.0.0.1:9/register \
  --gcm-checkin-url=http://127.0.0.1:9/checkin \
  --gcm-mcs-endpoint=127.0.0.1:9 \
  --window-size="${DISPLAY_WIDTH},${DISPLAY_HEIGHT}" \
  ${EXTERNAL_DISPLAY:+--start-fullscreen} \
  about:blank
