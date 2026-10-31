#!/bin/sh
set -eu

# Block until the X server on ${DISPLAY} actually accepts a connection
# (real handshake via xdpyinfo, as the chromium user), not merely until
# its socket file exists: a stale socket left in a pod-lifetime emptyDir,
# or an X server that is still starting, makes chromium exit with
# "Missing X server or $DISPLAY". `prepare` runs before every attempt.
wait_for_x() {
  waited=0
  until prepare && su-exec chromium xdpyinfo -display "${DISPLAY}" >/dev/null 2>&1; do
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
else
  su-exec chromium Xvfb "${DISPLAY}" -screen 0 "${DISPLAY_WIDTH}x${DISPLAY_HEIGHT}x${DISPLAY_DEPTH}" -nolisten tcp &
  XVFB_PID=$!

  trap 'kill "${XVFB_PID}" 2>/dev/null' EXIT INT TERM

  prepare() { :; }
fi

wait_for_x

touch /run/server-browser/ready

# No D-Bus daemon runs in this container. Pointing the session bus at the
# `disabled:` transport stops chromium from logging a connection error for
# every bus lookup (UPower, notifications, ...); passed through `env` so it
# survives su-exec.
exec su-exec chromium env DBUS_SESSION_BUS_ADDRESS=disabled: ${XAUTHORITY:+XAUTHORITY="${XAUTHORITY}"} chromium-browser \
  --no-sandbox \
  --disable-gpu \
  --disable-dev-shm-usage \
  --user-data-dir=/data \
  --remote-debugging-port="${DEBUGGING_PORT}" \
  --remote-debugging-address=0.0.0.0 \
  --no-first-run \
  --window-size="${DISPLAY_WIDTH},${DISPLAY_HEIGHT}" \
  ${EXTERNAL_DISPLAY:+--start-maximized} \
  about:blank
