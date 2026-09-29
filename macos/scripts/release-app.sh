#!/bin/sh
set -eu

version=${1:-}
if [ -z "$version" ]; then
  echo "usage: $0 VERSION" >&2
  exit 2
fi
version=${version#v}

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
AGENTBOX_VERSION="$version" "$root/scripts/build-app.sh"

archive="$root/dist/agentbox-client-macos-arm64-v${version}.zip"
rm -f "$archive" "$archive.sha256"
ditto -c -k --sequesterRsrc --keepParent "$root/dist/agentbox-client.app" "$archive"
(
  cd "$root/dist"
  shasum -a 256 "$(basename "$archive")" > "$(basename "$archive").sha256"
)

printf '%s\n' "$archive"
cat "$archive.sha256"
