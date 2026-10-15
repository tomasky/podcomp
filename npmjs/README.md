# `@tomasko/podcomp`

The npm launcher for [`podcomp`](https://github.com/tomasky/podcomp) — a
Compose Spec implementation that runs on Podman, written in MoonBit.

```sh
npm install -g @tomasko/podcomp
podcomp up
podcomp ps
podcomp logs -f web
podcomp down
```

`podcomp` reads the same `compose.yaml` / `compose.yml` / `docker-compose.yml`
files Docker Compose reads, merges and interpolates them, and drives `podman`
directly. There is no daemon, no Python runtime and no background state: one
native binary.

## What this package contains

A small launcher, not the binary itself. On the first `podcomp` run it
downloads the prebuilt native binary for your platform from the GitHub release
and caches it. Nothing is downloaded at install time.

| Platform | Target |
| --- | --- |
| Linux x86-64 | `podcomp-linux-x86_64` (static, musl) |
| Linux arm64 | `podcomp-linux-aarch64` (static, musl) |
| macOS Apple silicon | `podcomp-darwin-aarch64` |

The Linux builds are linked statically against musl, so they run on any
distribution regardless of its glibc version.

## Why there is no `postinstall`

This package deliberately declares **no install script**. Since npm 12,
dependency lifecycle scripts are blocked unless the user opts in; and pnpm 12
fails a *project* install outright with `ERR_PNPM_IGNORED_BUILDS` when a
dependency declares one:

```console
$ pnpm add @tomasko/podcomp
Error: ERR_PNPM_IGNORED_BUILDS
  × adding a new package
  ╰─▶ Ignored build scripts: @tomasko/podcomp@0.1.1
```

Downloading lazily from `bin/podcomp.js` sidesteps all of it: it works under
npm, pnpm, yarn, bun, `npx`, and `--ignore-scripts`, because it is an ordinary
command rather than an install hook.

## Cache location

The downloaded binary is kept outside the package, so reinstalling or clearing
`node_modules` never triggers a second download:

| Platform | Path |
| --- | --- |
| Linux | `$XDG_CACHE_HOME/podcomp` or `~/.cache/podcomp` |
| macOS | `~/Library/Caches/podcomp` |

## Environment variables

| Variable | Effect |
| --- | --- |
| `PODCOMP_BINARY` | Run this binary and never download anything |
| `PODCOMP_CACHE_DIR` | Where to keep the downloaded binary |
| `PODCOMP_VERSION` | Release version to fetch (default: this package's version) |
| `PODCOMP_REPO` | `owner/repo` to download from (default: `tomasky/podcomp`) |
| `PODCOMP_DOWNLOAD_BASE` | Full base URL, overriding `PODCOMP_REPO`/`PODCOMP_VERSION` |
| `PODCOMP_FORCE_DOWNLOAD` | Re-download even if the cached binary exists |
| `PODCOMP_SKIP_DOWNLOAD` | Never download; fail if the binary is absent |
| `PODCOMP_NO_VERIFY` | Skip SHA-256 verification of the download |

`PODCOMP_DOWNLOAD_BASE` and `PODCOMP_REPO` are there for forks, private mirrors
and air-gapped installs:

```sh
PODCOMP_DOWNLOAD_BASE=https://internal.example.com/podcomp npm install -g @tomasko/podcomp
```

## Other ways to install

```sh
# Installer script (no Node.js required)
curl -LsSf https://raw.githubusercontent.com/tomasky/podcomp/main/install.sh | bash

# Build from source
git clone https://github.com/tomasky/podcomp && cd podcomp
moon build --target native --release
```

## License

Apache-2.0
