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

A dedicated ClusterIP Service exposes the CDP port (via `debug-fwd`) and
another exposes the Xpra port. Two optional Gateway API `HTTPRoute`s
(disabled by default, one under `chromium.debug.httpRoute` for the
debugger endpoint, one under `xpra.httpRoute` for the xpra UI) can front
each service through an existing Gateway — each block has its own
`gatewayName`/`gatewayNamespace`/`sectionName`/`hostname`, deliberately
kept separate (rather than a single shared `httpRoute` block) so the
debugger and the xpra UI can be bound to two different Gateways (e.g.
one private, one public) by whoever deploys this chart.

## Decisions made so far

- Chromium base image: **Alpine** (apk `chromium` package), not Debian —
  chosen over Debian despite Debian being Xpra's native packaging
  target. Verified working: both `chromium/Dockerfile` and
  `xpra/Dockerfile` build successfully and install their respective apk
  packages without issue.
- Both Dockerfiles pin `FROM alpine:3.24` (not `alpine:edge`) — chromium
  and xpra are both available in 3.24's `community` repo
  (`155.0.8059.84-r0` / `6.4.3-r0` respectively), so edge isn't needed.
  Each component owns a `version.txt` (`chromium/version.txt`,
  `xpra/version.txt`) holding that pinned apk version string as the
  single source of truth — the CI pipeline reads it to supply both the
  `ARG CHROMIUM_VERSION`/`ARG XPRA_VERSION` build-arg and the pushed
  image tag. Bump the version by editing that file.
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
- Values.yaml keys: `chromium`, `xpra`, `persistence` — each top-level
  block owns its own `image`/`resources`/`securityContext` where
  applicable. The debug-forwarding sidecar lives nested under
  `chromium.debug` (not as a top-level `debugFwd` block) since it exists
  solely to expose chromium's own CDP port — see below.
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
- `chromium.debug.httpRoute`/`xpra.httpRoute` each default to
  `enabled: false` with no gateway/hostname set, since this chart has no
  cluster/Gateway of its own to attach to yet — both are plain Gateway
  API `HTTPRoute`s (`gateway.networking.k8s.io/v1`). They are
  intentionally two separate blocks, not a shared top-level `httpRoute`,
  specifically so the debugger and xpra UI can be exposed through two
  different Gateways.
- `chromium.debug.enabled`/`xpra.enabled` both default to `false` — only
  the `chromium` container runs out of the box; each sidecar (and its
  container, Service, and `x11-socket` emptyDir volume for xpra)
  is opt-in per deployment. `chromium.debug.httpRoute.enabled` only
  takes effect when `chromium.debug.enabled` is also true (the debugger
  Service it routes to doesn't exist otherwise), and likewise
  `xpra.httpRoute.enabled` requires `xpra.enabled` — enforced in the
  templates via `and`, not just documented.
- Each component owns its own Service rather than a single chart-wide
  one: `chromium.debug.service` (`templates/service-debugger.yaml`,
  rendered only when `chromium.debug.enabled`) and `xpra.service`
  (`templates/service-xpra.yaml`, rendered only when `xpra.enabled`),
  each with its own `type`/`port`. This replaced an earlier single
  top-level `service` block (shared `type`, `debuggingPort`/`xpraPort`)
  once it became clear the two sidecars could reasonably need different
  Service types (e.g. one internal `ClusterIP`, one `NodePort`/`LoadBalancer`)
  — matches the existing per-component `httpRoute` split for the same
  reason. The HTTPRoutes' `backendRefs` point at
  `<fullname>-debugger`/`<fullname>-xpra` accordingly.
- The debug-forwarding sidecar, its image, resources, securityContext,
  Service, and HTTPRoute all live nested under `chromium.debug` (not a
  top-level `debugFwd` block as originally structured) — the debugger
  is fundamentally a facet of exposing chromium's CDP port, not an
  independent component, so its config belongs inside `chromium` the
  same way xpra's own Service/httpRoute live inside `xpra`. The
  `debug-fwd` container name in the StatefulSet is unchanged; only the
  values.yaml location and all `.Values.chromium.debug.*` template
  references moved.

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
- `chromium/` (`Dockerfile`, `entrypoint.sh`, `version.txt`) and
  `xpra/` (`Dockerfile`, `entrypoint.sh`, `version.txt`) added at the
  repo root, one self-contained folder per component. Both build
  successfully (`docker build`, verified) on `alpine:3.24`.
  `chromium.image.repository`/`tag` and `xpra.image.repository`/`tag`
  are still blank in `values.yaml` since these images aren't published
  anywhere yet.
- A GitHub Actions pipeline (`.github/workflows/chromium-image.yaml`)
  builds and pushes the chromium image to
  `ghcr.io/<owner>/server-browser/chromium`, triggered only on changes
  under `chromium/` (plus the workflow file itself). It reads
  `chromium/version.txt` for both the `CHROMIUM_VERSION` build-arg and
  the pushed tag (plus a floating `latest` tag), using the ephemeral
  `GITHUB_TOKEN` to authenticate — same-tag pushes are allowed to
  overwrite. Layer caching uses the `gha` backend
  (`cache-from`/`cache-to: type=gha`).
  `.github/workflows/xpra-image.yaml` mirrors this exactly for xpra
  (triggered on `xpra/**`, reads `xpra/version.txt`, pushes to
  `ghcr.io/<owner>/server-browser/xpra`).
- `.github/workflows/chart-release.yaml` releases the chart —
  deliberately `workflow_dispatch`-only (a `bump: patch|minor|major`
  input), not triggered on push to `chart/`. An auto-trigger was
  considered (semantic-release off conventional commits scoped to
  `chart/`) but dropped: it would need the release job to push a
  version-bump commit back to `main` itself, which risks retriggering
  the same workflow in a loop and also hits branch-protection
  complexity the user didn't want to deal with for this chart. Manual
  dispatch sidesteps both — nothing ever triggers this workflow except
  a human running it. It bumps `chart/Chart.yaml`'s
  `version`/`appVersion`, commits as `github-actions[bot]`, tags
  `chart-v<version>`, pushes both to `main`, then packages and pushes
  the chart as an OCI artifact to
  `oci://ghcr.io/<owner>/server-browser/charts`. See README.md's
  "Releasing a new chart version" for the user-facing steps.

## Not yet started

- Publishing the built `chromium`/`xpra` images somewhere
  `values.yaml`'s `image.repository` can actually reference.
- End-to-end runtime verification (deploying the chart, confirming
  xpra actually shadows chromium's display and CDP is reachable through
  debug-fwd) — so far only `docker build` has been exercised per image,
  not the full pod wiring (shared X11 socket, readiness probes) together.
