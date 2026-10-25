# server-browser

`CLAUDE.md` in this repo is a symlink to this file (`AGENTS.md`) — they are
the same file, not two separate documents to keep in sync.

User-intended documentation (what this project is, why it exists, how
the pieces fit together for someone reading the repo rather than working
on it) belongs in `README.md`, not here. This file (`AGENTS.md`) is for
agent/implementation context instead: decisions made, why, and current
progress/status — see the sections below.

A Helm chart (`chart/`) providing a remotely-controllable, persistent
Chromium browser: Chrome DevTools Protocol (remote debugging) access
plus an interactive Xpra-forwarded display of the same browser session.

This is a standalone project, developed independently of any specific
cluster, meant to be usable by anyone on any Kubernetes cluster — nothing
here should assume or hardcode details of a specific target cluster;
every cluster-specific detail is left to each user's own `values.yaml`.

## Architecture

A single pod (StatefulSet, 1 replica — the browser's profile and X
display session are stateful/singleton by nature) with three containers:

1. **`chromium`** — custom image (Alpine + `chromium` apk package +
   Xvfb). Runs chromium headful against a virtual X display, with
   `--remote-debugging-port=<port>`. No bundled VNC/display server is
   used here (ruled out upstream images like `jlesage/chromium` for this
   reason — they bundle their own noVNC/VNC, which would conflict with
   Xpra owning the display).
2. **`debug-fwd`** — `alpine/socat` (upstream image, no modification
   needed). Chromium >=M113 forces `--remote-debugging-address` back to
   `127.0.0.1` regardless of what's requested, so the CDP port is never
   actually reachable from outside the container as chromium binds it.
   This container relays `0.0.0.0:<debuggingPort> -> 127.0.0.1:<debuggingPort>`
   inside the pod's network namespace, making the port reachable via the
   Service.
3. **`xpra`** — custom image (no official Xpra Docker image exists
   upstream; it's only packaged via apt/dnf). Shadows/attaches to the
   chromium container's existing X display (`xpra shadow` /
   `--use-display`) rather than starting its own application — the two
   containers share the X11 socket (`/tmp/.X11-unix`) via an `emptyDir`
   volume. Serves Xpra's HTML5/TCP client.

Persistence: a PVC backing chromium's `--user-data-dir` (profile, cache,
cookies, extensions), mounted only into the `chromium` container.

A ClusterIP Service exposes both the CDP port (via `debug-fwd`) and the
Xpra port. Two optional Gateway API `HTTPRoute`s (disabled by default,
one under `chromium.httpRoute` for the debugger endpoint, one under
`xpra.httpRoute` for the xpra UI) can front each service through an
existing Gateway — each block has its own
`gatewayName`/`gatewayNamespace`/`sectionName`/`hostname`, deliberately
kept separate (rather than a single shared `httpRoute` block) so the
debugger and the xpra UI can be bound to two different Gateways (e.g.
one private, one public) by whoever deploys this chart.

## Decisions made so far

- Chromium base image: **Alpine** (apk `chromium` package), not Debian —
  chosen over Debian despite Debian being Xpra's native packaging
  target. Verified working: both `Dockerfile.chromium` and
  `Dockerfile.xpra` build successfully and install their respective apk
  packages without issue.
- Both Dockerfiles pin `FROM alpine:3.24` (not `alpine:edge`) — chromium
  and xpra are both available in 3.24's `community` repo
  (`155.0.8059.84-r0` / `6.4.3-r0` respectively), so edge isn't needed.
  `ARG CHROMIUM_VERSION`/`ARG XPRA_VERSION` default to those pinned
  versions; override with a different apk version string to bump.
- `debug-fwd` container name (not `socat`) is intentional — short for
  "debug forward", describing its role rather than its implementation.
- Both entrypoints wait on the shared X11 socket in a `sleep 1` loop
  (logging "waiting for X server on ... to be up..." each iteration),
  then touch `/run/server-browser/ready` just before `exec`ing into the
  long-running process (chromium / `xpra shadow`) — `exec` replaces the
  shell, so the ready-file write has to happen immediately before it,
  not after. Each container's own readinessProbe in
  `templates/statefulset.yaml` is a plain `test -f
  /run/server-browser/ready` exec check against that file.
- Values.yaml keys: `chromium`, `debugFwd`, `xpra`, `persistence`,
  `service` — each top-level block owns its own
  `image`/`resources`/`securityContext` where applicable.
- No suitable combined chromium+xpra image exists upstream at all
  (checked specifically for this) — both `chromium` and `xpra` images
  are authored in this project rather than sourced externally.
- `xpra.auth.password`/`passwordSecretName`+`passwordSecretKey` protect
  the xpra HTML5/websocket listener (`--bind-ws=...,auth=file,...`) —
  `passwordSecretName` (pointing at a Secret) takes precedence over the
  plaintext `password` field when both are set; when neither is set,
  xpra runs passwordless (`auth=allow`). Plaintext `password` exists for
  local testing convenience, not recommended for anything checked into
  git.
- `persistence.enabled` defaults to `false` — when disabled, the
  StatefulSet falls back to an `emptyDir` for chromium's user-data dir
  instead of a `volumeClaimTemplate`.
- `chromium.httpRoute`/`xpra.httpRoute` each default to `enabled: false`
  with no gateway/hostname set, since this chart has no cluster/Gateway
  of its own to attach to yet — both are plain Gateway API `HTTPRoute`s
  (`gateway.networking.k8s.io/v1`). They are intentionally two separate
  blocks, not a shared top-level `httpRoute`, specifically so the
  debugger and xpra UI can be exposed through two different Gateways.

## Progress

- `chart/` scaffolded via `helm create` and pared down to what this
  chart actually needs (StatefulSet instead of Deployment; no HPA,
  Ingress, ServiceAccount, or generated tests). `helm lint` and
  `helm template` both verified clean, including with persistence and
  both HTTPRoutes enabled.
- `templates/statefulset.yaml`: 3 containers (`chromium`, `debug-fwd`,
  `xpra`) wired per the architecture above, each of `chromium`/`xpra`
  with its own readinessProbe (see the ready-file decision above);
  `templates/service.yaml` exposes both ports; `templates/httproute-xpra.yaml`
  and `templates/httproute-debugger.yaml` are independently toggleable.
- `Dockerfile.chromium` + `entrypoint.chromium.sh` and `Dockerfile.xpra`
  + `entrypoint.xpra.sh` added at the repo root. Both build successfully
  (`docker build`, verified) on `alpine:3.24`.
  `chromium.image.repository`/`tag` and `xpra.image.repository`/`tag`
  are still blank in `values.yaml` since these images aren't published
  anywhere yet.

## Not yet started

- Publishing the built `chromium`/`xpra` images somewhere
  `values.yaml`'s `image.repository` can actually reference.
- End-to-end runtime verification (deploying the chart, confirming
  xpra actually shadows chromium's display and CDP is reachable through
  debug-fwd) — so far only `docker build` has been exercised per image,
  not the full pod wiring (shared X11 socket, readiness probes) together.
