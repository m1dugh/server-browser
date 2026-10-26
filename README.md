# server-browser

A browser running on a server, not on your laptop — reachable and fully
interactive from anywhere, over nothing but HTTP(S).

## Goal

The main use case for this project is giving an **AI agent** a real,
persistent browser to drive: something with its own IP, its own cookies/
session state, and its own debugging interface, that keeps running and
keeps its state between agent runs instead of spinning a throwaway
headless browser up and down. A human can also open the same session in
a normal browser tab to watch or take over at any point — useful any
time a step needs a human in the loop (solving a captcha, approving a
login, inspecting something visually) without ever needing desktop
access to the machine the browser actually runs on.

Concretely, this chart deploys one browser session that exposes two
independent things to the outside world:

- A **Chrome DevTools Protocol (CDP)** endpoint — the interface
  automation tooling (Puppeteer, Playwright, an agent's own browser-use
  tooling, etc.) drives the browser through.
- An **interactive, streamed view** of that same browser, reachable from
  a plain web browser tab on a laptop — no VNC client, no desktop
  software, just a URL.

Both point at the exact same browser instance and the exact same page —
whatever one side does (navigate, click, fill a form) is immediately
visible on the other.

## Connection chain

```
┌─────────────────────┐         ┌──────────────────────────────────────────────────────────┐
│       laptop         │         │                      kubernetes pod                        │
│                       │         │                                                            │
│  ┌─────────────────┐  │  HTTP   │  ┌──────────┐   X11 socket    ┌────────────────────────┐  │
│  │ web browser tab  │──┼────────┼─▶│ kasmvnc  │◀───────────────▶│  chromium              │  │
│  │ (KasmVNC HTML5)   │  │         │  │ (owns    │  (shared volume) │  headful, connects to  │  │
│  └─────────────────┘  │         │  │  display) │                  │  kasmvnc's display    │  │
│                       │         │  └──────────┘                  └───────────┬────────────┘  │
│  ┌─────────────────┐  │  HTTP   │  ┌───────────┐        loopback-only CDP   │                │
│  │ agent / CDP      │──┼────────┼─▶│ debug-fwd │◀───────────────────────────┘                │
│  │ client (CDP)     │  │         │  │  (socat)  │                                             │
│  └─────────────────┘  │         │  └───────────┘                                             │
└─────────────────────┘         └──────────────────────────────────────────────────────────┘
```

The pod runs three containers side by side, sharing the same network
namespace (so `localhost` inside the pod means "any of these three
containers") and, for two of them, the same X11 display:

1. **`kasmvnc`** — owns the pod's X11 display: a real, virtual X server
   (KasmVNC's own `Xvnc`, not a bare display like Xvfb) with its web/
   websocket client built in. Open its URL in any web browser and you
   get a live, interactive view of whatever is rendering into that
   display — mouse and keyboard input included — with nothing to
   install on the viewing end. It launches before `chromium` and never
   runs any application itself; it only owns the display the `chromium`
   container connects into.
2. **`chromium`** — a real, headful Chromium browser, connecting to the
   `kasmvnc` container's display as a plain X11 client over a shared
   volume mounted at `/tmp/.X11-unix` in both (plus a second shared
   volume carrying the X11 authentication cookie `kasmvnc` generates,
   since KasmVNC's `Xvnc` enforces X11 auth unlike a bare Xvfb). It is
   started with Chrome DevTools Protocol enabled
   (`--remote-debugging-port=<port>`), which is what lets an external
   client control it: open tabs, navigate, click, read the DOM,
   intercept network traffic, take screenshots, and so on — the same
   protocol tools like Puppeteer/Playwright already speak. Its profile
   directory (cookies, local storage, logged-in sessions, extensions)
   can be persisted on a volume, so the same logged-in browser session
   survives a pod restart. When `kasmvnc` is disabled, `chromium` falls
   back to running its own Xvfb instead, for CDP-only use with no
   visual access at all.
3. **`debug-fwd`** — a small relay sitting between the chromium container
   and the outside world. Chromium (from version 113 onward) silently
   forces its remote-debugging interface back to `127.0.0.1` no matter
   what address is requested, as a security hardening measure — so the
   CDP port is never actually reachable from outside the `chromium`
   container on its own. `debug-fwd` is a plain `socat` TCP relay that
   listens on all interfaces and forwards every connection to that
   loopback-only CDP port, making it reachable the rest of the pod/
   cluster via a normal Kubernetes Service.

Both the CDP endpoint (via `debug-fwd`) and the kasmvnc viewer are
exposed through a Kubernetes `Service`, and optionally through their own
Gateway API `HTTPRoute` each (kept as two independent routes on purpose,
so the CDP endpoint and the human-facing viewer can be published through
two different Gateways — e.g. the CDP endpoint kept private/internal-only
for agents, the viewer exposed more broadly for human access, or vice
versa, depending on the deployment).

Only the `chromium` container runs by default — `debug-fwd`
(`chromium.debug.enabled`) and `kasmvnc` (`kasmvnc.enabled`) are both
opt-in, each toggled independently in `values.yaml` alongside their own
`httpRoute.enabled`.

## Why this shape

No single upstream Docker image does "headful Chromium with CDP, no
built-in display server" plus a maintained display/remote-access image
that both exposes a single HTTP(S) endpoint and reliably resizes its
display to match the connecting client — several alternatives (Xpra,
Neko, noVNC, Selkies, KasmVNC) were evaluated and compared against
those two requirements during design. This project builds its own
minimal `chromium/Dockerfile` (installing `chromium` from Alpine's own
package repository) and a thin `kasmvnc/Dockerfile` layered on top of
Kasm Technologies' own Alpine "core" image (KasmVNC + XFCE, no bundled
browser), configured to suppress XFCE's panel so a single maximized
chromium window fills the display edge-to-edge. See `AGENTS.md` for the
full comparison, the reasoning behind this specific choice, and current
project status.

## Releasing a new chart version

The `chromium`/`kasmvnc` images are built and pushed to `ghcr.io`
automatically whenever their respective folders change. The Helm chart
is released separately and manually, since chart changes don't
necessarily line up with image changes:

1. Go to this repo's **Actions** tab → **Release and push Helm chart**
   → **Run workflow**.
2. Pick the version bump (`patch`, `minor`, or `major`) and run it.

The workflow bumps `chart/Chart.yaml`'s `version`/`appVersion`, commits
and tags that (`chart-vX.Y.Z`) on `main`, then packages and pushes the
chart as an OCI artifact to
`oci://ghcr.io/<owner>/server-browser/charts`. Install/upgrade it with
Helm's OCI support, e.g.:

```sh
helm upgrade --install server-browser \
  oci://ghcr.io/<owner>/server-browser/charts/server-browser \
  --version X.Y.Z
```

## Status

This is a standalone Helm chart (`chart/`), meant to be usable by
anyone on any Kubernetes cluster — nothing in this repo assumes or
hardcodes details of a specific cluster. Every cluster-specific detail
(image registries, storage class, Gateway names/hostnames, whether
persistence or either `HTTPRoute` is enabled, kasmvnc auth, and so on)
is left to each user to configure through `values.yaml` for their own
deployment.
