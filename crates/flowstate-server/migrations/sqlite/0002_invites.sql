CREATE TABLE invites (
    id          TEXT PRIMARY KEY,
    team_id     TEXT NOT NULL REFERENCES teams (id) ON DELETE CASCADE,
    email       TEXT NOT NULL,
    role        TEXT NOT NULL CHECK (role IN ('owner', 'admin', 'member')),
    token_hash  TEXT NOT NULL UNIQUE,
    invited_by  TEXT NOT NULL REFERENCES users (id),
    created_at  INTEGER NOT NULL,
    expires_at  INTEGER NOT NULL,
    accepted_at INTEGER,
    accepted_by TEXT REFERENCES users (id)
);
CREATE INDEX invites_team ON invites (team_id);
