#!/bin/zsh
# Build Tide.app end to end and install it to ~/Applications.
#   scripts/build.sh              core + app, sign, install, relaunch if it was running
#   SKIP_CORE=1 scripts/build.sh  reuse the last Rust build
#   SIGN_IDENTITY="-" ...         ad-hoc signing
set -euo pipefail
ROOT="${0:A:h:h}"
APP="$ROOT/build/Tide.app"
DEST="${DEST:-$HOME/Applications/Tide.app}"
# Signing: SIGN_IDENTITY, else the identity in scripts/.signing-identity (not committed), else
# ad hoc, which runs fine on any Mac. A stable identity keeps permissions across rebuilds.
if [[ -z "${SIGN_IDENTITY:-}" && -f "$ROOT/scripts/.signing-identity" ]]; then
  SIGN_IDENTITY="$(<"$ROOT/scripts/.signing-identity")"
fi
SIGN_IDENTITY="${SIGN_IDENTITY:--}"

[[ -n "${SKIP_CORE:-}" && -d "$ROOT/app/Frameworks/TideCoreFFI.xcframework" ]] || "$ROOT/scripts/build-core.sh"

cd "$ROOT/app"
swift build -c release --arch arm64
BIN="$(swift build -c release --arch arm64 --show-bin-path)/Tide"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Tide"
strip -x "$APP/Contents/MacOS/Tide" 2>/dev/null || true
cp "$ROOT/app/Resources/Info.plist" "$APP/Contents/Info.plist"

# Icon: drawn by the app itself (DESIGN.md §10).
ICNS="$ROOT/build/AppIcon.icns"
if [[ ! -f "$ICNS" || -n "${REDRAW_ICON:-}" ]]; then
  WORK="$(mktemp -d)"
  "$BIN" --render-icon "$WORK/icon.png" >/dev/null
  "$BIN" --render-icon "$WORK/icon-small.png" --small >/dev/null
  mkdir "$WORK/AppIcon.iconset"
  # 16 and 32 px (and their @2x) use the small-size art: wider cuts, stronger waves.
  for size in 16 32 128 256 512; do
    src="$WORK/icon.png"; (( size <= 32 )) && src="$WORK/icon-small.png"
    sips -z $size $size "$src" --out "$WORK/AppIcon.iconset/icon_${size}x${size}.png" >/dev/null
    sips -z $((size * 2)) $((size * 2)) "$src" --out "$WORK/AppIcon.iconset/icon_${size}x${size}@2x.png" >/dev/null
  done
  iconutil -c icns "$WORK/AppIcon.iconset" -o "$ICNS"
  rm -rf "$WORK"
fi
cp "$ICNS" "$APP/Contents/Resources/AppIcon.icns"

"$ROOT/scripts/bundle-aria2.sh" "$APP" "$SIGN_IDENTITY"

codesign --force --sign "$SIGN_IDENTITY" --timestamp=none "$APP"
codesign --verify --strict "$APP"

# Replace the installed copy (quit it first so aria2 writes its progress files).
WAS_RUNNING=0
if pgrep -xq Tide; then
  WAS_RUNNING=1
  osascript -e 'tell application id "com.nizar.tide" to quit' >/dev/null 2>&1 || true
  for i in {1..50}; do pgrep -xq Tide || break; sleep 0.2; done
fi
mkdir -p "${DEST:h}"
rm -rf "$DEST"
cp -R "$APP" "$DEST"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$DEST" >/dev/null 2>&1 || true
[[ $WAS_RUNNING == 1 ]] && open "$DEST"

echo "Signed with: $SIGN_IDENTITY"
echo "Size:        $(du -sh "$DEST" | cut -f1)"
echo "Installed:   $DEST"
