#!/usr/bin/env bash
# LoRA fine-tune a small model on Apple Silicon, then export a GGUF the app
# can load through llama-server.
#
#   uv sync --extra train
#   ./train_mlx.sh                       # defaults below
#   BASE=Qwen/Qwen3-0.6B ITERS=1000 ./train_mlx.sh
#
# Export to GGUF needs a llama.cpp checkout for convert_hf_to_gguf.py and a
# built llama-quantize: LLAMA_CPP=~/src/llama.cpp ./train_mlx.sh
# (scripts/build-llama-server.sh leaves one in build/llama.cpp-src; build
# the quantizer there with `cmake --build build --target llama-quantize`).
#
# Training runs under nice; the conversion step pulls torch into a
# throwaway environment, since only llama.cpp's converter needs it.
set -euo pipefail
cd "$(dirname "$0")"

BASE="${BASE:-Qwen/Qwen3-1.7B}"
ITERS="${ITERS:-1200}"
BATCH="${BATCH:-8}"
LAYERS="${LAYERS:-16}"
RANK="${RANK:-16}"
LR="${LR:-1e-4}"
EVAL_EVERY="${EVAL_EVERY:-100}"
OUT="${OUT:-out}"
DATA="${DATA:-data}"
NAME="flowstate-cleanup-$(basename "$BASE" | tr '[:upper:]' '[:lower:]')"

[[ -f "$DATA/train.jsonl" ]] || { echo "run build_dataset.py first"; exit 1; }
mkdir -p "$OUT"

# The CLI has no flag for LoRA rank; it comes from a config file.
cat > "$OUT/lora.yaml" <<EOF
lora_parameters:
  rank: $RANK
  scale: 20.0
  dropout: 0.0
lr_schedule:
  name: cosine_decay
  warmup: $((ITERS / 20))
  arguments: [$LR, $ITERS, $(python3 -c "print($LR / 10)")]
EOF

if [[ "${SKIP_TRAIN:-}" != 1 ]]; then
    nice uv run mlx_lm.lora -c "$OUT/lora.yaml" \
        --model "$BASE" --train --data "$DATA" \
        --iters "$ITERS" --batch-size "$BATCH" --num-layers "$LAYERS" --learning-rate "$LR" \
        --steps-per-eval "$EVAL_EVERY" --val-batches 25 --save-every "$EVAL_EVERY" \
        --max-seq-length 2048 ${GRAD_CHECKPOINT:+--grad-checkpoint} \
        --mask-prompt --adapter-path "$OUT/adapters" 2>&1 | tee "$OUT/train.log"
fi

uv run mlx_lm.fuse --model "$BASE" --adapter-path "$OUT/adapters" --save-path "$OUT/$NAME" --dequantize

if [[ -n "${LLAMA_CPP:-}" ]]; then
    # Same transformers as training, or the converter can't read the saved tokenizer config.
    TRANSFORMERS="$(uv run python -c 'import transformers; print(transformers.__version__)')"
    uv run --no-project --python 3.12 --with torch --with "transformers==$TRANSFORMERS" --with sentencepiece \
        --with safetensors --with protobuf --with numpy \
        python "$LLAMA_CPP/convert_hf_to_gguf.py" "$OUT/$NAME" --outfile "$OUT/$NAME-f16.gguf" --outtype f16
    "$LLAMA_CPP/build/bin/llama-quantize" "$OUT/$NAME-f16.gguf" "$OUT/$NAME-Q4_K_M.gguf" Q4_K_M
    echo "GGUF ready: $OUT/$NAME-Q4_K_M.gguf"
    echo "Copy it to ~/Library/Application Support/Flowstate/Models/ — the app prefers files named flowstate*."
else
    echo "Fused model in $OUT/$NAME. Set LLAMA_CPP to also export a GGUF."
fi
