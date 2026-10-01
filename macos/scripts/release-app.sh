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
dmg="$root/dist/agentbox-client-macos-arm64-v${version}.dmg"
scratch=$(mktemp -d "${TMPDIR:-/tmp}/agentbox-dmg.XXXXXX")
trap 'rm -rf "$scratch"' EXIT HUP INT TERM
rm -f "$archive" "$archive.sha256"
ditto -c -k --sequesterRsrc --keepParent "$root/dist/agentbox-client.app" "$archive"
ditto "$root/dist/agentbox-client.app" "$scratch/agentbox-client.app"
ln -s /Applications "$scratch/Applications"
hdiutil create -ov -volname "agentbox-client $version" -srcfolder "$scratch" -format UDZO "$dmg"
(
  cd "$root/dist"
  shasum -a 256 "$(basename "$archive")" > "$(basename "$archive").sha256"
  shasum -a 256 "$(basename "$dmg")" > "$(basename "$dmg").sha256"
)

printf '%s\n' "$archive" "$dmg"
cat "$archive.sha256"
cat "$dmg.sha256"
