# fnspeak-server

The optional backend behind FnSpeak Cloud. The app is fully usable without it; the server adds:

- **Accounts and teams**: email magic-link sign-in, a personal workspace per user, teams with owner/admin/member roles, email invites, and API tokens for the app and MCP clients.
- **Sync**: notes and meetings (with transcript segments) pushed and pulled between devices, last writer wins. Items can be shared with a team.
- **Search** across everything you can see: SQLite FTS5 or Postgres full-text search.
- **Team glossary**: names and jargon your teammates' apps pull into their vocabulary.
- **Hosted cleanup and meeting summaries**, forwarded to Anthropic or any OpenAI-compatible endpoint.
- **MCP** at `/mcp`, so an AI assistant can search and read your notes, meetings and summaries.

One binary. SQLite by default; Postgres with `--features postgres`. Request and response text sent for cleanup is never logged or stored.

## Self-hosting with Docker Compose

```bash
git clone https://github.com/rdewsnap/fnspeak && cd fnspeak
cp deploy/.env.example deploy/.env
# In deploy/.env: set POSTGRES_PASSWORD, FNSPEAK_SECRET (openssl rand -hex 32)
# and FNSPEAK_BASE_URL. Add SMTP and FNSPEAK_LLM_API_KEY if you want them.
docker compose -f deploy/docker-compose.yml up -d
curl http://localhost:8080/healthz
# Without SMTP, sign-in links appear in the log:
docker compose -f deploy/docker-compose.yml logs -f server
```

`deploy/fly.toml` is an example for a single Fly.io machine with SQLite on a volume. To run without Docker: `cargo run --release -p fnspeak-server` (add `--features postgres` for Postgres).

## Configuration

| Variable | Default | |
|---|---|---|
| `FNSPEAK_SECRET` | required | At least 32 characters. Mixed into stored token hashes; changing it signs everyone out. |
| `FNSPEAK_DATABASE_URL` | `sqlite://fnspeak.db` | `sqlite://path`, `sqlite::memory:` or `postgres://…` |
| `FNSPEAK_BASE_URL` | `http://localhost:8080` | Public URL, used in emailed links and as the allowed MCP host |
| `FNSPEAK_BIND` | `0.0.0.0:8080` | Listen address |
| `FNSPEAK_CORS_ORIGINS` | origin of the base URL | Comma-separated browser origins allowed to call the API |
| `FNSPEAK_TRUST_PROXY` | off | Rate-limit by the first `X-Forwarded-For` address; set behind a proxy that overwrites it |
| `FNSPEAK_SMTP_HOST` | unset | Unset: emails are logged instead of sent |
| `FNSPEAK_SMTP_PORT` | `587` | |
| `FNSPEAK_SMTP_USERNAME`, `FNSPEAK_SMTP_PASSWORD` | unset | |
| `FNSPEAK_SMTP_FROM` | required with SMTP | |
| `FNSPEAK_SMTP_SECURITY` | `starttls` | `starttls`, `tls` or `none` |
| `FNSPEAK_LLM_API_KEY` | unset | Unset: hosted cleanup and summaries are off |
| `FNSPEAK_LLM_PROVIDER` | `anthropic` | `anthropic` or `openai` (any OpenAI-compatible API) |
| `FNSPEAK_LLM_BASE_URL` | `https://api.anthropic.com` | Required for `openai`, e.g. `https://api.groq.com/openai/v1` |
| `FNSPEAK_LLM_MODEL` | `claude-haiku-5-5` | Cleanup model |
| `FNSPEAK_LLM_SUMMARY_MODEL` | same as above | Summary model |
| `FNSPEAK_LOG_FORMAT` | text | `json` for structured logs; levels via `RUST_LOG` |

## API

Everything except sign-in and `/healthz` takes `Authorization: Bearer <token>`. Errors are `{"error": {"code", "message"}}`. Timestamps are Unix milliseconds; ids are UUIDv7 strings chosen by the client.

