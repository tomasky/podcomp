#!/usr/bin/env bash
# podcomp installer — https://github.com/tomasky/podcomp
#
#   curl -LsSf https://raw.githubusercontent.com/tomasky/podcomp/main/install.sh | bash
#   curl -LsSf https://raw.githubusercontent.com/tomasky/podcomp/main/install.sh | bash -s -- --version 0.1.1
#
# Environment overrides:
#   PODCOMP_VERSION        release version to install (default: latest)
#   PODCOMP_INSTALL_DIR    where to put the `podcomp` binary (default: ~/.local/bin)
#   PODCOMP_REPO           owner/repo to download from (default: tomasky/podcomp)
#   PODCOMP_DOWNLOAD_BASE  full base URL; overrides PODCOMP_REPO/PODCOMP_VERSION
set -euo pipefail

REPO="${PODCOMP_REPO:-tomasky/podcomp}"
BIN="podcomp"

say() { printf '%s\n' "$*"; }
err() { printf 'error: %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<EOF
podcomp installer

Usage:
  install.sh [options]

Options:
  -v, --version <version>       install a specific version (e.g. 0.1.1)
  -b, --install-dir <dir>       install into <dir> (default: ~/.local/bin)
      --no-verify               skip SHA-256 checksum verification
  -h, --help                    show this help

Environment:
  PODCOMP_VERSION, PODCOMP_INSTALL_DIR, PODCOMP_REPO, PODCOMP_DOWNLOAD_BASE
EOF
}

version=""
install_dir=""
verify=1

while [ $# -gt 0 ]; do
  case "$1" in
    -h | --help)
      usage
      exit 0
      ;;
    -v | --version)
      [ $# -ge 2 ] || err "--version requires a value"
      version="$2"
      shift 2
      ;;
    --version=*)
      version="${1#*=}"
      shift
      ;;
    -b | --install-dir)
      [ $# -ge 2 ] || err "--install-dir requires a value"
      install_dir="$2"
      shift 2
      ;;
    --install-dir=*)
      install_dir="${1#*=}"
      shift
      ;;
    --no-verify)
      verify=0
      shift
      ;;
    *)
      err "unknown argument: $1 (try --help)"
      ;;
  esac
done

[ -n "$version" ] || version="${PODCOMP_VERSION:-}"
[ -n "$install_dir" ] || install_dir="${PODCOMP_INSTALL_DIR:-}"
[ -n "$install_dir" ] || install_dir="$HOME/.local/bin"

# --- detect platform -------------------------------------------------------
os="$(uname -s)"
arch="$(uname -m)"
case "$os-$arch" in
  Linux-x86_64 | Linux-amd64) target="linux-x86_64" ;;
  Linux-aarch64 | Linux-arm64) target="linux-aarch64" ;;
  Darwin-arm64) target="darwin-aarch64" ;;
  Darwin-x86_64)
    err "unsupported platform: $os-$arch — the MoonBit toolchain no longer ships a darwin-x86_64 target, so no Intel macOS build is published"
    ;;
  *)
    err "unsupported platform: $os-$arch (podcomp supports linux-x86_64, linux-aarch64 and darwin-aarch64)"
    ;;
esac

# --- downloader ------------------------------------------------------------
if command -v curl >/dev/null 2>&1; then
  dl() { curl -fsSL "$1" -o "$2"; }
elif command -v wget >/dev/null 2>&1; then
  dl() { wget -qO "$2" "$1"; }
else
  err "either curl or wget is required"
fi

# --- resolve base URL ------------------------------------------------------
if [ -n "${PODCOMP_DOWNLOAD_BASE:-}" ]; then
  base="${PODCOMP_DOWNLOAD_BASE%/}"
elif [ -n "$version" ]; then
  base="https://github.com/$REPO/releases/download/v$version"
else
  base="https://github.com/$REPO/releases/latest/download"
fi

asset="podcomp-$target"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

say "podcomp: downloading $base/$asset"
dl "$base/$asset" "$tmp/$asset" || err "failed to download $base/$asset"

# --- verify ----------------------------------------------------------------
if [ "$verify" = 1 ]; then
  if dl "$base/$asset.sha256" "$tmp/$asset.sha256" 2>/dev/null; then
    if command -v sha256sum >/dev/null 2>&1; then
      (cd "$tmp" && sha256sum -c "$asset.sha256" >/dev/null) ||
        err "checksum verification failed for $asset"
    elif command -v shasum >/dev/null 2>&1; then
      (cd "$tmp" && shasum -a 256 -c "$asset.sha256" >/dev/null) ||
        err "checksum verification failed for $asset"
    else
      say "podcomp: warning: no sha256sum/shasum available, skipping verification"
    fi
  else
    say "podcomp: warning: no checksum published ($asset.sha256), skipping verification"
  fi
fi

# --- install ---------------------------------------------------------------
mkdir -p "$install_dir"
if command -v install >/dev/null 2>&1; then
  install -m 755 "$tmp/$asset" "$install_dir/$BIN"
else
  cp "$tmp/$asset" "$install_dir/$BIN"
  chmod 755 "$install_dir/$BIN"
fi

say "podcomp: installed $install_dir/$BIN"

case ":$PATH:" in
  *":$install_dir:"*) ;;
  *)
    say ""
    say "$install_dir is not on your PATH. Add it by appending this to your shell profile:"
    say ""
    say "  export PATH=\"$install_dir:\$PATH\""
    ;;
esac

"$install_dir/$BIN" --version 2>/dev/null || true
