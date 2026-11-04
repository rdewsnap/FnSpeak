#!/usr/bin/env bash
# Build FnSpeak.app: Rust core → UniFFI Swift bindings → Swift app → bundle.
#
#   scripts/build-mac.sh                  # release build into build/FnSpeak.app
#   scripts/build-mac.sh --skip-bundle    # stop after `swift build` (what CI uses)
#   scripts/build-mac.sh --features ""    # no speech engines: fast, enough to type-check the app
#   LLAMA_SERVER=/path/to/llama-server scripts/build-mac.sh
#                                         # also bundle a self-contained llama-server
#
# Environment:
#   FEATURES   same as --features (default "mac": Whisper + Parakeet + Metal)
#   SIGN_ID    codesign identity (default "-", ad-hoc)
#   OUT_DIR    where FnSpeak.app is written (default build/)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_SRC="$ROOT/apps/mac"
LIBS="$APP_SRC/.rust-libs"
OUT_DIR="${OUT_DIR:-$ROOT/build}"
OUT="$OUT_DIR/FnSpeak.app"
FEATURES="${FEATURES-mac}"
SKIP_BUNDLE=0
export PATH="$HOME/.cargo/bin:$PATH"

usage() { sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//'; }

while [[ $# -gt 0 ]]; do
    case "$1" in
        --skip-bundle) SKIP_BUNDLE=1 ;;
        --features) FEATURES="${2?--features needs a value}"; shift ;;
        --features=*) FEATURES="${1#--features=}" ;;
        -h|--help) usage; exit 0 ;;
        *) echo "unknown option: $1" >&2; usage >&2; exit 2 ;;
    esac
    shift
done

FEATURE_ARGS=()
[[ -n "$FEATURES" ]] && FEATURE_ARGS=(--features "$FEATURES")

build_rust() {
    echo "==> Building Rust core (features: ${FEATURES:-none})"
    cargo build --release -p fnspeak-ffi ${FEATURE_ARGS[@]+"${FEATURE_ARGS[@]}"} --manifest-path "$ROOT/Cargo.toml"

    rm -rf "$LIBS" && mkdir -p "$LIBS"
    cp "$ROOT/target/release/libfnspeak_ffi.dylib" "$LIBS/"
    # The speech engine dylibs only exist when the parakeet feature is on.
    for lib in "$ROOT"/target/release/libsherpa-onnx-c-api.dylib "$ROOT"/target/release/libonnxruntime*.dylib; do
        if [[ -e "$lib" ]]; then cp "$lib" "$LIBS/"; fi
    done
    install_name_tool -id @rpath/libfnspeak_ffi.dylib "$LIBS/libfnspeak_ffi.dylib"
}

generate_bindings() {
    echo "==> Generating Swift bindings"
    local gen
    gen="$(mktemp -d)"
    cargo run --quiet --release -p fnspeak-ffi ${FEATURE_ARGS[@]+"${FEATURE_ARGS[@]}"} --bin uniffi-bindgen --manifest-path "$ROOT/Cargo.toml" -- \
        generate --library "$LIBS/libfnspeak_ffi.dylib" --language swift --out-dir "$gen"
    mkdir -p "$APP_SRC/Sources/FnSpeak/Generated" "$APP_SRC/Sources/fnspeak_ffiFFI"
    mv "$gen/fnspeak_ffi.swift" "$APP_SRC/Sources/FnSpeak/Generated/"
    mv "$gen/fnspeak_ffiFFI.h" "$APP_SRC/Sources/fnspeak_ffiFFI/"
    mv "$gen/fnspeak_ffiFFI.modulemap" "$APP_SRC/Sources/fnspeak_ffiFFI/module.modulemap"
    rm -rf "$gen"
}

build_swift() {
    echo "==> Building Swift app"
    swift build -c release --package-path "$APP_SRC"
}

assemble_bundle() {
    local bin
    bin="$(swift build -c release --package-path "$APP_SRC" --show-bin-path)/FnSpeak"

    echo "==> Assembling $OUT"
    rm -rf "$OUT"
    mkdir -p "$OUT/Contents/MacOS" "$OUT/Contents/Frameworks" "$OUT/Contents/Resources"
    cp "$bin" "$OUT/Contents/MacOS/FnSpeak"
    cargo build --release -p fnspeak-mcp --manifest-path "$ROOT/Cargo.toml"
    cp "$ROOT/target/release/fnspeak-mcp" "$OUT/Contents/MacOS/fnspeak-mcp"
    cp "$APP_SRC/Support/Info.plist" "$OUT/Contents/Info.plist"
    cp "$LIBS"/*.dylib "$OUT/Contents/Frameworks/"
    if [[ -n "${LLAMA_SERVER:-}" ]]; then
        cp "$LLAMA_SERVER" "$OUT/Contents/Resources/llama-server"
    fi
}

sign_bundle() {
    # Ad-hoc signature for local use. scripts/notarize.sh re-signs with a
    # Developer ID for releases.
    local sign_id="${SIGN_ID:--}"
    for lib in "$OUT"/Contents/Frameworks/*.dylib; do
        codesign --force --sign "$sign_id" "$lib"
    done
    if [[ -f "$OUT/Contents/Resources/llama-server" ]]; then
        codesign --force --sign "$sign_id" "$OUT/Contents/Resources/llama-server"
    fi
    codesign --force --sign "$sign_id" "$OUT/Contents/MacOS/fnspeak-mcp"
    codesign --force --sign "$sign_id" --entitlements "$APP_SRC/Support/FnSpeak.entitlements" "$OUT"
}

build_rust
generate_bindings
build_swift

if [[ "$SKIP_BUNDLE" == 1 ]]; then
    echo "==> Done (bundle skipped)"
    exit 0
fi

assemble_bundle
sign_bundle
echo "==> Done: $OUT"
