#!/usr/bin/env bash
# LoRA fine-tune a small model on Apple Silicon, then export a GGUF the app
# can load through llama-server.
#
#   uv sync --extra train
#   ./train_mlx.sh                       # defaults below
#   BASE=Qwen/Qwen3-0.6B ITERS=3000 ./train_mlx.sh
#
# Export to GGUF needs a llama.cpp checkout for convert_hf_to_gguf.py and
# llama-quantize: LLAMA_CPP=~/src/llama.cpp ./train_mlx.sh
set -euo pipefail
cd "$(dirname "$0")"

BASE="${BASE:-Qwen/Qwen3-1.7B}"
ITERS="${ITERS:-2000}"
BATCH="${BATCH:-8}"
LAYERS="${LAYERS:-16}"
OUT="${OUT:-out}"
NAME="flowstate-cleanup-$(basename "$BASE" | tr '[:upper:]' '[:lower:]')"

[[ -f data/train.jsonl ]] || { echo "run build_dataset.py first"; exit 1; }

uv run mlx_lm.lora \
    --model "$BASE" --train --data data \
    --iters "$ITERS" --batch-size "$BATCH" --num-layers "$LAYERS" \
    --mask-prompt --adapter-path "$OUT/adapters"

uv run mlx_lm.fuse --model "$BASE" --adapter-path "$OUT/adapters" --save-path "$OUT/$NAME" --dequantize

if [[ -n "${LLAMA_CPP:-}" ]]; then
    uv run python "$LLAMA_CPP/convert_hf_to_gguf.py" "$OUT/$NAME" --outfile "$OUT/$NAME-f16.gguf" --outtype f16
    "$LLAMA_CPP/build/bin/llama-quantize" "$OUT/$NAME-f16.gguf" "$OUT/$NAME-Q4_K_M.gguf" Q4_K_M
    echo "GGUF ready: $OUT/$NAME-Q4_K_M.gguf"
    echo "Copy it to ~/Library/Application Support/Flowstate/Models/ — the app prefers files named flowstate*."
else
    echo "Fused model in $OUT/$NAME. Set LLAMA_CPP to also export a GGUF."
fi
