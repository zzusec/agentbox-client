#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
scratch=$(mktemp -d "${TMPDIR:-/tmp}/agentbox-app-smoke.XXXXXX")
trap 'rm -rf "$scratch"' EXIT HUP INT TERM
# The checks are not an app bundle, so the terminal page is staged next to
# them and the terminal view is pointed at it.
sh "$root/scripts/stage-terminal-assets.sh" "$scratch/terminal"
{
  find "$root/Sources/AgentboxTerm" -name '*.swift' ! -name main.swift -print0
  printf '%s\0' "$root/scripts/app_smoke_checks.swift"
} | xargs -0 swiftc -parse-as-library -o "$scratch/check"
AGENTBOX_TERMINAL_ASSETS="$scratch/terminal" "$scratch/check"
