# Snippets

Date: 2026-11-10
Status: implemented on `claude/flow-team-features-e4b1eb`; the in-app checks in the plan have not been run

## Goal

Say a trigger phrase while dictating and get a saved block of text in its
place: "my calendar link" becomes the URL, "standard sign off" becomes three
lines. Snippets are personal by default and can be shared with a team, the
same way glossary terms are.

This is the first of three team-feature sub-projects. Team vocabulary (shared
corrections and a glossary editor) and team cleanup style get their own specs.

## Non-goals

- Placeholders or variables inside snippet text.
- Syncing personal snippets between a user's own devices.
- Expanding typed text outside dictation.
- Expansion in Raw mode or in verbatim transcription (meetings, notes bar
  verbatim path).

## Data model

A snippet has:

| Field | Notes |
|---|---|
| `id` | Local UUID for personal snippets; the server id for team snippets |
| `trigger` | The phrase as the user typed it, 1 to 60 characters |
| `trigger_key` | `vocab::learn::heard_key(trigger)`: lowercase words joined by single spaces. What matching and uniqueness use |
| `text` | Plain text, may contain line breaks, 1 to 4000 characters |
| `source` | `personal` or `team` |
| `team_id`, `team_name` | Set for team snippets only |
| `can_edit` | Always true for personal; for team snippets, whether this user may edit or remove it |
| `updated_at` | Milliseconds |

`trigger_key` is unique among personal snippets. A personal and a team snippet
may share a key, and so may snippets from two teams; `active()` below says
which one fires.

### Trigger rules

A trigger is rejected, with a reason shown to the user, when:

- its key has fewer than two words;
- `vocab::learn::is_common_phrase` says it is a common phrase;
- its key equals a spoken command phrase from `commands.rs` ("scratch that",
  "new line", "new paragraph", "send it", "send that");
- another snippet of the same source already has that key.

The same rules run in the core (for personal snippets) and on the server (for
team snippets, minus the common-phrase check, which needs the core's word
list). The core closes that gap: `replace_team` runs every rule on each row
the server sends and skips the ones that fail, so a team snippet with an
everyday-phrase trigger never fires on this Mac. The editor runs the same
rules when a team snippet's trigger is edited.

## Core: `fnspeak-core/src/snippets/`

One module with two parts: the store in `mod.rs`, the matcher in `matcher.rs`.

**Store.** `SnippetStore` over SQLite, in `snippets.db` beside
`vocabulary.db`.

- `open(path)`, `in_memory()`
- `list() -> Vec<Snippet>`
- `add(trigger, text) -> Result<Snippet>` (personal)
- `update(id, trigger, text) -> Result<Snippet>` (personal)
- `remove(id) -> Result<bool>` (personal)
- `replace_team(Vec<TeamSnippet>) -> Result<usize>` replaces every team
  snippet, like `VocabIndex::replace_source`
- `validate_trigger(trigger, ignoring_id) -> Result<(), TriggerError>`
- `active() -> Vec<Snippet>` the effective set: personal, plus team snippets
  whose key no personal snippet has. Two team snippets with the same key
  (from different teams) resolve to the one with the lower `id`, so the
  result is stable.

**Matcher.** Pure functions, no I/O.

- `find(text, &[Snippet]) -> Vec<Match>` where `Match` is a byte range and a
  snippet index. Matching is on normalized words: case-insensitive,
  punctuation between and around words ignored, whole words only. Longest
  trigger first; matches never overlap.
- `expand(text, &[Snippet]) -> (String, Vec<Range<usize>>)` replaces each
  match with the snippet's text and returns the ranges the snippet text
  occupies in the output. Punctuation directly after a trigger is kept
  unless the snippet text ends in a line break or its own punctuation.

## Pipeline

In `Pipeline::clean`, after `result.filtered` is computed:

1. `matches = snippets::find(&result.filtered, &active)`. If empty, the
   pipeline behaves exactly as today.
2. The matched trigger phrases, as they appear in the transcript, are added
   to the `vocabulary` passed to the cleaner and the guardrail, so the model
   is told to keep them and the guardrail accepts them.
3. After the model returns and passes the guardrail, run `find` on the model
   text. If it finds fewer matches than step 1, the model reworded a
   trigger: discard the model text, set `fallback_reason` to
   `"cleanup changed a snippet trigger"`, and keep `result.filtered`.
4. `result.text` is the text from step 3, triggers still in it.
5. `result.insert` is `expand(result.text, &active)` run through
   `fit_to_cursor` as today, except that when the expanded text begins with
   a snippet it does not change the case of the first letter.

