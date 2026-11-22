#!/bin/zsh
# Copy Homebrew's aria2c and every non-system library it needs into an app bundle:
#   Contents/Helpers/aria2c, Contents/Frameworks/*.dylib (install names rewritten, re-signed).
#   scripts/bundle-aria2.sh /path/to/Tide.app [signing identity]
set -euo pipefail
APP="$1"
IDENTITY="${2:--}"
SRC="$(readlink -f "$(command -v aria2c || echo /opt/homebrew/bin/aria2c)")"
HELPERS="$APP/Contents/Helpers"
FW="$APP/Contents/Frameworks"
mkdir -p "$HELPERS" "$FW"
cp -f "$SRC" "$HELPERS/aria2c"
chmod 755 "$HELPERS/aria2c"

is_local() { [[ "$1" == /opt/homebrew/* || "$1" == /usr/local/* ]] }

# Breadth-first over the dependency graph.
queue=("$HELPERS/aria2c")
typeset -A done_libs
while (( ${#queue} )); do
  bin="${queue[1]}"; queue=("${queue[@]:1}")
  for dep in $(otool -L "$bin" | tail -n +2 | awk '{print $1}'); do
    is_local "$dep" || continue
    name="${dep:t}"
    if [[ -z "${done_libs[$name]:-}" ]]; then
      cp -f "$(readlink -f "$dep")" "$FW/$name"
      chmod 644 "$FW/$name"
      install_name_tool -id "@executable_path/../Frameworks/$name" "$FW/$name" 2>/dev/null
      done_libs[$name]=1
      queue+=("$FW/$name")
    fi
    install_name_tool -change "$dep" "@executable_path/../Frameworks/$name" "$bin" 2>/dev/null
  done
done

# Nothing may still point into Homebrew.
for f in "$HELPERS/aria2c" "$FW"/*.dylib; do
  if otool -L "$f" | tail -n +2 | awk '{print $1}' | grep -qE '^/(opt/homebrew|usr/local)/'; then
    echo "still links Homebrew: $f" >&2; otool -L "$f" >&2; exit 1
  fi
done

for f in "$FW"/*.dylib "$HELPERS/aria2c"; do
  codesign --force --sign "$IDENTITY" --timestamp=none "$f" >/dev/null 2>&1
done
"$HELPERS/aria2c" --version | head -1 >/dev/null
echo "aria2: $("$HELPERS/aria2c" --version | head -1) + ${#done_libs} libraries"
