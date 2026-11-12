# Apple speech prototype

A throwaway tool that runs the bench clips through Apple's built-in speech recognition, so `fnspeak-bench` can score it next to Whisper and Parakeet. It lives on the `apple-speech-prototype` branch and nothing in the app or the crates depends on it.

## Running it

```bash
bench/apple-speech/run.sh --manifest bench/manifest.tts.jsonl \
    --vocab bench/vocab.example.txt --out bench/apple-speech/out/apple.jsonl
```

The first run asks for Speech Recognition permission. `run.sh` wraps the binary in a small app bundle because macOS kills a bare command line tool that asks for it.

The output is a copy of the manifest where each audio clip has become a transcript-only clip holding what Apple heard. Score it the usual way:

```bash
cargo run --release -p fnspeak-bench -- --manifest bench/apple-speech/out/apple.jsonl \
    --vocab bench/vocab.example.txt \
    --llama-server build/llama-server --local-model <cleanup model>.gguf
```

Flags: `--no-hints` skips the vocabulary hints, `--allow-network` lets Apple use its servers (off by default, so audio stays on the Mac), `--engine` picks the recogniser.

| `--engine` | API | Needs | State |
|---|---|---|---|
| `legacy` (default) | `SFSpeechRecognizer`, on-device | macOS 14 | Works, results below |
| `dictation` | `SpeechAnalyzer` + `DictationTranscriber` | macOS 26 and Xcode 26 | Written from the docs, never compiled |
| `speech` | `SpeechAnalyzer` + `SpeechTranscriber` | macOS 26 and Xcode 26 | Written from the docs, never compiled |

## First results, 2026-11-12

11 synthetic-voice clips from `bench/manifest.tts.jsonl`, vocabulary from `bench/vocab.example.txt`, cleanup by `flowstate-cleanup-qwen3-1.7b` Q4_K_M, one run each on macOS 15.7.7. Apple is the older on-device recogniser.

After cleanup:

| Speech engine | WER | Terms right | Repair WER | Speech | Cleanup |
|---|---|---|---|---|---|
| Whisper large-v3-turbo q5_0 | 2.2% | 100.0% | 3.3% | 321 ms | 107 ms |
| Parakeet TDT 0.6B v2 | 9.0% | 87.5% | 10.0% | 152 ms | 138 ms |
| Apple, with 9 hints | 12.4% | 75.0% | 13.3% | 178 ms | 159 ms |
| Apple, no hints | 12.4% | 75.0% | 13.3% | 149 ms | 161 ms |

Raw, before any cleanup (the references are the cleaned-up sentences, so every engine looks bad here; the terms column is the useful one):

| Speech engine | WER | Terms right |
|---|---|---|
| Whisper | 36.0% | 100.0% |
| Parakeet | 50.6% | 25.0% |
| Apple, with hints | 43.8% | 62.5% |
| Apple, no hints | 50.6% | 12.5% |

What Apple got wrong, after cleanup:

| Said | Apple heard |
|---|---|
| build (twice) | bill |
| cache key | cash key |
| the auth ones | the odd ones |
| Kubernetes | cube needs |
| at four | for |
| DoDSafeTransfer | DOD safe transfer |

Reading it:

- Apple is about as fast as Parakeet and roughly twice as fast as Whisper on the speech step.
- Its accuracy is the worst of the three. 12.4% is 11 wrong words out of 89.
- Most of its misses are ordinary words (build, cache, auth), not names. Cleanup can't repair those, because "bill" and "cash key" are valid English.
- Hints help the raw output a lot (5 of 8 terms right against 1 of 8), but the sound-alike matching in the core recovers the same terms without them, so the end result is identical.
- Self-correction repair still works on Apple's transcripts, apart from the clip where it lost a word.

Limits: 11 clips, synthetic voices, one run, and Apple's own docs say this on-device recogniser is the less accurate one. The macOS 26 engines are the real test and have not been run. Apple's time includes starting the recogniser on the first clip, as Whisper's does.