| | |
|---|---|
| `POST /v1/auth/magic-link` `{email}` | Email a sign-in link (rate limited) |
| `GET /v1/auth/verify?token=` | Page the link opens |
| `POST /v1/auth/verify` `{token, name?}` | Exchange the link token for an API token; creates the account on first sign-in |
| `GET /v1/me` | Account and teams |
| `GET/POST /v1/tokens`, `DELETE /v1/tokens/{id}` | API tokens |
| `GET/POST /v1/teams`, `GET/PATCH /v1/teams/{id}` | Teams |
| `GET/POST /v1/teams/{id}/invites`, `DELETE …/invites/{id}` | Invites |
| `GET /v1/invites/{token}`, `POST /v1/invites/{token}/accept` | Look at or accept an invite (must be signed in as the invited address) |
| `PATCH/DELETE /v1/teams/{id}/members/{user_id}` | Change role, remove, leave |
| `GET/POST /v1/teams/{id}/glossary`, `DELETE …/glossary/{id}` | Team glossary |
| `GET /v1/glossary` | Glossary terms from all your teams |
| `GET /v1/notes`, `GET/PUT/DELETE /v1/notes/{id}` | Notes |
| `GET /v1/meetings`, `GET/PUT/DELETE /v1/meetings/{id}` | Meetings; `PUT` may include `segments` |
| `GET /v1/sync?since=&limit=` | Changes since a cursor, including deletions |
| `POST /v1/sync` `{notes, meetings}` | Push a batch; per-item `applied`, `stale`, `forbidden` or `rejected` |
| `GET /v1/search?q=` | Full-text search |
| `POST /v1/cleanup` | Clean up a dictation |
| `POST /v1/summarize` | Summarize a meeting transcript into Markdown and action items |
| `POST /v1/chat/completions` | Cleanup in OpenAI format, for the app's existing cloud mode |
| `POST /mcp` | MCP (Streamable HTTP) |
| `GET /healthz` | |

Sync: `PUT` or push a note or meeting with your own `updated_at`; it's stored only if newer than the server's copy. Pull with `since` set to the last `cursor` you got (start at 0) until `more` is false. The cursor is a server-side sequence number, so device clocks don't affect what you receive. To share an item, set `shared_with_team_id` to one of your teams; `visibility` defaults to `team` when it's set. Only the owner can change an item.

## Pointing the Mac app at a server

1. Open FnSpeak's settings, go to **Account**, enter the server URL (or leave the default for FnSpeak Cloud) and your email, and request a sign-in link.
2. Open the emailed (or logged) link, press **Sign in**, and paste the link or the token it shows back into the Account tab.
3. Turn on **Sync** to keep notes and meetings on the server, and pick **FnSpeak Cloud (or your server)** as the cleanup provider if you want hosted cleanup and summaries.

If the server can't be reached or answers with an error, the app falls back to its rule-based cleanup.

## Connecting an MCP client

Create a token for the client with `POST /v1/tokens {"name": "Claude"}` (or reuse one), then add the server as a remote HTTP MCP server, for example in Claude Code:

```bash
claude mcp add --transport http fnspeak https://your-server/mcp --header "Authorization: Bearer fst_…"
```

or in a JSON config:

```json
{ "mcpServers": { "fnspeak": { "type": "http", "url": "https://your-server/mcp",
  "headers": { "Authorization": "Bearer fst_…" } } } }
```

Tools: `search_notes(query, limit)`, `get_note(id)`, `list_meetings(since, limit)`, `get_meeting(id, include_transcript)`, `get_meeting_summary(id)`, `list_action_items(open_only)`, `create_note(title, body)`. Resources: `fnspeak://notes/{id}` and `fnspeak://meetings/{id}` as Markdown. Results cover exactly what the token's user can see. Revoke a client's access by deleting its token.

## Development

```bash
cargo test -p fnspeak-server
# Against Postgres as well, one fresh database per test:
FNSPEAK_TEST_POSTGRES_URL=postgres://postgres:pw@localhost:5432/postgres \
  cargo test -p fnspeak-server --features postgres
```

Migrations are embedded and run at startup; SQLite and Postgres each have their own copy in `migrations/`.
