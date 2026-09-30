#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
scratch=$(mktemp -d "${TMPDIR:-/tmp}/agentbox-app-smoke.XXXXXX")
trap 'rm -rf "$scratch"' EXIT HUP INT TERM
find "$root/../third_party/swiftterm/Sources/SwiftTerm" -name '*.swift' -print0 |
  xargs -0 swiftc -parse-as-library -module-name SwiftTerm -emit-library -emit-module \
    -emit-module-path "$scratch/SwiftTerm.swiftmodule" -o "$scratch/libSwiftTerm.dylib"
{
  find "$root/Sources/AgentboxTerm" -name '*.swift' ! -name main.swift -print0
  printf '%s\0' "$root/scripts/app_smoke_checks.swift"
} | xargs -0 swiftc -parse-as-library -I "$scratch" -L "$scratch" -lSwiftTerm \
  -Xlinker -rpath -Xlinker "$scratch" -o "$scratch/check"
"$scratch/check"
