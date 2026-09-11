#!/bin/zsh
set -euo pipefail

script_dir=${0:A:h}
project_dir=${script_dir:h}
core_dir="$project_dir/Rust/snake_core"
swift_dir="$project_dir/Generated/SnakeCoreBindings"
ffi_dir="$project_dir/Generated/SnakeCoreFFI"
staging_dir=$(mktemp -d /tmp/snake-uniffi.XXXXXX)

cleanup() {
    /bin/rm -rf "$staging_dir"
}
trap cleanup EXIT

cd "$core_dir"
cargo build --release
cargo run --bin uniffi-bindgen -- \
    --swift-sources \
    --headers \
    --modulemap \
    --module-name snake_coreFFI \
    target/release/libsnake_core.dylib \
    "$staging_dir"

mkdir -p "$swift_dir" "$ffi_dir"
cp "$staging_dir/snake_core.swift" "$swift_dir/snake_core.swift"
cp "$staging_dir/snake_coreFFI.h" "$ffi_dir/snake_coreFFI.h"
cp "$staging_dir/snake_core.modulemap" "$ffi_dir/module.modulemap"

echo "Generated SnakeCoreBindings and snake_coreFFI."
