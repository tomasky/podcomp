#!/usr/bin/env bash
#
# Set the version in all three places at once.
#
#   scripts/bump-version.sh 0.2.0
#   scripts/bump-version.sh --bump patch
#
# `moon.mod` is the module version, `podcomp.mbt` is what `podcomp --version`
# prints, and `npmjs/package.json` is what the npm launcher downloads.
# `scripts/check-version.sh` fails when the three disagree (CI runs it) and
# `release.yml` fails when they disagree with the tag, so bump them together
# with this script rather than editing one copy by hand.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
cd "$here/.."

usage() {
  printf 'usage: %s <version>|--bump patch|minor|major\n' "$(basename "$0")" >&2
  exit 2
}

case "${1:-}" in
  --bump)
    case "${2:-}" in
      major | minor | patch) ;;
      *) usage ;;
    esac
    current="$(sed -n 's/^version[[:space:]]*=[[:space:]]*"\(.*\)"/\1/p' moon.mod)"
    major="${current%%.*}"
    rest="${current#*.}"
    minor="${rest%%.*}"
    patch="${rest#*.}"
    case "$2" in
      major) major=$((major + 1)); minor=0; patch=0 ;;
      minor) minor=$((minor + 1)); patch=0 ;;
      patch) patch=$((patch + 1)) ;;
    esac
    version="$major.$minor.$patch"
    ;;
  '' | -*) usage ;;
  *) version="$1" ;;
esac

case "$version" in
  [0-9]*\.[0-9]*\.[0-9]*) ;;
  *)
    printf 'error: %s is not an X.Y.Z version\n' "$version" >&2
    exit 2
    ;;
esac

# `sed -i` is not portable between GNU and BSD, so rewrite through a temp file.
rewrite() {
  file="$1"
  expression="$2"
  tmp="$(mktemp)"
  sed "$expression" "$file" >"$tmp"
  mv "$tmp" "$file"
}

rewrite moon.mod "s|^version[[:space:]]*=.*|version = \"$version\"|"
rewrite podcomp.mbt "s|^pub let version : String = .*|pub let version : String = \"$version\"|"
rewrite npmjs/package.json "s|^\([[:space:]]*\)\"version\": .*|\1\"version\": \"$version\",|"

exec "$here/check-version.sh"
