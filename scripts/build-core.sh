#!/bin/zsh
# Build the Rust core as a static library, generate its Swift bindings with UniFFI and wrap it
# into app/Frameworks/TideCoreFFI.xcframework for SwiftPM.
set -euo pipefail
ROOT="${0:A:h:h}"
source "$HOME/.cargo/env"
export MACOSX_DEPLOYMENT_TARGET=26.0

cd "$ROOT/core"
cargo build --release -p tide-core
LIB="$ROOT/core/target/release/libtide_core.a"

GEN="$ROOT/build/ffi"
rm -rf "$GEN"
mkdir -p "$GEN/headers"
cargo run --release -q -p uniffi-bindgen -- "$LIB" "$GEN" --swift-sources --headers --modulemap --module-name tide_coreFFI \
  --modulemap-filename module.modulemap
mv "$GEN"/*.h "$GEN/module.modulemap" "$GEN/headers/"

XCF="$ROOT/app/Frameworks/TideCoreFFI.xcframework"
rm -rf "$XCF"
mkdir -p "${XCF:h}"
xcodebuild -create-xcframework -library "$LIB" -headers "$GEN/headers" -output "$XCF" >/dev/null

mkdir -p "$ROOT/app/Sources/TideFFI"
cp "$GEN"/*.swift "$ROOT/app/Sources/TideFFI/"
echo "core: $(du -h "$LIB" | cut -f1) static lib → $XCF"
echo "bindings: $(ls "$ROOT/app/Sources/TideFFI")"
