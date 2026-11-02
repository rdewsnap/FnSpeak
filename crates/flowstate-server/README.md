# flowstate-server

The optional backend behind Flowstate Cloud. The app is fully usable without it; the server adds:

- **Accounts and teams**: email magic-link sign-in, a personal workspace per user, teams with owner/admin/member roles, email invites, and API tokens for the app and MCP clients.
- **Sync**: notes and meetings (with transcript segments) pushed and pulled between devices, last writer wins. Items can be shared with a team.
- **Search** across everything you can see: SQLite FTS5 or Postgres full-text search.
- **Team glossary**: names and jargon your teammates' apps pull into their vocabulary.
- **Hosted cleanup and meeting summaries**, forwarded to Anthropic or any OpenAI-compatible endpoint.
- **MCP** at `/mcp`, so an AI assistant can search and read your notes, meetings and summaries.

One binary. SQLite by default; Postgres with `--features postgres`. Request and response text sent for cleanup is never logged or stored.

## Self-hosting with Docker Compose

```bash
git clone https://github.com/rdewsnap/flowstate && cd flowstate
cp deploy/.env.example deploy/.env
# In deploy/.env: set POSTGRES_PASSWORD, FLOWSTATE_SECRET (openssl rand -hex 32)
# and FLOWSTATE_BASE_URL. Add SMTP and FLOWSTATE_LLM_API_KEY if you want them.
docker compose -f deploy/docker-compose.yml up -d
curl http://localhost:8080/healthz
# Without SMTP, sign-in links appear in the log:
docker compose -f deploy/docker-compose.yml logs -f server
```

`deploy/fly.toml` is an example for a single Fly.io machine with SQLite on a volume. To run without Docker: `cargo run --release -p flowstate-server` (add `--features postgres` for Postgres).

## Configuration

| Variable | Default | |
|---|---|---|
| `FLOWSTATE_SECRET` | required | At least 32 characters. Mixed into stored token hashes; changing it signs everyone out. |
| `FLOWSTATE_DATABASE_URL` | `sqlite://flowstate.db` | `sqlite://path`, `sqlite::memory:` or `postgres://…` |
| `FLOWSTATE_BASE_URL` | `http://localhost:8080` | Public URL, used in emailed links and as the allowed MCP host |
| `FLOWSTATE_BIND` | `0.0.0.0:8080` | Listen address |
| `FLOWSTATE_CORS_ORIGINS` | origin of the base URL | Comma-separated browser origins allowed to call the API |
| `FLOWSTATE_TRUST_PROXY` | off | Rate-limit by the first `X-Forwarded-For` address; set behind a proxy that overwrites it |
| `FLOWSTATE_SMTP_HOST` | unset | Unset: emails are logged instead of sent |
| `FLOWSTATE_SMTP_PORT` | `587` | |
| `FLOWSTATE_SMTP_USERNAME`, `FLOWSTATE_SMTP_PASSWORD` | unset | |
| `FLOWSTATE_SMTP_FROM` | required with SMTP | |
| `FLOWSTATE_SMTP_SECURITY` | `starttls` | `starttls`, `tls` or `none` |
| `FLOWSTATE_LLM_API_KEY` | unset | Unset: hosted cleanup and summaries are off |
| `FLOWSTATE_LLM_PROVIDER` | `anthropic` | `anthropic` or `openai` (any OpenAI-compatible API) |
| `FLOWSTATE_LLM_BASE_URL` | `https://api.anthropic.com` | Required for `openai`, e.g. `https://api.groq.com/openai/v1` |
| `FLOWSTATE_LLM_MODEL` | `claude-haiku-5-5` | Cleanup model |
| `FLOWSTATE_LLM_SUMMARY_MODEL` | same as above | Summary model |
| `FLOWSTATE_LOG_FORMAT` | text | `json` for structured logs; levels via `RUST_LOG` |

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

1. Get a token: `curl -X POST $SERVER/v1/auth/magic-link -H 'content-type: application/json' -d '{"email":"you@example.com"}'`, open the emailed (or logged) link and press **Sign in**.
2. In Flowstate's settings, set cleanup to **Cloud**, provider **Other OpenAI-compatible**, base URL `$SERVER/v1`, paste the token as the API key and press **Save**. The model fields can be anything; the server uses its own model.

If the server can't be reached or answers with an error, the app falls back to its rule-based cleanup.

## Connecting an MCP client

Create a token for the client with `POST /v1/tokens {"name": "Claude"}` (or reuse one), then add the server as a remote HTTP MCP server, for example in Claude Code:

```bash
claude mcp add --transport http flowstate https://your-server/mcp --header "Authorization: Bearer fst_…"
```

or in a JSON config:

```json
{ "mcpServers": { "flowstate": { "type": "http", "url": "https://your-server/mcp",
  "headers": { "Authorization": "Bearer fst_…" } } } }
```

Tools: `search_notes(query, limit)`, `get_note(id)`, `list_meetings(since, limit)`, `get_meeting(id, include_transcript)`, `get_meeting_summary(id)`, `list_action_items(open_only)`, `create_note(title, body)`. Resources: `flowstate://notes/{id}` and `flowstate://meetings/{id}` as Markdown. Results cover exactly what the token's user can see. Revoke a client's access by deleting its token.

## Development

```bash
cargo test -p flowstate-server
# Against Postgres as well, one fresh database per test:
FLOWSTATE_TEST_POSTGRES_URL=postgres://postgres:pw@localhost:5432/postgres \
  cargo test -p flowstate-server --features postgres
```

Migrations are embedded and run at startup; SQLite and Postgres each have their own copy in `migrations/`.
