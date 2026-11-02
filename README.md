# Flowstate

Dictation for macOS that runs on your Mac and learns how you talk.

I tried one of the paid dictation apps, loved what it did to my rambling, and couldn't justify a subscription for something my laptop can clearly do itself. So I built the one I wanted. Hold Fn, talk, let go. It drops the ums, fixes "send it to Sam, sorry, Priya", and spells my company's name right because I corrected it once and it remembered.

Speech-to-text never leaves your machine. On most Apple Silicon Macs the cleanup model runs locally too. No account needed. Open source under the AGPL.

## What it does

Hold Fn and talk. When you let go, the text lands in whatever field you were in, cleaned up: fillers gone, stutters and repeats gone, and if you corrected yourself mid-sentence ("book it for Monday, actually Tuesday") you get the corrected version. It reads the field you're typing into, so Slack gets casual, Mail gets prose, and the terminal gets exactly what you said.

It knows your words. It picks names up from your projects folder, contacts and calendar, and it learns from you: if it hears "kin ju" and you retype it to Kinju, next time it's Kinju. There's an undo on the pill if it guessed wrong.

Say "scratch that" to drop the last sentence, "new line" or "new paragraph" for what you'd expect, and "send it" to press Return if you've turned that on.

A few things grew out of using it every day:

- **Notes.** ⌥Space opens a little bar for a quick note, typed or dictated. Everything's searchable. Notes can mirror to a folder as Markdown if you live in Obsidian.
- **Meetings.** It records your mic and the call's audio, transcribes as you go, and when you stop you get a summary with decisions and action items. The audio isn't kept.
- **Your AI tools can read your notes.** There's a small MCP server in the app bundle, so Claude, Cursor or whatever you use can search your notes and meetings. Read-only, local, no network.
- **Integrations.** Apple Notes, a signed webhook, meeting summaries written back to the calendar event, Shortcuts actions and `flowstate://` links.
- **Your clipboard is left alone.** Pasting the dictation saves and restores whatever you had copied, and tells clipboard managers to ignore it.

If the cleanup model is slow, missing or makes something up, you get the rule-cleaned text instead. You never lose a dictation.

## Install

There's no signed release yet, so you build it. Apple Silicon, Rust (rustup), Xcode 16 and CMake:

```bash
scripts/fetch-models.sh         # Whisper, Parakeet and a 4B cleanup model, about 3.7 GB
scripts/build-llama-server.sh   # llama-server for local cleanup
LLAMA_SERVER=build/llama-server scripts/build-mac.sh
open build/Flowstate.app
```

Homebrew's llama.cpp currently fails to compile its Metal shaders on macOS 15, which is why the second script builds a pinned version. First launch asks for microphone and Accessibility access and picks a cleanup mode based on your hardware.

If Fn opens the emoji picker, set System Settings → Keyboard → "Press 🌐 key to" → Do Nothing.

| | |
|---|---|
| Hold Fn | dictate while held |
| Double-tap Fn | hands-free, press Fn again to stop |
| ⌃⌥Z | swap the last dictation for the raw transcript |
| ⌥Space | notes bar |

## How it works

Audio goes to Whisper (whisper.cpp) or Parakeet (sherpa-onnx, faster), with your vocabulary passed in as a prompt. A rule-based filter strips um/uh, `I-I`, `the the`. Misheard names get matched by sound against your vocabulary (`PG vector` → `pgvector`). Then a small language model handles the judgment calls: `like`, `you know`, restarts, and corrections that reach back a few sentences. Last, a guardrail rejects any rewrite that adds words you didn't say.

The cleanup model runs through llama.cpp as a sidecar on localhost. If your Mac can't run it comfortably you can point it at your own API key (Anthropic, Groq, anything OpenAI-compatible), or turn it off and just get the rule-based cleanup, which is instant. In cloud mode only text is sent, never audio, and dictations with no self-corrections go to a cheaper model.

## Is it any good?

`flowstate-bench` scores the pipeline on word error rate, whether your vocabulary came out spelled right, fillers left behind, and whether self-corrections were applied. You can paste other tools' output into the manifest and score them on the same clips.

```bash
cargo run -p flowstate-bench -- --manifest bench/manifest.example.jsonl --vocab bench/vocab.example.txt
```

Record clips as 16 kHz mono WAV, e.g. `ffmpeg -f avfoundation -i ":0" -ar 16000 -ac 1 bench/clips/vocab-01.wav`, and run with `--features whisper,parakeet` for the full pipeline.

I've also started on fine-tuning a smaller model so slower Macs can do cleanup locally. `training/` has the scripts; your own recordings are never used for it.

## Connecting an AI assistant

```json
{"mcpServers":{"flowstate":{"command":"/Applications/Flowstate.app/Contents/MacOS/flowstate-mcp"}}}
```

Or for Claude Code: `claude mcp add flowstate -- /Applications/Flowstate.app/Contents/MacOS/flowstate-mcp`. Add `--allow-write` if you want the assistant to be able to save notes.

## Sync and teams

Everything above works with no account. If you want your notes on two Macs, a shared glossary with your team, or cleanup without running a model or managing a key, the app can sign in to a server. The server is in this repo (`crates/flowstate-server`), one binary, SQLite or Postgres, docker compose in `deploy/`. Run your own or use mine once it's up. Either way audio never leaves your Mac; the server only sees text you choose to sync.

## Layout

```
crates/flowstate-core     the pipeline: STT, filter, vocabulary, cleanup, commands, notes, meetings
crates/flowstate-ffi      UniFFI bindings for the Mac app
crates/flowstate-mcp      the local MCP server
crates/flowstate-bench    benchmark CLI
crates/flowstate-server   optional backend: accounts, teams, sync, hosted cleanup
apps/mac                  the menu bar app (Swift)
prompts/                  model prompts
training/                 data prep and fine-tuning
deploy/                   Dockerfile, compose, Fly config
```

Contributions welcome; see CONTRIBUTING.md for how branches work here.

## License

Flowstate is free software under the [GNU Affero General Public License](LICENSE), version 3 or later. © 2026 Ryan Dewsnap.

Use it for anything, at home or at work, at no cost. If you distribute a modified version, or run one as a service for other people, you have to publish your source under the same license.

The name Flowstate and the icon are not covered by the license. Forks need their own name and icon.
