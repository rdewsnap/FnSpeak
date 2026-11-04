# Small cleanup model: first run

| Model | Set | Clips | WER | Terms right | Fillers left | Repair WER | Cleanup latency | Fallbacks |
|---|---|---|---|---|---|---|---|---|
| Qwen3-4B-Instruct-2507 Q4_K_M (baseline) | TTS clips, Whisper | 11 | 1.1% | 100.0% | 0 | 3.3% | 301 ms | 0 |
| flowstate-cleanup-qwen3-0.6b Q4_K_M | TTS clips, Whisper | 11 | 3.4% | 100.0% | 0 | 6.7% | 90 ms | 0 |
| flowstate-cleanup-qwen3-1.7b Q4_K_M | TTS clips, Whisper | 11 | 2.2% | 100.0% | 0 | 3.3% | 167 ms | 0 |
| Qwen3-4B-Instruct-2507 Q4_K_M (baseline) | 200 validation pairs, cleanup only | 200 | 14.8% | 62.5% | 18 | 29.1% | 652 ms | 13 |
| flowstate-cleanup-qwen3-0.6b Q4_K_M | 200 validation pairs, cleanup only | 200 | 5.2% | 87.5% | 4 | 7.6% | 170 ms | 0 |
| flowstate-cleanup-qwen3-1.7b Q4_K_M | 200 validation pairs, cleanup only | 200 | 4.1% | 87.5% | 2 | 7.5% | 315 ms | 0 |

- Data: 25,697 pairs (5% validation): corrupt.py 11,000 (WikiText-2, oasst1, Dolly), SottoASR 6,000, Aawaaz 4,000, Disfl-QA 2,500, generate_local.py with the 4B 2,197; anything overlapping bench/ dropped.
- Training: mlx-lm LoRA, rank 16, 16 layers, --mask-prompt, lr 1e-4 cosine to 1e-5; 0.6B 1,000 steps at batch 8, 1.7B 2,400 steps at batch 4 x 2 accumulation; best validation loss 0.141 (0.6B), 0.082 (1.7B).
- Export: mlx_lm.fuse, convert_hf_to_gguf.py f16, llama-quantize Q4_K_M; served by the same build/llama-server as the baseline.
- TTS row: bench/tts.jsonl via scripts/make-tts-clips.sh, Whisper large-v3-turbo q5_0, bench/vocab.example.txt; cleanup latency is the bench's average minus Whisper's (about 605 ms).
- Validation row: valid_to_manifest.py, 200 ASCII pairs; its references follow the training data's conventions, so it favours the fine-tunes; 4B fallbacks are guardrail rejections.

# Speech engine latency

| Speech engine | Clips | WER | Terms right | Repair WER | STT latency | Cleanup latency |
|---|---|---|---|---|---|---|
| Whisper large-v3-turbo q5_0, beam 5 (current default) | 11 | 2.2% | 100.0% | 3.3% | 678 ms | 187 ms |
| Whisper large-v3-turbo q5_0, beam 2 | 11 | 3.4% | 100.0% | 3.3% | 709 ms | 178 ms |
| Whisper large-v3-turbo q5_0, beam 1 (greedy) | 11 | 2.2% | 100.0% | 3.3% | 618 ms | 174 ms |
| Parakeet TDT 0.6B v2, greedy | 11 | 10.1% | 75.0% | 10.0% | 174 ms | 178 ms |

- Setup: the TTS clips and vocabulary from the first table, cleanup always flowstate-cleanup-qwen3-1.7b Q4_K_M, three runs per row on an M4 Pro with the median shown (run 1 is the coldest). STT latency is the bench's per-clip average of the transcribe call, so it includes the first clip's Metal warm-up; the `--beam` flag sets Whisper's beam size.
- Whisper latency is noisy: beam 5 ranged 675-800 ms, beam 1 607-692 ms, and beam 2 was not faster than beam 5 in two of three runs. Greedy saves roughly 60-100 ms per clip with no accuracy change on these 11 clips (beam 2's 3.4% WER is one word on this tiny set).
- Parakeet is about four times faster on the speech step (about 175 ms) but gets one in four vocabulary terms wrong and four times the WER on repairs, because it has no prompt to bias with. Hotword boosting is still experimental and was not tried here. Clean synthetic voices flatter every row, so Whisper's lead on real speech and accents may be larger.
