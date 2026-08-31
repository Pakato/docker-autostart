# docker-autostart

A tiny watchdog that brings back Docker containers stuck in `created`, `exited`
or `restarting`.

It fills the gap left by the two usual tools:

| | watches | acts when |
|---|---|---|
| Docker `restart:` policy | its own container | the container exits, until you `docker stop` it or the daemon restarts oddly |
| [willfarrell/autoheal](https://github.com/willfarrell/docker-autoheal) | **running** containers | health check reports `unhealthy` |
| **docker-autostart** | **stopped** containers | a container is sitting in `created` / `exited` / crash-looping |

Alpine + `docker-cli` + a shell loop. About 15 MB to pull, no daemon, no database.

---

## Quick start

Label the containers you want watched, then run the watchdog:

```yaml
services:
  myapp:
    image: myapp:latest
    labels:
      autostart: "true"          # <- this is what gets it picked up

  autostart:
    image: pakato/docker-autostart:latest
    container_name: autostart
    restart: always
    network_mode: none
    environment:
      TZ: America/Sao_Paulo
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
      - autostart-state:/var/lib/autostart

volumes:
  autostart-state:
```

```bash
docker compose up -d
```

Or without compose:

```bash
docker run -d --name autostart --restart always --network none -v /var/run/docker.sock:/var/run/docker.sock -v autostart-state:/var/lib/autostart pakato/docker-autostart:latest
```

Watch what it is doing:

```bash
docker logs -f autostart
```

```
2026-08-31 12:00:00  watching containers labelled autostart=true
2026-08-31 12:00:00  states=created,exited interval=30s max_attempts=5 skip_exit_zero=true dry_run=false
2026-08-31 12:00:30  START  myapp (exited code=137) attempt 1 -> ok
```

---

## Configuration

Everything is an environment variable. Defaults are in bold.

| Variable | Default | What it does |
|---|---|---|
| `INTERVAL` | **30** | Seconds between sweeps. |
| `STARTUP_DELAY` | **5** | Seconds to wait before the *first* sweep, so a host reboot has a moment to settle and the watchdog does not fight containers that are already coming up. `0` sweeps immediately. |
| `CONTAINER_LABEL` | **autostart** | Only containers labelled `<value>=true` are watched. Set to `all` to watch every container on the host. |
| `STATES` | **created,exited** | Comma-separated states to act on. Add `restarting` to also react to crash loops. |
| `SKIP_EXIT_ZERO` | **true** | Ignore containers that exited with code 0 — they either finished their job or you stopped them on purpose. Set to `false` to restart those too. |
| `MAX_ATTEMPTS` | **5** | Give up after this many failed starts for the same container. `0` = never give up. |
| `ATTEMPT_RESET` | **3600** | Seconds of quiet before a container's attempt counter resets. The counter also resets the moment the container is seen running. |
| `RESTARTING_GRACE` | **300** | How long a container may sit in `restarting` before it counts as a crash loop. |
| `RESTARTING_ACTION` | **notify** | `notify` (log + notification only) or `restart` (force a `docker restart`). |
| `DRY_RUN` | **false** | Log what would happen and change nothing. Good for a first run with `CONTAINER_LABEL=all`. |
| `APPRISE_URL` | *(empty)* | Apprise / ntfy endpoint to POST notifications to. Empty disables notifications. |
| `TZ` | *(UTC)* | Timezone for log timestamps. |
| `STATE_DIR` | **/var/lib/autostart** | Where attempt counters live. Mount a volume here so counters survive a restart of the watchdog. |

### Which containers get watched

By label (default, recommended):

```yaml
labels:
  autostart: "true"
```

Rename the label with `CONTAINER_LABEL: mywatchdog` → then containers need
`mywatchdog: "true"`.

Everything on the host:

```yaml
environment:
  CONTAINER_LABEL: all
  DRY_RUN: "true"     # try this first, then flip it off
```

### Notifications

Point `APPRISE_URL` at an [Apprise](https://github.com/caronc/apprise-api) or
[ntfy](https://ntfy.sh) endpoint and remove `network_mode: none` so the
container can reach it:

```yaml
environment:
  APPRISE_URL: https://apprise.example.com/notify/mykey
# network_mode: none   <- must go
```

It POSTs `{"title": "autostart", "body": "...", "type": "success|failure|warning"}`.
A failing notification is logged and never blocks a restart.

Two failure modes, distinguished in the log:

```
WARN   notification rejected: HTTP 502 from https://apprise.example.com/notify/x
WARN   notification failed: curl: (6) Could not resolve host: ... (curl exit 6)
```

The first means your endpoint was reached but did not accept the POST — the
notification service is down or the URL path is wrong. The second means the
container could not reach it at all; the usual cause is leaving
`network_mode: none` set while `APPRISE_URL` is configured.

Note the payload is [Apprise API](https://github.com/caronc/apprise-api)
format (`/notify/{key}`). Bare ntfy expects a different body, so point
`APPRISE_URL` at an apprise-api instance, not at ntfy directly.

### Watching the watchdog

The image ships a `HEALTHCHECK` driven by a heartbeat file, so
`willfarrell/autoheal` can look after it:

```yaml
labels:
  autoheal: "true"
```

---

## How it decides

Every `INTERVAL` seconds:

1. Any watched container that is **running** gets its attempt counter cleared.
2. `created` → started immediately.
3. `exited` → started, unless the exit code is `0` and `SKIP_EXIT_ZERO=true`.
4. `restarting` (only if listed in `STATES`) → if it has been restarting longer
   than `RESTARTING_GRACE`, it notifies, or force-restarts when
   `RESTARTING_ACTION=restart`.
5. Counters for containers that no longer exist are pruned.

A container that fails `MAX_ATTEMPTS` times in a row is left alone until it
either comes back up or `ATTEMPT_RESET` seconds pass — so a genuinely broken
container does not get hammered forever.

---

## Tags

| Tag | Points at |
|---|---|
| `latest` | Newest release. |
| `1`, `1.2`, `1.2.3` | Semver, from git tags. |
| `main` | Newest commit on `main`. |
| `sha-abc1234` | One exact commit. |

Built for `linux/amd64`, `linux/arm64` and `linux/arm/v7`, so it runs on a
Raspberry Pi as-is.

Pin a version in production:

```yaml
image: pakato/docker-autostart:1.0.0
```

---

## Security note

This container talks to the Docker socket, which is equivalent to root on the
host. Nothing in it is exposed to the network — keep `network_mode: none`
unless you need `APPRISE_URL`. Read
[`autostart.sh`](autostart.sh) before you trust it; it is 150 lines of shell.

---

## Building and releasing

Build locally:

```bash
docker compose -f docker-compose.yml -f docker-compose.build.yml up -d --build
```

Publishing is automated. Pushing to `main` refreshes `latest` and `main`;
pushing a `v*.*.*` git tag publishes the version tags:

```bash
./release.sh 1.0.0
```

The [workflow](.github/workflows/docker-publish.yml) lints the script with
shellcheck and the Dockerfile with hadolint, then builds all three
architectures and pushes with SBOM and build provenance attached.

### First-time repository setup

The workflow needs two repository secrets:

| Secret | Value |
|---|---|
| `DOCKERHUB_USERNAME` | Your Docker Hub username. |
| `DOCKERHUB_TOKEN` | A Docker Hub access token with **Read, Write, Delete** scope, from [hub.docker.com → Account settings → Personal access tokens](https://app.docker.com/settings/personal-access-tokens). |

Optionally set a repository *variable* `DOCKERHUB_IMAGE` to publish somewhere
other than `pakato/docker-autostart`.

---

## License

MIT.
