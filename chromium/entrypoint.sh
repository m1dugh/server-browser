#!/bin/sh
set -eu

Xvfb "${DISPLAY}" -screen 0 "${DISPLAY_WIDTH}x${DISPLAY_HEIGHT}x${DISPLAY_DEPTH}" -nolisten tcp &
XVFB_PID=$!

trap 'kill "${XVFB_PID}" 2>/dev/null' EXIT INT TERM

until [ -S "/tmp/.X11-unix/X${DISPLAY#:}" ]; do
  echo "waiting for X server on ${DISPLAY} to be up..."
  sleep 1
done

touch /run/server-browser/ready

exec chromium-browser \
  --no-sandbox \
  --disable-gpu \
  --disable-dev-shm-usage \
  --user-data-dir=/data \
  --remote-debugging-port="${DEBUGGING_PORT}" \
  --remote-debugging-address=0.0.0.0 \
  --no-first-run \
  --window-size="${DISPLAY_WIDTH},${DISPLAY_HEIGHT}" \
  about:blank
