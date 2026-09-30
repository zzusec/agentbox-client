#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
scratch=$(mktemp -d "${TMPDIR:-/tmp}/agentbox-terminal-check.XXXXXX")
trap 'rm -rf "$scratch"' EXIT HUP INT TERM
{
  find "$root/../third_party/swiftterm/Sources/SwiftTerm" -name '*.swift' -print
  echo "$root/Sources/AgentboxTerm/NativeTheme.swift"
  echo "$root/scripts/terminal_rendering_checks.swift"
} | xargs swiftc -parse-as-library -o "$scratch/check"
"$scratch/check" "${1:-/private/tmp/agentbox-terminal-render-after.png}"
