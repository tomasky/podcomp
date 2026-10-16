# podcomp

A [Compose Spec](https://compose-spec.io/) implementation that runs on
[Podman](https://podman.io/), written in MoonBit. It reads the same
`compose.yaml` / `compose.yml` / `docker-compose.yml` files Docker Compose
reads, merges and interpolates them, and drives `podman` directly.

One native binary. No daemon, no Python runtime, no background state.

```console
$ podcomp up -d
$ podcomp ps
$ podcomp logs -f web
$ podcomp down
```

## Install

```sh
# Installer script (Linux x86-64/arm64, macOS arm64)
curl -LsSf https://raw.githubusercontent.com/tomasky/podcomp/main/install.sh | bash

# npm
npm install -g @tomasko/podcomp

# The MoonBit package registry (needs the MoonBit toolchain)
moon install kupas/podcomp/cmd/podcomp

# From source
git clone https://github.com/tomasky/podcomp && cd podcomp
moon build --target native --release
```

## What works

`podcomp` is a port of the reference
[`podman-compose`](https://github.com/containers/podman-compose) behaviour, so
the two can be used interchangeably for the common cases:

- **File discovery** — `compose.yaml`, `compose.yml`, `docker-compose.yml`, or
  `-f` (repeatable, `-` reads standard input). Multiple files are merged with
  Compose's rules, and `<<` merge keys are expanded.
- **Interpolation** — `.env` files (via `--env-file`), the process environment,
  and the full `${VAR}`, `${VAR:-default}`, `${VAR-default}`, `${VAR:?err}`,
  `${VAR:+alt}` and `$$` operator set.
- **Profiles** — services are selected with `--profile` and `COMPOSE_PROFILES`.
- **The service model** — `image`, `build`, `command`, `entrypoint`,
  `environment`, `env_file`, `ports`, `expose`, `volumes`, `tmpfs`, `networks`,
  `depends_on`, `healthcheck`, `labels`, `secrets`, `ulimits`, `deploy`,
  resource limits, `restart`, `user`, `workdir`, `hostname`, `dns`, `devices`,
  `sysctls`, `cap_add`/`cap_drop`, and more.
- **Pods** — the whole project runs in one pod (`--infra=false`), which is what
  makes service-name DNS work between containers. `x-podman.in_pod` and
  `--in-pod` control it.
- **Labels** — the same `io.podman.compose.*` / `com.docker.compose.*` labels
  the reference writes, so an existing project is picked up unchanged.

## Commands

```
up        create and start the stack
down      stop and remove the stack
ps        list containers
logs      show container logs
start     start services
stop      stop services
restart   restart services
kill      kill services
rm        remove stopped containers
pull      pull service images
build     build service images
images    list service images
exec      run a command in a running container
run       run a one-off command in a new container
port      print the host port for a published port
pause     pause services
unpause   unpause services
config    print the merged compose file
version   show the version
```

Global options include `-f/--file`, `-p/--project-name`, `--profile`,
`--env-file`, `--podman-path`, `--podman-args`, `--dry-run`, `--verbose` and
`--in-pod`. Run `podcomp --help` for the full list.

`--dry-run` prints the `podman` invocations instead of running them, which is
the quickest way to see what `podcomp` would do.

## Example

```yaml
services:
  web:
    image: docker.io/library/nginx:alpine
    ports:
      - "8080:80"
    volumes:
      - ./html:/usr/share/nginx/html:ro
    depends_on:
      - db
  db:
    image: docker.io/library/postgres:16
    environment:
      POSTGRES_PASSWORD: secret
    volumes:
      - pgdata:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD-SHELL", "pg_isready"]
      interval: 10s
      retries: 5

volumes:
  pgdata: {}
```

```console
$ podcomp --dry-run up
podman pod exists pod_demo
podman pod create --name=pod_demo --infra=false --share=
podman network exists demo_default
podman network create --label io.podman.compose.project=demo ... demo_default
podman create --name=demo_db_1 --pod=pod_demo ... docker.io/library/postgres:16
podman create --name=demo_web_1 --pod=pod_demo --requires=demo_db_1 ... nginx:alpine
podman start -a demo_db_1
podman start -a demo_web_1
```

## Building

Requires the [MoonBit toolchain](https://www.moonbitlang.com/download/).

```sh
moon check --target native --deny-warn
moon test --target native
moon build --target native --release
# _build/native/release/build/cmd/podcomp/podcomp.exe
```

Releases are cut by pushing a `v*` tag; `.github/workflows/release.yml` builds
static musl binaries for Linux and a native binary for macOS, attaches them to
the GitHub Release, and publishes the npm launcher. The tag has to match the
version in the sources.

The version is written down in `moon.mod` (the module), `podcomp.mbt` (what
`podcomp --version` prints) and `npmjs/package.json` (what the npm launcher
downloads). `scripts/check-version.sh` fails when the copies disagree, so bump
them together:

```sh
scripts/bump-version.sh 0.2.0
scripts/bump-version.sh --bump patch
```

## License

Apache-2.0
