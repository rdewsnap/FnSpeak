-- Timestamps are Unix milliseconds. Ids are UUIDv7 strings.

CREATE TABLE users (
    id         TEXT PRIMARY KEY,
    email      TEXT NOT NULL UNIQUE,
    created_at INTEGER NOT NULL
);

-- Every user gets a personal team on sign-up; shared teams are created
-- explicitly. Personal teams can't take invites.
CREATE TABLE teams (
    id         TEXT PRIMARY KEY,
    name       TEXT NOT NULL,
    personal   INTEGER NOT NULL DEFAULT 0,
    created_by TEXT NOT NULL REFERENCES users (id),
    created_at INTEGER NOT NULL
);

CREATE TABLE memberships (
    team_id    TEXT NOT NULL REFERENCES teams (id) ON DELETE CASCADE,
    user_id    TEXT NOT NULL REFERENCES users (id) ON DELETE CASCADE,
    role       TEXT NOT NULL CHECK (role IN ('owner', 'admin', 'member')),
    created_at INTEGER NOT NULL,
    PRIMARY KEY (team_id, user_id)
);
CREATE INDEX memberships_user ON memberships (user_id);

-- Magic links. Only a hash of the token is stored.
CREATE TABLE login_tokens (
    token_hash TEXT PRIMARY KEY,
    email      TEXT NOT NULL,
    created_at INTEGER NOT NULL,
    expires_at INTEGER NOT NULL,
    used_at    INTEGER
);

CREATE TABLE api_tokens (
    id           TEXT PRIMARY KEY,
    user_id      TEXT NOT NULL REFERENCES users (id) ON DELETE CASCADE,
    name         TEXT NOT NULL,
    token_hash   TEXT NOT NULL UNIQUE,
    created_at   INTEGER NOT NULL,
    last_used_at INTEGER
);
CREATE INDEX api_tokens_user ON api_tokens (user_id);
