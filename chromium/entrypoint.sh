#!/bin/sh
set -eu

if [ "${EXTERNAL_DISPLAY:-0}" = "1" ]; then
  # A sidecar (kasmvnc) owns the X11 display -- wait for its socket
  # instead of starting our own Xvfb. kasmvnc is started with
  # XAUTHORITY pointed at a path on a volume shared (read-only here)
  # with this container; since all containers in a pod share the same
  # network namespace (and so the same hostname), the X11 authority
  # entries kasmvnc wrote under its own hostname resolve correctly for
  # this container too -- no cookie extraction or local xauth database
  # needed.
  until [ -S "/tmp/.X11-unix/X${DISPLAY#:}" ]; do
    echo "waiting for X server on ${DISPLAY} to be up..."
    sleep 1
  done

  until [ -s /run/server-browser/x11-auth/Xauthority ]; do
    echo "waiting for X11 auth cookie to be up..."
    sleep 1
  done

  # kasmvnc's Xauthority is always written 0600, owned by its own
  # (different) uid -- unreadable by the chromium user this entrypoint
  # drops to below. Copy it to a chromium-owned path while still root.
  cp /run/server-browser/x11-auth/Xauthority /run/server-browser/xauthority
  chown chromium:chromium /run/server-browser/xauthority
  export XAUTHORITY=/run/server-browser/xauthority
else
  su-exec chromium Xvfb "${DISPLAY}" -screen 0 "${DISPLAY_WIDTH}x${DISPLAY_HEIGHT}x${DISPLAY_DEPTH}" -nolisten tcp &
  XVFB_PID=$!

  trap 'kill "${XVFB_PID}" 2>/dev/null' EXIT INT TERM

  until [ -S "/tmp/.X11-unix/X${DISPLAY#:}" ]; do
    echo "waiting for X server on ${DISPLAY} to be up..."
    sleep 1
  done
fi

touch /run/server-browser/ready

exec su-exec chromium env ${XAUTHORITY:+XAUTHORITY="${XAUTHORITY}"} chromium-browser \
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
