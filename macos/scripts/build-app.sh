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
cp "$root/Info.plist" "$app/Contents/Info.plist"
if [ -n "$version" ]; then
  plutil -replace CFBundleShortVersionString -string "$version" "$app/Contents/Info.plist"
  plutil -replace CFBundleVersion -string "$version" "$app/Contents/Info.plist"
fi

codesign --force --deep --sign - "$app"
printf '%s\n' "$app"
