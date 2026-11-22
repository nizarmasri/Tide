#!/bin/zsh
# Install the Rust toolchain Tide's core needs (minimal profile, Apple silicon only).
set -euo pipefail
if ! command -v rustup >/dev/null 2>&1 && [[ ! -x "$HOME/.cargo/bin/rustup" ]]; then
  curl --proto '=https' --tlsv1.2 -4 --retry 5 -sSf https://sh.rustup.rs -o /tmp/rustup-init.sh
  sh /tmp/rustup-init.sh -y --profile minimal --default-toolchain stable --default-host aarch64-apple-darwin
fi
source "$HOME/.cargo/env"
rustup show active-toolchain
rustc --version
cargo --version
