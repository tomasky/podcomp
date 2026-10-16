#!/usr/bin/env bash
#
# Fail when the three copies of the version disagree, or when they disagree
# with a release tag.
#
#   scripts/check-version.sh           # the three copies must agree
#   scripts/check-version.sh v0.1.3    # ... and match the tag
#
# The version is written down three times: `moon.mod` is the module version,
# `podcomp.mbt` is what `podcomp --version` prints, and `npmjs/package.json` is
# what the npm launcher downloads. A stale copy ships in the release assets, so
# `ci.yml` runs this on every change and `release.yml` runs it before building.
set -euo pipefail

cd "$(dirname "$0")/.."

mod="$(sed -n 's/^version[[:space:]]*=[[:space:]]*"\(.*\)"/\1/p' moon.mod)"
src="$(sed -n 's/^pub let version : String = "\(.*\)"/\1/p' podcomp.mbt)"
npm="$(sed -n 's/^[[:space:]]*"version": "\([^"]*\)".*/\1/p' npmjs/package.json)"

printf 'moon.mod=%s podcomp.mbt=%s npmjs/package.json=%s\n' "$mod" "$src" "$npm"

if [ -z "$mod" ]; then
  printf 'error: no version in moon.mod\n' >&2
  exit 1
fi
if [ "$mod" != "$src" ]; then
  printf 'error: podcomp.mbt says %s but moon.mod says %s; run scripts/bump-version.sh\n' "$src" "$mod" >&2
  exit 1
fi
if [ "$mod" != "$npm" ]; then
  printf 'error: npmjs/package.json says %s but moon.mod says %s; run scripts/bump-version.sh\n' "$npm" "$mod" >&2
  exit 1
fi

if [ "$#" -gt 0 ] && [ -n "${1:-}" ]; then
  want="${1#v}"
  if [ "$mod" != "$want" ]; then
    printf 'error: the release is %s but the sources are %s\n' "$want" "$mod" >&2
    exit 1
  fi
  printf 'release %s matches\n' "$1"
fi
