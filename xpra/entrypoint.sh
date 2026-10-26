#!/bin/sh
set -eu

until [ -S "/tmp/.X11-unix/X${DISPLAY#:}" ]; do
  echo "waiting for X server on ${DISPLAY} to be up..."
  sleep 1
done

if [ -n "${XPRA_PASSWORD:-}" ]; then
  PASSWORD_FILE="$(mktemp)"
  printf '%s' "${XPRA_PASSWORD}" > "${PASSWORD_FILE}"
  BIND_WS="0.0.0.0:${XPRA_PORT},auth=file,filename=${PASSWORD_FILE},client-username=no,verify-username=no"
else
  BIND_WS="0.0.0.0:${XPRA_PORT},auth=allow,client-username=no,verify-username=no"
fi

mkdir -p /run/server-browser
touch /run/server-browser/ready

exec xpra shadow "${DISPLAY}" \
  --bind=none \
  --bind-ws="${BIND_WS}" \
  --html=on \
  --daemon=no \
  --pidfile= \
  --dbus=no \
  --sharing=yes
