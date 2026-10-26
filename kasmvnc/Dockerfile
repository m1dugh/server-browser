# KasmVNC display server for the server-browser pod: owns the X11
# display (Xvnc, not Xvfb) and serves it over KasmVNC's single-port
# HTML5/websocket client. Nothing else runs in this container -- the
# chromium container in the pod connects to this display as a plain
# X11 client, sharing the X11 socket directory via a volume.
#
# Based on kasmweb/core-alpine-323, Kasm's own Alpine 3.23 "core" image
# (KasmVNC + XFCE, no bundled browser). Unlike Kasm's own app images
# (e.g. kasmweb/chromium), which are Ubuntu-based and ship a
# `single-application-xfce-perchannel-xml` config for a borderless,
# single-workspace, panel-less desktop, no such config exists upstream
# for the Alpine core image -- xfce-single-app/*.xml here is authored
# from scratch for this image, adapted from Kasm's own Ubuntu-based
# reference files (see AGENTS.md for details), not copied from
# anywhere upstream.
#
# The panel is suppressed via config (xfce4-session.xml drops it from
# the session's client list), not apk removal -- xfce4-panel is only
# removable as a dependency of the xfce4 meta-package, and actually
# uninstalling it cascades into removing xfwm4/xfdesktop/xfce4-session
# themselves (verified: `apk del xfce4-panel` is blocked outright, and
# `apk del xfce4` to work around it takes the whole desktop environment
# down with it). Not starting the panel achieves the same visible
# result without touching the package set at all.
ARG BASE_TAG
FROM kasmweb/core-alpine-323:${BASE_TAG}

USER root

COPY xfce-single-app/xfwm4.xml xfce-single-app/xfce4-desktop.xml \
     xfce-single-app/xfce4-session.xml \
     /home/kasm-default-profile/.config/xfce4/xfconf/xfce-perchannel-xml/

RUN chown -R 1000:0 /home/kasm-default-profile

USER 1000
