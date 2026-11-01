#!/usr/bin/env bash
# Turn bench/tts.jsonl into 16 kHz WAV clips with macOS `say`, and write
# bench/manifest.tts.jsonl pointing at them.
set -euo pipefail
cd "$(dirname "$0")/../bench"
mkdir -p clips
VOICE="${VOICE:-Samantha}"
python3 - "$VOICE" <<'PY'
import json, subprocess, sys
voice = sys.argv[1]
out = []
for line in open("tts.jsonl"):
    line = line.strip()
    if not line or line.startswith("//"):
        continue
    clip = json.loads(line)
    wav = f"clips/{clip['id']}.wav"
    subprocess.run(["say", "-v", voice, "-o", wav, "--file-format=WAVE", "--data-format=LEI16@16000", clip.pop("say")], check=True)
    clip["audio"] = wav
    out.append(json.dumps(clip))
open("manifest.tts.jsonl", "w").write("\n".join(out) + "\n")
print(f"wrote {len(out)} clips with voice {voice}")
PY
