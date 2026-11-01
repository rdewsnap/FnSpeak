#!/usr/bin/env bash
# Download the default models into ~/Library/Application Support/Flowstate/Models.
#
#   scripts/fetch-models.sh            # Whisper + Parakeet + cleanup model
#   scripts/fetch-models.sh whisper    # just one of: whisper, parakeet, cleanup
#
# Sizes: Whisper large-v3-turbo q5 ~550 MB, Parakeet TDT 0.6B int8 ~650 MB,
# Qwen3 4B Instruct Q4_K_M ~2.5 GB. Local cleanup also needs llama-server:
#   scripts/build-llama-server.sh
set -euo pipefail

DEST="$HOME/Library/Application Support/Flowstate/Models"
mkdir -p "$DEST"
WHAT="${1:-all}"

WHISPER_URL="https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo-q5_0.bin"
PARAKEET_URL="https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/sherpa-onnx-nemo-parakeet-tdt-0.6b-v2-int8.tar.bz2"
CLEANUP_URL="https://huggingface.co/unsloth/Qwen3-4B-Instruct-2507-GGUF/resolve/main/Qwen3-4B-Instruct-2507-Q4_K_M.gguf"

fetch() {
    local url="$1" out="$2"
    if [[ -e "$out" ]]; then
        echo "already have $(basename "$out")"
        return
    fi
    echo "downloading $(basename "$out")"
    curl -fL --progress-bar -o "$out.part" "$url"
    mv "$out.part" "$out"
}

if [[ "$WHAT" == all || "$WHAT" == whisper ]]; then
    fetch "$WHISPER_URL" "$DEST/ggml-large-v3-turbo-q5_0.bin"
fi

if [[ "$WHAT" == all || "$WHAT" == parakeet ]]; then
    if [[ ! -d "$DEST/parakeet-tdt-0.6b-v2" ]]; then
        archive="$DEST/parakeet.tar.bz2"
        fetch "$PARAKEET_URL" "$archive"
        tmp="$(mktemp -d)"
        tar -xjf "$archive" -C "$tmp"
        mv "$tmp"/sherpa-onnx-nemo-parakeet-tdt-0.6b-v2-int8 "$DEST/parakeet-tdt-0.6b-v2"
        rm -rf "$tmp" "$archive"
    else
        echo "already have parakeet-tdt-0.6b-v2"
    fi
fi

if [[ "$WHAT" == all || "$WHAT" == cleanup ]]; then
    fetch "$CLEANUP_URL" "$DEST/Qwen3-4B-Instruct-2507-Q4_K_M.gguf"
    [[ -x "$(dirname "$0")/../build/llama-server" ]] || echo "note: local cleanup needs llama-server — run scripts/build-llama-server.sh"
fi

echo "models are in $DEST"
