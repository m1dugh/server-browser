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

- Publishing the built `chromium`/`kasmvnc` images somewhere
  `values.yaml`'s `image.repository` can actually reference.
- Wiring `kasmvnc/` into `chart/templates/` and `values.yaml`, replacing
  the current `xpra` container/Service/HTTPRoute block there — the
  `xpra/` source folder and its CI workflow have already been removed
  (xpra is no longer in use at all, see the section below for why), but
  `chart/templates/statefulset.yaml`, `service-xpra.yaml`,
  `httproute-xpra.yaml`, and the `xpra` block in `values.yaml` still
  reference it as of this writing — the chart itself hasn't been
  updated yet, this is the next concrete step.
- End-to-end runtime verification (deploying the chart with the new
  KasmVNC-based display layer, confirming the shared X11 socket/
  Xauthority wiring and CDP-through-debug-fwd all work together in an
  actual cluster) — so far only verified via disposable local Docker
  containers, not the full pod wiring together.

## Display/remote-access layer: moving off xpra (in progress, architecture may still evolve)

After deploying with xpra, several real bugs surfaced in actual runtime
use (not just build-time): `xpra shadow` crashed on an upstream bug
walking non-existent socket-directory ancestors
(Xpra-org/xpra#4898, unfixed in Alpine's packaged 6.4.3-r0 at the time),
the bundled HTML5 client needed a separate `xpra-webclient` apk package
Alpine doesn't bundle into `xpra` itself, native `xpra attach` crashed
on a server-side `pwd.getpwnam()` username lookup unrelated to the
actual password check, and — the one that mattered most — xpra shadow
mode's dynamic resize-to-fit (resizing the shadowed X11 display to
match the connecting client's viewport) could not be made to work
reliably in hands-on testing despite `--resize-display=yes` being
xpra's documented default; the X11 display stayed fixed regardless of
client viewport size across repeated tests. Several alternatives were
evaluated (Neko, noVNC+x11vnc, Selkies, KasmVNC) specifically against:
single-HTTP-endpoint feasibility, confirmed dynamic resize support, and
whether the browser container could stay independently
owned/customized (our own chromium image, our own CDP flags, our own
PVC-backed `--user-data-dir`) rather than being replaced by a
vendor-bundled browser.

**Decision: KasmVNC**, specifically `kasmweb/core-alpine-<NNN>` as a
standalone display-owning container, chromium connecting into it as a
plain second container — not xpra's "chromium owns the display, a
sidecar shadows it" shape, but the reverse: KasmVNC's `Xvnc` owns the
display from the start, our chromium container is just an X11 client
connecting to it. This was chosen over the alternatives because:
  - Neko needs two separate ports/listeners no matter how hostname/path
    is arranged (WebRTC media is raw ICE/STUN-over-TCP, not HTTP;
    confirmed from Neko's own docs, which state outright that this
    traffic can't be reverse-proxied) — ruled out by the single-HTTP-
    endpoint requirement for this part of the chart specifically (CDP
    keeps its own separate endpoint regardless of which solution is
    picked here).
  - noVNC's actual resize behavior (whether its HTML5 client calls
    TigerVNC's `SetDesktopSize`/RandR mechanism) couldn't be confirmed
    from any official doc either way.
  - Selkies has confirmed first-class resize but, like Neko, is
    WebRTC-based and not single-port deployable without a TURN server
    or explicit UDP/TCP mux ports; also Debian/Ubuntu-only, no Alpine
    support.
  - KasmVNC is the only option confirmed (from official docs) to be
    both single-HTTP-port AND have a documented live/dynamic resize
    mode ("Remote Resizing" in their video-rendering docs) — though the
    underlying mechanism isn't documented in detail and hasn't yet been
    hands-on verified in this project the way xpra's (broken) resize
    was.
  - `kasmweb/chromium` (Kasm's own all-in-one browser image) was
    evaluated and rejected: hands-on testing confirmed its `APP_ARGS`
    env var successfully overrides `--remote-debugging-port`, but its
    hardcoded wrapper script (`install_chromium.sh`'s generated
    `/usr/bin/chromium` wrapper) still wins the `--user-data-dir` flag
    over anything passed via `APP_ARGS` (Chromium's last-flag-wins
    parsing resolves to the wrapper's own trailing bare
    `--user-data-dir`, not ours) — confirmed by checking the actual
    profile directory on disk after a test run, so this image can't
    support our PVC-backed custom data dir requirement without patching
    upstream's script.
  - KasmVNC itself has **no shadow-an-existing-display mode**: its
    `Xvnc` fork dropped TigerVNC's `x0vncserver` entirely (no such
    subdirectory in KasmVNC's `unix/CMakeLists.txt`, confirmed against
    upstream TigerVNC which still ships it), and its `kasmxproxy` tool
    is a pure X11 *client* that copies frames between two
    already-running X servers (confirmed from its source,
    `kasmxproxy.c`: both sides opened via `XOpenDisplay()`, the
    standard client-connect call) — it cannot itself create/own a
    display another container's app would render into. This ruled out
    directly replicating xpra's "shadow the chromium container's
    display" shape with KasmVNC.
  - The shape that does work, confirmed hands-on: `Xvnc` creates its
    own display and fully replaces Xvfb's role (same category of tool —
    KasmVNC's own `Xvnc` man page: "two servers in one... to the
    applications it is an X server, and to the remote VNC users it is a
    VNC server"); Kasm's own official `vnc_startup.sh` already starts
    `vncserver`/`Xvnc` completely decoupled from any specific
    application (it deliberately writes a no-op `xstartup` before
    starting `vncserver`, with the app/window-manager launch handled as
    an entirely separate, later step) — so splitting those two already-
    separate phases across two containers is a natural extension of
    Kasm's own pattern, not a workaround.

**`kasmweb/core-<distro>-<version>` naming**: the numeric suffix in
Kasm's "core" image names encodes the OS version packed in, with no
separator — e.g. `core-alpine-323` = Alpine **3.23**, `core-alpine-317`
= Alpine 3.17, `core-ubuntu-jammy` uses the codename instead since
Ubuntu images are named that way in Kasm's matrix. Checked and
confirmed `core-alpine-317` (which earlier, shallower research surfaced
first) is stale/superseded — Kasm's own CI build matrix
(`ci-scripts/template-vars.yaml` in `kasmtech/workspaces-core-images`)
currently only generates `321`/`322`/`323` tags for the Alpine track;
`317` aged out and its last Docker Hub tag predates `core-alpine-323`'s
by months. `core-alpine-323:1.19.0` is the version hands-on tested and
confirmed working in this project (matches `kasmweb/chromium`'s own
`1.19.0` release, same release cadence).

**Hands-on verified** (disposable local Docker containers, not yet
wired into the chart):
  - `kasmweb/core-alpine-323:1.19.0` run standalone (no app layer)
    starts `Xvnc` successfully and serves its HTML5/websocket client
    (confirmed: `401` on the web port with a password configured,
    `6901` by default).
  - Our own `chromium/Dockerfile` image, run as a **separate container**
    with no Xvfb at all, connecting via `$DISPLAY` to the KasmVNC
    container's X11 socket shared over a Docker volume mounted at
    `/tmp/.X11-unix` in both containers — confirmed working: chromium's
    window appears in the shared display's window tree (`xwininfo -root
    -tree` showed a `1023x767` window of class `"chromium"`), and CDP
    (`/json/version`) responded correctly from inside the chromium
    container with our own `--remote-debugging-port`/`--user-data-dir`
    flags intact and actually taking effect (unlike `kasmweb/chromium`'s
    broken `APP_ARGS` data-dir override).
  - Two real integration requirements surfaced that xpra's architecture
    never needed, both still open to resolve in the chart:
    1. **Shared volume permissions** — `Xvnc` silently falls back to an
       abstract-namespace-only Unix socket (invisible to a sibling
       container sharing the same directory) if it can't write a
       filesystem socket into `/tmp/.X11-unix` at the default
       permissions a fresh Docker volume/Kubernetes `emptyDir` starts
       with; needs `chmod 1777` applied before `Xvnc` starts. In the
       real chart this is expected to be solved with an init container
       mounting the same `emptyDir` and fixing permissions before the
       main containers start — not yet implemented/verified in
       Kubernetes itself, only diagnosed and reproduced via manual
       `chmod` in the local Docker test.
    2. **X11 authentication** — unlike our auth-less `Xvfb` invocation,
       `Xvnc` runs with `-auth <file>` (MIT-MAGIC-COOKIE-1 enforced).
       Copying the `.Xauthority` file between containers as-is does
       NOT work — the auth entry is looked up by the *connecting
       container's own hostname*, so each container must locally run
       `xauth add unix:<display-number> MIT-MAGIC-COOKIE-1 <cookie>`
       with the same cookie value (confirmed via a working `xdpyinfo`
       test after switching from file-copy to `xauth add`); only the
       cookie value itself needs to be shared across containers (e.g.
       a small shared file written by an init container), not the
       Xauthority file as a whole. Not yet wired into
       `chromium/entrypoint.sh` or the chart — currently only proven
       by a manual `xauth add` step in the disposable test container.
  - **Open, unresolved as of now**: `core-alpine-323` bundles a full
    XFCE desktop (panel, desktop icons, window manager chrome) by
    default — confirmed via `xwininfo`, which showed `xfce4-panel`,
    `xfdesktop`, and `xfwm4` windows alongside chromium's. Unlike
    xpra's bare-Xvfb/no-window-manager setup, chromium does not
    automatically fill the whole display here; Kasm's own
    `kasmweb/chromium` image solves this at the image/config level
    (stripping the panel, forcing maximize) — being investigated next
    for whether/how to replicate that against our own chromium
    container rather than Kasm's.

**Fullscreen/window-manager question — resolved.** Confirmed hands-on:
chromium's own `--start-maximized` flag (added to the chromium
container's own launch command, nothing xfwm4-side needed) makes its
window cover the display exactly edge-to-edge once the panel is
suppressed — `xwininfo` showed the chromium window at
`1024x768+0+0`, matching the display's own geometry precisely, with no
panel window present anywhere in the tree.

The panel itself is suppressed via **config, not package removal** —
`apk del xfce4-panel` is blocked outright (it's only removable as a
dependency of the `xfce4` meta-package), and forcibly removing `xfce4`
to route around that cascades into deleting `xfwm4`/`xfdesktop`/
`xfce4-session` themselves (confirmed hands-on — both were tried and
rejected). Instead, `xfce4-session.xml`'s own default session
definition (both the X11 "Failsafe" and Wayland "FailsafeWayland"
sessions) lists `xfce4-panel` as one of several session-managed
startup clients; dropping that one client entry from each session (in
a per-user override copied over the same path the base image reads
its default config from) means the panel process is simply never
started — no uninstall, no risk of taking anything else down with it.

A new `kasmvnc/` component holds this: `kasmvnc/Dockerfile` (`FROM
kasmweb/core-alpine-323:${BASE_TAG}`, copies in three authored config
files, nothing else), `kasmvnc/xfce-single-app/{xfwm4,xfce4-desktop,xfce4-session}.xml`
(none of these exist upstream for the Alpine core image — all three
authored from scratch here, adapted from Kasm's own Ubuntu-based
single-app reference files where one exists, from Alpine's own default
config where it doesn't), and `kasmvnc/version.txt` (holding just the
Kasm version pin, e.g. `1.19.0`, matching the existing
`chromium/version.txt`/`xpra/version.txt` single-purpose convention).

**Published image tag**: `<kasm-version>-alpine<alpine-version>` (e.g.
`1.19.0-alpine3.23`), not just the Kasm version alone — since this
image's actual contents (and compatibility) depend on both the Kasm
release and the Alpine base it's built against, and the two can
diverge independently if either `kasmvnc/version.txt` or the Alpine
line in `kasmvnc/Dockerfile`'s `FROM` changes without the other. The
Alpine version segment is derived mechanically in CI from the `FROM
kasmweb/core-alpine-323:${BASE_TAG}` line itself (`323` → `3.23`) via
`sed`, rather than hand-maintained in a second file, so there's exactly
one place (the `FROM` line) that encodes which Alpine release this
image is built against.
`.github/workflows/kasmvnc-image.yaml` mirrors the `chromium`/`xpra`
image pipelines (same QEMU/buildx/multi-arch setup) with this tag
derivation as its one addition.

This section will be revised/replaced once the architecture is
actually wired into `chart/templates/` — treat everything above as the
current best understanding, not a final design. Still open: the shared
X11 socket volume's permissions (to be handled by an init container in
the real chart, not yet implemented/verified in Kubernetes — only
reproduced via manual `chmod` in local Docker testing) and scripting
the per-container Xauthority cookie generation into
`chromium/entrypoint.sh` (currently only proven via a manual `xauth
add` step in testing, not yet written into the entrypoint itself).