Only `insert` is expanded. `result.text` is what history and the recent
dictations menu store, so both show what was said.
`record_usage` and `learn_from_edit` are unchanged; a snippet's text is not
fed to vocabulary learning (the app passes `learn_from_edit` nothing when the
insert contained a snippet).

`Pipeline` gains a public `snippets: Option<SnippetStore>` field, `None`
when the store could not be opened. `active()` is read once per dictation;
if it fails the dictation goes on without expansion.

Raw mode and `transcribe_verbatim` do not call any of this.

## FFI

`fnspeak-ffi` exposes, on the engine: `snippets()`, `add_snippet`,
`update_snippet`, `remove_snippet`, `replace_team_snippets`,
`validate_snippet_trigger`. `DictationResult` and the FFI `Dictation` gain
`expanded_snippets: u32` so the app can skip edit-learning for that insert.
The FFI `Snippet` also carries `shadowed`: a team snippet whose trigger a
personal one has.

## Server

New table, in both `db/sqlite.rs` and `db/postgres.rs`:

```sql
CREATE TABLE team_snippets (
  id          TEXT PRIMARY KEY,
  team_id     TEXT NOT NULL REFERENCES teams(id) ON DELETE CASCADE,
  phrase      TEXT NOT NULL,
  phrase_key  TEXT NOT NULL,
  body        TEXT NOT NULL,
  added_by    TEXT REFERENCES users(id) ON DELETE SET NULL,
  created_at  BIGINT NOT NULL,
  updated_at  BIGINT NOT NULL,
  UNIQUE (team_id, phrase_key)
);
```

The columns are `phrase` and `body` because `trigger` is an SQL keyword. The
JSON fields are still `trigger` and `text`. It ships as migration
`0006_team_snippets.sql` for both backends.

New module `snippets.rs`, routes mirroring `glossary.rs`:

| Route | Who | |
|---|---|---|
| `GET /v1/teams/{id}/snippets` | member | That team's snippets |
| `POST /v1/teams/{id}/snippets` | member | `{trigger, text}`; 409 if the key exists |
| `PATCH /v1/teams/{id}/snippets/{sid}` | admin, owner, or `added_by` | Edit trigger or text |
| `DELETE /v1/teams/{id}/snippets/{sid}` | admin, owner, or `added_by` | |
| `GET /v1/snippets` | signed in | Snippets from every team the caller is on, with `team_name` |

Every snippet in a response carries `can_edit`, worked out for the caller.

Length limits and the structural trigger rules (two words, not a command
phrase) are enforced here and answer 400. Snippet text is not logged.

## App

**Snippets tab** in Settings (`Settings/SnippetsTab.swift`), between
Vocabulary and Notes:

- A list of personal snippets: trigger, first line of text. Add, edit and
  delete. The editor is a trigger field and a multi-line text field; a
  rejected trigger shows the reason under the field and disables Save.
- Each personal snippet's menu has "Share with ▸ <team>", for teams the user
  is on. Sharing posts it to the team and leaves the personal copy in place.
- A "From your teams" section lists team snippets read-only, with the team
  name. One shadowed by a personal snippet is marked "Replaced by yours".
  Admins, owners and the author get Edit and Remove.

**Sync.** `SyncEngine` gains `pullSnippets`, next to `pullGlossary`: fetch
`GET /v1/snippets`, skip if unchanged since last applied, otherwise
`replace_team_snippets`. It runs behind a new preference,
`syncTeamSnippets` (default on), shown in `TeamsSection` under the glossary
toggle. Signing out or turning the toggle off clears team snippets.

`ServerClient` gains the four calls the app uses: list mine, add, edit,
remove. The per-team list is for other clients.

## Errors

- A failed snippet pull leaves the last applied team snippets in place and
  sets `SyncEngine.lastError`. Notes and meetings still sync in that run, so
  a server that predates the snippet routes does not stop them.
- A failed share shows the server's message in the Snippets tab; the
  personal snippet is unaffected.
- A store that cannot be opened disables snippets for the session and is
  logged; dictation carries on without expansion.

## Testing

Core (`snippets.rs` and `pipeline.rs` tests):

- Matching: case, punctuation, word boundaries ("link" does not match
  inside "linked"), longest-first, no overlap, several snippets in one
  dictation.
- Trigger validation: each rejection rule.
- `active()`: personal over team, stable choice between two teams.
- Pipeline: expansion without a model; expansion with a model that keeps
  the trigger; fallback when the model rewords it; no expansion in Raw mode;
  first-letter case kept when the insert starts with a snippet; trailing
  commands ("… my calendar link. Send it.") still work.

Server (`tests/hosted.rs` style): member can add, non-member cannot,
duplicate key is 409, only admin/owner/author can edit or remove,
`GET /v1/snippets` spans teams.

App: no UI tests; the tab is exercised by hand against a local server.
