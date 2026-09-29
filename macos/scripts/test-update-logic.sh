#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
output="${TMPDIR:-/tmp}/agentbox-update-logic-check"

swiftc \
  "$root/Sources/AgentboxTerm/UpdateLogic.swift" \
  "$root/scripts/update_logic_checks.swift" \
  -o "$output"
"$output"
