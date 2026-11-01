#!/usr/bin/env bash
# Build a self-contained llama-server (static, Metal shaders embedded) for
# local cleanup, and put it at build/llama-server.
#
# Pinned on purpose: newer llama.cpp Metal shaders use constexpr bfloat
# conversions that the macOS 15 Metal compiler rejects at runtime, which is
# why Homebrew's llama-server fails to start on macOS 15.
#
#   scripts/build-llama-server.sh
#   LLAMA_CPP_REF=<commit> scripts/build-llama-server.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
REF="${LLAMA_CPP_REF:-d81235049384534c167caea52b85a694f6103d14}"
SRC="$ROOT/build/llama.cpp-src"

if [[ ! -d "$SRC/.git" ]]; then
    git init -q "$SRC"
    git -C "$SRC" remote add origin https://github.com/ggml-org/llama.cpp
fi
git -C "$SRC" fetch -q --depth 1 origin "$REF"
git -C "$SRC" checkout -q FETCH_HEAD

cmake -S "$SRC" -B "$SRC/build" -DCMAKE_BUILD_TYPE=Release \
    -DBUILD_SHARED_LIBS=OFF -DGGML_METAL_EMBED_LIBRARY=ON \
    -DLLAMA_CURL=OFF -DLLAMA_OPENSSL=OFF -DLLAMA_BUILD_TESTS=OFF -DLLAMA_BUILD_EXAMPLES=OFF -DLLAMA_BUILD_SERVER=ON > /dev/null
cmake --build "$SRC/build" --target llama-server -j "$(sysctl -n hw.ncpu)" > /dev/null

cp "$SRC/build/bin/llama-server" "$ROOT/build/llama-server"
echo "built $ROOT/build/llama-server"
echo "bundle it with: LLAMA_SERVER=build/llama-server scripts/build-mac.sh"
