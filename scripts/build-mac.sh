#!/usr/bin/env bash
# Build Flowstate.app: Rust core → UniFFI Swift bindings → Swift app → bundle.
#
#   scripts/build-mac.sh            # release build into build/Flowstate.app
#   LLAMA_SERVER=/path/to/llama-server scripts/build-mac.sh
#                                   # also bundle a self-contained llama-server
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_SRC="$ROOT/apps/mac"
LIBS="$APP_SRC/.rust-libs"
OUT="$ROOT/build/Flowstate.app"
export PATH="$HOME/.cargo/bin:$PATH"

echo "==> Building Rust core"
cargo build --release -p flowstate-ffi --features mac --manifest-path "$ROOT/Cargo.toml"

rm -rf "$LIBS" && mkdir -p "$LIBS"
cp "$ROOT/target/release/libflowstate_ffi.dylib" "$ROOT/target/release/libsherpa-onnx-c-api.dylib" "$LIBS/"
cp "$ROOT"/target/release/libonnxruntime*.dylib "$LIBS/"
install_name_tool -id @rpath/libflowstate_ffi.dylib "$LIBS/libflowstate_ffi.dylib"

echo "==> Generating Swift bindings"
GEN="$(mktemp -d)"
cargo run --quiet --release -p flowstate-ffi --features mac --bin uniffi-bindgen --manifest-path "$ROOT/Cargo.toml" -- \
    generate --library "$LIBS/libflowstate_ffi.dylib" --language swift --out-dir "$GEN"
mkdir -p "$APP_SRC/Sources/Flowstate/Generated" "$APP_SRC/Sources/flowstate_ffiFFI"
mv "$GEN/flowstate_ffi.swift" "$APP_SRC/Sources/Flowstate/Generated/"
mv "$GEN/flowstate_ffiFFI.h" "$APP_SRC/Sources/flowstate_ffiFFI/"
mv "$GEN/flowstate_ffiFFI.modulemap" "$APP_SRC/Sources/flowstate_ffiFFI/module.modulemap"
rm -rf "$GEN"

echo "==> Building Swift app"
swift build -c release --package-path "$APP_SRC"
BIN="$(swift build -c release --package-path "$APP_SRC" --show-bin-path)/Flowstate"

echo "==> Assembling $OUT"
rm -rf "$OUT"
mkdir -p "$OUT/Contents/MacOS" "$OUT/Contents/Frameworks" "$OUT/Contents/Resources"
cp "$BIN" "$OUT/Contents/MacOS/Flowstate"
cp "$APP_SRC/Support/Info.plist" "$OUT/Contents/Info.plist"
cp "$LIBS"/*.dylib "$OUT/Contents/Frameworks/"
if [[ -n "${LLAMA_SERVER:-}" ]]; then
    cp "$LLAMA_SERVER" "$OUT/Contents/Resources/llama-server"
fi

# Ad-hoc signature for local use. Releases need a Developer ID and notarization.
SIGN_ID="${SIGN_ID:--}"
for lib in "$OUT"/Contents/Frameworks/*.dylib; do
    codesign --force --sign "$SIGN_ID" "$lib"
done
[[ -f "$OUT/Contents/Resources/llama-server" ]] && codesign --force --sign "$SIGN_ID" "$OUT/Contents/Resources/llama-server"
codesign --force --sign "$SIGN_ID" --entitlements "$APP_SRC/Support/Flowstate.entitlements" "$OUT"

echo "==> Done: $OUT"
