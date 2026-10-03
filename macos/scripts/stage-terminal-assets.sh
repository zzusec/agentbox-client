#!/bin/sh
# Assembles the terminal page into one directory: our page and glue from
# macos/Resources/terminal, and the xterm.js build the web console already
# serves (internal/web/static/vendor), so both clients run the same engine.
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
target=${1:?usage: stage-terminal-assets.sh TARGET_DIR}
vendor="$root/../internal/web/static/vendor"

mkdir -p "$target"
cp "$root/Resources/terminal/terminal.html" "$root/Resources/terminal/terminal.js" "$target/"
for file in xterm.js xterm.css addon-fit.js addon-webgl.js; do
  cp "$vendor/$file" "$target/$file"
done
# xterm.js is MIT-licensed; its licences travel with it.
mkdir -p "$target/licenses"
cp "$root/../third_party/licenses/"@xterm_* "$target/licenses/"
