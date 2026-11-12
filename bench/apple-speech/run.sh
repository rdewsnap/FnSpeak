#!/bin/bash
# Build the prototype, wrap it in a tiny app bundle and run it.
#
# The bundle matters: macOS only shows the Speech Recognition permission
# prompt for a process that is its own app. Run from a terminal as a bare
# binary, the tool is killed instead. The first run asks for permission.
#
#   bench/apple-speech/run.sh --manifest bench/manifest.tts.jsonl \
#       --vocab bench/vocab.example.txt --out bench/apple-speech/out/apple.jsonl
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
APP="$HERE/.build/AppleSpeechBench.app"
LOG="$HERE/out/last-run.log"

(cd "$HERE" && swift build -c release >/dev/null)
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$HERE/out"
cp "$HERE/.build/release/apple-speech" "$APP/Contents/MacOS/apple-speech"
cp "$HERE/Info.plist" "$APP/Contents/Info.plist"
codesign --force --sign - "$APP" >/dev/null 2>&1

# The app starts in /, so make every path argument absolute.
args=()
prev=""
for a in "$@"; do
    case "$prev" in
        --manifest|--vocab|--out) [[ "$a" = /* ]] || a="$PWD/$a" ;;
    esac
    args+=("$a")
    prev="$a"
done

: > "$LOG"
open -W -n --stdout "$LOG" --stderr "$LOG" "$APP" --args "${args[@]}"
cat "$LOG"
