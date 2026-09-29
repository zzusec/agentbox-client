#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$root"

swift build -c release
go build -o "$root/.build/release/abox-sync" ../cmd/abox-sync

app="$root/dist/Agentbox Term.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$root/.build/release/AgentboxTerm" "$app/Contents/MacOS/AgentboxTerm"
cp "$root/.build/release/abox-sync" "$app/Contents/Resources/abox-sync"
cp "$root/Info.plist" "$app/Contents/Info.plist"

codesign --force --deep --sign - "$app"
printf '%s\n' "$app"
