#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$root"

version=${AGENTBOX_VERSION:-}

swift build -c release
go build -o "$root/.build/release/abox-sync" ../cmd/abox-sync

app="$root/dist/agentbox-client.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$root/.build/release/AgentboxTerm" "$app/Contents/MacOS/AgentboxTerm"
cp "$root/.build/release/abox-sync" "$app/Contents/Resources/abox-sync"
cp "$root/Assets/AppIcon.icns" "$app/Contents/Resources/AppIcon.icns"
cp "$root/Info.plist" "$app/Contents/Info.plist"
if [ -n "$version" ]; then
  plutil -replace CFBundleShortVersionString -string "$version" "$app/Contents/Info.plist"
  plutil -replace CFBundleVersion -string "$version" "$app/Contents/Info.plist"
fi

# Freshly copied files can carry FinderInfo/provenance metadata that codesign
# rejects as "resource fork, Finder information, or similar detritus".
find "$app" -name .DS_Store -delete
find "$app" -name '._*' -delete
xattr -cr "$app"

codesign --force --deep --sign - "$app"
printf '%s\n' "$app"
